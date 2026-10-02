// POST /functions/v1/payments-webhook   (deploy with --no-verify-jwt; authenticity is checked with the Stripe signature)
// The ONLY place where payments become "succeeded" and plans are granted.
import Stripe from "npm:stripe@16.12.0";
import { adminClient } from "../_shared/common.ts";
import { fromMinor, stripeClient } from "../_shared/payments.ts";

const cryptoProvider = Stripe.createSubtleCryptoProvider();

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("POST only", { status: 405 });
  const secret = Deno.env.get("STRIPE_WEBHOOK_SECRET");
  const sig = req.headers.get("stripe-signature");
  if (!secret || !sig) return new Response("Webhook not configured", { status: 400 });

  const stripe = stripeClient();
  const raw = await req.text();
  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(raw, sig, secret, undefined, cryptoProvider);
  } catch (e) {
    return new Response(`Bad signature: ${(e as Error).message}`, { status: 400 });
  }

  const db = adminClient();
  const log = (event: string, meta: Record<string, unknown>) => db.from("usage_logs").insert({ event, meta });

  try {
    switch (event.type) {
      case "checkout.session.completed": {
        const s = event.data.object as Stripe.Checkout.Session;
        const m = s.metadata ?? {};
        if (s.payment_status !== "paid" && s.mode === "payment") break;
        const amount = fromMinor(s.amount_total ?? 0, s.currency ?? "usd");
        const currency = (s.currency ?? "usd").toUpperCase();
        if (m.kind === "donation") {
          await db.from("donations").update({ status: "succeeded", provider_ref: (s.subscription as string) ?? s.id }).eq("id", m.reference_id);
          await db.from("payment_transactions").upsert({ user_id: m.user_id, kind: "donation", amount, currency, status: "succeeded", provider: "stripe", provider_ref: s.id, raw: s as unknown as Record<string, unknown> }, { onConflict: "provider_ref" });
        } else if (m.kind === "subscription") {
          const sub = await stripe.subscriptions.retrieve(s.subscription as string);
          await db.from("subscriptions").update({
            status: sub.status, provider_customer_id: s.customer as string, provider_subscription_id: sub.id,
            current_period_end: new Date(sub.current_period_end * 1000).toISOString(), cancel_at_period_end: sub.cancel_at_period_end,
          }).eq("id", m.reference_id);
          await db.from("profiles").update({ subscription_plan: m.plan, subscription_status: sub.status }).eq("id", m.user_id);
          await db.from("payment_transactions").upsert({ user_id: m.user_id, kind: "subscription", amount, currency, status: "succeeded", provider: "stripe", provider_ref: s.id, raw: s as unknown as Record<string, unknown> }, { onConflict: "provider_ref" });
        }
        break;
      }
      case "invoice.paid": {
        const inv = event.data.object as Stripe.Invoice;
        if (inv.billing_reason === "subscription_create") break; // already recorded by checkout.session.completed
        const m = (inv.subscription_details?.metadata ?? {}) as Record<string, string>;
        await db.from("payment_transactions").upsert({
          user_id: m.user_id ?? null, kind: m.kind === "donation" ? "donation" : "subscription",
          amount: fromMinor(inv.amount_paid, inv.currency), currency: inv.currency.toUpperCase(), status: "succeeded", provider: "stripe", provider_ref: inv.id,
          raw: inv as unknown as Record<string, unknown>,
        }, { onConflict: "provider_ref" });
        if (m.kind === "donation" && m.user_id) {
          await db.from("donations").insert({ user_id: m.user_id, amount: fromMinor(inv.amount_paid, inv.currency), currency: inv.currency.toUpperCase(), interval: "month", status: "succeeded", provider: "stripe", provider_ref: inv.id });
        }
        break;
      }
      case "customer.subscription.updated":
      case "customer.subscription.deleted": {
        const sub = event.data.object as Stripe.Subscription;
        const m = sub.metadata ?? {};
        const status = event.type === "customer.subscription.deleted" ? "canceled" : sub.status;
        await db.from("subscriptions").update({ status, current_period_end: new Date(sub.current_period_end * 1000).toISOString(), cancel_at_period_end: sub.cancel_at_period_end })
          .eq("provider_subscription_id", sub.id);
        if (m.kind === "subscription" && m.user_id) {
          const active = ["active", "trialing", "past_due"].includes(status);
          await db.from("profiles").update({ subscription_plan: active ? m.plan : "free", subscription_status: status }).eq("id", m.user_id);
        }
        break;
      }
      case "charge.refunded": {
        const ch = event.data.object as Stripe.Charge;
        await db.from("payment_transactions").update({ status: "refunded" }).eq("provider_ref", (ch.payment_intent as string) ?? ch.id);
        break;
      }
    }
    await log("payment.webhook", { type: event.type, id: event.id });
  } catch (e) {
    console.error(e);
    await log("error", { where: "payments-webhook", type: event.type, message: (e as Error).message });
    return new Response("handler error", { status: 500 }); // Stripe retries
  }
  return new Response(JSON.stringify({ received: true }), { headers: { "Content-Type": "application/json" } });
});

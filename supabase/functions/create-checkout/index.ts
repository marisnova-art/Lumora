// POST /functions/v1/create-checkout
// body: { kind: 'donation'|'subscription'|'portal', amount, currency, interval, plan, message, anonymous, success_url, cancel_url, return_url }
// Live mode  → creates a provider checkout session and a *pending* row. Payment success is only recorded by payments-webhook.
// Test mode  → records clearly flagged is_test rows; never charges. Test plan upgrades require ALLOW_TEST_UPGRADES=true.
import { adminClient, getSetting, handle, HttpError, json, requireUser } from "../_shared/common.ts";
import { getProvider } from "../_shared/payments.ts";

const PLANS = ["premium", "ai_premium"] as const;

Deno.serve(handle(async (req) => {
  if (req.method !== "POST") throw new HttpError(405, "POST only");
  const user = await requireUser(req);
  const db = adminClient();
  const body = await req.json().catch(() => ({}));
  const kind = String(body.kind ?? "");

  const { data: profile } = await db.from("profiles").select("account_status").eq("id", user.id).maybeSingle();
  if (profile?.account_status === "suspended") throw new HttpError(403, "Account suspended");

  const mode = await getSetting<string>(db, "payments_mode", "test");
  const provider = mode === "live" ? getProvider() : null;
  if (mode === "live" && !provider) throw new HttpError(503, "Live payments are enabled but no provider key is configured");

  // ---------- billing portal
  if (kind === "portal") {
    if (!provider) return json(req, { message: "Billing portal is not available in test mode." });
    const { data: sub } = await db.from("subscriptions").select("provider_customer_id").eq("user_id", user.id)
      .not("provider_customer_id", "is", null).order("created_at", { ascending: false }).limit(1).maybeSingle();
    if (!sub?.provider_customer_id) throw new HttpError(404, "No billing customer found");
    const url = await provider.createPortal(sub.provider_customer_id, String(body.return_url ?? ""));
    return json(req, { url });
  }

  const currency = String(body.currency ?? (await getSetting(db, "currency", "USD"))).toUpperCase().slice(0, 3);
  const successUrl = String(body.success_url ?? ""), cancelUrl = String(body.cancel_url ?? "");
  if (provider && (!/^https:\/\//.test(successUrl) || !/^https:\/\//.test(cancelUrl))) throw new HttpError(400, "https success/cancel URLs required");

  // ---------- donation
  if (kind === "donation") {
    const amount = Math.round(Number(body.amount) * 100) / 100;
    if (!(amount >= 1 && amount <= 10000)) throw new HttpError(400, "Amount must be between 1 and 10000");
    const interval = body.interval === "month" ? "month" : "once";
    const { data: don, error } = await db.from("donations").insert({
      user_id: user.id, amount, currency, interval, message: String(body.message ?? "").slice(0, 280),
      is_anonymous: !!body.anonymous, status: provider ? "pending" : "test", is_test: !provider, provider: provider?.name ?? "test",
    }).select("id").single();
    if (error) throw error;
    if (!provider) {
      await db.from("payment_transactions").insert({ user_id: user.id, kind: "donation", amount, currency, status: "test", provider: "test", provider_ref: `test_${don.id}`, is_test: true });
      return json(req, { test: true, donation_id: don.id });
    }
    const r = await provider.createCheckout({ kind: "donation", userId: user.id, email: user.email, amount, currency, interval, referenceId: don.id, successUrl, cancelUrl });
    await db.from("donations").update({ provider_ref: r.providerRef }).eq("id", don.id);
    return json(req, { url: r.url });
  }

  // ---------- subscription
  if (kind === "subscription") {
    const plan = String(body.plan) as typeof PLANS[number];
    if (!PLANS.includes(plan)) throw new HttpError(400, "Unknown plan");
    const interval = body.interval === "year" ? "year" : "month";
    const plans = await getSetting<Record<string, { price_month: number; price_year: number }>>(db, "plans", {});
    const amount = Number(interval === "year" ? plans[plan]?.price_year : plans[plan]?.price_month) || 0; // display only; Stripe price IDs are authoritative
    const { data: prev } = await db.from("subscriptions").select("provider_customer_id").eq("user_id", user.id)
      .not("provider_customer_id", "is", null).limit(1).maybeSingle();
    const { data: sub, error } = await db.from("subscriptions").insert({
      user_id: user.id, plan, interval, status: provider ? "incomplete" : "test", provider: provider?.name ?? "test", is_test: !provider,
      provider_customer_id: prev?.provider_customer_id ?? null,
    }).select("id").single();
    if (error) throw error;
    if (!provider) {
      await db.from("payment_transactions").insert({ user_id: user.id, kind: "subscription", amount, currency, status: "test", provider: "test", provider_ref: `test_${sub.id}`, is_test: true });
      if (Deno.env.get("ALLOW_TEST_UPGRADES") === "true") {
        await db.from("profiles").update({ subscription_plan: plan, subscription_status: "test" }).eq("id", user.id);
      }
      return json(req, { test: true, subscription_id: sub.id, upgraded: Deno.env.get("ALLOW_TEST_UPGRADES") === "true" });
    }
    const r = await provider.createCheckout({ kind: "subscription", userId: user.id, email: user.email, amount, currency, interval, plan, referenceId: sub.id, successUrl, cancelUrl, customerId: prev?.provider_customer_id });
    return json(req, { url: r.url });
  }

  throw new HttpError(400, "Unknown kind");
}));

// Payment provider abstraction. Add new providers (Paddle, Toss Payments, PayPal…) by implementing PaymentProvider.
import Stripe from "npm:stripe@16.12.0";

export type CheckoutKind = "donation" | "subscription";
export interface CheckoutInput {
  kind: CheckoutKind;
  userId: string;
  email?: string;
  amount: number;             // major units (e.g. 4.99)
  currency: string;           // ISO 4217
  interval: "once" | "month" | "year";
  plan?: "premium" | "ai_premium";
  referenceId: string;        // our donation/subscription row id
  successUrl: string;
  cancelUrl: string;
  customerId?: string | null;
}
export interface CheckoutResult { url: string; providerRef: string; }

export interface PaymentProvider {
  name: string;
  createCheckout(i: CheckoutInput): Promise<CheckoutResult>;
  createPortal(customerId: string, returnUrl: string): Promise<string>;
}

const ZERO_DECIMAL = new Set(["JPY", "KRW", "VND", "CLP", "ISK", "UGX", "XAF", "XOF"]);
export const toMinor = (amount: number, currency: string) =>
  ZERO_DECIMAL.has(currency.toUpperCase()) ? Math.round(amount) : Math.round(amount * 100);
export const fromMinor = (amount: number, currency: string) =>
  ZERO_DECIMAL.has(currency.toUpperCase()) ? amount : amount / 100;

export function stripeClient(): Stripe {
  const key = Deno.env.get("STRIPE_SECRET_KEY");
  if (!key) throw new Error("STRIPE_SECRET_KEY is not configured");
  return new Stripe(key, { apiVersion: "2024-06-20", httpClient: Stripe.createFetchHttpClient() });
}

export class StripeProvider implements PaymentProvider {
  name = "stripe";
  stripe = stripeClient();

  async createCheckout(i: CheckoutInput): Promise<CheckoutResult> {
    const meta = { user_id: i.userId, kind: i.kind, plan: i.plan ?? "", reference_id: i.referenceId, interval: i.interval };
    let line: Stripe.Checkout.SessionCreateParams.LineItem;
    if (i.kind === "subscription") {
      // Price IDs live in secrets so admins can change prices in Stripe without code changes.
      const envKey = `STRIPE_PRICE_${(i.plan ?? "").toUpperCase()}_${i.interval === "year" ? "YEAR" : "MONTH"}`;
      const price = Deno.env.get(envKey);
      if (!price) throw new Error(`${envKey} is not configured`);
      line = { price, quantity: 1 };
    } else {
      line = {
        quantity: 1,
        price_data: {
          currency: i.currency.toLowerCase(),
          unit_amount: toMinor(i.amount, i.currency),
          product_data: { name: i.interval === "month" ? "Lumora Studio — monthly support" : "Lumora Studio — donation" },
          ...(i.interval === "month" ? { recurring: { interval: "month" as const } } : {}),
        },
      };
    }
    const recurring = i.kind === "subscription" || i.interval === "month";
    const session = await this.stripe.checkout.sessions.create({
      mode: recurring ? "subscription" : "payment",
      line_items: [line],
      success_url: i.successUrl,
      cancel_url: i.cancelUrl,
      client_reference_id: i.referenceId,
      customer: i.customerId ?? undefined,
      customer_email: i.customerId ? undefined : i.email,
      metadata: meta,
      ...(recurring ? { subscription_data: { metadata: meta } } : { payment_intent_data: { metadata: meta } }),
      allow_promotion_codes: i.kind === "subscription",
    });
    return { url: session.url!, providerRef: session.id };
  }

  async createPortal(customerId: string, returnUrl: string): Promise<string> {
    const s = await this.stripe.billingPortal.sessions.create({ customer: customerId, return_url: returnUrl });
    return s.url;
  }
}

export function getProvider(): PaymentProvider | null {
  const name = (Deno.env.get("PAYMENT_PROVIDER") ?? "stripe").toLowerCase();
  if (name === "stripe" && Deno.env.get("STRIPE_SECRET_KEY")) return new StripeProvider();
  return null; // → test mode
}

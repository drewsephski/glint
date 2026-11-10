import Stripe from "stripe";
import { OFFER, ServiceError, Store } from "./store.ts";

export class Payments {
  stripe: Stripe;
  store: Store;
  origin: string;
  webhookSecret: string;
  constructor(stripe: Stripe, store: Store, origin: string, webhookSecret: string) {
    this.stripe = stripe; this.store = store; this.origin = origin; this.webhookSecret = webhookSecret;
  }

  async fulfill(session: Pick<Stripe.Checkout.Session, "id" | "mode" | "status" | "payment_status" | "amount_total" | "currency" | "payment_intent" | "metadata">, account?: string) {
    const owner = session.metadata?.account;
    if (!owner || !/^[a-f0-9]{64}$/.test(owner) || (account && owner !== account)) throw new ServiceError(403, "Purchase does not belong to this access code.");
    if (session.payment_status !== "paid" || session.status !== "complete") return;
    if (session.mode !== "payment" || session.amount_total !== OFFER.priceCents || session.currency !== OFFER.currency || session.metadata?.pack !== "voice-50k-v1") {
      throw new ServiceError(400, "Purchase does not match the voiceover pack.");
    }
    const paymentID = typeof session.payment_intent === "string" ? session.payment_intent : session.payment_intent?.id;
    if (!paymentID) throw new ServiceError(400, "Purchase is missing its payment.");
    // Inspect the current charge too: a delayed completion event must not restore refunded/disputed credits.
    const payment = await this.stripe.paymentIntents.retrieve(paymentID, { expand: ["latest_charge"] });
    const charge = payment.latest_charge;
    if (charge && typeof charge !== "string" && (charge.refunded || charge.amount_refunded > 0 || charge.disputed)) {
      this.store.revoke(paymentID); return;
    }
    if (payment.status === "succeeded") this.store.credit(session.id, owner, paymentID);
  }

  async refresh(account: string) {
    const id = this.store.checkout(account);
    if (id) await this.fulfill(await this.stripe.checkout.sessions.retrieve(id), account);
  }

  async checkout(account: string): Promise<string> {
    const existing = this.store.checkout(account);
    if (existing) {
      const session = await this.stripe.checkout.sessions.retrieve(existing);
      if (session.status === "open" && session.url) return session.url;
      await this.fulfill(session, account);
    }
    const session = await this.stripe.checkout.sessions.create({
      mode: "payment", payment_method_types: ["card"],
      line_items: [{ quantity: 1, price_data: { currency: OFFER.currency, unit_amount: OFFER.priceCents,
        product_data: { name: "Glint Voiceover — 50,000 characters", description: "One-time purchase. No subscription. Generated and regenerated text uses characters." } } }],
      metadata: { account, pack: "voice-50k-v1" },
      success_url: `${this.origin}/complete`, cancel_url: `${this.origin}/cancel`,
    }, { idempotencyKey: `voice:${account}:${existing ?? "first"}` });
    if (!session.url) throw new ServiceError(502, "Checkout is unavailable. Please try again.");
    this.store.saveCheckout(session.id, account);
    return session.url;
  }

  async webhook(raw: Buffer, signature: string) {
    let event: Stripe.Event;
    try { event = this.stripe.webhooks.constructEvent(raw, signature, this.webhookSecret); }
    catch { throw new ServiceError(400, "Invalid payment signature."); }
    switch (event.type) {
      case "checkout.session.completed":
      case "checkout.session.async_payment_succeeded":
        await this.fulfill(await this.stripe.checkout.sessions.retrieve(event.data.object.id)); break;
      case "charge.refunded": {
        const payment = event.data.object.payment_intent;
        if (payment) this.store.revoke(typeof payment === "string" ? payment : payment.id);
        break;
      }
      case "charge.dispute.created": {
        const charge = await this.stripe.charges.retrieve(typeof event.data.object.charge === "string" ? event.data.object.charge : event.data.object.charge.id);
        if (charge.payment_intent) this.store.revoke(typeof charge.payment_intent === "string" ? charge.payment_intent : charge.payment_intent.id);
        break;
      }
    }
  }
}

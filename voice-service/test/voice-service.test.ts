import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import Stripe from "stripe";
import { OFFER, Store } from "../src/store.ts";
import { createService, accountFromHeader, hash } from "../src/service.ts";
import { Payments } from "../src/payments.ts";

const token = `glint_${"a".repeat(64)}`;
const account = hash(token);
const voiceID = "21m00Tcm4TlvDq8ikWAM";
const secret = "whsec_test_fixture";
const session = (overrides: Partial<Stripe.Checkout.Session> = {}) => ({
  id: "cs_test_1", object: "checkout.session", mode: "payment" as const, status: "complete" as const, payment_status: "paid" as const,
  amount_total: 2900, currency: "usd", payment_intent: "pi_1", metadata: { account, pack: "voice-50k-v1" }, ...overrides,
});

function fixture(options: { paid?: boolean; upstream?: typeof fetch; session?: ReturnType<typeof session>; charge?: object } = {}) {
  const store = new Store(":memory:");
  if (options.paid) store.credit("cs_fixture", account, "pi_fixture");
  const calls: { url: string; body?: string }[] = [];
  const stripe = new Stripe("sk_test_fixture", { maxNetworkRetries: 0, httpClient: Stripe.createFetchHttpClient(async (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
    const url = String(input); calls.push({ url, body: init?.body?.toString() });
    if (url.includes("payment_intents")) return Response.json({ id: "pi_1", status: "succeeded", latest_charge: options.charge ?? { refunded: false, amount_refunded: 0, disputed: false } });
    return Response.json(options.session ?? session());
  }) });
  const payments = new Payments(stripe, store, "https://voice.example.com", secret);
  const providerCalls: { url: string; headers: Headers; body: unknown }[] = [];
  const handle = createService({ store, payments, elevenlabsKey: "owner-secret-must-stay-server-side", voiceIDs: [voiceID],
    fetch: options.upstream ?? (async (input, init) => {
      providerCalls.push({ url: String(input), headers: new Headers(init?.headers), body: init?.body ? JSON.parse(String(init.body)) : null });
      return Response.json({ audio_base64: "YXVkaW8=", alignment: { characters: ["H", "i"], character_start_times_seconds: [0, 0.1], character_end_times_seconds: [0.1, 0.2] } });
    }),
  });
  function request(path: string, body?: unknown, auth: string | null = token, id = "generation-test-0001") {
    return handle(new Request(`https://voice.example.com${path}`, {
      method: body ? "POST" : "GET",
      headers: { ...(auth ? { authorization: `Bearer ${auth}` } : {}), "content-type": "application/json", "idempotency-key": id },
      ...(body ? { body: JSON.stringify(body) } : {}),
    }));
  }
  return { store, payments, stripe, handle, request, calls, providerCalls };
}

test("offer is exactly $29 USD for 50,000 characters", async () => {
  const f = fixture();
  assert.deepEqual(await (await f.request("/v1/offer", undefined, null)).json(), OFFER);
  f.store.db.close();
});

test("missing, malformed and unrelated tokens cannot generate or inspect another balance", async () => {
  const f = fixture({ paid: true });
  assert.throws(() => accountFromHeader("Bearer fake"));
  assert.equal((await f.request("/v1/synthesize", { voiceID, text: "Hello" }, null)).status, 401);
  assert.equal((await f.request("/v1/synthesize", { voiceID, text: "Hello" }, `glint_${"b".repeat(64)}`)).status, 402);
  assert.equal(f.providerCalls.length, 0);
  f.store.db.close();
});

test("creating an unpaid access code never grants characters", async () => {
  const f = fixture();
  assert.deepEqual(await (await f.request("/v1/access")).json(), { purchased: false, remaining: 0 });
  assert.equal((await f.request("/v1/voices")).status, 402);
  f.store.db.close();
});

test("paid fulfillment is verified with Stripe, idempotent and survives reopening the database", async () => {
  const dir = mkdtempSync(join(tmpdir(), "glint-voice-test-"));
  const f = fixture();
  const path = join(dir, "voice.sqlite");
  const store = new Store(path);
  const payments = new Payments(f.stripe, store, "https://voice.example.com", secret);
  try {
    await payments.fulfill(session());
    await payments.fulfill(session());
    assert.equal(store.balance(account), 50_000);
    store.db.close();
    const reopened = new Store(path);
    assert.equal(reopened.balance(account), 50_000);
    reopened.db.close();
  } finally { f.store.db.close(); rmSync(dir, { recursive: true }); }
});

test("unpaid, wrong-price and foreign purchases cannot unlock generation", async () => {
  const f = fixture();
  await f.payments.fulfill(session({ payment_status: "unpaid" }));
  assert.equal(f.store.balance(account), 0);
  await assert.rejects(f.payments.fulfill(session({ amount_total: 100 })));
  await assert.rejects(f.payments.fulfill(session(), "other-account"));
  assert.equal(f.store.balance(account), 0);
  f.store.db.close();
});

test("checkout uses a server-owned one-time price and never places the recovery code in Stripe metadata", async () => {
  const f = fixture({ session: session({ status: "open", url: "https://checkout.stripe.com/c/pay/test" }) });
  const response = await f.request("/v1/checkout", {});
  assert.equal(response.status, 200);
  const body = f.calls[0].body ?? "";
  const params = new URLSearchParams(body);
  assert.equal(params.get("mode"), "payment");
  assert.equal(params.get("line_items[0][price_data][unit_amount]"), "2900");
  assert.equal(params.get("metadata[account]"), account);
  assert.ok(!body.includes(token));
  assert.equal(f.store.balance(account), 0);
  const second = await f.request("/v1/checkout", {});
  assert.equal(second.status, 200);
  assert.equal(f.calls.filter(call => call.body?.includes("mode=payment")).length, 1);
  f.store.db.close();
});

test("webhook rejects forged signatures and grants a signed, verified payment exactly once", async () => {
  const f = fixture();
  const payload = JSON.stringify({ id: "evt_1", object: "event", type: "checkout.session.completed", data: { object: session() } });
  const send = (signature: string) => f.handle(new Request("https://voice.example.com/v1/webhook", { method: "POST", body: payload, headers: { "stripe-signature": signature } }));
  assert.equal((await send("forged")).status, 400);
  assert.equal(f.store.balance(account), 0);
  const signature = f.stripe.webhooks.generateTestHeaderString({ payload, secret });
  assert.equal((await send(signature)).status, 200);
  assert.equal((await send(signature)).status, 200);
  assert.equal(f.store.balance(account), 50_000);
  f.store.db.close();
});

test("refunds are idempotent and a late payment event cannot restore revoked credit", async () => {
  const f = fixture();
  f.store.revoke("pi_1");
  await f.payments.fulfill(session());
  assert.equal(f.store.balance(account), 0);
  f.store.credit("cs_2", account, "pi_2");
  f.store.reserve(account, "test-1", "hash", 100);
  f.store.revoke("pi_2"); f.store.revoke("pi_2");
  assert.equal(f.store.balance(account), -100);
  f.store.db.close();
});

test("shared-account webhooks acknowledge other products without granting voiceover credit", async () => {
  const f = fixture({ session: session({ metadata: { product: "another-product" } }) });
  const payload = JSON.stringify({ id: "evt_other", object: "event", type: "checkout.session.completed", data: { object: { id: "cs_other" } } });
  const signature = f.stripe.webhooks.generateTestHeaderString({ payload, secret });
  await f.payments.webhook(Buffer.from(payload), signature);
  assert.equal(f.store.balance(account), 0);
  assert.equal(f.calls.length, 1);
  f.store.db.close();
});

test("current refunded or disputed charges cannot fulfill even without a prior refund webhook", async () => {
  for (const charge of [{ refunded: true }, { amount_refunded: 100 }, { disputed: true }]) {
    const f = fixture({ charge });
    await f.payments.fulfill(session());
    assert.equal(f.store.balance(account), 0);
    f.store.db.close();
  }
});

test("synthesis debits exact Unicode characters, locks model and keeps the owner's key on the provider request", async () => {
  const f = fixture({ paid: true });
  const response = await f.request("/v1/synthesize", { voiceID, text: "Hi 🌍", model_id: "expensive_model" });
  assert.equal(response.status, 200);
  assert.equal(f.store.balance(account), 49_996);
  assert.equal(f.providerCalls[0].headers.get("xi-api-key"), "owner-secret-must-stay-server-side");
  assert.equal((f.providerCalls[0].body as { model_id: string }).model_id, "eleven_multilingual_v2");
  assert.ok(!(await response.text()).includes("owner-secret"));
  f.store.db.close();
});

test("replaying a generation returns the cached audio without spending or calling ElevenLabs twice", async () => {
  const f = fixture({ paid: true });
  const body = { voiceID, text: "Hello" };
  const first = await f.request("/v1/synthesize", body);
  const second = await f.request("/v1/synthesize", body);
  assert.equal(await first.text(), await second.text());
  assert.equal(f.providerCalls.length, 1);
  assert.equal(f.store.balance(account), 49_995);
  assert.equal((await f.request("/v1/synthesize", { voiceID, text: "Changed" })).status, 409);
  f.store.db.close();
});

test("concurrent requests cannot overdraw or duplicate upstream work", async () => {
  let finish!: (response: Response) => void;
  const f = fixture({ paid: true, upstream: async () => new Promise(resolve => { finish = resolve; }) });
  const first = f.request("/v1/synthesize", { voiceID, text: "Hello" });
  // Wait until the provider is called, so the first reservation is held.
  while (!finish) await new Promise(resolve => setImmediate(resolve));
  assert.equal((await f.request("/v1/synthesize", { voiceID, text: "World" }, token, "generation-test-0002")).status, 409);
  finish(Response.json({ audio_base64: "YXVkaW8=" }));
  assert.equal((await first).status, 200);
  assert.equal(f.store.balance(account), 49_995);
  f.store.db.close();
});

test("exhausted allowance, non-allowlisted voices and invalid settings never call the provider", async () => {
  const f = fixture({ paid: true });
  for (const body of [{ voiceID: "privatevoiceid123", text: "Hi" }, { voiceID, text: " " }, { voiceID, text: "a".repeat(5001) }, { voiceID, text: "Hi", voice_settings: { speed: 10 } }]) {
    assert.equal((await f.request("/v1/synthesize", body)).status, 400);
  }
  f.store.reserve(account, "consume", "hash", 50_000); f.store.complete(account, "consume", "{}");
  assert.equal((await f.request("/v1/synthesize", { voiceID, text: "Hello" })).status, 402);
  assert.equal(f.providerCalls.length, 0);
  f.store.db.close();
});

test("explicit provider failures refund once and do not expose provider secrets", async () => {
  const f = fixture({ paid: true, upstream: async () => new Response("owner-secret", { status: 429 }) });
  const response = await f.request("/v1/synthesize", { voiceID, text: "Hello" });
  assert.equal(response.status, 502);
  assert.ok(!(await response.text()).includes("owner-secret"));
  f.store.refundGeneration(account, "generation-test-0001");
  assert.equal(f.store.balance(account), 50_000);
  assert.equal((await f.request("/v1/synthesize", { voiceID, text: "Hello" })).status, 409);
  f.store.db.close();
});

test("uncertain network delivery retains reservation and prevents an automatic retry", async () => {
  const f = fixture({ paid: true, upstream: async () => { throw new Error("timeout"); } });
  assert.equal((await f.request("/v1/synthesize", { voiceID, text: "Hello" })).status, 504);
  assert.equal(f.store.balance(account), 49_995);
  assert.equal((await f.request("/v1/synthesize", { voiceID, text: "Hello" })).status, 409);
  f.store.db.close();
});

test("checkout landing page cannot grant credit", async () => {
  const f = fixture();
  assert.equal((await f.request("/complete", undefined, null)).status, 200);
  assert.equal(f.store.balance(account), 0);
  f.store.db.close();
});

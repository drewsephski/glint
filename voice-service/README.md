# Glint Voiceover service

One-time **$29 USD** packs include **50,000 characters** (roughly an hour; speaking rate varies). Packs do not renew automatically. New generated text consumes characters; Glint reuses existing clips when their text and voice have not changed. A personal ElevenLabs API key takes precedence and never consumes purchased characters.

This service is separate from `site/`, which is a static GitHub Pages export. It stores purchase balances in SQLite, verifies Stripe payments, and proxies only allowlisted ElevenLabs voices. The owner's ElevenLabs and Stripe keys stay in the server environment. No private cloned voices are exposed unless explicitly allowlisted.

## Run and deploy

Requires Node 24+ and pnpm. From this directory:

```sh
pnpm install --frozen-lockfile
pnpm typecheck
pnpm lint
pnpm test
# Supply the values in .env.example through your host's secret manager.
node --env-file=.env src/server.ts
```

Use the included Dockerfile on a host with **persistent storage** mounted at `/data`. Run **one replica**; the SQLite database and its WAL must survive restarts and redeploys. Back up the database using SQLite's backup API or a consistent volume snapshot. Do not deploy this to an ephemeral/serverless filesystem. Configure HTTPS, an edge rate limit (including a low limit on `/v1/checkout`), request-size limits and monitoring. The built-in peer-IP limit deliberately does not trust forwarded headers; configure the proxy to preserve the originating connection or supply separate edge limits so all customers do not share one proxy limit.

Set:

- `PUBLIC_URL`: HTTPS origin of this service, without a path.
- `STRIPE_SECRET_KEY`: this product's Stripe secret, test mode first.
- `STRIPE_WEBHOOK_SECRET`: signing secret for this service's webhook.
- `ELEVENLABS_API_KEY`: the owner's service key; never put it in the app or site.
- `ELEVENLABS_VOICE_IDS`: comma-separated IDs of voices intended for customers. Verify the configured voices are available on the owner's account.
- `DATABASE_PATH`: persistent path, `/data/voice.sqlite` in the container.

Register a Stripe **snapshot** webhook at `/v1/webhook` for `checkout.session.completed`, `checkout.session.async_payment_succeeded`, `charge.refunded`, and `charge.dispute.created`. Checkout uses a fixed server-side amount and `mode=payment`; there is no subscription or client-supplied price. Any refund or dispute revokes that pack's full allowance. Dispute reversals and uncertain provider requests require manual support review.

Build the app with the public URL:

```sh
GLINT_VOICE_SERVICE_URL=https://your-service.example.com scripts/build-app.sh
```

The build embeds **only this public origin** in Info.plist. The bundled CLI reads it too; standalone development executables can use the environment variable. Without a configured URL the app explains that purchases are unavailable and leaves personal-key generation working. No checkout can charge a customer in that unconfigured state.

## Purchase and recovery

The app generates a random bearer recovery code and saves it through the existing credential store (Keychain in signed builds). The server stores its SHA-256 hash, never the original code. Stripe metadata contains the hash and the pack version. Opening checkout or visiting its success page does not grant access: the webhook retrieves the session and payment from Stripe, verifies the paid status, currency, amount and pack, then credits it transactionally once. “Check Purchase” reconciles the latest checkout through the same verifier if webhook delivery is delayed.

The purchase dialog lets customers copy their recovery code and restore it on another Mac. This is deliberately independent of Claude/ChatGPT sign-in. The code grants access to the balance: keep it private. If a customer loses both the code and the local credential store, receipt verification and a manually issued replacement account are a support procedure; there is no automatic email recovery flow.

## Usage and failure behavior

- Balance is enforced on the server for every synthesis request, including CLI/MCP callers. Client UI state never grants entitlement.
- Text is limited to 5,000 characters per scene. Billing counts Unicode code points, including spaces and punctuation. Context text is bounded separately; the server fixes the generation model to `eleven_multilingual_v2` and format to MP3 with timestamps.
- A transaction reserves characters before calling ElevenLabs. One in-flight generation per balance prevents concurrent requests from overdrawing it. An idempotency key prevents a repeated HTTP request from charging or generating again.
- Completed audio responses are cached for replay for 24 hours, then removed on subsequent generation completion. Request IDs, hashes and usage records remain; narration text is not stored separately. ElevenLabs applies its own retention policy.
- Explicit provider rejection returns the reserved characters once. Network timeouts and malformed success responses retain the reservation because ElevenLabs may already have generated billable audio. Support must verify the provider request before refunding it. Do not blindly retry these requests.
- Refunds/disputes can make a balance negative if characters were already spent. A future pack first covers this usage. The UI displays zero until the balance becomes positive.

## Release verification still required

Local tests use a real SQLite database and mocked external HTTP responses, plus Stripe's signature implementation. They cover forged/duplicate payment events, ownership, amount checks, refunds, restart persistence, exhaustion, concurrent reservation, replay, Unicode counting and provider failures. They do **not** establish live payment or provider operation.

Before enabling purchases in a distributed build: deploy with persistent storage and real credentials, complete a Stripe test checkout, confirm the signed webhook grants exactly 50,000 characters, restore on another installation, synthesize a short real clip, verify the debit, then refund the test payment and verify access is revoked. Configure customer support and applicable checkout/tax settings for the business before switching to live Stripe keys.

Provider references: [Stripe fulfillment](https://docs.stripe.com/checkout/fulfillment), [webhook signatures](https://docs.stripe.com/webhooks), [ElevenLabs timestamped speech](https://elevenlabs.io/docs/api-reference/text-to-speech/convert-with-timestamps).

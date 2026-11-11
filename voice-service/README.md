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

The packaged app defaults to the deployed Glint service. To override the public URL for a separate environment:

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

## Deployment and verification — November 10, 2026

Production is deployed at `https://glint-voice-production.up.railway.app` in Railway's `glint-voice` project, `production` environment, and `glint-voice` service. It uses one replica, a 1-vCPU/500-MB limit, a 5-GB persistent volume mounted at `/data`, and `/v1/offer` as its deployment health check. The production database is `/data/voice.sqlite`.

Payments go to the **Andrew Sepeczi** Stripe account. The dedicated `Glint Voiceover production` restricted key has Checkout Sessions write access and Payment Intents / Charges and Refunds read access. The active production webhook receives the four events listed above. Both Stripe secrets and the owner's ElevenLabs key are stored only as Railway service variables. The allowlist currently contains the verified voice `21m00Tcm4TlvDq8ikWAM`.

The source was deployed from this directory using the Railway CLI; automatic GitHub deployment is not configured. To deploy an updated service:

```sh
pnpm lint && pnpm typecheck && pnpm test
railway up . --path-as-root \
  --project 243dccbf-4485-423f-b1a4-da642b999415 \
  --environment ff852d5b-4d89-4569-b972-c620d6aee33f \
  --service 2d77fe67-13e5-47aa-80aa-68811b8dfd31
```

Verified against the deployed service:

- Stripe sandbox checkout charged the test card $29 and its signed webhook granted exactly 50,000 characters.
- A real ElevenLabs generation consumed 75 characters and returned a valid 4.49-second MP3 with alignment data; 49,925 characters remained.
- Balance and cached audio survived redeployment. Replaying the same generation returned identical audio without another debit.
- The native Mac recovery dialog restored the purchase and displayed 49,925 characters without a personal ElevenLabs key.
- Refunding the sandbox payment revoked its allowance; generation then returned HTTP 402.
- Production uses a separate database from `/data/voice-test.sqlite`; the test recovery code has no production purchase or balance. The temporary test webhook is disabled.
- Live checkout created the correct $29 USD one-time payment using the restricted key. This verification checkout was expired without payment; no real charge was made.

The local signed app in `build/Glint.app` includes the public service URL. This setup does not publish a new downloadable app release. Railway's current plan does not allow automated volume backups; enable supported backups before relying on the service for irreplaceable customer balances. A volume preserves data across deployments but is not an independent backup.

## Automated coverage

Local tests use a real SQLite database and mocked external HTTP responses, plus Stripe's signature implementation. They cover forged/duplicate payment events, ownership, amount checks, refunds, restart persistence, exhaustion, concurrent reservation, replay, Unicode counting and provider failures. They do **not** establish live payment or provider operation.

The 17 backend tests and six packaging tests pass. Continue to verify checkout, recovery, generation, and refunds when changing payment or usage handling. Configure customer support and applicable checkout/tax settings for the business before a public launch.

Provider references: [Stripe fulfillment](https://docs.stripe.com/checkout/fulfillment), [webhook signatures](https://docs.stripe.com/webhooks), [ElevenLabs timestamped speech](https://elevenlabs.io/docs/api-reference/text-to-speech/convert-with-timestamps).

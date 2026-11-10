import { createHash } from "node:crypto";
import { z } from "zod";
import { OFFER, ServiceError, Store } from "./store.ts";
import type { Payments } from "./payments.ts";

const text = z.string().min(1).max(5_000).refine(v => v.trim().length > 0);
const synthesis = z.object({
  voiceID: z.string().regex(/^[a-zA-Z0-9]{10,80}$/), text,
  previous_text: z.string().max(5_000).optional(), next_text: z.string().max(5_000).optional(),
  voice_settings: z.object({
    stability: z.number().min(0).max(1).optional(), similarity_boost: z.number().min(0).max(1).optional(),
    style: z.number().min(0).max(1).optional(), speed: z.number().min(0.7).max(1.2).optional(),
    use_speaker_boost: z.boolean().optional(),
  }).optional(),
});
export const hash = (value: string) => createHash("sha256").update(value).digest("hex");
export function accountFromHeader(header: string | null): string {
  const token = header?.match(/^Bearer (glint_[a-f0-9]{64})$/)?.[1];
  if (!token) throw new ServiceError(401, "Restore your voiceover purchase or start a new checkout.");
  return hash(token);
}

type Options = {
  store: Store; payments: Pick<Payments, "checkout" | "refresh" | "webhook">;
  elevenlabsKey: string; voiceIDs: string[]; fetch?: typeof fetch;
};

export function createService(options: Options) {
  const { store, payments, elevenlabsKey, voiceIDs } = options;
  const fetchUpstream = options.fetch ?? fetch;
  let voiceCache: { expires: number; voices: unknown[] } | undefined;

  async function provider(path: string, body?: unknown) {
    return fetchUpstream(`https://api.elevenlabs.io${path}`, {
      method: body ? "POST" : "GET", signal: AbortSignal.timeout(240_000),
      headers: { "xi-api-key": elevenlabsKey, "Content-Type": "application/json" },
      ...(body ? { body: JSON.stringify(body) } : {}),
    });
  }

  return async function handle(request: Request): Promise<Response> {
    try {
      const { pathname } = new URL(request.url);
      if (request.method === "GET" && (pathname === "/complete" || pathname === "/cancel")) {
        const complete = pathname === "/complete";
        return new Response(`<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Glint Voiceover</title><style>body{font:16px system-ui;margin:15vh auto;padding:24px;max-width:440px;background:#111315;color:#eee}h1{font-size:28px}p{color:#aaa;line-height:1.6}</style><h1>${complete ? "You’re all set." : "Checkout canceled."}</h1><p>${complete ? "Return to Glint and choose Check Purchase to load your voiceover characters." : "You haven’t been charged. Return to Glint whenever you’re ready."}</p></html>`, { headers: { "Content-Type": "text/html; charset=utf-8", "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'", "Cache-Control": "no-store" } });
      }
      if (request.method === "POST" && pathname === "/v1/webhook") {
        await payments.webhook(Buffer.from(await request.arrayBuffer()), request.headers.get("stripe-signature") ?? "");
        return json({ received: true });
      }
      if (request.method === "GET" && pathname === "/v1/offer") return json(OFFER);
      const account = accountFromHeader(request.headers.get("authorization"));
      if (request.method === "POST" && pathname === "/v1/checkout") return json({ url: await payments.checkout(account) });
      if (request.method === "GET" && pathname === "/v1/access") {
        // Normal balance reads avoid Stripe calls. Reconciliation is explicit on return from checkout.
        if (new URL(request.url).searchParams.get("refresh") === "true") await payments.refresh(account);
        return json({ purchased: store.purchased(account), remaining: Math.max(0, store.balance(account)) });
      }
      if (request.method === "GET" && pathname === "/v1/voices") {
        if (store.balance(account) <= 0) throw new ServiceError(402, "Add voiceover characters to choose a voice.");
        if (!voiceCache || voiceCache.expires < Date.now()) {
          const voices = await Promise.all(voiceIDs.map(async id => {
            const response = await provider(`/v1/voices/${id}`);
            if (!response.ok) throw new ServiceError(502, "Voices are temporarily unavailable. Please try again.");
            const voice = z.object({ voice_id: z.string(), name: z.string(), labels: z.record(z.string(), z.string()).optional(), preview_url: z.string().nullable().optional() }).parse(await response.json());
            return voice;
          }));
          voiceCache = { expires: Date.now() + 3_600_000, voices };
        }
        return json({ voices: voiceCache.voices });
      }
      if (request.method === "POST" && pathname === "/v1/synthesize") {
        const body = synthesis.parse(await request.json());
        if (!voiceIDs.includes(body.voiceID)) throw new ServiceError(400, "Choose one of the included voices.");
        const id = request.headers.get("idempotency-key");
        if (!id || !/^[a-zA-Z0-9-]{16,80}$/.test(id)) throw new ServiceError(400, "Missing generation request ID.");
        const cost = Array.from(body.text).length;
        const cached = store.reserve(account, id, hash(JSON.stringify(body)), cost);
        if (cached) return new Response(cached, { headers: jsonHeaders });
        let response: Response;
        try {
          const { voiceID, ...payload } = body;
          response = await provider(`/v1/text-to-speech/${voiceID}/with-timestamps?output_format=mp3_44100_128`, {
            ...payload, model_id: "eleven_multilingual_v2",
          });
        } catch {
          // Delivery is uncertain on timeouts. Do not refund and silently repeat a potentially billable request.
          throw new ServiceError(504, "The voice provider did not confirm this generation. Characters are reserved; contact support before regenerating.");
        }
        if (!response.ok) {
          store.refundGeneration(account, id);
          throw new ServiceError(502, "Voice generation failed. Your characters were returned; please try again.");
        }
        const result: unknown = await response.json();
        if (!result || typeof result !== "object" || !("audio_base64" in result) || typeof result.audio_base64 !== "string" || !result.audio_base64.length) {
          throw new ServiceError(502, "The voice provider returned an incomplete generation. Contact support before regenerating.");
        }
        const serialized = JSON.stringify(result);
        store.complete(account, id, serialized);
        return new Response(serialized, { headers: jsonHeaders });
      }
      throw new ServiceError(404, "Not found.");
    } catch (error) {
      if (error instanceof ServiceError) return json({ error: error.message }, error.status);
      if (error instanceof z.ZodError || error instanceof SyntaxError) return json({ error: "Invalid request. Check the text and voice settings." }, 400);
      // Never return provider errors, API keys, payment data or submitted narration to the client/log.
      return json({ error: "Voiceover service is temporarily unavailable. Please try again." }, 503);
    }
  };
}

const jsonHeaders = { "Content-Type": "application/json", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" };
function json(body: unknown, status = 200) { return new Response(JSON.stringify(body), { status, headers: jsonHeaders }); }

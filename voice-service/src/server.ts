import { createServer } from "node:http";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import Stripe from "stripe";
import { Store } from "./store.ts";
import { Payments } from "./payments.ts";
import { createService } from "./service.ts";

function required(name: string): string {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`Missing ${name}`);
  return value;
}
const origin = new URL(required("PUBLIC_URL"));
if (origin.protocol !== "https:" && !["localhost", "127.0.0.1"].includes(origin.hostname)) throw new Error("PUBLIC_URL must use HTTPS");
const path = process.env.DATABASE_PATH ?? "data/voice.sqlite";
mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
const store = new Store(path);
const stripe = new Stripe(required("STRIPE_SECRET_KEY"), { maxNetworkRetries: 2, timeout: 20_000 });
const voiceIDs = required("ELEVENLABS_VOICE_IDS").split(",").map(v => v.trim());
if (!voiceIDs.length || voiceIDs.some(v => !/^[a-zA-Z0-9]{10,80}$/.test(v))) throw new Error("Invalid ELEVENLABS_VOICE_IDS");
const handle = createService({ store, payments: new Payments(stripe, store, origin.origin, required("STRIPE_WEBHOOK_SECRET")),
  elevenlabsKey: required("ELEVENLABS_API_KEY"), voiceIDs });
const limits = new Map<string, { count: number; until: number }>();
const server = createServer(async (incoming, outgoing) => {
  try {
    // Use the socket peer, never untrusted forwarded headers. A reverse proxy also needs an edge rate limit.
    const ip = incoming.socket.remoteAddress ?? "unknown";
    const now = Date.now();
    for (const [key, value] of limits) if (value.until < now) limits.delete(key);
    const limit = limits.get(ip) ?? { count: 0, until: now + 60_000 };
    limits.set(ip, limit);
    if (++limit.count > 120) { outgoing.writeHead(429, { "Retry-After": "60" }).end(); return; }
    const chunks: Buffer[] = [];
    let size = 0;
    for await (const chunk of incoming) {
      size += chunk.length;
      if (size > 100_000) { outgoing.writeHead(413).end(); return; }
      chunks.push(Buffer.from(chunk));
    }
    const headers = new Headers();
    for (const [key, value] of Object.entries(incoming.headers)) if (value) headers.set(key, Array.isArray(value) ? value.join(", ") : value);
    const request = new Request(new URL(incoming.url ?? "/", origin), { method: incoming.method, headers,
      ...(!["GET", "HEAD"].includes(incoming.method ?? "GET") ? { body: Buffer.concat(chunks) } : {}) });
    const response = await handle(request);
    outgoing.writeHead(response.status, Object.fromEntries(response.headers));
    outgoing.end(Buffer.from(await response.arrayBuffer()));
  } catch { outgoing.writeHead(500).end(); }
});
server.requestTimeout = 30_000;
server.headersTimeout = 15_000;
server.listen(Number(process.env.PORT ?? 8787), "0.0.0.0", () => console.log("Glint voice service listening"));

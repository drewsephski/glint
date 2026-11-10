import { DatabaseSync } from "node:sqlite";

export const OFFER = { priceCents: 2900, currency: "usd", characters: 50_000 } as const;

export class ServiceError extends Error {
  status: number;
  constructor(status: number, message: string) { super(message); this.status = status; }
}

export class Store {
  db: DatabaseSync;
  constructor(path: string) {
    this.db = new DatabaseSync(path);
    this.db.exec(`
      PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;
      CREATE TABLE IF NOT EXISTS accounts (id TEXT PRIMARY KEY, balance INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS checkouts (id TEXT PRIMARY KEY, account TEXT NOT NULL, created INTEGER NOT NULL);
      CREATE INDEX IF NOT EXISTS checkout_account ON checkouts(account);
      CREATE TABLE IF NOT EXISTS purchases (id TEXT PRIMARY KEY, account TEXT NOT NULL, payment TEXT UNIQUE NOT NULL);
      CREATE TABLE IF NOT EXISTS revoked_payments (payment TEXT PRIMARY KEY);
      CREATE TABLE IF NOT EXISTS generations (
        account TEXT NOT NULL, id TEXT NOT NULL, fingerprint TEXT NOT NULL, cost INTEGER NOT NULL,
        status TEXT NOT NULL, response TEXT, created INTEGER NOT NULL,
        PRIMARY KEY(account, id)
      );
    `);
  }

  transaction<T>(work: () => T): T {
    this.db.exec("BEGIN IMMEDIATE");
    try { const result = work(); this.db.exec("COMMIT"); return result; }
    catch (error) { this.db.exec("ROLLBACK"); throw error; }
  }

  balance(account: string): number {
    return Number(this.db.prepare("SELECT balance FROM accounts WHERE id=?").get(account)?.balance ?? 0);
  }

  purchased(account: string): boolean {
    return !!this.db.prepare("SELECT 1 FROM purchases WHERE account=? LIMIT 1").get(account);
  }

  checkout(account: string): string | undefined {
    return this.db.prepare("SELECT id FROM checkouts WHERE account=? ORDER BY created DESC LIMIT 1").get(account)?.id as string | undefined;
  }

  saveCheckout(id: string, account: string) {
    this.db.prepare("INSERT OR IGNORE INTO checkouts VALUES (?, ?, ?)").run(id, account, Date.now());
  }

  credit(id: string, account: string, payment: string) {
    this.transaction(() => {
      if (this.db.prepare("SELECT 1 FROM revoked_payments WHERE payment=?").get(payment)) return;
      const inserted = this.db.prepare("INSERT OR IGNORE INTO purchases VALUES (?, ?, ?)").run(id, account, payment);
      if (!inserted.changes) return;
      this.db.prepare(`INSERT INTO accounts VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET balance=balance+excluded.balance`)
        .run(account, OFFER.characters);
    });
  }

  revoke(payment: string) {
    this.transaction(() => {
      if (!this.db.prepare("INSERT OR IGNORE INTO revoked_payments VALUES (?)").run(payment).changes) return;
      const purchase = this.db.prepare("SELECT account FROM purchases WHERE payment=?").get(payment);
      // Keep a negative balance if already-used credits were refunded; a new pack cannot erase that usage.
      if (purchase) this.db.prepare("UPDATE accounts SET balance=balance-? WHERE id=?").run(OFFER.characters, purchase.account);
    });
  }

  reserve(account: string, id: string, fingerprint: string, cost: number): string | undefined {
    return this.transaction(() => {
      const prior = this.db.prepare("SELECT * FROM generations WHERE account=? AND id=?").get(account, id);
      if (prior) {
        if (prior.fingerprint !== fingerprint) throw new ServiceError(409, "This request ID was already used for different text.");
        if (prior.status === "complete" && typeof prior.response === "string") return prior.response;
        throw new ServiceError(409, "This generation was already submitted. Check your balance before trying again.");
      }
      if (this.db.prepare("SELECT 1 FROM generations WHERE account=? AND status='pending' AND created>? LIMIT 1")
        .get(account, Date.now() - 300_000)) throw new ServiceError(409, "A voiceover is already generating. Please wait.");
      const debit = this.db.prepare("UPDATE accounts SET balance=balance-? WHERE id=? AND balance>=?").run(cost, account, cost);
      if (!debit.changes) throw new ServiceError(402, "Not enough voiceover characters. Add a pack or use your own ElevenLabs key.");
      this.db.prepare("INSERT INTO generations VALUES (?, ?, ?, ?, 'pending', NULL, ?)").run(account, id, fingerprint, cost, Date.now());
      return undefined;
    });
  }

  complete(account: string, id: string, response: string) {
    this.db.prepare("UPDATE generations SET status='complete', response=? WHERE account=? AND id=? AND status='pending'")
      .run(response, account, id);
    // Retain idempotency records, but discard cached audio after 24 hours.
    this.db.prepare("UPDATE generations SET response=NULL WHERE created<? AND response IS NOT NULL").run(Date.now() - 86_400_000);
  }

  refundGeneration(account: string, id: string) {
    this.transaction(() => {
      const generation = this.db.prepare("SELECT cost FROM generations WHERE account=? AND id=? AND status='pending'").get(account, id);
      if (!generation) return;
      this.db.prepare("UPDATE generations SET status='failed' WHERE account=? AND id=?").run(account, id);
      this.db.prepare("UPDATE accounts SET balance=balance+? WHERE id=?").run(generation.cost, account);
    });
  }
}

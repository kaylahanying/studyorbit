import { DatabaseSync } from 'node:sqlite';
import { chmodSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { createHmac, randomBytes, timingSafeEqual } from 'node:crypto';
import { HttpError } from './schema.mjs';

const dayKey = now => new Date(now).toISOString().slice(0, 10);
const opaque = () => randomBytes(32).toString('base64url');
const denied = () => { throw new HttpError(429, 'limit', 'The hosted study service has reached a usage limit. Try again later, or use manual tasks.'); };
export const safeEqual = (a, b) => {
  const x = Buffer.from(a);
  const y = Buffer.from(b);
  return x.length === y.length && timingSafeEqual(x, y);
};

export class Store {
  constructor(config) {
    this.config = config;
    mkdirSync(dirname(config.database), { recursive: true, mode: 0o700 });
    this.db = new DatabaseSync(config.database);
    chmodSync(config.database, 0o600);
    this.db.exec(`PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;
      CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS sessions (hash TEXT PRIMARY KEY, expires INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS usage (day TEXT NOT NULL, scope TEXT NOT NULL, count INTEGER NOT NULL, PRIMARY KEY(day, scope));
      CREATE TABLE IF NOT EXISTS active (id TEXT PRIMARY KEY, session TEXT NOT NULL, expires INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS limits (window TEXT NOT NULL, scope TEXT NOT NULL, count INTEGER NOT NULL, PRIMARY KEY(window, scope));`);
    if (config.secret) this.secret = config.secret;
    else {
      this.db.prepare('INSERT OR IGNORE INTO meta VALUES (?, ?)').run('development-secret', opaque());
      this.secret = this.db.prepare('SELECT value FROM meta WHERE key = ?').get('development-secret').value;
    }
  }
  hash(value) { return createHmac('sha256', this.secret).update(value).digest('hex'); }
  csrf(token) { return this.hash(`csrf:${token}`); }
  transaction(fn) {
    this.db.exec('BEGIN IMMEDIATE');
    try {
      const value = fn();
      this.db.exec('COMMIT');
      return value;
    } catch (error) {
      this.db.exec('ROLLBACK');
      throw error;
    }
  }
  cleanup(now) {
    this.db.prepare('DELETE FROM sessions WHERE expires <= ?').run(now);
    this.db.prepare('DELETE FROM active WHERE expires <= ?').run(now);
    this.db.prepare('DELETE FROM usage WHERE day < ?').run(dayKey(now - 8 * 86400000));
    this.db.prepare('DELETE FROM limits WHERE window < ?').run(new Date(now - 2 * 86400000).toISOString().slice(0, 13));
  }
  authenticate(cookie, now = Date.now()) {
    if (typeof cookie !== 'string' || cookie.length > 4096) return null;
    const matches = cookie.split(';').map(item => item.trim()).filter(item => item.startsWith('studyorbit_session='));
    if (matches.length !== 1) return null;
    const token = matches[0].slice('studyorbit_session='.length);
    if (!/^[A-Za-z0-9_-]{43}$/u.test(token)) return null;
    const hash = this.hash(token);
    const record = this.db.prepare('SELECT expires FROM sessions WHERE hash = ? AND expires > ?').get(hash, now);
    return record ? { hash, token } : null;
  }
  bump(window, scope, limit) {
    const current = this.db.prepare('SELECT count FROM limits WHERE window = ? AND scope = ?').get(window, scope)?.count ?? 0;
    if (current >= limit) denied();
    this.db.prepare('INSERT INTO limits VALUES (?, ?, 1) ON CONFLICT(window, scope) DO UPDATE SET count=count+1').run(window, scope);
  }
  loginAttempt(address, now = Date.now()) {
    this.transaction(() => {
      this.cleanup(now);
      const hour = new Date(now).toISOString().slice(0, 13);
      this.bump(hour, `login:${this.hash(address)}`, this.config.loginHourlyLimit);
      this.bump(hour, 'all-login', this.config.sessionDailyLimit * 2);
    });
  }
  issue(address, now = Date.now()) {
    return this.transaction(() => {
      this.cleanup(now);
      const hour = new Date(now).toISOString().slice(0, 13);
      this.bump(hour, `issue:${this.hash(address)}`, this.config.loginHourlyLimit);
      this.bump(dayKey(now), 'all-issue', this.config.sessionDailyLimit);
      const token = opaque();
      const hash = this.hash(token);
      this.db.prepare('INSERT INTO sessions VALUES (?, ?)').run(hash, now + 7 * 86400000);
      return { token, hash };
    });
  }
  revoke(session) {
    this.db.prepare('DELETE FROM sessions WHERE hash = ?').run(session.hash);
  }
  remaining(session, now = Date.now()) {
    if (!session) return 0;
    const day = dayKey(now);
    const sessionUsed = this.db.prepare('SELECT count FROM usage WHERE day = ? AND scope = ?').get(day, session.hash)?.count ?? 0;
    const globalUsed = this.db.prepare('SELECT count FROM usage WHERE day = ? AND scope = ?').get(day, 'global')?.count ?? 0;
    return Math.max(0, Math.min(this.config.dailyLimit - sessionUsed, this.config.globalDailyLimit - globalUsed));
  }
  reserve(session, now = Date.now()) {
    return this.transaction(() => {
      this.cleanup(now);
      if (!this.db.prepare('SELECT hash FROM sessions WHERE hash = ? AND expires > ?').get(session.hash, now)) {
        throw new HttpError(401, 'session', 'Enter your pilot invitation to continue.');
      }
      if (this.remaining(session, now) <= 0) denied();
      const total = this.db.prepare('SELECT count(*) AS n FROM active').get().n;
      const own = this.db.prepare('SELECT count(*) AS n FROM active WHERE session = ?').get(session.hash).n;
      if (total >= this.config.concurrency || own >= 1) {
        throw new HttpError(429, 'busy', 'A study request is already running. Please wait before trying again.');
      }
      const id = opaque();
      // Charged at dispatch, including failures: restarts/errors cannot refund spend.
      // Leases outlive the 45-second provider timeout even across server restarts.
      this.db.prepare('INSERT INTO active VALUES (?, ?, ?)').run(id, session.hash, now + 60000);
      for (const scope of [session.hash, 'global']) {
        this.db.prepare('INSERT INTO usage VALUES (?, ?, 1) ON CONFLICT(day, scope) DO UPDATE SET count=count+1').run(dayKey(now), scope);
      }
      return id;
    });
  }
  release(id) { this.db.prepare('DELETE FROM active WHERE id = ?').run(id); }
  close() { this.db.close(); }
}

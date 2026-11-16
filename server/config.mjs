import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const mobileRoot = fileURLToPath(new URL('../', import.meta.url));
export const isLoopback = host => ['127.0.0.1', '::1', '[::1]', 'localhost'].includes(host);
const first = (...values) => values.find(value => typeof value === 'string' && value.trim())?.trim() ?? '';
const number = (value, fallback, min, max) => {
  const result = value === undefined ? fallback : Number(value);
  if (!Number.isSafeInteger(result) || result < min || result > max) throw new Error('Invalid StudyOrbit numeric configuration.');
  return result;
};

export function loadConfig(env = process.env) {
  const production = env.NODE_ENV === 'production' || env.STUDYORBIT_MODE === 'production';
  const host = env.STUDYORBIT_HOST || '127.0.0.1';
  const port = number(env.STUDYORBIT_PORT, 8787, 1, 65535);
  if (!isLoopback(host)) throw new Error('Bind loopback only; production uses a local HTTPS reverse proxy.');
  const origin = new URL(env.STUDYORBIT_ORIGIN || `http://${host.includes(':') ? `[${host}]` : host}:${port}`);
  if (origin.username || origin.password || origin.pathname !== '/' || origin.search || origin.hash ||
      !(origin.protocol === 'https:' || (!production && origin.protocol === 'http:' && isLoopback(origin.hostname)))) {
    throw new Error('StudyOrbit requires an HTTPS public origin, or a loopback development origin.');
  }
  const secret = env.STUDYORBIT_SESSION_SECRET || '';
  const invite = env.STUDYORBIT_INVITE_CODE || '';
  if (secret && (Array.from(secret).length < 32 || Buffer.byteLength(secret) > 4096)) throw new Error('Session secret must have at least 32 characters and at most 4096 bytes.');
  if (invite && (invite.length < 12 || invite.length > 256 || /[\r\n]/u.test(invite))) throw new Error('Invite code must have 12–256 characters.');
  if (production && (!secret || !invite)) throw new Error('Production requires a session secret and invite code.');
  const key = first(env.STUDYORBIT_API_KEY, env.LLM_API_KEY, env.ZHIPU_API_KEY, env.OPENCODE_API_KEY, env.MINIMAX_API_KEY);
  const defaultBase = env.ZHIPU_API_KEY ? 'https://open.bigmodel.cn/api/paas/v4' :
    env.OPENCODE_API_KEY ? 'https://opencode.ai/zen/v1' : env.MINIMAX_API_KEY ? 'https://api.minimax.io/v1' : '';
  const base = first(env.STUDYORBIT_BASE_URL, env.LLM_BASE_URL, env.MINIMAX_BASE_URL, defaultBase);
  const model = first(env.STUDYORBIT_MODEL, env.LLM_MODEL, env.MINIMAX_MODEL);
  if (key.length > 4096 || /[\r\n]/u.test(key) || model.length > 200 || /[\r\n]/u.test(model)) throw new Error('Invalid provider configuration.');
  let endpoint;
  if (base) {
    endpoint = new URL(base);
    if (endpoint.username || endpoint.password || endpoint.search || endpoint.hash ||
        !(endpoint.protocol === 'https:' || (!production && endpoint.protocol === 'http:' && isLoopback(endpoint.hostname)))) {
      throw new Error('Provider URL must use HTTPS without credentials, query, or fragment.');
    }
    endpoint.pathname = endpoint.pathname.replace(/\/+$/u, '');
    if (!endpoint.pathname.endsWith('/chat/completions')) endpoint.pathname += '/chat/completions';
  }
  if ([key, secret, invite].some(value => value &&
      (model.includes(value) || endpoint?.hostname.includes(value)))) {
    throw new Error('Public provider metadata must not contain credentials.');
  }
  const configured = Boolean(key && endpoint && model);
  if (production && !configured) throw new Error('Production requires a provider key, base URL, and model.');
  return Object.freeze({
    production, host, port, origin: origin.origin, secret, invite, key, model,
    endpoint: endpoint?.href, provider: endpoint?.hostname ?? '', configured,
    autoSession: !production && !invite && isLoopback(host) && isLoopback(origin.hostname),
    assets: resolve(env.STUDYORBIT_ASSETS || resolve(mobileRoot, 'build/web')),
    database: resolve(env.STUDYORBIT_DATABASE || resolve(mobileRoot, 'server/.data/studyorbit.sqlite')),
    dailyLimit: number(env.STUDYORBIT_DAILY_LIMIT, 20, 1, 1000),
    globalDailyLimit: number(env.STUDYORBIT_GLOBAL_DAILY_LIMIT, 200, 1, 100000),
    concurrency: number(env.STUDYORBIT_CONCURRENCY, 3, 1, 100),
    sessionDailyLimit: number(env.STUDYORBIT_SESSION_DAILY_LIMIT, 100, 1, 10000),
    loginHourlyLimit: number(env.STUDYORBIT_LOGIN_HOURLY_LIMIT, 10, 1, 100),
  });
}

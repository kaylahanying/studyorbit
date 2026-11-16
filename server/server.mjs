import http from 'node:http';
import { createReadStream } from 'node:fs';
import { realpath, stat } from 'node:fs/promises';
import { extname, resolve, sep } from 'node:path';
import { Store, safeEqual } from './store.mjs';
import { HttpError, parseJson, validateAiRequest } from './schema.mjs';
import { callProvider } from './provider.mjs';

const MAX_BODY = 384 * 1024;
const mime = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8', '.json': 'application/json; charset=utf-8',
  '.wasm': 'application/wasm', '.css': 'text/css; charset=utf-8', '.png': 'image/png',
  '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.webp': 'image/webp', '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon', '.woff': 'font/woff', '.woff2': 'font/woff2', '.ttf': 'font/ttf',
  '.otf': 'font/otf', '.bin': 'application/octet-stream', '.frag': 'application/octet-stream',
};
const fail = (status, code, message) => { throw new HttpError(status, code, message); };
const cookie = (config, token = '') => `studyorbit_session=${token}; Path=/; HttpOnly; SameSite=Strict; Max-Age=${token ? 604800 : 0}${config.production ? '; Secure' : ''}`;

function securityHeaders(response, production) {
  response.setHeader('Cache-Control', 'no-store');
  response.setHeader('X-Content-Type-Options', 'nosniff');
  response.setHeader('Referrer-Policy', 'no-referrer');
  response.setHeader('X-Frame-Options', 'DENY');
  response.setHeader('Cross-Origin-Opener-Policy', 'same-origin');
  response.setHeader('Cross-Origin-Resource-Policy', 'same-origin');
  response.setHeader('Permissions-Policy', 'camera=(self), microphone=(self), geolocation=(), payment=(), usb=()');
  response.setHeader('Content-Security-Policy', "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; worker-src 'self' blob:; connect-src 'self' blob:; img-src 'self' data: blob:; font-src 'self' data:; style-src 'self' 'unsafe-inline'; media-src 'self' blob:; object-src 'none'; base-uri 'self'; frame-ancestors 'none'; form-action 'self'");
  if (production) response.setHeader('Strict-Transport-Security', 'max-age=31536000');
}
function json(response, status, body) {
  if (response.destroyed || response.writableEnded) return;
  response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
  response.end(JSON.stringify(body));
}
async function readJson(request, max = MAX_BODY) {
  if (!/^application\/json(?:\s*;\s*charset=utf-8)?$/iu.test(request.headers['content-type'] || '') ||
      (request.headers['content-encoding'] && request.headers['content-encoding'] !== 'identity')) {
    fail(415, 'media', 'Send UTF-8 JSON only. Images, audio, uploads, and compressed requests are not accepted.');
  }
  const declared = request.headers['content-length'];
  if (declared !== undefined && (!/^\d+$/u.test(declared) || Number(declared) > max)) fail(413, 'input', 'The study context is too large.');
  const chunks = [];
  let length = 0;
  for await (const chunk of request.iterator({ destroyOnReturn: false })) {
    length += chunk.length;
    if (length > max) fail(413, 'input', 'The study context is too large.');
    chunks.push(chunk);
  }
  let text;
  try { text = new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks, length)); }
  catch { fail(400, 'input', 'Send valid UTF-8 JSON.'); }
  return parseJson(text);
}
function assertOrigin(request, config, write = false) {
  if (request.headers.host !== new URL(config.origin).host ||
      (request.headers.origin !== undefined && request.headers.origin !== config.origin) ||
      (write && request.headers.origin !== config.origin) ||
      request.headers['sec-fetch-site'] === 'cross-site') {
    fail(403, 'origin', 'Use the study app from its configured origin.');
  }
}
function requireSession(session) {
  if (!session) fail(401, 'session', 'Enter your pilot invitation to continue.');
}
function requireCsrf(request, session, store) {
  requireSession(session);
  const supplied = request.headers['x-csrf-token'];
  if (typeof supplied !== 'string' || !safeEqual(supplied, store.csrf(session.token))) {
    fail(403, 'csrf', 'Refresh the study session before continuing.');
  }
}
function status(config, store, session) {
  return {
    authenticated: Boolean(session), configured: config.configured,
    requiresInvite: !config.autoSession, provider: config.provider, model: config.model,
    remaining: store.remaining(session), dailyLimit: config.dailyLimit,
    ...(session ? { csrfToken: store.csrf(session.token) } : {}),
    ...(!config.configured ? { error: 'Hosted study AI is not configured. Manual tasks remain available.' } : {}),
  };
}
async function staticFile(request, response, config, assetsRoot) {
  if (!['GET', 'HEAD'].includes(request.method)) fail(405, 'method', 'Method not allowed.');
  let path;
  try { path = decodeURIComponent(request.url.split('?')[0]); }
  catch { fail(400, 'path', 'Invalid asset path.'); }
  if (!path.startsWith('/') || path.includes('\\') || path.includes('\0') ||
      path.split('/').some(segment => segment.startsWith('.'))) fail(404, 'asset', 'Asset not found.');
  let candidate = resolve(assetsRoot, `.${path}`);
  let info;
  try {
    candidate = await realpath(candidate);
    info = await stat(candidate);
  } catch {
    if (extname(path)) fail(404, 'asset', 'Asset not found.');
    candidate = await realpath(resolve(assetsRoot, 'index.html'));
    info = await stat(candidate);
  }
  if (candidate !== assetsRoot && !candidate.startsWith(`${assetsRoot}${sep}`)) fail(404, 'asset', 'Asset not found.');
  if (info.isDirectory() && path === '/') {
    candidate = await realpath(resolve(assetsRoot, 'index.html'));
    info = await stat(candidate);
    if (!candidate.startsWith(`${assetsRoot}${sep}`)) fail(404, 'asset', 'Asset not found.');
  }
  if (!info.isFile()) fail(404, 'asset', 'Asset not found.');
  response.writeHead(200, { 'Content-Type': mime[extname(candidate)] || 'application/octet-stream', 'Content-Length': info.size });
  if (request.method === 'HEAD') response.end();
  else {
    const stream = createReadStream(candidate);
    response.on('close', () => stream.destroy());
    stream.on('error', () => response.destroy());
    stream.pipe(response);
  }
}

export async function createStudyServer(config, { fetcher } = {}) {
  const assetsRoot = await realpath(config.assets);
  const indexPath = await realpath(resolve(assetsRoot, 'index.html'));
  const index = await stat(indexPath);
  if (!index.isFile() || !indexPath.startsWith(`${assetsRoot}${sep}`)) {
    throw new Error('Build the real Flutter web app before starting the hosted server.');
  }
  const store = new Store(config);
  const controllers = new Set();
  const server = http.createServer({ maxHeaderSize: 16 * 1024 }, async (request, response) => {
    securityHeaders(response, config.production);
    let reservation;
    let controller;
    try {
      assertOrigin(request, config);
      const path = request.url.split('?')[0];
      if (path !== '/api/session' && path !== '/api/ai') {
        if (path.startsWith('/api/')) fail(404, 'route', 'Route not found.');
        await staticFile(request, response, config, assetsRoot);
        return;
      }
      if (request.url.includes('?')) fail(400, 'input', 'API query parameters are not accepted.');
      const write = !['GET', 'HEAD'].includes(request.method);
      assertOrigin(request, config, write);
      let session = store.authenticate(request.headers.cookie);
      if (path === '/api/session' && request.method === 'GET') {
        if (!session && config.autoSession) {
          session = store.issue(request.socket.remoteAddress || 'loopback');
          response.setHeader('Set-Cookie', cookie(config, session.token));
        }
        json(response, 200, status(config, store, session));
      } else if (path === '/api/session' && request.method === 'POST') {
        store.loginAttempt(request.socket.remoteAddress || 'unknown');
        const body = await readJson(request, 1024);
        if (!body || typeof body !== 'object' || Array.isArray(body) ||
            Object.keys(body).length !== 1 || typeof body.inviteCode !== 'string' || body.inviteCode.length > 256) {
          fail(400, 'input', 'Enter a valid pilot invitation.');
        }
        if (!config.autoSession && !safeEqual(body.inviteCode, config.invite)) fail(401, 'invite', 'That pilot invitation was not accepted.');
        if (!session) session = store.issue(request.socket.remoteAddress || 'unknown');
        response.setHeader('Set-Cookie', cookie(config, session.token));
        json(response, 200, status(config, store, session));
      } else if (path === '/api/session' && request.method === 'DELETE') {
        requireCsrf(request, session, store);
        store.revoke(session);
        response.setHeader('Set-Cookie', cookie(config));
        response.setHeader('Clear-Site-Data', '"cache"');
        json(response, 200, status(config, store, null));
      } else if (path === '/api/ai' && request.method === 'POST') {
        requireCsrf(request, session, store);
        if (!config.configured) fail(503, 'configuration', 'Hosted study AI is unavailable. Manual tasks remain available.');
        const { operation, input } = validateAiRequest(await readJson(request));
        reservation = store.reserve(session);
        controller = new AbortController();
        controllers.add(controller);
        response.on('close', () => { if (!response.writableEnded) controller.abort(); });
        const result = await callProvider(config, operation, input, { signal: controller.signal, fetcher });
        json(response, 200, result);
      } else fail(405, 'method', 'Method not allowed.');
    } catch (error) {
      // No exception/body/header logging: providers and inputs may contain private text.
      const known = error instanceof HttpError;
      if (!response.headersSent) json(response, known ? error.status : 500, {
        code: known ? error.code : 'server',
        error: known ? error.message : 'The study service could not complete this request.',
      });
      else response.destroy();
    } finally {
      if (reservation) store.release(reservation);
      if (controller) controllers.delete(controller);
      // Do not drain an oversized/rejected untrusted request indefinitely.
      if (!request.complete && !response.destroyed) response.once('finish', () => request.destroy());
    }
  });
  server.requestTimeout = 15000;
  server.headersTimeout = 10000;
  server.keepAliveTimeout = 5000;
  server.maxRequestsPerSocket = 100;
  server.maxConnections = 128;
  server.on('clientError', (_error, socket) => socket.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n'));
  return {
    server, store,
    async close() {
      for (const controller of controllers) controller.abort();
      await new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
      store.close();
    },
  };
}

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, rm, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import http from 'node:http';
import { loadConfig } from './config.mjs';
import { Store } from './store.mjs';
import { validateAiRequest } from './schema.mjs';
import { callProvider, MAX_RESPONSE_BYTES } from './provider.mjs';
import { createStudyServer } from './server.mjs';

const testSecret = 'test-only-session-secret-with-32-characters';
const testInvite = 'test-only-pilot-invitation';
const input = () => ({
  now: '2026-11-15T17:00:00', captureId: 'capture-test', sourceText: 'Read chapter 4 tomorrow.',
  context: {
    preferences: {
      energy: 'steady', focusMinutes: 25, breakMinutes: 5, mealStartMinute: 1080,
      mealMinutes: 30, leisureMinutes: 30, weakSubjects: [], weakTopics: [], tomorrowCourses: [], coursesDate: null,
    },
    confirmedTasks: [], recentHistory: [], recentFocusRecords: [], recentTextEvidence: [],
    contextLimits: { historyIncluded: 0, historyTotal: 0, capturesIncluded: 0, capturesTotal: 0, focusIncluded: 0, focusTotal: 0 },
  },
});
const aiBody = () => ({ operation: 'extract', input: input(), consent: true });
async function fixture(t, overrides = {}, fetcher) {
  const root = await mkdtemp(join(tmpdir(), 'studyorbit-security-'));
  const assets = join(root, 'web');
  await mkdir(assets);
  await writeFile(join(assets, 'index.html'), '<!doctype html><title>Static boundary fixture</title>');
  await writeFile(join(assets, 'test.wasm'), Buffer.from([0, 97, 115, 109]));
  const config = { ...loadConfig({
    STUDYORBIT_ASSETS: assets, STUDYORBIT_DATABASE: join(root, 'private', 'usage.sqlite'),
    STUDYORBIT_SESSION_SECRET: testSecret, STUDYORBIT_INVITE_CODE: testInvite,
    STUDYORBIT_API_KEY: 'test-only-provider-credential', STUDYORBIT_BASE_URL: 'https://provider.invalid/v1',
    STUDYORBIT_MODEL: 'test-model',
  }), ...overrides };
  const app = await createStudyServer(config, { fetcher });
  await new Promise(resolve => app.server.listen(0, '127.0.0.1', resolve));
  config.origin = `http://127.0.0.1:${app.server.address().port}`;
  t.after(async () => { await app.close(); await rm(root, { recursive: true, force: true }); });
  const request = (path, options = {}) => fetch(config.origin + path, options);
  const signIn = async () => {
    const response = await request('/api/session', {
      method: 'POST', headers: { Origin: config.origin, 'Content-Type': 'application/json' },
      body: JSON.stringify({ inviteCode: testInvite }),
    });
    assert.equal(response.status, 200);
    const cookie = response.headers.get('set-cookie').split(';')[0];
    const value = await response.json();
    return { cookie, value, headers: { Origin: config.origin, Cookie: cookie, 'Content-Type': 'application/json', 'X-CSRF-Token': value.csrfToken } };
  };
  return { root, assets, config, app, request, signIn };
}

test('production fails closed and aliases resolve without embedding credentials in status', () => {
  assert.throws(() => loadConfig({ NODE_ENV: 'production' }));
  assert.throws(() => loadConfig({ STUDYORBIT_HOST: '0.0.0.0' }));
  assert.throws(() => loadConfig({ STUDYORBIT_BASE_URL: 'https://user:password@example.org' }));
  assert.throws(() => loadConfig({ STUDYORBIT_BASE_URL: 'http://public.example.org' }));
  assert.throws(() => loadConfig({ NODE_ENV: 'production', STUDYORBIT_ORIGIN: 'http://localhost:8787', STUDYORBIT_SESSION_SECRET: testSecret, STUDYORBIT_INVITE_CODE: testInvite }));
  const config = loadConfig({ LLM_API_KEY: 'test-only', LLM_BASE_URL: 'https://provider.invalid/v4', LLM_MODEL: 'configured-model' });
  assert.equal(config.endpoint, 'https://provider.invalid/v4/chat/completions');
  assert.equal(config.configured, true);
  assert.equal(config.autoSession, true);
  assert.equal(loadConfig({ STUDYORBIT_INVITE_CODE: testInvite }).autoSession, false);
});

test('exact operation schema rejects raw proxy, credential and media fields', () => {
  assert.deepEqual(validateAiRequest(aiBody()).input, input());
  for (const extra of [{ model: 'other' }, { messages: [] }, { apiKey: 'x' }, { image: 'x' }, { system: 'x' }]) {
    assert.throws(() => validateAiRequest({ ...aiBody(), ...extra }));
    assert.throws(() => validateAiRequest({ ...aiBody(), input: { ...input(), ...extra } }));
  }
  assert.throws(() => validateAiRequest({ ...aiBody(), consent: false }));
  assert.throws(() => validateAiRequest({ ...aiBody(), operation: 'chat' }));
  assert.throws(() => validateAiRequest({ ...aiBody(), input: { ...input(), sourceText: 'data:image/png;base64,abc' } }));
  assert.throws(() => validateAiRequest({ ...aiBody(), input: { ...input(), sourceText: 'x'.repeat(100001) } }));
  assert.throws(() => validateAiRequest({ ...aiBody(), input: { ...input(), context: { ...input().context, apiKey: 'x' } } }));
});

test('daily spending persists across restart and new sessions cannot bypass global budget', async t => {
  const root = await mkdtemp(join(tmpdir(), 'studyorbit-ledger-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const config = { ...loadConfig({ STUDYORBIT_SESSION_SECRET: testSecret }), database: join(root, 'usage.sqlite'), dailyLimit: 1, globalDailyLimit: 2, loginHourlyLimit: 3 };
  const now = Date.UTC(2026, 10, 15, 12);
  let store = new Store(config);
  const first = store.issue('127.0.0.1', now);
  const reservation = store.reserve(first, now);
  store.release(reservation);
  assert.equal(store.remaining(first, now), 0);
  assert.throws(() => store.reserve(first, now), error => error.status === 429);
  for (let attempt = 0; attempt < 3; attempt++) store.loginAttempt('127.0.0.1', now);
  store.close();
  store = new Store(config);
  assert.throws(() => store.loginAttempt('127.0.0.1', now), error => error.status === 429);
  assert.equal(store.authenticate(`studyorbit_session=${first.token}`, now).hash, first.hash);
  assert.equal(store.remaining(first, now), 0);
  const second = store.issue('127.0.0.1', now);
  store.release(store.reserve(second, now));
  const third = store.issue('127.0.0.1', now);
  assert.equal(store.remaining(third, now), 0);
  assert.throws(() => store.reserve(third, now), error => error.status === 429);
  assert.equal(store.remaining(third, now + 86400000), 1);
  store.close();
  const disk = (await readFile(config.database)).toString('latin1');
  assert.ok(!disk.includes(first.token));
  assert.ok(!disk.includes('Read chapter'));
});

test('concurrent reservations survive restart and expire only after provider deadline', async t => {
  const root = await mkdtemp(join(tmpdir(), 'studyorbit-concurrency-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const config = { ...loadConfig({ STUDYORBIT_SESSION_SECRET: testSecret }), database: join(root, 'usage.sqlite'), concurrency: 1 };
  const now = Date.UTC(2026, 10, 15, 12);
  let store = new Store(config);
  const first = store.issue('127.0.0.1', now);
  const second = store.issue('127.0.0.1', now);
  const lease = store.reserve(first, now);
  assert.throws(() => store.reserve(first, now), error => error.code === 'busy');
  assert.throws(() => store.reserve(second, now), error => error.code === 'busy');
  store.close();
  store = new Store(config);
  assert.throws(() => store.reserve(second, now + 45001), error => error.code === 'busy');
  store.release(store.reserve(second, now + 60001));
  store.release(lease);
  assert.equal(store.remaining(first, now + 60001), config.dailyLimit - 1);
  store.close();
});

test('HTTP origin, CSRF, consent, type and size boundaries reject before provider dispatch', async t => {
  let dispatches = 0;
  const f = await fixture(t, {}, async () => { dispatches++; throw new Error('must not dispatch'); });
  const login = await f.signIn();
  const post = (headers, body = aiBody()) => f.request('/api/ai', { method: 'POST', headers, body: JSON.stringify(body) });
  const noOrigin = { ...login.headers }; delete noOrigin.Origin;
  assert.equal((await post(noOrigin)).status, 403);
  assert.equal((await post({ ...login.headers, Origin: 'https://attacker.invalid' })).status, 403);
  const noCsrf = { ...login.headers }; delete noCsrf['X-CSRF-Token'];
  assert.equal((await post(noCsrf)).status, 403);
  assert.equal((await post({ ...login.headers, 'X-CSRF-Token': '0'.repeat(64) })).status, 403);
  assert.equal((await post(login.headers, { ...aiBody(), consent: false })).status, 400);
  assert.equal((await post({ ...login.headers, 'Content-Type': 'image/jpeg' })).status, 415);
  assert.equal((await post(login.headers, { ...aiBody(), input: { ...input(), audio: 'raw' } })).status, 400);
  assert.equal((await post(login.headers, { ...aiBody(), input: { ...input(), sourceText: 'x'.repeat(400000) } })).status, 413);
  assert.equal((await f.request('/api/ai', { method: 'OPTIONS', headers: { Origin: 'https://attacker.invalid' } })).status, 403);
  assert.equal(dispatches, 0);
  const status = await (await f.request('/api/session', { headers: { Cookie: login.cookie } })).json();
  assert.equal(status.remaining, f.config.dailyLimit);
});

test('closed invitation sessions are private, revocable and login attempts are durable', async t => {
  const f = await fixture(t, { loginHourlyLimit: 3 });
  const anonymous = await (await f.request('/api/session')).json();
  assert.equal(anonymous.authenticated, false);
  assert.equal(anonymous.requiresInvite, true);
  assert.equal(anonymous.csrfToken, undefined);
  const wrong = () => f.request('/api/session', {
    method: 'POST', headers: { Origin: f.config.origin, 'Content-Type': 'application/json' }, body: JSON.stringify({ inviteCode: 'wrong-invitation' }),
  });
  assert.equal((await wrong()).status, 401);
  const login = await f.signIn();
  assert.ok(!JSON.stringify(login.value).includes(testSecret));
  assert.ok(!JSON.stringify(login.value).includes(testInvite));
  assert.ok(!JSON.stringify(login.value).includes(f.config.key));
  const response = await f.request('/api/session', { headers: { Cookie: login.cookie } });
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.equal(response.headers.get('access-control-allow-origin'), null);
  assert.equal((await response.json()).authenticated, true);
  const logout = await f.request('/api/session', { method: 'DELETE', headers: login.headers });
  assert.equal(logout.status, 200);
  assert.match(logout.headers.get('set-cookie'), /HttpOnly; SameSite=Strict; Max-Age=0/u);
  assert.equal((await (await f.request('/api/session', { headers: { Cookie: login.cookie } })).json()).authenticated, false);
  assert.equal((await wrong()).status, 401);
  assert.equal((await wrong()).status, 429);
});

test('production session cookies have Secure, HttpOnly and Strict attributes', async t => {
  const f = await fixture(t, { production: true });
  const response = await f.request('/api/session', {
    method: 'POST', headers: { Origin: f.config.origin, 'Content-Type': 'application/json' },
    body: JSON.stringify({ inviteCode: testInvite }),
  });
  assert.equal(response.status, 200);
  assert.match(response.headers.get('set-cookie'), /HttpOnly; SameSite=Strict; Max-Age=604800; Secure/u);
});

test('static serving has real wasm MIME and blocks traversal, dotfiles and symlink escapes', async t => {
  const f = await fixture(t);
  await writeFile(join(f.root, 'private.txt'), 'not-a-public-asset');
  await symlink(join(f.root, 'private.txt'), join(f.assets, 'escape.txt'));
  const wasm = await f.request('/test.wasm');
  assert.equal(wasm.headers.get('content-type'), 'application/wasm');
  assert.deepEqual([...new Uint8Array(await wasm.arrayBuffer())], [0, 97, 115, 109]);
  assert.equal((await f.request('/escape.txt')).status, 404);
  assert.equal((await f.request('/.env')).status, 404);
  assert.equal((await f.request('/%2e%2e%2fprivate.txt')).status, 404);
  const page = await f.request('/');
  assert.equal(page.status, 200);
  assert.equal(page.headers.get('cache-control'), 'no-store');
  assert.match(page.headers.get('content-security-policy'), /connect-src 'self'/u);
  assert.equal(page.headers.get('x-content-type-options'), 'nosniff');
});

test('provider failures cannot disclose reflected private text and are never retried or redirected', async t => {
  const privateText = 'sensitive-synthetic-homework-do-not-return';
  const received = [];
  const upstream = http.createServer((request, response) => {
    received.push(request.url);
    if (request.url === '/redirect') response.writeHead(302, { Location: '/leak' });
    else response.writeHead(429, { 'Content-Type': 'application/json' });
    response.end(JSON.stringify({ error: privateText }));
  });
  await new Promise(resolve => upstream.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => upstream.close(resolve)));
  const config = { key: 'test-only-credential', model: 'test-model', endpoint: `http://127.0.0.1:${upstream.address().port}/redirect` };
  await assert.rejects(callProvider(config, 'extract', { ...input(), sourceText: privateText }), error => error.status === 502 && !error.message.includes(privateText));
  assert.deepEqual(received, ['/redirect']);
  let calls = 0;
  await assert.rejects(callProvider(config, 'extract', input(), { fetcher: async (_url, options) => {
    calls++;
    assert.equal(options.redirect, 'error');
    const request = JSON.parse(options.body);
    assert.equal(request.model, config.model);
    assert.equal(request.max_tokens, 6000);
    assert.equal(request.messages[0].role, 'system');
    assert.match(request.messages[0].content, /untrusted DATA/u);
    assert.equal(request.messages[1].role, 'user');
    return new Response(JSON.stringify({ choices: [{ finish_reason: 'stop', message: { content: JSON.stringify({ tasks: [config.key] }) } }] }), { headers: { 'Content-Type': 'application/json' } });
  } }), error => error.status === 502 && !error.message.includes(config.key));
  assert.equal(calls, 1);
  await assert.rejects(callProvider(config, 'extract', input(), { fetcher: async () => new Response('x'.repeat(MAX_RESPONSE_BYTES + 1), { headers: { 'Content-Type': 'application/json' } }) }), error => error.status === 502);
});

test('provider dispatch failures still consume durable allowance and leak no input', async t => {
  let calls = 0;
  const f = await fixture(t, { dailyLimit: 1 }, async () => {
    calls++;
    return new Response('provider reflected Read chapter 4 tomorrow. test-only-provider-credential', { status: 500 });
  });
  const login = await f.signIn();
  const options = { method: 'POST', headers: login.headers, body: JSON.stringify(aiBody()) };
  const response = await f.request('/api/ai', options);
  assert.equal(response.status, 502);
  const error = await response.text();
  assert.ok(!error.includes(input().sourceText));
  assert.ok(!error.includes(f.config.key));
  assert.equal((await f.request('/api/ai', options)).status, 429);
  assert.equal(calls, 1);
});

const confirmedTask = () => ({
  id: 'task', title: 'Read the assigned chapter', subject: 'English', kind: 'homework',
  stage: 'ready', minutes: 15, remainingSeconds: 900, spentSeconds: 2700, difficulty: 2,
  weak: false, dueAt: null, dueTimeKnown: false, deferUntil: null,
  sourceCaptureId: '', sourceQuote: '', reason: '',
  steps: [{ id: 'task-step-0', title: 'Read chapter' }],
});
const planBody = () => {
  const context = input().context;
  context.confirmedTasks = [confirmedTask()];
  return { operation: 'plan', consent: true, input: {
    now: input().now, day: '2026-11-15', eligibleTaskIds: ['task'], context,
  } };
};

test('task context uses exact remaining work without invented timestamps or draft stages', () => {
  assert.deepEqual(validateAiRequest(planBody()).input, planBody().input);
  for (const patch of [
    { createdAt: input().now }, { updatedAt: input().now }, { stage: 'draft' },
    { minutes: 60 }, { remainingSeconds: -1 }, { dueTimeKnown: true },
  ]) {
    const body = planBody();
    Object.assign(body.input.context.confirmedTasks[0], patch);
    assert.throws(() => validateAiRequest(body));
  }
  for (const patch of [{ remainingSeconds: 0, minutes: 0 }, { stage: 'done' },
    { deferUntil: '2026-11-16' }]) {
    const body = planBody();
    Object.assign(body.input.context.confirmedTasks[0], patch);
    assert.throws(() => validateAiRequest(body));
  }
  const exhausted = planBody();
  exhausted.input.context.confirmedTasks[0].remainingSeconds = 0;
  exhausted.input.context.confirmedTasks[0].minutes = 0;
  exhausted.input.eligibleTaskIds = [];
  assert.equal(validateAiRequest(exhausted).input.context.confirmedTasks[0].stage, 'ready');
});

test('courses require an explicit relevant calendar date and no legacy promotion', () => {
  for (const coursesDate of [null, '2026-11-14', '2026-11-18']) {
    const body = planBody();
    Object.assign(body.input.context.preferences, { tomorrowCourses: ['Math'], coursesDate });
    assert.throws(() => validateAiRequest(body));
  }
  for (const coursesDate of ['2026-11-15', '2026-11-16']) {
    const body = planBody();
    Object.assign(body.input.context.preferences, { tomorrowCourses: ['Math'], coursesDate });
    assert.equal(validateAiRequest(body).input.context.preferences.coursesDate, coursesDate);
  }
});

test('focus and feedback records preserve real evidence and reject impossible durations', () => {
  const body = planBody();
  body.input.context.recentFocusRecords = [{
    id: 'focus', taskId: 'task', taskTitle: 'Read chapter', subject: 'English',
    startedAt: '2026-11-15T16:00:00', endedAt: '2026-11-15T16:30:00', focusedSeconds: 900,
  }];
  body.input.context.recentTextEvidence = [{
    id: 'graded', text: 'Teacher feedback: revisit paragraph structure.',
    createdAt: '2026-11-14T10:00:00', feedback: true, truncated: false,
  }];
  assert.deepEqual(validateAiRequest(body).input.context.recentTextEvidence,
    body.input.context.recentTextEvidence);
  body.input.context.recentFocusRecords[0].focusedSeconds = 1801;
  assert.throws(() => validateAiRequest(body));
  body.input.context.recentFocusRecords[0].focusedSeconds = 900;
  body.input.context.recentFocusRecords[0].endedAt = '2026-11-15T15:00:00';
  assert.throws(() => validateAiRequest(body));
});

test('calendar overflow, secrets, excessive target days and duplicate confirmed ids fail closed', () => {
  const overflow = aiBody();
  overflow.input.now = '2026-02-30T17:00:00';
  assert.throws(() => validateAiRequest(overflow));
  for (const sourceText of ['Bearer syntheticCredential12345678', 'sk-syntheticCredential12345678',
    '-----BEGIN PRIVATE KEY-----']) {
    const body = aiBody(); body.input.sourceText = sourceText;
    assert.throws(() => validateAiRequest(body));
  }
  const distant = planBody(); distant.input.day = '2026-12-16';
  assert.throws(() => validateAiRequest(distant));
  const duplicate = planBody(); duplicate.input.context.confirmedTasks.push(confirmedTask());
  assert.throws(() => validateAiRequest(duplicate));
  assert.throws(() => loadConfig({ STUDYORBIT_API_KEY: 'synthetic-key', STUDYORBIT_MODEL: 'synthetic-key' }));
});

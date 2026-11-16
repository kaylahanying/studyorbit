export class HttpError extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

export const reject = () => {
  throw new HttpError(400, 'input', 'Use bounded text-only study context. No media, credentials, or custom provider instructions are accepted.');
};
const object = (value, fields) => {
  if (!value || typeof value !== 'object' || Array.isArray(value) ||
      Object.keys(value).some(key => !Object.hasOwn(fields, key))) reject();
  const result = {};
  for (const [key, validate] of Object.entries(fields)) {
    if (!Object.hasOwn(value, key)) reject();
    result[key] = validate(value[key]);
  }
  return result;
};
const text = (max, empty = false) => value => {
  if (typeof value !== 'string' || value.length > max || (!empty && !value.trim()) ||
      /[\u0000-\u0008\u000b\u000c\u000e-\u001f]/u.test(value) ||
      /data:(?:image|audio|video|application)\/|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|\bBearer\s+[A-Za-z0-9._-]{12,}|\bsk-[A-Za-z0-9_-]{16,}/iu.test(value)) reject();
  return value;
};
const integer = (min, max) => value => {
  if (!Number.isSafeInteger(value) || value < min || value > max) reject();
  return value;
};
const boolean = value => {
  if (typeof value !== 'boolean') reject();
  return value;
};
const nullable = validate => value => value === null ? null : validate(value);
const list = (max, validate) => value => {
  if (!Array.isArray(value) || value.length > max) reject();
  return value.map(validate);
};
const enumeration = choices => value => choices.includes(value) ? value : reject();
const date = value => {
  text(40)(value);
  const match = /^(\d{4})-(\d\d)-(\d\d)(?:T([01]\d|2[0-3]):([0-5]\d)(?::([0-5]\d)(?:\.\d{1,6})?)?(?:Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)?)?$/u.exec(value);
  if (!match || !Number.isFinite(Date.parse(value))) reject();
  const calendar = new Date(Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3])));
  if (calendar.getUTCFullYear() !== Number(match[1]) ||
      calendar.getUTCMonth() + 1 !== Number(match[2]) ||
      calendar.getUTCDate() !== Number(match[3])) reject();
  return value;
};
const id = text(200);
const task = value => object(value, {
  id, title: text(240), subject: text(120),
  kind: enumeration(['homework', 'revision', 'preparation', 'exam']),
  stage: enumeration(['ready', 'deferred', 'done']),
  minutes: integer(0, 100000), remainingSeconds: integer(0, 6000000),
  spentSeconds: integer(0, 1000000000), difficulty: integer(1, 3), weak: boolean,
  dueAt: nullable(date), dueTimeKnown: boolean, deferUntil: nullable(date),
  sourceCaptureId: text(200, true), sourceQuote: text(4000, true), reason: text(1000, true),
  steps: list(100, value => object(value, { id, title: text(240) })),
});
const context = value => object(value, {
  preferences: value => object(value, {
    energy: enumeration(['low', 'steady', 'high']), focusMinutes: integer(1, 120),
    breakMinutes: integer(1, 60), mealStartMinute: integer(960, 1259),
    mealMinutes: integer(1, 120), leisureMinutes: integer(1, 120),
    weakSubjects: list(100, text(240)), weakTopics: list(100, text(240)),
    tomorrowCourses: list(100, text(240)), coursesDate: nullable(date),
  }),
  confirmedTasks: list(1000, task),
  recentHistory: list(100, value => object(value, {
    id, kind: text(100), summary: text(2000, true), occurredAt: date, taskId: nullable(id),
  })),
  recentFocusRecords: list(100, value => object(value, {
    id, taskId: id, taskTitle: text(240), subject: text(120), startedAt: date,
    endedAt: date, focusedSeconds: integer(0, 1000000000),
  })),
  recentTextEvidence: list(20, value => object(value, {
    id, createdAt: date, text: text(12000), truncated: boolean, feedback: boolean,
  })),
  contextLimits: value => object(value, {
    historyIncluded: integer(0, 100), historyTotal: integer(0, 1000000),
    capturesIncluded: integer(0, 20), capturesTotal: integer(0, 1000000),
    focusIncluded: integer(0, 100), focusTotal: integer(0, 1000000),
  }),
});

// Reconstruct from exact schemas rather than forwarding arbitrary JSON objects.
export function validateAiRequest(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value) ||
      Object.keys(value).some(key => !['operation', 'input', 'consent'].includes(key))) reject();
  if (value.consent !== true) throw new HttpError(400, 'consent', 'Allow text-only AI processing before sending study context.');
  const operation = enumeration(['extract', 'plan'])(value.operation);
  const input = operation === 'extract'
    ? object(value.input, { now: date, captureId: id, sourceText: text(100000), context })
    : object(value.input, { now: date, day: date, eligibleTaskIds: list(200, id), context });
  const tasks = input.context.confirmedTasks;
  if (new Set(tasks.map(task => task.id)).size !== tasks.length) reject();
  for (const task of tasks) {
    if (task.minutes !== Math.ceil(task.remainingSeconds / 60) ||
        (task.dueTimeKnown && task.dueAt === null)) reject();
  }
  const target = operation === 'plan' ? input.day : input.now.slice(0, 10);
  const next = new Date(`${target}T00:00:00Z`);
  next.setUTCDate(next.getUTCDate() + 1);
  const p = input.context.preferences;
  if (p.coursesDate !== null && (!/^\d{4}-\d\d-\d\d$/u.test(p.coursesDate) ||
      ![target, next.toISOString().slice(0, 10)].includes(p.coursesDate) ||
      p.coursesDate < input.now.slice(0, 10))) reject();
  if (p.tomorrowCourses.length && p.coursesDate === null) reject();
  for (const record of input.context.recentFocusRecords) {
    if (Date.parse(record.startedAt) > Date.parse(record.endedAt) ||
        Date.parse(record.endedAt) > Date.parse(input.now) ||
        record.focusedSeconds > Math.floor((Date.parse(record.endedAt) - Date.parse(record.startedAt)) / 1000)) reject();
  }
  if (operation === 'plan') {
    if (!/^20\d\d-\d\d-\d\d$/u.test(input.day)) reject();
    const distance = (Date.parse(`${input.day}T00:00:00Z`) -
      Date.parse(`${input.now.slice(0, 10)}T00:00:00Z`)) / 86400000;
    if (distance < 0 || distance > 30) reject();
    const eligible = new Set(tasks.filter(task => task.stage !== 'done' &&
      task.remainingSeconds > 0 && (task.deferUntil === null ||
        task.deferUntil.slice(0, 10) <= input.day)).map(task => task.id));
    if (new Set(input.eligibleTaskIds).size !== input.eligibleTaskIds.length ||
        input.eligibleTaskIds.some(id => !eligible.has(id))) reject();
  }
  return { operation, input };
}

export function parseJson(text) {
  let depth = 0;
  let quoted = false;
  let escaped = false;
  for (const c of text) {
    if (quoted) {
      if (escaped) escaped = false;
      else if (c === '\\') escaped = true;
      else if (c === '"') quoted = false;
    } else if (c === '"') quoted = true;
    else if (c === '{' || c === '[') {
      if (++depth > 32) reject();
    } else if (c === '}' || c === ']') depth--;
  }
  try { return JSON.parse(text); } catch { reject(); }
}

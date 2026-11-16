import { HttpError, parseJson } from './schema.mjs';
import { prompts } from './prompts.mjs';

const failure = (code = 'provider') => new HttpError(502, code, 'The study provider could not complete a safe structured response. No AI drafts or advice were applied.');
export const PROVIDER_TIMEOUT_MS = 45000;
export const MAX_RESPONSE_BYTES = 512 * 1024;

export async function callProvider(config, operation, input, { signal, fetcher = fetch } = {}) {
  const timeout = AbortSignal.timeout(PROVIDER_TIMEOUT_MS);
  const combined = signal ? AbortSignal.any([signal, timeout]) : timeout;
  const body = JSON.stringify({
    model: config.model, temperature: 0.2, max_tokens: 6000,
    response_format: { type: 'json_object' },
    ...(/^glm/i.test(config.model) ? { thinking: { type: 'disabled' } } : {}),
    messages: [
      { role: 'system', content: prompts[operation] },
      { role: 'user', content: JSON.stringify(input) },
    ],
  });
  if (Buffer.byteLength(body) > 400 * 1024) throw new HttpError(413, 'input', 'The study context is too large. Shorten the capture or retained history.');
  let response;
  try {
    response = await fetcher(config.endpoint, {
      method: 'POST', redirect: 'error', signal: combined,
      headers: { Authorization: `Bearer ${config.key}`, 'Content-Type': 'application/json', Accept: 'application/json' },
      body,
    });
    if (!response.ok) {
      console.warn('StudyOrbit upstream rejected operation', { operation, status: response.status });
      throw failure();
    }
    if (!/^application\/json(?:\s*;|$)/iu.test(response.headers.get('content-type') || '')) throw failure();
    if (Number(response.headers.get('content-length') || 0) > MAX_RESPONSE_BYTES) throw failure('response');
    if (!response.body) throw failure('response');
    const reader = response.body.getReader();
    const chunks = [];
    let length = 0;
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        length += value.length;
        if (length > MAX_RESPONSE_BYTES) throw failure('response');
        chunks.push(value);
      }
    } finally {
      await reader.cancel().catch(() => {});
      reader.releaseLock();
    }
    const envelope = parseJson(new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks, length)));
    const choice = envelope?.choices?.[0];
    if (!Array.isArray(envelope?.choices) || envelope.choices.length > 8 ||
        choice?.finish_reason !== 'stop' || choice?.message?.refusal != null ||
        typeof choice?.message?.content !== 'string' || choice.message.content.length > 180000) throw failure('response');
    const content = choice.message.content;
    // Never pass provider metadata, error bodies, credentials, or response headers through.
    if ([config.key, config.secret, config.invite].some(secret => secret && content.includes(secret))) throw failure('response');
    const result = parseJson(content);
    if (!result || typeof result !== 'object' || Array.isArray(result)) throw failure('response');
    const fields = operation === 'extract' ? ['tasks'] : ['order', 'dependencies', 'reasons', 'suggestions'];
    if (Object.keys(result).length !== fields.length || fields.some(field => !Object.hasOwn(result, field))) throw failure('response');
    if (operation === 'extract' && (!Array.isArray(result.tasks) || result.tasks.length > 30)) throw failure('response');
    if (operation === 'plan' && (!Array.isArray(result.order) || result.order.length > 200 ||
        !Array.isArray(result.suggestions) || result.suggestions.length > 12 ||
        !result.dependencies || typeof result.dependencies !== 'object' || Array.isArray(result.dependencies) ||
        !result.reasons || typeof result.reasons !== 'object' || Array.isArray(result.reasons))) throw failure('response');
    return { choices: [{ finish_reason: 'stop', message: { role: 'assistant', content: JSON.stringify(result) } }] };
  } catch (error) {
    if (combined.aborted) throw new HttpError(504, 'timeout', 'The study provider timed out. No drafts or advice were applied.');
    if (error instanceof HttpError && error.status === 413) throw error;
    throw failure();
  } finally {
    if (response?.body && !response.body.locked) await response.body.cancel().catch(() => {});
  }
}

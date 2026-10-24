import { ApiClient, fetchApi, fetchWithRetry } from '../src/utils/api';
import { AppError } from '../src/errors';

declare function require(name: string): any;
const { test } = require('node:test');
const assert = require('node:assert/strict');

export function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

// Keep real request timeouts; only eliminate the retry backoff delay.
const realSetTimeout = globalThis.setTimeout;
globalThis.setTimeout = ((callback: TimerHandler, delay?: number, ...args: unknown[]) =>
  realSetTimeout(callback, delay === 30000 ? delay : 0, ...args)) as typeof setTimeout;
Object.defineProperty(globalThis, 'navigator', {
  configurable: true,
  value: { onLine: true },
});
(globalThis as unknown as { chrome: unknown }).chrome = {
  storage: { local: { get(_keys: string[], callback: (value: unknown) => void): void {
    callback({ auth_tokens: {
      accessToken: 'access-token', refreshToken: 'refresh-token', expiresAt: Date.now() + 60000,
    } });
  } } },
};

test('raw retry helper never automatically replays writes after ambiguous failures', async () => {
  for (const method of ['POST', 'post', 'PUT', 'PATCH', 'DELETE']) {
    for (const failure of [503, 429, new TypeError('connection lost'), new DOMException('aborted', 'AbortError')]) {
      let calls = 0;
      globalThis.fetch = async () => {
        calls++;
        if (calls > 1) return jsonResponse({ duplicate: true }, 201);
        if (failure instanceof Error) throw failure;
        return jsonResponse({ code: 'UNAVAILABLE', message: 'unavailable' }, failure);
      };
      if (failure instanceof Error) {
        await assert.rejects(fetchWithRetry('https://example.test/downloads', { method }, 1));
      } else {
        const response = await fetchWithRetry('https://example.test/downloads', { method }, 1);
        assert.equal(response.status, failure, `${method} should return its original failure`);
      }
      assert.equal(calls, 1, `${method} must not be replayed after ${String(failure)}`);
    }
  }
});

test('safe methods retain transient retries and return an unread response', async () => {
  for (const method of [undefined, 'GET', 'get', 'HEAD', 'OPTIONS']) {
    for (const failure of [503, 429, new TypeError('connection lost')]) {
      let calls = 0;
      globalThis.fetch = async () => {
        if (++calls === 1) {
          if (failure instanceof Error) throw failure;
          return jsonResponse({ code: 'UNAVAILABLE' }, failure);
        }
        return jsonResponse({ ok: true });
      };
      const response = await fetchWithRetry('https://example.test/library', { method }, 1);
      assert.equal(calls, 2);
      assert.equal(response.bodyUsed, false);
      assert.deepEqual(await response.json(), { ok: true });
    }
  }
});

test('ApiClient POST does not replay a download after a connection loss', async () => {
  let calls = 0;
  globalThis.fetch = async () => {
    if (++calls === 1) throw new TypeError('response lost after enqueue');
    return jsonResponse({ job_id: 'duplicate-job' }, 201);
  };
  await assert.rejects(new ApiClient().post('/api/v1/downloads', { url: 'https://youtu.be/test' }));
  assert.equal(calls, 1);
});

test('fetchApi reads an exhausted server error body once and rejects the API error', async () => {
  let calls = 0;
  let reads = 0;
  const response = jsonResponse({ error: {
    code: 'DOWNLOAD_ENQUEUE_FAILED', message: 'failed to enqueue trusted download',
  } }, 503);
  const readJson = response.json.bind(response);
  response.json = async () => { reads++; return readJson(); };
  globalThis.fetch = async () => { calls++; return response; };
  await assert.rejects(fetchApi('/api/v1/downloads', { retryConfig: { maxRetries: 0 } }),
    (error: unknown) => error instanceof AppError &&
      error.code === 'DOWNLOAD_ENQUEUE_FAILED' && error.statusCode === 503);
  assert.equal(calls, 1);
  assert.equal(reads, 1, 'the final failure must not fall through to success JSON parsing');
});

test('fetchApi safe reads retain bounded retries and the final structured server error', async () => {
  let calls = 0;
  let reads = 0;
  globalThis.fetch = async () => {
    calls++;
    const response = jsonResponse({ error: { code: 'DOWNLOAD_UNAVAILABLE', message: 'temporarily unavailable' } }, 503);
    const readJson = response.json.bind(response);
    response.json = async () => { reads++; return readJson(); };
    return response;
  };
  await assert.rejects(fetchApi('/api/v1/downloads', { retryConfig: { maxRetries: 1, initialBackoff: 0 } }),
    (error: unknown) => error instanceof AppError && error.code === 'DOWNLOAD_UNAVAILABLE');
  assert.equal(calls, 2);
  assert.equal(reads, 2, 'each response body should be consumed exactly once');
});

test('an explicit 401 permits one POST replay after a successful token refresh', async () => {
  const requests: Array<{ url: string; method?: string; body?: BodyInit | null; auth: string | null }> = [];
  const store: Record<string, unknown> = { auth_tokens: {
    accessToken: 'old-access', refreshToken: 'old-refresh', expiresAt: Date.now() - 1,
  } };
  (globalThis as unknown as { chrome: unknown }).chrome = {
    storage: { local: {
      get(_keys: string[], callback: (value: unknown) => void): void { callback(store); },
      set(value: Record<string, unknown>, callback: () => void): void { Object.assign(store, value); callback(); },
      remove(_keys: unknown, callback: () => void): void { callback(); },
    } },
  };
  globalThis.fetch = async (url, init) => {
    requests.push({ url: String(url), method: init?.method, body: init?.body,
      auth: new Headers(init?.headers).get('Authorization') });
    if (requests.length === 1) return jsonResponse({ code: 'TOKEN_EXPIRED', message: 'expired' }, 401);
    if (requests.length === 2) return jsonResponse({ accessToken: 'new-access', refreshToken: 'new-refresh' });
    return jsonResponse({ job_id: 'only-job' }, 201);
  };
  const result = await new ApiClient().post('/api/v1/downloads', { url: 'https://youtu.be/test' });
  assert.deepEqual(result, { job_id: 'only-job' });
  assert.equal(requests.length, 3);
  assert.equal(requests[1].url.endsWith('/api/v1/auth/refresh'), true);
  assert.equal(requests[1].method, 'POST');
  assert.deepEqual(JSON.parse(String(requests[1].body)), { refreshToken: 'old-refresh' });
  assert.equal(requests[0].body, requests[2].body);
  assert.equal(requests[2].auth, 'Bearer new-access');
});

test('fetchApi does not automatically retry POST even with a retry budget', async () => {
  let calls = 0;
  globalThis.fetch = async () => {
    if (++calls === 1) throw new TypeError('response lost after enqueue');
    return jsonResponse({ job_id: 'duplicate-job' }, 201);
  };
  await assert.rejects(fetchApi('/api/v1/downloads', {
    method: 'POST', retryConfig: { maxRetries: 1, initialBackoff: 0 },
  }), AppError);
  assert.equal(calls, 1);
});

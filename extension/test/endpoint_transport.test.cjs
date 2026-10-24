const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { endpointBundle } = require('../config/endpoints.cjs');

for (const base of ['http://localhost:8080/api/v1', 'https://api.example.test/api/v1/',
  'https://api.example.test:9443/music/api/v1/', 'https://api.example.test:9555/a/b/api/v1']) {
  test(`complete fetch URLs preserve version, prefix and port: ${base}`, async () => {
    const fixture = endpointBundle({ OMP_API_BASE_URL: base,
      OMP_HEALTH_URL: 'https://probe.example.test/ready',
      OMP_WEB_LOGIN_URL: 'https://ui.example.test/app/sign-in' });
    for (const name of ['endpoints', 'storage/index', 'utils/api']) {
      delete require.cache[require.resolve(path.join(__dirname, 'dist/src', name))];
    }
    const store = {};
    globalThis.__OMP_ENDPOINTS__ = fixture;
    globalThis.chrome = { storage: { local: {
      get(keys, callback) { callback(Object.fromEntries(keys.filter(k => k in store).map(k => [k, store[k]]))); },
      set(values, callback) { Object.assign(store, values); callback(); },
      remove(keys, callback) { for (const key of keys) delete store[key]; callback(); },
    } } };
    Object.defineProperty(globalThis, 'navigator', { configurable: true, value: { onLine: true } });
    const { setAuthTokens } = require('./dist/src/storage');
    const { ApiClient, fetchApi } = require('./dist/src/utils/api');
    await setAuthTokens({ accessToken: 'synthetic', refreshToken: 'synthetic-refresh', expiresAt: 1 });
    const calls = [];
    globalThis.fetch = async (input, options) => {
      calls.push({ url: String(input), method: options.method ?? 'GET' });
      if (calls.length === 1) return new Response('{}', { status: 401 });
      if (calls.length === 2) return Response.json({ accessToken: 'rotated', refreshToken: 'rotated-refresh' });
      return Response.json({});
    };
    await new ApiClient().authorizedFetch('/api/v1/library?limit=2');
    await fetchApi('/api/v1/search/recordings?query=fixture', { skipRetry: true });
    const expected = base.replace(/\/$/, '');
    assert.deepEqual(calls, [
      { url: expected + '/library?limit=2', method: 'GET' },
      { url: expected + '/auth/refresh', method: 'POST' },
      { url: expected + '/library?limit=2', method: 'GET' },
      { url: expected + '/search/recordings?query=fixture', method: 'GET' },
    ]);
  });
}

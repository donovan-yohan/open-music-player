const assert = require('node:assert/strict');
const test = require('node:test');
const load = () => require('../config/endpoints.cjs');

test('canonical extension gate includes configuration and runtime endpoint regressions', () => {
  const fs = require('node:fs');
  const gate = fs.readFileSync(require.resolve('../../scripts/test'), 'utf8');
  assert.match(gate, /npm run test:endpoints/);
  assert.match(require('../package.json').scripts['test:endpoints'], /endpoint_runtime_regression/);
});

test('webpack injects bundle and generates only configured/provider host permissions', () => {
  const env = { OMP_API_BASE_URL: 'https://api.example.test:9443/music/api/v1',
    OMP_HEALTH_URL: 'https://probe.example.test/ready', OMP_WEB_LOGIN_URL: 'https://ui.example.test/sign-in' };
  const original = { ...process.env };
  Object.assign(process.env, env);
  try {
    const config = require('../webpack.config.js')({}, { mode: 'production' });
    const define = config.plugins.find(p => p.definitions);
    assert.deepEqual(JSON.parse(define?.definitions.__OMP_ENDPOINTS__), load().endpointBundle(env));
    const copy = config.plugins.find(p => p.patterns);
    const manifest = JSON.parse(copy.patterns.find(p => p.from === 'manifest.json')
      .transform(Buffer.from(require('node:fs').readFileSync(require.resolve('../manifest.json')))));
    assert(manifest.host_permissions.includes('https://api.example.test/*'));
    assert(manifest.host_permissions.includes('https://www.youtube.com/*'));
    assert(!manifest.host_permissions.some(p => /localhost|openmusicplayer|<all_urls>/.test(p)));
  } finally { process.env = original; }
});

test('custom configuration must supply a complete valid immutable bundle', () => {
  const { endpointBundle } = load();
  const valid = {
    OMP_API_BASE_URL: 'https://api.example.test/prefix/api/v1',
    OMP_HEALTH_URL: 'https://api.example.test/ready',
    OMP_WEB_LOGIN_URL: 'https://ui.example.test/sign-in',
  };
  assert.throws(() => endpointBundle({ OMP_API_BASE_URL: valid.OMP_API_BASE_URL }));
  for (const key of Object.keys(valid)) {
    for (const bad of ['', 'ftp://example.test/path', 'https://user:pass@example.test/path',
      'https://example.test/path?q=1', 'https://example.test/path#x', 'https://example.test/a//b',
      'https://example.test/a/../b', 'https://example.test/a/%2e%2e/b', 'https://example.test/a%2fb',
      'https://example.test:99999/a', 'https://example.test:0/a', 'https://*/api',
      'https://example.test:/api', 'https://example.test/a%00b',
      'https://example.test/a\\b', ' https://example.test/a']) {
      assert.throws(() => endpointBundle({ ...valid, [key]: bad }), `${key}: ${bad}`);
    }
  }
  assert.throws(() => endpointBundle({ ...valid, OMP_WS_URL: 'https://api.example.test/ws' }));
  assert(Object.isFrozen(endpointBundle(valid)));
  assert.equal(endpointBundle({}).wsUrl, null);
  assert.equal(endpointBundle({}).apiBaseUrl, 'http://localhost:8080/api/v1');
});

test('explicit bundle preserves API prefix and independent health/login/WS URLs', () => {
  const { endpointBundle, hostPermissions } = load();
  const bundle = endpointBundle({
    OMP_API_BASE_URL: 'https://api.example.test:9443/music/api/v1/',
    OMP_HEALTH_URL: 'https://probe.example.test:8443/ready',
    OMP_WEB_LOGIN_URL: 'https://ui.example.test:7443/app/sign-in/',
    OMP_WS_URL: 'wss://api.example.test:9443/music/events',
  });
  assert.equal(bundle.apiBaseUrl, 'https://api.example.test:9443/music/api/v1');
  assert.equal(bundle.healthUrl, 'https://probe.example.test:8443/ready');
  assert.equal(bundle.webLoginUrl, 'https://ui.example.test:7443/app/sign-in/');
  assert.equal(bundle.wsUrl, 'wss://api.example.test:9443/music/events');
  assert.deepEqual(hostPermissions(bundle), [
    'https://api.example.test/*', 'https://probe.example.test/*', 'https://ui.example.test/*',
  ]); // Browser match patterns cannot restrict port; runtime URLs must preserve it.
});

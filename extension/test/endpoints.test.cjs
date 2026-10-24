const assert = require('node:assert/strict');
const test = require('node:test');
const load = () => require('../config/endpoints.cjs');

for (const code of [...Array(32).keys(), 127]) {
  test(`literal ASCII control U+${code.toString(16).padStart(4, '0')} rejects before URL normalization`, () => {
    const { endpointBundle } = load();
    const control = String.fromCharCode(code);
    const valid = { OMP_API_BASE_URL: 'https://api.example.test/prefix/api/v1',
      OMP_HEALTH_URL: 'https://probe.example.test/ready',
      OMP_WEB_LOGIN_URL: 'https://ui.example.test/sign-in',
      OMP_WS_URL: 'wss://events.example.test/progress' };
    for (const [key, url] of Object.entries(valid)) {
      const [scheme, rest] = url.split('://');
      for (const bad of [control + url, url + control,
        `${scheme}://${control}${rest}`, url.replace(/(\/\/[^/]+)/, `$1/a${control}b`)]) {
        assert.throws(() => endpointBundle({ ...valid, [key]: bad }),
          `${key}: ${JSON.stringify(bad)}`);
      }
    }
    const encoded = `https://api.example.test/a%${code.toString(16).padStart(2, '0')}b/api/v1`;
    assert.throws(() => endpointBundle({ ...valid, OMP_API_BASE_URL: encoded }), /Malformed endpoint path/);
  });
}

test('offline preflight inherits literal-control rejection from the endpoint validator', () => {
  const fs = require('node:fs');
  const path = require('node:path');
  const { prepare } = require('../../scripts/private-vm-preflight');
  const dir = fs.mkdtempSync(path.join(require('node:os').tmpdir(), 'endpoint-controls-'));
  const input = path.join(dir, 'synthetic-record.json');
  const evidence = path.join(dir, 'must-not-exist.json');
  const record = { approvedBy: 'Anko', verificationRef: 'synthetic-offline-control-regression',
    inputs: { OMP_API_BASE_URL: 'https://api.example.test/prefix/api/v1',
      OMP_HEALTH_URL: 'https://probe.example.test/ready', OMP_WEB_LOGIN_URL: 'https://ui.example.test/sign-in',
      MINIO_PUBLIC_ENDPOINT: 'https://media.example.test', OMP_CORS_ALLOWED_ORIGINS: ['https://ui.example.test'],
      OMP_SOURCE_REF: '1'.repeat(40), OMP_BUILD_ID: 'synthetic-control-regression' },
    checks: Object.fromEntries(['vmEnrollment', 'restore', 'apiRoutes', 'jwtAuth', 'media', 'cors', 'reboot', 'rollback']
      .map(key => [key, true])) };
  try {
    fs.writeFileSync(input, JSON.stringify(record));
    const args = ['--opt-in', '--anko-verification', input, '--evidence', evidence];
    assert.equal(prepare(args).evidence.liveVerifiedByScript, false);
    for (const code of [...Array(32).keys(), 127]) {
      record.inputs.OMP_API_BASE_URL = `https://api.example.test/a${String.fromCharCode(code)}b/api/v1`;
      fs.writeFileSync(input, JSON.stringify(record));
      assert.throws(() => prepare(args), /Invalid explicit endpoint URL/, `literal control ${code}`);
      assert.equal(fs.existsSync(evidence), false);
    }
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test('spaces and malformed authorities reject without being repaired', () => {
  const { validateUrl } = load();
  for (const bad of [' https://api.example.test/api/v1', 'https://api.example.test/api/v1 ',
    'https://api.example.test/a b/api/v1', 'https:///api.example.test/api/v1']) {
    assert.throws(() => validateUrl(bad));
  }
});

test('API bases require a terminal version path, not an origin or another route', () => {
  for (const api of ['https://api.example.test', 'https://api.example.test/',
    'https://api.example.test/music', 'https://api.example.test/api/v2',
    'https://api.example.test/api/v1/library', 'https://api.example.test/music/api/v10']) {
    assert.throws(() => load().endpointBundle({ OMP_API_BASE_URL: api,
      OMP_HEALTH_URL: 'https://probe.example.test/ready',
      OMP_WEB_LOGIN_URL: 'https://ui.example.test/sign-in' }), /api\/v1/, api);
  }
});

test('canonical extension gate includes configuration and runtime endpoint regressions', () => {
  const fs = require('node:fs');
  const gate = fs.readFileSync(require.resolve('../../scripts/test'), 'utf8');
  assert.match(gate, /npm run test:endpoints/);
  assert.match(require('../package.json').scripts['test:endpoints'], /endpoint_runtime_regression/);
});

for (const wsUrl of [undefined, 'wss://events.example.test:9555/progress']) {
test(`webpack isolates all endpoint inputs and preserves optional WS: ${wsUrl}`, () => {
  const env = { OMP_API_BASE_URL: 'https://api.example.test:9443/music/api/v1',
    OMP_HEALTH_URL: 'https://probe.example.test/ready', OMP_WEB_LOGIN_URL: 'https://ui.example.test/sign-in' };
  if (wsUrl !== undefined) env.OMP_WS_URL = wsUrl;
  const original = { ...process.env };
  for (const key of ['OMP_API_BASE_URL', 'OMP_HEALTH_URL', 'OMP_WEB_LOGIN_URL', 'OMP_WS_URL']) delete process.env[key];
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
}

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

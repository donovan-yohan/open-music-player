const test = require('node:test');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const root = path.resolve(__dirname, '..');
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'soundq-preflight-test-'));
process.on('exit', () => fs.rmSync(scratch, { recursive: true, force: true }));
const record = {
  approvedBy: 'Anko', verificationRef: 'fixture-only-not-operational-evidence',
  inputs: { OMP_API_BASE_URL: 'https://api.example.test:9443/music/api/v1/',
    OMP_HEALTH_URL: 'https://probe.example.test/ready',
    OMP_WEB_LOGIN_URL: 'https://ui.example.test/app/sign-in',
    MINIO_PUBLIC_ENDPOINT: 'https://media.example.test:9444',
    OMP_CORS_ALLOWED_ORIGINS: ['https://ui.example.test'],
    OMP_SOURCE_REF: '1'.repeat(40), OMP_BUILD_ID: 'fixture-build' },
  checks: Object.fromEntries(['vmEnrollment', 'restore', 'apiRoutes', 'jwtAuth', 'media', 'cors', 'reboot', 'rollback'].map(k => [k, true])),
};
function run(args) {
  return spawnSync(process.execPath, [path.join(root, 'scripts/private-vm-preflight'), ...args], { encoding: 'utf8' });
}
// Local, synthetic repositories only; no commit or source change in the real checkout.
function buildFixture(dir) {
  const checkout = path.join(dir, 'checkout');
  fs.mkdirSync(path.join(checkout, 'scripts'), { recursive: true });
  fs.mkdirSync(path.join(checkout, 'extension/config'), { recursive: true });
  fs.mkdirSync(path.join(checkout, 'client'));
  for (const file of ['scripts/private-vm-build', 'scripts/private-vm-preflight', 'extension/config/endpoints.cjs']) {
    fs.copyFileSync(path.join(root, file), path.join(checkout, file));
  }
  fs.writeFileSync(path.join(checkout, '.gitignore'), 'extension/node_modules/\n');
  const git = (...args) => {
    const result = spawnSync('git', ['-C', checkout, ...args], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    return result.stdout.trim();
  };
  git('init', '--quiet'); git('add', '.');
  git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.test', 'commit', '--quiet', '-m', 'synthetic fixture');
  // Even a populated dependency tree must not suppress the locked install.
  fs.mkdirSync(path.join(checkout, 'extension/node_modules'), { recursive: true });
  fs.writeFileSync(path.join(checkout, 'extension/node_modules/stale'), 'not trusted');
  return { checkout, git, head: git('rev-parse', 'HEAD'), tree: git('rev-parse', 'HEAD^{tree}') };
}
test('migration build binds Flutter and webpack to one approved snapshot, artifact-only', t => {
  const dir = fs.mkdtempSync(path.join(scratch, 'build-'));
  const fixture = buildFixture(dir);
  const bin = path.join(dir, 'bin'); fs.mkdirSync(bin);
  const log = path.join(dir, 'commands.jsonl');
  const keys = ['OMP_API_BASE_URL', 'OMP_HEALTH_URL', 'OMP_WEB_LOGIN_URL', 'OMP_WS_URL',
    'OMP_SOURCE_REF', 'OMP_BUILD_ID', 'MINIO_PUBLIC_ENDPOINT', 'OMP_CORS_ALLOWED_ORIGINS'];
  for (const name of ['flutter', 'npm', 'adb', 'docker', 'ssh', 'gh']) {
    fs.writeFileSync(path.join(bin, name), `#!${process.execPath}\n` +
      `require('node:fs').appendFileSync(${JSON.stringify(log)}, JSON.stringify({name:${JSON.stringify(name)}, args:process.argv.slice(2), cwd:process.cwd(), env:Object.fromEntries(${JSON.stringify(keys)}.filter(k=>process.env[k]!==undefined).map(k=>[k,process.env[k]]))})+'\\n');\n`, { mode: 0o755 });
  }
  const approved = structuredClone(record);
  approved.inputs.OMP_SOURCE_REF = fixture.head;
  approved.inputs.OMP_WS_URL = 'wss://events.example.test/progress';
  const verification = path.join(dir, 'anko.json');
  fs.writeFileSync(verification, JSON.stringify(approved));
  const evidence = path.join(dir, 'evidence.json');
  const result = spawnSync(process.execPath, [path.join(fixture.checkout, 'scripts/private-vm-build'), '--opt-in',
    '--anko-verification', verification, '--evidence', evidence, '--target', 'all'], {
    encoding: 'utf8', env: { ...process.env, PATH: bin + ':' + process.env.PATH,
      ...Object.fromEntries(keys.map(k => [k, 'unreviewed-shell-override'])) },
  });
  assert.equal(result.status, 0, result.stderr);
  const commands = fs.readFileSync(log, 'utf8').trim().split('\n').map(JSON.parse);
  const defines = ['OMP_API_BASE_URL', 'OMP_SOURCE_REF', 'OMP_BUILD_ID'].map(k => `--dart-define=${k}=${approved.inputs[k]}`);
  assert.deepEqual(commands.filter(c => c.name === 'flutter').map(c => c.args), [
    ['pub', 'get'], ['build', 'apk', '--debug', '--no-pub', '--target-platform', 'android-arm64', ...defines],
    ['pub', 'get'], ['build', 'web', '--release', '--no-pub', ...defines],
  ]);
  assert.deepEqual(commands.filter(c => c.name === 'npm').map(c => c.args), [['ci'], ['run', 'build']]);
  assert(commands.every(c => ['flutter', 'npm'].includes(c.name)), 'no deployment/install executable');
  for (const command of commands) {
    assert.equal(command.cwd, path.join(fixture.checkout, command.name === 'flutter' ? 'client' : 'extension'));
    assert.deepEqual(command.env, Object.fromEntries(keys.filter(k => !['MINIO_PUBLIC_ENDPOINT', 'OMP_CORS_ALLOWED_ORIGINS'].includes(k)).map(k => [k, approved.inputs[k]])));
  }
  const receipt = JSON.parse(fs.readFileSync(evidence));
  assert.equal(receipt.cutover, 'HELD');
  assert.equal(receipt.deployment, 'HELD');
  assert.equal(receipt.distribution, 'HELD');
  assert.equal(receipt.mediaOrigin, approved.inputs.MINIO_PUBLIC_ENDPOINT);
  assert.deepEqual(receipt.source, { commit: fixture.head, tree: fixture.tree, clean: true });
  t.diagnostic(JSON.stringify({ stubCommands: commands, preflightReceipt: receipt }));
  // An omitted optional WS must not pick up a destination from the shell.
  delete approved.inputs.OMP_WS_URL;
  fs.writeFileSync(verification, JSON.stringify(approved));
  const noWs = spawnSync(process.execPath, [path.join(fixture.checkout, 'scripts/private-vm-build'), '--opt-in',
    '--anko-verification', verification, '--evidence', path.join(dir, 'no-ws.json'), '--target', 'extension'], {
    encoding: 'utf8', env: { ...process.env, PATH: bin + ':' + process.env.PATH, OMP_WS_URL: 'wss://unreviewed.example.test/ws' },
  });
  assert.equal(noWs.status, 0, noWs.stderr);
  const last = JSON.parse(fs.readFileSync(log, 'utf8').trim().split('\n').at(-1));
  assert.equal(last.env.OMP_WS_URL, undefined);
});
test('migration build rejects mismatched or dirty source before tools and evidence', () => {
  for (const kind of ['mismatch', 'tracked', 'staged', 'untracked']) {
    const dir = fs.mkdtempSync(path.join(scratch, `source-${kind}-`));
    const fixture = buildFixture(dir);
    const bin = path.join(dir, 'bin'); fs.mkdirSync(bin);
    const log = path.join(dir, 'launched');
    for (const name of ['npm', 'flutter']) fs.writeFileSync(path.join(bin, name),
      `#!${process.execPath}\nrequire('node:fs').writeFileSync(${JSON.stringify(log)}, 'launched');\n`, { mode: 0o755 });
    const approval = structuredClone(record);
    approval.inputs.OMP_SOURCE_REF = fixture.head;
    if (kind === 'mismatch') {
      fixture.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.test',
        'commit', '--quiet', '--allow-empty', '-m', 'different clean checkout');
    } else if (kind === 'untracked') {
      fs.writeFileSync(path.join(fixture.checkout, 'unreviewed.txt'), 'unreviewed');
    } else {
      fs.appendFileSync(path.join(fixture.checkout, 'extension/config/endpoints.cjs'), '\n// unreviewed\n');
      if (kind === 'staged') fixture.git('add', '.');
    }
    const verification = path.join(dir, 'approval.json');
    const evidence = path.join(dir, 'receipt.json');
    fs.writeFileSync(verification, JSON.stringify(approval));
    const result = spawnSync(process.execPath, [path.join(fixture.checkout, 'scripts/private-vm-build'),
      '--opt-in', '--anko-verification', verification, '--evidence', evidence, '--target', 'extension'], {
      encoding: 'utf8', env: { ...process.env, PATH: bin + ':' + process.env.PATH },
    });
    assert.notEqual(result.status, 0, `${kind}: ${result.stdout}`);
    assert.match(result.stderr, kind === 'mismatch' ? /OMP_SOURCE_REF.*HEAD/ : /clean.*checkout/i);
    assert(!fs.existsSync(log), `${kind} launched build tools`);
    assert(!fs.existsSync(evidence), `${kind} minted evidence`);
  }
});
test('migration build keeps evidence outside the canonical source checkout before clean claims or tools', async t => {
  const kinds = ['inside', 'missing-inside', 'ignored-inside', 'outside-alias-inside',
    'outside-alias-missing-inside', 'outside-alias-ignored-inside', 'symlinked-parent-inside',
    'sibling-prefix-outside', 'outside-alias-outside', 'symlinked-parent-outside'];
  for (const kind of kinds) await t.test(kind, () => {
    const dir = fs.mkdtempSync(path.join(scratch, 'evidence-location-'));
    const fixture = buildFixture(dir);
    const approval = structuredClone(record); approval.inputs.OMP_SOURCE_REF = fixture.head;
    const verification = path.join(dir, 'approval.json');
    fs.writeFileSync(verification, JSON.stringify(approval));
    let checkout = fixture.checkout;
    let evidence;
    const outside = kind.endsWith('-outside');
    if (kind.startsWith('symlinked-parent-')) {
      const alias = path.join(dir, 'parent-alias'); fs.symlinkSync(dir, alias, 'dir');
      checkout = path.join(alias, 'checkout');
      evidence = path.join(alias, outside ? 'receipts' : 'checkout/receipts', 'receipt.json');
    } else if (kind.startsWith('outside-alias-')) {
      const alias = path.join(dir, 'output-alias');
      const destination = outside ? path.join(dir, 'receipts') : fixture.checkout;
      if (outside) fs.mkdirSync(destination);
      fs.symlinkSync(destination, alias, 'dir');
      evidence = path.join(alias, kind.includes('ignored') ? 'extension/node_modules/receipt.json' :
        kind.includes('missing') ? 'not-created/nested/receipt.json' : 'receipt.json');
    } else {
      evidence = path.join(kind === 'sibling-prefix-outside' ? fixture.checkout + '-receipts' : fixture.checkout,
        kind === 'ignored-inside' ? 'extension/node_modules/receipt.json' :
          kind === 'missing-inside' ? 'not-created/nested/receipt.json' : 'receipt.json');
    }
    // Snapshot only this explicit synthetic source; never traverse Git metadata.
    const snapshot = () => {
      const entries = {};
      const visit = relative => {
        for (const item of fs.readdirSync(path.join(fixture.checkout, relative), { withFileTypes: true })) {
          if (!relative && item.name === '.git') continue;
          const name = path.join(relative, item.name);
          entries[name] = item.isDirectory() ? 'directory' : fs.readFileSync(path.join(fixture.checkout, name), 'hex');
          if (item.isDirectory()) visit(name);
        }
      };
      visit(''); return entries;
    };
    const before = snapshot();
    assert.equal(fixture.git('status', '--porcelain=v1', '--untracked-files=all'), '');
    const bin = path.join(dir, 'bin'); fs.mkdirSync(bin);
    const commands = path.join(dir, 'commands.jsonl');
    const gitLog = path.join(dir, 'git.jsonl');
    const realGit = process.env.PATH.split(path.delimiter).map(p => path.join(p, 'git')).find(p => fs.existsSync(p));
    assert(realGit);
    fs.writeFileSync(path.join(bin, 'git'), `#!${process.execPath}\n` +
      `const {spawnSync}=require('node:child_process'); require('node:fs').appendFileSync(${JSON.stringify(gitLog)}, JSON.stringify(process.argv.slice(2))+'\\n');\n` +
      `const r=spawnSync(${JSON.stringify(realGit)},process.argv.slice(2),{stdio:'inherit'}); process.exit(r.status ?? 2);\n`, { mode: 0o755 });
    for (const name of ['npm', 'flutter']) fs.writeFileSync(path.join(bin, name), `#!${process.execPath}\n` +
      `const fs=require('node:fs'); fs.appendFileSync(${JSON.stringify(commands)}, JSON.stringify({name:${JSON.stringify(name)},args:process.argv.slice(2),receipt:JSON.parse(fs.readFileSync(${JSON.stringify(evidence)}))})+'\\n');\n`, { mode: 0o755 });
    const invoke = () => spawnSync(process.execPath, [path.join(checkout, 'scripts/private-vm-build'),
      '--opt-in', '--anko-verification', verification, '--evidence', evidence, '--target', 'extension'], {
      encoding: 'utf8', env: { ...process.env, PATH: bin + path.delimiter + process.env.PATH },
    });
    const result = invoke();
    const afterStatus = fixture.git('status', '--porcelain=v1', '--untracked-files=all');
    t.diagnostic(JSON.stringify({ kind, exit: result.status, stderr: result.stderr,
      evidenceExists: fs.existsSync(evidence), sourceStatusAfter: afterStatus,
      receipt: fs.existsSync(evidence) ? JSON.parse(fs.readFileSync(evidence)) : null,
      gitChecks: fs.existsSync(gitLog) ? fs.readFileSync(gitLog, 'utf8').trim().split('\n').map(JSON.parse) : [] }));
    if (!outside) {
      assert.equal(result.status, 2, 'source-contained evidence must be refused');
      assert.match(result.stderr, /evidence.*outside.*source checkout/i);
      assert(!fs.existsSync(evidence), 'must not mint a false clean-source receipt');
      assert(!fs.existsSync(commands), 'must not launch build tools');
      assert(!fs.existsSync(gitLog), 'reject output before source-clean checks');
    } else {
      assert.equal(result.status, 0, result.stderr);
      const receipt = fs.readFileSync(evidence, 'utf8');
      const observed = fs.readFileSync(commands, 'utf8').trim().split('\n').map(JSON.parse);
      assert.deepEqual(observed.map(c => [c.name, c.args]), [['npm', ['ci']], ['npm', ['run', 'build']]]);
      for (const command of observed) assert.deepEqual(command.receipt.source,
        { commit: fixture.head, tree: fixture.tree, clean: true }, 'receipt precedes tools');
      const rerun = invoke();
      assert.equal(rerun.status, 2);
      assert.match(rerun.stderr, /fresh.*evidence/i);
      assert.equal(fs.readFileSync(evidence, 'utf8'), receipt, 'outside receipts remain immutable');
      assert.equal(fs.readFileSync(commands, 'utf8').trim().split('\n').length, 2, 'rerun must not launch tools');
    }
    assert.equal(afterStatus, '', 'source remains clean');
    assert.deepEqual(snapshot(), before, 'including ignored source paths and absent nested directories');
  });
});
test('preflight requires an exact full lowercase commit SHA, without repairing source tokens', () => {
  const dir = fs.mkdtempSync(path.join(scratch, 'source-format-'));
  const verification = path.join(dir, 'approval.json');
  for (const [index, source] of ['fixture-ref', 'main', 'a'.repeat(7), 'A'.repeat(40),
    ' ' + 'a'.repeat(40), 'main@' + 'a'.repeat(40), 'a'.repeat(64)].entries()) {
    const approval = structuredClone(record); approval.inputs.OMP_SOURCE_REF = source;
    fs.writeFileSync(verification, JSON.stringify(approval));
    const evidence = path.join(dir, `receipt-${index}.json`);
    const result = run(['--opt-in', '--anko-verification', verification, '--evidence', evidence]);
    assert.notEqual(result.status, 0, source);
    assert.match(result.stderr, /OMP_SOURCE_REF/);
    assert(!fs.existsSync(evidence));
  }
});
test('ordinary local extension builds still accept custom fixtures without migration approval', () => {
  const dir = fs.mkdtempSync(path.join(scratch, 'local-build-'));
  const log = path.join(dir, 'npm.jsonl');
  fs.writeFileSync(path.join(dir, 'npm'), `#!${process.execPath}\n` +
    `require('node:fs').appendFileSync(${JSON.stringify(log)}, JSON.stringify({args:process.argv.slice(2), api:process.env.OMP_API_BASE_URL})+'\\n');\n`, { mode: 0o755 });
  const result = spawnSync('bash', [path.join(root, 'scripts/build'), 'extension'], {
    encoding: 'utf8', env: { ...process.env, PATH: dir + ':' + process.env.PATH, ...record.inputs },
  });
  assert.equal(result.status, 0, result.stderr);
  const commands = fs.readFileSync(log, 'utf8').trim().split('\n').map(JSON.parse);
  assert(commands.some(c => JSON.stringify(c.args) === JSON.stringify(['run', 'build'])));
  assert(commands.every(c => c.api === record.inputs.OMP_API_BASE_URL));
});
test('migration build rejects absent, invalid, incomplete or mismatched approval before tools/evidence', () => {
  const dir = fs.mkdtempSync(path.join(scratch, 'blocked-'));
  const bin = path.join(dir, 'bin'); fs.mkdirSync(bin);
  const log = path.join(dir, 'launched');
  for (const name of ['flutter', 'npm']) fs.writeFileSync(path.join(bin, name),
    `#!/bin/sh\ntouch '${log}'\nexit 0\n`, { mode: 0o755 });
  const verification = path.join(dir, 'anko.json');
  const variants = [
    { extra: ['--api-base-url', 'https://not-reviewed.example.test/api'] },
    { extra: ['--target', 'extension'] },
    { omit: '--opt-in' }, { omit: '--anko-verification' },
    { text: '{' }, { mutate: r => r.approvedBy = 'not-Anko' },
    { mutate: r => r.checks.media = false },
    { mutate: r => delete r.inputs.OMP_SOURCE_REF },
    { mutate: r => delete r.inputs.OMP_BUILD_ID },
    { mutate: r => delete r.inputs.OMP_HEALTH_URL },
    { mutate: r => r.inputs.OMP_API_BASE_URL = 'ftp://invalid.test/api' },
    { mutate: r => r.inputs.MINIO_PUBLIC_ENDPOINT += '/prefix' },
    { mutate: r => r.inputs.OMP_CORS_ALLOWED_ORIGINS = ['https://mismatched.example.test'] },
    { extra: ['--target', 'install'] },
  ];
  variants.forEach((variant, index) => {
    const approval = structuredClone(record); variant.mutate?.(approval);
    fs.writeFileSync(verification, variant.text || JSON.stringify(approval));
    const evidence = path.join(dir, `receipt-${index}.json`);
    let args = ['--opt-in', '--anko-verification', verification, '--evidence', evidence, '--target', 'all'];
    if (variant.omit) { const at = args.indexOf(variant.omit); args.splice(at, variant.omit === '--opt-in' ? 1 : 2); }
    const result = spawnSync(process.execPath, [path.join(root, 'scripts/private-vm-build'), ...args, ...(variant.extra || [])], {
      encoding: 'utf8', env: { ...process.env, PATH: bin + ':' + process.env.PATH },
    });
    assert.notEqual(result.status, 0, `variant ${index}: ${result.stdout}`);
    assert(!fs.existsSync(log), `variant ${index} launched a tool`);
    assert(!fs.existsSync(evidence), `variant ${index} wrote evidence`);
  });
});
test('preflight never overwrites input or existing receipts, and failed reruns clearly reject stale evidence', () => {
  const dir = fs.mkdtempSync(path.join(scratch, 'exclusive-'));
  const verification = path.join(dir, 'anko.json');
  const bytes = JSON.stringify(record);
  fs.writeFileSync(verification, bytes);
  const same = run(['--opt-in', '--anko-verification', verification, '--evidence', verification]);
  assert.notEqual(same.status, 0);
  assert.equal(fs.readFileSync(verification, 'utf8'), bytes);
  const evidence = path.join(dir, 'receipt.json');
  const args = ['--opt-in', '--anko-verification', verification, '--evidence', evidence];
  assert.equal(run(args).status, 0);
  const receipt = fs.readFileSync(evidence, 'utf8');
  assert.notEqual(run(args).status, 0, 'a passing rerun cannot replace a receipt');
  const invalid = structuredClone(record); invalid.checks.restore = false;
  fs.writeFileSync(verification, JSON.stringify(invalid));
  const failed = run(args);
  assert.notEqual(failed.status, 0);
  assert.match(failed.stderr, /existing evidence.*not.*current|fresh.*evidence/i);
  assert.equal(fs.readFileSync(evidence, 'utf8'), receipt);
});
test('documented main Compose local-browser override is executable without loosening production defaults', () => {
  const doc = fs.readFileSync(path.join(root, 'docs/PRIVATE_VM_MIGRATION.md'), 'utf8');
  const origins = doc.match(/export OMP_CORS_ALLOWED_ORIGINS='([^']+)'/);
  assert(origins, 'document an explicit exact-origin local-browser command');
  assert.equal(origins[1], 'http://localhost:3000,http://127.0.0.1:3000');
  const render = value => spawnSync('docker', ['compose', '--env-file', '/dev/null', '-f', path.join(root, 'docker-compose.yml'), 'config', '--format', 'json'], {
    encoding: 'utf8', env: { PATH: process.env.PATH, HOME: process.env.HOME,
      ...(value === undefined ? {} : { OMP_CORS_ALLOWED_ORIGINS: value }) },
  });
  for (const [value, expected] of [[undefined, ''], [origins[1], origins[1]]]) {
    const result = render(value);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(JSON.parse(result.stdout).services.backend.environment.OMP_CORS_ALLOWED_ORIGINS, expected);
  }
});
test('main compose forwards explicit browser endpoints and defaults to private storage/bindings', () => {
  const result = spawnSync('docker', ['compose', '--env-file', '/dev/null', '-f', path.join(root, 'docker-compose.yml'), 'config', '--format', 'json'], {
    encoding: 'utf8', env: { PATH: process.env.PATH, HOME: process.env.HOME,
      MINIO_PUBLIC_ENDPOINT: 'https://media.example.test:9444', OMP_CORS_ALLOWED_ORIGINS: 'https://ui.example.test' },
  });
  assert.equal(result.status, 0, result.stderr);
  const { services } = JSON.parse(result.stdout);
  assert.equal(services.backend.environment.MINIO_PUBLIC_ENDPOINT, 'https://media.example.test:9444');
  assert.equal(services.backend.environment.OMP_CORS_ALLOWED_ORIGINS, 'https://ui.example.test');
  for (const service of Object.values(services)) for (const port of service.ports || []) {
    assert.equal(port.host_ip, '127.0.0.1');
  }
  const init = services['minio-init'].entrypoint.join(' ');
  assert.match(init, /anonymous set none/);
  assert(!/anonymous set download/.test(init));
  assert(!/exit 0/.test(init));
});

test('main Compose keeps internal services loopback when application bindings and local ports change', async t => {
  const ports = { SERVER_PORT: '18080', POSTGRES_PORT: '15434', REDIS_PORT: '16380',
    MINIO_PORT: '19000', MINIO_CONSOLE_PORT: '19001', HTTP_PORT: '18081', HTTPS_PORT: '18443' };
  const expected = { backend: [[8080, ports.SERVER_PORT]], postgres: [[5432, ports.POSTGRES_PORT]],
    redis: [[6379, ports.REDIS_PORT]], minio: [[9000, ports.MINIO_PORT], [9001, ports.MINIO_CONSOLE_PORT]],
    nginx: [[80, ports.HTTP_PORT], [443, ports.HTTPS_PORT]] };
  for (const bind of ['0.0.0.0', '198.51.100.24']) await t.test(bind, () => {
    const result = spawnSync('docker', ['compose', '--env-file', '/dev/null', '-f',
      path.join(root, 'docker-compose.yml'), '--profile', 'production', 'config', '--format', 'json'], {
      encoding: 'utf8', env: { PATH: process.env.PATH, HOME: process.env.HOME,
        COMPOSE_DISABLE_ENV_FILE: 'true', DOCKER_HOST: 'unix:///nonexistent-soundq-config-only.sock',
        OMP_BIND_ADDRESS: bind, ...ports },
    });
    assert.equal(result.status, 0, result.stderr);
    const { services } = JSON.parse(result.stdout);
    t.diagnostic(JSON.stringify({ bind, ports: Object.fromEntries(Object.keys(expected).map(name => [name, services[name].ports])) }));
    for (const [name, mappings] of Object.entries(expected)) {
      assert.deepEqual(services[name].ports.map(p => [p.target, p.published]), mappings, `${name} port overrides preserved`);
      for (const port of services[name].ports) assert.equal(port.host_ip,
        ['backend', 'nginx'].includes(name) ? bind : '127.0.0.1', `${name} host binding`);
    }
  });
});
test('preflight fails closed until opt-in and Anko verified inputs, writes local evidence only', () => {
  const verification = path.join(scratch, 'anko.json');
  const evidence = path.join(scratch, 'evidence.json');
  fs.writeFileSync(verification, JSON.stringify(record));
  const args = ['--anko-verification', verification, '--evidence', evidence];
  assert.notEqual(run(args).status, 0);
  assert(!fs.existsSync(evidence));
  const result = run(['--opt-in', ...args]);
  assert.equal(result.status, 0, result.stderr);
  const output = JSON.parse(fs.readFileSync(evidence));
  assert.equal(output.endpoints.apiBaseUrl, 'https://api.example.test:9443/music/api/v1');
  assert.equal(output.cutover, 'HELD');
  assert.equal(output.liveVerifiedByScript, false);
  for (const [index, mutate] of [r => r.approvedBy = 'other', r => r.checks.restore = false,
    r => delete r.inputs.OMP_HEALTH_URL, r => r.inputs.MINIO_PUBLIC_ENDPOINT += '/prefix',
    r => r.inputs.OMP_CORS_ALLOWED_ORIGINS = ['*'], r => delete r.inputs.OMP_BUILD_ID].entries()) {
    const invalid = structuredClone(record); mutate(invalid);
    fs.writeFileSync(verification, JSON.stringify(invalid));
    const invalidEvidence = path.join(scratch, `invalid-preflight-${index}.json`);
    assert.notEqual(run(['--opt-in', '--anko-verification', verification, '--evidence', invalidEvidence]).status, 0);
    assert(!fs.existsSync(invalidEvidence));
  }
});

test('dogfood refuses a missing or invalid API value before creating evidence or building', () => {
  const bin = path.join(scratch, 'bin'); fs.mkdirSync(bin);
  fs.writeFileSync(path.join(bin, 'flutter'), '#!/bin/sh\nexit 97\n', { mode: 0o755 });
  for (const value of ['', 'ftp://host.test/api', 'https://host.test/api?x=1']) {
    const evidence = path.join(scratch, 'dogfood-' + value.length);
    const result = spawnSync('bash', [path.join(root, 'scripts/dogfood-android'), 'build'], {
      encoding: 'utf8', env: { ...process.env, PATH: bin + ':' + process.env.PATH, OMP_API_BASE_URL: value, OMP_DOGFOOD_EVIDENCE_DIR: evidence },
    });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /OMP_API_BASE_URL/);
    assert(!fs.existsSync(evidence));
  }
});

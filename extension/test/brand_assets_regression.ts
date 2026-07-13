declare const __dirname: string;
declare function require(module: string): any;

const assert = require('assert').strict;
const { existsSync, readFileSync } = require('fs');
const { join } = require('path');

const root = join(__dirname, '..', '..', '..');
const targets: Record<string, number> = {
  'assets/icon-16.png': 16,
  'assets/icon-48.png': 48,
  'assets/icon-128.png': 128,
  'icons/icon16.png': 16,
  'icons/icon48.png': 48,
  'icons/icon128.png': 128,
};

for (const [relative, size] of Object.entries(targets)) {
  const path = join(root, 'dist', relative);
  const source = join(root, relative);
  assert.ok(existsSync(path), `missing extension output ${relative}`);
  const bytes = readFileSync(path);
  assert.deepEqual(bytes, readFileSync(source), `${relative} differs from source asset`);
  assert.deepEqual([...bytes.subarray(0, 8)], [137, 80, 78, 71, 13, 10, 26, 10]);
  assert.equal(bytes.readUInt32BE(16), size, `${relative} width`);
  assert.equal(bytes.readUInt32BE(20), size, `${relative} height`);
}

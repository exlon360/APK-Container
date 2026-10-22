// SPDX-License-Identifier: GPL-2.0-or-later
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { execFileSync, spawnSync } from 'node:child_process';
import { hashFile } from '../../bridge/lib/backup.mjs';

const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const installer = path.join(repository, 'bridge/scripts/install-skill.mjs');
const source = path.join(repository, 'skills/apk');
function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'apk-installer-test-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const home = path.join(root, 'home'), codex = path.join(root, 'codex'), target = path.join(codex, 'skills/apk');
  fs.mkdirSync(home); fs.mkdirSync(target, { recursive: true });
  fs.writeFileSync(path.join(target, 'SKILL.md'), 'Existing customized skill\n', { mode: 0o640 });
  fs.writeFileSync(path.join(target, 'personal-extra.txt'), 'Keep this extra file\n');
  const env = { ...process.env, HOME: home, CODEX_HOME: codex };
  return { root, target, env, backups: path.join(home, '.codex/backups/pre-prompt') };
}
function manifests(backups) { return fs.readdirSync(backups).map(name => JSON.parse(fs.readFileSync(path.join(backups, name, 'manifest.json')))); }

test('skill installer verifies the old customized skill before overwrite and preserves extras', t => {
  const { target, env, backups } = fixture(t);
  const output = execFileSync(process.execPath, [installer, source], { env, encoding: 'utf8' });
  assert.match(output, /Verified checkpoint/);
  assert.equal(hashFile(path.join(target, 'SKILL.md')), hashFile(path.join(source, 'SKILL.md')));
  assert.equal(hashFile(path.join(target, 'scripts/apk.sh')), hashFile(path.join(source, 'scripts/apk.sh')));
  assert.equal(fs.readFileSync(path.join(target, 'personal-extra.txt'), 'utf8'), 'Keep this extra file\n');
  const saved = manifests(backups); assert.equal(saved.length, 1); assert.equal(saved[0].verified, true);
  assert.equal(saved[0].entries[0].original, target);
  const copy = saved[0].entries[0].copied;
  assert.equal(fs.readFileSync(path.join(copy, 'SKILL.md'), 'utf8'), 'Existing customized skill\n');
  assert.equal(fs.statSync(path.join(copy, 'SKILL.md')).mode & 0o777, 0o640);
  assert.equal(fs.readFileSync(path.join(copy, 'personal-extra.txt'), 'utf8'), 'Keep this extra file\n');
  const again = execFileSync(process.execPath, [installer, source], { env, encoding: 'utf8' });
  assert.match(again, /already installed/); assert.equal(manifests(backups).length, 1);
});

test('skill installer refuses overwrite when its checkpoint destination cannot be created', t => {
  const { target, env, backups } = fixture(t);
  fs.mkdirSync(path.dirname(backups), { recursive: true }); fs.writeFileSync(backups, 'not a directory');
  const result = spawnSync(process.execPath, [installer, source], { env, encoding: 'utf8' });
  assert.notEqual(result.status, 0);
  assert.equal(fs.readFileSync(path.join(target, 'SKILL.md'), 'utf8'), 'Existing customized skill\n');
  assert.equal(fs.readFileSync(path.join(target, 'personal-extra.txt'), 'utf8'), 'Keep this extra file\n');
});

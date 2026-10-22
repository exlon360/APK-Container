#!/usr/bin/env node
// SPDX-License-Identifier: GPL-2.0-or-later
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { checkpointPaths, hashFile } from '../lib/backup.mjs';

function contents(root) {
  if (!fs.existsSync(root)) return null;
  const found = {};
  function walk(file, relative) {
    const stat = fs.lstatSync(file);
    if (stat.isSymbolicLink()) found[relative] = { type: 'link', target: fs.readlinkSync(file) };
    else if (stat.isDirectory()) {
      found[relative] = { type: 'directory' };
      for (const name of fs.readdirSync(file).sort()) walk(path.join(file, name), `${relative}/${name}`);
    } else if (stat.isFile()) found[relative] = { type: 'file', sha256: hashFile(file), executable: Boolean(stat.mode & 0o111) };
    else throw new Error('Unsupported file in skill.');
  }
  walk(root, '.'); return found;
}
try {
  const source = path.resolve(process.argv[2] || '');
  const destination = path.join(process.env.CODEX_HOME || path.join(os.homedir(), '.codex'), 'skills/apk');
  if (!fs.existsSync(path.join(source, 'SKILL.md'))) throw new Error('Bundled APK skill is missing.');
  const expected = contents(source), original = contents(destination);
  const current = original && Object.entries(expected).every(([key, value]) => JSON.stringify(original[key]) === JSON.stringify(value));
  if (current) console.log('APK skill is already installed.');
  else {
    const checkpoint = checkpointPaths([destination], { label: 'apk-skill-install', summary: 'Install the APK Container /apk skill' });
    fs.mkdirSync(path.dirname(destination), { recursive: true });
    execFileSync('/usr/bin/ditto', ['--rsrc', '--extattr', '--acl', source, destination]);
    const installed = contents(destination);
    for (const [key, value] of Object.entries(expected)) if (JSON.stringify(installed[key]) !== JSON.stringify(value)) throw new Error('Installed skill verification failed.');
    console.log(`Installed /apk. Verified checkpoint: ${checkpoint}`);
  }
} catch (error) { console.error(error.message); process.exitCode = 1; }

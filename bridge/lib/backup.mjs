// SPDX-License-Identifier: GPL-2.0-or-later
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';

export function hashFile(file) {
  const hash = crypto.createHash('sha256');
  const fd = fs.openSync(file, 'r');
  try {
    const bytes = Buffer.allocUnsafe(1024 * 1024);
    let length;
    while ((length = fs.readSync(fd, bytes, 0, bytes.length, null))) hash.update(bytes.subarray(0, length));
  } finally { fs.closeSync(fd); }
  return hash.digest('hex');
}
export function privateDirectory(directory) { fs.mkdirSync(directory, { recursive: true, mode: 0o700 }); }
export function atomicJSON(file, value) {
  privateDirectory(path.dirname(file));
  const temporary = `${file}.${crypto.randomUUID()}.tmp`;
  fs.writeFileSync(temporary, JSON.stringify(value, null, 2) + '\n', { mode: 0o600, flag: 'wx' });
  fs.renameSync(temporary, file);
  fs.chmodSync(file, 0o600);
}
function metadata(file) {
  const stat = fs.lstatSync(file, { bigint: true });
  const entry = {
    type: stat.isSymbolicLink() ? 'symlink' : stat.isDirectory() ? 'directory' : 'file',
    mode: Number(stat.mode & 0o7777n), uid: Number(stat.uid), gid: Number(stat.gid),
    mtimeNS: stat.mtimeNs.toString(),
  };
  if (stat.isSymbolicLink()) entry.target = fs.readlinkSync(file);
  else if (stat.isFile()) { entry.bytes = Number(stat.size); entry.sha256 = hashFile(file); }
  else if (!stat.isDirectory()) throw new Error(`Unsupported special file in checkpoint: ${file}`);
  if (process.platform === 'darwin') {
    entry.xattrsSHA256 = crypto.createHash('sha256').update(execFileSync('/usr/bin/xattr', ['-s', '-lx', file])).digest('hex');
    entry.acl = execFileSync('/bin/ls', ['-lde', file], { encoding: 'utf8' }).split('\n').slice(1).join('\n');
  }
  return entry;
}
function inventory(root) {
  const entries = {};
  function visit(file, relative) {
    const value = metadata(file); entries[relative] = value;
    if (value.type === 'directory') for (const name of fs.readdirSync(file).sort()) visit(path.join(file, name), relative === '.' ? name : `${relative}/${name}`);
  }
  visit(root, '.'); return entries;
}
function equivalent(left, right) {
  if (Object.keys(left).join('\n') !== Object.keys(right).join('\n')) return false;
  return Object.keys(left).every(key => {
    const a = { ...left[key] }, b = { ...right[key] };
    const delta = BigInt(a.mtimeNS) - BigInt(b.mtimeNS);
    delete a.mtimeNS; delete b.mtimeNS;
    return delta >= -1000n && delta <= 1000n && JSON.stringify(a) === JSON.stringify(b);
  });
}

/** A real, verified checkpoint precedes every submitted build/edit request. */
export function checkpointPaths(paths, { label = 'apk-build', summary = '', backupRoot = path.join(os.homedir(), '.codex/backups/pre-prompt') } = {}) {
  privateDirectory(backupRoot);
  const utc = new Date().toISOString();
  const destination = path.join(backupRoot, `${utc.replace(/[-:.]/g, '')}-${label}-${crypto.randomUUID().slice(0, 8)}`);
  fs.mkdirSync(destination, { mode: 0o700 });
  const record = { host: os.hostname(), utc, request: summary, verified: false, entries: [], metadataNote: 'Exact contents, permissions, owners, symlink targets, ACLs and extended attributes verified. Timestamp comparison permits <=1000ns filesystem rounding; actual values are retained.', restore: 'Inspect originals for newer work first. Deliberately restore selected copies with ditto --rsrc --extattr --acl. Do not automatically restore previous app progress. Codex conversation history is append-only and is not rewound by this project checkpoint.' };
  try {
    for (const [index, originalValue] of paths.entries()) {
      const original = path.resolve(originalValue);
      if (!fs.existsSync(original) && !fs.lstatSync(original, { throwIfNoEntry: false })) { record.entries.push({ original, existed: false }); continue; }
      const copied = path.join(destination, 'copies', String(index));
      privateDirectory(path.dirname(copied));
      const before = inventory(original);
      if (process.platform === 'darwin') execFileSync('/usr/bin/ditto', ['--rsrc', '--extattr', '--acl', original, copied]);
      else fs.cpSync(original, copied, { recursive: true, preserveTimestamps: true, dereference: false });
      // ditto preserves link targets and metadata, but creates symlinks with a new
      // modification time. Restore link timestamps without following the target.
      for (const [relative, entry] of Object.entries(before)) if (entry.type === 'symlink') {
        const sourceLink = relative === '.' ? original : path.join(original, relative);
        const savedLink = relative === '.' ? copied : path.join(copied, relative);
        const stat = fs.lstatSync(sourceLink, { bigint: true });
        fs.lutimesSync(savedLink, Number(stat.atimeNs) / 1e9, Number(stat.mtimeNs) / 1e9);
      }
      const after = inventory(original), saved = inventory(copied);
      if (!equivalent(before, after) || !equivalent(after, saved)) { record.verificationFailure = { original, before, after, saved }; throw new Error(`Checkpoint verification failed for ${original}`); }
      record.entries.push({ original, copied, existed: true, originalMetadata: after, savedMetadata: saved });
    }
    record.verified = true;
    atomicJSON(path.join(destination, 'manifest.json'), record);
    return destination;
  } catch (error) {
    record.failure = error.message;
    atomicJSON(path.join(destination, 'manifest.json'), record);
    throw new Error(`No files were changed for this request: backup could not be verified (${error.message}). Checkpoint: ${destination}`);
  }
}

// SPDX-License-Identifier: GPL-2.0-or-later
// No inference or user Codex state: turn/start is validated using a nonexistent thread.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import assert from 'node:assert/strict';
import { CodexConnection } from '../../bridge/lib/codex.mjs';
import { discoverCodex } from '../../bridge/lib/profile.mjs';

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'apk-codex-protocol-'));
const project = path.join(root, 'app'), codexHome = path.join(root, 'codex');
fs.mkdirSync(project); fs.mkdirSync(codexHome, { mode: 0o700 });
const skillPath = path.join(codexHome, 'skills/apk/SKILL.md');
fs.mkdirSync(path.dirname(skillPath), { recursive: true });
fs.writeFileSync(skillPath, '---\nname: apk\ndescription: APK protocol fixture\n---\nProtocol fixture only.\n');
const env = { ...process.env, CODEX_HOME: codexHome };
delete env.CODEX_THREAD_ID; delete env.CODEX_SESSION_ID;
const connection = new CodexConnection(discoverCodex(), { cwd: project, env });
let passed = false;
try {
  await connection.start();
  const started = await connection.request('thread/start', { cwd: project, approvalPolicy: 'on-request', sandbox: 'workspace-write', serviceName: 'apk_container_bridge_smoke' }, 30000);
  assert.equal(typeof started.thread.id, 'string');
  await connection.request('thread/name/set', { threadId: started.thread.id, name: 'APK bridge protocol fixture' }, 30000);
  const resumed = await connection.request('thread/resume', { threadId: started.thread.id, cwd: project, approvalPolicy: 'on-request', sandbox: 'workspace-write', excludeTurns: true }, 30000);
  assert.equal(resumed.thread.id, started.thread.id);
  const models = await connection.request('model/list', {}, 30000);
  assert.ok(Array.isArray(models.data));
  await assert.rejects(connection.request('turn/start', {
    threadId: '00000000-0000-4000-8000-000000000000',
    clientUserMessageId: '00000000-0000-4000-8000-000000000001',
    input: [{ type: 'text', text: 'Protocol validation only; this thread does not exist.' }, { type: 'skill', name: 'apk', path: skillPath }],
    cwd: project, approvalPolicy: 'on-request',
    sandboxPolicy: { type: 'workspaceWrite', writableRoots: [project], networkAccess: true }
  }, 30000), /thread.*not found|no thread|unknown thread|thread.*does not exist/i);
  console.log('Codex protocol smoke passed: real stdio initialize, thread/start, naming, resume, model/list, and turn/start schema validation; isolated CODEX_HOME; no inference turn.');
  passed = true;
} finally {
  connection.close();
  // Allow the owned child to release files before deleting this disposable fixture.
  await new Promise(resolve => setTimeout(resolve, 300));
  if (passed) fs.rmSync(root, { recursive: true, force: true });
  else console.error(`Protocol diagnostic fixture retained at ${root}`);
}

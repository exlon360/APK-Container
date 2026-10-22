// SPDX-License-Identifier: GPL-2.0-or-later
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import https from 'node:https';
import crypto from 'node:crypto';
import { EventEmitter } from 'node:events';
import { execFileSync } from 'node:child_process';
import { initialize, pair, profile, exportProfile, readConfiguration } from '../../bridge/lib/profile.mjs';
import { BridgeService, verifyAPK, buildPrompt } from '../../bridge/lib/service.mjs';
import { checkpointPaths, hashFile } from '../../bridge/lib/backup.mjs';
import { startHTTPS } from '../../bridge/lib/server.mjs';

function sandbox(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'apk-bridge-test-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  return directory;
}
function config(t) {
  const root = sandbox(t);
  return initialize({ stateDir: path.join(root, 'state'), projectsDir: path.join(root, 'apps'), backupRoot: path.join(root, 'backups'), url: 'https://localhost:48152', codexPath: '/test/codex' });
}
function apk(file, content = 'example') {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  execFileSync('/usr/bin/python3', ['-c', 'import sys,zipfile\nwith zipfile.ZipFile(sys.argv[1],"w") as z:\n z.writestr("AndroidManifest.xml",sys.argv[2])\n z.writestr("classes.dex", "fixture")', file, content]);
}
class MockCodex extends EventEmitter {
  ready = false; calls = []; responses = []; counter = 0;
  async start() { this.ready = true; }
  async request(method, params) {
    this.calls.push({ method, params });
    if (method === 'thread/start') return { thread: { id: `thread-${++this.counter}` } };
    if (method === 'turn/start') return { turn: { id: `turn-${++this.counter}`, status: 'inProgress' } };
    return {};
  }
  respond(id, result) { this.responses.push({ id, result }); }
  reject(id, message) { this.responses.push({ id, error: message }); }
  close() { this.ready = false; }
}
async function settle() { await new Promise(resolve => setImmediate(resolve)); }
function serviceFor(t, options = {}) {
  const c = config(t); pair(c.stateDir); const rpc = new MockCodex();
  const service = new BridgeService(c, { connection: rpc, skillPath: null, ...options }); t.after(() => service.close());
  return { c, rpc, service };
}

test('private pairing profile, stable setup, verified exports, no tokens in public status', t => {
  const c = config(t), original = readConfiguration(c.stateDir);
  assert.equal(c.token.length, 64); assert.match(c.certificateSHA256, /^[a-f0-9]{64}$/);
  const stable = initialize({ stateDir: c.stateDir }); assert.equal(stable.token, original.token);
  assert.equal(fs.statSync(path.join(c.stateDir, 'configuration.json')).mode & 0o777, 0o600);
  assert.equal(fs.statSync(path.join(c.stateDir, 'bridge-key.pem')).mode & 0o777, 0o600);
  const exported = path.join(path.dirname(c.stateDir), 'exported.prf');
  exportProfile(c.stateDir, exported); assert.deepEqual(JSON.parse(fs.readFileSync(exported)), profile(c));
  const cert = new crypto.X509Certificate(fs.readFileSync(path.join(c.stateDir, 'bridge-cert.pem')));
  assert.equal(crypto.createHash('sha256').update(cert.raw).digest('hex'), c.certificateSHA256);
  const service = new BridgeService(c, { connection: new MockCodex() });
  assert.equal(service.status().paired, false); assert.equal(service.status().token, undefined);
  assert.throws(() => service.create('Test'), /Run \/apk/);
  pair(c.stateDir); assert.equal(service.status().paired, true);
  assert.equal(JSON.stringify(service.status()).includes(c.token), false); service.close();
});

test('checkpoint verifies contents, permissions and symlink; existing source is preserved', t => {
  const root = sandbox(t), original = path.join(root, 'app'); fs.mkdirSync(original);
  fs.writeFileSync(path.join(original, 'code.txt'), 'original', { mode: 0o640 });
  fs.symlinkSync('code.txt', path.join(original, 'link'));
  const checkpoint = checkpointPaths([original, path.join(root, 'future')], { backupRoot: path.join(root, 'backups'), summary: 'test' });
  const manifest = JSON.parse(fs.readFileSync(path.join(checkpoint, 'manifest.json')));
  assert.equal(manifest.verified, true); assert.equal(manifest.entries[1].existed, false);
  const copied = manifest.entries[0].copied;
  assert.equal(hashFile(path.join(copied, 'code.txt')), hashFile(path.join(original, 'code.txt')));
  assert.equal(fs.readlinkSync(path.join(copied, 'link')), 'code.txt');
  assert.equal(fs.statSync(path.join(copied, 'code.txt')).mode & 0o777, 0o640);
});

test('first and followup prompts remain hidden from device transcript; project identity and thread persist', async t => {
  const { service, rpc } = serviceFor(t);
  const project = service.create('../My app');
  assert.equal(path.basename(service.workspace(project)), project.id);
  service.submit(project.id, 'Make a notes app'); await settle();
  assert.equal(project.messages[0].text, 'Make a notes app');
  assert.equal(project.messages.length, 1);
  const first = rpc.calls.find(c => c.method === 'turn/start').params;
  assert.match(first.input[0].text, /build an APK file for Android 16 and LineageOS/);
  assert.equal(first.model, undefined); assert.equal(first.approvalPolicy, 'on-request');
  assert.equal(first.sandboxPolicy.type, 'workspaceWrite');
  assert.match(project.request.checkpoint, /apk-app-prompt/);
  assert.throws(() => service.submit(project.id, 'duplicate'), /already building/);
  await service.notification({ method: 'turn/completed', params: { threadId: project.threadID, turn: { id: project.activeTurnID, status: 'completed' } } });
  assert.equal(project.status, 'completed'); assert.equal(project.summary, null); assert.equal(project.artifacts.length, 0);
  const previousThread = project.threadID;
  service.submit(project.id, 'Add colors'); await settle();
  assert.equal(project.threadID, previousThread);
  assert.match(rpc.calls.filter(c => c.method === 'turn/start').at(-1).params.input[0].text, /edit or update the app/);
  assert.equal(rpc.calls.filter(c => c.method === 'thread/start').length, 1);
  assert.throws(() => service.get('../../state'), /not found/);
});

test('failed backup prevents transcript and app mutation before Codex starts', t => {
  const { service, rpc } = serviceFor(t);
  const project = service.create('Test');
  service.checkpoint = () => { throw new Error('backup failed'); };
  assert.throws(() => service.submit(project.id, 'hello'), /backup failed/);
  assert.equal(project.messages.length, 0); assert.equal(project.status, 'idle'); assert.equal(rpc.calls.length, 0);
});

test('real build requests attach the paired /apk skill and reject a missing installation', async t => {
  const root = sandbox(t), skillPath = path.join(root, 'skills/apk/SKILL.md');
  const { service, rpc } = serviceFor(t, { skillPath }), project = service.create('App');
  assert.throws(() => service.submit(project.id, 'Build'), /\/apk skill is missing/);
  assert.equal(project.messages.length, 0); assert.equal(rpc.calls.length, 0);
  fs.mkdirSync(path.dirname(skillPath), { recursive: true }); fs.writeFileSync(skillPath, 'APK fixture');
  service.submit(project.id, 'Build'); await settle();
  const input = rpc.calls.find(c => c.method === 'turn/start').params.input;
  assert.deepEqual(input[1], { type: 'skill', name: 'apk', path: skillPath });
  assert.match(input[0].text, /package ID, signing key/);
  assert.equal(project.messages[0].text, 'Build');
});

test('streamed visible reply, explicit approval/input and immutable verified artifact delivery', async t => {
  const { service, rpc } = serviceFor(t), project = service.create('Notes');
  service.submit(project.id, 'Create notes'); await settle();
  const threadId = project.threadID, turnId = project.activeTurnID;
  await service.notification({ method: 'item/agentMessage/delta', params: { threadId, turnId, itemId: 'reply', delta: 'Features\n' } });
  await service.notification({ method: 'item/agentMessage/delta', params: { threadId, turnId, itemId: 'reply', delta: 'Notes and search.' } });
  assert.equal(project.messages.at(-1).text, 'Features\nNotes and search.');
  service.serverRequest({ id: 31, method: 'item/commandExecution/requestApproval', params: { threadId, turnId, command: './gradlew assembleDebug', reason: 'Build the APK' } });
  assert.equal(project.status, 'awaitingApproval'); assert.equal(rpc.responses.length, 0);
  const approval = project.approvals[0]; service.answer(project.id, approval.id, { decision: 'accept' });
  assert.deepEqual(rpc.responses[0], { id: 31, result: { decision: 'accept' } });
  assert.equal(project.status, 'building');
  service.serverRequest({ id: 32, method: 'item/tool/requestUserInput', params: { threadId, turnId, questions: [{ id: 'theme', question: 'Color?', options: [] }] } });
  assert.throws(() => service.answer(project.id, project.approvals[0].id, { decision: 'accept', answers: {} }), /Answer every question/);
  service.answer(project.id, project.approvals[0].id, { decision: 'accept', answers: { theme: ['Blue'] } });
  assert.deepEqual(rpc.responses[1].result, { answers: { theme: { answers: ['Blue'] } } });
  const dist = path.join(service.workspace(project), 'dist'); apk(path.join(dist, 'notes.apk'));
  fs.writeFileSync(path.join(dist, 'build-report.json'), JSON.stringify({ requestID: project.request.id, features: ['Notes'], issues: ['Not device tested'], ideas: ['Sync'] }));
  await service.notification({ method: 'turn/completed', params: { threadId, turn: { id: turnId, status: 'completed' } } });
  assert.equal(project.summary.kind, 'created'); assert.deepEqual(project.summary.features, ['Notes']); assert.equal(project.artifacts.length, 1);
  const delivered = service.artifact(project.id, project.artifacts[0].id);
  assert.equal(delivered.sha256, hashFile(delivered.file)); assert.equal(service.publicProject(project).artifacts[0].file, undefined);
  fs.writeFileSync(path.join(dist, 'notes.apk'), 'changed source');
  assert.equal(hashFile(delivered.file), delivered.sha256, 'Published build must remain immutable');
});

test('stale APK and failed/interrupt turns never produce a completion card; followups can publish edits', async t => {
  const { service } = serviceFor(t), project = service.create('App'), dist = path.join(service.workspace(project), 'dist');
  apk(path.join(dist, 'old.apk'));
  service.submit(project.id, 'Explain the app'); await settle();
  await service.notification({ method: 'turn/completed', params: { threadId: project.threadID, turn: { id: project.activeTurnID, status: 'completed' } } });
  assert.equal(project.artifacts.length, 0); assert.equal(project.summary, null);
  service.submit(project.id, 'Build it'); await settle(); apk(path.join(dist, 'new.apk'), 'new');
  await service.notification({ method: 'turn/completed', params: { threadId: project.threadID, turn: { id: project.activeTurnID, status: 'failed', error: { message: 'compiler failed' } } } });
  assert.equal(project.artifacts.length, 0); assert.equal(project.error, 'compiler failed');
  service.submit(project.id, 'Try again'); await settle(); apk(path.join(dist, 'new.apk'), 'rebuilt');
  await service.notification({ method: 'turn/completed', params: { threadId: project.threadID, turn: { id: project.activeTurnID, status: 'completed' } } });
  assert.equal(project.summary.kind, 'created');
  service.submit(project.id, 'Edit the theme'); await settle(); apk(path.join(dist, 'new.apk'), 'theme');
  await service.notification({ method: 'turn/completed', params: { threadId: project.threadID, turn: { id: project.activeTurnID, status: 'completed' } } });
  assert.equal(project.summary.kind, 'edited'); assert.equal(project.artifacts.length, 2);
});

test('malformed APK and symlink paths cannot be published', t => {
  const root = sandbox(t), file = path.join(root, 'fake.apk'); fs.writeFileSync(file, 'PK fake');
  assert.throws(() => verifyAPK(file));
  apk(file); const link = path.join(root, 'linked.apk'); fs.symlinkSync(file, link);
  assert.throws(() => verifyAPK(link));
  assert.equal(verifyAPK(file).sha256, hashFile(file));
});

test('touching an unchanged APK needs a build report bound to this request', async t => {
  const { service } = serviceFor(t), project = service.create('App'), dist = path.join(service.workspace(project), 'dist'), file = path.join(dist, 'app.apk');
  apk(file);
  const touch = () => { const date = new Date(fs.statSync(file).mtimeMs + 1000); fs.utimesSync(file, date, date); };
  const finish = () => service.notification({ method: 'turn/completed', params: { threadId: project.threadID, turn: { id: project.activeTurnID, status: 'completed' } } });
  service.submit(project.id, 'Build'); await settle(); touch();
  fs.writeFileSync(path.join(dist, 'build-report.json'), JSON.stringify({ requestID: 'old-request', features: ['Stale report'] }));
  await finish(); assert.equal(project.artifacts.length, 0); assert.equal(project.summary, null);
  service.submit(project.id, 'Rebuild unchanged app'); await settle(); touch();
  fs.writeFileSync(path.join(dist, 'build-report.json'), JSON.stringify({ requestID: project.request.id, features: ['Verified rebuild'] }));
  await finish(); assert.equal(project.artifacts.length, 1); assert.deepEqual(project.summary.features, ['Verified rebuild']);
});

test('stop during thread creation never launches an invisible inference turn', async t => {
  const { service, rpc } = serviceFor(t), project = service.create('App');
  const original = rpc.request.bind(rpc); let release;
  rpc.request = async (method, params) => method === 'thread/start' ? await new Promise(resolve => { release = resolve; }) : original(method, params);
  service.submit(project.id, 'Build'); await settle(); await service.interrupt(project.id);
  release({ thread: { id: 'thread-stopped' } }); await settle();
  assert.equal(project.status, 'interrupted'); assert.equal(project.threadID, 'thread-stopped');
  assert.equal(rpc.calls.some(c => c.method === 'turn/start'), false);
  assert.equal(service.launching.size, 0);
});

test('stop before turn/start returns interrupts its eventual turn and refuses stale approvals', async t => {
  const { service, rpc } = serviceFor(t), project = service.create('App');
  const original = rpc.request.bind(rpc); let release;
  rpc.request = async (method, params) => method === 'turn/start' ? await new Promise(resolve => { release = resolve; }) : original(method, params);
  service.submit(project.id, 'Build'); await settle();
  const threadId = project.threadID, turnId = 'turn-stopped';
  service.serverRequest({ id: 41, method: 'item/commandExecution/requestApproval', params: { threadId, turnId, command: 'build' } });
  await service.interrupt(project.id);
  assert.throws(() => service.submit(project.id, 'Too early'), /already building or stopping/);
  release({ turn: { id: turnId } }); await settle();
  assert.equal(project.status, 'interrupted'); assert.equal(project.activeTurnID, null);
  assert.ok(rpc.calls.some(c => c.method === 'turn/interrupt' && c.params.turnId === turnId));
  assert.ok(rpc.responses.some(c => c.id === 41 && c.error));
  apk(path.join(service.workspace(project), 'dist', 'late.apk'));
  await service.notification({ method: 'turn/completed', params: { threadId, turn: { id: turnId, status: 'completed' } } });
  assert.equal(project.status, 'interrupted'); assert.equal(project.summary, null); assert.equal(project.artifacts.length, 0);
  assert.equal(service.buffered.size, 0);
});

test('late prior-turn completion cannot overwrite the next build; early current events replay once', async t => {
  const { service, rpc } = serviceFor(t), project = service.create('App');
  service.submit(project.id, 'First'); await settle(); const oldTurn = project.activeTurnID;
  await service.interrupt(project.id);
  const original = rpc.request.bind(rpc); let release;
  rpc.request = async (method, params) => method === 'turn/start' ? await new Promise(resolve => { release = resolve; }) : original(method, params);
  service.submit(project.id, 'Second'); await settle();
  const threadId = project.threadID, turnId = 'new-turn';
  await service.notification({ method: 'turn/completed', params: { threadId, turn: { id: oldTurn, status: 'completed' } } });
  await service.notification({ method: 'item/agentMessage/delta', params: { threadId, turnId, itemId: 'new-reply', delta: 'Current reply' } });
  release({ turn: { id: turnId } }); await settle();
  assert.equal(project.status, 'building'); assert.equal(project.activeTurnID, turnId);
  assert.equal(project.messages.filter(m => m.id === 'agent-new-reply').length, 1);
  assert.equal(project.messages.at(-1).text, 'Current reply');
  await service.notification({ method: 'turn/completed', params: { threadId, turn: { id: oldTurn, status: 'completed' } } });
  assert.equal(project.status, 'building'); assert.equal(project.summary, null);
  await service.notification({ method: 'turn/completed', params: { threadId, turn: { id: turnId, status: 'completed' } } });
  assert.equal(project.status, 'completed');
});

test('failed turn/start drains buffered approval requests and allows retry', async t => {
  const { service, rpc } = serviceFor(t), project = service.create('App');
  const original = rpc.request.bind(rpc); let reject;
  rpc.request = async (method, params) => method === 'turn/start' ? await new Promise((_, fail) => { reject = fail; }) : original(method, params);
  service.submit(project.id, 'Build'); await settle();
  service.serverRequest({ id: 42, method: 'item/commandExecution/requestApproval', params: { threadId: project.threadID, turnId: 'unknown-turn', command: 'build' } });
  reject(new Error('Turn could not start')); await settle();
  assert.equal(project.status, 'failed'); assert.equal(service.buffered.size, 0); assert.equal(service.launching.size, 0);
  assert.ok(rpc.responses.some(c => c.id === 42 && c.error));
  rpc.request = original; service.submit(project.id, 'Try again'); await settle(); assert.equal(project.status, 'building');
});

test('HTTPS transport requires bearer token, rejects browser origins, and exposes no private configuration', async t => {
  const { c, service } = serviceFor(t), server = await startHTTPS(service, { host: '127.0.0.1', port: 0 });
  t.after(() => new Promise(resolve => server.close(resolve)));
  const request = (route, options = {}) => new Promise((resolve, reject) => {
    const req = https.request({ hostname: '127.0.0.1', port: server.address().port, path: route, method: options.method || 'GET', rejectUnauthorized: false, agent: false, headers: options.headers || {} }, response => {
      let data = ''; response.on('data', d => data += d); response.on('end', () => resolve({ status: response.statusCode, data: JSON.parse(data) }));
    }); req.on('error', reject); if (options.body) req.write(options.body); req.end();
  });
  assert.equal((await request('/v1/status')).status, 401);
  assert.equal((await request('/v1/status', { headers: { authorization: `Bearer ${c.token}`, origin: 'https://evil.example' } })).status, 403);
  const status = await request('/v1/status', { headers: { authorization: `Bearer ${c.token}` } });
  assert.equal(status.status, 200); assert.equal(status.data.token, undefined); assert.equal(status.data.paired, true);
  const bad = await request('/v1/projects', { method: 'POST', headers: { authorization: `Bearer ${c.token}`, 'content-type': 'application/json' }, body: '{broken' });
  assert.equal(bad.status, 400);
});

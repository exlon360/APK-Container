// SPDX-License-Identifier: GPL-2.0-or-later
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { atomicJSON, checkpointPaths, hashFile, privateDirectory } from './backup.mjs';
import { readConfiguration, VERSION } from './profile.mjs';
import { CodexConnection } from './codex.mjs';

const ACTIVE = new Set(['building', 'awaitingApproval']);
const UUID = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
const now = () => new Date().toISOString();
export class APIError extends Error { constructor(status, message) { super(message); this.status = status; } }
export function validID(value) { if (!UUID.test(value || '')) throw new APIError(404, 'App project not found.'); return value; }
function limitedText(value, maximum = 20000) {
  if (typeof value !== 'string' || !value.trim() || value.length > maximum) throw new APIError(400, `Enter text between 1 and ${maximum} characters.`);
  return value.trim();
}
function reportList(value) { return Array.isArray(value) ? value.filter(v => typeof v === 'string').slice(0, 30).map(v => v.slice(0, 2000)) : []; }

/** Verify the central directory, not merely an APK-looking extension or PK prefix. */
export function verifyAPK(file) {
  const stat = fs.lstatSync(file);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size < 22 || stat.size > 1024 * 1024 * 1024) throw new Error('APK must be a regular ZIP file smaller than 1 GiB.');
  const fd = fs.openSync(file, 'r');
  try {
    const tail = Buffer.alloc(Math.min(stat.size, 65557));
    fs.readSync(fd, tail, 0, tail.length, stat.size - tail.length);
    let end = -1;
    for (let offset = tail.length - 22; offset >= 0; offset--) if (tail.readUInt32LE(offset) === 0x06054b50 && offset + 22 + tail.readUInt16LE(offset + 20) === tail.length) { end = offset; break; }
    if (end < 0 || tail.readUInt16LE(end + 4) !== 0 || tail.readUInt16LE(end + 6) !== 0) throw new Error('APK ZIP directory is missing or unsupported.');
    const count = tail.readUInt16LE(end + 10), length = tail.readUInt32LE(end + 12), start = tail.readUInt32LE(end + 16);
    if (!count || length > 16 * 1024 * 1024 || start + length > stat.size - tail.length + end) throw new Error('Invalid APK ZIP directory.');
    const directory = Buffer.alloc(length); fs.readSync(fd, directory, 0, length, start);
    let offset = 0, manifest = false;
    for (let entry = 0; entry < count; entry++) {
      if (offset + 46 > length || directory.readUInt32LE(offset) !== 0x02014b50) throw new Error('Truncated APK ZIP directory.');
      const nameLength = directory.readUInt16LE(offset + 28), extraLength = directory.readUInt16LE(offset + 30), commentLength = directory.readUInt16LE(offset + 32);
      if (offset + 46 + nameLength + extraLength + commentLength > length) throw new Error('Truncated APK ZIP entry.');
      const name = directory.subarray(offset + 46, offset + 46 + nameLength).toString('utf8');
      if (name === 'AndroidManifest.xml' && directory.readUInt32LE(offset + 24) > 0) manifest = true;
      offset += 46 + nameLength + extraLength + commentLength;
    }
    if (!manifest) throw new Error('The APK has no AndroidManifest.xml.');
  } finally { fs.closeSync(fd); }
  return { bytes: stat.size, sha256: hashFile(file) };
}
function apkFiles(directory) {
  if (!fs.existsSync(directory)) return [];
  if (fs.lstatSync(directory).isSymbolicLink()) throw new Error('The dist folder must not be a symbolic link.');
  return fs.readdirSync(directory).filter(name => name.toLowerCase().endsWith('.apk')).map(name => path.join(directory, name));
}
export function buildPrompt(project, text, requestID) {
  const first = project.submittedTurns === 0;
  const preamble = first
    ? "We're going to build an APK file for Android 16 and LineageOS. Make it compatible, within supported APIs, with exlon360's fork of Husk, APK Container, and its translation layer. The following prompt will be:"
    : "We're going to edit or update the app we are creating. The following prompt will include:";
  return `${preamble}\n\n${text}\n\nAPK Container build delivery instructions:\n- Work only in this app's project directory unless the user explicitly authorizes another location. A verified pre-request checkpoint has already been created by the bridge. Before changing additional existing state outside that checkpoint, back it up and verify it. Never delete existing checkpoints.\n- Preserve the user's requested app, package ID, signing key, and existing app data through every update. Target Android 16 (API 36) / LineageOS. Prefer standard Android Views and supported Android/Java APIs; use arm64-v8a for native code. Do not require Google Play services unless the request needs them. Translation-layer compatibility must be tested where possible and described honestly; Android runtime fallback may be necessary.\n- Use the Mac's available Android SDK/JDK. Keep new tool downloads and build outputs inside this project; do not modify system tooling or unrelated projects. Build and validate a real, installable, debug-signed APK.\n- Put final APK files directly in dist/. Write dist/build-report.json as JSON with requestID=${JSON.stringify(requestID)} and arrays features, issues, ideas (strings). Each reply should clearly describe Features, Issues, and Ideas; state build/test failures rather than claiming success.\n- Do not include these setup instructions in the conversational reply. The device displays only the user's request and your reply. The bridge creates the completion/download card only after validating a newly built APK.\n`;
}

export class BridgeService {
  constructor(config, { connection, checkpoint = checkpointPaths, skillPath = path.join(connection?.env?.CODEX_HOME || process.env.CODEX_HOME || path.join(os.homedir(), '.codex'), 'skills/apk/SKILL.md') } = {}) {
    this.config = config; this.checkpoint = checkpoint; this.projects = new Map(); this.approvals = new Map(); this.loadedThreads = new Set(); this.saving = new Map(); this.launching = new Map(); this.stopping = new Set(); this.buffered = new Map();
    this.recordsDir = path.join(config.stateDir, 'projects'); privateDirectory(this.recordsDir);
    this.connection = connection || new CodexConnection(config.codexPath, { cwd: config.projectsDir });
    this.skillPath = skillPath;
    for (const file of fs.readdirSync(this.recordsDir).filter(v => v.endsWith('.json'))) {
      const project = JSON.parse(fs.readFileSync(path.join(this.recordsDir, file), 'utf8'));
      validID(project.id);
      // Restarting never pretends the previous turn completed or publishes a stale APK.
      if (ACTIVE.has(project.status)) { project.status = 'interrupted'; project.error = 'The Mac bridge stopped during this request. Send a follow-up to resume the app.'; project.approvals = []; project.activeTurnID = null; }
      this.projects.set(project.id, project);
    }
    this.connection.on('notification', packet => { this.notification(packet).catch(error => this.failByThread(packet.params?.threadId, error)); });
    this.connection.on('request', packet => this.serverRequest(packet));
    this.connection.on('disconnected', error => { this.loadedThreads.clear(); for (const p of this.projects.values()) if (ACTIVE.has(p.status)) this.fail(p, error); });
  }
  configuration() { this.config = { ...this.config, ...readConfiguration(this.config.stateDir) }; return this.config; }
  status() { const c = this.configuration(); return { name: c.name, bridgeID: c.bridgeID, paired: Boolean(c.pairedAt), version: VERSION, codexReady: this.connection.ready }; }
  recordFile(project) { return path.join(this.recordsDir, `${project.id}.json`); }
  workspace(project) { return path.join(this.config.projectsDir, project.id); }
  save(project, deferred = false) {
    project.updatedAt = now();
    if (deferred) {
      if (!this.saving.has(project.id)) this.saving.set(project.id, setTimeout(() => { this.saving.delete(project.id); atomicJSON(this.recordFile(project), project); }, 250));
    } else { clearTimeout(this.saving.get(project.id)); this.saving.delete(project.id); atomicJSON(this.recordFile(project), project); }
  }
  publicProject(project, compact = false) {
    return { id: project.id, name: project.name, status: project.status, createdAt: project.createdAt, updatedAt: project.updatedAt, threadID: project.threadID, messages: compact ? [] : project.messages, artifacts: project.artifacts.map(({ file, ...a }) => a), approvals: project.approvals, summary: project.summary, error: project.error };
  }
  list() { return [...this.projects.values()].sort((a, b) => b.updatedAt.localeCompare(a.updatedAt)).map(p => this.publicProject(p, true)); }
  get(id) { const project = this.projects.get(validID(id)); if (!project) throw new APIError(404, 'App project not found.'); return project; }
  create(name) {
    const c = this.configuration(); if (!c.pairedAt) throw new APIError(409, 'Run /apk on your Mac to pair the build skill first.');
    name = typeof name === 'string' && name.trim() ? limitedText(name, 100) : 'New App';
    const project = { id: crypto.randomUUID(), name, status: 'idle', createdAt: now(), updatedAt: now(), threadID: null, messages: [], artifacts: [], approvals: [], summary: null, error: null, submittedTurns: 0, activeTurnID: null };
    this.checkpoint([this.workspace(project), this.recordFile(project)], { label: 'apk-new-app', summary: `Create app project ${name}`, backupRoot: this.config.backupRoot });
    privateDirectory(this.workspace(project)); this.projects.set(project.id, project); this.save(project); return project;
  }
  message(project, role, text, id = crypto.randomUUID()) { const message = { id, role, text, createdAt: now() }; project.messages.push(message); return message; }
  submit(id, text) {
    const project = this.get(id); text = limitedText(text);
    if (!this.configuration().pairedAt) throw new APIError(409, 'Run /apk on your Mac to pair the build skill first.');
    if (this.skillPath && (!fs.existsSync(this.skillPath) || !fs.statSync(this.skillPath).isFile())) throw new APIError(409, 'The /apk skill is missing on your Mac. Choose Pair Skill /apk in APK Container Bridge to install it.');
    if (this.launching.has(id) || this.stopping.has(id) || ACTIVE.has(project.status)) throw new APIError(409, 'This app is already building or stopping. Answer the pending question or wait for the current request to stop first.');
    // No state or workspace mutation occurs until this checkpoint succeeds.
    const checkpoint = this.checkpoint([this.workspace(project), this.recordFile(project)], { label: 'apk-app-prompt', summary: `Build/edit ${project.name}: ${text.slice(0, 200)}`, backupRoot: this.config.backupRoot });
    const requestID = crypto.randomUUID();
    const baseline = {};
    for (const file of apkFiles(path.join(this.workspace(project), 'dist'))) if (fs.lstatSync(file).isFile() && !fs.lstatSync(file).isSymbolicLink()) baseline[path.basename(file)] = { sha256: hashFile(file), mtimeMS: fs.statSync(file).mtimeMs };
    project.request = { id: requestID, checkpoint, startedAt: now(), baseline, text, hadArtifacts: project.artifacts.length > 0 };
    project.summary = null; project.error = null; project.approvals = []; project.activeTurnID = null; project.status = 'building';
    this.message(project, 'user', text); this.save(project);
    this.launching.set(project.id, requestID);
    this.run(project, buildPrompt(project, text, requestID), requestID).catch(error => { if (project.request?.id === requestID && ACTIVE.has(project.status)) this.fail(project, error); }).finally(() => {
      if (this.launching.get(project.id) === requestID) {
        this.launching.delete(project.id);
        for (const event of this.buffered.get(project.id) || []) if (event.request) this.connection.reject(event.packet.id, 'The turn could not start.');
        this.buffered.delete(project.id);
      }
    });
    return project;
  }
  async run(project, prompt, requestID) {
    const current = () => project.request?.id === requestID && ACTIVE.has(project.status);
    await this.connection.start();
    if (!current()) return;
    const threadOptions = { cwd: this.workspace(project), approvalPolicy: 'on-request', sandbox: 'workspace-write' };
    if (!project.threadID) {
      const result = await this.connection.request('thread/start', { ...threadOptions, serviceName: 'apk_container_bridge' });
      if (project.request?.id !== requestID) return;
      project.threadID = result.thread.id; this.loadedThreads.add(project.threadID); this.save(project);
      if (!current()) return;
      await this.connection.request('thread/name/set', { threadId: project.threadID, name: project.name }).catch(() => {});
    } else if (!this.loadedThreads.has(project.threadID)) {
      await this.connection.request('thread/resume', { ...threadOptions, threadId: project.threadID, excludeTurns: true }); this.loadedThreads.add(project.threadID);
    }
    if (!current()) return;
    project.submittedTurns += 1; this.save(project);
    this.buffered.set(project.id, []);
    const input = [{ type: 'text', text: prompt }];
    if (this.skillPath) input.push({ type: 'skill', name: 'apk', path: this.skillPath });
    const result = await this.connection.request('turn/start', { threadId: project.threadID, clientUserMessageId: requestID, input, cwd: this.workspace(project), approvalPolicy: 'on-request', sandboxPolicy: { type: 'workspaceWrite', writableRoots: [this.workspace(project)], networkAccess: true } });
    const queued = this.buffered.get(project.id) || []; this.buffered.delete(project.id);
    if (!current()) {
      // Stop pressed before turn/start returned: interrupt the returned turn,
      // instead of allowing an invisible build to continue on the Mac.
      for (const event of queued) if (event.request) this.connection.reject(event.packet.id, 'The request was stopped.');
      await this.connection.request('turn/interrupt', { threadId: project.threadID, turnId: result.turn.id });
      return;
    }
    project.activeTurnID = result.turn.id; this.save(project);
    for (const event of queued) {
      if (event.request) this.serverRequest(event.packet);
      else await this.notification(event.packet);
    }
  }
  findThread(threadID) { return [...this.projects.values()].find(p => p.threadID === threadID); }
  async notification({ method, params: p = {} }) {
    const project = this.findThread(p.threadId); if (!project) return;
    if (!ACTIVE.has(project.status)) return;
    const turnID = p.turnId || p.turn?.id;
    if (turnID && project.activeTurnID !== turnID) {
      const queue = this.buffered.get(project.id);
      if (queue && queue.length < 2000) queue.push({ packet: { method, params: p }, request: false });
      return;
    }
    if (method === 'turn/started') return;
    if (method === 'item/agentMessage/delta') {
      let message = project.messages.find(m => m.id === `agent-${p.itemId}`);
      if (!message) message = this.message(project, 'assistant', '', `agent-${p.itemId}`);
      message.text = (message.text + (p.delta || '')).slice(0, 2 * 1024 * 1024); this.save(project, true);
    }
    if (method === 'item/completed' && p.item?.type === 'agentMessage') {
      let message = project.messages.find(m => m.id === `agent-${p.item.id}`);
      if (!message) message = this.message(project, 'assistant', '', `agent-${p.item.id}`);
      if (typeof p.item.text === 'string') message.text = p.item.text.slice(0, 2 * 1024 * 1024);
      this.save(project);
    }
    if (method === 'serverRequest/resolved') {
      const pending = [...this.approvals.entries()].find(([, v]) => String(v.rpcID) === String(p.requestId));
      if (pending) { this.approvals.delete(pending[0]); project.approvals = project.approvals.filter(a => a.id !== pending[0]); if (ACTIVE.has(project.status)) project.status = project.approvals.length ? 'awaitingApproval' : 'building'; this.save(project); }
    }
    if (method === 'turn/completed') {
      // Ignore delayed completion from a previous turn rather than clearing a new build.
      if (project.activeTurnID && p.turn?.id !== project.activeTurnID) return;
      this.clearApprovals(project); project.activeTurnID = null;
      if (p.turn?.status === 'completed') await this.complete(project);
      else { project.status = p.turn?.status === 'interrupted' ? 'interrupted' : 'failed'; project.error = p.turn?.error?.message || (project.status === 'interrupted' ? 'The request was stopped. Send another message to continue.' : 'Codex could not complete this request.'); this.save(project); }
    }
    if (method === 'error' && p.willRetry === false) this.fail(project, new Error(p.error?.message || 'Codex reported an error.'));
  }
  async complete(project) {
    const directory = path.join(this.workspace(project), 'dist');
    let report = null;
    const reportFile = path.join(directory, 'build-report.json');
    if (fs.existsSync(reportFile) && !fs.lstatSync(reportFile).isSymbolicLink() && fs.statSync(reportFile).size < 128 * 1024) {
      try { const candidate = JSON.parse(fs.readFileSync(reportFile, 'utf8')); if (candidate.requestID === project.request?.id) report = candidate; } catch {}
    }
    const artifacts = [];
    for (const source of apkFiles(directory)) {
      if (!fs.lstatSync(source).isFile() || fs.lstatSync(source).isSymbolicLink()) continue;
      const verified = verifyAPK(source), previous = project.request?.baseline?.[path.basename(source)];
      // Merely touching an old APK cannot create a success card. Identical
      // rebuilds additionally require a fresh report bound to this request.
      const changed = !previous || previous.sha256 !== verified.sha256 || (report && fs.statSync(source).mtimeMs > previous.mtimeMS);
      if (!changed) continue;
      const id = crypto.randomUUID(), destination = path.join(this.config.stateDir, 'artifacts', project.id, `${id}.apk`);
      this.checkpoint([destination], { label: 'apk-publish-build', summary: `Record new APK delivery destination for ${project.name}`, backupRoot: this.config.backupRoot });
      privateDirectory(path.dirname(destination)); fs.copyFileSync(source, destination, fs.constants.COPYFILE_EXCL); fs.chmodSync(destination, 0o600);
      const saved = verifyAPK(destination); if (saved.sha256 !== verified.sha256) throw new Error('The APK changed during delivery; retry the build.');
      artifacts.push({ id, name: path.basename(source), bytes: saved.bytes, sha256: saved.sha256, createdAt: now(), downloadPath: `/v1/projects/${project.id}/artifacts/${id}`, file: destination });
    }
    project.status = 'completed'; project.error = null;
    if (artifacts.length) {
      project.artifacts.unshift(...artifacts);
      const kind = !project.request.hadArtifacts ? 'created' : /\b(edit|change|fix|tweak|adjust|correct)\b/i.test(project.request.text) ? 'edited' : 'updated';
      project.summary = { kind, features: reportList(report?.features), issues: reportList(report?.issues), ideas: reportList(report?.ideas) };
      if (!report) project.summary.issues.push('The APK was produced, but Codex did not provide a current structured build report. Read its reply for validation details.');
      this.message(project, 'status', `I've ${kind} your app. Open My Apps to download it on this device.`);
    } else {
      project.summary = null;
      this.message(project, 'status', 'Codex finished this reply without a new APK. Read the reply for features, issues, and next steps; your previous builds are still in My Apps.');
    }
    this.save(project);
  }
  serverRequest(packet) {
    const p = packet.params || {}, project = this.findThread(p.threadId);
    if (!project) { this.connection.reject(packet.id, 'This request is not associated with a paired APK project.'); return; }
    if (!ACTIVE.has(project.status)) { this.connection.reject(packet.id, 'This request belongs to a stopped or completed turn.'); return; }
    if (p.turnId && project.activeTurnID !== p.turnId) {
      const queue = this.buffered.get(project.id);
      if (queue && queue.length < 2000) queue.push({ packet, request: true });
      else this.connection.reject(packet.id, 'This request belongs to a stopped or completed turn.');
      return;
    }
    const types = { 'item/commandExecution/requestApproval': ['command', 'Allow this command?'], 'item/fileChange/requestApproval': ['file', 'Allow these file changes?'], 'item/permissions/requestApproval': ['permissions', 'Allow this access?'], 'item/tool/requestUserInput': ['input', 'Codex needs your answer'] };
    const type = types[packet.method];
    if (!type) {
      if (packet.method === 'mcpServer/elicitation/request') this.connection.respond(packet.id, { action: 'decline', content: null });
      else this.connection.reject(packet.id, 'This request is not supported by APK Container Bridge.');
      this.message(project, 'status', 'Codex requested an unsupported interaction. It was declined; continue this task on your Mac if needed.'); this.save(project); return;
    }
    const id = crypto.randomUUID();
    const detail = [p.reason, p.command, p.cwd ? `Working folder: ${p.cwd}` : null, p.grantRoot ? `Folder: ${p.grantRoot}` : null, p.permissions ? JSON.stringify(p.permissions, null, 2) : null, p.additionalPermissions ? JSON.stringify(p.additionalPermissions, null, 2) : null].filter(Boolean).join('\n\n').slice(0, 20000);
    const approval = { id, kind: type[0], title: type[1], detail, createdAt: now(), questions: Array.isArray(p.questions) ? p.questions.map(q => ({ id: q.id, header: q.header || '', question: q.question, options: q.options || [] })) : [] };
    this.approvals.set(id, { rpcID: packet.id, projectID: project.id, method: packet.method, params: p }); project.approvals.push(approval); project.status = 'awaitingApproval'; this.save(project);
  }
  answer(id, approvalID, { decision, answers = {} }) {
    const project = this.get(id), approval = this.approvals.get(approvalID);
    if (!approval || approval.projectID !== id) throw new APIError(404, 'This approval is no longer pending.');
    if (!['accept', 'decline'].includes(decision)) throw new APIError(400, 'Choose accept or decline.');
    let response;
    if (approval.method === 'item/tool/requestUserInput') {
      const validated = {};
      for (const question of approval.params.questions || []) {
        const answer = answers[question.id];
        if (decision === 'accept' && (!Array.isArray(answer) || !answer.length || answer.some(v => typeof v !== 'string' || !v.trim() || v.length > 10000))) throw new APIError(400, 'Answer every question before continuing.');
        validated[question.id] = { answers: decision === 'accept' ? answer : ['User declined to answer.'] };
      }
      response = { answers: validated };
    } else if (approval.method === 'item/permissions/requestApproval') response = { permissions: decision === 'accept' ? approval.params.permissions || {} : {}, scope: 'turn' };
    else response = { decision };
    this.connection.respond(approval.rpcID, response); this.approvals.delete(approvalID); project.approvals = project.approvals.filter(a => a.id !== approvalID); project.status = project.approvals.length ? 'awaitingApproval' : 'building'; this.save(project); return project;
  }
  clearApprovals(project) { for (const a of project.approvals) this.approvals.delete(a.id); project.approvals = []; }
  async interrupt(id) {
    const project = this.get(id), threadID = project.threadID, turnID = project.activeTurnID;
    if (!ACTIVE.has(project.status)) return project;
    project.status = 'interrupted'; project.error = 'Stopped. Send another message to continue this app.'; project.activeTurnID = null; this.clearApprovals(project); this.save(project);
    if (threadID && turnID) {
      this.stopping.add(id);
      try { await this.connection.request('turn/interrupt', { threadId: threadID, turnId: turnID }); }
      finally { this.stopping.delete(id); }
    }
    return project;
  }
  artifact(id, artifactID) {
    const project = this.get(id), artifact = project.artifacts.find(a => a.id === validID(artifactID));
    if (!artifact) throw new APIError(404, 'APK build not found.');
    const root = fs.realpathSync(path.join(this.config.stateDir, 'artifacts', project.id)), real = fs.realpathSync(artifact.file);
    if (!real.startsWith(root + path.sep) || hashFile(real) !== artifact.sha256) throw new APIError(409, 'The saved APK changed. Rebuild it before downloading.');
    return artifact;
  }
  failByThread(id, error) { const p = this.findThread(id); if (p && ACTIVE.has(p.status)) this.fail(p, error); }
  fail(project, error) { project.status = 'failed'; project.error = String(error.message || error).slice(0, 3000); project.activeTurnID = null; this.clearApprovals(project); this.save(project); }
  close() {
    for (const project of this.projects.values()) {
      if (ACTIVE.has(project.status)) { project.status = 'interrupted'; project.activeTurnID = null; project.error = 'The Mac bridge stopped during this request. Send a follow-up to resume the app.'; this.clearApprovals(project); this.save(project); }
      else if (this.saving.has(project.id)) this.save(project);
    }
    this.connection.close();
  }
}

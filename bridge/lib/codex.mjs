// SPDX-License-Identifier: GPL-2.0-or-later
import { spawn } from 'node:child_process';
import { EventEmitter } from 'node:events';
import readline from 'node:readline';

/** App-server remains local: only this bridge's scoped HTTP API is exposed. */
export class CodexConnection extends EventEmitter {
  constructor(binary, { env = process.env, cwd } = {}) {
    super(); this.binary = binary; this.env = env; this.cwd = cwd; this.nextID = 1; this.pending = new Map(); this.ready = false; this.startPromise = null;
  }
  async start() {
    if (this.ready) return;
    if (this.startPromise) return this.startPromise;
    this.startPromise = this._start();
    try { await this.startPromise; } finally { this.startPromise = null; }
  }
  async _start() {
    this.child = spawn(this.binary, ['app-server', '--listen', 'stdio://'], { env: this.env, cwd: this.cwd, stdio: ['pipe', 'pipe', 'pipe'] });
    this.child.on('error', error => this._closed(error));
    this.child.on('exit', () => this._closed(new Error('The local Codex process stopped. Reopen the bridge to reconnect.')));
    // stderr is never forwarded to devices: it may include private host diagnostics.
    this.child.stderr.resume();
    const lines = readline.createInterface({ input: this.child.stdout });
    lines.on('line', line => {
      let packet; try { packet = JSON.parse(line); } catch { return; }
      if (packet.method) this.emit(packet.id === undefined ? 'notification' : 'request', packet);
      else if (packet.id !== undefined) {
        const pending = this.pending.get(String(packet.id)); if (!pending) return;
        this.pending.delete(String(packet.id)); clearTimeout(pending.timer);
        if (packet.error) pending.reject(new Error(packet.error.message || 'Codex rejected the request.'));
        else pending.resolve(packet.result);
      }
    });
    await this.request('initialize', { clientInfo: { name: 'apk_container_bridge', title: 'APK Container Bridge', version: '1.1.0' }, capabilities: { experimentalApi: false } });
    this.notify('initialized', {}); this.ready = true;
  }
  _closed(error) {
    const wasReady = this.ready; this.ready = false;
    for (const request of this.pending.values()) { clearTimeout(request.timer); request.reject(error); }
    this.pending.clear();
    if (wasReady) this.emit('disconnected', error);
  }
  send(packet) {
    if (!this.child?.stdin?.writable) throw new Error('Codex is not connected.');
    this.child.stdin.write(JSON.stringify(packet) + '\n');
  }
  request(method, params, timeout = 120000) {
    const id = this.nextID++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(String(id)); reject(new Error(`Codex did not answer ${method}.`)); }, timeout);
      this.pending.set(String(id), { resolve, reject, timer });
      try { this.send({ id, method, params }); } catch (error) { clearTimeout(timer); this.pending.delete(String(id)); reject(error); }
    });
  }
  notify(method, params) { this.send({ method, params }); }
  respond(id, result) { this.send({ id, result }); }
  reject(id, message) { this.send({ id, error: { code: -32601, message } }); }
  close() { this.child?.kill('SIGTERM'); this._closed(new Error('Bridge closed.')); }
}

// Real HTTPS fixture for the production Swift store. All state is disposable.
import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';
import https from 'node:https';
import { X509Certificate } from 'node:crypto';
import { execFileSync } from 'node:child_process';

const root = process.argv[2];
const key = path.join(root, 'fixture.key'), cert = path.join(root, 'fixture.pem');
execFileSync('/usr/bin/openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', key, '-out', cert,
  '-days', '1', '-subj', '/CN=localhost'], { stdio: 'ignore' });
const token = 'store-fixture-token-never-a-user-credential';
const counts = {};
const pending = new Map();
let holdStatus = false, holdRead = true, revision = 0;
const project = (stale = false) => ({ id: 'project-fixture', name: 'Keep this app', status: stale ? 'failed' : revision ? 'completed' : 'building',
  createdAt: '2026-01-01T00:00:00Z', updatedAt: stale ? '9999-01-01T00:00:00Z' : `2026-01-01T00:00:0${revision}Z`,
  threadID: null, messages: [], artifacts: [], approvals: [], summary: null, error: stale ? 'STALE REPLY MUST NOT APPLY' : null });
const send = (response, value) => { response.writeHead(200, { 'Content-Type': 'application/json' }); response.end(JSON.stringify(value)); };
const server = https.createServer({ key: fs.readFileSync(key), cert: fs.readFileSync(cert) }, (request, response) => {
  if (request.headers.authorization !== 'Bearer ' + token) { response.writeHead(401); response.end('{}'); return; }
  const route = request.url;
  counts[route] = (counts[route] || 0) + 1;
  if (route === '/v1/status') {
    if (holdStatus) { holdStatus = false; pending.set('status', response); return; }
    send(response, { bridgeID: 'store-fixture', paired: true }); return;
  }
  if (route === '/v1/projects') { send(response, { projects: [project()] }); return; }
  if (route === '/v1/projects/project-fixture') {
    if (holdRead) { holdRead = false; revision = 1; pending.set('read', response); return; }
    send(response, { project: project() }); return;
  }
  if (route.includes('/approvals/')) { request.resume(); pending.set('approval', response); return; }
  if (route.endsWith('/interrupt')) { request.resume(); pending.set('interrupt', response); return; }
  if (route.endsWith('/messages')) { request.resume(); pending.set('send', response); return; }
  if (route.includes('/artifacts/')) { pending.set('download', response); return; }
  response.writeHead(404); response.end('{}');
});
server.on('tlsClientError', () => {});
const control = http.createServer((request, response) => {
  if (request.url === '/hold-status') holdStatus = true;
  if (request.url.startsWith('/release/')) {
    const name = request.url.slice('/release/'.length), held = pending.get(name);
    pending.delete(name);
    if (held) {
      if (name === 'status') send(held, { bridgeID: 'store-fixture', paired: true });
      else if (name === 'download') { held.writeHead(200); held.end('x'); }
      else send(held, { project: project(name === 'read') });
    }
  }
  send(response, { counts, pending: [...pending.keys()] });
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
await new Promise(resolve => control.listen(0, '127.0.0.1', resolve));
const profile = { format: 'apk-container-agent', version: 1, bridgeID: 'store-fixture', name: 'Fixture Mac',
  url: `https://127.0.0.1:${server.address().port}`, token,
  certificateSHA256: new X509Certificate(fs.readFileSync(cert)).fingerprint256.replaceAll(':', '').toLowerCase(), createdAt: 'fixture' };
fs.writeFileSync(path.join(root, 'fixture.json'), JSON.stringify({ profile, control: `http://127.0.0.1:${control.address().port}` }));
process.on('SIGTERM', () => { for (const value of [server, control]) { value.closeAllConnections(); value.close(); } process.exit(); });

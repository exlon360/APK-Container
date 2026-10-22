// Isolated local HTTPS fixtures. Never reads installed bridge files or credentials.
import fs from 'node:fs';
import path from 'node:path';
import https from 'node:https';
import { execFileSync } from 'node:child_process';
import { X509Certificate } from 'node:crypto';
const directory = process.argv[2];
const credential = name => {
  const key = path.join(directory, name + '.key');
  const cert = path.join(directory, name + '.pem');
  execFileSync('/usr/bin/openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', key, '-out', cert,
    '-days', '1', '-subj', '/CN=localhost'], { stdio: 'ignore' });
  return { key: fs.readFileSync(key), cert: fs.readFileSync(cert) };
};
const identity = credential('paired');
const otherIdentity = credential('other');
const token = 'test-fixture-token-never-a-user-credential';
const pin = new X509Certificate(identity.cert).fingerprint256.replaceAll(':', '').toLowerCase();
const counts = {};
let failPrimary = false;
const servers = [];
let redirectAddress;
async function start(kind, credentials = identity) {
  const server = https.createServer(credentials, (req, res) => {
    counts[kind] ??= {};
    counts[kind][req.url] = (counts[kind][req.url] ?? 0) + 1;
    if (req.headers.authorization !== 'Bearer ' + token) { res.writeHead(401); res.end('{}'); return; }
    const json = (status, value) => { res.writeHead(status, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(value)); };
    if (kind === 'slow') return; // Connected socket, no headers: the client deadline must cancel it.
    if (req.url === '/v1/status') {
      if (kind === 'unauthorized') return json(401, { error: 'Expired fixture pairing' });
      if (kind === 'invalid') return json(200, { unexpected: true });
      if (kind === 'wrongID') return json(200, { bridgeID: 'other-bridge', paired: true });
      if (kind === 'good' && failPrimary) return json(503, { error: 'Primary no longer available' });
      return setTimeout(() => json(200, { bridgeID: 'fixture', paired: true }), kind === 'backup' ? 100 : 0);
    }
    if (req.url === '/v1/fail') return json(503, { error: 'Fixture service is reachable but busy' });
    if (req.url === '/v1/redirect') { res.writeHead(302, { Location: redirectAddress + '/v1/redirect-target' }); return res.end(); }
    if (req.url === '/v1/drop-post') {
      req.resume(); req.on('end', () => { req.socket.destroy(); }); return;
    }
    if (req.url === '/v1/drop-read' && kind === 'good') { failPrimary = true; req.socket.destroy(); return; }
    if (req.url === '/v1/artifact') { res.writeHead(200, { 'Content-Type': 'application/vnd.android.package-archive' }); return res.end('APK fixture bytes'); }
    if (req.url === '/v1/counts') return json(200, counts);
    return json(200, { ok: true });
  });
  server.on('tlsClientError', () => {});
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  servers.push(server);
  return 'https://127.0.0.1:' + server.address().port;
}
const addresses = {};
for (const kind of ['good', 'backup', 'slow', 'unauthorized', 'invalid', 'wrongID', 'redirectTarget']) addresses[kind] = await start(kind);
addresses.wrongPin = await start('wrongPin', otherIdentity);
redirectAddress = addresses.redirectTarget;
fs.writeFileSync(path.join(directory, 'fixture.json'), JSON.stringify({ addresses, token, pin }));
process.on('SIGTERM', () => { for (const server of servers) { server.closeAllConnections(); server.close(); } process.exit(); });

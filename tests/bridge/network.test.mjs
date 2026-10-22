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
import { fileURLToPath } from 'node:url';
import { lanIPv4Addresses, connectionOrigins } from '../../bridge/lib/network.mjs';
import { initialize, pair, profile, exportProfile } from '../../bridge/lib/profile.mjs';
import { BridgeService } from '../../bridge/lib/service.mjs';
import { startHTTPS } from '../../bridge/lib/server.mjs';

const address = (value, extra = {}) => ({ address: value, family: 'IPv4', internal: false, ...extra });
function scratch(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'apk-network-test-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true })); return root;
}
function configuration(t, url = 'https://fixture-mac.local:48152') {
  const root = scratch(t);
  return initialize({ stateDir: path.join(root, 'state'), projectsDir: path.join(root, 'apps'), backupRoot: path.join(root, 'backups'), url, codexPath: '/test/codex' });
}
class NoCodex extends EventEmitter { ready = false; close() {} }

test('LAN candidates include only usable Ethernet/Wi-Fi IPv4 interfaces in stable order', () => {
  const interfaces = {
    en2: [address('192.168.1.9'), address('192.168.1.9')],
    en0: [address('172.20.8.221'), address('::1', { family: 'IPv6' }), address('127.0.0.1'), address('169.254.1.1'), address('10.1.1.1', { internal: true })],
    en1: [address('10.0.0.42', { family: 4 }), address('not-an-address'), address('255.255.255.255')],
    utun7: [address('100.100.100.1')], awdl0: [address('192.168.50.1')], bridge100: [address('192.168.64.1')], lo0: [address('127.0.0.1')], docker0: [address('172.17.0.1')],
  };
  assert.deepEqual(lanIPv4Addresses(interfaces), ['172.20.8.221', '10.0.0.42', '192.168.1.9']);
});

test('legacy profile primary is numeric for .local with hostname fallback and six-origin cap', () => {
  const interfaces = { en0: Array.from({ length: 10 }, (_, i) => address(`192.168.1.${i + 2}`)) };
  const actual = connectionOrigins({ url: 'https://Fixture-Mac.local:48152' }, interfaces);
  assert.equal(actual.url, 'https://192.168.1.2:48152');
  assert.equal(actual.alternateURLs[0], 'https://fixture-mac.local:48152');
  assert.equal(actual.alternateURLs.length, 5);
  assert.equal(new Set([actual.url, ...actual.alternateURLs]).size, 6);
  assert.deepEqual(connectionOrigins({ url: 'https://fixture-mac.local:48152' }, {}), { url: 'https://fixture-mac.local:48152', alternateURLs: [] });
});

test('custom VPN hostname and port retain priority; duplicate and insecure origins are rejected', () => {
  const interfaces = { en0: [address('192.168.1.2')] };
  assert.deepEqual(connectionOrigins({ url: 'https://private-vpn.example:443' }, interfaces), {
    url: 'https://private-vpn.example', alternateURLs: ['https://192.168.1.2']
  });
  assert.deepEqual(connectionOrigins({ url: 'https://192.168.1.2:48152' }, interfaces), {
    url: 'https://192.168.1.2:48152', alternateURLs: []
  });
  for (const url of ['http://host:48152', 'https://host/path', 'https://user:pass@host', 'https://host?query=x']) {
    assert.throws(() => connectionOrigins({ url }, interfaces), /HTTPS origin/);
  }
});

test('fresh profile export keeps certificate/token/configuration and checkpoints before changing address', t => {
  const originalInterfaces = os.networkInterfaces;
  t.after(() => { os.networkInterfaces = originalInterfaces; });
  os.networkInterfaces = () => ({ en0: [address('192.168.1.11')] });
  const c = configuration(t), profilePath = path.join(c.stateDir, 'agent.prf');
  const before = fs.readFileSync(profilePath), configurationBefore = fs.readFileSync(path.join(c.stateDir, 'configuration.json'));
  const keyBefore = fs.readFileSync(path.join(c.stateDir, 'bridge-key.pem'));
  assert.equal(JSON.parse(before).url, 'https://192.168.1.11:48152');
  os.networkInterfaces = () => ({ en0: [address('192.168.1.22')] });
  const current = profile(c);
  assert.equal(current.url, 'https://192.168.1.22:48152');
  assert.equal(current.token, c.token); assert.equal(current.certificateSHA256, c.certificateSHA256); assert.equal(current.bridgeID, c.bridgeID);
  assert.deepEqual(fs.readFileSync(profilePath), before, 'Reading current endpoints must not rewrite stored profile');
  exportProfile(c.stateDir);
  assert.equal(JSON.parse(fs.readFileSync(profilePath)).url, current.url);
  assert.deepEqual(fs.readFileSync(path.join(c.stateDir, 'configuration.json')), configurationBefore);
  assert.deepEqual(fs.readFileSync(path.join(c.stateDir, 'bridge-key.pem')), keyBefore);
  const records = fs.readdirSync(c.backupRoot).filter(v => v.includes('apk-agent-profile'));
  assert.equal(records.length, 1);
  const checkpoint = JSON.parse(fs.readFileSync(path.join(c.backupRoot, records[0], 'manifest.json')));
  assert.equal(checkpoint.verified, true); assert.deepEqual(fs.readFileSync(checkpoint.entries[0].copied), before);
  assert.equal(fs.statSync(profilePath).mode & 0o777, 0o600);
});

test('public CLI status reports usable endpoint choices without credentials or profile writes', t => {
  const c = configuration(t), profilePath = path.join(c.stateDir, 'agent.prf');
  const before = fs.readFileSync(profilePath);
  const result = JSON.parse(execFileSync(process.execPath, ['bridge/bridge.mjs', 'status', '--state-dir', c.stateDir], { encoding: 'utf8' }));
  assert.ok(Array.isArray(result.alternateURLs));
  assert.ok([result.url, ...result.alternateURLs].includes(c.url));
  assert.equal(result.token, undefined); assert.equal(result.certificateSHA256, undefined);
  assert.equal(JSON.stringify(result).includes(c.token), false);
  assert.deepEqual(fs.readFileSync(profilePath), before);
});

test('CLI invoked through a symlink or macOS temporary-directory alias still returns status JSON', t => {
  const c = configuration(t), linkedEntry = path.join(scratch(t), 'bridge-alias.mjs');
  fs.symlinkSync(fileURLToPath(new URL('../../bridge/bridge.mjs', import.meta.url)), linkedEntry);
  const result = JSON.parse(execFileSync(process.execPath, [linkedEntry, 'status', '--state-dir', c.stateDir], { encoding: 'utf8' }));
  assert.equal(result.bridgeID, c.bridgeID);
  assert.equal(result.token, undefined);
});

test('importing the CLI does not invoke main, including an absent argv entry path', () => {
  const entryURL = new URL('../../bridge/bridge.mjs', import.meta.url).href;
  const script = `process.argv[1] = '/nonexistent/apk-bridge-import.mjs'; await import(${JSON.stringify(entryURL)}); console.log('imported');`;
  assert.equal(execFileSync(process.execPath, ['--input-type=module', '-e', script], { encoding: 'utf8' }), 'imported\n');
});

test('default HTTPS listener accepts authenticated IPv6 and IPv4 with the same pinned certificate', async t => {
  const c = configuration(t); pair(c.stateDir);
  const service = new BridgeService(c, { connection: new NoCodex(), skillPath: null });
  const server = await startHTTPS(service, { port: 0 });
  t.after(() => { service.close(); return new Promise(resolve => server.close(resolve)); });
  assert.equal(server.address().family, 'IPv6');
  const request = hostname => new Promise((resolve, reject) => {
    const req = https.get({ hostname, port: server.address().port, path: '/v1/status', agent: false,
      ca: fs.readFileSync(path.join(c.stateDir, 'bridge-cert.pem')),
      checkServerIdentity: (_host, cert) => crypto.createHash('sha256').update(cert.raw).digest('hex') === c.certificateSHA256 ? undefined : new Error('Pin mismatch'),
      headers: { Authorization: `Bearer ${c.token}` }
    }, response => { let body = ''; response.on('data', value => body += value); response.on('end', () => resolve({ status: response.statusCode, body: JSON.parse(body) })); });
    req.setTimeout(2000, () => req.destroy(new Error('Connection timed out'))); req.on('error', reject);
  });
  for (const host of ['::1', '127.0.0.1']) {
    const result = await request(host); assert.equal(result.status, 200); assert.equal(result.body.bridgeID, c.bridgeID); assert.equal(result.body.paired, true);
  }
});

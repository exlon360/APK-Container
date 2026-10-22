// SPDX-License-Identifier: GPL-2.0-or-later
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { atomicJSON, checkpointPaths, privateDirectory } from './backup.mjs';

export const DEFAULT_STATE = path.join(os.homedir(), 'Library/Application Support/APK Container Bridge');
export const DEFAULT_PROJECTS = path.join(os.homedir(), 'Documents/ChatGPT/apk files');
export const VERSION = '1.1.0';
export function configurationFile(stateDir) { return path.join(stateDir, 'configuration.json'); }
export function readConfiguration(stateDir) {
  if (!fs.existsSync(configurationFile(stateDir))) throw new Error('The bridge is not set up yet. Choose Start Bridge or Generate agent.prf on your Mac.');
  const config = JSON.parse(fs.readFileSync(configurationFile(stateDir), 'utf8'));
  if (config.version !== 1 || !/^[a-f0-9]{64}$/.test(config.token) || !config.bridgeID || !config.url) throw new Error('Bridge configuration is invalid. Restore its verified checkpoint rather than replacing credentials.');
  return config;
}
export function profile(config) {
  return { format: 'apk-container-agent', version: 1, bridgeID: config.bridgeID, name: config.name, url: config.url, token: config.token, certificateSHA256: config.certificateSHA256, createdAt: config.createdAt };
}
export function discoverCodex() {
  if (process.env.APK_CONTAINER_CODEX) return process.env.APK_CONTAINER_CODEX;
  try { return execFileSync('/usr/bin/which', ['codex'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim(); } catch {}
  for (const candidate of [
    '/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex',
    '/Applications/Codex.app/Contents/Resources/codex', '/opt/homebrew/bin/codex', '/usr/local/bin/codex',
  ]) if (fs.existsSync(candidate)) return candidate;
  throw new Error('Codex CLI was not found. Install or open Codex on this Mac, sign in, and try again.');
}
export function initialize({ stateDir = DEFAULT_STATE, projectsDir = DEFAULT_PROJECTS, url, name = 'APK Container Bridge', port = 48152, codexPath, backupRoot } = {}) {
  stateDir = path.resolve(stateDir); projectsDir = path.resolve(projectsDir);
  if (fs.existsSync(configurationFile(stateDir))) return readConfiguration(stateDir);
  const host = os.hostname().replace(/[^A-Za-z0-9.-]/g, '-') || 'localhost';
  const endpoint = new URL(url || `https://${host.includes('.') ? host : `${host}.local`}:${port}`);
  if (endpoint.protocol !== 'https:' || endpoint.username || endpoint.password || (endpoint.pathname !== '/' && endpoint.pathname !== '') || endpoint.search || endpoint.hash) throw new Error('The bridge URL must be an HTTPS origin, such as https://My-Mac.local:48152.');
  const selectedPort = Number(endpoint.port || 443);
  if (!Number.isInteger(selectedPort) || selectedPort < 1 || selectedPort > 65535) throw new Error('Invalid bridge port.');
  const selectedCodex = codexPath || discoverCodex();
  const checkpoint = checkpointPaths([stateDir, ...(!fs.existsSync(projectsDir) ? [projectsDir] : [])], { label: 'apk-bridge-init', summary: 'Initialize APK Container Bridge settings and private pairing profile', backupRoot });
  privateDirectory(stateDir);
  // Preserve an existing projects folder; creating it does not modify its contents.
  privateDirectory(projectsDir);
  const keyFile = path.join(stateDir, 'bridge-key.pem'), certFile = path.join(stateDir, 'bridge-cert.pem');
  if (fs.existsSync(keyFile) || fs.existsSync(certFile)) throw new Error('Unpaired certificate files already exist. Preserve or restore the previous bridge configuration before setup.');
  execFileSync('/usr/bin/openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-sha256', '-days', '3650', '-nodes', '-keyout', keyFile, '-out', certFile, '-subj', '/CN=APK Container Bridge'], { stdio: 'ignore' });
  fs.chmodSync(keyFile, 0o600); fs.chmodSync(certFile, 0o600);
  const certificate = new crypto.X509Certificate(fs.readFileSync(certFile));
  const config = { version: 1, bridgeID: crypto.randomUUID(), name, url: endpoint.origin, port: selectedPort, token: crypto.randomBytes(32).toString('hex'), certificateSHA256: crypto.createHash('sha256').update(certificate.raw).digest('hex'), createdAt: new Date().toISOString(), pairedAt: null, stateDir, projectsDir, codexPath: selectedCodex, backupRoot: backupRoot || path.join(os.homedir(), '.codex/backups/pre-prompt'), initializationCheckpoint: checkpoint };
  atomicJSON(configurationFile(stateDir), config);
  atomicJSON(path.join(stateDir, 'agent.prf'), profile(config));
  return config;
}
export function pair(stateDir = DEFAULT_STATE) {
  const config = readConfiguration(stateDir);
  if (!config.pairedAt) {
    checkpointPaths([configurationFile(stateDir)], { label: 'apk-pair-skill', summary: 'Pair the APK Container build skill with this Mac bridge', backupRoot: config.backupRoot });
    config.pairedAt = new Date().toISOString(); atomicJSON(configurationFile(stateDir), config);
  }
  return config;
}
export function exportProfile(stateDir, output) {
  const config = readConfiguration(stateDir), destination = path.resolve(output || path.join(stateDir, 'agent.prf'));
  const desired = JSON.stringify(profile(config), null, 2) + '\n';
  if (fs.existsSync(destination) && fs.readFileSync(destination, 'utf8') === desired) return destination;
  checkpointPaths([destination], { label: 'apk-agent-profile', summary: 'Export APK Container pairing profile', backupRoot: config.backupRoot });
  atomicJSON(destination, profile(config)); return destination;
}

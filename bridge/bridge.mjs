#!/usr/bin/env node
// SPDX-License-Identifier: GPL-2.0-or-later
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { DEFAULT_STATE, initialize, readConfiguration, pair, exportProfile, VERSION } from './lib/profile.mjs';
import { BridgeService } from './lib/service.mjs';
import { startHTTPS } from './lib/server.mjs';
import { connectionOrigins } from './lib/network.mjs';

export function argumentsFor(argv) {
  const command = argv[0] || 'help', options = {};
  for (let i = 1; i < argv.length; i++) {
    const key = argv[i];
    if (key === '--json') options.json = true;
    else if (['--state-dir', '--projects-dir', '--url', '--codex', '--out', '--backup-root'].includes(key)) {
      if (!argv[i + 1] || argv[i + 1].startsWith('--')) throw new Error(`Missing value for ${key}`);
      options[key.slice(2)] = argv[++i];
    } else throw new Error(`Unknown option ${key}`);
  }
  return { command, options };
}
function publicStatus(config) { return { bridgeID: config.bridgeID, name: config.name, ...connectionOrigins(config), paired: Boolean(config.pairedAt), profilePath: path.join(config.stateDir, 'agent.prf'), stateDir: config.stateDir, projectsDir: config.projectsDir, version: VERSION }; }
export async function main(argv = process.argv.slice(2)) {
  const { command, options } = argumentsFor(argv), stateDir = path.resolve(options['state-dir'] || DEFAULT_STATE);
  if (command === 'init') {
    const config = initialize({ stateDir, projectsDir: options['projects-dir'], url: options.url, codexPath: options.codex, backupRoot: options['backup-root'] });
    console.log(JSON.stringify(publicStatus(config))); return;
  }
  if (command === 'pair') { console.log(JSON.stringify(publicStatus(pair(stateDir)))); return; }
  if (command === 'profile') { console.log(JSON.stringify({ profilePath: exportProfile(stateDir, options.out) })); return; }
  if (command === 'status') { console.log(JSON.stringify(publicStatus(readConfiguration(stateDir)))); return; }
  if (command === 'projects') {
    const directory = path.join(stateDir, 'projects'), projects = [];
    if (fs.existsSync(directory)) for (const file of fs.readdirSync(directory).filter(v => v.endsWith('.json'))) {
      const p = JSON.parse(fs.readFileSync(path.join(directory, file), 'utf8'));
      projects.push({ id: p.id, name: p.name, threadID: p.threadID, status: p.status, updatedAt: p.updatedAt, path: path.join(readConfiguration(stateDir).projectsDir, p.id) });
    }
    console.log(JSON.stringify({ projects })); return;
  }
  if (command === 'start') {
    const service = new BridgeService(readConfiguration(stateDir));
    const server = await startHTTPS(service);
    console.log(JSON.stringify({ event: 'listening', ...connectionOrigins(service.config), port: server.address().port }));
    let stopping = false;
    const stop = () => {
      if (stopping) return; stopping = true;
      service.close(); server.close(() => process.exit(0)); server.closeIdleConnections?.();
      setTimeout(() => { server.closeAllConnections?.(); process.exit(0); }, 3000).unref();
    };
    process.on('SIGTERM', stop); process.on('SIGINT', stop); return;
  }
  if (command === 'help' || command === '--help') {
    console.log('APK Container Bridge\n  init [--state-dir PATH] [--projects-dir PATH] [--url https://Mac.local:48152] [--codex PATH]\n  start | pair | status | projects --json [--state-dir PATH]\n  profile --out PATH [--state-dir PATH]\nPairing credentials stay in private agent.prf files and are never printed.'); return;
  }
  throw new Error(`Unknown command ${command}`);
}
function invokedAsScript() {
  if (!process.argv[1]) return false;
  try {
    // Node resolves the module URL through symlinks, including macOS /var aliases.
    return fs.realpathSync(process.argv[1]) === fs.realpathSync(fileURLToPath(import.meta.url));
  } catch { return false; }
}
if (invokedAsScript()) main().catch(error => { console.error(JSON.stringify({ error: String(error.message || error) })); process.exitCode = 1; });

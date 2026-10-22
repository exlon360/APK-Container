// SPDX-License-Identifier: GPL-2.0-or-later
import fs from 'node:fs';
import path from 'node:path';
import https from 'node:https';
import crypto from 'node:crypto';
import { APIError } from './service.mjs';

function sendJSON(response, status, body) {
  response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' });
  response.end(JSON.stringify(body));
}
function authenticated(request, token) {
  const expected = Buffer.from(`Bearer ${token}`), actual = Buffer.from(request.headers.authorization || '');
  return actual.length === expected.length && crypto.timingSafeEqual(actual, expected);
}
async function body(request) {
  if (!(request.headers['content-type'] || '').startsWith('application/json')) throw new APIError(415, 'Send JSON data.');
  const chunks = []; let bytes = 0;
  for await (const chunk of request) { bytes += chunk.length; if (bytes > 128 * 1024) throw new APIError(413, 'This request is too large.'); chunks.push(chunk); }
  try {
    const value = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    if (!value || Array.isArray(value) || typeof value !== 'object') throw new Error();
    return value;
  } catch { throw new APIError(400, 'The request is not valid JSON.'); }
}
export async function startHTTPS(service, { host, port = service.config.port } = {}) {
  const server = https.createServer({ key: fs.readFileSync(path.join(service.config.stateDir, 'bridge-key.pem')), cert: fs.readFileSync(path.join(service.config.stateDir, 'bridge-cert.pem')), minVersion: 'TLSv1.2' }, async (request, response) => {
    try {
      // Native pinned clients do not send Origin; reject browser-originated operations.
      if (request.headers.origin) throw new APIError(403, 'Use the paired APK Container app.');
      if (!authenticated(request, service.configuration().token)) throw new APIError(401, 'Import this Mac’s agent.prf to pair the device.');
      const url = new URL(request.url, 'https://localhost'), segments = url.pathname.split('/').filter(Boolean);
      if (request.method === 'GET' && url.pathname === '/v1/status') { sendJSON(response, 200, service.status()); return; }
      if (segments.length < 2 || segments[0] !== 'v1' || segments[1] !== 'projects') throw new APIError(404, 'Unknown bridge endpoint.');
      if (segments.length === 2) {
        if (request.method === 'GET') { sendJSON(response, 200, { projects: service.list() }); return; }
        if (request.method === 'POST') { const input = await body(request); sendJSON(response, 201, { project: service.publicProject(service.create(input.name)) }); return; }
      }
      const id = segments[2];
      if (segments.length === 3 && request.method === 'GET') { sendJSON(response, 200, { project: service.publicProject(service.get(id)) }); return; }
      if (segments.length === 4 && request.method === 'POST') {
        if (segments[3] === 'messages') { const input = await body(request); sendJSON(response, 202, { project: service.publicProject(service.submit(id, input.text)) }); return; }
        if (segments[3] === 'interrupt') { await body(request); sendJSON(response, 200, { project: service.publicProject(await service.interrupt(id)) }); return; }
      }
      if (segments.length === 5 && segments[3] === 'approvals' && request.method === 'POST') { sendJSON(response, 200, { project: service.publicProject(service.answer(id, segments[4], await body(request))) }); return; }
      if (segments.length === 5 && segments[3] === 'artifacts' && request.method === 'GET') {
        const artifact = service.artifact(id, segments[4]);
        response.writeHead(200, { 'Content-Type': 'application/vnd.android.package-archive', 'Content-Length': artifact.bytes, 'Content-Disposition': `attachment; filename="${artifact.name.replace(/[^A-Za-z0-9._-]/g, '_')}"`, 'Cache-Control': 'no-store', 'X-APK-SHA256': artifact.sha256, 'X-Content-Type-Options': 'nosniff' });
        const stream = fs.createReadStream(artifact.file); stream.on('error', () => response.destroy()); stream.pipe(response); return;
      }
      throw new APIError(404, 'Unknown bridge endpoint.');
    } catch (error) {
      if (!response.headersSent) sendJSON(response, error.status || 503, { error: String(error.message || 'The Mac bridge could not complete this request.').slice(0, 3000) });
      else response.destroy();
    }
  });
  server.headersTimeout = 15000; server.requestTimeout = 30000; server.keepAliveTimeout = 5000; server.maxHeadersCount = 32;
  const listen = address => new Promise((resolve, reject) => {
    const failed = error => { server.off('listening', ready); reject(error); };
    const ready = () => { server.off('error', failed); resolve(); };
    server.once('error', failed); server.once('listening', ready);
    server.listen({ port, host: address, ipv6Only: false });
  });
  if (host !== undefined) await listen(host);
  else {
    // A .local name often resolves to IPv6 first. Bind a dual-stack socket so
    // those connections work as well as numeric IPv4 profile addresses.
    try { await listen('::'); }
    catch (error) {
      if (!['EAFNOSUPPORT', 'EADDRNOTAVAIL', 'EPROTONOSUPPORT'].includes(error.code)) throw error;
      await listen('0.0.0.0');
    }
  }
  return server;
}

// SPDX-License-Identifier: GPL-2.0-or-later
import os from 'node:os';
import net from 'node:net';

const MAX_ORIGINS = 6;

/** Only Ethernet/Wi-Fi addresses belong in an automatically exported LAN profile.
 * VPN, AWDL, loopback, VM and Docker interfaces are not phone-reachable defaults.
 * An explicitly configured VPN origin remains the primary address.
 */
export function lanIPv4Addresses(interfaces = os.networkInterfaces()) {
  const addresses = [];
  const names = Object.keys(interfaces).filter(name => /^en\d+$/.test(name))
    .sort((a, b) => Number(a.slice(2)) - Number(b.slice(2)));
  for (const name of names) for (const entry of interfaces[name] || []) {
    if (entry.internal || !['IPv4', 4].includes(entry.family) || net.isIP(entry.address) !== 4) continue;
    const octets = entry.address.split('.').map(Number);
    if (octets[0] === 0 || octets[0] === 127 || octets[0] >= 224 || (octets[0] === 169 && octets[1] === 254)) continue;
    if (!addresses.includes(entry.address)) addresses.push(entry.address);
  }
  return addresses;
}

/** Compute fresh export/status addresses without changing the stored identity,
 * token, certificate, or configured origin. Legacy clients read `url`; new
 * clients may probe the bounded alternate list using the same certificate pin.
 */
export function connectionOrigins(config, interfaces = os.networkInterfaces()) {
  const configured = new URL(config.url);
  if (configured.protocol !== 'https:' || configured.username || configured.password || configured.search || configured.hash || !['', '/'].includes(configured.pathname)) {
    throw new Error('The configured bridge address must be an HTTPS origin.');
  }
  const numeric = lanIPv4Addresses(interfaces).map(address => {
    const endpoint = new URL(configured.origin); endpoint.hostname = address; return endpoint.origin;
  });
  const localName = configured.hostname.toLowerCase().endsWith('.local');
  // Preserve the .local fallback even when a Mac has many network addresses.
  const preferred = localName && numeric.length ? [numeric[0], configured.origin, ...numeric.slice(1)] : [configured.origin, ...numeric];
  const origins = [...new Set(preferred)].slice(0, MAX_ORIGINS);
  return { url: origins[0], alternateURLs: origins.slice(1) };
}

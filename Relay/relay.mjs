import http from 'node:http';
import https from 'node:https';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const digest = value => crypto.createHash('sha256').update(value).digest('hex');
const token = () => crypto.randomBytes(32).toString('base64url');
const same = (value, hash) => typeof hash === 'string' && /^[0-9a-f]{64}$/.test(hash)
  && crypto.timingSafeEqual(Buffer.from(digest(value), 'hex'), Buffer.from(hash, 'hex'));
const validID = value => /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(value);
const save = (file, state) => {
  const next = file + '.next';
  fs.writeFileSync(next, JSON.stringify(state) + '\n', { mode: 0o600 });
  const fd = fs.openSync(next, 'r'); try { fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
  fs.renameSync(next, file);
};

export function createRelay({ stateFile, tls, ticketTTL = 120_000, waitTimeout = 45_000,
  sessionTimeout = 3_600_000, maximumBytes = 4 * 1024 ** 3 }) {
  const state = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
  if (!Array.isArray(state.routes) || state.routes.length > 64 || state.routes.some(r => !validID(r.id))) throw Error('Invalid relay state');
  const routes = new Map(state.routes.map(r => [r.id, r]));
  const tickets = new Map(), waiting = new Map(), active = new Map(), sockets = new Set(), requests = new Map();
  const metrics = { admitted: 0, rejected: 0, tunnels: 0, bytes: 0 };
  const server = tls ? https.createServer({ ...tls, minVersion: 'TLSv1.2', maxHeaderSize: 8192 }) : http.createServer({ maxHeaderSize: 8192 });
  server.requestTimeout = 10_000; server.headersTimeout = 10_000; server.keepAliveTimeout = 5_000;
  server.on('connection', socket => {
    if (sockets.size >= 128) { socket.destroy(); return; }
    sockets.add(socket); socket.on('close', () => sockets.delete(socket)); socket.on('error', () => {});
  });
  function auth(req) {
    const header = req.headers['authorization'] ?? req.headers['proxy-authorization'];
    if (typeof header !== 'string' || !header.startsWith('Basic ') || header.length > 256) return null;
    const value = Buffer.from(header.slice(6), 'base64').toString('utf8');
    const split = value.indexOf(':');
    if (split < 0 || !['host', 'client'].includes(value.slice(0, split))) return null;
    return { role: value.slice(0, split), secret: value.slice(split + 1) };
  }
  function limited(req) {
    const ip = req.socket.remoteAddress, now = Date.now();
    for (const [key, value] of requests) if (now - value.since > 60_000) requests.delete(key);
    if (!requests.has(ip)) { if (requests.size >= 1024) return true; requests.set(ip, { since: now, count: 0 }); }
    return ++requests.get(ip).count > 120;
  }
  function json(res, status, body) {
    res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }); res.end(JSON.stringify(body));
  }
  function closeRoute(id) {
    waiting.get(id)?.destroy(); waiting.delete(id);
    for (const pair of active.get(id) ?? []) { pair.host.destroy(); pair.client.destroy(); }
    active.delete(id);
    for (const [key, value] of tickets) if (value.route === id) tickets.delete(key);
  }
  server.on('request', (req, res) => {
    req.resume();
    if (req.method === 'GET' && req.url === '/healthz') { json(res, 200, { status: 'ready' }); return; }
    if (limited(req)) { json(res, 429, { error: 'rate_limit' }); return; }
    const match = /^\/v1\/routes\/([0-9a-f-]{36})\/(ticket|enable|revoke)$/.exec(req.url ?? '');
    const credentials = auth(req), route = match && routes.get(match[1]);
    if (req.method !== 'POST' || !route || !credentials || !same(credentials.secret, route[credentials.role + 'Hash'])) {
      metrics.rejected++; json(res, 403, { error: 'denied' }); return;
    }
    const action = match[2];
    if (action !== 'ticket') {
      if (credentials.role !== 'host') { json(res, 403, { error: 'denied' }); return; }
      const clientCapability = action === 'enable' ? token() : null;
      const previous = { ...route };
      route.enabled = action === 'enable'; route.clientHash = clientCapability ? digest(clientCapability) : null; route.revision++;
      try { save(stateFile, state); } catch { Object.assign(route, previous); json(res, 503, { error: 'storage_unavailable' }); return; }
      closeRoute(route.id);
      json(res, 200, { revision: route.revision, clientCapability }); return;
    }
    if (!route.enabled) { json(res, 403, { error: 'revoked' }); return; }
    const now = Date.now();
    for (const [key, value] of tickets) if (value.expires <= now) tickets.delete(key);
    if (tickets.size >= 256) { json(res, 429, { error: 'busy' }); return; }
    const value = token(), expires = now + ticketTTL;
    tickets.set(digest(value), { route: route.id, role: credentials.role, expires });
    metrics.admitted++;
    json(res, 200, { ticket: value, expiresAt: expires / 1000 });
  });
  server.on('connect', (req, socket, head) => {
    socket.pause();
    const reject = status => { metrics.rejected++; socket.end(`HTTP/1.1 ${status}\r\nConnection: close\r\n\r\n`); };
    if (limited(req)) { reject('429 Too Many Requests'); return; }
    const match = /^([0-9a-f-]{36})\.notebook:443$/.exec(req.url ?? ''), credentials = auth(req);
    if (!credentials) { socket.end('HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm="Notebook"\r\nConnection: close\r\n\r\n'); return; }
    const ticket = tickets.get(digest(credentials.secret));
    if (!match || !ticket || ticket.route !== match[1] || ticket.role !== credentials.role
      || ticket.expires <= Date.now() || !routes.get(ticket.route)?.enabled || head.length > 0) {
      reject('403 Forbidden'); return;
    }
    tickets.delete(digest(credentials.secret)); // one connection, never a replayable bearer
    const id = ticket.route;
    if ((active.get(id)?.size ?? 0) >= 2) { reject('429 Too Many Requests'); return; }
    if (ticket.role === 'host') {
      if (waiting.has(id)) { reject('409 Conflict'); return; }
      waiting.set(id, socket);
      const timer = setTimeout(() => { if (waiting.get(id) === socket) { waiting.delete(id); reject('408 Request Timeout'); } }, waitTimeout).unref();
      socket.once('close', () => { clearTimeout(timer); if (waiting.get(id) === socket) waiting.delete(id); });
      return;
    }
    const host = waiting.get(id);
    if (!host || host.destroyed) { reject('503 Service Unavailable'); return; }
    waiting.delete(id);
    const pair = { host, client: socket, bytes: 0 }, pairs = active.get(id) ?? new Set();
    pairs.add(pair); active.set(id, pairs); metrics.tunnels++;
    const timer = setTimeout(() => { host.destroy(); socket.destroy(); }, sessionTimeout).unref();
    const finish = () => { clearTimeout(timer); host.destroy(); socket.destroy(); pairs.delete(pair); if (!pairs.size) active.delete(id); };
    for (const stream of [host, socket]) {
      stream.once('close', finish); stream.once('error', finish);
      stream.on('data', data => { pair.bytes += data.length; metrics.bytes += data.length; if (pair.bytes > maximumBytes) finish(); });
      stream.setTimeout(120_000, finish);
      stream.setNoDelay(true);
      stream.write('HTTP/1.1 200 Connection Established\r\n\r\n');
    }
    // Node streams backpressure both directions; no payload retention or logging.
    host.pipe(socket); socket.pipe(host); host.resume(); socket.resume();
  });
  server.on('clientError', (_error, socket) => socket.destroy());
  const close = async () => { for (const socket of sockets) socket.destroy(); await new Promise(resolve => server.close(resolve)); };
  return { server, close, metrics };
}

function main() {
  const [command, stateFile, output, endpoint] = process.argv.slice(2);
  if (command === 'provision') {
    if (!stateFile || !output || !/^https:\/\/[a-z0-9.-]+$/.test(endpoint ?? '')) throw Error('provision STATE OUTPUT HTTPS_ENDPOINT');
    if (fs.existsSync(output)) throw Error('Provisioning output already exists');
    const state = fs.existsSync(stateFile) ? JSON.parse(fs.readFileSync(stateFile, 'utf8')) : { routes: [] };
    if (state.routes.length >= 64) throw Error('Route limit');
    const id = crypto.randomUUID(), capability = token();
    state.routes.push({ id, hostHash: digest(capability), clientHash: null, enabled: false, revision: 0 });
    fs.mkdirSync(path.dirname(stateFile), { recursive: true }); save(stateFile, state);
    fs.writeFileSync(output, JSON.stringify({ endpoint, route: id, capability }) + '\n', { mode: 0o600, flag: 'wx' });
    console.log('Provisioned route', id); return;
  }
  if (command !== 'serve' || !stateFile) throw Error('serve STATE');
  const readTLS = () => ({ cert: fs.readFileSync(process.env.NOTEBOOK_RELAY_CERT), key: fs.readFileSync(process.env.NOTEBOOK_RELAY_KEY) });
  const relay = createRelay({ stateFile, tls: readTLS() });
  relay.server.listen(Number(process.env.PORT ?? 443), '0.0.0.0', () => console.log('Notebook relay ready'));
  process.on('SIGHUP', () => { try { relay.server.setSecureContext(readTLS()); } catch { console.error('TLS reload failed'); } });
  process.on('SIGTERM', () => { void relay.close().then(() => process.exit(0)); });
  setInterval(() => console.log(JSON.stringify(relay.metrics)), 60_000).unref();
}
if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) main();

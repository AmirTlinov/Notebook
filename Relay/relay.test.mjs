import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import { once } from 'node:events';
import { createRelay } from './relay.mjs';
const hash = value => crypto.createHash('sha256').update(value).digest('hex');
const auth = (role, secret) => 'Basic ' + Buffer.from(role + ':' + secret).toString('base64');
async function fixture(t, options = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'notebook-relay-'));
  const id = crypto.randomUUID(), host = crypto.randomBytes(32).toString('base64url'), client = crypto.randomBytes(32).toString('base64url');
  const stateFile = path.join(root, 'state.json');
  fs.writeFileSync(stateFile, JSON.stringify({ routes: [{ id, hostHash: hash(host), clientHash: hash(client), enabled: true, revision: 1 }] }));
  const relay = createRelay({ stateFile, ...options });
  relay.server.listen(0, '127.0.0.1'); await once(relay.server, 'listening');
  t.after(async () => { await relay.close(); fs.rmSync(root, { recursive: true, force: true }); });
  const port = relay.server.address().port;
  const call = async (action, role, secret) => {
    const response = await fetch(`http://127.0.0.1:${port}/v1/routes/${id}/${action}`, { method: 'POST', headers: { Authorization: auth(role, secret) } });
    return { status: response.status, body: await response.json() };
  };
  const ticket = async role => (await call('ticket', role, role === 'host' ? host : client)).body.ticket;
  const connect = async (role, token, target = id + '.notebook:443') => {
    const socket = net.connect(port, '127.0.0.1'); socket.on('error', () => {}); await once(socket, 'connect');
    socket.write(`CONNECT ${target} HTTP/1.1\r\nHost: ${target}\r\nProxy-Authorization: ${auth(role, token)}\r\n\r\n`);
    return socket;
  };
  return { id, host, client, relay, call, ticket, connect };
}
const data = async socket => (await once(socket, 'data'))[0];
// TCP preserves bytes, not write/chunk boundaries. Accumulate the fixed payload.
function bytes(socket, count) {
  return new Promise((resolve, reject) => {
    const chunks = []; let size = 0;
    const timer = setTimeout(() => { cleanup(); reject(Error('Payload timeout')); }, 2000);
    function cleanup() { clearTimeout(timer); socket.off('data', received); socket.off('close', closed); }
    function closed() { cleanup(); reject(Error('Incomplete payload')); }
    function received(chunk) { chunks.push(chunk); size += chunk.length; if (size >= count) { cleanup(); resolve(Buffer.concat(chunks)); } }
    socket.on('data', received); socket.once('close', closed);
  });
}

test('a reverse carrier forwards only opaque bytes, with bounded active pairs', async t => {
  const f = await fixture(t), h = await f.ticket('host'), c = await f.ticket('client');
  const host = await f.connect('host', h), hostReady = data(host);
  const client = await f.connect('client', c), clientReady = data(client);
  assert.match((await hostReady).toString(), /200 Connection Established/);
  assert.match((await clientReady).toString(), /200 Connection Established/);
  const payload = crypto.randomBytes(32 * 1024), received = bytes(host, payload.length); client.write(payload);
  assert.deepEqual(await received, payload);
  const back = bytes(client, payload.length); host.write(payload); assert.deepEqual(await back, payload);
  assert.equal(f.relay.metrics.tunnels, 1);
});

test('tickets are single-use, expire, and cannot open an arbitrary CONNECT destination', async t => {
  const f = await fixture(t, { ticketTTL: 80, waitTimeout: 100 });
  const forged = await f.connect('client', 'wrong'); assert.match((await data(forged)).toString(), /403/);
  const c = await f.ticket('client');
  const arbitrary = await f.connect('client', c, 'example.com:443'); assert.match((await data(arbitrary)).toString(), /403/);
  await new Promise(resolve => setTimeout(resolve, 100));
  const expired = await f.connect('client', c); assert.match((await data(expired)).toString(), /403/);
  const h = await f.ticket('host'); const first = await f.connect('host', h);
  const replay = await f.connect('host', h); assert.match((await data(replay)).toString(), /403/);
  first.destroy();
});

test('revocation closes both ends and denies old client credentials; re-enrollment rotates them', async t => {
  const f = await fixture(t); const host = await f.connect('host', await f.ticket('host')), ready = data(host);
  const client = await f.connect('client', await f.ticket('client')); await data(client); await ready;
  const closedHost = once(host, 'close'), closedClient = once(client, 'close');
  assert.equal((await f.call('revoke', 'host', f.host)).status, 200); await closedHost; await closedClient;
  assert.equal((await f.call('ticket', 'client', f.client)).status, 403);
  const enabled = await f.call('enable', 'host', f.host); assert.equal(enabled.status, 200);
  assert.notEqual(enabled.body.clientCapability, f.client);
  assert.equal((await f.call('ticket', 'client', enabled.body.clientCapability)).status, 200);
  assert.equal((await f.call('enable', 'client', enabled.body.clientCapability)).status, 403);
});

test('byte quota terminates both streams without retaining their payload', async t => {
  const f = await fixture(t, { maximumBytes: 1024 });
  const host = await f.connect('host', await f.ticket('host')), ready = data(host);
  const client = await f.connect('client', await f.ticket('client')); await data(client); await ready;
  const closed = once(client, 'close'); client.write(crypto.randomBytes(4096)); await closed;
  assert.ok(f.relay.metrics.bytes >= 4096);
});

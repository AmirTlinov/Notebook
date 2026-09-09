import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { mkdtemp, mkdir, readFile, writeFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { gunzipSync } from 'node:zlib';
import { selectedPNG, imageItems, event, respond, textItem, catalog } from './provider-support.mjs';
import { createHash } from 'node:crypto';

const [harness, repository] = process.argv.slice(2);
const binary = process.env.NOTEBOOK_CONTRACT_CODEX ?? '/Users/amir/.local/bin/codex';
const profile = join(repository, 'Applications/Mac/AgentRuntime/notebook.config.toml');
const report = [];
const answer = 'Подтверждённый ответ. '.repeat(500);

function requireNotebookOnly(request) {
  const tools = catalog(request);
  assert.equal(request.model, 'gpt-5.5');
  assert.equal(tools.length, 1, JSON.stringify(tools));
  assert.equal(tools[0].type, 'namespace'); assert.equal(tools[0].name, 'notebook');
  assert.deepEqual(tools[0].tools.map(x => x.name), ['read']);
  assert.equal(tools[0].tools[0].type, 'function');
}

async function scenario(name, { corruptProfile = false, corruptBinary = false, text = answer } = {}) {
  const root = await mkdtemp(join(tmpdir(), 'notebook-executor-contract-'));
  const home = join(root, 'runtime');
  await mkdir(home, { mode: 0o700 });
  const imagePath = join(root, 'frozen-reference.png'); await writeFile(imagePath, selectedPNG, { mode: 0o600 });
  let selectedProfile = profile, selectedBinary = binary;
  if (corruptProfile) {
    selectedProfile = join(root, 'altered.toml');
    await writeFile(selectedProfile, (await readFile(profile, 'utf8')).replace('shell_tool = false', 'shell_tool = true'));
  }
  if (corruptBinary) {
    selectedBinary = join(root, 'unverified-codex');
    await writeFile(selectedBinary, '#!/bin/sh\necho should-never-run > "' + join(root, 'unsafe-executed') + '"\n', { mode: 0o700 });
  }
  const requests = [], events = []; let providerError, diagnostics = '', running;
  const server = createServer(async (request, response) => {
    try {
      if (request.method !== 'POST' || request.url !== '/v1/responses') { response.writeHead(404); response.end(); return; }
      const chunks = []; let size = 0;
      for await (const chunk of request) { size += chunk.length; assert.ok(size <= 4 * 1024 * 1024); chunks.push(chunk); }
      let bytes = Buffer.concat(chunks);
      if (request.headers['content-encoding'] === 'gzip') bytes = gunzipSync(bytes);
      const value = JSON.parse(bytes.toString()); requests.push(value); requireNotebookOnly(value);
      if (name === 'cancel' || name === 'cancel_during_tool' && requests.length > 1) {
        response.writeHead(200, { 'content-type': 'text/event-stream' });
        event(response, { type: 'response.created', response: { id: 'resp_wait', object: 'response', status: 'in_progress', output: [] } });
        if (name === 'cancel') running.stdin.write('cancel\n');
        return;
      }
      if (requests.length === 1) respond(response, { id: 'fc_contract', type: 'function_call', namespace: 'notebook', name: 'read', call_id: 'stable-notebook-call-1', arguments: '{}' });
      else {
        assert.ok(JSON.stringify(value.input).includes('stable-notebook-call-1'));
        const images = imageItems(value.input);
        if (name === 'image') {
          assert.equal(images.length, 1, 'Vision must be an actual input_image content item, not JSON text.');
          assert.equal(images[0].image_url, 'data:image/png;base64,' + selectedPNG.toString('base64'));
          assert.equal(createHash('sha256').update(Buffer.from(images[0].image_url.split(',')[1], 'base64')).digest('hex'),
            createHash('sha256').update(selectedPNG).digest('hex'));
        } else assert.equal(images.length, 0);
        respond(response, textItem(text));
      }
    } catch (error) { providerError = error; response.writeHead(500); response.end(); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const url = `http://127.0.0.1:${server.address().port}/v1`;
  try {
    running = spawn(harness, [selectedBinary, home, selectedProfile, url, name, imagePath], { env: { PATH: '/usr/bin:/bin', HOME: root }, stdio: ['pipe', 'pipe', 'pipe'] });
    running.stderr.on('data', x => { diagnostics = (diagnostics + x.toString()).slice(-16384); });
    createInterface({ input: running.stdout }).on('line', line => {
      const value = JSON.parse(line); events.push(value);
      if (name === 'cancel_during_tool' && value.event === 'toolAdmitted') running.stdin.write('cancel\n');
    });
    const timeout = setTimeout(() => running.kill('SIGKILL'), 20000);
    const [code, signal] = await new Promise(resolve => running.once('exit', (...args) => resolve(args))); clearTimeout(timeout);
    assert.equal(code, 0, `${name}: ${signal ?? ''} ${diagnostics} ${JSON.stringify(events)}`);
    if (providerError) throw providerError;
    const done = events.find(x => x.event === 'complete'); assert.ok(done, JSON.stringify(events));
    if (corruptProfile || corruptBinary) {
      assert.equal(done.status, 'unavailable'); assert.equal(done.failure, corruptProfile ? 'unsupportedProfile' : 'unsupportedRuntime');
      assert.equal(requests.length, 0);
      if (corruptBinary) await assert.rejects(readFile(join(root, 'unsafe-executed')));
    } else if (name.startsWith('cancel')) {
      assert.equal(done.status, 'interrupted'); assert.ok(events.some(x => x.event === 'cancelAck' && x.acknowledged));
      if (name === 'cancel_during_tool') {
        assert.deepEqual(done.calls, ['stable-notebook-call-1']);
        assert.ok(events.findIndex(x => x.event === 'toolAdmitted') < events.findIndex(x => x.event === 'cancelRequested'));
        assert.ok(events.findIndex(x => x.event === 'cancelRequested') < events.findIndex(x => x.event === 'toolDrained'));
        assert.ok(events.findIndex(x => x.event === 'toolDrained') < events.findIndex(x => x.event === 'cancelAck'));
      }
    } else if (name === 'response_limit') {
      assert.equal(done.status, 'failed'); assert.equal(done.failure, 'responseLimit');
    } else {
      assert.equal(done.status, 'completed'); assert.equal(done.answer, text);
      assert.deepEqual(done.calls, ['stable-notebook-call-1']); assert.ok(done.chunks.every(n => n > 0 && n <= 8192));
      assert.ok(done.chunks.length > 1); assert.equal(requests.length, 2);
    }
    report.push({ scenario: name, status: done.status, requests: requests.length, tools: requests.map(catalog), events: events.map(x => ({ ...x, answer: x.answer ? `${Buffer.byteLength(x.answer)} UTF-8 bytes` : x.answer })) });
    console.log(`PASS ${name}`);
  } catch (error) {
    console.error(JSON.stringify({ name, diagnostics, events, requestCount: requests.length }, null, 2)); throw error;
  } finally {
    running?.kill('SIGTERM'); server.closeAllConnections(); await new Promise(resolve => server.close(resolve));
    await rm(root, { recursive: true, force: true });
  }
}

await scenario('complete');
await scenario('image');
await scenario('cancel');
await scenario('cancel_during_tool');
await scenario('response_limit', { text: 'a'.repeat(1_048_577) });
await scenario('unknown_profile', { corruptProfile: true });
await scenario('unknown_binary', { corruptBinary: true });
await writeFile(join(repository, '.build/agent-executor-contract/report.json'), JSON.stringify(report, null, 2));

// Negative control: merely supplying dynamicTools and disabling code_mode does NOT constrain
// a code_mode_only model. This separate raw probe never feeds user content or executes a tool.
async function codeModeOnlyNegativeControl() {
  const root = await mkdtemp(join(tmpdir(), 'notebook-code-mode-control-'));
  await mkdir(join(root, 'cwd')); await mkdir(join(root, 'tmp'));
  await writeFile(join(root, 'config.toml'), await readFile(profile), { mode: 0o600 });
  let observed, child, diagnostic = '';
  const server = createServer(async (request, response) => {
    const chunks = []; for await (const chunk of request) chunks.push(chunk);
    let bytes = Buffer.concat(chunks); if (request.headers['content-encoding'] === 'gzip') bytes = gunzipSync(bytes);
    observed = catalog(JSON.parse(bytes.toString()));
    respond(response, textItem('No tool execution in the negative control.'));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const provider = `{name="Negative control",base_url="http://127.0.0.1:${server.address().port}/v1",wire_api="responses",requires_openai_auth=false,supports_websockets=false,request_max_retries=0,stream_max_retries=0}`;
  const pending = new Map(); let sequence = 0, turnDone;
  const done = new Promise(resolve => { turnDone = resolve; });
  const call = (method, params) => new Promise((resolve, reject) => {
    const id = ++sequence; pending.set(id, { resolve, reject }); child.stdin.write(JSON.stringify({ id, method, params }) + '\n');
  });
  let timeout;
  try {
    child = spawn(binary, ['app-server', '--stdio', '--strict-config', '-c', 'model="gpt-5.6-sol"', '-c', 'model_provider="contract_mock"', '-c', `model_providers.contract_mock=${provider}`],
      { cwd: join(root, 'cwd'), env: { HOME: root, CODEX_HOME: root, TMPDIR: join(root, 'tmp'), PATH: '/usr/bin:/bin', RUST_LOG: 'off' }, stdio: ['pipe', 'pipe', 'pipe'] });
    child.stderr.on('data', bytes => { diagnostic = (diagnostic + bytes.toString()).slice(-16000); });
    createInterface({ input: child.stdout }).on('line', line => {
      const value = JSON.parse(line);
      if (value.id && pending.has(value.id)) { const waiter = pending.get(value.id); pending.delete(value.id); value.error ? waiter.reject(value.error) : waiter.resolve(value.result); }
      if (value.id && value.method) child.stdin.write(JSON.stringify({ id: value.id, error: { code: -32601, message: 'Negative control executes no tools.' } }) + '\n');
      if (value.method === 'turn/completed') turnDone();
    });
    child.once('exit', () => { for (const waiter of pending.values()) waiter.reject(new Error(diagnostic)); pending.clear(); turnDone(); });
    timeout = setTimeout(() => child.kill('SIGKILL'), 20000);
    await call('initialize', { clientInfo: { name: 'notebook_negative_catalog', version: '1' }, capabilities: { experimentalApi: true } });
    child.stdin.write(JSON.stringify({ method: 'initialized', params: {} }) + '\n');
    const thread = await call('thread/start', { model: 'gpt-5.6-sol', ephemeral: true, allowProviderModelFallback: false,
      cwd: join(root, 'cwd'), environments: [], runtimeWorkspaceRoots: [], selectedCapabilityRoots: [], sandbox: 'read-only', approvalPolicy: 'never',
      dynamicTools: [{ type: 'namespace', name: 'notebook', description: 'Only the test Notebook grant.', tools: [{ type: 'function', name: 'read', description: 'Isolated addressed read.', inputSchema: { type: 'object', properties: {}, additionalProperties: false } }] }] });
    await call('turn/start', { threadId: thread.thread.id, environments: [], input: [{ type: 'text', text: 'Negative catalogue control. Reply without calling tools.' }] });
    await done;
    assert.ok(observed?.some(tool => tool.type === 'namespace' && tool.name === 'functions' && tool.tools.some(child => child.name === 'exec')));
    report.push({ scenario: 'code_mode_only_is_not_an_admissible_profile', tools: observed.map(tool => ({ type: tool.type, name: tool.name, tools: tool.tools?.map(child => child.name) })) });
    console.log('PASS code_mode_only_is_not_an_admissible_profile');
  } finally {
    clearTimeout(timeout); child?.kill('SIGTERM'); server.closeAllConnections(); await new Promise(resolve => server.close(resolve));
    if (child && child.exitCode === null) await new Promise(resolve => { const kill = setTimeout(() => child.kill('SIGKILL'), 1000); child.once('exit', () => { clearTimeout(kill); resolve(); }); });
    await rm(root, { recursive: true, force: true });
  }
}
await codeModeOnlyNegativeControl();
await writeFile(join(repository, '.build/agent-executor-contract/report.json'), JSON.stringify(report, null, 2));

console.log('Notebook App Server contract: all 8 real-process checks passed.');

import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { gunzipSync } from 'node:zlib';
import { selectedPNG, imageItems, event, respond, textItem, catalog } from './provider-support.mjs';

const [harness, repository] = process.argv.slice(2);
const binary = process.env.NOTEBOOK_CONTRACT_CODEX ?? '/Users/amir/.local/bin/codex';
const profile = join(repository, 'Applications/Mac/AgentRuntime/notebook.config.toml');
const answer = 'Сохранённый ответ 👨‍👩‍👧‍👦 é по выбранному фрагменту. '.repeat(500);
const report = [];
const call = (name, args, suffix = name) => ({ id: `fc_${suffix}`, type: 'function_call', namespace: 'notebook', name,
  call_id: `stable-${suffix}`, arguments: JSON.stringify(args) });
function outputFor(value, callID) {
  return (value.input ?? []).find(item => item.type === 'function_call_output' && item.call_id === callID);
}
function outputText(value, callID) {
  const result = outputFor(value, callID); assert.ok(result, JSON.stringify(value.input));
  if (typeof result.output === 'string') return result.output;
  return (result.output ?? []).filter(item => item.type === 'input_text').map(item => item.text).join('');
}

async function scenario(name) {
  const root = await mkdtemp(join(tmpdir(), 'notebook-coordinator-contract-'));
  const pngPath = join(root, 'selected.png'); await writeFile(pngPath, selectedPNG, { mode: 0o600 });
  const change = ['change', 'input_active', 'input_stop', 'mutation_unconfirmed'].includes(name);
  const events = [], requests = []; let child, fixture, providerError, diagnostics = '', probeSentAt;
  const server = createServer(async (request, response) => {
    try {
      if (request.method !== 'POST' || request.url !== '/v1/responses') { response.writeHead(404); response.end(); return; }
      const chunks = []; let size = 0;
      for await (const chunk of request) { size += chunk.length; assert.ok(size <= 8 * 1024 * 1024); chunks.push(chunk); }
      let bytes = Buffer.concat(chunks); if (request.headers['content-encoding'] === 'gzip') bytes = gunzipSync(bytes);
      const value = JSON.parse(bytes.toString()); requests.push(value);
      const tools = catalog(value);
      assert.equal(value.model, 'gpt-5.5'); assert.equal(tools.length, 1);
      assert.equal(tools[0].type, 'namespace'); assert.equal(tools[0].name, 'notebook');
      assert.deepEqual(tools[0].tools.map(x => x.name).sort(), change ? ['apply', 'read', 'render'] : ['read', 'render']);
      assert.ok(fixture, 'A durable request exists before its model turn.');
      assert.ok(!JSON.stringify(value).includes('Private outside source'));
      assert.ok(!JSON.stringify(value).includes('New live text, not the selected source'));
      if (name === 'stop') {
        response.writeHead(200, { 'content-type': 'text/event-stream' });
        event(response, { type: 'response.created', response: { id: 'resp_wait', object: 'response', status: 'in_progress', output: [] } });
        child.stdin.write('stop\n'); return;
      }
      if (requests.length === 1) { respond(response, call('read', { referenceID: fixture.referenceID })); return; }
      if (requests.length === 2) {
        const source = JSON.parse(outputText(value, 'stable-read'));
        assert.equal(source.hasImage, true); assert.equal(source.source.reference.id.toLowerCase(), fixture.referenceID.toLowerCase());
        assert.ok(JSON.stringify(source).includes('Frozen selected text')); assert.equal(source.source.image, undefined);
        assert.ok(!JSON.stringify(source).includes(selectedPNG.toString('base64')));
        respond(response, call('render', { referenceID: fixture.referenceID })); return;
      }
      if (requests.length === 3) {
        const images = imageItems(value.input); assert.equal(images.length, 1);
        assert.equal(images[0].image_url, 'data:image/png;base64,' + selectedPNG.toString('base64'));
        if (change && name !== 'mutation_unconfirmed') {
          respond(response, call('apply', { summary: 'Подпись внутри разрешённого фрагмента', operations: [{
            kind: 'insertElement', target: fixture.target, id: 'agent-answer',
            values: { kind: 'markdown', source: 'Сохранённое действие', frame: { x: 100, y: 30, width: 80, height: 40 } }
          }] }));
          if (name === 'input_active' || name === 'input_stop') {
            // Probe while the real Core input gate rejects the admitted tool; the writer must remain free.
            setTimeout(() => { probeSentAt = performance.now(); child.stdin.write('queue-probe\n'); }, 100);
          }
          return;
        }
        respond(response, textItem(answer)); return;
      }
      const output = JSON.parse(outputText(value, 'stable-apply'));
      assert.ok(output.id, JSON.stringify(output));
      assert.equal(output.action.requestID.toLowerCase(), fixture.requestID.toLowerCase());
      assert.equal(output.action.operations[0].id, 'agent-answer');
      respond(response, textItem(answer));
    } catch (error) { providerError = error; response.writeHead(500); response.end(); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  try {
    child = spawn(harness, [binary, root, profile, `http://127.0.0.1:${server.address().port}/v1`, name, pngPath],
      { env: { PATH: '/usr/bin:/bin', HOME: root }, stdio: ['pipe', 'pipe', 'pipe'] });
    child.stderr.on('data', bytes => { diagnostics = (diagnostics + bytes.toString()).slice(-20000); });
    createInterface({ input: child.stdout }).on('line', line => {
      try {
        const value = JSON.parse(line); events.push(value);
        if (value.event === 'fixture') fixture = value;
        if (value.event === 'writerAvailable') {
          value.latencyMs = performance.now() - probeSentAt;
          assert.equal(value.inputHeld, true); assert.ok(value.latencyMs < 1000, 'An input retry held the one writer.');
          child.stdin.write(name === 'input_stop' ? 'stop\n' : 'release\n');
        }
      } catch (error) { providerError = error; child.kill('SIGTERM'); }
    });
    const timeout = setTimeout(() => child.kill('SIGKILL'), 30000);
    const [code, signal] = await new Promise(resolve => child.once('exit', (...args) => resolve(args))); clearTimeout(timeout);
    if (providerError) throw providerError;
    assert.equal(code, 0, `${name}: ${signal ?? ''} ${diagnostics} ${JSON.stringify(events)}`);
    const done = events.find(x => x.event === 'complete'); assert.ok(done, JSON.stringify(events));
    assert.equal(done.stoppedCleanly, true); assert.equal(done.idempotentStop, true, 'Repeated wake/quit cannot create another execution or answer.');
    if (name === 'stop' || name === 'input_stop') {
      assert.equal(done.status, 'stopped'); assert.ok(events.some(x => x.event === 'stopCommitted'));
      assert.equal(done.savedElements, 0); assert.equal(done.snapshot.execution.receiptIDs.length, 0);
    } else if (name === 'mutation_unconfirmed') {
      assert.equal(done.status, 'failed'); assert.equal(done.snapshot.responseText, answer);
      assert.equal(done.snapshot.execution.receiptIDs.length, 0); assert.equal(done.snapshot.execution.answerEntryID, undefined);
      assert.match(done.snapshot.execution.error, /квитанции/);
    } else {
      assert.equal(done.status, 'completed'); assert.equal(done.snapshot.responseText, answer);
      assert.ok(done.snapshot.execution.answerEntryID); assert.ok(done.snapshot.execution.responseSequence > 1);
      assert.equal(done.snapshot.execution.responseBytes, Buffer.byteLength(answer));
      assert.equal(done.savedElements, change ? 1 : 0);
      assert.equal(done.snapshot.execution.receiptIDs.length, change ? 1 : 0);
    }
    if (name === 'input_active' || name === 'input_stop') assert.ok(events.some(x => x.event === 'writerAvailable'));
    report.push({ scenario: name, status: done.status, requests: requests.length,
      bytes: done.snapshot.execution.responseBytes, chunks: done.snapshot.execution.responseSequence,
      receipts: done.snapshot.execution.receiptIDs, idempotentStop: done.idempotentStop,
      events: events.filter(x => x.event !== 'complete') });
    console.log(`PASS coordinator ${name}`);
  } catch (error) { console.error(JSON.stringify({ name, diagnostics, events, requests: requests.length }, null, 2)); throw error; }
  finally {
    child?.kill('SIGTERM'); server.closeAllConnections(); await new Promise(resolve => server.close(resolve));
    await rm(root, { recursive: true, force: true });
  }
}
for (const name of ['question', 'change', 'mutation_unconfirmed', 'input_active', 'stop', 'input_stop']) await scenario(name);
await writeFile(join(repository, '.build/agent-coordinator-contract/report.json'), JSON.stringify(report, null, 2));
console.log('Notebook coordinator: all 6 real SQL/App Server checks passed.');

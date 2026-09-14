import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

// Execute the actual body-free startup handshake from the bundled shell.
// Native tests separately verify WK identity, admission and physical adoption.
const html = fs.readFileSync(new URL('../../Applications/WebResources/document-shell.html', import.meta.url), 'utf8');
const start = html.indexOf('      // A body-free shell may finish common startup');
assert(start >= 0);
const end = html.indexOf('    })();', start);
assert(end > start);
const source = html.slice(start, end);
const turn = () => new Promise(resolve => setImmediate(resolve));

function execution(math) {
  const messages = [], errors = [];
  vm.runInNewContext(source, { MathJax: math, bridge: value => messages.push(value.kind),
    diagnostic: (...values) => errors.push(values) });
  return { messages, errors };
}

let complete, typesettings = 0;
const pending = new Promise(resolve => { complete = resolve; });
const success = execution({ startup: { promise: pending }, typesetPromise() { typesettings += 1; } });
await turn();
assert.deepEqual(success.messages, [], 'A bridge or DOM load alone cannot acknowledge common startup');
complete(); await turn();
assert.deepEqual(success.messages, ['commonRuntimeReady']);
assert.equal(typesettings, 0, 'The empty shell cannot typeset a document or perform a canonical measurement');
assert.deepEqual(success.errors, []);

const broken = execution({ startup: { promise: Promise.reject(new Error('actual startup failed')) }, typesetPromise() {} });
await turn();
assert.deepEqual(broken.messages, ['commonRuntimeFailed']);
assert.equal(broken.errors.length, 1);
const incomplete = execution({ startup: { promise: Promise.resolve() } });
await turn();
assert.deepEqual(incomplete.messages, ['commonRuntimeFailed']);
assert.equal(incomplete.errors.length, 1);
console.log('3 actual shell handshake contracts passed');

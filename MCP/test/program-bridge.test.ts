import assert from 'node:assert/strict';
import test from 'node:test';
import {readFileSync} from 'node:fs';
import {createContext, runInContext} from 'node:vm';

const source = readFileSync(new URL('../../Applications/WebResources/notebook-program.js', import.meta.url), 'utf8');
function fixture(options: Record<string, unknown> = {}) {
  const commits: unknown[] = [], diagnostics: unknown[] = [], events: any[] = [];
  const context = createContext({setTimeout, clearTimeout, AbortController, CustomEvent,
    dispatchEvent: (event: any) => events.push(event)});
  runInContext(source, context);
  const program = context.createNotebookProgram({state:{phase:0},timeoutMS:30,readyTimeoutMS:30,
    onCommit:(...value: unknown[]) => commits.push(value),
    report:(...value: unknown[]) => diagnostics.push(value), ...options});
  const json = (value: unknown) => JSON.parse(JSON.stringify(value));
  return {program, api:program.api, commits, diagnostics, events, json};
}

test('one API owns canonical commits, copied JSON state and revision-guarded external state', async () => {
  const {program,api,commits,events,json} = fixture();
  api.state.phase = 90;
  assert.equal(api.state.phase, 0);
  assert.equal(api.commit({phase:0}), false);
  assert.equal(api.commit({phase:1}), true);
  assert.equal(await program.apply({phase:9}, '0'), false);
  assert.equal(await program.apply({phase:2}, '1'), true);
  assert.deepEqual(json(commits), [[{phase:1},'1']]);
  assert.deepEqual(json(events[0].detail), {phase:2});
});

test('missing, rejected and hung ready never complete as ready; static markup needs no declaration', async () => {
  await assert.rejects(fixture().program.start(), /program_completion_unknown/);
  const rejected = fixture(); rejected.api.ready(Promise.reject(new Error('author setup')));
  await assert.rejects(rejected.program.start(), /author setup/);
  const hung = fixture(); hung.api.ready(new Promise(() => {}));
  await assert.rejects(hung.program.start(), /program_ready_timeout/);
  assert.equal((await fixture().program.start({requiresReady:false})).version, 'NotebookProgram/1');
});

test('ready waits for every declared setup and the paint boundary', async () => {
  let finish!: () => void, painted = false;
  const {program,api} = fixture({paint:() => { painted = true; }});
  api.ready(new Promise<void>(resolve => { finish = resolve; }));
  api.ready(Promise.resolve());
  const ready = program.start();
  await Promise.resolve(); assert.equal(painted, false);
  finish(); await ready;
  assert.equal(painted, true);
  assert.throws(() => api.ready(Promise.resolve()), /declared_late/);
});

test('checkpoint stops the author before reading its actual playhead; no optimistic writer commit', async () => {
  const order: string[] = [];
  const {program,api,commits,json} = fixture({paint:() => order.push('paint')});
  let phase = 0.375;
  api.lifecycle({pause:() => order.push('pause'), checkpoint:() => {
    order.push('checkpoint'); return {phase};
  }, resume:() => order.push('resume'), dispose:() => order.push('dispose')});
  assert.deepEqual(json(await program.checkpoint()), {phase});
  assert.deepEqual(order, ['pause','checkpoint']);
  assert.equal(api.commit({phase:0.8}), false);
  assert.equal(await program.apply({phase:0.9}), false);
  assert.equal(commits.length, 0, 'Native owner, not JS, must confirm persistence');
  await program.resume(); assert.equal(program.suspended, false);
  assert.equal(api.commit({phase:0.5}), true);
  await program.dispose(); await program.dispose();
  assert.equal(order.filter(value => value === 'dispose').length, 1);
  assert.equal(api.commit({phase:0.6}), false);
});

test('a parked program checkpoints without waiting for a hidden viewport paint', async () => {
  const {program,api} = fixture({paint:() => new Promise(() => {})});
  api.lifecycle({checkpoint:() => ({phase:0.25})});
  assert.equal((await program.checkpoint()).phase, 0.25);
});

test('a completed frozen checkpoint is idempotent until resume', async () => {
  let pauses = 0, checkpoints = 0;
  const {program, api} = fixture();
  api.lifecycle({pause:() => { pauses++; }, checkpoint:() => ({phase:++checkpoints})});
  assert.equal((await program.checkpoint()).phase, 1);
  assert.equal((await program.checkpoint()).phase, 1);
  assert.equal(pauses, 1);
  await program.resume();
  assert.equal((await program.checkpoint()).phase, 2);
});

test('failed checkpoint retains last explicit state and permits owner-controlled recovery', async () => {
  const {program,api} = fixture();
  api.lifecycle({checkpoint:() => { throw new Error('author checkpoint'); }});
  await assert.rejects(program.checkpoint(), /author checkpoint/);
  assert.equal(api.state.phase, 0);
  assert.equal(program.suspended, true);
  await program.resume();
  assert.equal(api.commit({phase:0.5}), true);
});

test('timeout aborts the author request; late completion cannot change state', async () => {
  let finish!: (value: unknown) => void, signal!: AbortSignal;
  const {program,api} = fixture();
  api.lifecycle({checkpoint:(context: {signal: AbortSignal}) => {
    signal = context.signal; return new Promise(resolve => { finish = resolve; });
  }});
  await assert.rejects(program.checkpoint(), /program_checkpoint_timeout/);
  assert.equal(signal.aborted, true);
  await program.resume(); api.commit({phase:0.25});
  finish({phase:0.75}); await new Promise(resolve => setTimeout(resolve, 0));
  assert.equal(api.state.phase, 0.25);
});

test('dispose or return supersedes an in-flight checkpoint, without a late state publication', async () => {
  for (const operation of ['dispose','resume']) {
    let finish!: (value: unknown) => void;
    const {program,api} = fixture();
    api.lifecycle({checkpoint:() => new Promise(resolve => { finish = resolve; })});
    const pending = program.checkpoint();
    await new Promise(resolve => setTimeout(resolve, 0));
    const rejected = assert.rejects(pending, /program_superseded/);
    await program[operation](); await rejected;
    finish({phase:0.75}); await new Promise(resolve => setTimeout(resolve, 0));
    assert.equal(api.state.phase, 0);
  }
});

test('a failed program cannot serialize checkpoints or block an independent program', async () => {
  const a = fixture(), b = fixture();
  a.api.lifecycle({checkpoint:() => new Promise(() => {})});
  const failure = assert.rejects(a.program.checkpoint(), /timeout/);
  await assert.rejects(a.program.checkpoint(), /busy/);
  b.api.lifecycle({checkpoint:() => ({phase:0.5})});
  assert.equal((await b.program.checkpoint()).phase, 0.5);
  await failure;
});

test('invalid lifecycle registration and non-JSON state are rejected before mutation', () => {
  const {api} = fixture();
  assert.throws(() => api.lifecycle({scheduler:() => {}}), /invalid/);
  api.lifecycle({pause:() => {}});
  assert.throws(() => api.lifecycle({}), /invalid/);
  assert.throws(() => api.commit(undefined));
  assert.equal(api.state.phase, 0);
});

const lcSource = readFileSync(new URL('../skills/notebook/assets/animation/lc.js', import.meta.url), 'utf8');
test('LC uses one analytic model: quarter-period signs, SI units and conserved energy', () => {
  const context = createContext({});
  runInContext(lcSource.slice(0,lcSource.indexOf('\n(() => {')), context);
  for (const inductance of [10,100,200]) for (const capacitance of [10,25,100]) for (const voltage of [1,5,10]) {
    const samples = [0,.25,.5,.75,1].map(phase => context.sampleLC({phase,inductance,capacitance,voltage}));
    for (const s of samples) assert.ok(Math.abs(s.electric+s.magnetic-s.total)<1e-14);
    assert.ok(Math.abs(samples[0].q-samples[0].Q)<1e-14);
    assert.ok(Math.abs(samples[1].q)<1e-14);
    assert.ok(samples[1].I<0 && samples[3].I>0);
    assert.ok(Math.abs(samples[2].q+samples[0].Q)<1e-14);
    assert.ok(Math.abs(samples[0].q-samples[4].q)<1e-14);
  }
});

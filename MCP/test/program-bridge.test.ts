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

test('native focus admission rejects timers before true and preserves every already accepted snapshot', async () => {
  const snapshots: any[] = [];
  const {program, api, events} = fixture({stateTransport:{enabled:false,credit:65536,
    onSnapshot:(snapshot:unknown)=>snapshots.push(snapshot),requestCredit:()=>{}}});
  assert.equal(api.commit({phase:1}), false);
  assert.equal(api.state.phase, 0); assert.equal(snapshots.length, 0);
  program.setCommitEnabled(true); // The existing trusted-input capture runs before the authored click.
  assert.equal(api.commit({phase:1}), true);
  program.setCommitEnabled(false);
  assert.equal(api.commit({phase:2}), false);
  assert.equal(JSON.parse(program.readSnapshot({revision:'1',offset:0})).phase, 1);
  let drained = false;
  const checkpoint = program.checkpoint().then((value:any)=>{drained=true;return value;});
  await Promise.resolve(); assert.equal(drained, false);
  program.acknowledgeSnapshot('1');
  assert.equal((await checkpoint).phase, 1);
  assert.equal(snapshots.length, 1);
  assert.equal(events.filter(event=>event.type==='notebookcapacity').length, 1);
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
  const joined = assert.rejects(a.program.checkpoint(), /timeout/);
  b.api.lifecycle({checkpoint:() => ({phase:0.5})});
  assert.equal((await b.program.checkpoint()).phase, 0.5);
  await failure; await joined;
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

test('semantic selection is copied only after a successful pause and never read from a running scene', async () => {
  const {program,api,json} = fixture();
  let phase = .25, calls = 0;
  const selected = {objectID:'gear-a',label:'Gear',anchor:{x:.4,y:.5},values:[{label:'angle',value:1,unit:'rad'}],model:{phase}};
  api.semantic(() => {calls++;return selected;});
  api.lifecycle({pause:() => {phase=.5;},checkpoint:() => ({phase})});
  assert.throws(() => program.semanticSelection(), /pause_required/);
  await program.checkpoint();
  assert.equal(calls,1);selected.label='changed later';
  assert.equal(json(program.semanticSelection()).label,'Gear');
  await program.checkpoint();assert.equal(calls,1);
  await program.resume();assert.throws(() => program.semanticSelection(),/pause_required/);
  await program.dispose();assert.throws(() => program.semanticSelection(),/disposed/);
});

test('unbounded, asynchronous and throwing author semantics never fail the saved checkpoint or become late evidence', async () => {
  for (const callback of [() => ({model:'x'.repeat(4097)}), () => Promise.resolve({objectID:'late'}), () => {throw Error('author');}]) {
    const {program,api} = fixture();api.semantic(callback);
    api.lifecycle({pause:() => {},checkpoint:() => ({phase:.75})});
    assert.equal((await program.checkpoint()).phase,.75);
    assert.equal(program.semanticSelection(),null);
    await new Promise(resolve => setTimeout(resolve,0));assert.equal(program.semanticSelection(),null);
  }
  const {program,api} = fixture();api.semantic(() => ({objectID:'unsafe running'}));
  await program.checkpoint();assert.equal(program.semanticSelection(),null,'No author pause means no semantic promise');
});


test('author vector export pauses the isolated executor and receives the exact saved state without commits',async()=>{
  const {program,api,commits,json}=fixture();let phase=99;const order:string[]=[];
  api.lifecycle({pause:()=>{order.push('pause');},checkpoint:()=>{throw Error('Must not checkpoint the later phase');}});
  api.exportFrame(({state,format,signal}:any)=>{assert.equal(format,'svg');assert.equal(signal.aborted,false);phase=state.phase;order.push('render');assert.equal(api.commit({phase:99}),false);return `<svg>${phase}</svg>`;});
  assert.equal(await program.exportFrame({format:'svg',state:{phase:.25}}),'<svg>0.25</svg>');
  assert.deepEqual(order,['pause','render']);assert.equal(commits.length,0);assert.equal(program.suspended,true);
  assert.deepEqual(json(api.state),{phase:0},'An export frame is not a durable checkpoint');
});

test('missing, throwing, unbounded or cancelled author SVG is an error, never a raster fallback',async()=>{
  await assert.rejects(fixture().program.exportFrame({format:'svg',state:null}),/export_unavailable/);
  for(const render of [()=>{throw Error('render failed');},()=> 'x'.repeat(524289),()=>new Promise(()=>{})]){
    const {program,api}=fixture();api.exportFrame(render);
    await assert.rejects(program.exportFrame({format:'svg',state:null}),/render failed|export_limit|export_timeout/);
  }
  const {program,api}=fixture();let done!:(value:string)=>void;
  api.exportFrame(()=>new Promise<string>(resolve=>{done=resolve}));
  const pending=program.exportFrame({format:'svg',state:null});await new Promise(resolve=>setTimeout(resolve,0));
  await program.dispose();done('<svg/>');await assert.rejects(pending,/superseded|disposed/);
});


test('raster export waits for the authored saved frame at exact scale and never checkpoints or commits',async()=>{
  const {program,api,commits}=fixture();let ready=false,ratio=0;
  api.lifecycle({pause:()=>{},checkpoint:()=>{throw Error('No later phase');}});
  api.exportFrame(async({format,state,pixelRatio}:any)=>{assert.equal(format,'raster');assert.equal(state.phase,.625);
    ratio=pixelRatio;await new Promise(resolve=>setTimeout(resolve,1));ready=true;assert.equal(api.commit(state),false);return null;});
  assert.equal(await program.exportFrame({format:'raster',state:{phase:.625},pixelRatio:3}),null);
  assert.equal(ready,true);assert.equal(ratio,3);assert.equal(commits.length,0);assert.equal(program.suspended,true);
  for(const pixelRatio of [0,-1,NaN,Infinity,9])await assert.rejects(program.exportFrame({format:'raster',state:null,pixelRatio}),/extent/);
  await assert.rejects(fixture().program.exportFrame({format:'raster',state:null,pixelRatio:2}),/unavailable/);
  const invalid=fixture();invalid.api.exportFrame(()=>'<svg/>');await assert.rejects(invalid.program.exportFrame({format:'raster',state:null,pixelRatio:2}),/raster_invalid/);
});

test('video requires explicit author timeline, receives absolute times and never advances the saved state',async()=>{
  const missing=fixture();missing.api.exportFrame(()=>null);
  await assert.rejects(missing.program.exportFrame({format:'raster',state:{phase:.25},pixelRatio:1,time:0}),/timeline_unavailable/);
  const {program,api,commits}=fixture();const frames:any[]=[];
  api.exportFrame(({state,time}:any)=>{frames.push([state.phase,time]);return null;},{timeline:true});
  for(const time of [0,.5,0])await program.exportFrame({format:'raster',state:{phase:.25},pixelRatio:2,time});
  assert.deepEqual(frames,[[.25,0],[.25,.5],[.25,0]]);assert.equal(commits.length,0);assert.equal(api.state.phase,0);
  await assert.rejects(program.exportFrame({format:'raster',state:null,pixelRatio:1,time:-1}),/timeline_unavailable/);
});


test('PDF vectors are opt-in, bounded copied replacement regions; declared author failures never fall back',async()=>{
  const unsupported=fixture();unsupported.api.exportFrame(()=>{throw Error('Must not request undeclared vectors')});
  assert.deepEqual(unsupported.json(await unsupported.program.exportFrame({format:'pdf',state:null})),[]);
  const {program,api,commits}=fixture();const layer={svg:'<svg/>',frame:{x:1,y:2,width:30,height:40}},layers=[layer];
  api.exportFrame(({format,state}:any)=>{assert.equal(format,'pdf');assert.equal(state.phase,.75);return layers;},{vectors:true});
  const copied=await program.exportFrame({format:'pdf',state:{phase:.75}});
  layer.frame.x=9;assert.equal(copied[0].frame.x,1);assert.equal(commits.length,0);
  for(const value of [null,Array(17).fill(layer),[{svg:'x'.repeat(524288),frame:layer.frame}],
    [{svg:'<svg/>',frame:{x:NaN,y:0,width:1,height:1}}],[{svg:'<svg/>',frame:{x:0,y:0,width:-1,height:1}}]]) {
    const f=fixture();f.api.exportFrame(()=>value,{vectors:true});
    await assert.rejects(f.program.exportFrame({format:'pdf',state:null}),/export_limit|vector_invalid/);
  }
  const bad=fixture();bad.api.exportFrame(()=>{throw Error('broken vector')},{vectors:true});
  await assert.rejects(bad.program.exportFrame({format:'pdf',state:null}),/broken vector/);
});


test('explicit retry continues the failed stage without running resume or replaying a completed pause', async () => {
  for (const failedStage of ['pause', 'checkpoint']) {
    const {program,api} = fixture(); let pauses = 0, checkpoints = 0, resumes = 0;
    api.lifecycle({pause:() => { if (++pauses === 1 && failedStage === 'pause') throw Error('pause failed'); },
      checkpoint:() => { if (++checkpoints === 1 && failedStage === 'checkpoint') throw Error('checkpoint failed'); return {phase:.75}; },
      resume:() => { resumes++; }});
    await assert.rejects(program.checkpoint(), /failed/);
    assert.equal(program.lifecycleState.phase, 'failed');
    assert.equal(api.commit({phase:9}), false);
    assert.equal((await program.checkpoint({retry:true})).phase, .75);
    assert.equal(pauses, failedStage === 'pause' ? 2 : 1);
    assert.equal(checkpoints, failedStage === 'checkpoint' ? 2 : 1);
    assert.equal(resumes, 0);
  }
});

test('native-timeout retry revokes the old generation before its browser watchdog fires', async () => {
  const {program,api} = fixture({timeoutMS:1000}); let finish!: (value: unknown) => void, oldSignal!: AbortSignal, calls = 0;
  api.lifecycle({checkpoint:({signal}:any) => {
    if (++calls === 1) { oldSignal = signal; return new Promise(resolve => { finish = resolve; }); }
    return {phase:.5};
  }});
  const first = program.checkpoint(); const refused = assert.rejects(first, /superseded/);
  await new Promise(resolve => setTimeout(resolve,0));
  assert.equal((await program.checkpoint({retry:true})).phase,.5);
  await refused; assert.equal(oldSignal.aborted,true);
  finish({phase:99}); await new Promise(resolve => setTimeout(resolve,0));
  assert.equal(api.state.phase,.5);
});

test('resume failure keeps the accepted frozen model and retry never checkpoints it again', async () => {
  const {program,api} = fixture(); let checkpoints = 0, resumes = 0;
  api.lifecycle({checkpoint:() => ({phase:++checkpoints}),resume:() => { if (++resumes === 1) throw Error('resume failed'); }});
  await program.checkpoint(); await assert.rejects(program.resume(), /resume failed/);
  assert.equal(program.suspended,true); assert.equal(api.commit({phase:9}),false);
  assert.equal((await program.checkpoint({retry:true})).phase,1);
  assert.equal(checkpoints,1); await program.resume(); assert.equal(program.suspended,false);
});


test('admitted snapshots are immutable FIFO and overload refuses before true without changing state', async () => {
  const descriptors:any[] = [], requests:number[] = [];
  const {program,api,events} = fixture({stateTransport:{credit:512,
    onSnapshot:(value:any)=>descriptors.push(value),requestCredit:(bytes:number)=>requests.push(bytes)}});
  const a={phase:1}; assert.equal(api.commit(a),true); a.phase=90;
  assert.equal(api.commit({phase:2}),true);
  assert.equal(api.commit({phase:3}),false); assert.equal(api.state.phase,2);
  assert.equal(requests.length,1);
  assert.deepEqual(descriptors.map(d=>JSON.parse(program.readSnapshot({revision:d.revision}))),[{phase:1},{phase:2}]);
  assert.throws(()=>program.acknowledgeSnapshot('2'),/ack_order/);
  let paused=false;api.lifecycle({pause:()=>{paused=true;},checkpoint:()=>({phase:4})});
  const checkpoint=program.checkpoint({serialized:true});await new Promise(resolve=>setTimeout(resolve,0));
  assert.equal(paused,false,'Checkpoint barrier waits for accepted explicit commits');
  program.acknowledgeSnapshot('1');program.acknowledgeSnapshot('2');
  const frozen=await checkpoint;assert.equal(JSON.parse(program.readSnapshot({revision:frozen.revision})).phase,4);
  assert.ok(events.some((event:any)=>event.type==='notebookcapacity'));
  assert.equal(api.commit({phase:5}),false);
});

test('large-to-small writes borrow old-state admission until the addressed merge completes', async () => {
  const text='😀'.repeat(1_100_000), requests:number[]=[], descriptors:any[]=[];
  const {program,api}=fixture({state:{text},stateTransport:{credit:1024,
    onSnapshot:(value:any)=>descriptors.push(value),requestCredit:(bytes:number)=>requests.push(bytes)}});
  assert.equal(api.commit({text:'small'}),false,'Old state is still read by the causal writer');
  const minimum=Buffer.byteLength(JSON.stringify({text}))*8;
  assert.ok(requests[0]!>minimum-1024);
  program.grantStateCredit(requests[0]);assert.equal(api.commit({text:'small'}),true);
  assert.ok(descriptors[0].cost>=minimum);
  program.acknowledgeSnapshot('1');
  api.lifecycle({checkpoint:()=>({text:'checkpoint'})});
  const frozen=await program.checkpoint({serialized:true});
  assert.ok(frozen.cost>=Buffer.byteLength(JSON.stringify({text:'checkpoint'}))*8);
});

test('a model larger than 4MiB acquires credit and transfers exact surrogate-safe bounded windows', async () => {
  const descriptors:any[] = [], requests:number[] = [];
  const {program,api}=fixture({stateTransport:{credit:1024,onSnapshot:(d:any)=>descriptors.push(d),requestCredit:(bytes:number)=>requests.push(bytes)}});
  const value={text:'x'.repeat(4*1024*1024)+'😀'.repeat(200_000)};
  assert.equal(api.commit(value),false);assert.equal(api.state.phase,0);
  program.grantStateCredit(requests[0]);assert.equal(api.commit(value),true);
  const descriptor=descriptors[0];let encoded='',offset=0,count=0;
  while(offset<descriptor.units){const chunk=program.readSnapshot({revision:descriptor.revision,offset});
    assert.ok(Buffer.byteLength(chunk)<=1024*1024);assert.equal(chunk.isWellFormed(),true);
    encoded+=chunk;offset+=chunk.length;count++;}
  assert.ok(count>4);assert.deepEqual(JSON.parse(encoded),value);
  await program.dispose();
  assert.equal(program.readSnapshot({revision:'1',offset:0}).length,262144,'Accepted snapshot survives disposal until native acknowledgement');
  program.acknowledgeSnapshot('1');await program.drainCommits();
});

test('native timeout cancels lifecycle immediately, even while accepted commits drain', async () => {
  const {program,api} = fixture({timeoutMS:1000}); let complete!: (value:any)=>void, signal!:AbortSignal, calls=0;
  api.lifecycle({checkpoint:({signal:s}:any)=>{signal=s;calls++;return calls===1 ? new Promise(resolve=>complete=resolve) : {phase:2};}});
  const pending=program.checkpoint();const rejected=assert.rejects(pending,/superseded/);
  await new Promise(resolve=>setTimeout(resolve,0));
  assert.equal(program.cancelLifecycle(),true);assert.equal(signal.aborted,true);await rejected;
  complete({phase:99});await new Promise(resolve=>setTimeout(resolve,0));assert.equal(api.state.phase,0);
  assert.equal((await program.checkpoint({retry:true})).phase,2);

  const descriptors:any[]=[];
  const blocked=fixture({stateTransport:{credit:1024,onSnapshot:(d:any)=>descriptors.push(d),requestCredit:()=>{}}});
  let pauses=0;blocked.api.lifecycle({pause:()=>{pauses++;}});blocked.api.commit({phase:1});
  const draining=blocked.program.checkpoint();const cancelled=assert.rejects(draining,/superseded/);
  assert.equal(blocked.program.lifecycleState.phase,'draining');assert.equal(blocked.program.cancelLifecycle(),true);
  blocked.program.acknowledgeSnapshot(descriptors[0].revision);await cancelled;
  assert.equal(pauses,0);await blocked.program.checkpoint({retry:true});assert.equal(pauses,1);
});

test('external state windows publish atomically and stale or replaced presentation never rolls back a commit', async () => {
  const {program,api}=fixture();
  const value={payload:'😀'.repeat(1_300_000),phase:9},json=JSON.stringify(value);
  for(let offset=0;offset<json.length;) {
    let end=Math.min(json.length,offset+262144);if(end<json.length&&/[\uD800-\uDBFF]/.test(json[end-1]!))end--;
    assert.equal(await program.receiveStateWindow({transfer:'large',offset,units:json.length,text:json.slice(offset,end),revision:'0'}),true);
    if(end<json.length)assert.equal(api.state.phase,0);
    offset=end;
  }
  assert.equal(api.state.payload,value.payload);
  const old='{"phase":90}';
  await program.receiveStateWindow({transfer:'old',offset:0,units:old.length,text:old.slice(0,5),revision:'0'});
  assert.equal(api.commit({phase:10}),true);
  assert.equal(await program.receiveStateWindow({transfer:'old',offset:5,units:old.length,text:old.slice(5),revision:'0'}),false);
  assert.equal(api.state.phase,10);
  await program.receiveStateWindow({transfer:'obsolete',units:old.length,text:old.slice(0,5),revision:'1'});
  assert.equal(await program.receiveStateWindow({transfer:'new',units:2,text:'{}',revision:'1'}),true);
  assert.equal(await program.receiveStateWindow({transfer:'obsolete',offset:5,units:old.length,text:old.slice(5),revision:'1'}),false);
  assert.equal(api.state.phase,undefined);
});


test('a lost ACK reply retries idempotently without double credit or removing the next snapshot', async () => {
  const descriptors:any[]=[];
  const {program,api}=fixture({stateTransport:{credit:512,onSnapshot:(d:any)=>descriptors.push(d),requestCredit:()=>{}}});
  assert.equal(api.commit({phase:1}),true);assert.equal(api.commit({phase:2}),true);
  program.acknowledgeSnapshot('1');program.acknowledgeSnapshot('1');
  assert.equal(api.commit({phase:3}),true);assert.equal(api.commit({phase:4}),false,'Repeated ACK cannot grant credit twice');
  assert.equal(JSON.parse(program.readSnapshot({revision:'2'})).phase,2);
  assert.throws(()=>program.acknowledgeSnapshot('3'),/ack_order/);
  assert.throws(()=>program.acknowledgeSnapshot('0'),/ack_order/);
  program.acknowledgeSnapshot('2');program.acknowledgeSnapshot('1');program.acknowledgeSnapshot('3');
  await program.drainCommits();assert.equal(descriptors.length,3);
});

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const html = fs.readFileSync(new URL('../../Applications/WebResources/document-shell.html', import.meta.url), 'utf8');
function section(start, end) {
  const a = html.indexOf(start), b = html.indexOf(end, a);
  assert(a >= 0 && b > a, `Missing shipped boundary: ${start} … ${end}`); return html.slice(a, b);
}
const observationSource = section('      let preparationObservation = null;', '      let presentationEpoch = ');
const receiptSource = section('      const observedPageReceipt = async', '      // Each pending frame');
const renderSource = section('      const renderFrame = async', '      const observedPageReceipt');
const programWaitSource = section('      const waitForProgram = ', '      const retirePresentation = ');
const programSource = fs.readFileSync(new URL('../../Applications/WebResources/document-program.js', import.meta.url), 'utf8');
const tick = () => new Promise(resolve => setImmediate(resolve));
const frame = {documentID:'document', runtimeID:'runtime', generation:'18', sourceKey:'source',
  stateKey:'state', renderToken:'token', pageIndex:3};

function execution() {
  let now = 0, clockReads = 0;
  const frames = [], actions = [];
  const document = {hidden:false, readyState:'complete', fonts:{}, createElement:()=>({}),
    getElementById:()=>({textContent:''})};
  Object.defineProperties(document.fonts, {
    status: {get(){throw new Error('Cannot trigger font/style status work')}},
    size: {get(){throw new Error('Cannot trigger font/style size work')}}
  });
  const scope = {document, performance:{now:()=>{clockReads++;return now}},
    payload:{...frame},
    requestAnimationFrame:fn=>frames.push(fn),
    setPageIndex:index=>actions.push(['setPageIndex',index]), pageReceipt:()=>({...scope.payload}),
    getComputedStyle:()=>{throw new Error('No observer layout')}, AbortController, DOMException};
  vm.runInNewContext(observationSource + receiptSource + programWaitSource + `
    globalThis.api={observePreparation, observedPageReceipt, observeBrowserState,
      observation:()=>preparationObservation};`, scope);
  return {scope, frames, actions, api:scope.api, time:value=>{now=value}, reads:()=>clockReads};
}

test('no observation adds no clock/lifecycle sampling and preserves the two real scheduled callbacks', async () => {
  const f=execution(); f.time(10);
  let finished=false;
  const task=f.api.observedPageReceipt(3,true,'').then(value=>{finished=true;return value});
  assert.equal(f.frames.length,1); assert.equal(finished,false); assert.equal(f.reads(),0);
  f.frames.shift()(); await tick();
  assert.equal(f.frames.length,1); assert.equal(finished,false);
  f.frames.shift()(); const value=await task;
  assert.equal(value.preparationObservation,undefined); assert.equal(f.reads(),0);
  assert.deepEqual(f.actions,[['setPageIndex',3]]);
});

test('receipt phases bound each wait without claiming either callback is an installed frame', async () => {
  const f=execution(); f.api.observePreparation({...frame,attemptID:'a'}); f.time(100);
  const task=f.api.observedPageReceipt(3,true,'a');
  f.time(130); f.frames.shift()(); await tick();
  f.time(180); f.frames.shift()(); const value=await task;
  const o=value.preparationObservation;
  assert.equal(o.attemptID,'a'); assert.equal(o.phasesMS.receipt_setPage,0);
  assert.equal(o.phasesMS.receipt_raf1,30); assert.equal(o.phasesMS.receipt_raf2,80);
  assert.equal(o.phasesMS.receipt_complete,80);
  assert.equal(o.states.receipt_enter.documentHidden,0);
  assert.equal(o.states.receipt_raf2.documentReadyState,2);
  assert.deepEqual(Object.keys(o.states.receipt_raf2).sort(),['documentHidden','documentReadyState']);
  f.api.observePreparation({...frame,attemptID:'a'});
  assert.equal(f.api.observation().attemptID,'a'); // Re-arming the same native attempt retains its source flags.
});

test('superseded source, runtime, state, token, page or attempt cannot inherit an earlier receipt observation', async () => {
  for(const [key,value] of Object.entries({...frame,documentID:'other',runtimeID:'other',generation:'19',
    sourceKey:'other',stateKey:'other',renderToken:'other',pageIndex:4,attemptID:'other'})) {
    const f=execution(); f.api.observePreparation({...frame,attemptID:'old'});
    const task=f.api.observedPageReceipt(3,true,'old');
    f.frames.shift()(); await tick();
    if(key==='attemptID')f.api.observePreparation({...frame,attemptID:value});
    else f.scope.payload={...frame,[key]:value};
    f.frames.shift()(); const receipt=await task;
    assert.equal(receipt.preparationObservation,undefined,key);
  }
});

test('the shipped program adapter waits on its one font getter and image decode before author readiness', async () => {
  const handlers=new Map(), messages=[], actions=[];
  let fontResolve, imageResolve, fontGets=0;
  const fontsReady=new Promise(resolve=>{fontResolve=resolve});
  const imageReady=new Promise(resolve=>{imageResolve=resolve});
  const document={fonts:{}, images:[{naturalWidth:1,decode:()=>{actions.push('decode');return imageReady}}],
    body:{scrollHeight:10,scrollWidth:10}};
  Object.defineProperties(document.fonts,{
    ready:{get(){fontGets++;actions.push('font-get');return fontsReady}},
    status:{get(){throw new Error('No font status sampling')}},
    size:{get(){throw new Error('No font size sampling')}}
  });
  const scope={document,window:{},innerHeight:10,innerWidth:10,queueMicrotask,
    parent:{postMessage:value=>messages.push(value)},addEventListener:(name,handler)=>handlers.set(name,handler),
    createNotebookProgram:()=>({api:{},start:async value=>{actions.push(['start',value.requiresReady])}})};
  vm.runInNewContext(programSource+`
    installNotebookDocumentProgram({blockID:'program',token:'token',state:{},requiresReady:true},createNotebookProgram);`,scope);
  assert.deepEqual(messages.map(value=>value.channel),['notebook-program-installed']);
  const task=handlers.get('load')();
  await tick();assert.equal(fontGets,1);assert.deepEqual(actions,['font-get']);
  assert.equal(messages.some(value=>value.channel==='notebook-program-ready'),false);
  fontResolve();await tick();assert.deepEqual(actions,['font-get','decode']);
  assert.equal(messages.some(value=>value.channel==='notebook-program-ready'),false);
  imageResolve();await task;
  assert.equal(fontGets,1);assert.deepEqual(actions,['font-get','decode',['start',true]]);
  assert.deepEqual(messages.map(value=>value.channel),
    ['notebook-program-installed','notebook-program-ready','notebook-program-started']);
});

function renderExecution(observe=true) {
  const f=execution();if(observe)f.api.observePreparation({...frame,attemptID:'render'});
  let programResolve,stateResolve,required=true,installed=0;
  const programs=new Promise(resolve=>{programResolve=resolve});
  const state=new Promise(resolve=>{stateResolve=resolve});
  Object.assign(f.scope,{payload:null,installedSourceKey:null,installedFragment:null,appliedStateKey:null,
    currentPageIndex:()=>3,pendingFrame:null,currentFrame:null,activeProgramPreparation:null,
    programsVisible:true,presentationIsRendering:false,frameIsRequired:()=>required,
    presentationChanged:()=>f.actions.push(['presentation',f.scope.presentationIsRendering]),
    bridge:value=>f.actions.push(['bridge',value.kind]),
    installPhysicalFragment:()=>{installed++},prepareInteractiveFrames:()=>programs,
    work:{stateApplications:0},applyInteractiveState:()=>state,
    runtimeDiagnostics:[],layoutCanonical:true,pageLayout:{pageCount:9}});
  vm.runInNewContext(renderSource+'\nglobalThis.render=renderFrame;',f.scope);
  const job={frame:{...frame},source:{key:'source'},state:{key:'state',states:{}},
    fragment:{html:'<section data-block-id="program"></section>'},diagnostics:[]};
  return {...f,run:()=>f.scope.render(job),programResolve,stateResolve,
    supersede:()=>{required=false},installed:()=>installed,
    rendered:()=>f.actions.filter(value=>value[0]==='bridge'&&value[1]==='rendered').length};
}

test('render observation times the actual program and state waits, not removed PDF/font work', async () => {
  for(const observe of [false,true]) {
    const f=renderExecution(observe),task=f.run();await tick();
    assert.equal(f.installed(),1); // Only the transparent hit/program fragment, not canonical paper pixels.
    assert.equal(f.scope.presentationIsRendering,true);assert.equal(f.rendered(),0);
    assert.equal(f.scope.work.stateApplications,0);
    if(observe)assert.equal(f.api.observation().phasesMS.render_programs,undefined);
    f.time(130);f.programResolve();await tick();
    assert.equal(f.scope.work.stateApplications,1);assert.equal(f.rendered(),0);
    assert.equal(f.scope.appliedStateKey,null);
    if(observe)assert.equal(f.api.observation().phasesMS.render_programs,130);
    f.time(210);f.stateResolve();await task;
    assert.equal(f.rendered(),1);assert.equal(f.scope.presentationIsRendering,false);
    assert.equal(f.scope.appliedStateKey,'state');assert.equal(f.scope.activeProgramPreparation,null);
    if(observe) {
      const phases=f.api.observation().phasesMS;
      assert.equal(phases.render_enter,0);assert.equal(phases.render_fragmentDOM,0);
      assert.equal(phases.render_install,0);assert.equal(phases.render_state,210);
      assert.equal(phases.render_complete,210);
    } else assert.equal(f.reads(),0,'Observation-disabled render adds no clock/lifecycle sampling');
  }
});

test('a superseded frame cannot publish canonical readiness from either real program dependency', async () => {
  for(const boundary of ['before-install','programs','state']) {
    const f=renderExecution();if(boundary==='before-install')f.supersede();
    const task=f.run();await tick();
    if(boundary==='state'){f.time(50);f.programResolve();await tick();}
    f.supersede();f.time(200);f.programResolve();f.stateResolve();await task;
    assert.equal(f.installed(),boundary==='before-install'?0:1,boundary);
    assert.equal(f.rendered(),0,boundary);assert.equal(f.scope.appliedStateKey,null,boundary);
    assert.equal(f.api.observation().phasesMS.render_complete,undefined,boundary);
    assert.equal(f.scope.activeProgramPreparation,null,boundary);
    if(boundary!=='before-install')assert.equal(f.scope.presentationIsRendering,true,boundary);
  }
});

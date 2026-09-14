import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const html = fs.readFileSync(new URL('../../Applications/WebResources/document-shell.html', import.meta.url), 'utf8');
function section(start, end) {
  const a = html.indexOf(start), b = html.indexOf(end, a);
  assert(a >= 0 && b > a); return html.slice(a, b);
}
const observationSource = section('      let preparationObservation = null;', '      let sourcePreparation = null;');
const receiptSource = section('      const observedPageReceipt = async', '      // Each pending frame');
const renderSource = section('      const renderFrame = async', '      const observedPageReceipt');
const fontSource = section('          const observation = preparationObservation?.sourceKey', "          phase('fontsReady');") + "phase('fontsReady');";
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
    sourcePreparation:{host:{isConnected:true}}, payload:{...frame},
    requestAnimationFrame:fn=>frames.push(fn),
    setPageIndex:index=>actions.push(['setPageIndex',index]), pageReceipt:()=>({...scope.payload}),
    getComputedStyle:()=>{throw new Error('No observer layout')}, AbortController};
  vm.runInNewContext(observationSource + receiptSource + `
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
  assert.equal(o.states.receipt_raf2.sourcePreparationConnected,1);
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

test('actual font ready getter and promise wait remain single operations with separate elapsed times', async () => {
  const f=execution(); f.api.observePreparation({...frame,attemptID:'font'});
  let resolve, getters=0;
  const wait=new Promise(done=>{resolve=done});
  Object.defineProperty(f.scope.document.fonts,'ready',{get(){getters++;f.time(7);return wait}});
  Object.assign(f.scope,{source:{key:'source'},preparationPhasesMS:{},phase:name=>f.actions.push(name)});
  const task=vm.runInNewContext(`(async()=>{${fontSource}})()`,f.scope);
  await tick(); assert.equal(getters,1); assert.deepEqual(f.actions,[]);
  f.time(27); resolve(); await task;
  assert.equal(f.scope.preparationPhasesMS.fontsReadyGetter,7);
  assert.equal(f.scope.preparationPhasesMS.fontsReadyAwait,20);
  assert.deepEqual(f.actions,['fontsReady']);
  assert.equal(f.api.observation().states.fonts_before.sourcePreparationConnected,1);
});

test('render observation measures the real decode barrier and cannot install a superseded fragment', async () => {
  for(const superseded of [false,true]) {
    const f=execution(); f.api.observePreparation({...frame,attemptID:'render'});
    let release, required=true, installed=0;
    const decode=new Promise(resolve=>{release=resolve});
    Object.assign(f.scope,{payload:null, installedSourceKey:null, installedFragment:null, appliedStateKey:null,
      currentPageIndex:()=>0, pendingFrame:null, activeImagePreparation:null, currentFrame:null,
      presentationIsRendering:false, frameIsRequired:()=>required,
      notebookDocumentImages:{waitForPixels:()=>decode}, presentationChanged:()=>{}, bridge:()=>{},
      installPhysicalFragment:()=>{installed++}, prepareInteractiveFrames:async()=>{},
      activeEditorLayout:null, restoreEditor:()=>{}, work:{stateApplications:0},
      applyInteractiveState:async()=>{}, runtimeDiagnostics:[], layoutCanonical:true,pageLayout:{pageCount:9}});
    vm.runInNewContext(renderSource+'\nglobalThis.render=renderFrame;',f.scope);
    const task=f.scope.render({frame:{...frame},source:{key:'source'},state:{key:'state',states:{}},
      fragment:{html:'<img>'},mathStyles:'',diagnostics:[]});
    await tick();assert.equal(installed,0);assert.equal(f.api.observation().phasesMS.render_images,undefined);
    f.time(200);required=!superseded;release();await task;
    assert.equal(installed,superseded?0:1);
    const phases=f.api.observation().phasesMS;
    assert.equal(phases.render_images,200);
    assert.equal(phases.render_complete,superseded?undefined:200);
  }
});

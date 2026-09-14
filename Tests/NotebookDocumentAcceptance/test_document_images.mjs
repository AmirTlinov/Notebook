import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const source = fs.readFileSync(new URL('../../Applications/WebResources/document-images.js', import.meta.url), 'utf8');
const context = {window: {}, DOMException, AbortController, getComputedStyle: node => node.style};
vm.runInNewContext(source, context);
const api = context.window.notebookDocumentImages;
const px = value => ({unit: 'px', value});
function fixture(overrides = {}, parentStyle = {}) {
  const root = {};
  const parent = {parentElement: root, style: {display: 'block', float: 'none', position: 'static', ...parentStyle}};
  const values = {'width': px(451), 'height': px(158), 'min-width': px(0), 'min-height': px(0),
    'max-width': {unit: 'percent', value: 100}, 'max-height': {value: 'none'}, ...overrides};
  const image = {parentElement: parent, getAttribute: key => ({width:'451',height:'158'})[key],
    computedStyleMap: () => new Map(Object.entries(values)), closest: () => ({dataset:{blockId:'image-block'}})};
  return {root, image};
}
const rootFor = images => ({querySelectorAll: () => images});
const tick = () => new Promise(resolve => setImmediate(resolve));

test('fixed axes retain max-width scaling; intrinsic and unknown layout stay conservative', () => {
  const fixed = fixture(); assert.equal(api.hasFixedGeometry(fixed.image, fixed.root), true);
  for (const override of [{width:{value:'auto'}},{height:{value:'auto'}},{width:{unit:'percent',value:100}},
    {'max-height':{unit:'percent',value:100}},{'min-width':{value:'min-content'}}]) {
    const f = fixture(override); assert.equal(api.hasFixedGeometry(f.image, f.root), false);
  }
  for (const parent of [{display:'flex'},{display:'grid'},{display:'table-cell'},{position:'absolute'},{float:'left'}]) {
    const f = fixture({}, parent); assert.equal(api.hasFixedGeometry(f.image,f.root),false);
  }
  fixed.image.computedStyleMap = undefined;
  assert.equal(api.hasFixedGeometry(fixed.image,fixed.root),false);
});

test('geometry only waits intrinsic images; visible pixel barrier waits both', async () => {
  const fixed = fixture(), intrinsic = fixture({height:{value:'auto'}});
  intrinsic.image.parentElement.parentElement = fixed.root;
  let fixedCalls=0, intrinsicCalls=0;
  fixed.image.decode=async()=>{fixedCalls++}; intrinsic.image.decode=async()=>{intrinsicCalls++};
  fixed.root.querySelectorAll=()=>[fixed.image,intrinsic.image];
  await api.waitForGeometry(fixed.root,()=>false);
  assert.equal(fixedCalls,0); assert.equal(intrinsicCalls,1);
  await api.waitForPixels(fixed.root);
  assert.equal(fixedCalls,1); assert.equal(intrinsicCalls,2);
});

test('cancellation keeps the actual four in-flight decodes owned until all finish', async () => {
  let submitted=0, active=0, peak=0, completed=false;
  const releases=[];
  const images=Array.from({length:20},()=>({decode:()=>{
    submitted++; active++;peak=Math.max(peak,active);
    return new Promise(resolve=>releases.push(()=>{active--;resolve()}));
  }}));
  const controller=new AbortController();
  const wait=api.waitForPixels(rootFor(images),controller.signal).finally(()=>{completed=true});
  // Observe rejection immediately: a late rejection must not be unhandled.
  const rejected=assert.rejects(wait,{name:'AbortError'});
  await tick();assert.equal(submitted,4);controller.abort();await tick();
  assert.equal(completed,false);assert.equal(active,4);
  for(const release of releases.slice(0,3))release();await tick();
  assert.equal(completed,false);assert.equal(submitted,4);
  releases[3]();await rejected;
  assert.equal(active,0);assert.equal(peak,4);assert.equal(submitted,4);
});

test('local decode failure drains sibling work, stops submissions, and retains block provenance', async () => {
  const releases=[];let submitted=0,completed=false;
  const images=Array.from({length:8},(_,index)=>({closest:()=>({dataset:{blockId:'block-'+index}}),decode:()=>{
    submitted++;
    return new Promise((resolve,reject)=>releases.push(index===0?()=>reject(new Error('actual decode failed')):resolve));
  }}));
  const wait=api.waitForPixels(rootFor(images)).finally(()=>{completed=true});
  const rejected=assert.rejects(wait,error=>error.message==='document_image_decode_failed'&&error.blockID==='block-0');
  await tick();releases[0]();await tick();assert.equal(completed,false);
  releases.slice(1).forEach(release=>release());await rejected;
  assert.equal(submitted,4);
});

test('the actual frame fence revokes late image publication without confusing large generations', () => {
  const html=fs.readFileSync(new URL('../../Applications/WebResources/document-shell.html',import.meta.url),'utf8');
  const start=html.indexOf('      let requiredFrame = null;');
  const end=html.indexOf('      const renderFrame = async',start);
  assert.ok(start>=0&&end>start);
  const scope={activeImagePreparation:null};
  vm.runInNewContext(html.slice(start,end)+'\nglobalThis.fence={requireFrame,frameIsRequired};',scope);
  const f=scope.fence;
  const old={runtimeID:'runtime-a',generation:'18446744073709551000'};
  const latest={...old,generation:'18446744073709551001'};
  f.requireFrame(old);let aborted=0;
  scope.activeImagePreparation={job:{frame:old},controller:{abort(){aborted++}}};
  f.requireFrame(latest);
  assert.equal(aborted,1);assert.equal(f.frameIsRequired(old),false);assert.equal(f.frameIsRequired(latest),true);
  f.requireFrame(old);assert.equal(f.frameIsRequired(latest),true);
  assert.equal(f.frameIsRequired({...latest,runtimeID:'other-runtime'}),false);
  assert.throws(()=>f.requireFrame({...latest,generation:'nan'}),/document_frame_requirement_invalid/);
});


test('superseding a program wait releases only its frame and retirement ends unstarted programs', async () => {
  const html=fs.readFileSync(new URL('../../Applications/WebResources/document-shell.html',import.meta.url),'utf8');
  const start=html.indexOf('      let requiredFrame = null;');
  const end=html.indexOf('      const renderFrame = async',start);
  let removed=0,cancelled=0;
  const scope={activeImagePreparation:null,pendingFrame:null,payload:{runtimeID:'owner'},
    interactiveFrames:new Map([['pending',{isStarted:false,container:{remove(){removed++}},cancel(){cancelled++}}],
      ['running',{isStarted:true,container:{remove(){throw Error('running context lost')}},cancel(){throw Error('running context lost')}}]]),
    AbortController,DOMException};
  vm.runInNewContext(html.slice(start,end)+`
globalThis.fence={requireFrame,retirePresentation,frameIsRequired,
    wait(frame,promise){const controller=new AbortController();activeProgramPreparation={frame,controller};
      return waitForProgram(promise,controller.signal)}};`,scope);
  const frame={runtimeID:'owner',generation:'1'};
  scope.fence.requireFrame(frame);
  const pending=scope.fence.wait(frame,new Promise(()=>{}));
  const cancelledWait=assert.rejects(pending,{name:'AbortError'});
  const next={...frame,generation:'2'};
  scope.fence.requireFrame(next);await cancelledWait;
  assert.equal(removed,0);assert.equal(cancelled,0);
  assert.equal(await scope.fence.wait(next,Promise.resolve('ready')),'ready');
  scope.fence.retirePresentation('owner');
  assert.equal(scope.fence.frameIsRequired(next),false);
  assert.equal(removed,1);assert.equal(cancelled,1);
  assert.equal(scope.interactiveFrames.size,1);
  scope.fence.retirePresentation('owner');assert.equal(cancelled,1);
});

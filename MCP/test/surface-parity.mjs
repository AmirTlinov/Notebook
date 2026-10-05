import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {mkdir, readdir} from 'node:fs/promises';
import {dirname, resolve} from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';
import {build} from 'esbuild';
import {buildSurface} from '../build-surface.mjs';

// Run explicitly: node MCP/test/surface-parity.mjs. This compares the real
// browser adapter and WASM artifact with the native Swift geometry owner.
const root=resolve(dirname(fileURLToPath(import.meta.url)),'../..');
const output=resolve(root,'.build/surface-parity');
await mkdir(output,{recursive:true});
const {bytes,receipt}=await buildSurface();
const sources=resolve(root,'Sources/NotebookSurface');
const compile=spawnSync('xcrun',['swiftc','-O','-package-name','Notebook',
  ...(await readdir(sources)).filter(name=>name.endsWith('.swift')).sort().map(name=>resolve(sources,name)),
  resolve(root,'MCP/test/surface-parity.swift'),'-o',resolve(output,'native')],{encoding:'utf8'});
assert.equal(compile.status,0,compile.error?.message??compile.stderr);
const loader=resolve(output,'loader.mjs');
await build({stdin:{contents:"export {SwiftSurface} from './swift-surface.ts'; export {InkInput} from './ink-input.ts'; export {InkGPU} from './ink-gpu.ts';",
  resolveDir:resolve(root,'MCP/panel'),loader:'ts'},outfile:loader,
  bundle:true,platform:'node',format:'esm',target:'es2022'});
const {SwiftSurface,InkInput,InkGPU}=await import(pathToFileURL(loader).href);
const surface=await SwiftSurface.load(bytes);
const projection=resolve(output,'projection.mjs');
await build({entryPoints:[resolve(root,'MCP/panel/projection.ts')],outfile:projection,
  bundle:true,platform:'node',format:'esm',target:'es2022'});
const {admitPanelCamera,panelCoordinateScale,panelProjection,transformPanelCamera}=await import(pathToFileURL(projection).href);
const tile=(132/2.54/2)*256,maximum=Number.MAX_SAFE_INTEGER;
const world=values=>({tileX:values[0],tileY:values[1],localX:values[2],localY:values[3]});
const address=point=>[point.tileX,point.tileY,point.localX,point.localY];
const sample=(x,y,radius=2)=>[x,y,radius,0.1,0.2,0.3,0.5];
const cases={
  cameras:[
    [91,-37,211,3900,0.43,1024,1366,781,428,811,496,2.1],
    [-48,76,2111,903,0.31,1366,1024,982,271,811,496,1.73],
    [maximum,-maximum,0,0,0.0125,834,1194,417,597,416,598,1],
    [-maximum,maximum,0,0,4,834,1194,417,597,418,596,1],
    [0,0,0,0,1,800,600,100,100,100,100,1e300],
    [0,0,0,0,1,800,600,100,100,100,100,1e-300],
  ],
  offsets:[
    [0,0,0,0,-0.125,-tile],
    [12,-40,tile-0.125,0.25,0.5,-0.5],
    [maximum,-maximum,0.25,0.25,0.125,-0.125],
    [maximum,0,tile-1,0,2,0],
    [-maximum,0,0,0,-1,0],
  ],
  deltas:[
    [maximum,maximum,1.125,2.25,maximum,maximum,1.25,2.125],
    [-maximum,maximum,0,0,maximum,-maximum,tile-1,tile-1],
    [1,-1,0,0,0,0,tile-0.125,0.5],
  ],
  strokes:[
    sample(0,0),
    [...sample(-500,12),...sample(700,12)],
    [...sample(0,0),...sample(0,20,1),...sample(0,-20,3)],
    [...sample(0,0),...sample(0.001,0.001),...sample(0.002,0.002),...sample(1,1)],
    Array.from({length:1024},(_,i)=>sample(i/3,Math.sin(i/13)*20,0.5+(i%9)/4)).flat(),
  ].map(points=>Array.from(new Float32Array(points))),
  // kind, original[4], translation[2], hasBounds, bounds[4]. Exercise every
  // handle at both clamps and after reversal through the actual TS adapter.
  manipulations:[
    ...Array.from({length:9},(_,kind)=>[[5000,-5000],[-5000,5000],[20,-10],[0,0]]
      .map(delta=>[kind,100,80,200,160,...delta,1,0,0,600,800])).flat(),
    [4,0,0,0.4,0.6,-20,-20,0,0,0,0,0],
    [1,100,100,3000,2200,-400,-500,0,0,0,0,0],
    [0,1e308,0,1,1,1e308,12,0,0,0,0,0],
    [4,-1e308,0,1e308,1,1e308,12,0,0,0,0,0],
  ],
  pressure:[[0,-1,0],[1,-1,0],[0.8,0.2,0],[0.8,0.2,1/240],
    [0.1,0.9,1/60],[-2,0.3,0.012],[2,0.3,1]],
  ink:[
    {changedFrom:0,tail:sample(0,0)},
    {changedFrom:1,tail:[...sample(10,0,1),...sample(20,0,3)]},
    // Measured input replaces prediction, including a coincident pressure tip.
    {changedFrom:1,tail:[...sample(10,4,1),...sample(10.004,4.003,3),...sample(30,8,2)]},
    {changedFrom:2,tail:[]},
    ...[[2,170],[170,171],[171,256],[256,257],[257,520]].map(([start,end])=>({changedFrom:start,
      tail:Array.from({length:end-start},(_,i)=>sample((start+i)/3,Math.sin((start+i)/7)*9,1+(i%3)/4)).flat()})),
    {changedFrom:508,tail:Array.from({length:6},(_,i)=>sample(170+i/3,10-i/2,2)).flat()},
    {changedFrom:512,tail:[]},
    {changedFrom:0,tail:[...sample(4,5,1),...sample(4.004,5.003,3)]},
  ].map(update=>({...update,tail:Array.from(new Float32Array(update.tail))})),
};
// Explicit transport ratios cover the large-window conversion independently
// of panelCoordinateScale; every fixture also goes through the native oracle.
const browserCameras=[
  {name:'ordinary',viewport:[1024,768],ratio:1,scale:0.43,from:[781,428],to:[811,496],magnification:2.1},
  {name:'large CSS pan',viewport:[4096,2304],ratio:0.5,scale:0.4,from:[2048,1152],to:[2148,1202],magnification:1},
  {name:'minimum rounding width',viewport:[2562,1600],ratio:2048/2562,scale:0.0125/(2048/2562),from:[1281,800],to:[1321,820],magnification:1},
  {name:'minimum rounding height',viewport:[1600,2562],ratio:2048/2562,scale:0.0125/(2048/2562),from:[800,1281],to:[840,1301],magnification:1},
  {name:'maximum CSS scale',viewport:[5120,2880],ratio:0.4,scale:10,from:[3800,900],to:[3400,1200],magnification:0.7},
  {name:'clamp in',viewport:[4096,2304],ratio:0.5,scale:1.3,from:[3200,900],to:[3300,1000],magnification:1e300},
  {name:'clamp out',viewport:[4096,2304],ratio:0.5,scale:1.3,from:[3200,900],to:[3300,1000],magnification:1e-300},
  {name:'resize admission',viewport:[1280,800],ratio:1,scale:10,from:[640,400],to:[650,420],magnification:1},
  {name:'positive world edge',viewport:[4096,2304],ratio:0.5,scale:1,from:[2048,1152],to:[2047,1153],magnification:1,
    center:[maximum,-maximum,tile-0.125,0.125]},
  {name:'negative world edge',viewport:[4096,2304],ratio:0.5,scale:1,from:[2048,1152],to:[2049,1151],magnification:1,
    center:[-maximum,maximum,0.125,tile-0.125]},
].map(value=>({...value,center:value.center??[maximum-10,-maximum+10,1234,2345]}));
const nativeBrowserStart=cases.cameras.length;
for(const v of browserCameras)cases.cameras.push([...v.center,v.scale*v.ratio,
  ...v.viewport.map(n=>n*v.ratio),...v.from.map(n=>n*v.ratio),...v.to.map(n=>n*v.ratio),v.magnification]);
const native=spawnSync(resolve(output,'native'),[],{input:JSON.stringify(cases),encoding:'utf8',maxBuffer:8*1024*1024});
assert.equal(native.status,0,native.error?.message??native.stderr);
const expected=JSON.parse(native.stdout);
let maximumPositionError=0;
let maximumNodeError=0;
try {
  cases.cameras.forEach((v,i)=>{
    const camera=surface.camera({center:world(v),scale:v[4]}, {x:v[5],y:v[6]},
      {x:v[7],y:v[8]}, {x:v[9],y:v[10]},v[11]);
    assert.deepEqual([...address(camera.center),camera.scale],expected.cameras[i],`camera ${i}`);
  });
  const point=([x,y])=>({x,y});
  const browserResults=browserCameras.map((v,i)=>{
    assert.equal(panelCoordinateScale(...v.viewport),v.ratio,v.name);
    const camera=transformPanelCamera(surface,{center:world(v.center),scale:v.scale},point(v.viewport),
      point(v.from),point(v.to),v.magnification);
    const nativeCamera=expected.cameras[nativeBrowserStart+i];
    assert.deepEqual([...address(camera.center),camera.scale],
      [...nativeCamera.slice(0,4),nativeCamera[4]/v.ratio],v.name);
    return camera;
  });
  assert.deepEqual(surface.delta(world(browserCameras[1].center),browserResults[1].center),{x:-250,y:-125},
    '100×50 CSS pixel movement at scale 0.4 preserves physical displacement');
  assert.equal(browserResults[5].scale,surface.maximumScale/0.5);
  assert.equal(browserResults[6].scale,surface.minimumScale/0.5);
  assert.equal(browserResults[7].scale,surface.maximumScale);
  for(const index of [8,9])assert.deepEqual(browserResults[index].center,world(browserCameras[index].center),
    'an out-of-world pan retains the complete admitted camera');

  const viewport={x:2562,y:1600},center=world([maximum-10,-maximum+10,1234,2345]);
  const initial=admitPanelCamera(surface,{center,scale:0.3},viewport);
  const from={x:1700,y:550},to={x:1800,y:640};
  const first=transformPanelCamera(surface,initial,viewport,from,to,1.31);
  transformPanelCamera(surface,initial,viewport,from,{x:1900,y:690},1.48);
  assert.deepEqual(transformPanelCamera(surface,initial,viewport,from,to,1.31),first,
    'reversing a contact retraces the immutable camera basis');
  const returned=transformPanelCamera(surface,first,viewport,to,from,1/1.31);
  const reversal=surface.delta(initial.center,returned.center);
  assert.ok(Math.abs(reversal.x)<1e-9&&Math.abs(reversal.y)<1e-9);
  assert.ok(Math.abs(initial.scale-returned.scale)<1e-15);
  for(const scale of [0,-1,NaN,Infinity])assert.throws(()=>admitPanelCamera(surface,{center,scale},viewport),RangeError);
  const lower=admitPanelCamera(surface,{center,scale:1e-300},viewport);
  const upper=admitPanelCamera(surface,{center,scale:1e300},viewport);
  assert.equal(lower.scale,surface.minimumScale/(2048/2562));
  assert.equal(upper.scale,surface.maximumScale/(2048/2562));
  for(const size of [{x:5120,y:2880},{x:1280,y:800},viewport]){
    const admitted=admitPanelCamera(surface,upper,size);
    assert.deepEqual(admitted.center,center);
    const view=panelProjection(size.x,size.y,1,admitted),retina=panelProjection(size.x,size.y,3,admitted);
    assert.deepEqual(view.camera,retina.camera,'DPR changes resource density, never the camera');
    assert.deepEqual(view.camera.center,center);
    assert.ok(view.camera.scale>=surface.minimumScale&&view.camera.scale<=surface.maximumScale);
  }
  cases.offsets.forEach((v,i)=>{
    if(expected.offsets[i]===null)assert.throws(()=>surface.offset(world(v),v[4],v[5]),RangeError);
    else assert.deepEqual(address(surface.offset(world(v),v[4],v[5])),expected.offsets[i],`offset ${i}`);
  });
  cases.deltas.forEach((v,i)=>{
    const delta=surface.delta(world(v),world(v.slice(4)));
    assert.deepEqual([delta.x,delta.y],expected.deltas[i],`delta ${i}`);
  });
  const manipulationKinds=['move','topLeading','topTrailing','bottomLeading','bottomTrailing',
    'topCenter','bottomCenter','leadingCenter','trailingCenter'];
  const rectangle=(v,offset)=>({x:v[offset],y:v[offset+1],width:v[offset+2],height:v[offset+3]});
  cases.manipulations.forEach((v,i)=>{
    const run=()=>surface.manipulateFrame(manipulationKinds[v[0]],rectangle(v,1),{x:v[5],y:v[6]},v[7]===1?rectangle(v,8):undefined);
    if(expected.manipulations[i]===null)assert.throws(run,RangeError);
    else {const frame=run();assert.deepEqual([frame.x,frame.y,frame.width,frame.height],expected.manipulations[i],`manipulation ${i}`);}
  });
  for(const kind of ['invalid','toString'])assert.throws(()=>surface.manipulateFrame(kind,
    {x:0,y:0,width:10,height:10},{x:1,y:1}),RangeError);
  cases.pressure.forEach((v,i)=>{
    const actual=surface.penSample(v[0],v[1]<0?undefined:v[1],v[2]);
    [actual.width,actual.opacity,actual.filteredForce,actual.color.red,actual.color.green,actual.color.blue]
      .forEach((value,j)=>assert.ok(Math.abs(value-expected.pressure[i][j])<=1e-14,`pressure ${i}:${j}`));
  });
  const contact=surface.inkContact();
  let uploaded=new Float32Array(0),capacity=0;
  const upload=update=>{
    if(update.capacity>capacity){
      assert.equal(update.first,0,'a new GPU allocation receives its complete source');
      capacity=update.capacity;uploaded=new Float32Array(capacity*6);
    }
    uploaded.set(update.nodes,update.first*6);
    return uploaded.slice(0,update.total*6);
  };
  cases.ink.forEach((v,i)=>{
    const update=contact.update(new Float32Array(v.tail),v.changedFrom),wanted=expected.ink[i];
    assert.equal(update.vertexCount,wanted.vertices,`ink topology ${i}`);
    assert.ok(update.first===0||update.first===wanted.first,`ink dirty prefix ${i}`);
    const actual=upload(update);assert.equal(actual.length,wanted.nodes.length,`ink node count ${i}`);
    actual.forEach((value,j)=>{
      const native=Math.fround(wanted.nodes[j]),error=Math.abs(value-native);
      maximumNodeError=Math.max(maximumNodeError,error);
      assert.ok(error<=Math.max(1e-6,Math.abs(native)*8e-7),`ink node ${i}:${j}`);
    });
  });
  contact.dispose();contact.dispose();
  assert.throws(()=>contact.update(new Float32Array(sample(1,1))),/closed/);
  // A refused replacement or growth must leave both the cumulative input and
  // the published GPU capacity recoverable by the next ordinary append.
  for(const growth of [false,true]){
    const rejected=surface.inkContact(),clean=surface.inkContact();
    const initial=new Float32Array([...sample(0,0),...sample(10,0)]);
    const before=rejected.update(initial),beforeNodes=before.nodes.slice();clean.update(initial);
    const bad=growth?new Float32Array(Array.from({length:255},(_,i)=>sample(20+i,1)).flat()):new Float32Array(sample(NaN,0));
    bad[bad.length-7]=NaN;
    assert.throws(()=>rejected.update(bad,growth?2:1),RangeError);
    const next=rejected.update(new Float32Array(sample(20,0))),wanted=clean.update(new Float32Array(sample(20,0)));
    if(next.capacity>before.capacity)assert.equal(next.first,0,'rejected growth cannot omit the unpublished prefix');
    const actual=new Float32Array(next.total*6),expectedNodes=new Float32Array(wanted.total*6);
    actual.set(beforeNodes);actual.set(next.nodes,next.first*6);
    const full=clean.update(new Float32Array([...initial,...sample(20,0)]),0);
    expectedNodes.set(full.nodes,full.first*6);
    assert.deepEqual(actual,expectedNodes,'invalid input cannot poison a later valid append');
    rejected.dispose();clean.dispose();
  }
  // One real browser-input contact through Swift/WASM. Only the GPU endpoint
  // is stubbed here; the host gate separately executes compact WGSL readback.
  const originalCreate=InkGPU.create,controller=new AbortController(),failures=[];
  let notifications=0,lost,finishConnect;
  const makeGPU=()=>({disposed:false,uploaded:[],
    setNodes(update){assert.equal(this.disposed,false);this.uploaded.push({...update,nodes:update.nodes.slice()});},
    resize(){assert.equal(this.disposed,false);},draw(){assert.equal(this.disposed,false);},dispose(){this.disposed=true;}});
  const painter=makeGPU();let attempts=0;
  InkGPU.create=async(_canvas,_signal,failed)=>{
    lost=failed;
    return ++attempts===1?painter:new Promise(resolve=>{finishConnect=resolve;});
  };
  const turn=()=>new Promise(resolve=>setImmediate(resolve));
  const canvas={hidden:true},camera={center:world([0,0,0,0]),scale:2},inputViewport={x:800,y:600};
  const input=new InkInput(canvas,()=>surface,()=>({camera,viewport:inputViewport,pixelScale:2}),controller.signal,
    ()=>notifications++,(error)=>failures.push(error));
  const pointer=(time,x,pressure=0.8,extra={})=>({pointerId:1,pointerType:'pen',timeStamp:time,
    clientX:x,clientY:320,pressure,azimuthAngle:0,altitudeAngle:Math.PI/2,...extra});
  const basis={origin:world([0,0,0,0]),camera,viewport:inputViewport,client:{x:10,y:20}};
  try{
    await turn();assert.equal(input.ready,true);
    assert.equal(input.begin(pointer(100,410,0.2),basis),true);
    input.append(pointer(104,420,0.8,{getCoalescedEvents:()=>[pointer(102,414,0.3),pointer(102,416,0.5)],
      getPredictedEvents:()=>[pointer(106,424,1),pointer(108,428,0.3)]}));
    assert.equal(painter.uploaded.at(-1).total,6);
    assert.throws(()=>input.append(pointer(105,Infinity)),RangeError);
    const result=input.finish(pointer(104,421));
    assert.deepEqual(result.points.map(p=>p.x),[0,2,3,5,5.5],'coalesced and final samples survive a rounded timestamp');
    assert.deepEqual(result.points.map(p=>p.force),[0.2,0.3,0.5,0.8,0.8]);
    assert.ok(result.points.every(p=>p.width===2.2/2));
    let filtered;
    for(const [i,point] of result.points.entries()){
      const style=surface.penSample(point.force,filtered,i?point.timeOffset-result.points[i-1].timeOffset:0);
      assert.equal(point.opacity,style.opacity,'predictions and refused input never change measured pressure');
      filtered=style.filteredForce;
    }
    assert.equal(painter.uploaded.at(-1).total,5,'pointerup retracts predictions');
    assert.equal(input.pointer,undefined);assert.equal(input.hasPreview,true);
    input.presented();assert.equal(canvas.hidden,true);assert.equal(input.hasPreview,false);
    input.begin(pointer(150,410,0.2),{...basis,clip:{x:0,y:0,width:800,height:1000}});
    input.append(pointer(154,420,0.8,{getPredictedEvents:()=>[pointer(156,424,1),pointer(158,428,0.3)]}));
    const measuredForce=surface.penSample(0.8,0.2,0.004).filteredForce;
    const predictedForce=surface.penSample(1,measuredForce,0.002).filteredForce;
    assert.equal(painter.uploaded.at(-1).nodes.at(-1),Math.fround(surface.penSample(0.3,predictedForce,0.002).opacity));
    const page=input.finish(pointer(156,422,0.7));
    assert.ok(page.points.every(p=>p.width===2.2),'page zoom preserves native paper width');
    assert.equal(page.points.at(-1).opacity,surface.penSample(0.7,measuredForce,0.002).opacity);
    input.presented();
    input.begin(pointer(200,410),basis);lost(new Error('Device lost'));
    input.append(pointer(202,412));assert.equal(input.ready,false);
    input.dispose();const afterClose=notifications,replacement=makeGPU();
    finishConnect(replacement);await turn();
    assert.equal(replacement.disposed,true,'a late GPU connection cannot mount after disposal');
    assert.equal(input.ready,false);assert.equal(notifications,afterClose);assert.deepEqual(failures,[]);
  }finally{input.dispose();controller.abort();InkGPU.create=originalCreate;}
  cases.strokes.forEach((v,i)=>{
    const actual=surface.stroke(new Float32Array(v)), wanted=expected.strokes[i];
    assert.equal(actual.length,wanted.length,`stroke ${i} topology`);
    actual.forEach((value,j)=>{
      assert.ok(Number.isFinite(value));
      const nativeFloat=Math.fround(wanted[j]),error=Math.abs(value-nativeFloat);
      if(j%6<2){
        maximumPositionError=Math.max(maximumPositionError,error);
        // Apple's SIMD normalize and WASI scalar math may round differently.
        assert.ok(error<=Math.max(1e-6,Math.abs(nativeFloat)*8e-7),`stroke ${i} vertex ${j}: ${value} != ${nativeFloat}`);
      }else assert.equal(value,nativeFloat,`stroke ${i} color ${j}`);
    });
  });
  assert.throws(()=>surface.offset(world([maximum+1,0,0,0]),0,0),RangeError);
  assert.throws(()=>surface.offset(world([0,0,tile,0]),0,0),RangeError);
  assert.throws(()=>surface.camera({center:world([0,0,0,0]),scale:1},
    {x:0,y:600},{x:0,y:0},{x:0,y:0},1),RangeError);
  const largestFloat=2**128-2**104;
  for(const invalid of [[],[1],sample(0,0,-1),sample(NaN,0),
    sample(largestFloat,largestFloat,largestFloat),
    [...sample(0,0),...sample(1e30,1e30)],
    [...sample(largestFloat,1),...sample(-largestFloat,2)]]) {
    assert.throws(()=>surface.stroke(new Float32Array(invalid)),RangeError);
  }

  // The adapter has to reacquire memory views after allocation grows memory,
  // and returned meshes must survive subsequent calls without aliasing.
  const retained=surface.stroke(new Float32Array(cases.strokes[0]));
  const retainedCopy=retained.slice();
  const large=new Float32Array(65_536*7);
  for(let i=0;i<65_536;i++)large.set(sample(i/64,(i%32)/4),i*7);
  const largeMesh=surface.stroke(large);
  assert.equal(largeMesh.length,((65_536-1)*6+72)*6);
  assert.ok(largeMesh.every(Number.isFinite));
  assert.deepEqual(retained,retainedCopy);
  for(let i=0;i<100;i++)surface.stroke(new Float32Array(cases.strokes[4]));
  surface.dispose();surface.dispose();
  assert.throws(()=>surface.delta(world([0,0,0,0]),world([0,0,0,0])),/closed/);
  assert.throws(()=>surface.stroke(new Float32Array(cases.strokes[0])),/closed/);
  assert.throws(()=>admitPanelCamera(surface,{center,scale:1},viewport),/closed/);
  assert.throws(()=>transformPanelCamera(surface,initial,viewport,from,to,1),/closed/);
  assert.throws(()=>surface.manipulateFrame('move',{x:0,y:0,width:10,height:10},{x:1,y:1}),/closed/);
  assert.throws(()=>surface.inkContact(),/closed/);
} finally {surface.dispose();}

// Exercise the C ABI directly: invalid geometry and insufficient capacity must
// leave the caller's output untouched, and allocation limits cannot wrap.
const wasi=resolve(output,'wasi.mjs');
await build({entryPoints:[resolve(root,'MCP/panel/surface-wasi.ts')],outfile:wasi,
  bundle:true,platform:'node',format:'esm',target:'es2022'});
const {surfaceWasi}=await import(pathToFileURL(wasi).href);
let wasm;
({instance:{exports:wasm}}=await WebAssembly.instantiate(bytes,{wasi_snapshot_preview1:surfaceWasi(()=>wasm.memory)}));
wasm._initialize();
assert.equal(wasm.notebook_surface_alloc(0),0);
assert.equal(wasm.notebook_surface_alloc(64*1024*1024+1),0);
assert.equal(wasm.notebook_surface_stroke_capacity(65_537),0);
const input=wasm.notebook_surface_alloc(14*4),vertices=wasm.notebook_surface_alloc(78*6*4);
try {
  const inputs=new Float32Array(wasm.memory.buffer,input,14),mesh=new Float32Array(wasm.memory.buffer,vertices,78*6);
  mesh.fill(12345);inputs.set([...sample(0,0),...sample(10,10)]);
  assert.equal(wasm.notebook_surface_stroke(input,2,vertices,1),-78);
  assert.ok(mesh.every(value=>value===12345));
  inputs.set([...sample(2**128-2**104,1),...sample(-(2**128-2**104),2)]);
  assert.equal(wasm.notebook_surface_stroke(input,2,vertices,78),0);
  assert.ok(mesh.every(value=>value===12345));
} finally {wasm.notebook_surface_free(input);wasm.notebook_surface_free(vertices);}
const cameraBuffer=wasm.notebook_surface_alloc(32*8);
try {
  for(const scale of [0,-1,NaN,Infinity]){
    const values=new Float64Array(wasm.memory.buffer,cameraBuffer,32);
    values.fill(12345);values.set([0,0,0,0,scale,800,600,400,300,400,300,1]);
    assert.equal(wasm.notebook_surface_camera(cameraBuffer,cameraBuffer+16*8),0);
    assert.ok(new Float64Array(wasm.memory.buffer,cameraBuffer+16*8,5).every(value=>value===12345));
  }
  for(const input of [[NaN,-1,0],[0,Infinity,0],[0,-1,-1],[0,-1,Infinity]]){
    const values=new Float64Array(wasm.memory.buffer,cameraBuffer,32);
    values.fill(12345);values.set(input);
    assert.equal(wasm.notebook_surface_pen_sample(cameraBuffer,cameraBuffer+16*8),0);
    assert.ok(new Float64Array(wasm.memory.buffer,cameraBuffer+16*8,6).every(value=>value===12345));
  }
}finally{wasm.notebook_surface_free(cameraBuffer);}
const manipulationBuffer=wasm.notebook_surface_alloc(32*8);
try {
  const valid=[100,80,200,160,20,-10,0,0,0,0,0];
  const failures=[[-1,valid],[9,valid],[-(2**31),valid],[2**31-1,valid],
    ...[[0,NaN],[1,Infinity],[2,0],[3,-1],[4,NaN],[5,Infinity],[6,2]]
      .map(([index,value])=>[0,valid.map((n,i)=>i===index?value:n)]),
    [0,[100,80,200,160,20,-10,1,0,0,-600,800]],
    [0,[1e308,0,1,1,1e308,12,0,0,0,0,0]],
    [4,[-1e308,0,1e308,1,1e308,12,0,0,0,0,0]]];
  for(const [kind,input] of failures){
    const values=new Float64Array(wasm.memory.buffer,manipulationBuffer,32);
    values.fill(12345);values.set(input);
    assert.equal(wasm.notebook_surface_manipulate_frame(kind,manipulationBuffer,manipulationBuffer+16*8),0);
    assert.ok(new Float64Array(wasm.memory.buffer,manipulationBuffer+16*8,4).every(value=>value===12345));
  }
}finally{wasm.notebook_surface_free(manipulationBuffer);}
const inkPointer=wasm.notebook_surface_ink_create(),inkInput=wasm.notebook_surface_alloc(4*7*4),inkOutput=wasm.notebook_surface_alloc(4*6*4);
try{
  const input=new Float32Array(wasm.memory.buffer,inkInput,4*7),output=new Float32Array(wasm.memory.buffer,inkOutput,4*6);
  input.set([...sample(0,0),...sample(10,0)]);
  assert.equal(wasm.notebook_surface_ink_update(inkPointer,inkInput,2,0),2);
  output.fill(12345);
  assert.equal(wasm.notebook_surface_ink_nodes(inkPointer,inkOutput,1),-2);
  assert.ok(output.every(value=>value===12345));
  assert.equal(wasm.notebook_surface_ink_nodes(inkPointer,inkOutput,4),2);
  const saved=output.slice(0,12),dirty=wasm.notebook_surface_ink_dirty_start(inkPointer);
  for(const bad of [sample(NaN,0),sample(1e10,0),sample(20,0,-1),[20,0,1,0,0,0,2]]){
    input.set(bad,14);
    assert.equal(wasm.notebook_surface_ink_update(inkPointer,inkInput,3,2),0);
    assert.equal(wasm.notebook_surface_ink_dirty_start(inkPointer),dirty);
    assert.equal(wasm.notebook_surface_ink_vertex_count(inkPointer),78);
    assert.equal(wasm.notebook_surface_ink_nodes(inkPointer,inkOutput,4),2);
    assert.deepEqual(output.slice(0,12),saved,'a refused tail leaves the admitted contact untouched');
  }
  input.set(sample(20,0),14);
  assert.equal(wasm.notebook_surface_ink_update(inkPointer,inkInput,3,2),3);
  assert.equal(wasm.notebook_surface_ink_vertex_count(inkPointer),84);
}finally{wasm.notebook_surface_ink_free(inkPointer);wasm.notebook_surface_free(inkInput);wasm.notebook_surface_free(inkOutput);}
console.log(JSON.stringify({result:'PASS',wasm:receipt.sha256,cameras:cases.cameras.length,
  browserCameras:browserCameras.length,
  manipulations:cases.manipulations.length,
  offsets:cases.offsets.length,deltas:cases.deltas.length,strokes:cases.strokes.length,
  pressure:cases.pressure.length,incrementalUpdates:cases.ink.length,inputContact:'PASS',maximumNodeError,
  maximumPositionError,maximumStrokePoints:65_536},null,2));

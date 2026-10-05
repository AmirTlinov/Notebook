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
await build({entryPoints:[resolve(root,'MCP/panel/swift-surface.ts')],outfile:loader,
  bundle:true,platform:'node',format:'esm',target:'es2022'});
const {SwiftSurface}=await import(pathToFileURL(loader).href);
const surface=await SwiftSurface.load(bytes);
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
};
const native=spawnSync(resolve(output,'native'),[],{input:JSON.stringify(cases),encoding:'utf8',maxBuffer:8*1024*1024});
assert.equal(native.status,0,native.error?.message??native.stderr);
const expected=JSON.parse(native.stdout);
let maximumPositionError=0;
try {
  cases.cameras.forEach((v,i)=>{
    const camera=surface.camera({center:world(v),scale:v[4]}, {x:v[5],y:v[6]},
      {x:v[7],y:v[8]}, {x:v[9],y:v[10]},v[11]);
    assert.deepEqual([...address(camera.center),camera.scale],expected.cameras[i],`camera ${i}`);
  });
  cases.offsets.forEach((v,i)=>{
    if(expected.offsets[i]===null)assert.throws(()=>surface.offset(world(v),v[4],v[5]),RangeError);
    else assert.deepEqual(address(surface.offset(world(v),v[4],v[5])),expected.offsets[i],`offset ${i}`);
  });
  cases.deltas.forEach((v,i)=>{
    const delta=surface.delta(world(v),world(v.slice(4)));
    assert.deepEqual([delta.x,delta.y],expected.deltas[i],`delta ${i}`);
  });
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
console.log(JSON.stringify({result:'PASS',wasm:receipt.sha256,cameras:cases.cameras.length,
  offsets:cases.offsets.length,deltas:cases.deltas.length,strokes:cases.strokes.length,
  maximumPositionError,maximumStrokePoints:65_536},null,2));

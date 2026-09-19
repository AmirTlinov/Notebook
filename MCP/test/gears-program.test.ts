import assert from 'node:assert/strict';
import test from 'node:test';
import {readFile} from 'node:fs/promises';
import {angles,centers,design,ratios,selection,velocity,tau} from '../skills/notebook/assets/science/gears/model.js';
const {gearsProgramFixture,gearsFixtureURL}=await import(new URL('./gears-program-fixture.mjs',import.meta.url).href);
const near=(a:number,b:number)=>assert.ok(Math.abs(a-b)<1e-7,`${a} != ${b}`);
test('the three wheels retain pitch contact, angular ratios, units and a full marked return',()=>{
  assert.deepEqual(centers,[-75,25,89]);assert.deepEqual(ratios,[1,-1.5,2.5]);
  for(const phase of [0,.013,.125,.5,.73,1]){
    const a=angles(phase),b=angles(phase+.01),delta=b.map((v,i)=>v-a[i]!);
    near(delta[0]!*60+delta[1]!*40,0);near(delta[1]!*40+delta[2]!*24,0);
    for(let i=0;i<2;i++){
      const r=design.gears[i]!.teeth*design.module/2,next=design.gears[i+1]!.teeth*design.module/2;
      near(centers[i+1]!-centers[i]!,r+next);
      near(velocity(i,r,0)[1],velocity(i+1,-next,0)[1]);
    }
  }
  angles(1).forEach((a,i)=>near((a-angles(0)[i]!)/tau,[2,-3,5][i]!));
});
test('camera and control state reject invalid values without dependence on the viewport',()=>{
  assert.deepEqual(selection({camera:[Infinity,0,300],phase:NaN,reveal:7,selected:'not-a-part'}),{...selection(null),reveal:1});
  const saved={phase:.44,reveal:.7,selected:'output',field:true,camera:[0,390,1]};assert.deepEqual(selection(saved),saved);
  const value=selection(saved);value.camera[0]=7;assert.equal(saved.camera[0],0);
});
test('the real glTF fixture has bounded detailed geometry, shared 2K maps and stable part IDs',async()=>{
  const url=new URL('../skills/notebook/assets/science/gears/',import.meta.url);
  const gltf=JSON.parse(await readFile(new URL('mechanism.gltf',url),'utf8'));
  const metadata=JSON.parse(await readFile(new URL('metadata.json',url),'utf8'));
  const triangles=gltf.meshes.reduce((sum:number,m:any)=>sum+m.primitives.reduce((s:number,p:any)=>s+gltf.accessors[p.indices].count/3,0),0);
  assert.equal(triangles,metadata.triangles);assert.ok(triangles>=80_000&&triangles<=150_000);
  assert.equal((await readFile(new URL('mechanism.bin',url))).length,gltf.buffers[0].byteLength);
  const root=gltf.nodes[gltf.scenes[0].nodes[0]];assert.deepEqual(root.scale,[.001,.001,.001]);
  for(const id of ['input','idler','output','base','bridge'])assert.equal(gltf.nodes.filter((n:any)=>n.name===id).length,1);
  assert.deepEqual(gltf.images.map((i:any)=>i.uri),['machined.png','roughness.png']);
  for(const image of gltf.images){const bytes=await readFile(new URL(image.uri,url));assert.equal(bytes.readUInt32BE(16),2048);assert.equal(bytes.readUInt32BE(20),2048);}
  assert.deepEqual(await gearsProgramFixture(),JSON.parse(await readFile(gearsFixtureURL,'utf8')));
});

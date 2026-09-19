import assert from 'node:assert/strict';
import test from 'node:test';
import {readFile} from 'node:fs/promises';
import {generateSamples,envelope,selection,sampleWindow,count,binSize,impulseIndex} from '../skills/notebook/assets/science/signal/model.js';
const {signalProgramFixture,signalFixtureURL}=await import(new URL('./signal-program-fixture.mjs',import.meta.url).href);
const {prepare}=await import(new URL('../skills/notebook/scripts/prepare.mjs',import.meta.url).href);
test('dense signal source and min-max bins reproduce every sample and retain the rare extremum',async()=>{
  const samples=generateSamples(),bins=envelope(samples);
  const bytes=await readFile(new URL('../skills/notebook/assets/science/signal/data.bin',import.meta.url));
  assert.equal(samples.length,100_000);assert.equal(bytes.length,count*4);
  for(let i=0;i<count;i++)assert.equal(samples[i],bytes.readFloatLE(i*4));
  const overview=await readFile(new URL('../skills/notebook/assets/science/signal/overview.bin',import.meta.url));
  for(let b=0;b<bins.length/2;b++){
    assert.equal(bins[b*2],overview.readFloatLE(b*8));assert.equal(bins[b*2+1],overview.readFloatLE(b*8+4));
    for(let i=b*binSize;i<(b+1)*binSize;i++)assert.ok(samples[i]!>=bins[b*2]!&&samples[i]!<=bins[b*2+1]!);
  }
  assert.equal(bins[Math.floor(impulseIndex/binSize)*2+1],samples[impulseIndex+1]);
  assert.ok(samples[impulseIndex+1]!>2);assert.ok(Math.max(...Array.from(samples).filter((_,i)=>i%100===0))<1.5);
});
test('selection clamps by source sample indices and never depends on viewport',()=>{
  assert.deepEqual(selection({center:NaN,span:9}),{sample:null,center:50,span:4});
  for(const center of [-Infinity,-5,0,61.337,100,200])for(const span of [.05,.2,1,4]){
    const state=selection({center,span}),window=sampleWindow(state);
    assert.ok(window.start>=0&&window.end<=count);assert.equal(window.length,span*1000);
  }
  assert.deepEqual(sampleWindow(selection({center:61.337,span:.05})),{start:61312,end:61362,length:50,from:61.312,to:61.361});
});
test('the exact dense browser build and offline MathJax assets match the native fixture',async()=>{
  assert.deepEqual(await signalProgramFixture(),JSON.parse(await readFile(signalFixtureURL,'utf8')));
  const result=await prepare('program',{example:'signal'});assert.equal(result.build.cacheHit,true);
  assert.ok(result.package.files.some((f:any)=>f.path.includes('/svg/dynamic/')));
  assert.ok(result.package.files.filter((f:any)=>f.path.endsWith('.bin')).every((f:any)=>f.byteCount<=400_000));
  await assert.rejects(prepare('program',{example:'signal',entry:'ambiguous.ts'}),/not both/);
  await assert.rejects(prepare('animation',{example:'signal'}),/offline assets/);
});

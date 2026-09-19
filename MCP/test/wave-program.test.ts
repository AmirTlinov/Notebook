import assert from 'node:assert/strict';
import test from 'node:test';
import {Wave,parameters,initial,center,size,courant} from '../skills/notebook/assets/science/wave/model.js';
test('256-square wave starts from rest, keeps fixed boundaries and discrete energy',()=>{
 const p=parameters({time:1.2}),w=new Wave(p),start=initial(p),n=size;
 w.advance();const i=96*n+72,lap=start[i-1]!+start[i+1]!+start[i-n]!+start[i+n]!-4*start[i]!;
 assert.ok(Math.abs(w.field[i]!-(start[i]!+.5*w.c2*lap))<1e-7);
 while(w.advance());const r=w.report();assert.ok(Math.abs(r.energy-1)<1e-5,String(r.energy));assert.ok(r.amplitude<1);
 for(let i=0;i<n;i++){assert.equal(w.field[i],0);assert.equal(w.field[(n-1)*n+i],0);assert.equal(w.field[i*n],0);assert.equal(w.field[i*n+n-1],0);}
 assert.ok(2*w.c2<1);assert.ok(w.c2<=courant**2);assert.equal(r.time,p.time);
});
test('numerical mode converges toward the known two-dimensional standing wave',()=>{
 const errors=[32,64,128,256].map(n=>{const w=new Wave(parameters({shape:'mode',speed:1.7,time:.37}),n);while(w.advance());return w.report().error!;});
 for(let i=1;i<errors.length;i++)assert.ok(errors[i]!<errors[i-1]!*.36,JSON.stringify(errors));assert.ok(errors[3]!<3e-5);
});
test('seed, zero time and malformed parameters have explicit reproducible meanings',()=>{
 assert.deepEqual(parameters({speed:Infinity,time:NaN,seed:-5,shape:'unknown'}),{speed:1,time:.65,seed:1,shape:'pulse'});
 assert.deepEqual(center(246),center(246));assert.notDeepEqual(center(246),center(247));
 const w=new Wave(parameters({time:0}));assert.equal(w.advance(),false);assert.deepEqual(w.field,initial(w.p));assert.equal(w.report().time,0);
});

test('the actual external NumPy output agrees with the worker model and its provenance hashes',async()=>{
 const {readFile}=await import('node:fs/promises'),{createHash}=await import('node:crypto');
 const root=new URL('../skills/notebook/assets/science/wave/',import.meta.url),read=(name:string)=>readFile(new URL(name,root));
 const provenance=JSON.parse(await read('provenance.json').then(v=>v.toString()));
 const hash=(bytes:Uint8Array)=>createHash('sha256').update(bytes).digest('hex');
 assert.equal(hash(await read('generate.py')),provenance.scriptSHA256);assert.equal(hash(await read('recording-input.json')),provenance.inputSHA256);
 for(const [name,info] of Object.entries(provenance.outputs) as [string,{sha256:string;bytes:number}][]){const bytes=await read(name);assert.equal(bytes.length,info.bytes);assert.equal(hash(bytes),info.sha256);}
 const w=new Wave(parameters(provenance.parameters));while(w.advance());assert.equal(w.steps,provenance.steps);assert.equal(w.dt,provenance.dt);
 const bytes=await read('final.bin');let error=0;for(let i=0;i<w.field.length;i++)error=Math.max(error,Math.abs(w.field[i]!-bytes.readFloatLE(i*4)));
 assert.ok(error<3e-6,String(error));
 const {waveProgramFixture,waveFixtureURL}=await import(new URL('./wave-program-fixture.mjs',import.meta.url).href);
 assert.deepEqual(await waveProgramFixture(),JSON.parse(await readFile(waveFixtureURL,'utf8')));
});

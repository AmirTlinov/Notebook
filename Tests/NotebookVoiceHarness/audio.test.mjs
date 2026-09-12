import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const ctx=vm.createContext({});vm.runInContext(fs.readFileSync(new URL('../../Applications/WebResources/voice-audio.js',import.meta.url),'utf8'),ctx);
const Audio=ctx.NotebookVoiceAudio;
test('waiting never transmits ambient audio and activation replays the whole addressed request exactly once',()=>{
 const gate=new Audio(10);gate.append(Float32Array.of(9,9,9));assert.deepEqual([...gate.output(3)],[0,0,0]);
 gate.append(Float32Array.of(1,2,3));gate.activate(3);gate.append(Float32Array.of(4,5));assert.deepEqual([...gate.output(2)],[0,0]);
 gate.sending=true;assert.deepEqual([...gate.output(8)],[1,2,3,4,5,0,0,0]);assert.deepEqual([...gate.output(2)],[0,0]);
});
test('retention is bounded and an expired or missing address fails closed',()=>{
 const gate=new Audio(1);for(let i=0;i<100;i++)gate.append(Float32Array.of(i));assert.ok(gate.blocks.length<=13);
 assert.throws(()=>gate.activate(0));assert.throws(()=>gate.activate(gate.frame));
 const slow=new Audio(1);slow.append(Float32Array.of(1));slow.activate(0);assert.throws(()=>slow.append(new Float32Array(41)));
});
test('mute drops every pending sample and quiet speech is never classified as disposable silence',()=>{
 const gate=new Audio(10);const quiet=new Float32Array(30).fill(.00001);gate.append(quiet);gate.activate(0);gate.sending=true;
 assert.deepEqual([...gate.output(30)],[...quiet]);gate.append(Float32Array.of(7));gate.clear();assert.deepEqual([...gate.output(3)],[0,0,0]);
 gate.append(Float32Array.of(8));gate.mode='holding';gate.sending=true;gate.append(Float32Array.of(2));assert.deepEqual([...gate.output(3)],[2,0,0]);
});

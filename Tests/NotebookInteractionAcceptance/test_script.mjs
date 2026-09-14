// CPU-only observer contracts. A VM is not WebKit or displayed-frame evidence.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const swift=fs.readFileSync(new URL('../../Applications/Shared/NotebookInteractionScript.swift',import.meta.url),'utf8');
const source=swift.split('"""')[1].replace('\\(selectorsJSON)','["#count"]');
function setup(types=[]){
  const messages=[],listeners=new Map(),microtasks=[],observers=[];
  class Element { constructor(){this.tagName='OUTPUT';this.id='count';this.textContent='0';this.value=undefined;}
    getAttribute(){return null;} getBoundingClientRect(){return {x:1,y:2,width:30,height:20};}}
  const node=new Element();
  class PerformanceObserver {
    static supportedEntryTypes=types;
    constructor(callback){this.callback=callback;observers.push(this);}
    observe(config){this.config=config;}
  }
  let mutation;
  const context={notebookLoadToken:'immutable-runtime',performance:{now:()=>20,timeOrigin:1700000000000},
    Element,PerformanceObserver,MutationObserver:class {constructor(fn){mutation=fn;}observe(options){this.options=options;}},
    innerWidth:500,innerHeight:700,queueMicrotask:fn=>microtasks.push(fn),
    addEventListener:(name,fn,options)=>{listeners.set(name,{fn,options});},
    document:{querySelector:()=>node,body:{}},
    window:{webkit:{messageHandlers:{notebook:{postMessage:value=>messages.push(value)}}}}};
  vm.runInNewContext(source,context);
  return {messages,listeners,node,observers,microtasks,mutate:()=>mutation(),
    dispatch:(name,fields={})=>listeners.get(name).fn({type:name,isTrusted:true,timeStamp:12,pointerId:7,target:node,...fields})};
}
test('only actual trusted input is observed and never prevented',()=>{
  const x=setup();x.dispatch('pointerdown',{isTrusted:false});assert.equal(x.messages.length,1);
  x.dispatch('pointerdown');assert.equal(x.messages.at(-1).observation.stage,'trusted_event');
  assert.equal(x.messages.at(-1).token,'immutable-runtime');
  for(const name of ['pointerdown','pointerup','click','input','change','keydown']){
    assert.equal(x.listeners.get(name).options.passive,true);assert.equal(x.listeners.get(name).options.capture,true);
  }
});
test('DOM observations do not claim display',()=>{
  const x=setup();x.dispatch('DOMContentLoaded');x.dispatch('click');x.node.textContent='1';x.mutate();
  const changed=x.messages.at(-1).observation;
  assert.equal(changed.stage,'dom_observable_change');assert.equal(changed.observables[0].text,'1');
  assert.equal(changed.precedingEvent.name,'click');
  x.microtasks.forEach(fn=>fn());assert.equal(x.messages.at(-1).observation.stage,'post_listener_microtask_dom');
  assert.equal(x.node.textContent,'1');
});
test('missing Event Timing is explicitly unavailable and not zero duration',()=>{
  const x=setup();assert.equal(x.observers.length,0);
  assert.equal(x.messages[0].observation.eventTiming,false);assert.equal(x.messages[0].observation.displayMeasured,false);
  assert.equal(x.messages[0].observation.duration,undefined);
});
test('Event Timing precision and threshold are explicit',()=>{
  const x=setup(['event','first-input']);assert.equal(x.observers[0].config.durationThreshold,16);
  x.observers[0].callback({getEntries:()=>[{name:'click',entryType:'event',startTime:12,duration:24,
    processingStart:14,processingEnd:20,interactionId:3,target:x.node}]});
  const entry=x.messages.at(-1).observation;assert.equal(entry.duration,24);
  assert.equal(entry.durationQuantizationMs,8);assert.equal(entry.displayMeasured,false);
});
test('observer output stops at its explicit budget',()=>{
  const x=setup();for(let i=0;i<10000;i++)x.dispatch('input');
  const count=x.messages.length;assert.ok(count<=4097);assert.equal(x.messages.at(-1).observation.stage,'truncated');
  x.dispatch('click');assert.equal(x.messages.length,count);
});

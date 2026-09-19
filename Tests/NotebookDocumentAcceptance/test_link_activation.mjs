import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
import test from 'node:test';
import vm from 'node:vm';

// Executes the shipped listener, without a browser/gesture/display claim.
// Node Event.isTrusted is always false: this harness never fabricates true.
const rootDirectory = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const shell = readFileSync(path.join(rootDirectory, 'Applications/WebResources/document-shell.html'), 'utf8');
const start = shell.indexOf('let linkActivationSequence = 0;');
const end = shell.indexOf('const editingTouches = new Map();', start);
assert.ok(start >= 0 && end > start);
const listenerSource = shell.slice(start, end);
function fixture() {
  const records = [];
  const anchor = {getAttribute: name => name === 'href' ? '#раздел:β' : null};
  let click;
  const receipt = {documentID:'document', runtimeID:'runtime', generation:'3', sourceKey:'source',
    stateKey:'state', renderToken:'pixels', pageIndex:0, presentationEpoch:'7', presentation:'canonical'};
  const context = vm.createContext({root:{contains: value => value === anchor,
    addEventListener:(name, listener) => { if(name==='click')click=listener; }},
    payload:{}, layoutCanonical:true, editingBlockID:null, presentationIsRendering:false,
    lastTouchTap:{}, presentationReceipt:()=>receipt, bridge:value=>records.push(value)});
  vm.runInContext(listenerSource, context);
  return {records, context, receipt, click:()=>{
    const event = new Event('click', {cancelable:true});
    Object.defineProperty(event,'target',{value:{closest:()=>anchor}});
    Object.defineProperty(event,'userActivated',{value:true}); // Untrusted args do not grant trust.
    click(event);
    return event;
  }};
}

test('canonical activation preserves source provenance and event trust, never caller arguments',()=>{
  const f=fixture(); const event=f.click();
  assert.equal(event.defaultPrevented,true);
  assert.equal(f.records.length,1);
  for(const [key,value] of Object.entries(f.receipt))assert.equal(f.records[0][key],value);
  assert.equal(f.records[0].href,'#раздел:β');
  assert.equal(f.records[0].userActivated,false);
  assert.equal(f.records[0].activationSequence,'1');
});

test('a runtime assigns distinct ordered identities to terminal activations',()=>{
  const f=fixture(); f.click(); f.click();
  assert.deepEqual(f.records.map(x=>x.activationSequence),['1','2']);
});

test('editor, rendering and absent canonical source cannot emit navigation',()=>{
  for(const [key,value] of [['payload',null],['layoutCanonical',false],['presentationIsRendering',true]]){
    const f=fixture(); f.context[key]=value;
    assert.equal(f.click().defaultPrevented,true);
    assert.equal(f.records.length,0,key);
  }
});

// The same shipped activation boundary owns source editing. In particular,
// two pointer releases from one pinch must never masquerade as two taps.
function editingFixture() {
  const listeners = new Map(), edits = [];
  let now = 0;
  const section = {dataset:{blockId:'body'}};
  const target = {closest: selector => selector === '.block.editable' ? section : null};
  const listen = (name, listener) => listeners.set(name, listener);
  const context = vm.createContext({
    root:{contains: value => value === section, addEventListener:listen},
    editorLayer:{addEventListener:()=>{}}, addEventListener:listen,
    lastTouchTap:null, performance:{now:()=>now}, beginEditing:id=>edits.push(id),
  });
  const end = shell.indexOf("addEventListener('message'", start);
  vm.runInContext(shell.slice(start, end), context);
  function send(type, id=1, x=100, y=100, pointerType='touch') {
    now += 20;
    listeners.get(type)?.({pointerId:id, clientX:x, clientY:y, pointerType, target,
      preventDefault(){}});
  }
  return {edits, send, advance:ms=>{now+=ms}, tap:()=>{send('pointerdown');send('pointerup')}};
}

test('a two-finger pinch and its compatibility double-click never edit source',()=>{
  const f=editingFixture();
  f.send('pointerdown',1,100); f.send('pointerdown',2,120);
  f.send('pointerup',1,100); f.send('pointerup',2,120);
  f.send('dblclick');
  assert.deepEqual(f.edits,[]);
  f.tap(); f.tap();
  assert.deepEqual(f.edits,['body'], 'a subsequent deliberate double tap still works');
});

test('drag, cancellation, long hold and orphan release cannot complete a double tap',()=>{
  for(const kind of ['drag','cancel','hold','orphan']) {
    const f=editingFixture(); f.tap();
    if(kind!=='orphan')f.send('pointerdown');
    if(kind==='drag') { f.send('pointermove',1,160); f.send('pointermove',1,100); }
    if(kind==='cancel')f.send('pointercancel');
    if(kind==='hold')f.advance(500);
    f.send('pointerup'); f.send('dblclick');
    assert.deepEqual(f.edits,[],kind);
  }
});

test('single-finger double tap has one owner; a later mouse double-click still edits',()=>{
  const f=editingFixture(); f.tap();f.tap();f.send('dblclick');
  assert.deepEqual(f.edits,['body']);
  f.send('pointerdown',3,100,100,'mouse');f.send('dblclick',3,100,100,'mouse');
  assert.deepEqual(f.edits,['body','body']);
});

// Exercise the actual message builder too: a gesture-only test cannot detect
// a native receiver rejecting a message with no document identity.
test('source request carries the installed document, runtime, generation and page',()=>{
  const messages = [], receipt = {documentID:'doc',runtimeID:'runtime',sourceKey:'source',generation:'7',pageIndex:2};
  const context = vm.createContext({payload:{editable:true,blocks:[{id:'body',kind:'tex'}]},
    root:{getBoundingClientRect:()=>({left:10,top:20,width:100,height:200}),clientWidth:200,clientHeight:400},
    presentationReceipt:()=>receipt,bridge:message=>messages.push(message)});
  vm.runInContext(shell.slice(shell.indexOf('const beginEditing ='), shell.indexOf('const setEditingEnabled ='))+
    "beginEditing('body',{clientX:35,clientY:50});",context);
  for(const [key,value] of Object.entries(receipt))assert.equal(messages[0][key],value);
  assert.equal(messages[0].kind,'requestSource');assert.equal(messages[0].x,50);assert.equal(messages[0].y,60);
});

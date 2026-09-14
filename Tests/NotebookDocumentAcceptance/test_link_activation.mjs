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
const end = shell.indexOf("root.addEventListener('dblclick'", start);
assert.ok(start >= 0 && end > start);
const listenerSource = shell.slice(start, end);
function fixture() {
  const records = [];
  const anchor = {getAttribute: name => name === 'href' ? '#раздел:β' : null};
  let click;
  const receipt = {documentID:'document', runtimeID:'runtime', generation:'3', sourceKey:'source',
    stateKey:'state', renderToken:'pixels', pageIndex:0, presentationEpoch:'7', presentation:'canonical'};
  const context = vm.createContext({root:{contains: value => value === anchor,
    addEventListener:(name, listener) => { assert.equal(name,'click'); click=listener; }},
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
  for(const [key,value] of [['payload',null],['layoutCanonical',false],['editingBlockID','editing'],['presentationIsRendering',true]]){
    const f=fixture(); f.context[key]=value;
    assert.equal(f.click().defaultPrevented,true);
    assert.equal(f.records.length,0,key);
  }
});

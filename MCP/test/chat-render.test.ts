import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFileSync} from 'node:fs';
import {runInContext} from 'node:vm';
import {setImmediate} from 'node:timers/promises';
import {Marked} from 'marked';
import createDOMPurify from 'dompurify';
const domModule='jsdom';const {JSDOM}=await import(domModule);

function deferred(){let resolve!:()=>void,reject!:(e:Error)=>void;const promise=new Promise<void>((yes,no)=>{resolve=yes;reject=no;});return {promise,resolve,reject};}
function chatHarness(options:{startup?:Promise<void>,typeset?:(nodes:any[])=>Promise<void>,clear?:(nodes:any[])=>void,found?:(items:Set<any>)=>void}={}){
  const html=readFileSync(new URL('../../Applications/WebResources/chat-shell.html',import.meta.url),'utf8');
  const source=html.slice(html.indexOf('<script>\nconst escapeMath')+8,html.lastIndexOf('</script>'));
  const dom=new JSDOM('<!doctype html><body><main id="messages"></main></body>',{runScripts:'outside-only'});
  const window=dom.window,document=window.document,root=document.getElementById('messages');
  const layout={height:100,width:640},typesets:number[]=[],cleared:any[]=[],errors:unknown[][]=[],scrolls:number[]=[];
  Object.defineProperty(document.documentElement,'scrollHeight',{get:()=>layout.height});
  Object.defineProperty(window,'scrollY',{value:0,writable:true});window.innerHeight=1000;
  window.scrollTo=(_x:number,y:number)=>{scrolls.push(y);window.scrollY=Math.max(0,Math.min(y,layout.height-window.innerHeight));};
  window.scrollBy=(_x:number,y:number)=>{scrolls.push(y);window.scrollY+=y;};
  window.HTMLElement.prototype.getBoundingClientRect=function(){return {top:0,bottom:20,height:20,width:layout.width};};
  window.HTMLElement.prototype.scrollIntoView=function(){};
  let parses=0,active=0;const parser=new Marked(),parse=parser.parse.bind(parser);
  parser.parse=((s:string)=>{parses++;return parse(s);}) as typeof parser.parse;
  window.marked=parser;window.DOMPurify=createDOMPurify(window);window.console={error:(...args:unknown[])=>errors.push(args)};
  const math=new Set<any>(),actions=new Map<string,(doc:any)=>void>();
  const mathDocument={math,addRenderAction(name:string,_priority:number,action:(doc:any)=>void){actions.set(name,action);},removeRenderAction(name:string){actions.delete(name);}};
  window.MathJax={startup:{promise:options.startup??Promise.resolve(),document:mathDocument},
    typesetClear(nodes:any[]){assert.equal(active,0,'Cleanup cannot race active math');cleared.push(...nodes);for(const item of math)if(nodes.includes(item.owner))math.delete(item);options.clear?.(nodes);},
    async typesetPromise(nodes:any[]){
      active++;assert.equal(active,1);typesets.push(nodes.length);
      try{
        for(const owner of nodes){
          const walker=document.createTreeWalker(owner,window.NodeFilter.SHOW_TEXT);let node;
          while(node=walker.nextNode())for(const match of node.data.matchAll(/\$([^$]+)\$/g))
            math.add({owner,math:match[1],start:{node,n:match.index},end:{node,n:match.index+match[0].length}});
        }
        options.found?.(math);
        for(const action of actions.values())action(mathDocument);
        await options.typeset?.(nodes);
        const edits=[...math].map(item=>{const range=document.createRange();range.setStart(item.start.node,item.start.n);range.setEnd(item.end.node,item.end.n);return {item,range};});
        for(const {item,range} of edits.reverse()){
          if(item.math==='bad')throw new Error('fixture rejected retained math item');
          const output=document.createElement('mjx-container');output.textContent=item.math;item.typesetRoot=output;
          range.deleteContents();range.insertNode(output);
        }
      }finally{active--;}
    }};
  runInContext(source,dom.getInternalVMContext());
  return {window,document,root,layout,typesets,cleared,errors,scrolls,math,actions,get parses(){return parses;},
    evaluate:(script:string)=>runInContext(script,dom.getInternalVMContext()),
    async settle(){await runInContext('(async()=>{while(mathRendering)await mathRendering;})()',dom.getInternalVMContext());},
    close(){dom.window.close();}};
}
const message=(id:string,text:string)=>({id,role:'assistant',text});
function update(conversation:string,messages:ReturnType<typeof message>[],extra:Record<string,unknown>={}){
  return {conversation,reset:false,order:messages.map(m=>m.id),upserts:messages,removed:[],work:null,turnStatuses:{},focus:null,...extra};
}
async function accepted(publication:Promise<void>){assert.equal(await Promise.race([publication.then(()=>true),setImmediate().then(()=>false)]),true,'Transcript acceptance must not wait for unrelated MathJax work');}

test('chat delta retains unchanged nodes and prepares only changed message bodies',async()=>{
  const h=chatHarness();const publish=async(value:unknown)=>{await h.window.updateMessages(value);await h.settle();};
  const messages=Array.from({length:128},(_,i)=>message('message-'+i,'Body '+i));
  const base=update('one',messages);await publish(base);assert.equal(h.parses,128);assert.deepEqual(h.typesets,[128]);
  const first=h.root.children[0],changed=h.root.children[127];
  await publish({...base,upserts:[{...messages[127],text:'Changed'}]});
  assert.equal(h.parses,129);assert.equal(h.root.children[0],first);assert.equal(h.root.children[127],changed);assert.deepEqual(h.typesets,[128,1]);
  await publish({...base,upserts:[],work:{turnID:'work',title:'Working',running:true}});assert.equal(h.parses,129);
  const activity={id:'tool',turnID:'turn',role:'assistant',text:'Command',activity:{kind:'command',status:'completed'}};
  await publish({...base,order:['tool'],removed:messages.map(m=>m.id),upserts:[activity]});
  const group=h.root.children[0];group.open=true;const article=group.children[1];
  await publish({...base,order:['tool'],upserts:[],turnStatuses:{turn:'interrupted'}});
  assert.equal(h.root.children[0],group);assert.equal(group.open,true);assert.equal(group.children[1],article);assert.match(group.textContent,/Остановлено/);
  await publish({...base,order:['older-tool','tool'],upserts:[{...activity,id:'older-tool'}]});assert.equal(h.root.children[0],group);assert.equal(group.open,true);h.close();
});

test('plain text and reset publish before startup and only current bodies are cloned',async()=>{
  const startup=deferred(),h=chatHarness({startup:startup.promise});
  await accepted(h.window.updateMessages(update('old',[message('same','$old$')])));
  for(let i=0;i<50;i++)await accepted(h.window.updateMessages(update('new',[message('same','Plain '+i)])));
  assert.match(h.root.textContent,/Plain 49/);assert.deepEqual(h.typesets,[]);assert.equal(h.document.querySelectorAll('.math-stage').length,0);
  startup.resolve();await h.settle();assert.deepEqual(h.typesets,[1]);assert.equal(h.document.querySelectorAll('.math-stage').length,0);h.close();
});

test('delayed math cannot overwrite a reset conversation with a reused message ID',async()=>{
  const held=deferred(),started=deferred();let calls=0;
  const h=chatHarness({typeset:async()=>{if(calls++===0){started.resolve();await held.promise;}}});
  await accepted(h.window.updateMessages(update('old',[message('same','$old$')])));await started.promise;
  await accepted(h.window.updateMessages(update('new',[message('same','$new$')])));held.resolve();await h.settle();
  assert.equal(h.root.querySelector('mjx-container').textContent,'new');assert.deepEqual(h.typesets,[1,1]);assert.equal(h.math.size,0);h.close();
});

test('streaming coalesces the latest source while preserving the current article and actions',async()=>{
  const held=deferred(),started=deferred();let calls=0;
  const h=chatHarness({typeset:async()=>{if(calls++===0){started.resolve();await held.promise;}}});
  await accepted(h.window.updateMessages(update('one',[message('same','$0$')])));await started.promise;
  const article=h.root.children[0];for(let i=1;i<=100;i++)await accepted(h.window.updateMessages(update('one',[message('same','$'+i+'$')])));
  const save=article.querySelector('.save-answer');assert.equal(h.root.children[0],article);assert.equal(h.evaluate('pendingMath.size'),1);assert.equal(h.document.querySelectorAll('.math-stage').length,1);
  held.resolve();await h.settle();assert.equal(article.querySelector('mjx-container').textContent,'100');assert.equal(article.querySelector('.save-answer'),save);assert.deepEqual(h.typesets,[1,1]);h.close();
});

test('removal and conversion to activity retire pending math without delaying the transcript',async()=>{
  const startup=deferred(),h=chatHarness({startup:startup.promise});
  await accepted(h.window.updateMessages(update('one',[message('same','$old$')])));
  const activity={...message('same','Command'),turnID:'turn',activity:{kind:'command',status:'inProgress'}};
  await accepted(h.window.updateMessages(update('one',[activity])));startup.resolve();await h.settle();assert.deepEqual(h.typesets,[]);assert.match(h.root.textContent,/Command/);h.close();
});

test('a failed live math source does not poison another body in the same conversation',async()=>{
  const held=deferred(),started=deferred();let calls=0;
  const h=chatHarness({typeset:async()=>{if(++calls===1){started.resolve();await held.promise;}}});
  const first=message('first','$bad$');await accepted(h.window.updateMessages(update('one',[first])));await started.promise;
  await accepted(h.window.updateMessages(update('one',[first,message('second','$good$')])));held.reject(new Error('fixture async load rejection'));await h.settle();
  assert.match(h.root.children[0].textContent,/\$bad\$/);assert.equal(h.root.children[1].querySelector('mjx-container').textContent,'good');assert.equal(h.errors.length,1);assert.equal(h.math.size,0);assert.equal(h.actions.size,0);h.close();
});

test('startup failure cannot retain or reject transcript acceptance',async()=>{
  const startup=deferred(),h=chatHarness({startup:startup.promise});await accepted(h.window.updateMessages(update('one',[message('same','First')])));
  startup.reject(new Error('fixture startup failure'));await h.settle();await accepted(h.window.updateMessages(update('two',[message('next','Next')])));await h.settle();
  assert.match(h.root.textContent,/Next/);assert.equal(h.evaluate('pendingMath.size'),0);assert.equal(h.document.querySelectorAll('.math-stage').length,0);h.close();
});

for(const change of ['status','controls'])test(`${change}-only delta preserves tail intent when prepared math changes height`,async()=>{
  const held=deferred(),started=deferred(),h=chatHarness({typeset:async()=>{started.resolve();await held.promise;}});
  h.layout.height=2000;h.window.scrollY=1000;
  const insert=h.window.Range.prototype.insertNode;h.window.Range.prototype.insertNode=function(node:any){insert.call(this,node);if(h.root.contains(node))h.layout.height=3000;};
  const first=message('same','$x$');await accepted(h.window.updateMessages(update('one',[first])));await started.promise;
  await accepted(h.window.updateMessages(update('one',change==='controls'?[{...first,isTruncated:true} as typeof first]:[first],change==='status'?{work:{turnID:'w',title:'Working',running:true}}:{})));
  held.resolve();await h.settle();assert.equal(h.window.scrollY,2000);assert.deepEqual(h.typesets,[1]);h.close();
});

test('math commit preserves newer human scroll, prose selection and focused link',async()=>{
  const held=deferred(),started=deferred(),h=chatHarness({typeset:async()=>{started.resolve();await held.promise;}});
  h.layout.height=2000;h.window.scrollY=1000;
  await accepted(h.window.updateMessages(update('one',[message('same','same $x$ same [link](https://example.com)')])));await started.promise;
  const p=h.root.querySelector('.content p'),tail=p.childNodes[2],link=p.querySelector('a'),selection=h.window.getSelection();
  link.focus();selection.setBaseAndExtent(tail,1,tail,5);h.window.scrollY=200;held.resolve();await h.settle();
  assert.equal(selection.toString(),'same');assert.equal(selection.anchorNode,tail);assert.equal(h.document.activeElement,link);assert.equal(h.window.scrollY,200);h.close();
});

test('raw HTML mixed prose/math retains duplicate-word endpoints and details focus through exact Range edits',async()=>{
  const held=deferred(),started=deferred(),h=chatHarness({typeset:async()=>{started.resolve();await held.promise;}});
  await accepted(h.window.updateMessages(update('one',[message('same','<details><summary>Focus</summary><p>same $x$ same</p></details>')])));await started.promise;
  const details=h.root.querySelector('details'),summary=details.querySelector('summary'),text=details.querySelector('p').firstChild,s=h.window.getSelection();
  details.open=true;summary.focus();s.setBaseAndExtent(text,9,text,13);held.resolve();await h.settle();
  assert.equal(s.toString(),'same');assert.equal(h.document.activeElement,summary);assert.equal(details.open,true);assert.equal(h.root.querySelectorAll('mjx-container').length,1);h.close();
});

test('subsequent source update preserves selected prose after previously rendered math',async()=>{
  const h=chatHarness(),first=message('same','same $x$ same');await h.window.updateMessages(update('one',[first]));await h.settle();
  const p=h.root.querySelector('.content p'),tail=p.lastChild,s=h.window.getSelection();s.setBaseAndExtent(tail,1,tail,5);
  await accepted(h.window.updateMessages(update('one',[message('same','same $x$ same and more')])));assert.equal(s.toString(),'same');await h.settle();assert.equal(s.toString(),'same');h.close();
});

test('cleared human selection stays cleared while multiple UTF-16 math ranges commit',async()=>{
  const held=deferred(),started=deferred(),h=chatHarness({typeset:async()=>{started.resolve();await held.promise;}});
  await accepted(h.window.updateMessages(update('one',[message('same','<p>😀 $x$ middle $y$ same</p>')])));await started.promise;
  const p=h.root.querySelector('p'),s=h.window.getSelection();s.selectAllChildren(p);s.removeAllRanges();held.resolve();await h.settle();
  assert.equal(s.rangeCount,0);assert.equal(p.textContent,'😀 x middle y same');assert.equal(p.querySelectorAll('mjx-container').length,2);h.close();
});

test('staging is inert, suppresses duplicate IDs, matches width and retries a resized source',async()=>{
  const held=deferred(),started=deferred(),widths:string[]=[];let calls=0;
  const h=chatHarness({typeset:async nodes=>{const stage=nodes[0].parentElement;assert.equal(stage.inert,true);assert.equal(stage.getAttribute('aria-hidden'),'true');assert.equal(stage.querySelectorAll('[id]').length,0);widths.push(stage.style.width);if(calls++===0){started.resolve();await held.promise;}}});
  await accepted(h.window.updateMessages(update('one',[message('same','<p id="source-anchor">$x$</p>')])));await started.promise;
  assert.equal(h.document.querySelectorAll('#source-anchor').length,1);h.layout.width=480;held.resolve();await h.settle();
  assert.deepEqual(widths,['640px','480px']);assert.equal(h.document.querySelectorAll('#source-anchor').length,1);assert.equal(h.document.querySelectorAll('.math-stage').length,0);h.close();
});

test('cleanup failure removes the active staging host and leaves plain source',async()=>{
  const h=chatHarness({clear:()=>{throw new Error('fixture cleanup failure');}});await accepted(h.window.updateMessages(update('one',[message('same','$x$')])));await h.settle();
  assert.equal(h.document.querySelectorAll('.math-stage').length,0);assert.match(h.root.textContent,/\$x\$/);assert.equal(h.errors.length,1);h.close();
});


test('selection inside replaced TeX follows native Range collapse without selecting unrelated prose',async()=>{
  const held=deferred(),started=deferred(),h=chatHarness({typeset:async()=>{started.resolve();await held.promise;}});
  await accepted(h.window.updateMessages(update('one',[message('same','<p>before $x$ after</p>')])));await started.promise;
  const text=h.root.querySelector('p').firstChild,s=h.window.getSelection(),offset=text.data.indexOf('x');s.setBaseAndExtent(text,offset,text,offset+1);
  held.resolve();await h.settle();assert.equal(s.isCollapsed,true);assert.equal(s.toString(),'');assert.equal(h.root.querySelector('mjx-container').textContent,'x');h.close();
});

test('overlapping engine source matches are rejected before any live mutation',async()=>{
  const h=chatHarness({found:items=>{const first=[...items][0];if(first)items.add({...first});}});
  await accepted(h.window.updateMessages(update('one',[message('same','$x$')])));await h.settle();
  assert.equal(h.root.querySelectorAll('mjx-container').length,0);assert.match(h.root.textContent,/\$x\$/);assert.equal(h.errors.length,1);
  assert.match(String(h.errors[0]),/Overlapping transcript math sources/);assert.equal(h.document.querySelectorAll('.math-stage').length,0);h.close();
});

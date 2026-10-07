import assert from 'node:assert/strict';
import {test} from 'node:test';
import {execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

// Real bundled engine, with its Node lite adaptor. This checks MathJax ownership
// and SVG portability, not browser font metrics, layout or native selection.
test('clearing a settled staged MathJax job permits later math and retains prepared SVG',()=>{
  // Isolate MathJax's singleton and the deliberately rejected loader fixture.
  // 4.1.3 can also report that exact injected error through an internal readiness
  // rejection. Record it explicitly; any unrelated rejection fails the child.
  const output=execFileSync(process.execPath,['--input-type=module','--eval',String.raw`
    import assert from 'node:assert/strict';
    import MathJax from './MCP/node_modules/mathjax/node-main.mjs';
    const expectedRejections=[];
    process.on('unhandledRejection',error=>{
      if(error?.message!=='fixture failed asynchronous TeX load')throw error;
      expectedRejections.push(error.message);
    });
    await MathJax.init({startup:{typeset:false},loader:{load:['input/tex','output/svg']},tex:{inlineMath:[['$','$']]}});
    const adaptor=MathJax.startup.adaptor,doc=MathJax.startup.document;
    const first=adaptor.node('article',{},[adaptor.text('$first$')]);adaptor.append(adaptor.body(doc.document),first);
    const original=doc.inputJax[0].compile.bind(doc.inputJax[0]),calls=[];
    doc.inputJax[0].compile=(item,document)=>{
      calls.push(item.math);
      if(item.math==='first'){
        const error=Object.assign(new Error('retry'),{retry:Promise.reject(new Error('fixture failed asynchronous TeX load'))});
        void error.retry.catch(()=>{});throw error;
      }
      return original(item,document);
    };
    await assert.rejects(MathJax.typesetPromise([first]),/fixture failed asynchronous TeX load/);
    assert.equal(Array.from(doc.math).length,1,'Rejected math remains registered until its owner clears it');
    MathJax.typesetClear([first]);adaptor.remove(first);
    const second=adaptor.node('article',{},[adaptor.text('$second$')]);adaptor.append(adaptor.body(doc.document),second);
    await MathJax.typesetPromise([second]);assert.deepEqual(calls,['first','second']);
    const prepared=adaptor.innerHTML(second);assert.match(prepared,/<mjx-container/);assert.match(prepared,/<svg/);
    MathJax.typesetClear([second]);assert.equal(Array.from(doc.math).length,0);
    assert.equal(adaptor.innerHTML(second),prepared,'Clearing ownership must retain prepared SVG');
    const live=adaptor.node('div');adaptor.append(adaptor.body(doc.document),live);
    for(const child of [...adaptor.childNodes(second)]){adaptor.remove(child);adaptor.append(live,child);}
    adaptor.remove(second);assert.equal(adaptor.innerHTML(live),prepared,'Prepared SVG survives the body commit');
    await new Promise(resolve=>setImmediate(resolve));
    console.log(JSON.stringify({calls,retainedItems:Array.from(doc.math).length,svgPreserved:true,expectedReadinessRejections:expectedRejections.length}));
  `],{cwd:fileURLToPath(new URL('../..',import.meta.url)),encoding:'utf8',timeout:15000});
  const result=JSON.parse(output);assert.deepEqual(result.calls,['first','second']);
  assert.equal(result.retainedItems,0);assert.equal(result.svgPreserved,true);
});

async function realTranscript(){
  const modulePath='jsdom';const {JSDOM,VirtualConsole}=await import(modulePath);
  const errors:Error[]=[],virtualConsole=new VirtualConsole();virtualConsole.on('jsdomError',(error:Error)=>errors.push(error));
  virtualConsole.on('error',(...args:unknown[])=>errors.push(new Error(args.map(String).join(' '))));
  const dom=await JSDOM.fromFile(fileURLToPath(new URL('../../Applications/WebResources/chat-shell.html',import.meta.url)),{
    runScripts:'dangerously',resources:'usable',pretendToBeVisual:true,virtualConsole,
    beforeParse(window:any){window.scrollTo=()=>{};window.scrollBy=()=>{};}
  });
  const window=dom.window;
  await new Promise<void>((resolve,reject)=>{
    const timer=setTimeout(()=>reject(new Error('Local transcript resources did not load')),10000);
    window.addEventListener('load',()=>{clearTimeout(timer);resolve();},{once:true});
  });
  await window.MathJax.startup.promise;
  return {window,errors,close:()=>dom.window.close(),settle:()=>window.eval('(async()=>{while(mathRendering)await mathRendering;})()')};
}
function transcriptUpdate(text:string){return {conversation:'real',reset:false,order:['body'],upserts:[{id:'body',role:'assistant',text}],removed:[],work:null,turnStatuses:{},focus:null};}

test('real MathJax assistive output preserves current duplicate-word selection, link focus and next streamed source',async()=>{
  const h=await realTranscript(),w=h.window,original=w.MathJax.typesetPromise.bind(w.MathJax);
  let release!:()=>void,started!:()=>void;const gate=new Promise<void>(resolve=>{release=resolve;}),running=new Promise<void>(resolve=>{started=resolve;});
  let calls=0;w.MathJax.typesetPromise=async(nodes:unknown)=>{if(++calls===1){started();await gate;}return original(nodes);};
  try{
    const text='<p>😀 same $x$ same $y$ tail</p><a href="https://example.com">Focus link</a>';
    await w.updateMessages(transcriptUpdate(text));await running;
    const root=w.document.getElementById('messages'),p=root.querySelector('p'),source=p.firstChild,link=root.querySelector('a'),selection=w.getSelection();
    link.focus();const offset=source.data.lastIndexOf('same');selection.setBaseAndExtent(source,offset,source,offset+4);
    release();await h.settle();
    assert.equal(root.querySelector('p'),p);assert.equal(selection.toString(),'same');assert.equal(w.document.activeElement,link);
    assert.equal(root.querySelectorAll('mjx-container').length,2);assert.equal(root.querySelectorAll('mjx-assistive-mml').length,2);
    assert.equal(w.document.querySelectorAll('.math-stage').length,0);assert.equal(Array.from(w.MathJax.startup.document.math).length,0);
    await w.updateMessages(transcriptUpdate(text+' More'));assert.equal(selection.toString(),'same');await h.settle();assert.equal(selection.toString(),'same');
    assert.deepEqual(h.errors,[]);
  }finally{release();h.close();}
});

test('real MathJax maps multi-node UTF-16 source ranges without replacing focused disclosure or selected prose',async()=>{
  const h=await realTranscript(),w=h.window,original=w.MathJax.typesetPromise.bind(w.MathJax);
  let release!:()=>void,started!:()=>void;const gate=new Promise<void>(resolve=>{release=resolve;}),running=new Promise<void>(resolve=>{started=resolve;});
  w.MathJax.typesetPromise=async(nodes:unknown)=>{started();await gate;return original(nodes);};
  try{
    let allowSource!:()=>void;w.MathJax.startup.promise=new Promise<void>(resolve=>{allowSource=resolve;});
    await w.updateMessages(transcriptUpdate('<details open><summary>Focus summary</summary><p>😀 before $x+y$ after</p></details>'));
    const root=w.document.getElementById('messages'),details=root.querySelector('details'),summary=root.querySelector('summary'),p=root.querySelector('p'),s=w.getSelection();
    // Adjacent Text nodes are supported MathJax input; arbitrary intervening
    // HTML elements are intentionally not part of a TeX expression.
    p.firstChild.splitText(p.firstChild.data.indexOf('+'));const tail=p.lastChild;
    allowSource();await running;
    summary.focus();const offset=tail.data.indexOf('after');s.setBaseAndExtent(tail,offset,tail,offset+5);
    release();await h.settle();
    assert.equal(root.querySelector('details'),details);assert.equal(w.document.activeElement,summary);assert.equal(details.open,true);assert.equal(s.toString(),'after');
    assert.equal(p.querySelectorAll('mjx-container').length,1);assert.equal(p.querySelectorAll('mjx-assistive-mml').length,1);
    assert.equal(w.document.querySelectorAll('.math-stage').length,0);assert.deepEqual(h.errors,[]);
  }finally{release();h.close();}
});

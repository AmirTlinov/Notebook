import assert from 'node:assert/strict';
import test from 'node:test';
import {randomUUID} from 'node:crypto';
const {makeRecipe, chartSVG} = await import(new URL('../skills/notebook/scripts/recipes.mjs',import.meta.url).href);
import {sdkInputs} from '../src/sdk-contracts.js';
import {operationSchema} from '../src/actions.js';
import {executionInput} from '../src/server.js';
import {offsetWorld, TILE_SIZE} from '../src/spatial.js';
import {mkdtemp,readFile,rm,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {deflateSync} from 'node:zlib';
import {randomBytes} from 'node:crypto';
const {prepare,loadImage} = await import(new URL('../skills/notebook/scripts/prepare.mjs',import.meta.url).href);
const {animationPreview} = await import(new URL('../skills/notebook/scripts/animation-preview.mjs',import.meta.url).href);

const target={kind:'page',id:randomUUID()};
const tree={id:'root',label:'Вопрос',children:[
  {id:'a',label:'Длинное понятное название первой ветки',children:[{id:'a1',label:'Источник'},{id:'a2',label:'Проверка'}]},
  {id:'b',label:'Другая мысль'},
]};
const AsyncFunction=Object.getPrototypeOf(async function(){}).constructor;

test('mind map has non-overlapping editable nodes, bound edges and stable semantic IDs',()=>{
  const runID=randomUUID(),input={target,tree};
  const request=makeRecipe('mindmap',input,runID);
  assert.deepEqual(makeRecipe('mindmap',input,runID),request);
  executionInput.parse(request);
  const ops=request.args.operations;
  ops.forEach((op:unknown)=>operationSchema.parse(op));
  const nodes=ops.filter((op:any)=>op.values.graphic.shape!=='connector');
  assert.equal(nodes.length,5);assert.equal(ops.length,9);
  for(const a of nodes) for(const b of nodes) if(a!==b) {
    const x=a.values.frame,y=b.values.frame;
    assert.ok(x.x+x.width<=y.x||y.x+y.width<=x.x||x.y+x.height<=y.y||y.y+y.height<=x.y);
  }
  for(const op of ops.filter((op:any)=>op.values.graphic.shape==='connector')) {
    for(const end of ['start','end']) assert.ok(nodes.some((node:any)=>node.id===op.values.graphic.connection[end].binding.elementID));
  }
  assert.equal(request.args.ids.a,nodes.find((node:any)=>node.id===request.args.ids.a).id);
});

test('flow supports joins and back edges; comparison wraps long text',()=>{
  const flow=makeRecipe('flow',{target,nodes:[{id:'a',label:'Начало'},{id:'b',label:'Проверка',shape:'diamond'},{id:'c',label:'Готово'}],
    edges:[{from:'a',to:'b'},{from:'b',to:'c',label:'Да'},{from:'b',to:'a',label:'Нет'}]},randomUUID());
  flow.args.operations.forEach((op:unknown)=>operationSchema.parse(op));
  assert.equal(flow.args.operations.length,6);
  const comparison=makeRecipe('compare',{target,columns:[{title:'A',body:'Очень длинное объяснение '.repeat(20)},{title:'B',body:'Коротко'}]},randomUUID());
  comparison.args.operations.forEach((op:unknown)=>operationSchema.parse(op));
  assert.ok(comparison.args.operations[0].values.frame.height>100);
  assert.throws(()=>makeRecipe('flow',{target,nodes:[{id:'a',label:'A'}],edges:[{from:'a',to:'missing'}]},randomUUID()),/missing/);
});

test('board placement normalizes every element across tile boundaries',()=>{
  const anchor={tileX:-4,tileY:5,localX:TILE_SIZE-10,localY:TILE_SIZE-20};
  const runID=randomUUID(),page=makeRecipe('mindmap',{target,tree},runID);
  const board=makeRecipe('mindmap',{target:{kind:'board',id:target.id},anchor,tree},runID);
  for(let i=0;i<page.args.operations.length;i++) {
    const local=page.args.operations[i].values,world=board.args.operations[i].values;
    assert.deepEqual(world.worldOrigin,offsetWorld(anchor,local.frame.x,local.frame.y));
    operationSchema.parse(board.args.operations[i]);
  }
  assert.throws(()=>makeRecipe('mindmap',{target:{kind:'board',id:target.id},tree},randomUUID()),/anchor/);
});

test('provided basis is used as-is, one transaction, no mandatory readback',async()=>{
  const base={workspaceID:randomUUID(),owners:[{target,revision:'old'}]};
  const request=makeRecipe('mindmap',{target,tree,base},randomUUID());
  const calls:any[]=[],result={actionID:randomUUID(),publication:{saved:'confirmed'}};
  const nb={read:()=>assert.fail('must not refresh supplied basis'),transaction:async(key:string,action:unknown)=>{
    sdkInputs.transaction!.parse({key,action});calls.push(action);return result;
  }};
  const output=await new AsyncFunction('nb','args',request.code)(nb,request.args);
  assert.equal(calls.length,1);assert.deepEqual(calls[0].base,base);assert.deepEqual(output.action,result);
});

test('documents retain chosen order and editable blocks; append does not replace existing content',()=>{
  const document=makeRecipe('document',{target:{kind:'board',id:target.id},anchor:{tileX:0,tileY:0,localX:50,localY:50},
    title:'Исследование',sections:[{id:'finding',heading:'Наблюдение',body:'$x^2$'},{id:'source',body:'[Источник](https://example.org)'}]},randomUUID());
  const op=document.args.operations[0];operationSchema.parse(op);
  assert.equal(op.kind,'createDocument');assert.equal(op.values.blocks.length,3);
  assert.match(op.values.blocks[1].source,/Наблюдение/);
  const append=makeRecipe('document',{target:{kind:'document',id:randomUUID()},afterID:'existing',
    sections:[{id:'new',body:'Продолжение'}]},randomUUID());
  assert.equal(append.args.operations[0].kind,'insertBlock');
  assert.equal(append.args.operations[0].values.afterID,'existing');
});

test('SVG plots use actual data and embed as self-contained sources',()=>{
  const svg=chartSVG({title:'Рост & время',series:[{label:'A',points:[[0,2],[1,4],[2,3]]}]});
  assert.match(svg,/<svg/);assert.match(svg,/Рост &amp; время/);assert.match(svg,/<polyline/);
  assert.throws(()=>chartSVG({series:[{points:[[0,NaN]]}]}),/finite/);
  const visual=makeRecipe('visual',{target,image:{dataURL:'data:image/svg+xml;base64,'+Buffer.from(svg).toString('base64'),width:720,height:420},caption:'Рисунок <1>'},randomUUID());
  const op=visual.args.operations[0];operationSchema.parse(op);
  assert.match(op.values.source,/data:image\/svg\+xml;base64,/);
  assert.match(op.values.source,/Рисунок &lt;1&gt;/);
  assert.doesNotMatch(op.values.source,/file:\/\//);
});

test('pointer is ephemeral and freehand sketch uses native editable ink',()=>{
  const request=makeRecipe('point',{bounds:{origin:{tileX:0,tileY:0,localX:10,localY:20},width:200,height:120}},randomUUID());
  executionInput.parse(request);
  sdkInputs.present!.parse({key:'point',view:{deviceID:randomUUID(),sessionID:randomUUID(),sequence:1,nonce:randomUUID()},steps:request.args.steps});
  const sketch=makeRecipe('sketch',{target,strokes:[{points:[{x:10,y:20},{x:25,y:30},{x:50,y:20}],width:2}]},randomUUID());
  sketch.args.operations.forEach((op:unknown)=>operationSchema.parse(op));
  assert.equal(sketch.args.operations[0].kind,'appendInkStroke');
});

test('image and Markdown source files become self-contained input, not paths',async()=>{
  const directory=await mkdtemp(join(tmpdir(),'notebook-recipe-files-'));
  try {
    const svg=chartSVG({series:[{points:[[1,2],[3,4]]}]});
    await writeFile(join(directory,'figure.svg'),svg);
    await writeFile(join(directory,'section.md'),'Содержательный **вывод**.');
    const image=await prepare('visual',{target,imagePath:'figure.svg'},{baseDirectory:directory});
    assert.match(image.args.operations[0].values.source,/data:image\/svg\+xml;base64,/);
    assert.doesNotMatch(JSON.stringify(image),/figure\.svg|notebook-recipe-files/);
    const doc=await prepare('document',{target:{kind:'document',id:randomUUID()},sections:[{sourcePath:'section.md'}]},{baseDirectory:directory});
    assert.equal(doc.args.operations[0].values.source,'Содержательный **вывод**.');
  } finally {await rm(directory,{recursive:true,force:true});}
});

async function waveInput() {
  const directory=new URL('../skills/notebook/assets/animation/',import.meta.url);
  return {html:await readFile(new URL('wave.html',directory),'utf8'),css:await readFile(new URL('wave.css',directory),'utf8'),
    javaScript:await readFile(new URL('wave.js',directory),'utf8'),initialState:{phase:0,amplitude:1,speed:1}};
}
test('animation uses the existing web/interactive owners with embedded code and state',async()=>{
  const program=await waveInput(),runID=randomUUID();
  for(const kind of ['page','board','document']) {
    const input={...program,target:{...target,kind},anchor:{tileX:0,tileY:0,localX:20,localY:30},afterID:'previous'};
    const request=makeRecipe('animation',input,runID);
    assert.deepEqual(makeRecipe('animation',input,runID),request);
    executionInput.parse(request);
    const op=request.args.operations[0];operationSchema.parse(op);
    assert.equal(op.kind,kind==='document'?'insertBlock':'insertElement');
    assert.equal(op.values.kind,kind==='document'?'interactive':'web');
    assert.equal(op.values.html,program.html);assert.equal(op.values.javaScript,program.javaScript);
    assert.deepEqual(op.values.initialState??op.values.state,program.initialState);
    if(kind==='document') assert.equal(op.values.afterID,'previous');
    assert.ok(animationPreview(request).includes(program.html));
  }
  assert.throws(()=>makeRecipe('animation',{target,...program,html:''}),/fragment/);
  assert.throws(()=>makeRecipe('animation',{target:{...target,kind:'document'},...program,height:2049}),/48–2048/);
});

test('animation file preparation embeds sources; preview cannot close its script with program data',async()=>{
  const directory=await mkdtemp(join(tmpdir(),'notebook-animation-'));
  try {
    await writeFile(join(directory,'scene.html'),'<svg viewBox="0 0 100 100"></svg>');
    await writeFile(join(directory,'scene.js'),'notebook.ready(Promise.resolve()); // </script><script>bad()</script>');
    const input={target,htmlPath:'scene.html',javaScriptPath:'scene.js',initialState:{label:'</script>'}};
    const request=await prepare('animation',input,{baseDirectory:directory});
    assert.doesNotMatch(JSON.stringify(request),/scene\.html|scene\.js|notebook-animation-/);
    assert.doesNotMatch(animationPreview(request),/<script>bad\(\)/);
    assert.match(animationPreview(request),/connect-src 'none'/);
    await assert.rejects(prepare('animation',{...input,html:'ambiguous'},{baseDirectory:directory}),/not both/);
  } finally {await rm(directory,{recursive:true,force:true});}
});

test('wave controls render analytic phases, keep frames local and restore shared state paused',async()=>{
  const {javaScript}=await waveInput();
  const elements=new Map<string,any>(),events=new Map<string,Function>(),frames=new Map<number,Function>();
  let sequence=0,ready:Promise<unknown>|undefined,state:any={phase:0,amplitude:1,speed:1};
  const commits:any[]=[];let lifecycle:any;
  const document={hidden:false,getElementById:(id:string)=>{
    if(!elements.has(id)) elements.set(id,{attributes:{},listeners:{},value:'',textContent:'',
      setAttribute(key:string,value:unknown){this.attributes[key]=value},
      addEventListener(key:string,fn:Function){this.listeners[key]=fn}});
    return elements.get(id);
  },addEventListener:(key:string,fn:Function)=>events.set(key,fn)};
  const notebook={lifecycle:(hooks:any)=>{lifecycle=hooks},get state(){return state},commit:(next:any)=>{state=next;commits.push(next)},ready:(p:Promise<unknown>)=>ready=p};
  new Function('document','notebook','requestAnimationFrame','cancelAnimationFrame','addEventListener',javaScript)(document,notebook,
    (fn:Function)=>{frames.set(++sequence,fn);return sequence},(id:number)=>frames.delete(id),(key:string,fn:Function)=>events.set(key,fn));
  await ready;
  const click=(id:string)=>elements.get(id).listeners.click();
  const point=()=>Number(elements.get('particle').attributes.cy);
  assert.ok(Math.abs(point()-150)<1e-9);
  click('forward');assert.ok(Math.abs(point()-212)<1e-9);assert.equal(state.phase,0.25);
  click('back');assert.ok(Math.abs(point()-150)<1e-9);
  const count=commits.length;
  click('play');
  const tick=(now:number)=>{const [id,fn]=[...frames][0]!;frames.delete(id);fn(now)};
  tick(0);tick(1000);assert.ok(Math.abs(point()-212)<1e-9);
  assert.equal(commits.length,count);
  click('play');assert.equal(frames.size,0);assert.equal(commits.length,count+1);assert.equal(state.phase,0.25);
  click('play');state={phase:0.75,amplitude:0.5,speed:2};events.get('notebookstate')!();
  assert.equal(frames.size,0);assert.equal(elements.get('play').textContent,'Пуск');
  assert.ok(Math.abs(point()-119)<1e-9);
  state={phase:0.25,amplitude:0,speed:1};events.get('notebookstate')!();assert.equal(point(),150);
  click('play');tick(0);tick(500);lifecycle.pause();
  assert.equal(frames.size,0);assert.equal(lifecycle.checkpoint().phase,0.375);
  lifecycle.dispose();assert.equal(frames.size,0);
});

function png(width:number,height:number):Buffer {
  function crc32(bytes:Buffer) {let crc=0xffffffff;for(const b of bytes){crc^=b;for(let i=0;i<8;i++)crc=(crc>>>1)^((crc&1)?0xedb88320:0);}return (crc^0xffffffff)>>>0;}
  function chunk(type:string,data:Buffer) {const body=Buffer.concat([Buffer.from(type),data]),head=Buffer.alloc(4),tail=Buffer.alloc(4);head.writeUInt32BE(data.length);tail.writeUInt32BE(crc32(body));return Buffer.concat([head,body,tail]);}
  const header=Buffer.alloc(13);header.writeUInt32BE(width);header.writeUInt32BE(height,4);header[8]=8;header[9]=6;
  const rows=[];for(let y=0;y<height;y++)rows.push(Buffer.from([0]),randomBytes(width*4));
  return Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]),chunk('IHDR',header),chunk('IDAT',deflateSync(Buffer.concat(rows))),chunk('IEND',Buffer.alloc(0))]);
}
test('large raster gets an explicit fitting copy, original and PNG alpha preserved',async()=>{
  const directory=await mkdtemp(join(tmpdir(),'notebook-recipe-image-'));
  try {
    const original=png(720,720),path=join(directory,'source.png'),copy=join(directory,'fit.png');
    await writeFile(path,original);
    await assert.rejects(loadImage(path),/too large/);
    const image=await loadImage(path,{fit:true,outputPath:copy});
    assert.deepEqual(await readFile(path),original);
    const bytes=Buffer.from(image.dataURL.split(',')[1],'base64');
    assert.ok(bytes.length<=700_000);assert.equal(bytes[25],6);assert.ok(image.width<720);
    executionInput.parse(makeRecipe('visual',{target,image},randomUUID()));
  } finally {await rm(directory,{recursive:true,force:true});}
});

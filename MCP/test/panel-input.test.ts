import assert from 'node:assert/strict';
import test from 'node:test';
import {randomUUID} from 'node:crypto';
import {readFileSync} from 'node:fs';
import {createContext, runInContext} from 'node:vm';
import {transformSync} from 'esbuild';
import {NotebookSession,PanelError} from '../panel/session.js';
import {InkInput} from '../panel/ink-input.js';
import {InkGPU} from '../panel/ink-gpu.js';
import type {SwiftSurface} from '../panel/swift-surface.js';
import type {PanelMutation, PanelSnapshot} from '../panel/model.js';

// Execute the shipped controller listeners against the real session. DOM,
// geometry and GPU ports are bounded fixtures, not browser/Swift/host evidence.
const source=readFileSync(new URL('../panel/panel.ts',import.meta.url),'utf8');
function section(start:string,end:string){
  const first=source.indexOf(start),last=source.indexOf(end,first);
  assert.ok(first>=0&&last>first,`Missing controller section: ${start}`);
  return source.slice(first,last);
}
const listeners=transformSync([
  section('function active(){','function activeCard(){'),
  section('async function save(request:PanelMutation){','session.bounds='),
  section('function newElement(','paper.addEventListener("pointerdown"'),
  section('paper.addEventListener("pointerdown"','async function openCard('),
  section('paper.addEventListener("dblclick"','paper.addEventListener("wheel"'),
  section('async function remove(){','el("delete").addEventListener'),
  section('const handleShortcut=','window.addEventListener("keyup"'),
].join('\n'),{loader:'ts',target:'es2022'}).code;
const turn=()=>new Promise<void>(resolve=>setImmediate(resolve));

async function fixture(){
  const id=randomUUID(),actionID=randomUUID(),target={kind:'board' as const,id:randomUUID()};
  const snapshot:PanelSnapshot={workspaceID:id,socketKey:'0123456789abcdef01234567',target,cursor:'1',
    checkpoint:{id:randomUUID(),epoch:randomUUID(),readCursor:'1',changeCursor:'1'},
    worldOrigin:{tileX:0,tileY:0,localX:0,localY:0},size:{width:800,height:600},cards:[],
    elements:[{source:{id:'text',kind:'nativeText',source:'Before',frame:{x:100,y:100,width:100,height:80}}}],
    rawInkPresent:false,unsupportedElements:[],history:{undoActionID:actionID},truncated:false,
    appearance:{status:'ready',requestID:randomUUID(),sourceRevision:'1',
      camera:{center:{tileX:0,tileY:0,localX:400,localY:300},scale:1},viewport:{x:800,y:600},layers:[]}};
  const calls:{name:string;arguments:Record<string,unknown>}[]=[];
  const writes:{resolve:(value:Awaited<ReturnType<NotebookSession['app']['callServerTool']>>)=>void}[]=[];
  const session=new NotebookSession();session.snapshot=snapshot;
  session.app.updateModelContext=async()=>({});
  session.app.callServerTool=async request=>{
    calls.push({name:request.name,arguments:request.arguments!});
    if(request.name==='notebook_panel_presentation')return {content:[],structuredContent:snapshot};
    return new Promise(resolve=>writes.push({resolve}));
  };
  session.needsPresentation=()=>false;
  await session.refresh(true);calls.length=0;
  const paperListeners=new Map<string,(event:unknown)=>void>(),keyListeners=new Map<string,(event:unknown)=>void>(),
    editorListeners=new Map<string,(event:unknown)=>void>(),controlListeners=new Map<string,(event:unknown)=>void>();
  const captures=new Set<number>();
  let previews=0,clears=0,inkClears=0;
  const ink={pointer:undefined as number|undefined,hasPreview:false,ready:true,
    begin(event:{pointerId:number}){this.pointer=event.pointerId;this.hasPreview=true;return true;},
    append(){},finish(){this.pointer=undefined;return {points:[{x:1,y:1,force:1}],worldOrigin:snapshot.worldOrigin};},
    clear(){this.pointer=undefined;this.hasPreview=false;inkClears++;}};
  const elementHit={getAttribute:()=> 'text'};
  const hit={hasAttribute:()=>false,closest:(selector:string)=>selector==='[data-element-id]'?elementHit:null};
  const blank={hasAttribute:()=>false,closest:()=>null};
  const surface={point:(x:number,y:number)=>({x,y}),selectionFrame:()=>snapshot.elements[0]!.source.frame,
    authoredFrame:()=>snapshot.elements[0]!.source.frame,
    preview(){previews++;},clearPreview(){clears++;},select(){},hideSubject(){}};
  const editor={value:'',hidden:true,style:{},scrollHeight:80,focus(){},select(){},
    addEventListener:(name:string,callback:(event:unknown)=>void)=>editorListeners.set(name,callback)};
  const context=createContext({session,ink,surface,PanelError,crypto:{randomUUID},events:{},
    document:{createElementNS:(_namespace:string,tagName:string)=>({tagName,setAttribute(){}})},
    selection:{replaceChildren(){},append(){}},
    paper:{addEventListener:(name:string,callback:(event:unknown)=>void)=>paperListeners.set(name,callback),
      ownerDocument:{elementFromPoint:()=>hit},
      setPointerCapture:(pointer:number)=>captures.add(pointer),hasPointerCapture:(pointer:number)=>captures.has(pointer),
      releasePointerCapture:(pointer:number)=>captures.delete(pointer),getBoundingClientRect:()=>({left:0,top:0})},
    workspace:{clientWidth:800,clientHeight:600,
      addEventListener:(name:string,callback:(event:unknown)=>void)=>keyListeners.set(name,callback),focus(){}},
    controls:{addEventListener:(name:string,callback:(event:unknown)=>void)=>controlListeners.set(name,callback)},
    gesture:null,draft:null,selected:{kind:'element',id:'text'},tool:'select',space:false,closed:false,editor,
    camera:{x:0,y:0,scale:1},worldCamera:snapshot.appearance!.camera,viewport:()=>({x:800,y:600}),
    geometry:{manipulateFrame:(_mode:string,frame:{x:number;y:number},delta:{x:number;y:number})=>
      ({...frame,x:frame.x+delta.x,y:frame.y+delta.y}),offset:(origin:object,x:number,y:number)=>({...origin,localX:x,localY:y})},
    choose(value:unknown){context.selected=value;},buttons(){},toolButtons(){},
    canMove:()=>true,canEdit:()=>true,canMoveCard:()=>true,activeCard:()=>undefined,
    setCamera(){},openCard(){},
    operation:(kind:string,elementID:string,values:Record<string,unknown>)=>({kind,target,id:elementID,values}),
    mutation:(summary:string,operation:PanelMutation['operations'][number])=>
      ({...session.address(),actionID:randomUUID(),summary,operations:[operation],sources:operation.kind==='appendInkStroke'?[]:[{id:operation.id}]}),
  });
  runInContext(listeners,context);
  const dispatch=async(name:string,event:unknown)=>{
    paperListeners.get(name)?.(event);
    await turn();
  };
  const pointer=(name:string,id=1,x=100)=>dispatch(name,
    {pointerId:id,clientX:x,clientY:100,button:0,altKey:false,
      target:context.tool==='pen'?blank:hit,preventDefault(){}});
  const key=async(value:string,control=false,fromControls=false)=>{
    let prevented=false;
    (fromControls?controlListeners:keyListeners).get('keydown')?.({key:value,code:value===' '?'Space':value,isComposing:false,
      metaKey:false,ctrlKey:control,shiftKey:false,altKey:false,target:blank,
      currentTarget:fromControls?context.controls:context.workspace,preventDefault(){prevented=true;}});
    await turn();
    return prevented;
  };
  const editorKey=async(value:string,control=false)=>{
    editorListeners.get('keydown')?.({key:value,isComposing:false,metaKey:false,ctrlKey:control,preventDefault(){}});
    await turn();
  };
  return {session,snapshot,context,calls,writes,ink,captures,pointer,dispatch,key,editor,editorKey,
    counts:()=>({previews,clears,inkClears}),complete:async()=>{
      for(const write of writes.splice(0))write.resolve({content:[],structuredContent:{status:'saved'}});
      await turn();
    }};
}

test('tool controls retain the board shortcuts without an extra focus click',async()=>{
  const f=await fixture();
  await f.key('p',false,true);assert.equal(f.context.tool,'pen');
  await f.key('v',false,true);assert.equal(f.context.tool,'select');
  await f.key('z',true,true);assert.equal(f.calls.at(-1)!.name,'notebook_panel_undo');
  await f.complete();
});

test('Enter and Space on controls preserve native button activation',async()=>{
  const f=await fixture();
  for(const key of ['Enter',' ']){
    assert.equal(await f.key(key,false,true),false,'The button still receives its native activation');
    assert.equal(f.context.draft,null);assert.equal(f.editor.hidden,true);
    assert.equal(f.context.space,false);assert.equal(f.writes.length,0);
  }
});

test('a completed shape save preserves the next tool chosen while saving',async()=>{
  const f=await fixture();f.context.tool='rectangle';
  await f.pointer('pointerdown');await f.pointer('pointermove',1,140);await f.pointer('pointerup',1,140);
  assert.equal(f.writes.length,1);assert.equal(f.context.tool,'select');
  const operation=(f.calls.at(-1)!.arguments.operations as PanelMutation['operations'])[0]!;
  assert.equal(operation.kind,'insertElement');
  assert.equal((operation.values.graphic as {shape:string}).shape,'rectangle');
  await f.key('p',false,true);assert.equal(f.context.tool,'pen');
  await f.complete();assert.equal(f.context.tool,'pen');
});

test('keyboard undo and delete cannot admit another action during a dragged contact',async t=>{
  for(const key of ['z','Delete'])await t.test(key,async()=>{
    const f=await fixture();await f.pointer('pointerdown');await f.pointer('pointermove',1,140);
    assert.equal(f.session.suspended,true);
    const before=f.counts();
    await f.key(key,key==='z');
    try{
      assert.equal(f.writes.length,0,`${key} cannot interrupt the gesture's mutation boundary`);
      assert.deepEqual(f.counts(),before,`${key} cannot remove the active gesture's preview`);
    }
    finally{await f.complete();}
    await f.pointer('pointerup',1,140);
    assert.equal(f.writes.length,1,'The completed movement still saves once');
    assert.equal(f.calls.at(-1)!.name,'notebook_panel_edit');
    await f.complete();
  });
});

test('Enter and double-click cannot open a nested editor or release the current contact',async t=>{
  for(const tool of ['select','pen'])for(const trigger of ['Enter','dblclick'])await t.test(`${tool}: ${trigger}`,async()=>{
    const f=await fixture();f.context.tool=tool;
    await f.pointer('pointerdown');await f.pointer('pointermove',1,140);
    if(trigger==='Enter')await f.key('Enter');else await f.pointer('dblclick',1,140);
    await f.editorKey('Escape');await f.key('z',true);
    try{
      assert.equal(f.writes.length,0,'Editor dismissal cannot admit undo while the original contact survives');
      assert.equal(f.session.suspended,true);assert.equal(f.editor.hidden,true);assert.equal(f.context.draft,null);
      assert.equal(tool==='pen'?f.ink.pointer:f.context.gesture.pointer,1);
    }finally{await f.complete();}
    await f.pointer('pointerup',1,140);assert.equal(f.writes.length,1);
    await f.complete();
  });
});

test('an idle editor still opens, cancels and saves one completed edit',async()=>{
  const f=await fixture();await f.key('Enter');
  assert.ok(f.context.draft);assert.equal(f.editor.hidden,false);
  await f.editorKey('Escape');assert.equal(f.context.draft,null);assert.equal(f.writes.length,0);
  await f.pointer('dblclick');assert.ok(f.context.draft);f.editor.value='After';
  await f.editorKey('Enter',true);assert.equal(f.writes.length,1);
  assert.equal(f.calls.at(-1)!.name,'notebook_panel_edit');
  assert.equal((f.calls.at(-1)!.arguments.operations as PanelMutation['operations'])[0]!.values.source,'After');
  await f.complete();assert.equal(f.context.draft,null);assert.equal(f.editor.hidden,true);
  assert.equal(f.session.mutationReady,true);
});

test('the text tool still admits and saves a new element',async()=>{
  const f=await fixture();f.context.tool='text';await f.pointer('pointerdown');
  assert.equal(f.context.draft?.isNew,true);assert.equal(f.editor.hidden,false);
  f.editor.value='New text';await f.editorKey('Enter',true);assert.equal(f.writes.length,1);
  const operation=(f.calls.at(-1)!.arguments.operations as PanelMutation['operations'])[0]!;
  assert.equal(operation.kind,'insertElement');assert.equal(operation.values.source,'New text');
  await f.complete();assert.equal(f.context.draft,null);assert.equal(f.editor.hidden,true);
  assert.equal(f.session.mutationReady,true);
});

test('lost pointer capture cancels the unfinished preview and resumes the same projection',async t=>{
  for(const tool of ['select','pen'])await t.test(tool,async()=>{
    const f=await fixture();f.context.tool=tool;
    await f.pointer('pointerdown');await f.pointer('pointermove',1,140);
    const view={viewport:{x:900,y:700},pixelScale:2,
      camera:{center:{tileX:0,tileY:0,localX:500,localY:350},scale:1.5}};
    f.session.view=()=>view;f.session.needsPresentation=()=>true;f.session.viewportChanged();
    f.captures.delete(1);await f.pointer('lostpointercapture');
    assert.equal(f.session.suspended,false,`${tool} cannot retain input after capture is stolen`);
    assert.equal(f.context.gesture,null);assert.equal(f.ink.hasPreview,false);
    assert.equal(f.writes.length,0,'Cancellation is never a saved action');
    assert.equal(f.calls.at(-1)!.name,'notebook_panel_presentation');
    assert.deepEqual(f.calls.at(-1)!.arguments.target,f.snapshot.target);
    assert.deepEqual(f.calls.at(-1)!.arguments.appearance,view,'Cancellation drains the latest projection demand');
    assert.ok(tool==='pen'?f.counts().inkClears>0:f.counts().clears>0);
    await f.pointer('pointerdown',2);await f.pointer('pointermove',2,150);
    await f.pointer('pointerup',2,150);assert.equal(f.writes.length,1,'The next contact is immediately available');
    await f.complete();
  });
});

test('Escape still cancels an unfinished contact without admitting a competing write',async t=>{
  for(const tool of ['select','pen'])await t.test(tool,async()=>{
    const f=await fixture();f.context.tool=tool;
    await f.pointer('pointerdown');await f.pointer('pointermove',1,140);
    await f.key('Escape');
    assert.equal(f.session.suspended,false);assert.equal(f.session.mutationReady,true);
    assert.equal(f.context.gesture,null);assert.equal(f.ink.hasPreview,false);assert.equal(f.captures.size,0);
    assert.equal(f.writes.length,0);assert.equal(f.context.tool,'select');
    await f.pointer('lostpointercapture');await f.pointer('pointerup',1,140);
    assert.equal(f.writes.length,0,'Trailing terminal events cannot save cancelled input');
  });
});

test('late lost-capture events preserve a completed ink contact and a newer pointer',async t=>{
  for(const tool of ['select','pen'])for(const nextPointer of [1,2])await t.test(`${tool}: pointer ${nextPointer}`,async()=>{
    const f=await fixture();f.context.tool=tool;
    await f.pointer('pointerdown');await f.pointer('pointermove',1,140);await f.pointer('pointerup',1,140);
    const cleared=f.counts().inkClears;
    assert.equal(f.writes.length,1);
    await f.pointer('lostpointercapture');
    assert.equal(f.writes.length,1,'Normal release cannot cancel or repeat its accepted write');
    if(tool==='pen'){assert.equal(f.ink.hasPreview,true);assert.equal(f.counts().inkClears,cleared);}
    await f.complete();
    // The real snapshot callback drops a sealed preview only after presentation.
    if(tool==='pen')f.ink.clear();
    await f.pointer('pointerdown',nextPointer);await f.pointer('lostpointercapture',1);
    assert.equal(f.captures.has(nextPointer),true);
    assert.equal(tool==='pen'?f.ink.pointer:f.context.gesture.pointer,nextPointer);
    await f.pointer('pointerup',nextPointer,150);assert.equal(f.writes.length,1);
    await f.complete();
  });
});

test('real pen input retains measured samples through completion and discards only cancelled contact',async t=>{
  // Retention and command admission run through production InkInput. These
  // geometry/GPU ports deliberately do not claim Swift parity or rendering.
  const gpu={setNodes(){},resize(){},draw(){},dispose(){}} as unknown as InkGPU;
  t.mock.method(InkGPU,'create',async()=>gpu);
  const geometry={delta:()=>({x:0,y:0}),
    penSample:(force:number)=>({width:2,opacity:1,filteredForce:force,color:{red:0,green:0,blue:0}}),
    inkContact:()=>({update(){return {};},snapshot(){return {};},dispose(){}})} as unknown as SwiftSurface;
  const f=await fixture();f.context.tool='pen';
  const errors:Error[]=[],lifetime=new AbortController();t.after(()=>lifetime.abort());
  const input=new InkInput({hidden:true} as HTMLCanvasElement,()=>geometry,
    ()=>({camera:f.snapshot.appearance!.camera,viewport:{x:800,y:600},pixelScale:1}),
    lifetime.signal,()=>{},error=>errors.push(error));
  await turn();assert.equal(input.ready,true);f.context.ink=input;
  f.session.onSnapshot=()=>input.presented();
  const sample=(time:number,force:number)=>({pointerId:1,timeStamp:time,pointerType:'pen',pressure:force,
    clientX:100+time,clientY:100,azimuthAngle:time/100,altitudeAngle:0.8,button:0,altKey:false,
    target:{hasAttribute:()=>false,closest:()=>null},preventDefault(){}});
  await f.dispatch('pointerdown',sample(10,.2));
  await f.dispatch('pointermove',{...sample(40,.5),getCoalescedEvents:()=>[sample(20,.3),sample(30,.4)],
    getPredictedEvents:()=>[sample(60,.9)]});
  await f.dispatch('pointerup',sample(50,.6));
  assert.deepEqual(errors,[]);assert.equal(f.writes.length,1);
  assert.equal(input.pointer,undefined);assert.equal(input.hasPreview,true);
  const request=f.calls.at(-1)!.arguments;
  const operation=(request.operations as PanelMutation['operations'])[0]!;
  const points=operation.values.points as {force:number;timeOffset:number;azimuth:number;altitude:number}[];
  assert.equal(operation.kind,'appendInkStroke');assert.deepEqual(request.sources,[]);
  assert.deepEqual(points.map(point=>point.force),[.2,.3,.4,.5,.6]);
  assert.deepEqual(points.map(point=>point.timeOffset),[0,.01,.02,.03,.04]);
  assert.deepEqual(points.map(point=>point.azimuth),[.1,.2,.3,.4,.5]);
  assert.ok(points.every(point=>point.altitude===.8));
  await f.dispatch('lostpointercapture',sample(50,.6));
  assert.equal(input.hasPreview,true);assert.equal(f.writes.length,1);
  assert.equal(f.calls.at(-1)!.arguments,request,'Normal release preserves the one admitted command');
  assert.equal(points.length,5,'Predicted samples never enter the saved contact');
  await f.complete();assert.equal(input.hasPreview,false);
  await f.dispatch('pointerdown',sample(100,.3));
  await f.dispatch('lostpointercapture',sample(50,.6));
  assert.equal(input.pointer,1,'A captured reused pointer ID survives an old loss event');
  await f.dispatch('pointerup',sample(110,.4));assert.equal(f.writes.length,1);await f.complete();
  await f.dispatch('pointerdown',sample(200,.5));f.captures.delete(1);
  await f.dispatch('lostpointercapture',sample(210,.5));
  assert.equal(input.hasPreview,false);assert.equal(f.session.suspended,false);assert.equal(f.writes.length,0);
  await f.dispatch('pointerup',sample(220,.6));
  assert.equal(f.writes.length,0,'Trailing up cannot save cancelled measurements');
});

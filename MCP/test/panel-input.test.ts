import {panelIdentity} from './panel-fixture.js';
import assert from 'node:assert/strict';
import test from 'node:test';
import {randomUUID} from 'node:crypto';
import {readFileSync} from 'node:fs';
import {createContext, runInContext} from 'node:vm';
import {transformSync} from 'esbuild';
import {NotebookSession,PanelError} from '../panel/session.js';
import {InkInput} from '../panel/ink-input.js';
import {InkGPU} from '../panel/ink-gpu.js';
import {editable} from '../panel/surface.js';
import {admitPanelCamera,panelCoordinateScale,transformPanelCamera} from '../panel/projection.js';
import type {SwiftSurface,SurfaceCamera,SurfacePoint} from '../panel/swift-surface.js';
import {capturedSource,type PanelMutation,type PanelSnapshot} from '../panel/model.js';

// Execute the shipped controller listeners against the real session. DOM,
// geometry and GPU ports are bounded fixtures, not browser/Swift/host evidence.
const source=readFileSync(new URL('../panel/panel.ts',import.meta.url),'utf8');
function section(start:string,end:string){
  const first=source.indexOf(start),last=source.indexOf(end,first);
  assert.ok(first>=0&&last>first,`Missing controller section: ${start}`);
  return source.slice(first,last);
}
const listeners=transformSync([
  section('const camera:Camera={','let selected:PanelSelection'),
  section('const worldDelta=','function choose('),
  section('function active(){','function buttons(){'),
  section('function buttons(){','function cameraScaleBounds(){'),
  section('function cameraScaleBounds(){','function mutation('),
  section('function mutation(','async function save(request:PanelMutation){'),
  section('async function save(request:PanelMutation){','session.bounds='),
  section('session.onClose=()=>{','let first=true;'),
  section('function newElement(','paper.addEventListener("pointerdown"'),
  section('paper.addEventListener("pointerdown"','async function openCard('),
  section('paper.addEventListener("dblclick"','function toolButtons(){'),
  section('function toolButtons(){','async function remove(){'),
  section('async function remove(){','el("delete").addEventListener'),
  section('const handleShortcut=','window.addEventListener("keyup"'),
  section('const resizeObserver=','function observeDisplayScale(){'),
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
  const session=new NotebookSession(panelIdentity);session.snapshot=snapshot;
  let retry:(()=>Promise<void>)|null=null;
  session.onError=(_message,action)=>{retry=action;};
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
  let editorFocused=false;
  const blurFocusedEditor=()=>{if(editorFocused){editorFocused=false;editorListeners.get('blur')?.({});}};
  const captures=new Set<number>();
  let previews=0,clears=0,inkClears=0,editorFocus=0,workspaceFocus=0,disposals=0,geometryDisposals=0,cameraPublications=0,inkDraws=0;
  let resize:()=>void=()=>{throw new Error('ResizeObserver was not installed');};
  const ink={pointer:undefined as number|undefined,hasPreview:false,ready:true,
    begin(event:{pointerId:number}){this.pointer=event.pointerId;this.hasPreview=true;return true;},
    append(){},finish(){this.pointer=undefined;return {points:[{x:1,y:1,force:1}],worldOrigin:snapshot.worldOrigin};},
    clear(){this.pointer=undefined;this.hasPreview=false;inkClears++;},draw(){inkDraws++;}};
  const elementHit={getAttribute:()=> 'text'};
  const hit={hasAttribute:()=>false,closest:(selector:string)=>selector==='[data-element-id]'?elementHit:null};
  const resizeHit={...hit,hasAttribute:(name:string)=>name==='data-resize-handle'};
  const blank={hasAttribute:()=>false,closest:()=>null};
  const surface={point:(x:number,y:number)=>({x,y}),selectionFrame:()=>snapshot.elements[0]!.source.frame,
    authoredFrame:()=>snapshot.elements[0]!.source.frame,
    hasSubject:()=>true,hasItemSubject:()=>true,setCamera(){cameraPublications++;},
    preview(){previews++;},previewSize(){previews++;},clearPreview(){clears++;},select(){},hideSubject(){},dispose:async()=>{disposals++;}};
  const editor={value:'',hidden:true,readOnly:false,style:{},scrollHeight:80,focus(){editorFocused=true;editorFocus++;},select(){},
    addEventListener:(name:string,callback:(event:unknown)=>void)=>editorListeners.set(name,callback)};
  type ToolEvent={button:number;preventDefault:()=>void};
  type ToolControl={dataset:{tool:string};disabled:boolean;pressed:string;listeners:Map<string,(event:ToolEvent)=>void>;
    focus:()=>void;setAttribute:(name:string,value:string)=>void;addEventListener:(name:string,callback:(event:ToolEvent)=>void)=>void};
  const toolControls=new Map(['select','hand','pen','text','rectangle','ellipse','connector'].map((tool):[string,ToolControl]=>[tool,
    {dataset:{tool},disabled:false,pressed:tool==='select'?'true':'false',listeners:new Map(),
      focus(){blurFocusedEditor();},
      setAttribute(name:string,value:string){if(name==='aria-pressed')this.pressed=value;},
      addEventListener(name:string,callback:(event:ToolEvent)=>void){this.listeners.set(name,callback);}}]));
  const otherControls=new Map<string,{disabled:boolean;hidden:boolean;textContent:string}>();
  const context=createContext({session,ink,surface,PanelError,capturedSource,editable,
    admitPanelCamera,panelCoordinateScale,transformPanelCamera,crypto:{randomUUID},events:{},
    document:{createElementNS:(_namespace:string,tagName:string)=>({tagName,setAttribute(){}}),
      querySelectorAll:()=>[...toolControls.values()]},
    el(id:string){if(!otherControls.has(id))otherControls.set(id,{disabled:false,hidden:false,textContent:''});return otherControls.get(id);},
    selection:{replaceChildren(){},append(){}},
    paper:{addEventListener:(name:string,callback:(event:unknown)=>void)=>paperListeners.set(name,callback),
      ownerDocument:{elementFromPoint:()=>hit},
      setPointerCapture:(pointer:number)=>captures.add(pointer),hasPointerCapture:(pointer:number)=>captures.has(pointer),
      releasePointerCapture:(pointer:number)=>captures.delete(pointer),getBoundingClientRect:()=>({left:0,top:0})},
    workspace:{clientWidth:800,clientHeight:600,dataset:{},
      addEventListener:(name:string,callback:(event:unknown)=>void)=>keyListeners.set(name,callback),focus(){blurFocusedEditor();workspaceFocus++;}},
    controls:{addEventListener:(name:string,callback:(event:unknown)=>void)=>controlListeners.set(name,callback)},
    gesture:null,draft:null,editorFinish:null,toolIntent:0,selected:{kind:'element',id:'text'},tool:'select',space:false,closed:false,editor,
    path:[],geometryLoaded:true,lifetime:new AbortController(),worldCamera:snapshot.appearance!.camera,
    ResizeObserver:class{constructor(callback:()=>void){resize=callback;}observe(){}disconnect(){}},
    geometry:{minimumScale:.0125,maximumScale:4,dispose(){geometryDisposals++;},
      camera:(camera:SurfaceCamera,_viewport:SurfacePoint,from:SurfacePoint,to:SurfacePoint,magnification:number)=>
        ({center:{...camera.center,localX:camera.center.localX+(from.x-to.x)/camera.scale,
          localY:camera.center.localY+(from.y-to.y)/camera.scale},scale:camera.scale*magnification}),
      delta:(origin:SurfaceCamera['center'],destination:SurfaceCamera['center'])=>
        ({x:destination.localX-origin.localX,y:destination.localY-origin.localY}),
      manipulateFrame:(_mode:string,frame:{x:number;y:number},delta:{x:number;y:number})=>
        ({...frame,x:frame.x+delta.x,y:frame.y+delta.y}),
      offset:(origin:SurfaceCamera['center'],x:number,y:number)=>({...origin,localX:origin.localX+x,localY:origin.localY+y})},
    choose(value:unknown){context.selected=value;context.buttons();},
    openCard(){},
    operation:(kind:string,elementID:string,values:Record<string,unknown>)=>({kind,target,id:elementID,values}),
  });
  runInContext(listeners,context);
  session.onStateChange=()=>context.buttons();context.buttons();
  const dispatch=async(name:string,event:unknown)=>{
    paperListeners.get(name)?.(event);
    await turn();
  };
  const pointer=(name:string,id=1,x=100,resizing=false)=>dispatch(name,
    {pointerId:id,clientX:x,clientY:100,button:0,altKey:false,
      target:resizing?resizeHit:context.tool==='pen'?blank:hit,preventDefault(){}});
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
  const activateTool=async(tool:string)=>{
    const button=toolControls.get(tool)!;if(button.disabled)return false;
    button.listeners.get('click')?.({button:0,preventDefault(){}});await turn();return true;
  };
  const pressTool=async(tool:string)=>{
    const button=toolControls.get(tool)!;if(button.disabled)return false;
    let prevented=false;
    button.listeners.get('pointerdown')?.({button:0,preventDefault(){prevented=true;}});
    if(!prevented)button.focus();
    await turn();return prevented;
  };
  const clickTool=async(tool:string)=>{if(toolControls.get(tool)!.disabled)return false;await pressTool(tool);return activateTool(tool);};
  const blurEditor=async()=>{blurFocusedEditor();await turn();};
  const close=async()=>{
    session.app.connect=async()=>{};await session.connect();
    await session.app.onteardown!({},{} as never);await turn();
  };
  return {session,snapshot,context,calls,writes,ink,captures,pointer,dispatch,key,editor,editorKey,clickTool,pressTool,activateTool,blurEditor,toolControls,otherControls,close,retry:()=>retry,
    resize:()=>resize(),counts:()=>({previews,clears,inkClears,editorFocus,workspaceFocus,disposals,geometryDisposals,cameraPublications,inkDraws}),complete:async()=>{
      for(const write of writes.splice(0))write.resolve({content:[],structuredContent:{status:'saved'}});
      await turn();
    }};
}

test('camera input does not read content arrays with 100000 entries',async()=>{
  const f=await fixture(),text=f.snapshot.elements[0]!;
  const reads={elements:0,pages:0,unsupported:0};
  const watched=<T>(name:keyof typeof reads,entries:T[])=>new Proxy(entries,{get(array,property,receiver){
    reads[name]++;
    return Reflect.get(array,property,receiver);
  }});
  f.snapshot.target={kind:'page',id:randomUUID()};
  f.snapshot.elements=watched('elements',Array.from({length:100000},(_,index)=>index===99999?text:
    {source:{...text.source,id:`element-${index}`}}));
  f.snapshot.unsupportedElements=watched('unsupported',Array.from({length:100000},(_,index)=>
    ({id:`unsupported-${index}`,kind:'program',reason:'program'})));
  f.snapshot.navigation={position:{index:50000,pageID:f.snapshot.target.id},
    directory:{header:{item:{title:'Large document',pageCount:100000}},
      pages:watched('pages',Array.from({length:100000},(_,index)=>
        ({position:{index,pageID:index===50000?f.snapshot.target.id:`page-${index}`}})))}};
  await f.session.refresh(true);f.context.buttons();
  for(const [name,count]of Object.entries(reads))assert.ok(count>=100000,`${name} exercises the real control-state lookup`);
  assert.equal(f.otherControls.get('delete')!.disabled,false);
  assert.equal(f.otherControls.get('page-previous')!.disabled,false);
  assert.equal(f.otherControls.get('page-next')!.disabled,false);
  const basis=f.session.snapshot,selection=f.context.selected;
  const cameraInput=async(action:()=>Promise<void>)=>{
    reads.elements=reads.pages=reads.unsupported=0;
    const before=f.counts();await action();
    assert.deepEqual(reads,{elements:0,pages:0,unsupported:0},'Camera samples never scan content or the page directory');
    assert.equal(f.counts().cameraPublications,before.cameraPublications+1);
    assert.equal(f.counts().inkDraws,before.inkDraws+1);
    assert.equal(f.otherControls.get('zoom-level')!.textContent,`${Math.round(f.context.worldCamera.scale*100)}%`);
    assert.equal(f.session.snapshot,basis);assert.equal(f.context.selected,selection);
    assert.equal(f.writes.length,0);
  };
  let prevented=false;
  await cameraInput(()=>f.dispatch('wheel',{ctrlKey:true,metaKey:false,deltaX:0,deltaY:-25,
    clientX:400,clientY:300,preventDefault(){prevented=true;}}));
  assert.equal(prevented,true);assert.equal(f.otherControls.get('zoom-level')!.textContent,'122%');
  const center=f.context.worldCamera.center;
  await cameraInput(()=>f.dispatch('wheel',{ctrlKey:false,metaKey:false,deltaX:30,deltaY:40,preventDefault(){}}));
  assert.notDeepEqual(f.context.worldCamera.center,center,'The real wheel listener publishes its pan');
  await f.clickTool('hand');await f.pointer('pointerdown',7,200);
  assert.equal(f.context.gesture.mode,'pan');
  for(const x of [220,260,280])await cameraInput(()=>f.pointer('pointermove',7,x));
  await f.pointer('pointerup',7,280);assert.equal(f.context.gesture,null);
});

test('editor entry updates controls without a camera state refresh',async()=>{
  const f=await fixture(),before=f.counts();
  assert.equal(f.otherControls.get('zoom-in')!.disabled,false);
  assert.equal(f.otherControls.get('workspaces')!.disabled,false);
  await f.key('Enter');
  assert.equal(f.context.draft.element,f.snapshot.elements[0]);assert.equal(f.editor.hidden,false);
  assert.equal(f.counts().cameraPublications,before.cameraPublications+1);
  assert.equal(f.counts().editorFocus,before.editorFocus+1);assert.equal(f.editor.readOnly,false);
  for(const id of ['zoom-in','zoom-out','zoom-fit','workspaces'])assert.equal(f.otherControls.get(id)!.disabled,true,id);
  assert.equal(f.toolControls.get('hand')!.disabled,false,'A draft still finishes through the toolbar');
  await f.editorKey('Escape');assert.equal(f.context.draft,null);assert.equal(f.editor.hidden,true);
  for(const id of ['zoom-in','zoom-out','zoom-fit','workspaces'])assert.equal(f.otherControls.get(id)!.disabled,false,id);
  assert.equal(f.writes.length,0);
});

test('resize cancellation restores controls before another presentation',async t=>{
  for(const mode of ['move','resize'])await t.test(mode,async()=>{
    const f=await fixture();await f.pointer('pointerdown',1,100,mode==='resize');await f.pointer('pointermove',1,140);
    assert.equal(f.context.gesture.mode,mode);assert.equal(f.session.suspended,true);assert.equal(f.captures.has(1),true);
    for(const id of ['zoom-in','workspaces','undo','delete'])assert.equal(f.otherControls.get(id)!.disabled,true,id);
    assert.equal(f.toolControls.get('hand')!.disabled,true);
    const before=f.counts(),basis=f.session.snapshot,requests=f.calls.length;
    f.context.workspace.clientWidth=900;f.context.workspace.clientHeight=700;f.resize();
    assert.equal(f.context.gesture,null);assert.equal(f.session.suspended,false);assert.equal(f.session.mutationReady,true);
    assert.equal(f.captures.size,0);assert.equal(f.counts().clears,before.clears+1);
    assert.equal(f.counts().cameraPublications,before.cameraPublications+1);
    for(const id of ['zoom-in','zoom-out','zoom-fit','workspaces','undo','delete'])assert.equal(f.otherControls.get(id)!.disabled,false,id);
    assert.equal(f.toolControls.get('hand')!.disabled,false);assert.equal(f.editor.readOnly,false);
    assert.equal(f.session.snapshot,basis);assert.equal(f.calls.length,requests);assert.equal(f.writes.length,0);
    await f.pointer('lostpointercapture');await f.pointer('pointerup',1,140);
    assert.equal(f.writes.length,0,'Trailing terminal events cannot save a resized contact');
  });
  await t.test('pen with a pending presentation',async t=>{
    const f=await fixture(),gpu={setNodes(){},resize(){},draw(){},dispose(){}} as unknown as InkGPU;
    t.mock.method(InkGPU,'create',async()=>gpu);
    let contactDisposals=0;
    Object.assign(f.context.geometry,{
      penSample:(force:number)=>({width:2,opacity:1,filteredForce:force,color:{red:0,green:0,blue:0}}),
      inkContact:()=>({update(){return {};},snapshot(){return {};},dispose(){contactDisposals++;}}),
    });
    const errors:Error[]=[],changes:{suspended:boolean;undoDisabled:boolean}[]=[];
    const input=new InkInput({hidden:true} as HTMLCanvasElement,()=>f.context.geometry,
      ()=>({camera:f.context.worldCamera,viewport:{x:800,y:600},pixelScale:1}),f.context.lifetime.signal,
      ()=>{f.context.buttons();changes.push({suspended:f.session.suspended,undoDisabled:f.otherControls.get('undo')!.disabled});},
      error=>errors.push(error));
    await turn();assert.equal(input.ready,true);f.context.ink=input;f.context.tool='pen';
    let release!:(value:Awaited<ReturnType<NotebookSession['app']['callServerTool']>>)=>void;
    const response=new Promise<Awaited<ReturnType<NotebookSession['app']['callServerTool']>>>(resolve=>{release=resolve;});
    let requested=false;
    t.mock.method(f.session.app,'callServerTool',async(request:Parameters<NotebookSession['app']['callServerTool']>[0])=>{
      assert.equal(request.name,'notebook_panel_presentation');requested=true;return response;
    });
    const reading=f.session.refresh(true);
    t.after(async()=>{release({content:[],structuredContent:f.snapshot});await reading;f.context.lifetime.abort();});
    await turn();assert.equal(requested,true);
    const sample={pointerId:1,timeStamp:10,pointerType:'pen',pressure:.5,clientX:100,clientY:100,button:0,altKey:false,
      target:{hasAttribute:()=>false,closest:()=>null},preventDefault(){}};
    await f.dispatch('pointerdown',sample);assert.equal(input.pointer,1);assert.equal(f.session.suspended,true);
    assert.equal(f.otherControls.get('undo')!.disabled,true);assert.equal(f.editor.readOnly,true);changes.length=0;
    const basis=f.session.snapshot;f.resize();
    assert.deepEqual(changes,[{suspended:true,undoDisabled:true}],'The real InkInput.clear publishes before suspension is released');
    assert.equal(input.pointer,undefined);assert.equal(input.hasPreview,false);assert.equal(contactDisposals,1);
    assert.equal(f.captures.size,0);assert.equal(f.session.suspended,false);assert.equal(f.session.mutationReady,true);
    for(const id of ['undo','back','zoom-in','workspaces'])assert.equal(f.otherControls.get(id)!.disabled,false,id);
    assert.equal(f.editor.readOnly,false);assert.equal(f.toolControls.get('hand')!.disabled,false);
    assert.equal(f.otherControls.get('delete')!.disabled,true,'Pen entry cleared the selection');
    await turn();assert.equal(f.otherControls.get('undo')!.disabled,false,'Controls remain ready while the response is still pending');
    assert.equal(f.session.snapshot,basis);assert.deepEqual(errors,[]);assert.equal(f.writes.length,0);
    await f.dispatch('lostpointercapture',sample);await f.dispatch('pointerup',{...sample,timeStamp:20});
    assert.equal(f.writes.length,0,'The cancelled pen contact cannot produce a later write');
  });
});

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
  await f.key('Enter');assert.ok(f.context.draft);
  await f.clickTool('hand');assert.equal(f.context.draft,null);assert.equal(f.context.tool,'hand');
  assert.equal(f.writes.length,0,'An unchanged draft finishes without a recursive completion');
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
  await f.clickTool('hand');assert.equal(f.context.draft,null);assert.equal(f.context.tool,'hand');
  assert.equal(f.writes.length,0,'An empty new draft finishes without a recursive completion');
  f.context.tool='text';await f.pointer('pointerdown');
  const reopened:unknown=Reflect.get(f.context,'draft');
  assert.ok(reopened&&typeof reopened==='object'&&'isNew' in reopened);
  assert.equal(reopened.isNew,true);
  f.editor.value='New text';await f.editorKey('Enter',true);assert.equal(f.writes.length,1);
  const operation=(f.calls.at(-1)!.arguments.operations as PanelMutation['operations'])[0]!;
  assert.equal(operation.kind,'insertElement');assert.equal(operation.values.source,'New text');
  await f.complete();assert.equal(f.context.draft,null);assert.equal(f.editor.hidden,true);
  assert.equal(f.session.mutationReady,true);
});

test('blur and tool changes share one editor completion and preserve the latest intent',async t=>{
  for(const outcome of ['saved-toolbar','saved-shortcut','conflict','uncertain','cancel','closed'])await t.test(outcome,async()=>{
    const f=await fixture();await f.key('Enter');f.editor.value='After';
    await f.blurEditor();assert.equal(f.writes.length,1);
    const request=f.calls.find(call=>call.name==='notebook_panel_edit')!.arguments;
    const selected=f.context.selected;
    assert.equal(f.toolControls.get('rectangle')!.disabled,false,'A draft cannot disable finishing through its toolbar');
    await f.clickTool('rectangle');await f.clickTool('ellipse');await f.key('p',false,true);
    if(outcome==='saved-toolbar')await f.clickTool('hand');
    assert.equal(f.writes.length,1,'Blur, rapid clicks and a shortcut share the original addressed write');
    assert.equal(f.context.tool,'select');assert.ok(f.context.draft);assert.equal(f.editor.readOnly,true);
    if(outcome==='cancel'){
      await f.editorKey('Escape');assert.ok(f.context.draft);assert.equal(f.editor.value,'After');
      assert.equal(f.writes.length,1,'Escape cannot discard a dispatched save or admit another action');
    }
    if(outcome==='conflict'||outcome==='uncertain'){
      f.writes.shift()!.resolve({content:[],isError:true,structuredContent:{status:'error',
        code:outcome==='conflict'?'revision_conflict':'ipc_timeout',message:'Save was not confirmed'}});
      await turn();assert.ok(f.context.draft);assert.equal(f.editor.value,'After');
      assert.deepEqual(f.context.selected,selected);assert.equal(f.context.tool,'select');
      if(outcome==='conflict'){assert.equal(f.session.hasPending,false);assert.equal(f.editor.readOnly,false);return;}
      assert.equal(f.session.hasPending,true);assert.equal(f.editor.readOnly,true);
      await f.clickTool('hand');assert.equal(f.calls.filter(call=>call.name==='notebook_panel_edit').length,1,
        'An unknown outcome remains owned by the same Session action');
      const retry=f.retry();assert.ok(retry);const recovery=retry();await turn();
      f.writes.shift()!.resolve({content:[],structuredContent:{status:{kind:'notebookRuntime',ready:true,pid:2,state:'ready',
        workspaceID:f.snapshot.workspaceID,socketKey:f.snapshot.socketKey},workspaces:[],snapshot:f.snapshot}});
      await recovery;await turn();
      assert.deepEqual(f.calls.filter(call=>call.name==='notebook_panel_edit')[1]!.arguments,request,
        'Recovery retries the authentic command, including its actionID and captured sources');
    }
    if(outcome==='closed'){
      await f.close();const afterClose=f.counts();assert.equal(f.context.closed,true);
      assert.equal(afterClose.disposals,1);assert.equal(afterClose.geometryDisposals,1);
      await f.complete();assert.deepEqual(f.counts(),afterClose,'Late receipts cannot refocus or recreate a closed controller');
      assert.equal(f.context.tool,'select');assert.equal(f.context.draft,null);assert.equal(f.editor.hidden,true);return;
    }
    await f.complete();
    assert.equal(f.context.draft,null);assert.equal(f.editor.hidden,true);assert.equal(f.session.hasPending,false);
    assert.equal(f.context.tool,outcome==='cancel'?'select':outcome==='saved-toolbar'||outcome==='uncertain'?'hand':'pen');
    assert.equal(f.toolControls.get(f.context.tool)!.pressed,'true');
    assert.equal(f.calls.filter(call=>call.name==='notebook_panel_edit').length,outcome==='uncertain'?2:1);
  });
});

test('one pointer activation cannot retry a fast editor refusal before its click',async()=>{
  const f=await fixture();await f.key('Enter');f.editor.value='After';
  const before=structuredClone(f.snapshot.elements[0]!.source),selected=f.context.selected;
  const peer={...before,source:'Peer changed the text',frame:{...before.frame,width:150}};
  const refuse=async()=>{
    f.snapshot.cursor='2';f.snapshot.appearance!.sourceRevision='2';
    f.snapshot.checkpoint={...f.snapshot.checkpoint!,id:randomUUID(),readCursor:'2',changeCursor:'2'};
    f.snapshot.elements=[{source:peer}];
    f.writes.shift()!.resolve({content:[],isError:true,structuredContent:{status:'error',code:'revision_conflict',message:'Peer source changed'}});
    await turn();
  };
  const prevented=await f.pressTool('hand');
  // A default focus change would reject its blur write before mouseup/click.
  // A prevented default must never be replaced by a synthetic blur in this port.
  if(f.writes.length)await refuse();
  await f.activateTool('hand');
  assert.equal(f.calls.filter(call=>call.name==='notebook_panel_edit').length,1,
    'Pointerdown and click are one activation, not two addressed writes after a fast conflict');
  assert.equal(prevented,true);assert.equal(f.writes.length,1);
  const first=f.calls.find(call=>call.name==='notebook_panel_edit')!.arguments;
  assert.deepEqual(structuredClone(first.sources),[capturedSource(f.snapshot.target,before)]);
  await refuse();
  assert.equal(f.editor.value,'After');assert.equal(f.editor.hidden,false);assert.equal(f.context.tool,'select');
  assert.deepEqual(f.context.selected,selected);assert.deepEqual(f.context.draft.element.source,peer);
  assert.equal(f.session.snapshot!.cursor,'2');assert.equal(f.session.hasPending,false);
  assert.equal(f.calls.filter(call=>call.name==='notebook_panel_edit').length,1,'Refusal never invents a new save intent');
  await f.clickTool('hand');
  const retry=f.calls.filter(call=>call.name==='notebook_panel_edit')[1]!.arguments;
  assert.notEqual(retry.actionID,first.actionID);assert.deepEqual(structuredClone(retry.sources),[capturedSource(f.snapshot.target,peer)]);
  assert.equal((retry.operations as PanelMutation['operations'])[0]!.values.source,'After');
  await f.complete();assert.equal(f.context.draft,null);assert.equal(f.context.tool,'hand');
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
  assert.equal(operation.kind,'appendInkStroke');assert.deepEqual(structuredClone(request.sources),[]);
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

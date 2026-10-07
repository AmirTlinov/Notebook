import { NotebookSession, PanelError } from "./session.js";
import { Surface, editable } from "./surface.js";
import { admitPanelCamera, panelCoordinateScale, panelProjection, transformPanelCamera } from "./projection.js";
import { SwiftSurface, type SurfaceCamera } from "./swift-surface.js";
import { InkInput } from "./ink-input.js";
import { WorkspacePicker } from "./workspaces.js";
import type {PanelIdentity} from "../panel-bundle.mjs";
import { capturedSource, type Camera, type Frame, type PanelElement, type PanelMutation, type PanelOperation, type PanelCard, type PanelSelection, type Point, type PanelTarget, type PanelView } from "./model.js";

const el=<T extends HTMLElement>(id:string)=>document.getElementById(id) as T;
const workspace=el<HTMLElement>("workspace");
const controls=el<HTMLElement>("surface-controls");
const paper=document.getElementById("paper") as unknown as SVGSVGElement;
const material=document.getElementById("material") as unknown as SVGGElement;
const selection=document.getElementById("selection") as unknown as SVGGElement;
const editor=el<HTMLTextAreaElement>("text-editor");
declare const NOTEBOOK_SURFACE_WASM:string;
let geometry:SwiftSurface;
let geometryLoaded=false;
let closed=false;
// Connect the host while Swift compiles. Snapshot admission owns readiness;
// closing during compilation releases the result without mounting a surface.
const geometryReady=SwiftSurface.compressed(NOTEBOOK_SURFACE_WASM).then(value=>{
  if(closed){value.dispose();return false;}
  geometry=value;geometryLoaded=true;session.suspended=false;
  session.viewportChanged();void session.refresh(true);
  return true;
}).catch(error=>{
  if(closed)return false;
  el("status").textContent="Не удалось открыть поверхность";
  const message=el("message");message.hidden=false;
  message.querySelector("span")!.textContent=error instanceof Error?error.message:String(error);
  el<HTMLButtonElement>("retry").hidden=true;
  document.querySelectorAll<HTMLButtonElement>("button").forEach(button=>button.disabled=true);
  return false;
});
const identity=JSON.parse(el<HTMLScriptElement>("notebook-panel-identity").textContent??"null") as PanelIdentity|null;
if(!identity||typeof identity.version!=="string"||typeof identity.cohort!=="string"
  ||!/^\d{1,9}\.\d{1,9}\.\d{1,9}$/.test(identity.version)||!/^[a-f0-9]{64}$/.test(identity.cohort)){
  throw new Error("Notebook не передал идентичность этой панели.");
}
const session=new NotebookSession(identity);
// Host registration starts immediately; content reads wait for a usable local
// surface. A failed compilation leaves the same read gate parked.
session.suspended=true;
const surface=new Surface(paper,material,selection);
const lifetime=new AbortController();
const events={signal:lifetime.signal};
const workspaces=new WorkspacePicker(session,lifetime.signal);
session.onRuntime=status=>workspaces.start(status);
el("workspaces").addEventListener("click",()=>{void workspaces.open();},events);
// Native projections may change their local origin. Keep one world camera so
// accepting pixels never changes the exact request center through a round trip.
let worldCamera:NonNullable<PanelView["camera"]>={center:{tileX:0,tileY:0,localX:0,localY:0},scale:1};
const camera:Camera={
  get x(){return worldDelta(worldCamera.center,session.snapshot?.worldOrigin??null).x-workspace.clientWidth/(2*worldCamera.scale);},
  get y(){return worldDelta(worldCamera.center,session.snapshot?.worldOrigin??null).y-workspace.clientHeight/(2*worldCamera.scale);},
  get scale(){return worldCamera.scale;},
};
let selected:PanelSelection|null=null;
let tool="select",space=false;
let retry:(()=>Promise<void>)|null=null;
let draft:{element:PanelElement;isNew:boolean}|null=null;
let editorFinish:Promise<boolean>|null=null;
let toolIntent=0;
type Gesture={pointer:number;start:Point;last:Point;client:Point;lastClient:Point;camera:SurfaceCamera;viewport:Point;mode:"pan"|"move"|"resize"|"create";element?:PanelElement;card?:PanelCard;subject?:PanelSelection;frame?:Frame;bounds?:Frame;shown?:Frame};
let gesture:Gesture|null=null;
const path:{target:PanelTarget;camera:NonNullable<PanelView["camera"]>;selection:PanelSelection|null}[]=[];
const ink=new InkInput(el<HTMLCanvasElement>("ink-preview"),()=>geometry,
  ()=>({camera:worldCamera,viewport:viewport(),pixelScale:window.devicePixelRatio}),lifetime.signal,
  ()=>{if(!closed)buttons();},(error,retry)=>session.onError(error.message,retry));
const worldDelta=(a:NonNullable<typeof session.snapshot>["worldOrigin"],b:NonNullable<typeof session.snapshot>["worldOrigin"]):Point=>a&&b?geometry.delta(b,a):{x:0,y:0};
const viewport=():Point=>({x:Math.max(1,workspace.clientWidth),y:Math.max(1,workspace.clientHeight)});
function choose(value:PanelSelection|null){selected=value;surface.select(value);buttons();session.context(value);}
function active(){return selected?.kind==="element"?session.snapshot?.elements.find(e=>e.source.id===selected!.id):undefined;}
function activeCard(){return selected?.kind==="item"?session.snapshot?.cards.find(c=>c.item.id===selected!.id):undefined;}
function canMoveCard(card:PanelCard){return card.editable===true&&card.source?.id.toLowerCase()===card.item.id.toLowerCase()&&surface.hasItemSubject(card.item.id);}
function canEdit(element:PanelElement){return editable(element)&&surface.hasSubject(element.source.id)&&!session.snapshot?.unsupportedElements.some(e=>e.id===element.source.id);}
function canMove(element:PanelElement){return canEdit(element)&&!element.source.graphic?.connection?.start?.binding&&!element.source.graphic?.connection?.end?.binding;}
function neighbor(direction:number):PanelTarget|undefined{
  const navigation=session.snapshot?.navigation,index=navigation?.position?.index;
  if(session.snapshot?.target.kind!=="page"||index===undefined)return;
  const page=navigation?.directory?.pages.find(page=>page.position.index===index+direction);
  return page?{kind:"page",id:page.position.pageID}:undefined;
}
function buttons(){
  const drawing=ink.pointer!==undefined,waiting=!session.mutationReady||drawing;
  el<HTMLButtonElement>("delete").disabled=!active()||!canEdit(active()!)||waiting;
  el<HTMLButtonElement>("workspaces").disabled=session.busy||drawing||!!draft||!!gesture;
  el<HTMLButtonElement>("undo").disabled=!session.snapshot?.history.undoActionID||waiting;
  editor.readOnly=waiting||!!editorFinish;
  document.querySelectorAll<HTMLButtonElement>("[data-tool]").forEach(button=>button.disabled=!canChooseTool(button.dataset.tool!));
  el<HTMLButtonElement>("back").hidden=path.length===0&&!session.snapshot?.navigation?.parentBoard;
  el<HTMLButtonElement>("back").disabled=waiting;
  for(const id of ["zoom-in","zoom-out","zoom-fit"])el<HTMLButtonElement>(id).disabled=!session.hasAppearance||!!draft||!!gesture||drawing;
  const navigation=session.snapshot?.navigation;
  el("page-navigation").hidden=session.snapshot?.target.kind!=="page"||!navigation?.directory||!navigation.position;
  el("page-position").textContent=navigation?.position&&navigation.directory?`${navigation.position.index+1} / ${navigation.directory.header.item.pageCount}`:"";
  el<HTMLButtonElement>("page-previous").disabled=waiting||!neighbor(-1);
  el<HTMLButtonElement>("page-next").disabled=waiting||!neighbor(1);
  el("zoom-level").textContent=`${Math.round(camera.scale*100)}%`;
  workspace.dataset.tool=tool;workspace.dataset.pan=String(gesture?.mode==="pan"||space);
}
function cameraScaleBounds(){
  const ratio=panelCoordinateScale(workspace.clientWidth,workspace.clientHeight);
  return {min:geometry.minimumScale/ratio,max:geometry.maximumScale/ratio};
}
function setCamera(next:Camera){
  if(closed)return;
  if(!geometryLoaded){session.viewportChanged();return;}
  const center=next===camera?worldCamera.center:geometry.offset(session.snapshot?.worldOrigin??worldCamera.center,
    next.x+workspace.clientWidth/(2*next.scale),next.y+workspace.clientHeight/(2*next.scale));
  publishCamera(admitPanelCamera(geometry,{center,scale:next.scale},viewport()));
}
function publishCamera(next:SurfaceCamera){
  if(closed)return;
  worldCamera=next;
  surface.setCamera(camera);ink.draw();if(draft)positionEditor(draft.element,draft.isNew);buttons();session.viewportChanged();
}
function mutation(summary:string,operation:PanelOperation,element?:PanelElement,card?:PanelCard):PanelMutation {
  return {...session.address(),actionID:crypto.randomUUID(),summary,operations:[operation],
    sources:operation.kind==="appendInkStroke"?[]:[card?.source??(element?capturedSource(session.address().target,element.source):{id:operation.id})]};
}
async function save(request:PanelMutation){
  try{await session.save(request);return !closed;}catch{if(!closed)surface.clearPreview();return false;}finally{if(!closed)buttons();}
}
session.bounds=()=>!closed&&geometryLoaded&&session.snapshot?.worldOrigin?{anchor:session.snapshot.worldOrigin,
  region:{x:camera.x,y:camera.y,width:Math.max(1,workspace.clientWidth/camera.scale),height:Math.max(1,workspace.clientHeight/camera.scale)}}:undefined;
session.knownAssets=()=>surface.assetIDs;
session.needsPresentation=()=>!closed&&geometryLoaded&&!surface.covers(session.bounds(),session.view(false));
session.view=(navigation,restoredCamera)=>{
  const supplied=restoredCamera??(!navigation&&session.hasAppearance&&session.snapshot?.worldOrigin?worldCamera:undefined);
  return panelProjection(workspace.clientWidth,workspace.clientHeight,window.devicePixelRatio,
    supplied,!navigation&&session.hasAppearance);
};
session.onPrepareSnapshot=async(snapshot,view)=>await geometryReady&&!closed&&surface.prepare(snapshot,view);
session.onCancelSnapshotPreparation=()=>surface.cancelPreparation();
session.onClose=()=>{
  const inkPointer=ink.pointer;
  closed=true;lifetime.abort();resizeObserver.disconnect();
  if(inkPointer!==undefined&&paper.hasPointerCapture(inkPointer))paper.releasePointerCapture(inkPointer);
  if(gesture&&paper.hasPointerCapture(gesture.pointer))paper.releasePointerCapture(gesture.pointer);
  gesture=null;draft=null;editor.hidden=true;
  const disposed=surface.dispose();if(geometryLoaded)geometry.dispose();return disposed;
};
let first=true;
let priorTarget:string|undefined;
let priorWorkspace:string|undefined;
session.onSnapshot=snapshot=>{
  if(priorWorkspace!==snapshot.workspaceID){path.length=0;priorWorkspace=snapshot.workspaceID;}
  const address=`${snapshot.workspaceID}:${snapshot.target.kind}:${snapshot.target.id}`;
  if(priorTarget!==address){cancelGesture(false);first=true;selected=null;priorTarget=address;}
  surface.render(snapshot);
  ink.presented();
  if(first){
    const appearance=snapshot.appearance!;
    const scale=appearance.camera.scale*viewport().x/appearance.viewport.x;
    worldCamera=admitPanelCamera(geometry,{center:appearance.camera.center,scale},viewport());first=false;
  }
  surface.setCamera(camera);
  el("surface-name").textContent=snapshot.navigation?.directory?.header.item.title??(snapshot.target.kind==="board"?"Доска":"Лист");
  surface.select(selected);buttons();session.context(selected);
  const notes=[];
  if(snapshot.truncated)notes.push("Видимая область содержит больше объектов. Приблизьте нужный участок.");
  for(const diagnostic of snapshot.appearance?.diagnostics??[])if(diagnostic.message)notes.push(diagnostic.message);
  el("coverage").textContent=notes.join(" ");
  if(draft){if(!draft.isNew)surface.hideSubject(draft.element.source.id,true);positionEditor(draft.element,draft.isNew);}
};
session.onStateChange=buttons;
session.onStatus=text=>{el("status").textContent=text;buttons();};
session.onError=(message,action)=>{
  const box=el("message");box.hidden=!message;box.querySelector("span")!.textContent=message;
  retry=action;el<HTMLButtonElement>("retry").hidden=!action;
  buttons();
};
el("retry").addEventListener("click",()=>{void retry?.().catch(()=>{});},events);

function operation(kind:PanelOperation["kind"],id:string,values:Record<string,unknown>):PanelOperation {
  return {kind,target:session.address().target,id,values};
}
function newElement(point:Point,kind:string):PanelElement {
  return {source:{id:crypto.randomUUID(),kind,source:"",...(session.snapshot?.worldOrigin?{worldOrigin:session.snapshot.worldOrigin}:{}),frame:{...point,width:240,height:90},
    textStyle:{fontSize:24,weight:.4,red:.1,green:.1,blue:.1,alpha:1}}};
}
function openEditor(element:PanelElement,isNew=false){
  if(editorFinish||!session.mutationReady||gesture||ink.hasPreview)return;
  if(!isNew&&!canEdit(element))return;
  draft={element,isNew};
  const font=element.source.kind==="nativeText"?element.source.textStyle?.fontSize??34:24;
  const frame=surface.authoredFrame(element),scale=Math.max(camera.scale,16/font);
  setCamera({scale,x:frame.x+frame.width/2-workspace.clientWidth/(2*scale),y:frame.y+frame.height/2-workspace.clientHeight/(2*scale)});
  if(!isNew)surface.hideSubject(element.source.id,true);
  editor.value=element.source.kind==="nativeText"?element.source.source:String(element.source.graphic?.label??"");
  positionEditor(element,isNew);editor.hidden=false;editor.focus();editor.select();
}
function positionEditor(element:PanelElement,isNew:boolean){
  const text=element.source.kind==="nativeText";
  const frame=isNew||text?surface.authoredFrame(element):surface.frame(element);
  editor.style.left=`${(frame.x-camera.x)*camera.scale}px`;
  editor.style.top=`${(frame.y-camera.y)*camera.scale}px`;
  editor.style.minWidth=text?"0":"60px";
  editor.style.width=`${text?frame.width*camera.scale:Math.max(120,frame.width*camera.scale)}px`;
  editor.style.height=`${Math.max(60,frame.height*camera.scale)}px`;
  const fontSize=element.source.kind==="nativeText"?element.source.textStyle?.fontSize??34:24;
  const weight=element.source.kind==="nativeText"?element.source.textStyle?.weight??.45:.3;
  editor.style.fontSize=`${fontSize*camera.scale}px`;
  editor.style.fontWeight=String(weight<.2?300:weight<.4?400:weight<.6?500:weight<.8?600:700);
}
function finishEditor(cancel=false):Promise<boolean>{
  if(cancel)++toolIntent;
  if(closed)return Promise.resolve(false);
  // Blur and a subsequent tool click own one completion, including an unknown
  // accepted write. Escape cannot discard or replace that dispatched action.
  if(editorFinish)return editorFinish;
  const captured=draft;if(!captured)return Promise.resolve(true);
  if(session.busy||session.hasPending)return Promise.resolve(false);
  const value=editor.value,element=captured.element;
  const previous=element.source.kind==="nativeText"?element.source.source:String(element.source.graphic?.label??"");
  const finishing=(async()=>{
    if(cancel||(captured.isNew?!value.trim():value===previous)){
      if(!captured.isNew)surface.hideSubject(element.source.id,false);
      draft=null;editor.hidden=true;session.suspended=false;
      await session.refresh();if(closed)return false;
      workspace.focus();return true;
    }
    const values:Record<string,unknown>=element.source.kind==="nativeText"?{source:value}:{graphic:{label:value}};
    if(element.source.kind==="nativeText")values.frame={...element.source.frame,
      height:Math.max(element.source.frame.height,editor.scrollHeight/camera.scale)};
    if(captured.isNew){
      Object.assign(values,{kind:"nativeText",textStyle:element.source.textStyle});
      if(element.source.worldOrigin)values.worldOrigin=element.source.worldOrigin;
    }
    const request=mutation("Изменить текст",operation(captured.isNew?"insertElement":"updateElement",element.source.id,values),captured.isNew?undefined:element);
    try{
      await session.save(request);if(closed)return false;
      draft=null;editor.hidden=true;session.suspended=false;
      await session.refresh();if(closed)return false;
      choose({kind:"element",id:element.source.id});workspace.focus();return true;
    }catch(error){
      if(closed)return false;
      session.suspended=false;await session.refresh();
      if(closed)return false;
      const current=session.snapshot?.elements.find(e=>e.source.id===element.source.id);
      if(error instanceof PanelError&&error.code==="revision_conflict"&&current&&!captured.isNew){draft={element:current,isNew:false};session.onError("Элемент изменился. Ваш текст остался в редакторе; проверьте его и сохраните ещё раз.",null);}
      editor.focus();return false;
    }
  })();
  editorFinish=finishing;buttons();
  const release=()=>{if(editorFinish===finishing){editorFinish=null;if(!closed)buttons();}};
  void finishing.then(release,release);
  return finishing;
}
editor.addEventListener("keydown",event=>{
  if(event.isComposing)return;
  if(event.key==="Escape"){event.preventDefault();void finishEditor(true);}
  if(event.key==="Enter"&&(event.metaKey||event.ctrlKey)){event.preventDefault();void finishEditor();}
},events);
editor.addEventListener("blur",()=>{if(draft)void finishEditor();},events);

paper.addEventListener("pointerdown",event=>{
  if(!session.snapshot||!session.hasAppearance||event.button===2||gesture||ink.pointer!==undefined)return;
  const target=event.target as Element,resizing=target.hasAttribute("data-resize-handle");
  const itemID=target.closest("[data-card-id]")?.getAttribute("data-card-id");
  const elementID=target.closest("[data-element-id]")?.getAttribute("data-element-id");
  const subject:PanelSelection|null=resizing?selected:itemID?{kind:"item",id:itemID}:elementID?{kind:"element",id:elementID}:null;
  const wantsPan=tool==="hand"||space||event.button===1||event.altKey||(tool==="select"&&!subject);
  if(!wantsPan&&!session.mutationReady)return;
  if(wantsPan)session.beginCameraInteraction();
  if(draft){void finishEditor();if(!wantsPan)return;}
  const point=surface.point(event.clientX,event.clientY);
  if(tool==="pen"&&!wantsPan){
    const rect=paper.getBoundingClientRect(),size=viewport();
    try{
      const origin=session.snapshot.target.kind==="board"?geometry.offset(worldCamera.center,
        (event.clientX-rect.left-size.x/2)/camera.scale,(event.clientY-rect.top-size.y/2)/camera.scale):{tileX:0,tileY:0,localX:0,localY:0};
      if(ink.begin(event,{origin,camera:worldCamera,viewport:size,client:{x:rect.left,y:rect.top},
      ...(session.snapshot.target.kind==="page"?{clip:{x:0,y:0,...session.snapshot.size}}:{})})){
      choose(null);session.suspended=true;paper.setPointerCapture(event.pointerId);workspace.focus();buttons();event.preventDefault();
    }}catch(error){ink.clear();session.onError(error instanceof Error?error.message:String(error),null);}
    return;
  }
  const element=subject?.kind==="element"?session.snapshot.elements.find(e=>e.source.id===subject.id):undefined;
  const card=subject?.kind==="item"?session.snapshot.cards.find(c=>c.item.id===subject.id):undefined;
  let mode:Gesture["mode"];
  if(wantsPan){mode="pan";if(!subject&&tool==="select"&&!space&&event.button===0&&!event.altKey)choose(null);}
  else if(tool==="text"){event.preventDefault();choose(null);openEditor(newElement(point,"nativeText"),true);return;}
  else if(tool!=="select"){mode="create";choose(null);}
  else{
    choose(subject);
    if(card){if(!canMoveCard(card)){workspace.focus();return;}mode="move";}
    else{if(!element||!canMove(element)){workspace.focus();return;}mode=resizing?"resize":"move";}
  }
  const frame=mode==="resize"&&element?.source.kind==="nativeText"?surface.authoredFrame(element):subject?surface.selectionFrame(subject):undefined;
  gesture={pointer:event.pointerId,start:point,last:point,client:{x:event.clientX,y:event.clientY},
    lastClient:{x:event.clientX,y:event.clientY},camera:worldCamera,viewport:viewport(),mode,
    ...(subject?{subject}:{}),...(card?{card}:{}),...(element?{element}:{}),
    ...(frame?{frame}:{}),
    ...(session.snapshot.target.kind==="page"?{bounds:{x:0,y:0,...session.snapshot.size}}:{})};
  session.suspended=mode!=="pan";paper.setPointerCapture(event.pointerId);workspace.focus();buttons();event.preventDefault();
},events);
paper.addEventListener("pointermove",event=>{
  if(ink.pointer===event.pointerId){
    try{ink.append(event);}catch(error){session.onError(error instanceof Error?error.message:String(error),null);}
    return;
  }
  if(!gesture||event.pointerId!==gesture.pointer)return;
  updateGesture(gesture,event);
},events);
function updateGesture(g:Gesture,event:PointerEvent){
  const point=surface.point(event.clientX,event.clientY);
  const dx=point.x-g.start.x,dy=point.y-g.start.y;
  if(g.mode==="pan"){
    // Swift resolves each contact against its immutable camera basis, just as
    // on iPad. A new scene origin cannot accumulate rounding or rewind the pan.
    publishCamera(transformPanelCamera(geometry,g.camera,g.viewport,{x:0,y:0},
      {x:event.clientX-g.client.x,y:event.clientY-g.client.y},1));
  }else if(g.mode==="move"||g.mode==="resize"){
    if(!g.frame)return;
    try{
      const shown=geometry.manipulateFrame(g.mode==="move"?"move":g.element?.source.kind==="nativeText"?"trailingCenter":"bottomTrailing",
        g.frame,{x:dx,y:dy},g.bounds);
      const movement={x:shown.x-g.frame.x,y:shown.y-g.frame.y};
      const origin=g.card?.center??g.element?.source.worldOrigin;
      if(g.mode==="move"&&origin)geometry.offset(origin,movement.x,movement.y);
      g.shown=shown;
      if(g.mode==="move")surface.preview(g.subject!,movement.x,movement.y);
      else drawGesture(g,dx,dy);
    }catch{return;} // Keep the last admitted pose at an address/geometry limit.
  }else drawGesture(g,dx,dy);
  g.last=point;g.lastClient={x:event.clientX,y:event.clientY};
}
function drawGesture(g:Gesture,dx:number,dy:number){
  selection.replaceChildren();
  const shape=document.createElementNS("http://www.w3.org/2000/svg",tool==="ellipse"&&g.mode==="create"?"ellipse":"rect");
  const f=g.mode==="resize"?g.shown!:
    {x:Math.min(g.start.x,g.start.x+dx),y:Math.min(g.start.y,g.start.y+dy),width:Math.max(1,Math.abs(dx)),height:Math.max(1,Math.abs(dy))};
  if(g.mode==="resize")surface.previewSize(g.element!.source.id,f.width,f.height);
  const attrs=shape.tagName==="ellipse"?{cx:f.x+f.width/2,cy:f.y+f.height/2,rx:f.width/2,ry:f.height/2}:{x:f.x,y:f.y,width:f.width,height:f.height};
  for(const [key,value]of Object.entries(attrs))shape.setAttribute(key,String(value));
  shape.setAttribute("fill","#496d8710");shape.setAttribute("stroke","#496d87");shape.setAttribute("stroke-width",String(1.5/camera.scale));selection.append(shape);
}
async function finishGesture(event:PointerEvent,cancel=false){
  if(ink.pointer===event.pointerId){
    try{
      const values=cancel?undefined:ink.finish(event);
      if(paper.hasPointerCapture(event.pointerId))paper.releasePointerCapture(event.pointerId);
      session.suspended=false;
      if(!values){ink.clear();void session.refresh();return;}
      if(session.address().target.kind==="page")delete (values as {worldOrigin?:unknown}).worldOrigin;
      if(!await save(mutation("Штрих ручки",operation("appendInkStroke",crypto.randomUUID(),values))))ink.clear();
    }catch(error){ink.clear();session.suspended=false;session.onError(error instanceof Error?error.message:String(error),null);}
    finally{if(!closed)buttons();}
    return;
  }
  const g=gesture;if(!g||g.pointer!==event.pointerId)return;
  if(!cancel)updateGesture(g,event);
  gesture=null;session.suspended=false;buttons();
  if(paper.hasPointerCapture(event.pointerId))paper.releasePointerCapture(event.pointerId);
  const dx=g.shown&&g.mode==="move"?g.shown.x-g.frame!.x:g.last.x-g.start.x;
  const dy=g.shown&&g.mode==="move"?g.shown.y-g.frame!.y:g.last.y-g.start.y;
  if(cancel||g.mode==="pan"||Math.hypot(dx,dy)<2/camera.scale){surface.clearPreview();void session.refresh();return;}
  if(g.card){
    await save(mutation("Переместить карточку",operation("moveItem",g.card.item.id,{center:geometry.offset(g.card.center,dx,dy)}),undefined,g.card));
  }else if(g.mode==="move"||g.mode==="resize"){
    const source=g.element!.source;
    const frame={...source.frame};const values:Record<string,unknown>={frame};
    if(g.mode==="resize"){
      if(!g.shown){surface.clearPreview();return;}
      frame.width=g.shown.width;
      if(source.kind!=="nativeText")frame.height=g.shown.height;
    }
    else if(source.worldOrigin)values.worldOrigin=geometry.offset(source.worldOrigin,dx,dy);
    else{frame.x+=dx;frame.y+=dy;}
    await save(mutation(g.mode==="move"?"Переместить элемент":"Изменить размер",operation("updateElement",source.id,values),g.element));
  }else{
    const id=crypto.randomUUID();const width=Math.max(20,Math.abs(dx)),height=Math.max(20,Math.abs(dy));
    const frame={x:Math.min(g.start.x,g.last.x),y:Math.min(g.start.y,g.last.y),width,height};
    const graphic:Record<string,unknown>={shape:tool,style:{stroke:{red:.12,green:.12,blue:.12},strokeWidth:2},label:"",representation:"geometry",visible:true,sourceInkIDs:[]};
    if(tool==="connector")graphic.connection={start:{point:{x:g.start.x-frame.x,y:g.start.y-frame.y}},end:{point:{x:g.last.x-frame.x,y:g.last.y-frame.y}},bend:0,startArrowhead:"none",endArrowhead:"arrow",labelPosition:.5,routing:"straight"};
    const values:Record<string,unknown>={kind:"graphic",source:"",frame,graphic};if(session.snapshot?.worldOrigin)values.worldOrigin=session.snapshot.worldOrigin;
    selectTool("select");
    if(await save(mutation("Добавить фигуру",operation("insertElement",id,values))))choose({kind:"element",id});
  }
}
paper.addEventListener("pointerup",event=>{void finishGesture(event);},events);
paper.addEventListener("pointercancel",event=>{void finishGesture(event,true);},events);
paper.addEventListener("lostpointercapture",event=>{
  // A newer contact can reuse the same pointer ID before an old release is
  // observed. Only the contact which no longer owns capture is cancelled.
  if(!paper.hasPointerCapture(event.pointerId))void finishGesture(event,true);
},events);
async function openCard(id:string){
  if(ink.hasPreview||gesture||session.busy||session.hasPending||!(await finishEditor())||closed)return;
  const card=session.snapshot?.cards.find(c=>c.item.id===id);if(!card)return;
  const target:PanelTarget|undefined=card.item.kind==="board"?{kind:"board",id}:
    card.item.kind==="notebook"&&typeof card.item.firstPageID==="string"?{kind:"page",id:card.item.firstPageID}:undefined;
  if(!target){session.onError("Просмотр этого документа в панели пока недоступен.",null);return;}
  const previous={target:session.address().target,camera:{...worldCamera,center:{...worldCamera.center}},selection:selected};
  if(await session.openSurface(target))path.push(previous);buttons();
}
paper.addEventListener("dblclick",event=>{
  // Pointer capture delivers click events to the canvas. Resolve the actual
  // hit under the pointer, including cards while the hand tool is active.
  const target=paper.ownerDocument.elementFromPoint(event.clientX,event.clientY);
  const card=target?.closest("[data-card-id]")?.getAttribute("data-card-id");
  if(card){event.preventDefault();choose({kind:"item",id:card});void openCard(card);return;}
  const elementID=target?.closest("[data-element-id]")?.getAttribute("data-element-id");
  const element=session.snapshot?.elements.find(value=>value.source.id===elementID);
  if(element&&!session.busy&&!session.hasPending){event.preventDefault();choose({kind:"element",id:element.source.id});openEditor(element);}
},events);
paper.addEventListener("wheel",event=>{
  if(draft||gesture||ink.pointer!==undefined||!session.hasAppearance)return;event.preventDefault();
  if(event.ctrlKey||event.metaKey){const bounds=paper.getBoundingClientRect();zoom(Math.exp(-event.deltaY*.008),{x:event.clientX-bounds.left,y:event.clientY-bounds.top});}
  else{session.beginCameraInteraction();publishCamera(transformPanelCamera(geometry,worldCamera,viewport(),{x:0,y:0},{x:-event.deltaX,y:-event.deltaY},1));}
},{passive:false,...events});
function zoom(factor:number,point:Point={x:workspace.clientWidth/2,y:workspace.clientHeight/2}){
  if(closed||ink.pointer!==undefined||!session.hasAppearance)return;
  session.beginCameraInteraction();
  publishCamera(transformPanelCamera(geometry,worldCamera,viewport(),point,point,factor));
}
function toolButtons(){document.querySelectorAll<HTMLButtonElement>("[data-tool]").forEach(button=>button.setAttribute("aria-pressed",String(button.dataset.tool===tool)));buttons();}
function canChooseTool(next:string){return !closed&&session.hasAppearance&&!gesture&&ink.pointer===undefined&&(next!=="pen"||ink.ready);}
function selectTool(next:string){++toolIntent;tool=next;toolButtons();}
async function requestTool(next:string){
  if(!canChooseTool(next))return;
  const intent=++toolIntent;
  if(!(await finishEditor())||intent!==toolIntent||!canChooseTool(next))return;
  selectTool(next);workspace.focus();
}
document.querySelectorAll<HTMLButtonElement>("[data-tool]").forEach(button=>{
  // One pointer activation finishes the draft at click. Moving focus first
  // could save on blur, then retry a fast refusal as a second automatic write.
  button.addEventListener("pointerdown",event=>{if(event.button===0&&draft)event.preventDefault();},events);
  button.addEventListener("click",()=>{
    if(!canChooseTool(button.dataset.tool!))return;
    void requestTool(button.dataset.tool!);button.focus();
  },events);
});
async function remove(){if(!session.mutationReady)return;const element=active();if(ink.pointer===undefined&&element&&canEdit(element)&&!draft)await save(mutation("Удалить элемент",operation("removeElement",element.source.id,{}),element));}
el("delete").addEventListener("click",()=>{void remove();},events);
el("undo").addEventListener("click",()=>{if(ink.pointer===undefined)void session.undo().catch(()=>{});},events);
el("zoom-in").addEventListener("click",()=>zoom(1.2),events);el("zoom-out").addEventListener("click",()=>zoom(1/1.2),events);
el("zoom-fit").addEventListener("click",()=>{void(async()=>{const frame=await session.requestFit();if(!frame||closed)return;const bounds=cameraScaleBounds();setCamera(surface.fit(bounds.min,bounds.max,frame));})();},events);
el("back").addEventListener("click",()=>{void(async()=>{if(ink.hasPreview||gesture||!(await finishEditor())||closed)return;
  const place=path.at(-1),target=place?.target??session.snapshot?.navigation?.parentBoard;
  if(target&&await session.openSurface(target,place?.camera)&&place){path.pop();choose(place.selection);}buttons();})();},events);
async function stepPage(direction:number){if(ink.hasPreview||gesture||!(await finishEditor())||closed)return;const target=neighbor(direction);if(target)await session.openSurface(target);if(!closed)buttons();}
el("page-previous").addEventListener("click",()=>{void stepPage(-1);},events);
el("page-next").addEventListener("click",()=>{void stepPage(1);},events);
const handleShortcut=(event:KeyboardEvent)=>{
  if(event.target===editor||event.isComposing)return;
  if(event.currentTarget===controls&&(event.key==="Enter"||event.key===" "))return;
  const card=(event.target as Element).closest("[data-card-id]")?.getAttribute("data-card-id");
  if(card&&event.key==="Enter"){event.preventDefault();void openCard(card);return;}
  if(card&&event.key===" "){event.preventDefault();choose({kind:"item",id:card});return;}
  if(event.code==="Space"){space=true;buttons();event.preventDefault();}
  if(event.key==="Escape"){event.preventDefault();cancelGesture();choose(null);selectTool("select");}
  if(event.key==="Delete"||event.key==="Backspace"){event.preventDefault();void remove();}
  if(event.key.toLowerCase()==="z"&&(event.metaKey||event.ctrlKey)&&!event.shiftKey){event.preventDefault();if(ink.pointer===undefined)void session.undo().catch(()=>{});}
  if(event.key==="Enter"){if(activeCard()){event.preventDefault();void openCard(activeCard()!.item.id);}else if(active())openEditor(active()!);}
  if(!event.metaKey&&!event.ctrlKey&&!event.altKey){const key=event.key.toLowerCase(),next=({v:"select",h:"hand",p:"pen",t:"text",r:"rectangle",o:"ellipse",a:"connector"} as Record<string,string>)[key];if(next)void requestTool(next);}
};
workspace.addEventListener("keydown",handleShortcut,events);
controls.addEventListener("keydown",handleShortcut,events);
function cancelGesture(refresh=true){
  const pointer=ink.pointer;
  if(pointer!==undefined){if(paper.hasPointerCapture(pointer))paper.releasePointerCapture(pointer);ink.clear();session.suspended=false;if(refresh)void session.refresh();}
  const g=gesture;if(!g)return;gesture=null;session.suspended=false;if(paper.hasPointerCapture(g.pointer))paper.releasePointerCapture(g.pointer);surface.clearPreview();buttons();if(refresh)void session.refresh();
}
window.addEventListener("keyup",event=>{if(event.code==="Space"){space=false;buttons();}},events);
window.addEventListener("blur",()=>{space=false;cancelGesture();buttons();},events);
const resizeObserver=new ResizeObserver(()=>{
  if(closed)return;
  if(ink.pointer!==undefined)cancelGesture();
  // A resized viewport changes the local origin. Cancel an unfinished geometry
  // preview before its captured anchor can become a false movement delta.
  if(gesture&&gesture.mode!=="pan"){
    const pointer=gesture.pointer;gesture=null;session.suspended=false;
    if(paper.hasPointerCapture(pointer))paper.releasePointerCapture(pointer);
    surface.clearPreview();
  }
  setCamera(camera);
  if(gesture?.mode==="pan"){
    // A viewport change starts a new coordinate basis at the last measured
    // contact. Subsequent samples retain the current center and admitted scale.
    gesture.camera=worldCamera;gesture.viewport=viewport();gesture.client=gesture.lastClient;
  }
  if(draft)positionEditor(draft.element,draft.isNew);
});
resizeObserver.observe(workspace);
function observeDisplayScale(){
  window.matchMedia(`(resolution: ${window.devicePixelRatio}dppx)`).addEventListener("change",()=>{
    if(closed)return;
    setCamera(camera);observeDisplayScale();
  },{once:true,signal:lifetime.signal});
}
observeDisplayScale();
void session.connect().catch(error=>session.onError(error instanceof Error?error.message:String(error),null));

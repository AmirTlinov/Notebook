import { NotebookSession } from "./session.js";
import { Surface, editable } from "./surface.js";
import { panelProjection } from "./projection.js";
import { offsetWorld, TILE_SIZE } from "../src/spatial.js";
import { capturedSource, type Camera, type Frame, type PanelElement, type PanelMutation, type PanelOperation, type PanelCard, type PanelSelection, type Point, type PanelTarget, type PanelView } from "./model.js";

const el=<T extends HTMLElement>(id:string)=>document.getElementById(id) as T;
const workspace=el<HTMLElement>("workspace");
const paper=document.getElementById("paper") as unknown as SVGSVGElement;
const material=document.getElementById("material") as unknown as SVGGElement;
const selection=document.getElementById("selection") as unknown as SVGGElement;
const editor=el<HTMLTextAreaElement>("text-editor");
const session=new NotebookSession();
const surface=new Surface(paper,material,selection);
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
type Gesture={pointer:number;start:Point;last:Point;client:Point;mode:"pan"|"move"|"resize"|"create";element?:PanelElement;card?:PanelCard;subject?:PanelSelection;frame?:Frame};
let gesture:Gesture|null=null;
const path:{target:PanelTarget;camera:NonNullable<PanelView["camera"]>;selection:PanelSelection|null}[]=[];
const worldDelta=(a:NonNullable<typeof session.snapshot>["worldOrigin"],b:NonNullable<typeof session.snapshot>["worldOrigin"]):Point=>a&&b?
  {x:(a.tileX-b.tileX)*TILE_SIZE+a.localX-b.localX,y:(a.tileY-b.tileY)*TILE_SIZE+a.localY-b.localY}:{x:0,y:0};
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
  const waiting=!session.mutationReady;
  el<HTMLButtonElement>("delete").disabled=!active()||!canEdit(active()!)||waiting;
  el<HTMLButtonElement>("undo").disabled=!session.snapshot?.history.undoActionID||waiting;
  editor.readOnly=waiting;
  document.querySelectorAll<HTMLButtonElement>("[data-tool]").forEach(button=>button.disabled=button.dataset.tool==="hand"?!session.hasAppearance||!!draft||!!gesture:waiting||!!gesture);
  el<HTMLButtonElement>("back").hidden=path.length===0&&!session.snapshot?.navigation?.parentBoard;
  el<HTMLButtonElement>("back").disabled=waiting;
  for(const id of ["zoom-in","zoom-out","zoom-fit"])el<HTMLButtonElement>(id).disabled=!session.hasAppearance||!!draft||!!gesture;
  const navigation=session.snapshot?.navigation;
  el("page-navigation").hidden=session.snapshot?.target.kind!=="page"||!navigation?.directory||!navigation.position;
  el("page-position").textContent=navigation?.position&&navigation.directory?`${navigation.position.index+1} / ${navigation.directory.header.item.pageCount}`:"";
  el<HTMLButtonElement>("page-previous").disabled=waiting||!neighbor(-1);
  el<HTMLButtonElement>("page-next").disabled=waiting||!neighbor(1);
  el("zoom-level").textContent=`${Math.round(camera.scale*100)}%`;
  workspace.dataset.tool=tool;workspace.dataset.pan=String(gesture?.mode==="pan"||space);
}
function cameraScaleBounds(){
  const ratio=Math.min(1,2048/Math.max(1,workspace.clientWidth),2048/Math.max(1,workspace.clientHeight));
  return {min:.0125/ratio,max:4/ratio};
}
function setCamera(next:Camera){
  const bounds=cameraScaleBounds(),scale=Math.max(bounds.min,Math.min(bounds.max,next.scale));
  const center=next===camera?worldCamera.center:offsetWorld(session.snapshot?.worldOrigin??worldCamera.center,
    next.x+workspace.clientWidth/(2*next.scale),next.y+workspace.clientHeight/(2*next.scale));
  worldCamera={center,scale};
  surface.setCamera(camera);if(draft)positionEditor(draft.element,draft.isNew);buttons();session.viewportChanged();
}
function mutation(summary:string,operation:PanelOperation,element?:PanelElement,card?:PanelCard):PanelMutation {
  return {...session.address(),actionID:crypto.randomUUID(),summary,operations:[operation],
    sources:[card?.source??(element?capturedSource(session.address().target,element.source):{id:operation.id})]};
}
async function save(request:PanelMutation){
  try{await session.save(request);return true;}catch{surface.clearPreview();return false;}finally{buttons();}
}
session.bounds=()=>session.snapshot?.worldOrigin?{anchor:session.snapshot.worldOrigin,
  region:{x:camera.x,y:camera.y,width:Math.max(1,workspace.clientWidth/camera.scale),height:Math.max(1,workspace.clientHeight/camera.scale)}}:undefined;
session.knownAssets=()=>surface.assetIDs;
session.needsPresentation=()=>!surface.covers(session.bounds(),session.view(false));
session.view=(navigation,restoredCamera)=>{
  const supplied=restoredCamera??(!navigation&&session.hasAppearance&&session.snapshot?.worldOrigin?worldCamera:undefined);
  return panelProjection(workspace.clientWidth,workspace.clientHeight,window.devicePixelRatio,
    supplied,!navigation&&session.hasAppearance);
};
session.onPrepareSnapshot=(snapshot,view)=>surface.prepare(snapshot,view);
session.onClose=()=>surface.dispose();
let first=true;
let priorTarget:string|undefined;
session.onSnapshot=snapshot=>{
  const address=`${snapshot.target.kind}:${snapshot.target.id}`;
  if(priorTarget!==address){first=true;selected=null;priorTarget=address;}
  surface.render(snapshot);
  if(first){
    const appearance=snapshot.appearance!;
    const scale=appearance.camera.scale*workspace.clientWidth/appearance.viewport.x;
    worldCamera={center:appearance.camera.center,scale};first=false;
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
session.onStatus=text=>{el("status").textContent=text;buttons();};
session.onError=(message,action)=>{
  const box=el("message");box.hidden=!message;box.querySelector("span")!.textContent=message;
  retry=action;el<HTMLButtonElement>("retry").hidden=!action;
  buttons();
};
el("retry").addEventListener("click",()=>{void retry?.().catch(()=>{});});

function operation(kind:PanelOperation["kind"],id:string,values:Record<string,unknown>):PanelOperation {
  return {kind,target:session.address().target,id,values};
}
function newElement(point:Point,kind:string):PanelElement {
  return {source:{id:crypto.randomUUID(),kind,source:"",...(session.snapshot?.worldOrigin?{worldOrigin:session.snapshot.worldOrigin}:{}),frame:{...point,width:240,height:90},
    textStyle:{fontSize:24,weight:.4,red:.1,green:.1,blue:.1,alpha:1}}};
}
function openEditor(element:PanelElement,isNew=false){
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
async function finishEditor(cancel=false):Promise<boolean>{
  const captured=draft;if(!captured)return true;
  if(session.busy||session.hasPending)return false;
  if(cancel){if(!captured.isNew)surface.hideSubject(captured.element.source.id,false);draft=null;editor.hidden=true;session.suspended=false;await session.refresh();workspace.focus();return true;}
  const value=editor.value,element=captured.element;
  if(captured.isNew&&!value.trim())return finishEditor(true);
  const previous=element.source.kind==="nativeText"?element.source.source:String(element.source.graphic?.label??"");
  if(!captured.isNew&&value===previous)return finishEditor(true);
  const values:Record<string,unknown>=element.source.kind==="nativeText"?{source:value}:{graphic:{label:value}};
  if(element.source.kind==="nativeText")values.frame={...element.source.frame,
    height:Math.max(element.source.frame.height,editor.scrollHeight/camera.scale)};
  if(captured.isNew){
    Object.assign(values,{kind:"nativeText",textStyle:element.source.textStyle});
    if(element.source.worldOrigin)values.worldOrigin=element.source.worldOrigin;
  }
  const request=mutation("Изменить текст",operation(captured.isNew?"insertElement":"updateElement",element.source.id,values),captured.isNew?undefined:element);
  try{
    await session.save(request);draft=null;editor.hidden=true;session.suspended=false;
    await session.refresh();choose({kind:"element",id:element.source.id});workspace.focus();return true;
  }catch{
    session.suspended=false;await session.refresh();
    const current=session.snapshot?.elements.find(e=>e.source.id===element.source.id);
    if(current&&!captured.isNew){draft={element:current,isNew:false};session.onError("Элемент изменился. Ваш текст остался в редакторе; проверьте его и сохраните ещё раз.",null);}
    editor.focus();return false;
  }
}
editor.addEventListener("keydown",event=>{
  if(event.key==="Escape"){event.preventDefault();void finishEditor(true);}
  if(event.key==="Enter"&&(event.metaKey||event.ctrlKey)){event.preventDefault();void finishEditor();}
});
editor.addEventListener("blur",()=>{if(draft)void finishEditor();});

paper.addEventListener("pointerdown",event=>{
  if(!session.snapshot||!session.hasAppearance||event.button===2||gesture)return;
  const target=event.target as Element,resizing=target.hasAttribute("data-resize-handle");
  const itemID=target.closest("[data-card-id]")?.getAttribute("data-card-id");
  const elementID=target.closest("[data-element-id]")?.getAttribute("data-element-id");
  const subject:PanelSelection|null=resizing?selected:itemID?{kind:"item",id:itemID}:elementID?{kind:"element",id:elementID}:null;
  const wantsPan=tool==="hand"||space||event.button===1||event.altKey||(tool==="select"&&!subject);
  if(!wantsPan&&!session.mutationReady)return;
  if(draft){void finishEditor();if(!wantsPan)return;}
  const point=surface.point(event.clientX,event.clientY);
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
  gesture={pointer:event.pointerId,start:point,last:point,client:{x:event.clientX,y:event.clientY},mode,
    ...(subject?{subject}:{}),...(card?{card}:{}),...(element?{element,
      frame:mode==="resize"&&element.source.kind==="nativeText"?surface.authoredFrame(element):surface.frame(element)}:{})};
  session.suspended=mode!=="pan";paper.setPointerCapture(event.pointerId);workspace.focus();buttons();event.preventDefault();
});
paper.addEventListener("pointermove",event=>{
  if(!gesture||event.pointerId!==gesture.pointer)return;
  const point=surface.point(event.clientX,event.clientY);gesture.last=point;
  const dx=point.x-gesture.start.x,dy=point.y-gesture.start.y;
  if(gesture.mode==="pan"){
    // A newly accepted projection may rebase the world origin mid-pan.
    // Screen deltas remain valid across that rebase and never rewind the gesture.
    setCamera({...camera,x:camera.x-(event.clientX-gesture.client.x)/camera.scale,
      y:camera.y-(event.clientY-gesture.client.y)/camera.scale});
    gesture.client={x:event.clientX,y:event.clientY};
  }else if(gesture.mode==="move")surface.preview(gesture.subject!,dx,dy);
  else drawGesture(gesture,dx,dy);
});
function drawGesture(g:Gesture,dx:number,dy:number){
  selection.replaceChildren();
  const shape=document.createElementNS("http://www.w3.org/2000/svg",tool==="ellipse"&&g.mode==="create"?"ellipse":"rect");
  const textWidth=g.mode==="resize"&&g.element!.source.kind==="nativeText";
  const f=g.mode==="resize"?{...g.frame!,width:Math.max(20,g.frame!.width+dx),height:textWidth?g.frame!.height:Math.max(20,g.frame!.height+dy)}:
    {x:Math.min(g.start.x,g.start.x+dx),y:Math.min(g.start.y,g.start.y+dy),width:Math.max(1,Math.abs(dx)),height:Math.max(1,Math.abs(dy))};
  if(g.mode==="resize")surface.previewSize(g.element!.source.id,f.width,f.height);
  const attrs=shape.tagName==="ellipse"?{cx:f.x+f.width/2,cy:f.y+f.height/2,rx:f.width/2,ry:f.height/2}:{x:f.x,y:f.y,width:f.width,height:f.height};
  for(const [key,value]of Object.entries(attrs))shape.setAttribute(key,String(value));
  shape.setAttribute("fill","#496d8710");shape.setAttribute("stroke","#496d87");shape.setAttribute("stroke-width",String(1.5/camera.scale));selection.append(shape);
}
async function finishGesture(event:PointerEvent,cancel=false){
  const g=gesture;if(!g||g.pointer!==event.pointerId)return;gesture=null;session.suspended=false;buttons();
  if(paper.hasPointerCapture(event.pointerId))paper.releasePointerCapture(event.pointerId);
  const dx=g.last.x-g.start.x,dy=g.last.y-g.start.y;
  if(cancel||g.mode==="pan"||Math.hypot(dx,dy)<2/camera.scale){surface.clearPreview();void session.refresh();return;}
  if(g.card){
    await save(mutation("Переместить карточку",operation("moveItem",g.card.item.id,{center:offsetWorld(g.card.center,dx,dy)}),undefined,g.card));
  }else if(g.mode==="move"||g.mode==="resize"){
    const source=g.element!.source;
    const frame={...source.frame};const values:Record<string,unknown>={frame};
    if(g.mode==="resize"){frame.width=Math.max(20,frame.width+dx);if(source.kind!=="nativeText")frame.height=Math.max(20,frame.height+dy);}
    else if(source.worldOrigin)values.worldOrigin=offsetWorld(source.worldOrigin,dx,dy);
    else{frame.x+=dx;frame.y+=dy;}
    await save(mutation(g.mode==="move"?"Переместить элемент":"Изменить размер",operation("updateElement",source.id,values),g.element));
  }else{
    const id=crypto.randomUUID();const width=Math.max(20,Math.abs(dx)),height=Math.max(20,Math.abs(dy));
    const frame={x:Math.min(g.start.x,g.last.x),y:Math.min(g.start.y,g.last.y),width,height};
    const graphic:Record<string,unknown>={shape:tool,style:{stroke:{red:.12,green:.12,blue:.12},strokeWidth:2},label:"",representation:"geometry",visible:true,sourceInkIDs:[]};
    if(tool==="connector")graphic.connection={start:{point:{x:g.start.x-frame.x,y:g.start.y-frame.y}},end:{point:{x:g.last.x-frame.x,y:g.last.y-frame.y}},bend:0,startArrowhead:"none",endArrowhead:"arrow",labelPosition:.5,routing:"straight"};
    const values:Record<string,unknown>={kind:"graphic",source:"",frame,graphic};if(session.snapshot?.worldOrigin)values.worldOrigin=session.snapshot.worldOrigin;
    if(await save(mutation("Добавить фигуру",operation("insertElement",id,values)))){tool="select";toolButtons();choose({kind:"element",id});}
  }
}
paper.addEventListener("pointerup",event=>{void finishGesture(event);});
paper.addEventListener("pointercancel",event=>{void finishGesture(event,true);});
async function openCard(id:string){
  if(session.busy||session.hasPending||!(await finishEditor()))return;
  const card=session.snapshot?.cards.find(c=>c.item.id===id);if(!card)return;
  const target:PanelTarget|undefined=card.item.kind==="board"?{kind:"board",id}:
    card.item.kind==="notebook"&&typeof card.item.firstPageID==="string"?{kind:"page",id:card.item.firstPageID}:undefined;
  if(!target){session.onError("Этот документ пока открывается в приложении Notebook. Агент может работать с ним через инструменты плагина.",null);return;}
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
});
paper.addEventListener("wheel",event=>{
  if(draft||gesture||!session.hasAppearance)return;event.preventDefault();
  if(event.ctrlKey||event.metaKey){const point=surface.point(event.clientX,event.clientY);zoom(Math.exp(-event.deltaY*.008),point);}
  else setCamera({...camera,x:camera.x+event.deltaX/camera.scale,y:camera.y+event.deltaY/camera.scale});
},{passive:false});
function zoom(factor:number,point:Point={x:camera.x+workspace.clientWidth/camera.scale/2,y:camera.y+workspace.clientHeight/camera.scale/2}){
  const bounds=cameraScaleBounds();
  const scale=Math.min(bounds.max,Math.max(bounds.min,camera.scale*factor));
  setCamera({x:point.x-(point.x-camera.x)*camera.scale/scale,y:point.y-(point.y-camera.y)*camera.scale/scale,scale});
}
function toolButtons(){document.querySelectorAll<HTMLButtonElement>("[data-tool]").forEach(button=>button.setAttribute("aria-pressed",String(button.dataset.tool===tool)));buttons();}
document.querySelectorAll<HTMLButtonElement>("[data-tool]").forEach(button=>button.addEventListener("click",()=>{void(async()=>{if(await finishEditor()){tool=button.dataset.tool!;toolButtons();workspace.focus();}})();}));
async function remove(){const element=active();if(element&&canEdit(element)&&!draft)await save(mutation("Удалить элемент",operation("removeElement",element.source.id,{}),element));}
el("delete").addEventListener("click",()=>{void remove();});
el("undo").addEventListener("click",()=>{void session.undo().catch(()=>{});});
el("zoom-in").addEventListener("click",()=>zoom(1.2));el("zoom-out").addEventListener("click",()=>zoom(1/1.2));
el("zoom-fit").addEventListener("click",()=>{void(async()=>{const frame=await session.requestFit();if(!frame)return;const bounds=cameraScaleBounds();setCamera(surface.fit(bounds.min,bounds.max,frame));})();});
el("back").addEventListener("click",()=>{void(async()=>{if(!(await finishEditor()))return;
  const place=path.at(-1),target=place?.target??session.snapshot?.navigation?.parentBoard;
  if(target&&await session.openSurface(target,place?.camera)&&place){path.pop();choose(place.selection);}buttons();})();});
async function stepPage(direction:number){if(!(await finishEditor()))return;const target=neighbor(direction);if(target)await session.openSurface(target);buttons();}
el("page-previous").addEventListener("click",()=>{void stepPage(-1);});
el("page-next").addEventListener("click",()=>{void stepPage(1);});
workspace.addEventListener("keydown",event=>{
  if(event.target===editor)return;
  const card=(event.target as Element).closest("[data-card-id]")?.getAttribute("data-card-id");
  if(card&&event.key==="Enter"){event.preventDefault();void openCard(card);return;}
  if(card&&event.key===" "){event.preventDefault();choose({kind:"item",id:card});return;}
  if(event.code==="Space"){space=true;buttons();event.preventDefault();}
  if(event.key==="Escape"){event.preventDefault();cancelGesture();choose(null);tool="select";toolButtons();}
  if(event.key==="Delete"||event.key==="Backspace"){event.preventDefault();void remove();}
  if(event.key.toLowerCase()==="z"&&(event.metaKey||event.ctrlKey)&&!event.shiftKey){event.preventDefault();void session.undo().catch(()=>{});}
  if(event.key==="Enter"){if(activeCard()){event.preventDefault();void openCard(activeCard()!.item.id);}else if(active())openEditor(active()!);}
  if(!event.metaKey&&!event.ctrlKey&&!event.altKey){const key=event.key.toLowerCase(),next=({v:"select",h:"hand",t:"text",r:"rectangle",o:"ellipse",a:"connector"} as Record<string,string>)[key];if(next&&!gesture){tool=next;toolButtons();}}
});
function cancelGesture(){const g=gesture;if(!g)return;gesture=null;session.suspended=false;if(paper.hasPointerCapture(g.pointer))paper.releasePointerCapture(g.pointer);surface.clearPreview();buttons();void session.refresh();}
window.addEventListener("keyup",event=>{if(event.code==="Space"){space=false;buttons();}});
window.addEventListener("blur",()=>{space=false;cancelGesture();buttons();});
new ResizeObserver(()=>{
  // A resized viewport changes the local origin. Cancel an unfinished geometry
  // preview before its captured anchor can become a false movement delta.
  if(gesture&&gesture.mode!=="pan"){
    const pointer=gesture.pointer;gesture=null;session.suspended=false;
    if(paper.hasPointerCapture(pointer))paper.releasePointerCapture(pointer);
    surface.clearPreview();
  }
  setCamera(camera);
  if(draft)positionEditor(draft.element,draft.isNew);
}).observe(workspace);
function observeDisplayScale(){
  window.matchMedia(`(resolution: ${window.devicePixelRatio}dppx)`).addEventListener("change",()=>{
    setCamera(camera);observeDisplayScale();
  },{once:true});
}
observeDisplayScale();
void session.connect().catch(error=>session.onError(error instanceof Error?error.message:String(error),null));

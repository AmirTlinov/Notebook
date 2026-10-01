import { NotebookSession } from "./session.js";
import { Surface, editable } from "./surface.js";
import { offsetWorld, TILE_SIZE } from "../src/spatial.js";
import { capturedSource, type Camera, type Frame, type PanelElement, type PanelMutation, type PanelOperation, type Point, type PanelTarget } from "./model.js";

const el=<T extends HTMLElement>(id:string)=>document.getElementById(id) as T;
const workspace=el<HTMLElement>("workspace");
const paper=document.getElementById("paper") as unknown as SVGSVGElement;
const material=document.getElementById("material") as unknown as SVGGElement;
const selection=document.getElementById("selection") as unknown as SVGGElement;
const editor=el<HTMLTextAreaElement>("text-editor");
const session=new NotebookSession();
const surface=new Surface(paper,material,selection);
let camera:Camera={x:0,y:0,scale:1};
let selected:string|null=null;
let tool="select",space=false;
let retry:(()=>Promise<void>)|null=null;
let draft:{element:PanelElement;isNew:boolean}|null=null;
type Gesture={pointer:number;start:Point;last:Point;mode:"pan"|"move"|"resize"|"create";element?:PanelElement;frame?:Frame;camera:Camera};
let gesture:Gesture|null=null;
const path:PanelTarget[]=[];
const worldDelta=(a:NonNullable<typeof session.snapshot>["worldOrigin"],b:NonNullable<typeof session.snapshot>["worldOrigin"]):Point=>a&&b?
  {x:(a.tileX-b.tileX)*TILE_SIZE+a.localX-b.localX,y:(a.tileY-b.tileY)*TILE_SIZE+a.localY-b.localY}:{x:0,y:0};
function choose(id:string|null){selected=id;surface.select(id);buttons();session.context(id);}
function active(){return session.snapshot?.elements.find(e=>e.source.id===selected);}
function canEdit(element:PanelElement){return editable(element)&&!session.snapshot?.unsupportedElements.some(e=>e.id===element.source.id);}
function canMove(element:PanelElement){return canEdit(element)&&!element.source.graphic?.connection?.start?.binding&&!element.source.graphic?.connection?.end?.binding;}
function buttons(){
  const waiting=session.busy||session.hasPending;
  el<HTMLButtonElement>("delete").disabled=!active()||!canEdit(active()!)||waiting;
  el<HTMLButtonElement>("undo").disabled=!session.snapshot?.history.undoActionID||waiting;
  editor.readOnly=waiting;
  document.querySelectorAll<HTMLButtonElement>("[data-tool]").forEach(button=>button.disabled=waiting);
  el<HTMLButtonElement>("back").hidden=path.length===0;
  el<HTMLButtonElement>("back").disabled=waiting;
  el<HTMLButtonElement>("zoom-fit").textContent=`${Math.round(camera.scale*100)}%`;
}
function setCamera(next:Camera){camera=next;surface.setCamera(camera);buttons();session.viewportChanged();}
function mutation(summary:string,operation:PanelOperation,element?:PanelElement):PanelMutation {
  return {...session.address(),actionID:crypto.randomUUID(),summary,operations:[operation],
    sources:[element?capturedSource(session.address().target,element.source):{id:operation.id}]};
}
async function save(request:PanelMutation){
  try{await session.save(request);}catch{}finally{buttons();}
}
session.bounds=()=>session.snapshot?.worldOrigin?{anchor:session.snapshot.worldOrigin,
  region:{x:camera.x,y:camera.y,width:Math.max(1,workspace.clientWidth/camera.scale),height:Math.max(1,workspace.clientHeight/camera.scale)}}:undefined;
let priorOrigin:NonNullable<typeof session.snapshot>["worldOrigin"]=null;
let first=true;
let priorTarget:string|undefined;
session.onSnapshot=snapshot=>{
  if(gesture||draft)return;
  if(priorTarget!==snapshot.target.id){first=true;selected=null;priorTarget=snapshot.target.id;}
  const delta=worldDelta(snapshot.worldOrigin,priorOrigin);priorOrigin=snapshot.worldOrigin;
  surface.render(snapshot);
  if(first){camera=surface.fit();first=false;}else{camera={...camera,x:camera.x-delta.x,y:camera.y-delta.y};}
  surface.setCamera(camera);
  el("surface-name").textContent=snapshot.target.kind==="board"?"Доска":"Лист";
  if(selected&&!snapshot.elements.some(e=>e.source.id===selected))selected=null;
  surface.select(selected);buttons();session.context(selected);
  const notes=[];
  if(snapshot.rawInkPresent)notes.push("Рукописный слой доступен в Notebook на iPad.");
  if(snapshot.truncated)notes.push("Видимая область содержит больше объектов. Приблизьте нужный участок.");
  el("coverage").textContent=notes.join(" ");
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
  return {source:{id:crypto.randomUUID(),kind,source:"",frame:{...point,width:240,height:90},
    textStyle:{fontSize:24,weight:.4,red:.1,green:.1,blue:.1,alpha:1}}};
}
function openEditor(element:PanelElement,isNew=false){
  if(!isNew&&!canEdit(element))return;
  draft={element,isNew};session.suspended=true;
  const frame=isNew?element.source.frame:surface.frame(element);
  editor.value=element.source.kind==="nativeText"?element.source.source:String(element.source.graphic?.label??"");
  editor.style.left=`${(frame.x-camera.x)*camera.scale}px`;
  editor.style.top=`${(frame.y-camera.y)*camera.scale}px`;
  editor.style.width=`${Math.max(120,frame.width*camera.scale)}px`;
  editor.style.height=`${Math.max(60,frame.height*camera.scale)}px`;
  const fontSize=element.source.kind==="nativeText"?element.source.textStyle?.fontSize??34:24;
  const weight=element.source.kind==="nativeText"?element.source.textStyle?.weight??.45:.3;
  editor.style.fontSize=`${fontSize*camera.scale}px`;
  editor.style.fontWeight=String(weight<.2?300:weight<.4?400:weight<.6?500:weight<.8?600:700);
  editor.hidden=false;editor.focus();editor.select();
}
async function finishEditor(cancel=false):Promise<boolean>{
  const captured=draft;if(!captured)return true;
  if(session.busy||session.hasPending)return false;
  if(cancel){draft=null;editor.hidden=true;session.suspended=false;await session.refresh(true);workspace.focus();return true;}
  const value=editor.value,element=captured.element;
  if(captured.isNew&&!value.trim())return finishEditor(true);
  const previous=element.source.kind==="nativeText"?element.source.source:String(element.source.graphic?.label??"");
  if(!captured.isNew&&value===previous)return finishEditor(true);
  const values:Record<string,unknown>=element.source.kind==="nativeText"?{source:value}:{graphic:{label:value}};
  if(element.source.kind==="nativeText")values.frame={...element.source.frame,
    height:Math.max(element.source.frame.height,editor.scrollHeight/camera.scale)};
  if(captured.isNew){
    Object.assign(values,{kind:"nativeText",textStyle:element.source.textStyle});
    if(session.snapshot?.worldOrigin)values.worldOrigin=session.snapshot.worldOrigin;
  }
  const request=mutation("Изменить текст",operation(captured.isNew?"insertElement":"updateElement",element.source.id,values),captured.isNew?undefined:element);
  try{
    await session.save(request);draft=null;editor.hidden=true;session.suspended=false;
    await session.refresh(true);choose(element.source.id);workspace.focus();return true;
  }catch{
    session.suspended=false;await session.refresh(true);session.suspended=true;
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
  if(!session.snapshot||session.busy||session.hasPending||event.button===2)return;
  if(draft){void finishEditor();return;}
  const point=surface.point(event.clientX,event.clientY);
  const resizing=(event.target as Element).hasAttribute("data-resize-handle");
  const hit=resizing?selected:(event.target as Element).closest("[data-element-id]")?.getAttribute("data-element-id")??null;
  const element=session.snapshot.elements.find(e=>e.source.id===hit);
  let mode:Gesture["mode"];
  if(space||event.button===1||event.altKey)mode="pan";
  else if(tool==="text"){event.preventDefault();choose(null);openEditor(newElement(point,"nativeText"),true);return;}
  else if(tool!=="select"){mode="create";choose(null);}
  else{
    choose(hit);
    if(!element||!canMove(element)){workspace.focus();return;}
    mode=resizing?"resize":"move";
  }
  gesture={pointer:event.pointerId,start:point,last:point,mode,camera:{...camera},...(element?{element,frame:surface.frame(element)}:{})};
  session.suspended=true;paper.setPointerCapture(event.pointerId);workspace.focus();event.preventDefault();
});
paper.addEventListener("pointermove",event=>{
  if(!gesture||event.pointerId!==gesture.pointer)return;
  const point=surface.point(event.clientX,event.clientY);gesture.last=point;
  const dx=point.x-gesture.start.x,dy=point.y-gesture.start.y;
  if(gesture.mode==="pan"){
    const rect=paper.getBoundingClientRect();
    const sx=(gesture.start.x-gesture.camera.x)*gesture.camera.scale+rect.left;
    const sy=(gesture.start.y-gesture.camera.y)*gesture.camera.scale+rect.top;
    setCamera({...gesture.camera,x:gesture.camera.x-(event.clientX-sx)/gesture.camera.scale,y:gesture.camera.y-(event.clientY-sy)/gesture.camera.scale});
  }else if(gesture.mode==="move")surface.preview(gesture.element!.source.id,dx,dy);
  else drawGesture(gesture,dx,dy);
});
function drawGesture(g:Gesture,dx:number,dy:number){
  selection.replaceChildren();
  const shape=document.createElementNS("http://www.w3.org/2000/svg",tool==="ellipse"&&g.mode==="create"?"ellipse":"rect");
  const f=g.mode==="resize"?{...g.frame!,width:Math.max(20,g.frame!.width+dx),height:Math.max(20,g.frame!.height+dy)}:
    {x:Math.min(g.start.x,g.start.x+dx),y:Math.min(g.start.y,g.start.y+dy),width:Math.max(1,Math.abs(dx)),height:Math.max(1,Math.abs(dy))};
  const attrs=shape.tagName==="ellipse"?{cx:f.x+f.width/2,cy:f.y+f.height/2,rx:f.width/2,ry:f.height/2}:{x:f.x,y:f.y,width:f.width,height:f.height};
  for(const [key,value]of Object.entries(attrs))shape.setAttribute(key,String(value));
  shape.setAttribute("fill","#496d8710");shape.setAttribute("stroke","#496d87");shape.setAttribute("stroke-width",String(1.5/camera.scale));selection.append(shape);
}
async function finishGesture(event:PointerEvent,cancel=false){
  const g=gesture;if(!g||g.pointer!==event.pointerId)return;gesture=null;session.suspended=false;
  if(paper.hasPointerCapture(event.pointerId))paper.releasePointerCapture(event.pointerId);
  const dx=g.last.x-g.start.x,dy=g.last.y-g.start.y;
  if(cancel||g.mode==="pan"||Math.hypot(dx,dy)<2/camera.scale){surface.select(selected);await session.refresh(true);return;}
  if(g.mode==="move"||g.mode==="resize"){
    const source=g.element!.source;
    const frame={...source.frame};const values:Record<string,unknown>={frame};
    if(g.mode==="resize"){frame.width=Math.max(20,frame.width+dx);frame.height=Math.max(20,frame.height+dy);}
    else if(source.worldOrigin)values.worldOrigin=offsetWorld(source.worldOrigin,dx,dy);
    else{frame.x+=dx;frame.y+=dy;}
    await save(mutation(g.mode==="move"?"Переместить элемент":"Изменить размер",operation("updateElement",source.id,values),g.element));
  }else{
    const id=crypto.randomUUID();const width=Math.max(20,Math.abs(dx)),height=Math.max(20,Math.abs(dy));
    const frame={x:Math.min(g.start.x,g.last.x),y:Math.min(g.start.y,g.last.y),width,height};
    const graphic:Record<string,unknown>={shape:tool,style:{stroke:{red:.12,green:.12,blue:.12},strokeWidth:2},label:"",representation:"geometry",visible:true,sourceInkIDs:[]};
    if(tool==="connector")graphic.connection={start:{point:{x:g.start.x-frame.x,y:g.start.y-frame.y}},end:{point:{x:g.last.x-frame.x,y:g.last.y-frame.y}},bend:0,startArrowhead:"none",endArrowhead:"arrow",labelPosition:.5,routing:"straight"};
    const values:Record<string,unknown>={kind:"graphic",source:"",frame,graphic};if(session.snapshot?.worldOrigin)values.worldOrigin=session.snapshot.worldOrigin;
    await save(mutation("Добавить фигуру",operation("insertElement",id,values)));tool="select";toolButtons();choose(id);
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
  path.push(session.address().target);await session.openSurface(target);buttons();
}
paper.addEventListener("dblclick",event=>{
  const card=(event.target as Element).closest("[data-card-id]")?.getAttribute("data-card-id");
  if(card){event.preventDefault();void openCard(card);return;}
  const element=active();if(element&&!session.busy&&!session.hasPending){event.preventDefault();openEditor(element);}
});
paper.addEventListener("wheel",event=>{
  if(draft||gesture)return;event.preventDefault();
  if(event.ctrlKey||event.metaKey){const point=surface.point(event.clientX,event.clientY);zoom(Math.exp(-event.deltaY*.008),point);}
  else setCamera({...camera,x:camera.x+event.deltaX/camera.scale,y:camera.y+event.deltaY/camera.scale});
},{passive:false});
function zoom(factor:number,point:Point={x:camera.x+workspace.clientWidth/camera.scale/2,y:camera.y+workspace.clientHeight/camera.scale/2}){
  const scale=Math.min(8,Math.max(.05,camera.scale*factor));
  setCamera({x:point.x-(point.x-camera.x)*camera.scale/scale,y:point.y-(point.y-camera.y)*camera.scale/scale,scale});
}
function toolButtons(){document.querySelectorAll<HTMLButtonElement>("[data-tool]").forEach(button=>button.setAttribute("aria-pressed",String(button.dataset.tool===tool)));}
document.querySelectorAll<HTMLButtonElement>("[data-tool]").forEach(button=>button.addEventListener("click",()=>{void(async()=>{if(await finishEditor()){tool=button.dataset.tool!;toolButtons();workspace.focus();}})();}));
async function remove(){const element=active();if(element&&canEdit(element)&&!draft)await save(mutation("Удалить элемент",operation("removeElement",element.source.id,{}),element));}
el("delete").addEventListener("click",()=>{void remove();});
el("undo").addEventListener("click",()=>{void session.undo().catch(()=>{});});
el("zoom-in").addEventListener("click",()=>zoom(1.2));el("zoom-out").addEventListener("click",()=>zoom(1/1.2));
el("zoom-fit").addEventListener("click",()=>setCamera(surface.fit()));
el("back").addEventListener("click",()=>{void(async()=>{if(!(await finishEditor()))return;const target=path.pop();if(target)await session.openSurface(target);buttons();})();});
workspace.addEventListener("keydown",event=>{
  if(event.target===editor)return;
  const card=(event.target as Element).closest("[data-card-id]")?.getAttribute("data-card-id");
  if(card&&event.key==="Enter"){event.preventDefault();void openCard(card);return;}
  if(event.code==="Space"){space=true;event.preventDefault();}
  if(event.key==="Escape"){choose(null);tool="select";toolButtons();}
  if(event.key==="Delete"||event.key==="Backspace"){event.preventDefault();void remove();}
  if(event.key.toLowerCase()==="z"&&(event.metaKey||event.ctrlKey)&&!event.shiftKey){event.preventDefault();void session.undo().catch(()=>{});}
  if(event.key==="Enter"&&active())openEditor(active()!);
});
window.addEventListener("keyup",event=>{if(event.code==="Space")space=false;});
window.addEventListener("blur",()=>{space=false;});
new ResizeObserver(()=>{surface.setCamera(camera);session.viewportChanged();}).observe(workspace);
void session.connect().catch(error=>session.onError(error instanceof Error?error.message:String(error),null));

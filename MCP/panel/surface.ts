import type { Camera, Frame, PanelElement, PanelSnapshot, Point, Resolution } from "./model.js";
import type { WorldPoint } from "../src/domain.js";
import { TILE_SIZE } from "../src/spatial.js";

const NS="http://www.w3.org/2000/svg";
const zero:WorldPoint={tileX:0,tileY:0,localX:0,localY:0};
const shapes=new Set(["ellipse","rectangle","triangle","diamond","plus","connector"]);
const finite=(value:unknown,fallback=0):number=>typeof value==="number"&&Number.isFinite(value)?value:fallback;
const clamp=(value:number,min:number,max:number)=>Math.max(min,Math.min(max,value));
const pointValid=(point:Point)=>Number.isFinite(point.x)&&Number.isFinite(point.y);

function appearance(element:PanelElement):string|undefined {
  const value=element.appearance;
  return typeof value==="object"&&value!==null&&"state" in value?String(value.state):undefined;
}

function richText(element:PanelElement):boolean {
  const style=element.source.textStyle as Record<string,unknown>|undefined;
  return element.source.kind==="nativeText"&&(style?.format!=null||(Array.isArray(style?.runs)&&style.runs.length>0));
}

function drawable(element:PanelElement):boolean {
  const graphic=element.source.graphic,resolution=element.graphicResolution;
  if(!graphic||resolution?.state!=="geometry"||!resolution.frame||graphic.visible===false||graphic.representation!=="geometry")return false;
  if(graphic.mask!=null||graphic.freehand!=null||graphic.transform!=null||appearance(element)==="partial")return false;
  if(!shapes.has(String(graphic.shape)))return false;
  if(graphic.vertices&&finite(graphic.cornerRadius)>0)return false;
  if(graphic.shape==="connector"&&(!resolution.curves?.length||!resolution.curves.every(curve=>[curve.start,curve.control1,curve.control2,curve.end].every(pointValid))))return false;
  return true;
}

/** Editing a body needs a surface pose, rather than an unresolved parent pose. */
export function editable(element:PanelElement):boolean {
  if(element.source.parentID!=null||element.source.basis!=null||["erased","partial"].includes(appearance(element)??""))return false;
  if(element.source.kind==="nativeText")return !richText(element);
  if(!drawable(element))return false;
  const connection=element.source.graphic?.connection;
  return !connection?.start?.binding&&!connection?.end?.binding;
}

function delta(point:WorldPoint,origin:WorldPoint):Point {
  return {x:(point.tileX-origin.tileX)*TILE_SIZE+point.localX-origin.localX,
    y:(point.tileY-origin.tileY)*TILE_SIZE+point.localY-origin.localY};
}

function color(value:unknown,fallback="#252525"):string {
  if(typeof value!=="object"||value===null)return fallback;
  const channels=value as Record<string,unknown>;
  return `rgb(${["red","green","blue"].map(key=>Math.round(clamp(finite(channels[key]),0,1)*255)).join(" ")})`;
}

function node<K extends keyof SVGElementTagNameMap>(tag:K,attributes:Record<string,string|number>={}):SVGElementTagNameMap[K] {
  const element=document.createElementNS(NS,tag);
  for(const [name,value] of Object.entries(attributes))element.setAttribute(name,String(value));
  return element;
}

function text(parent:SVGElement,value:string,attributes:Record<string,string|number>):SVGTextElement {
  const element=node("text",attributes);element.textContent=value;parent.append(element);return element;
}

function curvesPath(resolution:Resolution):string {
  let previous:Point|undefined;
  return (resolution.curves??[]).map(curve=>{
    const move=!previous||previous.x!==curve.start.x||previous.y!==curve.start.y?`M ${curve.start.x} ${curve.start.y} `:"";
    previous=curve.end;
    return `${move}C ${curve.control1.x} ${curve.control1.y} ${curve.control2.x} ${curve.control2.y} ${curve.end.x} ${curve.end.y}`;
  }).join(" ");
}

/** Disposable DOM projection of the Mac owner's already resolved surface. */
export class Surface {
  private snapshot:PanelSnapshot|null=null;
  private camera:Camera={x:0,y:0,scale:1};
  private selected:string|null=null;
  private groups=new Map<string,SVGGElement>();
  private frames=new Map<string,Frame>();
  private origins=new Map<string,Point>();
  private unsupported=new Set<string>();
  private measure:CanvasRenderingContext2D|null=document.createElement("canvas").getContext("2d");

  constructor(private svg:SVGSVGElement,private material:SVGGElement,private selection:SVGGElement) {}

  frame(element:PanelElement):Frame {
    const resolved=element.graphicResolution;
    const sourceFrame=resolved?.state==="geometry"&&resolved.frame?resolved.frame:element.source.frame;
    const origin=resolved?.state==="geometry"?resolved.worldOrigin??element.source.worldOrigin:element.source.worldOrigin;
    const offset=delta(origin??zero,this.snapshot?.worldOrigin??zero);
    return {x:finite(sourceFrame.x)+offset.x,y:finite(sourceFrame.y)+offset.y,
      width:Math.max(1,finite(sourceFrame.width,1)),height:Math.max(1,finite(sourceFrame.height,1))};
  }

  render(snapshot:PanelSnapshot):void {
    this.snapshot=snapshot;
    this.unsupported=new Set(snapshot.unsupportedElements.map(element=>element.id));
    this.groups.clear();this.frames.clear();this.origins.clear();
    const content=document.createDocumentFragment();
    if(snapshot.target.kind==="page")content.append(node("rect",{x:0,y:0,width:snapshot.size.width,height:snapshot.size.height,
      fill:"#fff",stroke:"#e4e4e0","stroke-width":1}));
    for(const card of snapshot.cards){
      const position=delta(card.center,snapshot.worldOrigin??zero);
      if(!pointValid(position))continue;
      const frame={x:position.x-110,y:position.y-72,width:220,height:144};
      this.frames.set(`card:${card.item.id}`,frame);
      const group=node("g",{transform:`translate(${frame.x} ${frame.y})`,"data-card-id":card.item.id,class:"readonly",role:"button",tabindex:0,
        "aria-label":`Открыть ${card.item.title}`});
      this.card(group,card.item.title,card.item.kind==="board"?"Доска":card.item.kind==="notebook"?"Тетрадь":"Документ",frame.width,frame.height);
      content.append(group);
    }
    for(const element of snapshot.elements){
      const graphic=element.source.graphic;
      if(appearance(element)==="erased"||graphic?.visible===false||element.graphicResolution?.state==="hidden")continue;
      const frame=this.frame(element);
      if(![frame.x,frame.y,frame.width,frame.height].every(Number.isFinite))continue;
      const group=node("g",{"data-element-id":element.source.id,"data-id":element.source.id,
        transform:`translate(${frame.x} ${frame.y})`,class:editable(element)&&!this.unsupported.has(element.source.id)?"editable":"readonly"});
      const title=node("title");title.textContent=element.source.kind==="nativeText"?element.source.source:graphic?.label||element.source.kind;group.append(title);
      this.groups.set(element.source.id,group);this.frames.set(element.source.id,frame);this.origins.set(element.source.id,{x:frame.x,y:frame.y});
      if(this.unsupported.has(element.source.id)||appearance(element)==="partial"||richText(element))this.placeholder(group,element,frame);
      else if(element.source.kind==="nativeText")this.nativeText(group,element,frame);
      else if(drawable(element))this.graphic(group,element,frame);
      else this.placeholder(group,element,frame);
      content.append(group);
    }
    this.material.replaceChildren(content);
    this.setCamera(this.camera);
    this.select(this.selected);
  }

  setCamera(camera:Camera):void {
    this.camera={x:finite(camera.x),y:finite(camera.y),scale:clamp(finite(camera.scale,1),0.02,12)};
    const transform=`translate(${-this.camera.x*this.camera.scale} ${-this.camera.y*this.camera.scale}) scale(${this.camera.scale})`;
    this.material.setAttribute("transform",transform);this.selection.setAttribute("transform",transform);
    this.select(this.selected);
  }

  select(id:string|null):void {
    this.selected=id;this.selection.replaceChildren();
    const element=this.snapshot?.elements.find(element=>element.source.id===id),frame=id?this.frames.get(id):undefined;
    if(!element||!frame||!editable(element)||this.unsupported.has(element.source.id))return;
    const pad=4/this.camera.scale;
    this.selection.append(node("rect",{x:frame.x-pad,y:frame.y-pad,width:frame.width+pad*2,height:frame.height+pad*2,
      fill:"none",stroke:"#496d87","stroke-width":1.25,"vector-effect":"non-scaling-stroke",rx:2/this.camera.scale}));
    if(element.source.graphic?.shape!=="connector"){
      const size=9/this.camera.scale;
      this.selection.append(node("rect",{x:frame.x+frame.width-size/2,y:frame.y+frame.height-size/2,width:size,height:size,
        fill:"#fff",stroke:"#496d87","stroke-width":1.25,"vector-effect":"non-scaling-stroke",
        "data-resize-handle":"true","data-element-id":element.source.id,"pointer-events":"all",cursor:"nwse-resize"}));
    }
  }

  preview(id:string,dx:number,dy:number):void {
    const group=this.groups.get(id),origin=this.origins.get(id);
    if(!group||!origin)return;
    group.setAttribute("transform",`translate(${origin.x+finite(dx)} ${origin.y+finite(dy)})`);
    if(id===this.selected)this.selection.setAttribute("transform",`translate(${(-this.camera.x+finite(dx))*this.camera.scale} ${(-this.camera.y+finite(dy))*this.camera.scale}) scale(${this.camera.scale})`);
  }

  point(clientX:number,clientY:number):Point {
    const rect=this.svg.getBoundingClientRect();
    return {x:(clientX-rect.left)/this.camera.scale+this.camera.x,y:(clientY-rect.top)/this.camera.scale+this.camera.y};
  }

  fit():Camera {
    const frames=[...this.frames.values()];
    if(this.snapshot?.target.kind==="page")frames.push({x:0,y:0,...this.snapshot.size});
    if(!frames.length)return {x:0,y:0,scale:1};
    const x=Math.min(...frames.map(frame=>frame.x)),y=Math.min(...frames.map(frame=>frame.y));
    const width=Math.max(...frames.map(frame=>frame.x+frame.width))-x,height=Math.max(...frames.map(frame=>frame.y+frame.height))-y;
    const rect=this.svg.getBoundingClientRect(),scale=clamp(Math.min(Math.max(1,rect.width-100)/Math.max(1,width),Math.max(1,rect.height-140)/Math.max(1,height)),0.02,1);
    return {x:x-(rect.width/scale-width)/2,y:y-(rect.height/scale-height)/2,scale};
  }

  private card(group:SVGGElement,title:string,detail:string,width:number,height:number):void {
    group.append(node("rect",{width,height,rx:9,fill:"#fff",stroke:"#dcdcd6","stroke-width":1.1}));
    const icon=node("g",{transform:"translate(16 16)",stroke:"#a1a39c",fill:"none","stroke-width":1.3});
    icon.append(node("rect",{x:0,y:0,width:19,height:23,rx:2}),node("path",{d:"M 5 7 H 14 M 5 12 H 14 M 5 17 H 11"}));group.append(icon);
    text(group,detail,{x:45,y:31,"font-size":12,fill:"#85867f"});
    const label=text(group,"",{x:16,y:65,"font-size":17,"font-weight":500,fill:"#30322c"});
    this.lines(label,title||"Без названия",width-32,17,500,2);
    text(group,"Открыть →",{x:16,y:height-18,"font-size":11,fill:"#8b8d85"});
  }

  private placeholder(group:SVGGElement,element:PanelElement,frame:Frame):void {
    const width=Math.max(100,frame.width),height=Math.max(54,Math.min(frame.height,140));
    group.append(node("rect",{width,height,rx:5,fill:"#f7f7f3",stroke:"#d7d7cf","stroke-width":1,"stroke-dasharray":"4 4"}));
    const native=element.source.kind==="nativeText"?"Текст с нативным оформлением":element.source.kind==="graphic"?"Нативная геометрия":element.source.kind==="markdown"?"Документ":element.source.kind==="web"?"Интерактивная программа":"Нативный материал";
    text(group,native,{x:12,y:23,"font-size":12,fill:"#696c61"});
    text(group,"Просмотр в Notebook",{x:12,y:43,"font-size":11,fill:"#96998e"});
  }

  private nativeText(group:SVGGElement,element:PanelElement,frame:Frame):void {
    const style:Record<string,number>={red:.09,green:.09,blue:.08,...element.source.textStyle},fontSize=clamp(finite(style.fontSize,34),3,5760);
    const weight=finite(style.weight,.45),fontWeight=weight<.2?300:weight<.4?400:weight<.6?500:weight<.8?600:700;
    group.append(node("rect",{width:frame.width,height:frame.height,fill:"transparent"}));
    const label=text(group,"",{x:0,y:fontSize,"font-size":fontSize,"font-weight":fontWeight,"font-family":"system-ui, -apple-system, sans-serif",
      fill:color(style),opacity:clamp(finite(style.alpha,1),0,1),"xml:space":"preserve"});
    this.lines(label,element.source.source,frame.width,fontSize,fontWeight);
  }

  private lines(label:SVGTextElement,value:string,width:number,fontSize:number,fontWeight:number,limit=Infinity):void {
    if(this.measure)this.measure.font=`${fontWeight} ${fontSize}px system-ui, -apple-system, sans-serif`;
    const measure=(value:string)=>this.measure?.measureText(value).width??value.length*fontSize*.55;
    let lineNumber=0;
    for(const paragraph of value.split("\n")){
      let line="";
      const emit=()=>{if(lineNumber>=limit)return;const span=node("tspan",{x:label.getAttribute("x")??0,dy:lineNumber===0?0:fontSize*1.2});span.textContent=line;label.append(span);lineNumber++;line="";};
      for(const word of paragraph.split(/(\s+)/u)){
        if(line&&measure(line+word)>Math.max(1,width))emit();
        if(measure(word)<=Math.max(1,width))line+=word;
        else for(const character of word){if(line&&measure(line+character)>Math.max(1,width))emit();line+=character;}
        if(lineNumber>=limit)break;
      }
      emit();if(lineNumber>=limit)break;
    }
  }

  private graphic(group:SVGGElement,element:PanelElement,frame:Frame):void {
    const graphic=element.source.graphic!,resolution=element.graphicResolution!,style=graphic.style??{};
    const width=resolution.projection?.size.width??frame.width,height=resolution.projection?.size.height??frame.height;
    const body=node("g");
    if(resolution.projection){const t=resolution.projection.transform;body.setAttribute("transform",`matrix(${t.a} ${t.b} ${t.c} ${t.d} ${t.tx} ${t.ty})`);}
    const strokeWidth=Math.max(.01,finite(style.strokeWidth,2)),stroke=color(style.stroke),fill=style.fill?color(style.fill):"none";
    body.setAttribute("stroke",stroke);body.setAttribute("stroke-opacity",String(clamp(finite(style.stroke?.alpha,1),0,1)));
    body.setAttribute("stroke-width",String(strokeWidth));body.setAttribute("stroke-linecap","round");body.setAttribute("stroke-linejoin","round");body.setAttribute("fill",fill);
    body.setAttribute("fill-opacity",String(clamp(finite(style.fill?.alpha,1),0,1)));
    const dash=style.dash==="dashed"?[4,3]:style.dash==="dotted"?[0,3]:style.dash==="dashDot"?[4,3,0,3]:[];
    const pathAttributes:Record<string,string|number>=dash.length?{"stroke-dasharray":dash.map(value=>value*strokeWidth).join(" ")}:{};
    if(resolution.curves?.length){
      const d=curvesPath(resolution)+(graphic.shape!=="connector"&&graphic.shape!=="plus"?" Z":"");
      body.append(node("path",{d,...pathAttributes,...(graphic.shape==="connector"?{fill:"none"}:{})}));
    }else{
      const inset=Math.max(0,Math.min(strokeWidth/2,Math.min(width,height)/2-.01)),w=width-inset*2,h=height-inset*2;
      if(graphic.shape==="ellipse")body.append(node("ellipse",{cx:width/2,cy:height/2,rx:w/2,ry:h/2,...pathAttributes}));
      else if(graphic.shape==="rectangle"&&!graphic.vertices)body.append(node("rect",{x:inset,y:inset,width:w,height:h,rx:Math.min(finite(graphic.cornerRadius),w/2,h/2),...pathAttributes}));
      else if(graphic.shape==="plus")body.append(node("path",{d:`M ${inset} ${height/2} H ${width-inset} M ${width/2} ${inset} V ${height-inset}`,fill:"none",...pathAttributes}));
      else{
        const vertices:Point[]=graphic.vertices??(graphic.shape==="triangle"?[{x:.5,y:0},{x:1,y:1},{x:0,y:1}]:graphic.shape==="diamond"?[{x:.5,y:0},{x:1,y:.5},{x:.5,y:1},{x:0,y:.5}]:[{x:0,y:0},{x:1,y:0},{x:1,y:1},{x:0,y:1}]);
        body.append(node("polygon",{points:vertices.map(point=>`${inset+point.x*w},${inset+point.y*h}`).join(" "),...pathAttributes}));
      }
    }
    for(const head of resolution.heads??[]){
      if(!head.points.length||!head.points.every(pointValid))continue;
      const d=head.points.map((point,index)=>`${index===0?"M":"L"} ${point.x} ${point.y}`).join(" ")+(head.closed?" Z":"");
      body.append(node("path",{d,fill:head.filled?stroke:"none"}));
    }
    if(graphic.label){
      const center=resolution.label??{x:width/2,y:height/2},fontSize=24;
      const label=text(body,"",{x:center.x,y:center.y-(String(graphic.label).split("\n").length-1)*fontSize*.6+fontSize*.35,
        "text-anchor":"middle","font-size":fontSize,"font-weight":400,stroke:"none",fill:stroke,"fill-opacity":clamp(finite(style.stroke?.alpha,1),0,1)});
      String(graphic.label).split("\n").forEach((line,index)=>{const span=node("tspan",{x:center.x,dy:index===0?0:fontSize*1.2});span.textContent=line;label.append(span);});
    }
    group.append(body);
  }
}

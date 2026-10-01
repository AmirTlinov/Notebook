import type { AppearanceLayer, Camera, Frame, PanelElement, PanelSnapshot, Point } from './model.js';
import type { WorldPoint } from '../src/domain.js';
import { TILE_SIZE } from '../src/spatial.js';

const NS='http://www.w3.org/2000/svg';
const zero:WorldPoint={tileX:0,tileY:0,localX:0,localY:0};
const maximumEncodedBytes=12*1024*1024;
const maximumDecodedPixels=32*1024*1024;
function delta(point:WorldPoint,origin:WorldPoint):Point {
  return {x:(point.tileX-origin.tileX)*TILE_SIZE+point.localX-origin.localX,
    y:(point.tileY-origin.tileY)*TILE_SIZE+point.localY-origin.localY};
}
function node<K extends keyof SVGElementTagNameMap>(tag:K,attributes:Record<string,string|number>={}) {
  const value=document.createElementNS(NS,tag);
  for(const [key,attribute]of Object.entries(attributes))value.setAttribute(key,String(attribute));
  return value;
}
function validFrame(frame:Frame){return Object.values(frame).every(Number.isFinite)&&frame.width>0&&frame.height>0;}
function validPoint(point:WorldPoint){return Number.isSafeInteger(point.tileX)&&Number.isSafeInteger(point.tileY)
  &&Number.isFinite(point.localX)&&Number.isFinite(point.localY);}
function sourceFrame(element:PanelElement,origin:WorldPoint):Frame{
  const frame=element.graphicResolution?.frame??element.source.frame;
  const offset=delta(element.graphicResolution?.worldOrigin??element.source.worldOrigin??zero,origin);
  return {...frame,x:frame.x+offset.x,y:frame.y+offset.y};
}

/** Capability stays conservative; the native publisher must also separate its appearance. */
export function editable(element:PanelElement):boolean {
  const source=element.source,graphic=source.graphic,style=source.textStyle;
  const appearance=element.appearance as {state?:string}|undefined;
  if(element.editable===false||source.parentID!=null||source.basis!=null||['erased','partial'].includes(appearance?.state??''))return false;
  if(source.kind==='nativeText')return style?.format==null&&(!Array.isArray(style?.runs)||style.runs.length===0);
  return source.kind==='graphic'&&graphic?.representation==='geometry'&&graphic.visible!==false
    &&!graphic.mask&&!graphic.freehand&&!graphic.transform&&!(graphic.sourceInkIDs?.length)
    &&element.graphicResolution?.state==='geometry'
    &&!graphic.connection?.start?.binding&&!graphic.connection?.end?.binding;
}

type Asset={url:string;image:HTMLImageElement};
type Cohort={snapshot:PanelSnapshot;fragment:DocumentFragment;assets:Map<string,Asset>;
  groups:Map<string,SVGGElement>;frames:Map<string,Frame>;origins:Map<string,Point>};

/** Native accepted pixels are disposable presentation. SVG owns only hit regions and handles. */
export class Surface {
  private camera:Camera={x:0,y:0,scale:1};
  private selected:string|null=null;
  private accepted:Cohort|null=null;
  private prepared:Cohort|null=null;
  private generation=0;
  get ready(){return this.accepted!==null;}
  constructor(private readonly svg:SVGSVGElement,private readonly material:SVGGElement,private readonly selection:SVGGElement){}

  async prepare(snapshot:PanelSnapshot):Promise<boolean>{
    const generation=++this.generation;
    const appearance=snapshot.appearance;
    if(appearance?.status!=='ready')throw new Error('Notebook ещё готовит изображение поверхности.');
    if(appearance.layers.length>96)throw new Error('Notebook превысил предел слоёв поверхности.');
    let encoded=0,pixels=0;
    for(const layer of appearance.layers){
      encoded+=layer.pngBase64.length;pixels+=layer.pixelWidth*layer.pixelHeight;
      if(!validFrame(layer.frame)||!validPoint(layer.worldOrigin)||!Number.isSafeInteger(layer.pixelWidth)||!Number.isSafeInteger(layer.pixelHeight)
        ||layer.pixelWidth<1||layer.pixelHeight<1||!Number.isFinite(layer.order)
        ||!/^[a-f0-9]{64}$/.test(layer.sha256)||!layer.pngBase64.startsWith('iVBORw0KGgo'))throw new Error('Notebook вернул неполное изображение слоя.');
    }
    if(encoded>maximumEncodedBytes||pixels>maximumDecodedPixels)throw new Error('Видимая поверхность превышает предел изображений. Приблизьте нужный участок.');
    const assets=new Map<string,Asset>();
    try{
      await Promise.all(appearance.layers.map(async layer=>{
        if(assets.has(layer.sha256))return;
        const retained=this.accepted?.assets.get(layer.sha256);
        if(retained){assets.set(layer.sha256,retained);return;}
        const bytes=Uint8Array.from(atob(layer.pngBase64),character=>character.charCodeAt(0));
        const url=URL.createObjectURL(new Blob([bytes],{type:'image/png'}));
        const image=new Image();assets.set(layer.sha256,{url,image});image.src=url;
        await image.decode();
        if(image.naturalWidth!==layer.pixelWidth||image.naturalHeight!==layer.pixelHeight)throw new Error('Размер изображения Notebook изменился.');
      }));
      if(generation!==this.generation){this.release(assets);return false;}
      const fragment=document.createDocumentFragment(),groups=new Map<string,SVGGElement>(),frames=new Map<string,Frame>(),origins=new Map<string,Point>();
      const origin=snapshot.worldOrigin??zero;
      const placed=(layer:AppearanceLayer):Frame=>{const offset=delta(layer.worldOrigin,origin);return {...layer.frame,x:layer.frame.x+offset.x,y:layer.frame.y+offset.y};};
      const separated=new Set(appearance.layers.flatMap(layer=>layer.elementID?[layer.elementID]:[]));
      // Canonical readonly content remains addressable to the agent. Editable
      // subject hits and cover navigation are placed above these transparent regions.
      for(const element of snapshot.elements){
        if(separated.has(element.source.id)||(element.appearance as {state?:string}|undefined)?.state==='erased'
          ||element.source.graphic?.visible===false)continue;
        const frame=sourceFrame(element,origin);if(!validFrame(frame))continue;
        frames.set(element.source.id,frame);
        const hit=node('rect',{...frame,fill:'transparent','pointer-events':'all','data-element-id':element.source.id,class:'readonly'});
        const title=node('title');title.textContent=element.source.kind==='nativeText'?element.source.source:String(element.source.graphic?.label??element.source.kind);
        hit.append(title);fragment.append(hit);
      }
      for(const layer of [...appearance.layers].sort((a,b)=>a.order-b.order)){
        const frame=placed(layer);
        const group=node('g',{'data-layer-id':layer.id,transform:`translate(${frame.x} ${frame.y})`});
        group.append(node('image',{href:assets.get(layer.sha256)!.url,width:frame.width,height:frame.height,
          preserveAspectRatio:'none','pointer-events':'none'}));
        if(layer.elementID){
          const element=snapshot.elements.find(value=>value.source.id===layer.elementID);
          if(element){
            const hitFrame=frame;
            if(!validFrame(hitFrame))throw new Error('Notebook вернул неполную геометрию элемента.');
            const canEdit=editable(element)&&!snapshot.unsupportedElements.some(value=>value.id===layer.elementID);
            group.setAttribute('data-element-id',layer.elementID);group.setAttribute('class',canEdit?'editable':'readonly');
            group.append(node('rect',{x:hitFrame.x-frame.x,y:hitFrame.y-frame.y,width:hitFrame.width,height:hitFrame.height,
              fill:'transparent','pointer-events':'all'}));
            const title=node('title');title.textContent=element.source.kind==='nativeText'?element.source.source:String(element.source.graphic?.label??element.source.kind);group.append(title);
            groups.set(layer.elementID,group);frames.set(layer.elementID,hitFrame);origins.set(layer.elementID,{x:frame.x,y:frame.y});
          }
        }
        fragment.append(group);
      }
      // Covers retain native physical bounds. Their appearance already lives in painter layers.
      for(const card of snapshot.cards){
        if(!card.frame||!validFrame(card.frame))continue;
        const offset=delta(card.worldOrigin??snapshot.worldOrigin??zero,origin);
        const frame={...card.frame,x:card.frame.x+offset.x,y:card.frame.y+offset.y};
        frames.set(`card:${card.item.id}`,frame);
        const hit=node('rect',{...frame,fill:'transparent','pointer-events':'all','data-card-id':card.item.id,role:'button',tabindex:0,
          'aria-label':`Открыть ${card.item.title}`});fragment.append(hit);
      }
      this.discardPrepared();this.prepared={snapshot,fragment,assets,groups,frames,origins};return true;
    }catch(error){this.release(assets);throw error;}
  }

  render(snapshot:PanelSnapshot){
    const next=this.prepared;if(!next||next.snapshot!==snapshot)throw new Error('Изображение поверхности ещё не подготовлено.');
    const previous=this.accepted;this.prepared=null;this.accepted=next;
    this.material.replaceChildren(next.fragment);
    if(previous)for(const [hash,asset]of previous.assets)if(!next.assets.has(hash))URL.revokeObjectURL(asset.url);
    this.setCamera(this.camera);this.select(this.selected);
  }
  private release(assets:Map<string,Asset>){for(const [hash,asset]of assets)if(this.accepted?.assets.get(hash)!==asset)URL.revokeObjectURL(asset.url);}
  private discardPrepared(){if(this.prepared){this.release(this.prepared.assets);this.prepared=null;}}
  dispose(){++this.generation;this.discardPrepared();if(this.accepted)for(const asset of this.accepted.assets.values())URL.revokeObjectURL(asset.url);this.accepted=null;this.material.replaceChildren();this.selection.replaceChildren();}
  hasSubject(id:string){return this.accepted?.groups.has(id)===true;}
  hideSubject(id:string,hidden:boolean){const group=this.accepted?.groups.get(id);if(group)group.style.visibility=hidden?'hidden':'';}
  frame(element:PanelElement):Frame{
    const accepted=this.accepted?.frames.get(element.source.id);if(accepted)return {...accepted};
    return sourceFrame(element,this.accepted?.snapshot.worldOrigin??zero);
  }
  authoredFrame(element:PanelElement):Frame{
    const offset=delta(element.source.worldOrigin??zero,this.accepted?.snapshot.worldOrigin??zero);
    return {...element.source.frame,x:element.source.frame.x+offset.x,y:element.source.frame.y+offset.y};
  }
  setCamera(camera:Camera){
    this.camera={...camera};this.svg.setAttribute('viewBox',`${camera.x} ${camera.y} ${Math.max(1,this.svg.clientWidth/camera.scale)} ${Math.max(1,this.svg.clientHeight/camera.scale)}`);
    this.svg.setAttribute('preserveAspectRatio','none');
  }
  select(id:string|null){
    this.selected=id;this.selection.removeAttribute('transform');this.selection.replaceChildren();
    if(!id||!this.accepted?.frames.has(id))return;
    const element=this.accepted.snapshot.elements.find(value=>value.source.id===id);
    if(!element)return;
    const body=this.accepted.frames.get(id)!;
    const canEdit=this.accepted.groups.has(id)&&editable(element)&&!this.accepted.snapshot.unsupportedElements.some(value=>value.id===id);
    const authored=this.authoredFrame(element),text=canEdit&&element.source.kind==='nativeText';
    const frame=text?{...authored,height:Math.max(authored.height,body.height)}:body;
    this.selection.append(node('rect',{...frame,fill:'none',stroke:'#496d87','stroke-width':1.25/this.camera.scale,
      ...(!canEdit?{'stroke-dasharray':`${4/this.camera.scale} ${3/this.camera.scale}`} :{}),'pointer-events':'none'}));
    if(!canEdit)return;
    if(element.source.graphic?.shape==='connector')return;
    const side=9/this.camera.scale;
    this.selection.append(node('rect',{x:frame.x+frame.width-side/2,y:frame.y+(text?frame.height/2:frame.height)-side/2,width:side,height:side,
      fill:'#fff',stroke:'#496d87','stroke-width':1.25/this.camera.scale,'pointer-events':'all',cursor:text?'ew-resize':'nwse-resize',
      'data-resize-handle':'true','data-element-id':id}));
  }
  preview(id:string,dx:number,dy:number){
    const group=this.accepted?.groups.get(id),origin=this.accepted?.origins.get(id);if(!group||!origin)return;
    group.setAttribute('transform',`translate(${origin.x+dx} ${origin.y+dy})`);this.selection.setAttribute('transform',`translate(${dx} ${dy})`);
  }
  previewSize(id:string,width:number,height:number){
    if(this.accepted?.snapshot.elements.find(element=>element.source.id===id)?.source.kind==='nativeText')return;
    const group=this.accepted?.groups.get(id),origin=this.accepted?.origins.get(id),frame=this.accepted?.frames.get(id);
    if(!group||!origin||!frame)return;
    group.setAttribute('transform',`translate(${frame.x} ${frame.y}) scale(${width/frame.width} ${height/frame.height}) translate(${origin.x-frame.x} ${origin.y-frame.y})`);
  }
  clearPreview(){
    this.selection.removeAttribute('transform');
    if(this.accepted)for(const [id,origin]of this.accepted.origins)this.accepted.groups.get(id)!.setAttribute('transform',`translate(${origin.x} ${origin.y})`);
    this.select(this.selected);
  }
  point(clientX:number,clientY:number):Point{
    const bounds=this.svg.getBoundingClientRect();return {x:this.camera.x+(clientX-bounds.left)/this.camera.scale,y:this.camera.y+(clientY-bounds.top)/this.camera.scale};
  }
  fit():Camera{
    const frames=[...this.accepted?.frames.values()??[]];
    if(this.accepted?.snapshot.target.kind==='page')frames.push({x:0,y:0,...this.accepted.snapshot.size});
    if(!frames.length)return {...this.camera};
    const left=Math.min(...frames.map(frame=>frame.x)),top=Math.min(...frames.map(frame=>frame.y));
    const right=Math.max(...frames.map(frame=>frame.x+frame.width)),bottom=Math.max(...frames.map(frame=>frame.y+frame.height));
    const ratio=this.svg.clientWidth/(this.accepted?.snapshot.appearance?.viewport.x??this.svg.clientWidth);
    const scale=Math.min(4*ratio,Math.max(.0125*ratio,Math.min((this.svg.clientWidth-80)/Math.max(1,right-left),(this.svg.clientHeight-120)/Math.max(1,bottom-top))));
    return {x:(left+right)/2-this.svg.clientWidth/(2*scale),y:(top+bottom)/2-this.svg.clientHeight/(2*scale),scale};
  }
}

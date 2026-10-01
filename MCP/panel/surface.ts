import type { Camera, Frame, PanelElement, PanelSelection, PanelSnapshot, PanelView, Point } from './model.js';
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

type Asset={url:string;image:HTMLImageElement;width:number;height:number};
type Hit={selection:PanelSelection;frame:Frame;label:string;editable:boolean;order:number};
type Group={node:SVGGElement;origin:Point;frame:Frame};
type Cohort={snapshot:PanelSnapshot;fragment:DocumentFragment;assets:Map<string,Asset>;
  groups:Map<string,Group[]>;frames:Map<string,Frame>;hits:Map<string,Hit>;
  backdrop:{rect:SVGRectElement;origin:Point}|null;density:number};
const key=(selection:PanelSelection)=>`${selection.kind}:${selection.id}`;

/** Native material owns pixels. This edge owns camera transforms, stable hits and controls. */
export class Surface {
  private camera:Camera={x:0,y:0,scale:1};
  private selected:PanelSelection|null=null;
  private motion:{selection:PanelSelection;dx:number;dy:number}|null=null;
  private accepted:Cohort|null=null;
  private prepared:Cohort|null=null;
  private generation=0;
  private readonly hitPlane=node('g',{'data-notebook-hits':'true'});
  private readonly hits=new Map<string,SVGRectElement>();
  get ready(){return this.accepted!==null;}
  get assetIDs(){return [...this.accepted?.assets.keys()??[]].slice(0,96);}
  constructor(private readonly svg:SVGSVGElement,private readonly material:SVGGElement,private readonly selection:SVGGElement){
    svg.insertBefore(this.hitPlane,selection);
  }
  covers(bounds:{anchor:WorldPoint;region:Frame}|undefined,density:number):boolean{
    const coverage=this.accepted?.snapshot.appearance?.coverage;
    const requested=this.accepted?.density;
    if(!bounds||!coverage||!requested||density<requested*.6||density>requested*Math.SQRT2)return false;
    const offset=delta(bounds.anchor,coverage.anchor),a=coverage.region,b=bounds.region;
    return b.x+offset.x>=a.x&&b.y+offset.y>=a.y&&b.x+offset.x+b.width<=a.x+a.width&&b.y+offset.y+b.height<=a.y+a.height;
  }
  private useful(snapshot:PanelSnapshot):boolean{
    const previous=this.accepted?.snapshot;
    if(!previous||previous.target.kind!==snapshot.target.kind||previous.target.id!==snapshot.target.id
      ||previous.appearance?.sourceRevision!==snapshot.appearance?.sourceRevision)return true;
    const width=this.svg.clientWidth/this.camera.scale,height=this.svg.clientHeight/this.camera.scale;
    const coverage=(value:PanelSnapshot)=>{
      const a=value.appearance!,c=a.coverage;
      const frame=c?{...c.region,...delta(c.anchor,previous.worldOrigin??zero)}:null;
      const center=delta(a.camera.center,previous.worldOrigin??zero);
      const left=frame?frame.x+c!.region.x:center.x-a.viewport.x/a.camera.scale/2;
      const top=frame?frame.y+c!.region.y:center.y-a.viewport.y/a.camera.scale/2;
      const w=c?.region.width??a.viewport.x/a.camera.scale,h=c?.region.height??a.viewport.y/a.camera.scale;
      return Math.max(0,Math.min(this.camera.x+width,left+w)-Math.max(this.camera.x,left))
        *Math.max(0,Math.min(this.camera.y+height,top+h)-Math.max(this.camera.y,top));
    };
    return coverage(snapshot)+width*height*1e-6>=coverage(previous);
  }
  async prepare(snapshot:PanelSnapshot,view:PanelView):Promise<boolean>{
    const generation=++this.generation,a=snapshot.appearance;
    if(a?.status!=='ready')throw new Error('Notebook ещё готовит изображение поверхности.');
    if(!this.useful(snapshot))return false;
    if(a.layers.length>96)throw new Error('Слишком большая область. Приблизьте нужный участок.');
    const assets=new Map<string,Asset>(),decode:Asset[]=[];let encoded=0,pixels=0;
    try{
      for(const layer of a.layers){
        if(!validFrame(layer.frame)||!validPoint(layer.worldOrigin)||!Number.isSafeInteger(layer.pixelWidth)||!Number.isSafeInteger(layer.pixelHeight)
          ||layer.pixelWidth<1||layer.pixelHeight<1||!Number.isFinite(layer.order)||!layer.assetID)throw new Error('Не удалось подготовить изображение доски.');
        const period=layer.repeatSize;
        if(period&&(snapshot.target.kind!=='board'||layer.id!=='board-grid'||layer.elementID||layer.itemID
          ||!Number.isFinite(period.width)||!Number.isFinite(period.height)||period.width<=0||period.height<=0
          ||period.width>layer.frame.width||period.height>layer.frame.height))throw new Error('Notebook вернул неверный фон поверхности.');
        const id=layer.assetID.toLowerCase();
        const retained=assets.get(id)??this.accepted?.assets.get(id);
        if(retained){
          if(retained.width!==layer.pixelWidth||retained.height!==layer.pixelHeight)throw new Error('Изображение объекта изменилось. Обновите доску.');
          assets.set(id,retained);continue;
        }
        if(!layer.pngBase64?.startsWith('iVBORw0KGgo')||!/^[a-f0-9]{64}$/.test(layer.sha256??''))throw new Error('Notebook не прислал запрошенный материал.');
        encoded+=layer.pngBase64.length;pixels+=layer.pixelWidth*layer.pixelHeight;
        if(encoded>maximumEncodedBytes||pixels>maximumDecodedPixels||assets.size>=96)throw new Error('Видимая поверхность превышает предел изображений. Приблизьте нужный участок.');
        const bytes=Uint8Array.from(atob(layer.pngBase64),character=>character.charCodeAt(0));
        const url=URL.createObjectURL(new Blob([bytes],{type:'image/png'})),image=new Image();
        const asset={url,image,width:layer.pixelWidth,height:layer.pixelHeight};assets.set(id,asset);decode.push(asset);image.src=url;
      }
      if([...assets.values()].reduce((sum,asset)=>sum+asset.width*asset.height,0)>maximumDecodedPixels)throw new Error('Слишком большая область. Приблизьте нужный участок.');
      await Promise.all(decode.map(async asset=>{
        await asset.image.decode();
        if(asset.image.naturalWidth!==asset.width||asset.image.naturalHeight!==asset.height)throw new Error('Размер изображения Notebook изменился.');
      }));
      if(generation!==this.generation||!this.useful(snapshot)){this.release(assets);return false;}
      const fragment=document.createDocumentFragment(),groups=new Map<string,Group[]>(),frames=new Map<string,Frame>(),hits=new Map<string,Hit>();
      let backdrop:Cohort['backdrop']=null;const origin=snapshot.worldOrigin??zero,orders=new Map<string,number>();
      const cardOrder=Math.max(0,...a.layers.filter(layer=>!layer.elementID).map(layer=>layer.order))+1;
      for(const layer of [...a.layers].sort((x,y)=>x.order-y.order)){
        const offset=delta(layer.worldOrigin,origin),frame={...layer.frame,x:layer.frame.x+offset.x,y:layer.frame.y+offset.y};
        const group=node('g',{'data-layer-id':layer.id,transform:`translate(${frame.x} ${frame.y})`});
        const image=node('image',{href:assets.get(layer.assetID.toLowerCase())!.url,width:frame.width,height:frame.height,preserveAspectRatio:'none','pointer-events':'none'});
        if(layer.repeatSize){
          const id=`notebook-grid-${crypto.randomUUID()}`,pattern=node('pattern',{id,...layer.repeatSize,patternUnits:'userSpaceOnUse',overflow:'hidden'});
          pattern.append(image);group.append(pattern);const rect=node('rect',{fill:`url(#${id})`,'pointer-events':'none'});group.append(rect);backdrop={rect,origin:{x:frame.x,y:frame.y}};
        }else group.append(image);
        const selection:PanelSelection|undefined=layer.elementID?{kind:'element',id:layer.elementID}:layer.itemID?{kind:'item',id:layer.itemID}:undefined;
        if(selection){
          const id=key(selection),body=layer.subjectFrame??layer.frame;
          if(!validFrame(body))throw new Error('Notebook вернул неполную геометрию объекта.');
          frames.set(id,{...body,x:body.x+offset.x,y:body.y+offset.y});orders.set(id,Math.max(orders.get(id)??-Infinity,layer.order));
          group.setAttribute(selection.kind==='item'?'data-card-subject':'data-element-subject',selection.id);
          const list=groups.get(id)??[];list.push({node:group,origin:{x:frame.x,y:frame.y},frame});groups.set(id,list);
        }
        fragment.append(group);
      }
      for(const card of snapshot.cards){
        if(!card.frame||!validFrame(card.frame))continue;
        const selection:PanelSelection={kind:'item',id:card.item.id},id=key(selection),offset=delta(card.worldOrigin??origin,origin);
        const frame={...card.frame,x:card.frame.x+offset.x,y:card.frame.y+offset.y};frames.set(id,frame);
        hits.set(id,{selection,frame,label:card.item.title||'Без названия',editable:card.editable===true&&!!card.source&&groups.has(id),order:orders.get(id)??cardOrder});
      }
      for(const element of snapshot.elements){
        if((element.appearance as {state?:string}|undefined)?.state==='erased'||element.source.graphic?.visible===false)continue;
        const selection:PanelSelection={kind:'element',id:element.source.id},id=key(selection),frame=frames.get(id)??sourceFrame(element,origin);
        if(!validFrame(frame))continue;frames.set(id,frame);
        hits.set(id,{selection,frame,label:element.source.kind==='nativeText'?element.source.source:String(element.source.graphic?.label??element.source.kind),
          editable:groups.has(id)&&editable(element)&&!snapshot.unsupportedElements.some(value=>value.id===selection.id),order:orders.get(id)??-1});
      }
      this.discardPrepared();this.prepared={snapshot,fragment,assets,groups,frames,hits,backdrop,density:(view.camera?.scale??a.camera.scale)*view.pixelScale};return true;
    }catch(error){this.release(assets);throw error;}
  }
  render(snapshot:PanelSnapshot){
    const next=this.prepared;if(!next||next.snapshot!==snapshot)throw new Error('Изображение поверхности ещё не подготовлено.');
    const previous=this.accepted;this.prepared=null;this.accepted=next;this.motion=null;this.material.replaceChildren(next.fragment);
    const focused=document.activeElement,focusedID=[...this.hits].find(([,hit])=>hit===focused)?.[0];
    let previousHit:SVGRectElement|null=null;
    for(const [id,hit]of this.hits)if(!next.hits.has(id)){if(hit===focused)this.svg.parentElement?.focus();hit.remove();this.hits.delete(id);}
    for(const [id,value]of [...next.hits].sort((a,b)=>a[1].order-b[1].order)){
      let hit=this.hits.get(id);
      if(!hit){hit=node('rect',{fill:'transparent','pointer-events':'all',tabindex:0,role:'button'});this.hits.set(id,hit);}
      const expected:ChildNode|null=previousHit?previousHit.nextSibling:this.hitPlane.firstChild;
      if(expected!==hit)this.hitPlane.insertBefore(hit,expected);previousHit=hit;
      for(const [name,n]of Object.entries(value.frame))hit.setAttribute(name,String(n));
      hit.setAttribute(value.selection.kind==='item'?'data-card-id':'data-element-id',value.selection.id);
      hit.setAttribute('aria-label',value.label);hit.setAttribute('class',value.editable?'editable':'readonly');
    }
    if(focusedID&&this.hits.has(focusedID)&&document.activeElement!==focused)(this.hits.get(focusedID)! as unknown as HTMLElement).focus({preventScroll:true});
    if(previous)for(const [id,asset]of previous.assets)if(!next.assets.has(id))URL.revokeObjectURL(asset.url);
    this.setCamera(this.camera);
  }
  private release(assets:Map<string,Asset>){for(const [id,asset]of assets)if(this.accepted?.assets.get(id)!==asset)URL.revokeObjectURL(asset.url);}
  private discardPrepared(){if(this.prepared){this.release(this.prepared.assets);this.prepared=null;}}
  dispose(){++this.generation;this.discardPrepared();if(this.accepted)for(const asset of this.accepted.assets.values())URL.revokeObjectURL(asset.url);this.accepted=null;this.material.replaceChildren();this.hitPlane.replaceChildren();this.hits.clear();this.selection.replaceChildren();}
  hasSubject(id:string){return this.accepted?.groups.has(`element:${id}`)===true;}
  hasItemSubject(id:string){return this.accepted?.groups.has(`item:${id}`)===true;}
  hideSubject(id:string,hidden:boolean){for(const group of this.accepted?.groups.get(`element:${id}`)??[])group.node.style.visibility=hidden?'hidden':'';}
  frame(element:PanelElement):Frame{return {...(this.accepted?.frames.get(`element:${element.source.id}`)??sourceFrame(element,this.accepted?.snapshot.worldOrigin??zero))};}
  authoredFrame(element:PanelElement):Frame{
    const offset=delta(element.source.worldOrigin??zero,this.accepted?.snapshot.worldOrigin??zero);return {...element.source.frame,x:element.source.frame.x+offset.x,y:element.source.frame.y+offset.y};
  }
  setCamera(camera:Camera){
    const width=Math.max(1,this.svg.clientWidth/camera.scale),height=Math.max(1,this.svg.clientHeight/camera.scale);
    this.camera={...camera};this.svg.setAttribute('viewBox',`${camera.x} ${camera.y} ${width} ${height}`);this.svg.setAttribute('preserveAspectRatio','none');
    const backdrop=this.accepted?.backdrop;
    if(backdrop)for(const [name,value]of Object.entries({x:camera.x-backdrop.origin.x,y:camera.y-backdrop.origin.y,width,height}))backdrop.rect.setAttribute(name,String(value));
    this.select(this.selected);
  }
  select(selection:PanelSelection|null){
    this.selected=selection;this.selection.removeAttribute('transform');this.selection.replaceChildren();
    for(const [id,hit]of this.hits)hit.setAttribute('aria-pressed',String(!!selection&&id===key(selection)));
    if(!selection||!this.accepted)return;const id=key(selection),body=this.accepted.frames.get(id);if(!body)return;
    const element=selection.kind==='element'?this.accepted.snapshot.elements.find(value=>value.source.id===selection.id):undefined;
    const canEdit=this.accepted.hits.get(id)?.editable===true,text=canEdit&&element?.source.kind==='nativeText';
    const authored=element?this.authoredFrame(element):body,frame=text?{...authored,height:Math.max(authored.height,body.height)}:body;
    if(this.motion&&key(this.motion.selection)===id)this.selection.setAttribute('transform',`translate(${this.motion.dx} ${this.motion.dy})`);
    this.selection.append(node('rect',{...frame,fill:'none',stroke:'#496d87','stroke-width':1.25/this.camera.scale,
      ...(!canEdit?{'stroke-dasharray':`${4/this.camera.scale} ${3/this.camera.scale}`} :{}),'pointer-events':'none'}));
    if(!canEdit||!element||element.source.graphic?.shape==='connector')return;
    const side=9/this.camera.scale;
    this.selection.append(node('rect',{x:frame.x+frame.width-side/2,y:frame.y+(text?frame.height/2:frame.height)-side/2,width:side,height:side,
      fill:'#fff',stroke:'#496d87','stroke-width':1.25/this.camera.scale,'pointer-events':'all',cursor:text?'ew-resize':'nwse-resize','data-resize-handle':'true','data-element-id':selection.id}));
  }
  preview(selection:PanelSelection,dx:number,dy:number){
    this.motion={selection,dx,dy};const id=key(selection);for(const group of this.accepted?.groups.get(id)??[])group.node.setAttribute('transform',`translate(${group.origin.x+dx} ${group.origin.y+dy})`);
    const hit=this.hits.get(id),frame=this.accepted?.frames.get(id);if(hit&&frame){hit.setAttribute('x',String(frame.x+dx));hit.setAttribute('y',String(frame.y+dy));}
    this.selection.setAttribute('transform',`translate(${dx} ${dy})`);
  }
  previewSize(id:string,width:number,height:number){
    if(this.accepted?.snapshot.elements.find(element=>element.source.id===id)?.source.kind==='nativeText')return;
    const body=this.accepted?.frames.get(`element:${id}`);if(!body)return;
    for(const group of this.accepted?.groups.get(`element:${id}`)??[])group.node.setAttribute('transform',`translate(${body.x} ${body.y}) scale(${width/body.width} ${height/body.height}) translate(${group.origin.x-body.x} ${group.origin.y-body.y})`);
  }
  clearPreview(){
    this.motion=null;
    if(this.accepted)for(const [id,groups]of this.accepted.groups){for(const group of groups)group.node.setAttribute('transform',`translate(${group.origin.x} ${group.origin.y})`);
      const hit=this.hits.get(id),frame=this.accepted.frames.get(id);if(hit&&frame){hit.setAttribute('x',String(frame.x));hit.setAttribute('y',String(frame.y));}}
    this.select(this.selected);
  }
  point(clientX:number,clientY:number):Point{const bounds=this.svg.getBoundingClientRect();return{x:this.camera.x+(clientX-bounds.left)/this.camera.scale,y:this.camera.y+(clientY-bounds.top)/this.camera.scale};}
  fit(minScale:number,maxScale:number,bounds=this.accepted?.snapshot.fitBounds):Camera{
    const snapshot=this.accepted?.snapshot;
    const offset=bounds?delta(bounds.anchor,snapshot?.worldOrigin??zero):{x:0,y:0};
    const frame=bounds?{...bounds.region,x:bounds.region.x+offset.x,y:bounds.region.y+offset.y}:
      snapshot?.target.kind==='page'?{x:0,y:0,...snapshot.size}:null;
    if(!frame||!validFrame(frame))return {...this.camera};
    const scale=Math.min(maxScale,Math.max(minScale,Math.min((this.svg.clientWidth-80)/frame.width,(this.svg.clientHeight-120)/frame.height)));
    return{x:frame.x+frame.width/2-this.svg.clientWidth/(2*scale),y:frame.y+frame.height/2-this.svg.clientHeight/(2*scale),scale};
  }
}

import {InkGPU} from './ink-gpu.js';
import {SwiftSurface,type SwiftInkContact,type SurfaceCamera} from './swift-surface.js';
import type {Frame,Point} from './model.js';
import type {WorldPoint} from '../src/domain.js';

type Measurement=Point&{width:number;opacity:number;force:number;timeOffset:number;azimuth:number;altitude:number};
type Basis={origin:WorldPoint;camera:SurfaceCamera;viewport:Point;client:Point;clip?:Frame};
type Contact={pointer:number;basis:Basis;geometry:SwiftInkContact;points:Measurement[];
  filtered:number|undefined;timestamp:number;started:number;sealed:boolean};

/** Browser events and GPU lifetime. Swift owns pressure, normalization and
 * prepared geometry; the existing command owner receives measured samples. */
export class InkInput {
  private gpu:InkGPU|undefined;
  private contact:Contact|undefined;
  private connecting:Promise<void>|undefined;
  private color={red:0,green:0,blue:0};
  private closed=false;
  private readonly abort=()=>this.dispose();
  get ready(){return !!this.gpu&&!this.closed&&!this.signal.aborted;}
  get pointer(){return this.contact?.sealed?undefined:this.contact?.pointer;}
  get hasPreview(){return !!this.contact;}

  constructor(private readonly canvas:HTMLCanvasElement,private readonly surface:()=>SwiftSurface,
    private readonly view:()=>{camera:SurfaceCamera;viewport:Point;pixelScale:number},
    private readonly signal:AbortSignal,private readonly changed:()=>void,
    private readonly failed:(error:Error,retry:()=>Promise<void>)=>void){
    signal.addEventListener('abort',this.abort,{once:true});
    void this.connect();
  }

  private connect():Promise<void>{
    if(this.closed||this.signal.aborted)return Promise.resolve();
    if(this.connecting)return this.connecting;
    let offered:InkGPU|undefined,earlyFailure:Error|undefined,reconnect=false;
    this.connecting=InkGPU.create(this.canvas,this.signal,error=>{
      if(this.closed)return;
      if(!offered){earlyFailure=error;return;}
      if(this.gpu!==offered)return;
      offered.dispose();this.gpu=undefined;this.changed();
      if(this.connecting)reconnect=true;else void this.connect();
    }).then(gpu=>{
      offered=gpu;
      if(this.closed||this.signal.aborted){gpu.dispose();return;}
      if(earlyFailure)throw earlyFailure;
      this.gpu=gpu;
      if(this.contact?.points.length)gpu.setNodes(this.contact.geometry.snapshot(),this.color);
      this.draw();this.changed();
    }).catch(error=>{
      offered?.dispose();if(this.gpu===offered)this.gpu=undefined;
      if(!this.closed&&!this.signal.aborted)this.failed(error instanceof Error?error:new Error(String(error)),()=>this.connect());
    }).finally(()=>{this.connecting=undefined;if(reconnect&&!this.closed)void this.connect();});
    return this.connecting;
  }

  begin(event:PointerEvent,basis:Basis){
    if(!this.ready||this.contact)return false;
    this.contact={pointer:event.pointerId,basis,geometry:this.surface().inkContact(),points:[],
      filtered:undefined,timestamp:event.timeStamp,started:event.timeStamp,sealed:false};
    try{this.append(event,false);this.canvas.hidden=false;return true;}
    catch(error){this.clear();throw error;}
  }

  append(event:PointerEvent,predict=true){
    const contact=this.contact;
    if(!contact||contact.sealed||contact.pointer!==event.pointerId)return;
    const changedFrom=contact.points.length,tail:number[]=[],points:Measurement[]=[];
    let timestamp=contact.timestamp,filtered=contact.filtered,color=this.color;
    const {basis}=contact,local=this.surface().delta(basis.origin,basis.camera.center);
    const record=(sample:PointerEvent,measured:boolean)=>{
      if(measured&&sample.timeStamp<timestamp)return;
      const force=sample.pointerType==='pen'?sample.pressure:1;
      const style=this.surface().penSample(force,filtered,Math.max(0,sample.timeStamp-timestamp)/1000);
      const point:Measurement={
        x:local.x+(sample.clientX-basis.client.x-basis.viewport.x/2)/basis.camera.scale,
        y:local.y+(sample.clientY-basis.client.y-basis.viewport.y/2)/basis.camera.scale,
        // Page ink keeps its physical paper width; board input is measured in
        // screen points, matching the two native coordinate adapters.
        width:style.width/(basis.clip?1:basis.camera.scale),opacity:style.opacity,force,
        timeOffset:Math.max(0,sample.timeStamp-contact.started)/1000,
        azimuth:sample.azimuthAngle??0,altitude:sample.altitudeAngle??Math.PI/2};
      if(![point.timeOffset,point.force,point.azimuth,point.altitude].every(Number.isFinite))throw new RangeError('Неверное измерение пера.');
      if(measured){
        const previous=points.at(-1)??contact.points.at(-1);
        if(sample.timeStamp===timestamp&&previous&&point.x===previous.x&&point.y===previous.y
          &&point.force===previous.force&&point.azimuth===previous.azimuth&&point.altitude===previous.altitude)return;
        points.push(point);timestamp=sample.timeStamp;filtered=style.filteredForce;
      }else if(basis.clip){
        // Native page prediction advances its own filter. The board adapter
        // predicts each sample from the last measured tip instead.
        timestamp=sample.timeStamp;filtered=style.filteredForce;
      }
      color=style.color;
      tail.push(point.x,point.y,point.width/2,style.color.red*point.opacity,style.color.green*point.opacity,style.color.blue*point.opacity,point.opacity);
    };
    const measured=event.getCoalescedEvents?.()??[];
    for(const sample of measured)record(sample,true);
    record(event,true);
    const measuredTimestamp=timestamp,measuredForce=filtered;
    if(predict)for(const sample of event.getPredictedEvents?.()??[])record(sample,false);
    // An empty tail retracts predictions at pointerup without persisting them.
    const update=contact.geometry.update(new Float32Array(tail),changedFrom);
    for(const point of points)contact.points.push(point);
    contact.timestamp=measuredTimestamp;contact.filtered=measuredForce;this.color=color;
    this.gpu?.setNodes(update,this.color);this.draw();
  }

  finish(event:PointerEvent){
    const contact=this.contact;if(!contact||contact.pointer!==event.pointerId||contact.sealed)return;
    this.append(event,false);contact.sealed=true;
    return {points:contact.points,color:this.color,worldOrigin:contact.basis.origin};
  }

  /** Drop local pixels only after a saved scene has actually been installed. */
  presented(){if(this.contact?.sealed)this.clear();}
  clear(){
    this.contact?.geometry.dispose();this.contact=undefined;this.canvas.hidden=true;if(!this.closed)this.changed();
  }

  draw(){
    if(!this.gpu||!this.contact)return;
    const current=this.view(),center=this.surface().delta(this.contact.basis.origin,current.camera.center);
    const width=current.viewport.x/current.camera.scale,height=current.viewport.y/current.camera.scale;
    const frame:Frame={x:center.x-width/2,y:center.y-height/2,width,height};
    this.gpu.resize(Math.max(1,Math.ceil(current.viewport.x*current.pixelScale)),Math.max(1,Math.ceil(current.viewport.y*current.pixelScale)));
    this.gpu.draw(frame,this.contact.basis.clip);
  }

  dispose(){
    if(this.closed)return;this.closed=true;this.signal.removeEventListener('abort',this.abort);
    this.clear();this.gpu?.dispose();this.gpu=undefined;
  }
}

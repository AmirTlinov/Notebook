import {surfaceWasi} from './surface-wasi.js';
import type {WorldPoint} from '../src/domain.js';

type Exports={memory:WebAssembly.Memory;_initialize:()=>void;
  notebook_surface_alloc:(bytes:number)=>number;notebook_surface_free:(pointer:number)=>void;
  notebook_surface_minimum_scale:()=>number;notebook_surface_maximum_scale:()=>number;
  notebook_surface_camera:(input:number,output:number)=>number;
  notebook_surface_offset:(input:number,output:number)=>number;
  notebook_surface_delta:(input:number,output:number)=>number;
  notebook_surface_manipulate_frame:(kind:number,input:number,output:number)=>number;
  notebook_surface_pen_sample:(input:number,output:number)=>number;
  notebook_surface_ink_create:()=>number;notebook_surface_ink_free:(contact:number)=>void;
  notebook_surface_ink_update:(contact:number,input:number,count:number,changedFrom:number)=>number;
  notebook_surface_ink_dirty_start:(contact:number)=>number;
  notebook_surface_ink_vertex_count:(contact:number)=>number;
  notebook_surface_ink_nodes:(contact:number,output:number,capacity:number)=>number;
  notebook_surface_stroke_capacity:(count:number)=>number;
  notebook_surface_stroke:(input:number,count:number,output:number,capacity:number)=>number;};
const address=(p:WorldPoint)=>[p.tileX,p.tileY,p.localX,p.localY];
const point=(v:Float64Array):WorldPoint=>({tileX:v[0]!,tileY:v[1]!,localX:v[2]!,localY:v[3]!});
export type SurfaceCamera={center:WorldPoint;scale:number};
export type SurfacePoint={x:number;y:number};
export type SurfaceRect=SurfacePoint&{width:number;height:number};
// Numeric wire tags match NotebookElementResizeHandle.allCases. Edge behavior
// and size constraints are resolved only by the Swift surface.
const manipulationKinds={move:0,topLeading:1,topTrailing:2,bottomLeading:3,bottomTrailing:4,
  topCenter:5,bottomCenter:6,leadingCenter:7,trailingCenter:8} as const;
export type SurfaceManipulationKind=keyof typeof manipulationKinds;
const rectangle=(frame:SurfaceRect)=>[frame.x,frame.y,frame.width,frame.height];

/** One synchronous Swift module per panel; pointer events never wait for IPC. */
export class SwiftSurface {
  private buffer:number;
  private readonly contacts=new Set<SwiftInkContact>();
  get minimumScale(){return this.exports.notebook_surface_minimum_scale();}
  get maximumScale(){return this.exports.notebook_surface_maximum_scale();}
  private constructor(private wasm:Exports|undefined){this.buffer=this.allocate(32*8);}
  static async load(bytes:BufferSource):Promise<SwiftSurface>{
    let wasm:Exports;
    const result=await WebAssembly.instantiate(bytes,{wasi_snapshot_preview1:surfaceWasi(()=>wasm.memory)});
    wasm=result.instance.exports as Exports;wasm._initialize();return new SwiftSurface(wasm);
  }
  static async compressed(base64:string):Promise<SwiftSurface>{
    const data=Uint8Array.from(atob(base64),c=>c.charCodeAt(0));
    const stream=new Blob([data]).stream().pipeThrough(new DecompressionStream('gzip'));
    return this.load(await new Response(stream).arrayBuffer());
  }
  dispose(){
    for(const contact of this.contacts)contact.dispose();
    const wasm=this.wasm,buffer=this.buffer;
    this.wasm=undefined;this.buffer=0;
    if(wasm&&buffer)wasm.notebook_surface_free(buffer);
  }
  private get exports():Exports{
    if(!this.wasm)throw new Error('Surface is closed');
    return this.wasm;
  }
  private allocate(bytes:number){const p=this.exports.notebook_surface_alloc(bytes);if(!p)throw new RangeError('Surface buffer exceeds its budget');return p;}
  private invoke(fn:(input:number,output:number)=>number,values:number[]){
    const wasm=this.exports;
    new Float64Array(wasm.memory.buffer,this.buffer,32).set(values);
    if(fn(this.buffer,this.buffer+16*8)!==1)throw new RangeError('Invalid surface geometry');
    return new Float64Array(wasm.memory.buffer,this.buffer+16*8,16);
  }
  camera(camera:SurfaceCamera,viewport:SurfacePoint,from:SurfacePoint,to:SurfacePoint,magnification:number):SurfaceCamera{
    const v=this.invoke(this.exports.notebook_surface_camera,[...address(camera.center),camera.scale,viewport.x,viewport.y,from.x,from.y,to.x,to.y,magnification]);
    return {center:point(v),scale:v[4]!};
  }
  offset(origin:WorldPoint,x:number,y:number){return point(this.invoke(this.exports.notebook_surface_offset,[...address(origin),x,y]));}
  delta(origin:WorldPoint,destination:WorldPoint):SurfacePoint{
    const v=this.invoke(this.exports.notebook_surface_delta,[...address(origin),...address(destination)]);return {x:v[0]!,y:v[1]!};
  }
  penSample(force:number,previous:number|undefined,elapsed:number){
    const v=this.invoke(this.exports.notebook_surface_pen_sample,[force,previous??-1,elapsed]);
    return {width:v[0]!,opacity:v[1]!,filteredForce:v[2]!,color:{red:v[3]!,green:v[4]!,blue:v[5]!}};
  }
  inkContact(){
    const contact=new SwiftInkContact(this.exports,()=>this.contacts.delete(contact));
    this.contacts.add(contact);return contact;
  }
  manipulateFrame(kind:SurfaceManipulationKind,original:SurfaceRect,translation:SurfacePoint,bounds?:SurfaceRect):SurfaceRect{
    const wasm=this.exports;
    if(!Object.hasOwn(manipulationKinds,kind))throw new RangeError('Invalid surface manipulation');
    const v=this.invoke((input,output)=>wasm.notebook_surface_manipulate_frame(manipulationKinds[kind],input,output),
      [...rectangle(original),translation.x,translation.y,bounds?1:0,...(bounds?rectangle(bounds):[0,0,0,0])]);
    return {x:v[0]!,y:v[1]!,width:v[2]!,height:v[3]!};
  }
  stroke(points:Float32Array):Float32Array{
    const wasm=this.exports;
    const count=points.length/7;
    if(!Number.isInteger(count))throw new RangeError('Each point requires seven floats');
    const capacity=wasm.notebook_surface_stroke_capacity(count);
    if(!capacity)throw new RangeError('Invalid stroke point count');
    const input=this.allocate(points.byteLength);
    try{
      const output=this.allocate(capacity*6*4);
      try{
        new Float32Array(wasm.memory.buffer,input,points.length).set(points);
        const vertexCount=wasm.notebook_surface_stroke(input,count,output,capacity);
        if(vertexCount<=0)throw new RangeError('Invalid stroke geometry');
        return new Float32Array(wasm.memory.buffer,output,vertexCount*6).slice();
      }finally{wasm.notebook_surface_free(output);}
    }finally{wasm.notebook_surface_free(input);}
  }
}

/** The input and output buffers grow together only when a contact exceeds its
 * capacity. Each sample sends the changed suffix; Swift owns normalization. */
export class SwiftInkContact {
  private pointer:number;
  private input=0;
  private output=0;
  private capacity=0;
  private count=0;
  private nodeCount=0;
  private fullOutput=false;
  private points=new Float32Array(0);
  private nodes=new Float32Array(0);
  constructor(private instance:Exports|undefined,private released:(()=>void)|undefined){this.pointer=this.wasm.notebook_surface_ink_create();}
  private get wasm(){if(!this.instance)throw new Error('Ink contact is closed');return this.instance;}
  update(tail:Float32Array,changedFrom=this.count){
    if(!this.pointer)throw new Error('Ink contact is closed');
    const count=changedFrom+tail.length/7;
    if(!Number.isInteger(count)||!Number.isInteger(changedFrom)||changedFrom<0||changedFrom>this.count||count<1||count>65_536)
      throw new RangeError('Invalid ink contact size');
    const grew=count>this.capacity;
    if(grew){
      const capacity=Math.max(256,2**Math.ceil(Math.log2(count)));
      const input=this.wasm.notebook_surface_alloc(capacity*7*4),output=this.wasm.notebook_surface_alloc(capacity*6*4);
      if(!input||!output){if(input)this.wasm.notebook_surface_free(input);if(output)this.wasm.notebook_surface_free(output);throw new RangeError('Ink buffer exceeds its budget');}
      if(this.input)this.wasm.notebook_surface_free(this.input);if(this.output)this.wasm.notebook_surface_free(this.output);
      this.input=input;this.output=output;this.capacity=capacity;
      this.fullOutput=true;
      const points=new Float32Array(capacity*7);points.set(this.points);this.points=points;
      const nodes=new Float32Array(capacity*6);nodes.set(this.nodes);this.nodes=nodes;
    }
    const input=new Float32Array(this.wasm.memory.buffer,this.input,this.capacity*7);
    if(grew)input.set(this.points.subarray(0,this.count*7));
    input.set(tail,changedFrom*7);
    const total=this.wasm.notebook_surface_ink_update(this.pointer,this.input,count,changedFrom);
    if(total<=0){
      // The Swift owner refused atomically. Restore the measured prefix too,
      // so a later append can still resume the same contact after bad input.
      new Float32Array(this.wasm.memory.buffer,this.input,this.capacity*7)
        .set(this.points.subarray(changedFrom*7,this.count*7),changedFrom*7);
      throw new RangeError('Invalid ink geometry');
    }
    this.points.set(tail,changedFrom*7);
    const first=this.wasm.notebook_surface_ink_dirty_start(this.pointer);
    const dirty=this.wasm.notebook_surface_ink_nodes(this.pointer,this.output,this.capacity);
    if(dirty<0)throw new RangeError('Ink geometry exceeds its buffer');
    this.nodes.set(new Float32Array(this.wasm.memory.buffer,this.output,dirty*6),first*6);this.count=count;this.nodeCount=total;
    const outputStart=this.fullOutput?0:first;this.fullOutput=false;
    return {first:outputStart,total,capacity:this.capacity,vertexCount:this.wasm.notebook_surface_ink_vertex_count(this.pointer),nodes:this.nodes.subarray(outputStart*6,total*6)};
  }
  snapshot(){
    if(!this.pointer||!this.count)throw new Error('Ink contact has no geometry');
    // Only GPU recovery needs the entire prepared prefix.
    return {first:0,total:this.nodeCount,capacity:this.capacity,vertexCount:this.wasm.notebook_surface_ink_vertex_count(this.pointer),
      nodes:this.nodes.subarray(0,this.nodeCount*6)};
  }
  dispose(){
    if(!this.pointer)return;
    this.wasm.notebook_surface_ink_free(this.pointer);this.pointer=0;
    if(this.input)this.wasm.notebook_surface_free(this.input);if(this.output)this.wasm.notebook_surface_free(this.output);
    this.input=0;this.output=0;this.points=new Float32Array(0);this.nodes=new Float32Array(0);
    this.instance=undefined;this.released?.();this.released=undefined;
  }
}

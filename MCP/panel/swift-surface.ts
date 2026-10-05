import {surfaceWasi} from './surface-wasi.js';
import type {WorldPoint} from '../src/domain.js';

type Exports={memory:WebAssembly.Memory;_initialize:()=>void;
  notebook_surface_alloc:(bytes:number)=>number;notebook_surface_free:(pointer:number)=>void;
  notebook_surface_camera:(input:number,output:number)=>number;
  notebook_surface_offset:(input:number,output:number)=>number;
  notebook_surface_delta:(input:number,output:number)=>number;
  notebook_surface_stroke_capacity:(count:number)=>number;
  notebook_surface_stroke:(input:number,count:number,output:number,capacity:number)=>number;};
const address=(p:WorldPoint)=>[p.tileX,p.tileY,p.localX,p.localY];
const point=(v:Float64Array):WorldPoint=>({tileX:v[0]!,tileY:v[1]!,localX:v[2]!,localY:v[3]!});
export type SurfaceCamera={center:WorldPoint;scale:number};
export type SurfacePoint={x:number;y:number};

/** One synchronous Swift module per panel; pointer events never wait for IPC. */
export class SwiftSurface {
  private buffer:number;
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

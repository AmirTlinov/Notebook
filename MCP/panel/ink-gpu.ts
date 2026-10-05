/// <reference types="@webgpu/types" />
import type {Frame, Point} from './model.js';
import {panelPixelBudget} from './projection.js';

const shader=`
struct View { frame:vec4f, color:vec4f, counts:vec4u }
@group(0) @binding(0) var<uniform> view:View;
struct Node { p:vec2f, edge:vec2f, radius:f32, alpha:f32 }
@group(0) @binding(1) var<storage,read> nodes:array<Node>;
struct Vertex { @builtin(position) p:vec4f, @location(0) color:vec4f }
@vertex fn vertex(@location(0) p:vec2f,@location(1) color:vec4f)->Vertex {
  let unit=(p-view.frame.xy)/view.frame.zw;
  var v:Vertex;v.p=vec4f(unit.x*2-1,1-unit.y*2,0,1);v.color=color;return v;
}
fn direction(a:vec2f,b:vec2f)->vec2f {
  let d=b-a;
  if(!(dot(d,d)>0.0001)){return vec2f(1,0);}
  if(d.y==0){return vec2f(select(-1.0,1.0,d.x>0),0);}
  if(d.x==0){return vec2f(0,select(-1.0,1.0,d.y>0));}
  return normalize(d);
}
@vertex fn compact(@builtin(vertex_index) id:u32)->Vertex {
  let count=view.counts.x;var n=0u;var p:vec2f;
  let strip=(count-1)*6;
  if(count>1&&id<strip){
    let sides=array<u32,6>(0,1,2,1,3,2);let side=sides[id%6];
    n=id/6+side/2;p=nodes[n].p+nodes[n].edge*select(1.0,-1.0,side%2==1);
  }else{
    let disk=count==1;let first=disk||id<strip+36;
    n=select(count-1,0u,first);
    let local=select(id-strip-select(36u,0u,first),id,disk);
    let slot=local%3;
    p=nodes[n].p;
    if(slot>0){
      var angle=0.0;var sweep=6.283185307179586;var segments=24.0;
      if(!disk){
        var outward:vec2f;
        if(first){outward=-direction(nodes[0].p,nodes[1].p);}
        else{outward=direction(nodes[count-2].p,nodes[count-1].p);}
        angle=atan2(outward.y,outward.x)-1.570796326794897;sweep=3.141592653589793;segments=12.0;
      }
      let index=local/3+slot-1;
      let theta=select(angle+f32(index)/segments*sweep,angle,disk&&index==24);
      p+=vec2f(cos(theta),sin(theta))*nodes[n].radius;
    }
  }
  let unit=(p-view.frame.xy)/view.frame.zw;let a=nodes[n].alpha;
  var v:Vertex;v.p=vec4f(unit.x*2-1,1-unit.y*2,0,1);v.color=vec4f(a,a,a,a);return v;
}
@fragment fn fragment(v:Vertex)->@location(0) vec4f{return v.color*view.color;}`;

/** Platform painter for the triangles prepared by NotebookSurface. Geometry,
 * pressure and edits stay outside the GPU adapter; pixels use native blending. */
export class InkGPU {
  private vertices:GPUBuffer|undefined;
  private capacity=0;
  private count=0;
  private nodeCount=0;
  private compactBinding:GPUBindGroup|undefined;
  private color=[1,1,1,1];
  private detach=()=>{};
  private multisample:GPUTexture|undefined;
  private size:Point={x:0,y:0};
  private closed=false;
  private failure:Error|undefined;
  private readonly uniform:GPUBuffer;
  private readonly binding:GPUBindGroup;

  private constructor(private readonly canvas:HTMLCanvasElement,private readonly context:GPUCanvasContext,
    private readonly device:GPUDevice,private readonly format:GPUTextureFormat,private readonly pipeline:GPURenderPipeline,
    private readonly compactPipeline:GPURenderPipeline,
    failed:(error:Error)=>void){
    this.uniform=device.createBuffer({label:'Notebook ink viewport',size:48,usage:GPUBufferUsage.UNIFORM|GPUBufferUsage.COPY_DST});
    this.binding=device.createBindGroup({layout:pipeline.getBindGroupLayout(0),entries:[{binding:0,resource:{buffer:this.uniform}}]});
    device.addEventListener('uncapturederror',event=>this.fail(new Error(event.error.message),failed));
    void device.lost.then(info=>{if(info.reason!=='destroyed')this.fail(new Error(info.message||'GPU недоступен.'),failed);});
  }

  static async create(canvas:HTMLCanvasElement,signal:AbortSignal,failed:(error:Error)=>void):Promise<InkGPU>{
    signal.throwIfAborted();
    if(!navigator.gpu)throw new Error('WebGPU недоступен в панели Notebook.');
    const adapter=await navigator.gpu.requestAdapter();signal.throwIfAborted();
    if(!adapter)throw new Error('Не удалось подключить GPU.');
    const device=await adapter.requestDevice();
    try{
      signal.throwIfAborted();
      const context=canvas.getContext('webgpu');if(!context)throw new Error('Не удалось открыть поверхность GPU.');
      const format=navigator.gpu.getPreferredCanvasFormat(),module=device.createShaderModule({code:shader});
      const blend:GPUBlendComponent={srcFactor:'one',dstFactor:'one-minus-src-alpha',operation:'add'};
      const descriptor:GPURenderPipelineDescriptor={label:'Notebook canonical ink',layout:'auto',
        vertex:{module,entryPoint:'vertex',buffers:[{arrayStride:24,attributes:[
          {shaderLocation:0,offset:0,format:'float32x2'},{shaderLocation:1,offset:8,format:'float32x4'}]}]},
        fragment:{module,entryPoint:'fragment',targets:[{format,blend:{color:blend,alpha:blend}}]},
        primitive:{topology:'triangle-list'},multisample:{count:4}};
      const [pipeline,compactPipeline]=await Promise.all([device.createRenderPipelineAsync(descriptor),
        device.createRenderPipelineAsync({...descriptor,vertex:{module,entryPoint:'compact'}})]);
      signal.throwIfAborted();
      context.configure({device,format,alphaMode:'premultiplied',usage:GPUTextureUsage.RENDER_ATTACHMENT|GPUTextureUsage.COPY_SRC});
      const result=new InkGPU(canvas,context,device,format,pipeline,compactPipeline,failed);
      const close=()=>result.dispose();signal.addEventListener('abort',close,{once:true});
      result.detach=()=>signal.removeEventListener('abort',close);
      return result;
    }catch(error){device.destroy();throw error;}
  }

  private fail(error:Error,notify:(error:Error)=>void){if(!this.closed&&!this.failure){this.failure=error;notify(error);}}
  private requireOpen(){if(this.closed)throw new Error('Поверхность GPU закрыта.');if(this.failure)throw this.failure;}

  setMesh(vertices:Float32Array){
    this.requireOpen();
    if(vertices.length%18||vertices.byteLength>64*1024*1024)throw new RangeError('Неверный размер геометрии штриха.');
    this.reserve(vertices.byteLength);this.nodeCount=0;this.color=[1,1,1,1];
    this.count=vertices.length/6;
    if(this.count)this.device.queue.writeBuffer(this.vertices!,0,vertices as Float32Array<ArrayBuffer>);
  }

  private reserve(bytes:number){
    if(bytes>this.capacity){
      this.vertices?.destroy();this.capacity=Math.max(4096,2**Math.ceil(Math.log2(bytes)));
      this.vertices=this.device.createBuffer({label:'Notebook ink geometry',size:this.capacity,usage:GPUBufferUsage.VERTEX|GPUBufferUsage.STORAGE|GPUBufferUsage.COPY_DST});
      this.compactBinding=this.device.createBindGroup({layout:this.compactPipeline.getBindGroupLayout(0),entries:[
        {binding:0,resource:{buffer:this.uniform}},{binding:1,resource:{buffer:this.vertices}}]});
    }
  }

  setNodes(update:{first:number;total:number;capacity:number;vertexCount:number;nodes:Float32Array},color:{red:number;green:number;blue:number}){
    this.requireOpen();
    if(!Number.isSafeInteger(update.capacity)||update.capacity<update.total||update.capacity*24>64*1024*1024||update.first<0||update.first>update.total||update.nodes.length!==(update.total-update.first)*6)
      throw new RangeError('Неверный хвост геометрии штриха.');
    if(update.capacity*24>this.capacity&&update.first!==0)throw new Error('Новый GPU buffer требует полный источник.');
    this.reserve(update.capacity*24);this.nodeCount=update.total;this.count=update.vertexCount;
    this.color=[color.red,color.green,color.blue,1];
    this.device.queue.writeBuffer(this.vertices!,update.first*24,update.nodes as Float32Array<ArrayBuffer>);
  }

  resize(width:number,height:number){
    this.requireOpen();
    if(!Number.isSafeInteger(width)||!Number.isSafeInteger(height)||width<1||height<1)
      throw new RangeError('Неверный размер поверхности GPU.');
    // Display density changes the backing allocation, never the CSS viewport
    // or contact geometry. Match the scene's pixel budget on large displays.
    const scale=Math.min(1,this.device.limits.maxTextureDimension2D/Math.max(width,height),
      Math.sqrt(panelPixelBudget/width/height));
    width=Math.max(1,Math.floor(width*scale));height=Math.max(1,Math.floor(height*scale));
    if(this.size.x===width&&this.size.y===height)return;
    this.multisample?.destroy();this.canvas.width=width;this.canvas.height=height;
    this.multisample=this.device.createTexture({label:'Notebook ink antialiasing',size:{width,height},sampleCount:4,
      format:this.format,usage:GPUTextureUsage.RENDER_ATTACHMENT});this.size={x:width,y:height};
  }

  private encode(view:Frame,clip?:Frame){
    this.requireOpen();
    if(!this.multisample)throw new Error('Поверхность GPU ещё не имеет размера.');
    if(!Object.values(view).every(Number.isFinite)||view.width<=0||view.height<=0)throw new RangeError('Неверная камера GPU.');
    const uniforms=new ArrayBuffer(48);
    new Float32Array(uniforms).set([view.x,view.y,view.width,view.height,...this.color]);
    new Uint32Array(uniforms)[8]=this.nodeCount;this.device.queue.writeBuffer(this.uniform,0,uniforms);
    const texture=this.context.getCurrentTexture(),encoder=this.device.createCommandEncoder();
    const pass=encoder.beginRenderPass({colorAttachments:[{view:this.multisample.createView(),resolveTarget:texture.createView(),
      clearValue:{r:0,g:0,b:0,a:0},loadOp:'clear',storeOp:'discard'}]});
    let visible=true;
    if(clip){
      const left=Math.max(0,Math.floor((clip.x-view.x)/view.width*this.size.x));
      const top=Math.max(0,Math.floor((clip.y-view.y)/view.height*this.size.y));
      const right=Math.min(this.size.x,Math.ceil((clip.x+clip.width-view.x)/view.width*this.size.x));
      const bottom=Math.min(this.size.y,Math.ceil((clip.y+clip.height-view.y)/view.height*this.size.y));
      visible=right>left&&bottom>top;
      if(visible)pass.setScissorRect(left,top,right-left,bottom-top);
    }
    if(this.count&&visible){
      pass.setPipeline(this.nodeCount?this.compactPipeline:this.pipeline);pass.setBindGroup(0,this.nodeCount?this.compactBinding!:this.binding);
      if(!this.nodeCount)pass.setVertexBuffer(0,this.vertices!);pass.draw(this.count);
    }
    pass.end();return {texture,encoder};
  }

  draw(view:Frame,clip?:Frame){this.device.queue.submit([this.encode(view,clip).encoder.finish()]);}

  /** Acceptance reads the very same submitted surface, including MSAA/blend. */
  async sample(view:Frame,point:Point):Promise<number[]>{
    const {texture,encoder}=this.encode(view);
    if(!Number.isSafeInteger(point.x)||!Number.isSafeInteger(point.y)||point.x<0||point.y<0||point.x>=this.size.x||point.y>=this.size.y)
      throw new RangeError('Пиксель вне поверхности.');
    const buffer=this.device.createBuffer({size:256,usage:GPUBufferUsage.COPY_DST|GPUBufferUsage.MAP_READ});
    try{
      encoder.copyTextureToBuffer({texture,origin:point},{buffer,bytesPerRow:256},{width:1,height:1});
      this.device.queue.submit([encoder.finish()]);await buffer.mapAsync(GPUMapMode.READ);
      const pixel=Array.from(new Uint8Array(buffer.getMappedRange()).slice(0,4));buffer.unmap();
      return this.format.startsWith('bgra')?[pixel[2]!,pixel[1]!,pixel[0]!,pixel[3]!]:pixel;
    }finally{buffer.destroy();}
  }

  dispose(){
    if(this.closed)return;this.closed=true;
    this.detach();
    this.vertices?.destroy();this.multisample?.destroy();this.uniform.destroy();this.context.unconfigure();this.device.destroy();
  }
}

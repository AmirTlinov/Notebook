import {App} from '@modelcontextprotocol/ext-apps';
import {SwiftSurface} from '../../panel/swift-surface.js';
const app=new App({name:'Notebook surface verification',version:'1.0.0'});
const results=document.getElementById('results'),evidence=document.getElementById('evidence');
const report={moduleSHA256:SURFACE_WASM_SHA256,secureContext:isSecureContext,checks:{}};
const show=(name,state,detail)=>{
  report.checks[name]={state,detail};
  results.replaceChildren(...Object.entries(report.checks).map(([key,value])=>{
    const row=document.createElement('li');row.textContent=`${key}: ${value.state} — ${value.detail}`;return row;
  }));evidence.textContent=JSON.stringify(report,null,2);
};
let kernel,device,program;
async function wasm(){
  const started=performance.now();kernel=await SwiftSurface.compressed(SURFACE_WASM_GZIP);
  const camera={center:{tileX:9_007_199_254_740_000,tileY:-9_007_199_254_740_000,localX:30,localY:40},scale:1};
  const next=kernel.camera(camera,{x:600,y:180},{x:300,y:90},{x:320,y:100},2);
  if(next.center.localX!==20||next.center.localY!==35||next.scale!==2)throw Error('Incorrect Swift camera transform');
  const duration=performance.now()-started;
  show('Swift/WASM','PASS',`Загрузка и точная камера: ${duration.toFixed(1)} мс`);
}
async function gpu(){
  if(!navigator.gpu)throw Error('navigator.gpu отсутствует в панели');
  const adapter=await navigator.gpu.requestAdapter();if(!adapter)throw Error('GPU adapter недоступен');
  device=await adapter.requestDevice();device.pushErrorScope('validation');
  const canvas=document.getElementById('gpu'),context=canvas.getContext('webgpu');
  if(!context)throw Error('Контекст WebGPU недоступен');
  const format=navigator.gpu.getPreferredCanvasFormat();
  context.configure({device,format,alphaMode:'premultiplied',usage:GPUTextureUsage.RENDER_ATTACHMENT|GPUTextureUsage.COPY_SRC});
  const shader=device.createShaderModule({code:`
struct Vertex { @builtin(position) p:vec4f, @location(0) color:vec4f }
@vertex fn vertex(@location(0) p:vec2f,@location(1) color:vec4f)->Vertex {
  var v:Vertex;v.p=vec4f(p.x/300.0-1.0,1.0-p.y/90.0,0.0,1.0);v.color=color;return v;
}
@fragment fn fragment(v:Vertex)->@location(0) vec4f{return v.color;}`});
  const pipeline=await device.createRenderPipelineAsync({layout:'auto',vertex:{module:shader,entryPoint:'vertex',buffers:[{arrayStride:24,attributes:[{shaderLocation:0,offset:0,format:'float32x2'},{shaderLocation:1,offset:8,format:'float32x4'}]}]},
    fragment:{module:shader,entryPoint:'fragment',targets:[{format}]},primitive:{topology:'triangle-list'}});
  const points=new Float32Array(3*7);points.set([80,90,8,.7,.1,.4,1,300,90,8,.7,.1,.4,1,520,90,8,.7,.1,.4,1]);
  const vertices=kernel?kernel.stroke(points):new Float32Array([80,80,.7,.1,.4,1,300,100,.7,.1,.4,1,520,80,.7,.1,.4,1]);
  const buffer=device.createBuffer({size:vertices.byteLength,usage:GPUBufferUsage.VERTEX|GPUBufferUsage.COPY_DST});
  device.queue.writeBuffer(buffer,0,vertices);
  const pixels=device.createBuffer({size:256,usage:GPUBufferUsage.COPY_DST|GPUBufferUsage.MAP_READ});
  try{
    const texture=context.getCurrentTexture(),encoder=device.createCommandEncoder();
    const pass=encoder.beginRenderPass({colorAttachments:[{view:texture.createView(),clearValue:{r:1,g:1,b:1,a:1},loadOp:'clear',storeOp:'store'}]});
    pass.setPipeline(pipeline);pass.setVertexBuffer(0,buffer);pass.draw(vertices.length/6);pass.end();
    encoder.copyTextureToBuffer({texture,origin:{x:300,y:90}},{buffer:pixels,bytesPerRow:256},{width:1,height:1});
    device.queue.submit([encoder.finish()]);await pixels.mapAsync(GPUMapMode.READ);
    const pixel=Array.from(new Uint8Array(pixels.getMappedRange()).slice(0,4));pixels.unmap();
    const error=await device.popErrorScope();if(error)throw Error(error.message);
    if(pixel[3]!==255||pixel.slice(0,3).every(value=>value===255))throw Error(`GPU не нарисовал геометрию: ${pixel}`);
    show('WebGPU','PASS',`${kernel?'Штрих Swift':'Тестовый треугольник'}: ${vertices.length/6} вершин; GPU pixel ${pixel.join(', ')}`);
  }finally{buffer.destroy();pixels.destroy();}
}
async function isolatedProgram(){
  const token=crypto.randomUUID();program=document.createElement('iframe');
  program.title='Изолированная программа';program.sandbox='allow-scripts';
  const source=`<!doctype html><html lang="ru"><head><meta charset="utf-8"></head><body><p>Изолированная программа</p><button id="step">Счётчик: 0</button><script>
  let count=0;const token=${JSON.stringify(token)};let isolated=false;try{void parent.document.body}catch{isolated=true}
  function report(){parent.postMessage({notebookSurfaceCheck:token,count,isolated,charset:document.characterSet,title:document.querySelector('p').textContent,counter:document.getElementById('step').textContent},'*')}
  document.getElementById('step').onclick=()=>{count++;document.getElementById('step').textContent='Счётчик: '+count;report()};report();
  <\/script></body></html>`;
  const url=URL.createObjectURL(new Blob([source],{type:'text/html;charset=utf-8'}));program.src=url;
  await new Promise((resolve,reject)=>{
    const timeout=setTimeout(()=>{window.removeEventListener('message',received);URL.revokeObjectURL(url);reject(Error('Программа не прислала готовность за 5 секунд'));},5000);
    function received(event){
      if(event.source!==program.contentWindow||event.data?.notebookSurfaceCheck!==token)return;
      clearTimeout(timeout);URL.revokeObjectURL(url);
      const error=!event.data.isolated?'Программа получила доступ к DOM панели':
        event.data.charset!=='UTF-8'||event.data.title!=='Изолированная программа'||event.data.counter!==`Счётчик: ${event.data.count}`?'Повреждена кодировка текста программы':null;
      if(error){window.removeEventListener('message',received);show('Изоляция программы','FAIL',error);reject(Error(error));return;}
      show('Изоляция программы','PASS',`Отдельный origin; UTF-8; счётчик ${event.data.count}`);resolve();
    }
    window.addEventListener('message',received);document.getElementById('program').replaceChildren(program);
  });
}
const text=document.getElementById('text');let compositions=0;
const inputStatus=composing=>{document.getElementById('input-status').textContent=`${text.value.length} символов; композиции IME: ${compositions}; composing: ${composing}`;};
text.addEventListener('compositionend',()=>{compositions++;inputStatus(false);});
text.addEventListener('input',event=>inputStatus(event.isComposing));
document.getElementById('run').onclick=async()=>{
  document.getElementById('run').disabled=true;
  for(const [name,check] of [['Swift/WASM',wasm],['WebGPU',gpu],['Изоляция программы',isolatedProgram]]){
    try{await check();}catch(error){show(name,'FAIL',String(error));}
  }
  document.getElementById('run').textContent='Проверка завершена';
};
window.addEventListener('pagehide',()=>{kernel?.dispose();device?.destroy();program?.remove();},{once:true});
void app.connect().catch(error=>show('MCP Apps','FAIL',String(error)));

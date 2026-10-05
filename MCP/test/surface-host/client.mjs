import {App} from '@modelcontextprotocol/ext-apps';
import {SwiftSurface} from '../../panel/swift-surface.js';
import {InkGPU} from '../../panel/ink-gpu.js';
import {panelPixelBudget} from '../../panel/projection.js';
const app=new App({name:'Notebook surface verification',version:'1.0.0'});
const results=document.getElementById('results'),evidence=document.getElementById('evidence');
const report={moduleSHA256:SURFACE_WASM_SHA256,secureContext:isSecureContext,checks:{}};
const show=(name,state,detail)=>{
  report.checks[name]={state,detail};
  results.replaceChildren(...Object.entries(report.checks).map(([key,value])=>{
    const row=document.createElement('li');row.textContent=`${key}: ${value.state} — ${value.detail}`;return row;
  }));evidence.textContent=JSON.stringify(report,null,2);
};
let kernel,gpuRenderer,program;
const lifetime=new AbortController();
async function wasm(){
  const started=performance.now(),loaded=await SwiftSurface.compressed(SURFACE_WASM_GZIP);
  if(lifetime.signal.aborted){loaded.dispose();return;}
  kernel=loaded;
  const camera={center:{tileX:9_007_199_254_740_000,tileY:-9_007_199_254_740_000,localX:30,localY:40},scale:1};
  const next=kernel.camera(camera,{x:600,y:180},{x:300,y:90},{x:320,y:100},2);
  if(next.center.localX!==20||next.center.localY!==35||next.scale!==2)throw Error('Incorrect Swift camera transform');
  const duration=performance.now()-started;
  show('Swift/WASM','PASS',`Загрузка и точная камера: ${duration.toFixed(1)} мс`);
}
async function gpu(){
  if(!kernel)throw Error('Сначала нужен успешно загруженный Swift-модуль');
  gpuRenderer=await InkGPU.create(document.getElementById('gpu'),lifetime.signal,
    error=>show('WebGPU','FAIL',error.message));
  gpuRenderer.resize(600,180);
  const points=new Float32Array([80,90,8,.7,.1,.4,1,300,90,8,.7,.1,.4,1,520,90,8,.7,.1,.4,1]);
  const vertices=kernel.stroke(points);gpuRenderer.setMesh(vertices);
  const pixel=await gpuRenderer.sample({x:0,y:0,width:600,height:180},{x:300,y:90});
  if(pixel.some((value,index)=>Math.abs(value-[179,26,102,255][index])>1))throw Error(`Неверный GPU pixel: ${pixel}`);
  const contact=kernel.inkContact();
  try{
    // Cross both GPU byte and Swift contact growth boundaries. Ordinary input
    // uploads only the changed suffix, including prediction retraction.
    for(let index=0;index<300;index++){
      gpuRenderer.setNodes(contact.update(new Float32Array([80+index*440/299,90,8,.7,.1,.4,1])),{red:.7,green:.1,blue:.4});
    }
    const compact=await gpuRenderer.sample({x:0,y:0,width:600,height:180},{x:300,y:90});
    if(compact.some((value,index)=>Math.abs(value-pixel[index])>1))throw Error(`Compact GPU pixel: ${compact}; canonical: ${pixel}`);
    show('WebGPU','PASS',`Swift: ${vertices.length/6} вершин; 300 incremental samples; MSAA 4×; RGBA ${compact.join(', ')}`);
  }finally{contact.dispose();}
  const curve=new Float32Array(48*7),probes=[];
  for(let i=0;i<48;i++){
    const x=80+i*440/47,y=90+Math.sin(i/47*Math.PI*2)*32,radius=4+i/47*6,alpha=.25+i/47*.65;
    curve.set([x,y,radius,.7*alpha,.1*alpha,.4*alpha,alpha],i*7);
    if(i%8===0)probes.push({x:Math.round(x),y:Math.round(y+radius-1)});
  }
  const canonical=[],view={x:0,y:0,width:600,height:180};
  gpuRenderer.setMesh(kernel.stroke(curve));
  for(const point of probes)canonical.push(await gpuRenderer.sample(view,point));
  const curvedContact=kernel.inkContact();
  try{
    gpuRenderer.setNodes(curvedContact.update(curve),{red:.7,green:.1,blue:.4});
    for(let i=0;i<probes.length;i++){
      const actual=await gpuRenderer.sample(view,probes[i]);
      if(actual.some((value,c)=>Math.abs(value-canonical[i][c])>1))throw Error(`Контур/давление GPU: ${actual}; canonical: ${canonical[i]}`);
    }
    show('Контур и давление','PASS',`${probes.length} пикселей контура совпали с каноническим Swift-штрихом`);
  }finally{curvedContact.dispose();}
  const canvas=document.getElementById('gpu'),sizes=[];
  gpuRenderer.setMesh(vertices);
  for(const [width,height] of [[6016,3384],[32768,256],[600,180]]){
    gpuRenderer.resize(width,height);
    if(canvas.width*canvas.height>panelPixelBudget)throw Error('Превышен бюджет пикселей');
    const actual=await gpuRenderer.sample(view,{x:Math.floor(canvas.width/2),y:Math.floor(canvas.height/2)});
    if(actual.some((value,c)=>Math.abs(value-pixel[c])>1))throw Error(`Resize GPU pixel: ${actual}`);
    sizes.push(`${width}×${height} → ${canvas.width}×${canvas.height}`);
  }
  show('Retina/resize','PASS',sizes.join('; '));
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
    window.addEventListener('message',received,{signal:lifetime.signal});document.getElementById('program').replaceChildren(program);
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
const close=()=>{lifetime.abort();kernel?.dispose();gpuRenderer?.dispose();program?.remove();};
window.addEventListener('pagehide',close,{once:true});
app.onteardown=async()=>{close();return {};};
void app.connect().catch(error=>show('MCP Apps','FAIL',String(error)));

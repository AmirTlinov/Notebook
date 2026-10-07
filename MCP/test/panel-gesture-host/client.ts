import {App} from '@modelcontextprotocol/ext-apps';
import {Surface} from '../../panel/surface.js';
import type {AppearanceLayer, PanelSnapshot, PanelView} from '../../panel/model.js';
import {TILE_SIZE} from '../../src/spatial.js';

// The mounted panel, Swift camera and image owner are production code. Only the
// external tool transport and decoder completion are controlled by this probe.
const workspaceID=crypto.randomUUID(),a=crypto.randomUUID(),b=crypto.randomUUID(),epoch=crypto.randomUUID();
const origin={tileX:0,tileY:0,localX:0,localY:0},socketKey='0123456789abcdef01234567';
type Reply=Awaited<ReturnType<App['callServerTool']>>;
type Mode='late-pixels'|'late-error'|'held-decode';
type HeldDecode={url:string;finish:()=>void;fail:()=>void};
const trace:{event:string;detail:unknown}[]=[],held:HeldDecode[]=[],decoders=new Map<string,boolean>();
const reads={A:0,B:0},installs={A:0,B:0};
let mode:Mode='late-pixels',armed=true,holdDecoders=0,app:App|undefined;
let pending:{reply:Reply;finish:(value:Reply)=>void;signal:AbortSignal|undefined}|undefined;
let installed='none',earlyReleases=0;
const probe=document.createElement('aside');
probe.style.cssText='position:fixed;right:8px;top:52px;z-index:4;width:320px;max-height:70vh;overflow:auto;padding:12px;background:#ffffffed;border:1px solid #bcc9cf;border-radius:10px;font-size:12px';
probe.innerHTML='<strong>Граница навигации · actual panel DOM</strong><p>Откройте папку B двойным щелчком. Пока ответ удержан, начните pan, wheel или zoom на A.</p>'
  +'<label>Следующий переход <select id="probe-mode"><option value="late-pixels">Поздние пиксели</option><option value="late-error">Поздняя ошибка</option><option value="held-decode">Два удержанных декодера</option></select></label>'
  +'<button id="probe-reply">Вернуть ответ</button><button id="probe-first">Первый декодер: ошибка</button><button id="probe-second">Завершить декодеры</button>'
  +'<button id="probe-resize">Изменить ширину панели</button><button id="probe-close">Закрыть владельца</button><pre id="probe-evidence" style="white-space:pre-wrap;font-size:10px"></pre>';
document.body.append(probe);
function record(event:string,detail:unknown={}){trace.push({event,detail});show();}
function show(){
  const paper=document.getElementById('paper')!;
  probe.querySelector('#probe-evidence')!.textContent=JSON.stringify({installed,earlyReleases,
    reads,installs,
    viewBox:paper.getAttribute('viewBox'),captured:paper.hasPointerCapture(1),
    pending:!!pending,aborted:pending?.signal?.aborted,held:held.length,
    status:document.getElementById('status')!.textContent,trace:trace.slice(-16)},null,2);
}
probe.querySelector<HTMLSelectElement>('#probe-mode')!.onchange=event=>{
  mode=(event.target as HTMLSelectElement).value as Mode;armed=true;record('arm',mode);
};
probe.querySelector<HTMLButtonElement>('#probe-reply')!.onclick=()=>{
  const request=pending;if(!request)return;pending=undefined;
  record('late-reply',{aborted:request.signal?.aborted,mode});request.finish(request.reply);
};
probe.querySelector<HTMLButtonElement>('#probe-first')!.onclick=()=>{held.shift()?.fail();show();};
probe.querySelector<HTMLButtonElement>('#probe-second')!.onclick=()=>{for(const decoder of held.splice(0))decoder.finish();show();};
probe.querySelector<HTMLButtonElement>('#probe-resize')!.onclick=()=>{
  const workspace=document.getElementById('workspace')!;
  workspace.style.width=workspace.style.width?'':'72vw';record('resize',workspace.clientWidth);
};
probe.querySelector<HTMLButtonElement>('#probe-close')!.onclick=async()=>{
  if(!app)return;
  await app.onteardown?.({},{} as never);record('closed');
};
const decode=HTMLImageElement.prototype.decode;
HTMLImageElement.prototype.decode=async function(){
  const url=this.src;decoders.set(url,false);
  let wait:Promise<void>|undefined;
  if(holdDecoders>0){
    holdDecoders--;
    wait=new Promise<void>((finish,fail)=>held.push({url,finish,fail:()=>fail(new Error('Controlled decoder failure'))}));
    void wait.catch(()=>{});
    record('decode-held',{url});
  }
  try{await decode.call(this);await wait;}
  finally{decoders.set(url,true);record('decode-finished',{url});}
};
const revoke=URL.revokeObjectURL.bind(URL);
URL.revokeObjectURL=url=>{
  if(decoders.get(url)===false)earlyReleases++;
  record('resource-release',{url,joined:decoders.get(url)!==false});revoke(url);
};
const render=Surface.prototype.render;
Surface.prototype.render=function(snapshot){
  render.call(this,snapshot);installed=snapshot.target.id===a?'A':'B';
  installs[installed as 'A'|'B']++;
  record('installed',{target:installed,assets:this.assetIDs});
};
const cancel=Surface.prototype.cancelPreparation;
Surface.prototype.cancelPreparation=function(){
  const joined=cancel.call(this);record('preparation-withdrawn');
  void joined.then(()=>record('preparation-joined'));return joined;
};
new MutationObserver(show).observe(document.getElementById('paper')!,{attributes:true,attributeFilter:['viewBox']});
new MutationObserver(show).observe(document.getElementById('status')!,{childList:true,subtree:true});

async function raster(label:string,fill:string,frame:{x:number;y:number;width:number;height:number},itemID?:string):Promise<AppearanceLayer>{
  const canvas=document.createElement('canvas');canvas.width=frame.width*2;canvas.height=frame.height*2;
  const context=canvas.getContext('2d')!;context.scale(2,2);context.fillStyle=fill;context.fillRect(0,0,frame.width,frame.height);
  context.strokeStyle='#7594a5';context.strokeRect(1,1,frame.width-2,frame.height-2);
  context.fillStyle='#253c49';context.font='20px system-ui';context.fillText(label,20,frame.height/2);
  const pngBase64=canvas.toDataURL('image/png').split(',')[1]!;
  const bytes=Uint8Array.from(atob(pngBase64),value=>value.charCodeAt(0));
  const sha256=[...new Uint8Array(await crypto.subtle.digest('SHA-256',bytes))].map(value=>value.toString(16).padStart(2,'0')).join('');
  return {id:crypto.randomUUID(),assetID:crypto.randomUUID(),order:1,worldOrigin:origin,frame,
    pixelWidth:canvas.width,pixelHeight:canvas.height,pngBase64,sha256,...(itemID?{itemID}:{})};
}
const cards=[await raster('Открыть папку B','#e9f0f2',{x:200,y:130,width:240,height:140},b)];
const destination=[await raster('B · новая поверхность','#edf0e7',{x:0,y:0,width:480,height:160}),
  await raster('Второй фрагмент B','#f3e9de',{x:0,y:180,width:480,height:120})];
function snapshot(id:string,view:PanelView,knownAssets:string[]=[]):PanelSnapshot{
  const layers=(id===a?cards:destination).map(layer=>knownAssets.includes(layer.assetID)
    ? {...layer,pngBase64:undefined} : layer).map(layer=>{
      if(layer.pngBase64===undefined){const {pngBase64:_,...retained}=layer;return retained;}return layer;
    });
  const camera=view.camera??{center:{...origin,localX:id===a?320:240,localY:id===a?200:150},scale:1};
  const width=view.viewport.x/camera.scale,height=view.viewport.y/camera.scale;
  return {workspaceID,socketKey,target:{kind:'board',id},worldOrigin:origin,size:{width:1400,height:900},
    checkpoint:{id:crypto.randomUUID(),epoch,readCursor:'1',changeCursor:'1'},
    cursor:'1',elements:[],cards:id===a?[{item:{id:b,kind:'board',title:'Папка B'},center:{...origin,localX:320,localY:200},
      frame:cards[0]!.frame,worldOrigin:origin}]:[],rawInkPresent:false,unsupportedElements:[],history:{},truncated:false,
    appearance:{status:'ready',requestID:crypto.randomUUID(),sourceRevision:id,viewport:view.viewport,camera,layers,
      coverage:{anchor:origin,region:{x:camera.center.tileX*TILE_SIZE+camera.center.localX-width/2,
        y:camera.center.tileY*TILE_SIZE+camera.center.localY-height/2,width,height},level:0,pixelDensity:camera.scale*view.pixelScale}},
    ...(id===b?{navigation:{parentBoard:{kind:'board',id:a}}}:{})};
}
App.prototype.connect=async function(){
  app=this;this.ontoolresult?.({content:[],structuredContent:{open:{target:{kind:'board',id:a}}}});
};
App.prototype.updateModelContext=async()=>({});
App.prototype.callServerTool=async function(input,options){
  if(input.name==='notebook_panel_connect'){
    const requested=input.arguments as {target?:{id:string}};
    const initial=snapshot(requested.target?.id??a,{viewport:{x:800,y:600},pixelScale:1});
    delete initial.appearance;delete initial.checkpoint;
    return {content:[],structuredContent:initial};
  }
  if(input.name==='notebook_panel_changes')return await new Promise<Reply>((_resolve,reject)=>{
    const abort=()=>reject(new Error('The addressed observation was cancelled.'));
    if(options?.signal?.aborted)abort();else options?.signal?.addEventListener('abort',abort,{once:true});
  });
  if(input.name!=='notebook_panel_presentation')throw new Error('This isolated gesture probe accepts only native presentation reads.');
  const request=input.arguments as {target:{id:string};appearance:PanelView;knownAssets?:string[];knownCursor?:string;knownRequestID?:string};
  reads[request.target.id===a?'A':'B']++;
  record('presentation',{target:request.target.id===a?'A':'B',view:request.appearance});
  if(request.knownCursor==='1'&&request.knownRequestID)return {content:[],structuredContent:{unchanged:true,
    workspaceID,socketKey,target:{kind:'board',id:request.target.id}}};
  const value=snapshot(request.target.id,request.appearance,request.knownAssets);
  const reply:Reply={content:[],structuredContent:value};
  if(armed&&request.target.id===b){
    armed=false;
    if(mode==='held-decode'){holdDecoders=2;return reply;}
    return await new Promise<Reply>(finish=>{
      pending={reply:mode==='late-error'?{content:[],isError:true,structuredContent:{status:'error',code:'ipc_timeout',message:'Late B error'}}:reply,
        finish,signal:options?.signal};
      options?.signal?.addEventListener('abort',()=>record('navigation-aborted'),{once:true});show();
    });
  }
  return reply;
};
await import('../../panel/panel.js');
record('ready');

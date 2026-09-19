import './style.css';
import videoURL from './experiment.mp4';
import posterURL from './recording-poster.png';
import referenceURL from './final.bin';
import provenance from './provenance.json';
import {parameters,same,initial,size,color,courant,type Parameters,type Frame} from './model.ts';
const get=<T extends HTMLElement>(id:string)=>document.getElementById(id) as T;
const canvas=get<HTMLCanvasElement>('wave-field'),cut=get<HTMLCanvasElement>('wave-cut'),ctx=canvas.getContext('2d')!,cutContext=cut.getContext('2d')!;
const status=get('status'),failure=get('failure'),progress=get<HTMLProgressElement>('progress');
const speed=get<HTMLInputElement>('speed'),time=get<HTMLInputElement>('time'),seed=get<HTMLInputElement>('seed'),video=get<HTMLVideoElement>('recording');
const mediaPlay=get<HTMLButtonElement>('media-play'),mediaSeek=get<HTMLInputElement>('media-seek');
const rate=get<HTMLSelectElement>('rate'),sound=get<HTMLInputElement>('sound'),events=new AbortController();
const number=(v:unknown,f:number,min:number,max:number)=>typeof v==='number'&&Number.isFinite(v)?Math.max(min,Math.min(max,v)):f;
type State={draft:Parameters;accepted:Parameters|null;tab:'model'|'recording';playhead:number;rate:number;probe:{x:number;y:number}|null};
function stateFrom(value:unknown):State {
 const v=value as Partial<State>|null;
 const probe=v?.probe&&Number.isInteger(v.probe.x)&&Number.isInteger(v.probe.y)&&v.probe.x>=0&&v.probe.x<size&&v.probe.y>=0&&v.probe.y<size?{...v.probe}:null;
 return {probe,draft:parameters(v?.draft),accepted:v?.accepted?parameters(v.accepted):null,tab:v?.tab==='recording'?'recording':'model',playhead:number(v?.playhead,0,0,provenance.duration),rate:[.5,1,1.5,2].includes(v?.rate??0)?v!.rate!:1};
}
let state=stateFrom(notebook.state),worker:Worker|undefined,generation=0,debounce=0,disposed=false,suspended=false;
let lastGood:Float32Array|undefined,lastReport:Frame['report']|undefined,reference:Float32Array|undefined,referenceRequest:AbortController|undefined;
let exportRatio:number|undefined;
type Completion={resolve:()=>void;reject:(error:Error)=>void};
let completion:Completion|undefined;
let mediaMounted=false,restoringMedia=false,mediaEpoch=0;
const image=ctx.createImageData(size,size),palette=Array.from({length:2049},(_,i)=>color(i/1024-1));
const active=()=>!disposed&&!suspended;
const fmt=(n:number,d=2)=>n.toLocaleString('ru-RU',{minimumFractionDigits:d,maximumFractionDigits:d});
function commit(){if(active())notebook.commit({...state,draft:{...state.draft},accepted:state.accepted?{...state.accepted}:null});}
function sync() {
 speed.value=String(state.draft.speed);time.value=String(state.draft.time);seed.value=String(state.draft.seed);
 get('speed-value').textContent=fmt(state.draft.speed)+' м/с';get('time-value').textContent=fmt(state.draft.time)+' с';
 for(const shape of ['pulse','mode'])get(shape).setAttribute('aria-pressed',String(state.draft.shape===shape));
 for(const tab of ['model','recording']){get(tab+'-tab').setAttribute('aria-pressed',String(state.tab===tab));get(tab+'-view').hidden=state.tab!==tab;}
 for(const el of document.querySelectorAll<HTMLInputElement|HTMLButtonElement|HTMLSelectElement>('input,button,select'))el.disabled=!active();
 get<HTMLButtonElement>('cancel').disabled=!active()||(!worker&&!debounce);seed.disabled=!active()||state.draft.shape==='mode';
 rate.value=String(state.rate);mediaSeek.disabled=!active()||!mediaMounted||video.readyState<1;mediaPlay.disabled=!active()||!mediaMounted||(video.readyState<1&&!video.error);mediaPlay.textContent=video.error?'Повторить загрузку записи':video.paused?'Воспроизвести запись':'Пауза записи';
 const dx=1/(size-1),steps=Math.ceil(state.draft.time/(courant*dx/state.draft.speed)),dt=steps?state.draft.time/steps:courant*dx/state.draft.speed;
 get('numerics').textContent=`256 × 256 узлов · Δx = ${fmt(dx*1000,3)} мм · Δt = ${fmt(dt*1000,3)} мс · 2(cΔt/Δx)² = ${fmt(2*(state.draft.speed*dt/dx)**2,3)} < 1. Край закреплён, u = 0.`;
}
function draw(field:Float32Array,p:Parameters,report?:Frame['report'],partial=false) {
 for(let y=0;y<size;y++)for(let x=0;x<size;x++){
  const v=field[y*size+x]!,rgb=palette[Math.round(Math.max(-1,Math.min(1,v))*1024)+1024]!,offset=((size-1-y)*size+x)*4;
  image.data[offset]=rgb[0];image.data[offset+1]=rgb[1];image.data[offset+2]=rgb[2];image.data[offset+3]=255;
 }
 ctx.putImageData(image,0,0);
 const marker=get('probe-marker');marker.hidden=!state.probe;
 if(state.probe){marker.style.left=(state.probe.x+.5)/size*100+'%';marker.style.top=(size-state.probe.y-.5)/size*100+'%';}
 const width=Math.max(280,cut.getBoundingClientRect().width),height=120,dpr=exportRatio??Math.min(devicePixelRatio||1,2);
 if(cut.width!==Math.round(width*dpr)||cut.height!==height*dpr){cut.width=Math.round(width*dpr);cut.height=height*dpr;}
 const c=cutContext;c.setTransform(dpr,0,0,dpr,0,0);c.clearRect(0,0,width,height);c.strokeStyle='#aab0bf';c.lineWidth=1;c.beginPath();c.moveTo(28,60);c.lineTo(width-14,60);c.stroke();
 c.strokeStyle='#5274c5';c.lineWidth=2;c.beginPath();for(let x=0;x<size;x++){const y=60-(field[(size/2-1)*size+x]!+field[size/2*size+x]!)*22;const X=28+x/(size-1)*(width-42);x?c.lineTo(X,y):c.moveTo(X,y);}c.stroke();
 c.fillStyle=matchMedia('(prefers-color-scheme:dark)').matches?'#a9afbd':'#646772';c.font='13px -apple-system,sans-serif';c.fillText('y = 0,5 м',28,15);c.fillText('+1 мм',width-57,15);c.fillText('−1 мм',width-57,101);c.fillText('0',24,116);c.fillText('1 м',width-39,116);
 const t=report?.time??0;get('result-caption').textContent=`${partial?'Промежуточный кадр':'Показанный результат'}: t = ${fmt(t,3)} с · c = ${fmt(p.speed)} м/с · ${p.shape==='mode'?'проверочная мода':'импульс, seed '+p.seed}.`;
 const metrics=report?`E / E₀ = ${fmt(report.energy,6)}${report.error!==null?' · max |u − uточн| = '+report.error.toExponential(2)+' мм':''}`:'Начальное смещение, начальная скорость 0.';
 get('accuracy').textContent=metrics;
 const probe=state.probe;
 get('probe-value').textContent=probe?`Узел (${probe.x}, ${probe.y}): x = ${fmt(probe.x/(size-1),3)} м, y = ${fmt(probe.y/(size-1),3)} м; u = ${fmt(field[probe.y*size+probe.x]!,4)} мм.`:'Выберите узел касанием или стрелками.';
 if(report&&!partial&&reference&&same(p,provenance.parameters as Parameters)){
  let error=0;for(let i=0;i<field.length;i++)error=Math.max(error,Math.abs(field[i]!-reference[i]!));get('accuracy').textContent+=` · max |Worker − NumPy| = ${error.toExponential(2)} мм`;
 }
}
function showLast() {if(lastGood&&state.accepted)draw(lastGood,state.accepted,lastReport);else draw(initial(state.accepted??state.draft),state.accepted??state.draft);}
function stop() {const cancelled=completion;completion=undefined;cancelled?.reject(Error('program_export_compute_cancelled'));generation++;clearTimeout(debounce);debounce=0;if(worker){worker.onmessage=null;worker.onerror=null;worker.terminate();worker=undefined;}}
function fail(error:unknown){stop();failure.hidden=false;failure.textContent='Расчёт не завершён: '+String(error);status.textContent='Последний правильный результат сохранён. Можно повторить расчёт.';showLast();sync();}
function run(p=state.draft,restore=false,awaited?:Completion) {
 if(!active()||state.tab!=='model'){awaited?.reject(Error('program_export_compute_unavailable'));return;}
 stop();completion=awaited;const id=generation;failure.hidden=true;progress.value=0;status.textContent='Расчёт 256 × 256…';
 try{
  const job=new Worker(new URL('./worker-wave.js',import.meta.url),{type:'module'});worker=job;
  job.onmessage=(event:MessageEvent<Frame&{error?:string}>)=>{
   if(!active()||worker!==job||event.data.id!==generation)return;
   const result=event.data;if(result.error){fail(result.error);return;}
   if(!(result.buffer instanceof ArrayBuffer)||result.buffer.byteLength!==size*size*4){fail('Неверный размер поля');return;}
   const field=new Float32Array(result.buffer);draw(field,p,result.report,!result.done);progress.value=result.total?result.step/result.total:1;
   if(result.done){lastGood=field;lastReport=result.report;state={...state,accepted:{...p}};const done=completion;completion=undefined;stop();status.textContent='Расчёт завершён.';sync();if(!restore)commit();done?.resolve();}
   else {status.textContent=`Шаг ${result.step} / ${result.total}. Ввод доступен.`;job.postMessage({kind:'recycle',id,buffer:result.buffer},[result.buffer]);}
  };
  job.onerror=e=>{if(worker===job){e.preventDefault();fail(e.message||'Worker недоступен');}};
  job.postMessage({kind:'start',id,parameters:p});sync();
 }catch(error){fail(error);}
}
function edit(patch:Partial<Parameters>){if(!active())return;state={...state,draft:parameters({...state.draft,...patch})};stop();showLast();status.textContent='Параметры изменены…';debounce=window.setTimeout(()=>{debounce=0;run();},120);sync();}
for(const input of [speed,time]){input.addEventListener('input',()=>edit({[input.id]:Number(input.value)}),{signal:events.signal});input.addEventListener('change',commit,{signal:events.signal});}
seed.addEventListener('change',()=>{edit({seed:Number(seed.value)});commit();},{signal:events.signal});
for(const shape of ['pulse','mode'] as const)get(shape).addEventListener('click',()=>{edit({shape});commit();},{signal:events.signal});
get('calculate').addEventListener('click',()=>run(),{signal:events.signal});get('cancel').addEventListener('click',()=>{stop();showLast();status.textContent='Отменено. Последний правильный результат сохранён.';sync();commit();},{signal:events.signal});
function rememberMedia(){if(mediaMounted&&!restoringMedia&&video.readyState>=1&&!video.error&&Number.isFinite(video.currentTime))state={...state,playhead:Math.min(provenance.duration,video.currentTime),rate:video.playbackRate};}
function unmountMedia(){if(!mediaMounted)return;mediaEpoch++;rememberMedia();video.pause();mediaMounted=false;restoringMedia=false;video.removeAttribute('src');video.load();}
function mountMedia(){if(!active()||mediaMounted||state.tab!=='recording')return;mediaMounted=true;restoringMedia=true;mediaEpoch++;get('media-error').hidden=true;video.poster=posterURL;video.muted=!sound.checked;video.src=videoURL;video.load();}
video.addEventListener('loadedmetadata',()=>{if(!active()||!mediaMounted)return;video.playbackRate=state.rate;video.currentTime=Math.min(state.playhead,video.duration);restoringMedia=false;sync();},{signal:events.signal});
video.addEventListener('timeupdate',()=>{rememberMedia();mediaSeek.value=String(video.currentTime);get('playhead').textContent=fmt(video.currentTime)+' / '+fmt(provenance.duration)+' с';},{signal:events.signal});
for(const event of ['seeked','pause','ratechange'])video.addEventListener(event,()=>{if(mediaMounted&&!restoringMedia){rememberMedia();commit();sync();}},{signal:events.signal});
video.addEventListener('error',()=>{if(mediaMounted){get('media-error').hidden=false;get('media-error').textContent='Локальная запись недоступна. Численный расчёт остаётся доступен.';sync();}},{signal:events.signal});
mediaPlay.addEventListener('click',()=>{if(!active()||!mediaMounted)return;if(video.error){unmountMedia();mountMedia();sync();return;}const epoch=mediaEpoch;if(video.paused)void video.play().then(()=>{if(epoch===mediaEpoch)sync();}).catch(error=>{if(epoch!==mediaEpoch||!active())return;get('media-error').hidden=false;get('media-error').textContent='Не удалось начать воспроизведение: '+String(error);sync();});else video.pause();},{signal:events.signal});
mediaSeek.addEventListener('input',()=>{if(!active()||!mediaMounted)return;video.pause();video.currentTime=Number(mediaSeek.value);state={...state,playhead:Number(mediaSeek.value)};},{signal:events.signal});
mediaSeek.addEventListener('change',commit,{signal:events.signal});
video.addEventListener('ended',sync,{signal:events.signal});
rate.addEventListener('change',()=>{state={...state,rate:Number(rate.value)};video.playbackRate=state.rate;commit();},{signal:events.signal});sound.addEventListener('change',()=>{video.muted=!sound.checked;},{signal:events.signal});
function tab(value:State['tab']){stop();unmountMedia();state={...state,tab:value};sync();showLast();if(value==='recording')mountMedia();else if(!lastGood)run(state.accepted??state.draft,true);commit();}
for(const name of ['model','recording'] as const)get(name+'-tab').addEventListener('click',()=>tab(name),{signal:events.signal});
get('repeat').addEventListener('click',()=>{state={...state,draft:parameters(provenance.parameters)};tab('model');run();},{signal:events.signal});
async function loadReference(){const request=new AbortController();referenceRequest=request;try{const r=await fetch(referenceURL,{signal:request.signal});if(!r.ok)throw Error('reference');const bytes=await r.arrayBuffer();if(bytes.byteLength!==size*size*4)throw Error('reference length');if(!active()||request.signal.aborted||referenceRequest!==request)return;reference=new Float32Array(bytes);get('comparison-status').textContent='';if(lastGood&&state.accepted)draw(lastGood,state.accepted,lastReport);}catch{if(active()&&!request.signal.aborted)get('comparison-status').textContent='Снимок NumPy недоступен; численный результат Worker показан без внешнего сравнения.';}finally{if(referenceRequest===request)referenceRequest=undefined;}}
addEventListener('notebookstate',()=>{if(disposed)return;stop();unmountMedia();state=stateFrom(notebook.state);lastGood=undefined;lastReport=undefined;sync();showLast();if(state.tab==='recording')mountMedia();else run(state.accepted??state.draft,true);},{signal:events.signal});
const resize=new ResizeObserver(()=>{if(active()&&state.tab==='model')showLast();});resize.observe(cut);
const theme=matchMedia('(prefers-color-scheme:dark)');theme.addEventListener('change',showLast,{signal:events.signal});
canvas.addEventListener('click',event=>{
 if(!active()||!lastGood||!state.accepted||worker)return;
 const rect=canvas.getBoundingClientRect(),x=Math.floor((event.clientX-rect.left)/rect.width*size),y=size-1-Math.floor((event.clientY-rect.top)/rect.height*size);
 if(x<0||x>=size||y<0||y>=size)return;
 state={...state,probe:{x,y}};showLast();commit();
},{signal:events.signal});
canvas.addEventListener('keydown',event=>{
 if(!active()||!lastGood||!state.accepted||worker)return;
 const probe=state.probe??{x:Math.floor(size/2),y:Math.floor(size/2)},step=event.shiftKey?10:1;
 let {x,y}=probe;
 switch(event.key){case 'ArrowLeft':x-=step;break;case 'ArrowRight':x+=step;break;case 'ArrowUp':y+=step;break;case 'ArrowDown':y-=step;break;default:return;}
 event.preventDefault();state={...state,probe:{x:Math.max(0,Math.min(size-1,x)),y:Math.max(0,Math.min(size-1,y))}};showLast();commit();
},{signal:events.signal});
notebook.semantic(()=>{
 if(disposed||state.tab!=='model'||!state.probe||!lastGood||!state.accepted||!lastReport)return null;
 const p=state.probe,rect=canvas.getBoundingClientRect(),x=(rect.left+(p.x+.5)/size*rect.width)/innerWidth,y=(rect.top+(size-p.y-.5)/size*rect.height)/innerHeight;
 if(x<0||x>1||y<0||y>1)return null;
 return {objectID:'node:'+p.x+':'+p.y,label:'Узел мембраны',anchor:{x,y},
  values:[{label:'x',value:p.x/(size-1),unit:'m'},{label:'y',value:p.y/(size-1),unit:'m'},
    {label:'Смещение',value:lastGood[p.y*size+p.x]!,unit:'mm'},{label:'Время',value:lastReport.time,unit:'s'}],
  model:{parameters:{...state.accepted},grid:size,index:p.y*size+p.x,energyRatio:lastReport.energy}};
});
notebook.exportFrame(async ({format,state:saved,pixelRatio,time:offset,signal})=>{
 if(format!=='raster')throw Error('program_export_unavailable');
 if(signal.aborted||disposed)throw Error('program_export_cancelled');
 state=stateFrom(saved);
 if(offset!==undefined) {
  if(state.tab==='model') {
   if(!state.accepted||state.accepted.time+offset>4)throw Error('program_export_timeline_out_of_range');
   state.accepted={...state.accepted,time:state.accepted.time+offset};
  } else {
   if(state.playhead+offset>=provenance.duration)throw Error('program_export_timeline_out_of_range');
   state.playhead+=offset;
  }
 }
 exportRatio=pixelRatio;lastGood=undefined;lastReport=undefined;suspended=false;
 const cancel=()=>{stop();unmountMedia();};signal.addEventListener('abort',cancel,{once:true});
 try {
  sync();
  if(state.tab==='model') {
   // A saved accepted result is not the unfinished draft. No second solver or queue.
   if(state.accepted)await new Promise<void>((resolve,reject)=>run(state.accepted!,true,{resolve,reject}));
   else showLast();
  } else {
   video.muted=true;
   await new Promise<void>((resolve,reject)=>{
    const check=()=>{if(video.readyState>=2&&!video.seeking&&Math.abs(video.currentTime-state.playhead)<.03){cleanup();resolve();}};
    const failed=()=>{cleanup();reject(Error('program_export_media_unavailable'));};
    const cleanup=()=>{for(const event of ['loadeddata','seeked'])video.removeEventListener(event,check);video.removeEventListener('error',failed);signal.removeEventListener('abort',failed);};
    for(const event of ['loadeddata','seeked'])video.addEventListener(event,check);
    video.addEventListener('error',failed);signal.addEventListener('abort',failed,{once:true});
    mountMedia();video.muted=true;video.pause();check();
   });
  }
  if(signal.aborted)throw Error('program_export_cancelled');
  return null;
 } finally {signal.removeEventListener('abort',cancel);suspended=true;stop();video.pause();}
},{timeline:true});
notebook.lifecycle({pause(){suspended=true;stop();unmountMedia();referenceRequest?.abort();showLast();status.textContent='Расчёт приостановлен.';sync();},checkpoint(){return {...state,draft:{...state.draft},accepted:state.accepted?{...state.accepted}:null};},resume(){if(disposed)return;suspended=false;sync();if(!reference)void loadReference();if(state.tab==='recording')mountMedia();else if(!lastGood)run(state.accepted??state.draft,true);else{showLast();status.textContent='Последний результат восстановлен. Новый расчёт — по команде.';}},dispose(){disposed=true;stop();unmountMedia();referenceRequest?.abort();resize.disconnect();events.abort();lastGood=undefined;reference=undefined;canvas.width=canvas.height=cut.width=cut.height=0;}});
get('provenance').textContent=`Внешний расчёт: NumPy ${provenance.numpy}, ${provenance.steps} шагов; input SHA-256 ${provenance.inputSHA256}; script ${provenance.scriptSHA256}; video ${provenance.outputs['experiment.mp4'].sha256}. Полные параметры и hashes — provenance.json в пакете.`;
sync();showLast();notebook.ready(Promise.resolve()).catch(()=>{});void loadReference();if(state.tab==='recording')mountMedia();else run(state.accepted??state.draft,true);

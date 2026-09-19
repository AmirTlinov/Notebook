import * as Plot from '@observablehq/plot';
import './style.css';
import rawURL from './data.bin';
import overviewURL from './overview.bin';
import metadata from './data.json';
import {sampleRate,count,binSize,seed,impulseIndex,selection,sampleWindow,type Selection} from './model.ts';

declare global {interface Window {MathJax: {startup: {promise: Promise<void>; document: {reset(): void; updateDocument(): void}}; tex2svgPromise(tex: string, options: {display: boolean}): Promise<HTMLElement>}}}
const get = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const canvas = get<HTMLCanvasElement>('overview'), detail = get<HTMLDivElement>('detail');
const centerInput = get<HTMLInputElement>('center'), spanInput = get<HTMLSelectElement>('span');
const errorView = get<HTMLParagraphElement>('signal-error'), retry = get<HTMLButtonElement>('retry');
const theme = matchMedia('(prefers-color-scheme:dark)'), events = new AbortController();
let state = selection(notebook.state), suspended = false, disposed = false;
let bins: Float32Array, data: {start: number; values: Float32Array} | undefined;
let request: AbortController | undefined, loading: Promise<void> | undefined, wanted = false;
let exportRatio: number | undefined;
let formulaWanted = false, formulaWork: Promise<void> | undefined, frame = 0;
const active = () => !suspended && !disposed;
const colors = () => {const style = getComputedStyle(canvas); return {ink: style.getPropertyValue('--ink'), muted: style.getPropertyValue('--muted'),
  blue: style.getPropertyValue('--envelope'), orange: style.getPropertyValue('--window'), grid: style.getPropertyValue('--plot-grid')};};
const decode = (buffer: ArrayBuffer) => {const view = new DataView(buffer), values = new Float32Array(buffer.byteLength / 4);
  for (let i = 0; i < values.length; i++) values[i] = view.getFloat32(i * 4, true); return values;};
const format = (value: number) => value.toLocaleString('ru-RU', {minimumFractionDigits: 3, maximumFractionDigits: 3});
function syncControls() {
  const window = sampleWindow(state);
  centerInput.min = String(state.span / 2); centerInput.max = String(count / sampleRate - state.span / 2);
  centerInput.value = String(state.center); spanInput.value = String(state.span);
  get('center-value').textContent = format(state.center) + ' с';
  canvas.setAttribute('aria-valuenow', String(state.center));
  canvas.setAttribute('aria-valuetext', `От ${format(window.from)} до ${format(window.to)} секунд`);
  for (const control of [centerInput,spanInput,get<HTMLButtonElement>('event'),retry]) control.disabled = !active();
}
function drawOverview() {
  if (!bins || !active()) return;
  const {width,height} = canvas.getBoundingClientRect(), scale = exportRatio ?? Math.min(3, devicePixelRatio || 1);
  canvas.width = Math.round(width * scale); canvas.height = Math.round(height * scale);
  const ctx = canvas.getContext('2d')!; ctx.scale(scale,scale);
  const c = colors(), left = 44, right = width - 12, top = 12, bottom = height - 30;
  const x = (seconds: number) => left + (right - left) * seconds / (count / sampleRate);
  const y = (value: number) => bottom - (bottom - top) * (value + 1.5) / 4.5;
  ctx.font = '12px -apple-system, sans-serif'; ctx.textBaseline = 'middle'; ctx.lineWidth = 1;
  for (const value of [-1,0,1,2]) {
    ctx.strokeStyle = c.grid; ctx.beginPath();ctx.moveTo(left,y(value));ctx.lineTo(right,y(value));ctx.stroke();
    ctx.fillStyle = c.muted;ctx.textAlign = 'right';ctx.fillText(String(value),left - 8,y(value));
  }
  // Combine complete min/max bins per pixel. Unlike point sampling, an extremum cannot disappear.
  ctx.strokeStyle = c.blue; ctx.lineWidth = 1; ctx.beginPath();
  const pixels = Math.max(1,Math.floor(right - left)), n = bins.length / 2;
  for (let pixel = 0; pixel < pixels; pixel++) {
    const begin = Math.floor(pixel * n / pixels), end = Math.min(n, Math.max(begin + 1, Math.ceil((pixel + 1) * n / pixels)));
    let low = Infinity, high = -Infinity;
    for (let b = begin; b < end; b++) {low = Math.min(low,bins[b * 2]!); high = Math.max(high,bins[b * 2 + 1]!);}
    ctx.moveTo(left + pixel + .5,y(low));ctx.lineTo(left + pixel + .5,y(high));
  }
  ctx.stroke();ctx.fillStyle = c.muted;ctx.textAlign = 'center';
  for (const second of [0,20,40,60,80,100]) ctx.fillText(String(second),x(second),height - 12);
  const window = sampleWindow(state), from = x(window.from), to = x(window.to);
  ctx.globalAlpha = .18;ctx.fillStyle = c.orange;ctx.fillRect(from,top,Math.max(2,to - from),bottom - top);ctx.globalAlpha = 1;
  ctx.strokeStyle = c.orange;ctx.lineWidth = 2;ctx.strokeRect(from,top,Math.max(2,to - from),bottom - top);
}
function drawDetail() {
  if (!data || !active()) return;
  const desired = sampleWindow(state);
  if (data.start !== desired.start || data.values.length !== desired.length) return;
  const c = colors(), width = Math.max(240,Math.floor(detail.getBoundingClientRect().width));
  detail.replaceChildren(Plot.plot({width,height:250,marginLeft:44,marginRight:width < 450 ? 30 : 12,marginBottom:40,marginTop:22,
    style: {background:'transparent',color:c.ink,fontFamily:'-apple-system,BlinkMacSystemFont,sans-serif',fontSize:width < 500 ? '12px' : '14px'},
    x:{domain:[desired.from,desired.to],label:'Время, с',ticks:width < 450 ? 4 : 6,tickFormat:(value: number) => value.toFixed(state.span < 1 ? 3 : 1)},
    y:{domain:[-1.5,3],label:'Амплитуда, усл. ед.',grid:true,ticks:4},
    marks:[Plot.ruleY([0],{stroke:c.muted,strokeOpacity:.4}),Plot.lineY(data.values,{x:(_,i) => (data!.start + i) / sampleRate,stroke:c.blue,strokeWidth:1.6,clip:true}),
      ...(state.sample!==null && state.sample>=data.start && state.sample<data.start+data.values.length
        ? [Plot.dot([{x:state.sample/sampleRate,y:data.values[state.sample-data.start]!}],{x:'x',y:'y',r:5,fill:c.orange})] : []),
      ...(state.span <= .05 ? [Plot.dotY(data.values,{x:(_,i) => (data!.start + i) / sampleRate,r:2,fill:c.blue})] : [])]}));
  get('detail-caption').textContent = `${format(desired.from)}–${format(desired.to)} с · ${desired.length.toLocaleString('ru-RU')} исходных отсчётов · без прореживания`;
  if(state.sample!==null&&state.sample>=data.start&&state.sample<data.start+data.values.length)
    get('detail-caption').textContent+=` · Выбран № ${state.sample}: t = ${format(state.sample/sampleRate)} с, u = ${data.values[state.sample-data.start]!.toFixed(4)} усл. ед.`;
  detail.removeAttribute('data-pending');detail.removeAttribute('aria-busy');
}
function updateFormula() {
  formulaWanted = true;
  if (formulaWork) return formulaWork;
  formulaWork = (async () => {
    await window.MathJax.startup.promise;
    while (formulaWanted && active() && data) {
      formulaWanted = false; const observed = data;
      let min = Infinity, max = -Infinity;
      for (const value of observed.values) {min = Math.min(min,value);max = Math.max(max,value);}
      const node = await window.MathJax.tex2svgPromise(`\\min_{i\\in W} x_i = ${min.toFixed(3)},\\qquad \\max_{i\\in W} x_i = ${max.toFixed(3)}`, {display:true});
      if (active() && data === observed) {
        get('formula').replaceChildren(node);
        window.MathJax.startup.document.reset();window.MathJax.startup.document.updateDocument();
      }
    }
  })().finally(() => {formulaWork = undefined;});
  return formulaWork;
}
function showFailure(error: unknown) {
  if (!active()) return;
  errorView.textContent = `Не удалось прочитать выбранное окно: ${error instanceof Error ? error.message : String(error)}`;
  errorView.hidden = false;retry.hidden = false;detail.removeAttribute('aria-busy');
}
function loadWindow(): Promise<void> {
  wanted = true;
  if (loading) {request?.abort();return loading;}
  loading = (async () => {
    while (wanted && active()) {
      wanted = false;const target = sampleWindow(state);
      detail.setAttribute('data-pending','');detail.setAttribute('aria-busy','true');
      // Resize and theme reuse this window. No refetch or regeneration of 100k points.
      if (data?.start !== target.start || data.values.length !== target.length) {
        request = new AbortController(); const controller = request;
        try {
          const from = target.start * 4, to = target.end * 4 - 1;
          const response = await fetch(rawURL,{headers:{Range:`bytes=${from}-${to}`},signal:controller.signal});
          if (response.status !== 206 || response.headers.get('Content-Range') !== `bytes ${from}-${to}/${count * 4}`) throw Error('источник не поддержал адресный диапазон');
          const bytes = await response.arrayBuffer();
          if (bytes.byteLength !== target.length * 4) throw Error('неполное окно данных');
          if (!active() || controller.signal.aborted) continue;
          data = {start:target.start,values:decode(bytes)};
        } catch (error) {if (!controller.signal.aborted) throw error;continue;}
        finally {if (request === controller) request = undefined;}
      }
      if (!active() || wanted) continue;
      errorView.hidden = true;retry.hidden = true;drawDetail();await updateFormula();
    }
  })().finally(() => {loading = undefined;});
  return loading;
}
function change(patch: Partial<Selection>, commit: boolean) {
  if (!active()) return;
  state = selection({...state,...patch});syncControls();drawOverview();
  void loadWindow().catch(showFailure);
  if (commit) notebook.commit({...state});
}
function onResize() {
  if (!active() || frame) return;
  frame = requestAnimationFrame(() => {frame = 0;drawOverview();drawDetail();});
}
const resize = new ResizeObserver(onResize);resize.observe(canvas);resize.observe(detail);
centerInput.addEventListener('input',() => change({center:centerInput.valueAsNumber},false),{signal:events.signal});
centerInput.addEventListener('change',() => change({},true),{signal:events.signal});
spanInput.addEventListener('change',() => change({span:Number(spanInput.value)},true),{signal:events.signal});
get('event').addEventListener('click',() => change({center:impulseIndex / sampleRate,span:.05},true),{signal:events.signal});
retry.addEventListener('click',() => {void loadWindow().catch(showFailure);},{signal:events.signal});
function point(event: PointerEvent, commit = false) {
  const rect = canvas.getBoundingClientRect();change({center:(event.clientX - rect.left - 44) / (rect.width - 56) * count / sampleRate},commit);
}
canvas.addEventListener('pointerdown',event => {if (!active()) return;canvas.setPointerCapture(event.pointerId);point(event);},{signal:events.signal});
canvas.addEventListener('pointermove',event => {if (canvas.hasPointerCapture(event.pointerId)) point(event);},{signal:events.signal});
canvas.addEventListener('pointerup',event => {if (canvas.hasPointerCapture(event.pointerId)) {point(event,true);canvas.releasePointerCapture(event.pointerId);}},{signal:events.signal});
canvas.addEventListener('pointercancel',() => {if (active()) notebook.commit({...state});},{signal:events.signal});
canvas.addEventListener('keydown',event => {
  const step = event.shiftKey ? 10 : state.span / 4;
  const center = event.key === 'Home' ? 0 : event.key === 'End' ? count / sampleRate : event.key === 'ArrowLeft' ? state.center - step : event.key === 'ArrowRight' ? state.center + step : undefined;
  if (center !== undefined) {event.preventDefault();change({center},true);}
},{signal:events.signal});
detail.addEventListener('click',event=>{
  if(!active()||!data)return;
  const desired=sampleWindow(state);if(data.start!==desired.start||data.values.length!==desired.length)return;
  const rect=detail.getBoundingClientRect(),right=rect.width<450?30:12;
  const u=(event.clientX-rect.left-44)/(rect.width-44-right);if(u<0||u>1)return;
  state={...state,sample:data.start+Math.round(u*(data.values.length-1))};drawDetail();notebook.commit({...state});
},{signal:events.signal});
detail.addEventListener('keydown',event=>{
  if(!active()||!data)return;
  const desired=sampleWindow(state);if(data.start!==desired.start||data.values.length!==desired.length)return;
  const current=state.sample??data.start,step=event.shiftKey?10:1;
  const sample=event.key==='Home'?data.start:event.key==='End'?desired.end-1:event.key==='ArrowLeft'?current-step:event.key==='ArrowRight'?current+step:undefined;
  if(sample===undefined)return;event.preventDefault();
  state={...state,sample:Math.max(data.start,Math.min(desired.end-1,sample))};drawDetail();notebook.commit({...state});
},{signal:events.signal});
notebook.semantic(()=>{
  if(disposed||!data||state.sample===null)return null;
  const desired=sampleWindow(state),offset=state.sample-data.start;
  if(data.start!==desired.start||data.values.length!==desired.length||offset<0||offset>=data.values.length||detail.hasAttribute('data-pending'))return null;
  const value=data.values[offset]!,rect=detail.getBoundingClientRect(),right=rect.width<450?30:12;
  const x=(rect.left+44+offset/(data.values.length-1)*(rect.width-44-right))/innerWidth;
  const y=(rect.top+210-(value+1.5)/4.5*188)/innerHeight;
  if(x<0||x>1||y<0||y>1)return null;
  return {objectID:'sample:'+state.sample,label:'Отсчёт '+state.sample,anchor:{x,y},
    values:[{label:'Время',value:state.sample/sampleRate,unit:'s'},{label:'Амплитуда',value,unit:'arbitrary'}],
    model:{index:state.sample,sampleRate,dataSHA256:metadata.sha256,window:{...state}}};
});
theme.addEventListener('change',onResize,{signal:events.signal});
addEventListener('notebookstate',() => {state = selection(notebook.state);if (active()) {syncControls();drawOverview();void loadWindow().catch(showFailure);}},{signal:events.signal});
function pause() {suspended = true;wanted = false;formulaWanted = false;request?.abort();cancelAnimationFrame(frame);frame = 0;syncControls();}
// Export the chosen raw-sample Plot as vectors. Its computed presentation is
// copied into the SVG, so no parent CSS, network font or browser heap is needed.
notebook.exportFrame(async ({format,state: saved,signal,pixelRatio}) => {
  const cancel=()=>pause();signal.addEventListener('abort',cancel,{once:true});
  try {
    if(signal.aborted||disposed)throw Error('Экспорт отменён');
    suspended=false;state=selection(saved);exportRatio=pixelRatio;syncControls();drawOverview();await loadWindow();
    if(signal.aborted)throw new DOMException('Aborted','AbortError');
    if(format==='raster')return null;
    const source=detail.querySelector('svg');if(!source)throw Error('График не готов');
    function vector(source: SVGSVGElement) {
      const svg=source.cloneNode(true) as SVGSVGElement, r=source.getBoundingClientRect();
      svg.setAttribute('width',String(r.width));svg.setAttribute('height',String(r.height));
      const original=[source,...source.querySelectorAll('*')],copy=[svg,...svg.querySelectorAll('*')];
      const properties=['fill','fill-opacity','stroke','stroke-width','stroke-opacity','opacity','font-family','font-size','font-weight','font-style','text-anchor','dominant-baseline'];
      original.forEach((node,index)=>{const style=getComputedStyle(node),target=copy[index]!;
        for(const property of properties){const value=style.getPropertyValue(property);if(value&&!value.includes('url('))target.setAttribute(property,value);}
        for(const attribute of [...target.attributes])if(attribute.name.startsWith('data-')||['style','class'].includes(attribute.name))target.removeAttribute(attribute.name);});
      svg.querySelectorAll('style').forEach(node=>node.remove());
      svg.setAttribute('xmlns','http://www.w3.org/2000/svg');svg.setAttribute('xml:space','preserve');
      const background=document.createElementNS('http://www.w3.org/2000/svg','rect');
      const box=source.viewBox.baseVal;
      background.setAttribute('x',String(box.x));background.setAttribute('y',String(box.y));
      background.setAttribute('width',String(box.width||r.width));background.setAttribute('height',String(box.height||r.height));background.setAttribute('fill',getComputedStyle(canvas).getPropertyValue('--paper').trim()||'#fff');svg.prepend(background);
      const title=document.createElementNS('http://www.w3.org/2000/svg','title');title.textContent=get('detail-caption').textContent;svg.prepend(title);
      if(format==='pdf') {
        // A short authored slot can scroll. Replace only its visible vector
        // pixels; a formula below the viewport is not an invalid native layer.
        let left=Math.max(0,r.left),top=Math.max(0,r.top),right=Math.min(innerWidth,r.right),bottom=Math.min(innerHeight,r.bottom);
        for(let parent=source.parentElement;parent;parent=parent.parentElement) {
          const style=getComputedStyle(parent),clip=parent.getBoundingClientRect();
          if(/^(auto|scroll|hidden|clip)$/.test(style.overflowX)) {left=Math.max(left,clip.left+parent.clientLeft);right=Math.min(right,clip.left+parent.clientLeft+parent.clientWidth);}
          if(/^(auto|scroll|hidden|clip)$/.test(style.overflowY)) {top=Math.max(top,clip.top+parent.clientTop);bottom=Math.min(bottom,clip.top+parent.clientTop+parent.clientHeight);}
        }
        if(right<=left||bottom<=top)return null;
        const clipped=document.createElementNS('http://www.w3.org/2000/svg','svg');
        clipped.setAttribute('xmlns','http://www.w3.org/2000/svg');
        clipped.setAttribute('width',String(right-left));clipped.setAttribute('height',String(bottom-top));
        clipped.setAttribute('viewBox',`0 0 ${right-left} ${bottom-top}`);
        svg.setAttribute('x',String(r.left-left));svg.setAttribute('y',String(r.top-top));clipped.append(svg);
        return {svg:new XMLSerializer().serializeToString(clipped),frame:{x:left,y:top,width:right-left,height:bottom-top}};
      }
      return {svg:new XMLSerializer().serializeToString(svg),frame:{x:r.left,y:r.top,width:r.width,height:r.height}};
    }
    const plot=vector(source);
    if(format==='pdf') {
      const formula=get('formula').querySelector('svg');if(!formula)throw Error('Формула не готова');
      return [plot,vector(formula)].flatMap(layer=>layer?[layer]:[]);
    }
    const serialized=plot!.svg;
    return serialized;
  } finally {signal.removeEventListener('abort',cancel);pause();}
},{vectors:true});
notebook.lifecycle({pause,checkpoint:() => {pause();return {...state};},resume:async () => {
  if (disposed) return;suspended = false;syncControls();drawOverview();await loadWindow();
},dispose:() => {pause();disposed = true;events.abort();resize.disconnect();data = undefined;bins = new Float32Array();}});
notebook.ready((async () => {
  if (metadata.count !== count || metadata.sampleRate !== sampleRate || metadata.binSize !== binSize || metadata.seed !== seed) throw Error('Метаданные не соответствуют модели');
  const response = await fetch(overviewURL);if (!response.ok) throw Error('Обзор данных недоступен');
  const bytes = await response.arrayBuffer();if (bytes.byteLength !== Math.ceil(count / binSize) * 8) throw Error('Неполный обзор данных');
  bins = decode(bytes);syncControls();drawOverview();await loadWindow();
})());

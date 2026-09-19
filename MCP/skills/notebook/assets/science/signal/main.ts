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
  const {width,height} = canvas.getBoundingClientRect(), scale = Math.min(3, devicePixelRatio || 1);
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
      ...(state.span <= .05 ? [Plot.dotY(data.values,{x:(_,i) => (data!.start + i) / sampleRate,r:2,fill:c.blue})] : [])]}));
  get('detail-caption').textContent = `${format(desired.from)}–${format(desired.to)} с · ${desired.length.toLocaleString('ru-RU')} исходных отсчётов · без прореживания`;
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
theme.addEventListener('change',onResize,{signal:events.signal});
addEventListener('notebookstate',() => {state = selection(notebook.state);if (active()) {syncControls();drawOverview();void loadWindow().catch(showFailure);}},{signal:events.signal});
function pause() {suspended = true;wanted = false;formulaWanted = false;request?.abort();cancelAnimationFrame(frame);frame = 0;syncControls();}
notebook.lifecycle({pause,checkpoint:() => {pause();return {...state};},resume:async () => {
  if (disposed) return;suspended = false;syncControls();drawOverview();await loadWindow();
},dispose:() => {pause();disposed = true;events.abort();resize.disconnect();data = undefined;bins = new Float32Array();}});
notebook.ready((async () => {
  if (metadata.count !== count || metadata.sampleRate !== sampleRate || metadata.binSize !== binSize || metadata.seed !== seed) throw Error('Метаданные не соответствуют модели');
  const response = await fetch(overviewURL);if (!response.ok) throw Error('Обзор данных недоступен');
  const bytes = await response.arrayBuffer();if (bytes.byteLength !== Math.ceil(count / binSize) * 8) throw Error('Неполный обзор данных');
  bins = decode(bytes);syncControls();drawOverview();await loadWindow();
})());

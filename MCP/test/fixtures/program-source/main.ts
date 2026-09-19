import './style.css';
import curve from './curve.svg';
import {position} from './model';
const initial=notebook.state as {x?:number}|null;
let x=initial?.x??2,pending:Promise<void>=Promise.resolve(),paused=false;
const button=document.querySelector<HTMLButtonElement>('#next')!;
const output=document.querySelector<HTMLOutputElement>('#value')!;
const point=document.querySelector<SVGCircleElement>('#point')!;
document.querySelector('#curve')!.setAttribute('href',curve);
const worker=new Worker(new URL('./worker-square.js',import.meta.url),{type:'module'});
function draw(commit=false):Promise<void>{
  button.disabled=true;
  return pending=new Promise((resolve,reject)=>{
    worker.onerror=event=>reject(new Error(event.message));
    worker.onmessage=(event:MessageEvent<number>)=>{
      const y=event.data,[cx,cy]=position(x,y);
      point.setAttribute('cx',String(cx));point.setAttribute('cy',String(cy));
      output.textContent=`${x<0?`(−${-x})`:x}² = ${y}`;button.disabled=paused;
      if(commit)notebook.commit({x});resolve();
    };
    worker.postMessage(x);
  });
}
button.onclick=()=>{x=x>=3?-3:x+1;void draw(true)};
addEventListener('notebookstate',()=>{x=(notebook.state as {x:number}).x;void draw()});
notebook.lifecycle({pause:async()=>{paused=true;button.disabled=true;await pending},checkpoint:()=>({x}),
  resume:()=>{paused=false;button.disabled=false},dispose:()=>worker.terminate()});
notebook.ready(draw());

notebook.exportFrame(async ({format,state})=>{if(format!=='raster')throw Error('program_export_unavailable');x=(state as {x:number})?.x??2;await draw();return null;});

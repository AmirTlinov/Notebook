// One Notebook state owner; animation frames never commit to the shared document.
var Science = (() => {
  const $=id=>document.getElementById(id);
  const fmt=(v,d=2)=>(Math.abs(v)<0.5*10**-d?0:v).toLocaleString('ru-RU',{maximumFractionDigits:d});
  const clamp=(v,min,max)=>Math.max(min,Math.min(max,v));
  const line=(x1,y1,x2,y2,cls='grid')=>`<path class="${cls}" d="M${x1} ${y1}L${x2} ${y2}"/>`;
  const text=(x,y,label,cls='axis-label',anchor='middle')=>`<text x="${x}" y="${y}" class="${cls}" text-anchor="${anchor}">${label}</text>`;
  const path=points=>points.map(([x,y],i)=>`${i?'L':'M'}${x.toFixed(2)} ${y.toFixed(2)}`).join(' ');
  const circle=(x,y,r,cls)=>`<circle cx="${x}" cy="${y}" r="${r}" class="${cls}"/>`;
  const svg=(id,body)=>{$(id).innerHTML=body;};
  function axes({x0=45,y0=290,x1=445,y1=35,xmin=0,xmax=1,ymin=0,ymax=1,xticks=4,yticks=4}={}) {
    const x=v=>x0+(v-xmin)/(xmax-xmin)*(x1-x0),y=v=>y0-(v-ymin)/(ymax-ymin)*(y0-y1);
    let body='';for(let i=0;i<=xticks;i++){const v=xmin+(xmax-xmin)*i/xticks;body+=line(x(v),y1,x(v),y0)+text(x(v),y0+27,fmt(v,1));}
    for(let i=0;i<=yticks;i++){const v=ymin+(ymax-ymin)*i/yticks;body+=line(x0,y(v),x1,y(v))+text(x0-10,y(v)+6,fmt(v,1),'axis-label','end');}
    return {x,y,body};
  }
  function point(event,svgElement) {
    return new DOMPoint(event.clientX,event.clientY).matrixTransform(svgElement.getScreenCTM().inverse());
  }
  function mount({defaults,ranges={},normalize=v=>v,draw,tick}) {
    let state,playing=false,frame=0,last=null,suspended=false,disposed=false;
    const sanitize=value=>{
      const next={...structuredClone(defaults),...value};
      for(const [key,[min,max]] of Object.entries(ranges))next[key]=clamp(Number.isFinite(next[key])?next[key]:defaults[key],min,max);
      return normalize(next);
    };
    function render(forceInputs=false){
      for(const el of document.querySelectorAll('[data-key]')) {
        if(forceInputs||document.activeElement!==el)el.value=state[el.dataset.key];
        const out=$(el.dataset.key+'-value');if(out)out.textContent=typeof state[el.dataset.key]==='number'?fmt(state[el.dataset.key]):state[el.dataset.key];
      }
      if($('play')){$('play').textContent=playing?'Пауза':'Пуск';$('play').setAttribute('aria-pressed',String(playing));}
      draw(state);
    }
    const save=()=>!suspended&&!disposed&&notebook.commit(structuredClone(state));
    function stop(commit=false){playing=false;last=null;cancelAnimationFrame(frame);if(commit)save();}
    function change(patch,commit=true,{pause=true}={}){if(suspended||disposed)return;if(pause)stop();state=sanitize({...state,...patch});render();if(commit)save();}
    function step(now){
      if(!playing||suspended||disposed)return;
      if(last!==null){const next=tick(state,Math.min(now-last,100));if(next===null){stop(true);render();return;}state=sanitize({...state,...next});}
      last=now;render();frame=requestAnimationFrame(step);
    }
    function restore(){if(disposed||suspended)return;stop();state=sanitize(notebook.state??{});render(true);}
    for(const el of document.querySelectorAll('[data-key]')) {
      el.addEventListener('input',()=>change({[el.dataset.key]:el.type==='range'||el.type==='number'?Number(el.value):el.value},false,{pause:el.dataset.pause!=='false'}));
      el.addEventListener('change',()=>{el.value=state[el.dataset.key];save();});
    }
    if($('play'))$('play').addEventListener('click',()=>{
      if(suspended||disposed)return;
      if(playing){stop(true);render();}else if(tick){playing=true;last=null;render();frame=requestAnimationFrame(step);}
    });
    addEventListener('notebookstate',restore);
    const visibility=()=>{if(document.hidden&&!disposed){stop();render();}};
    document.addEventListener('visibilitychange',visibility);
    notebook.exportFrame(({format,state:saved})=>{
      if(format!=='raster')throw new Error('program_export_unavailable');
      stop();state=sanitize(saved??{});render(true);return null;
    });
    notebook.lifecycle({
      pause(){suspended=true;stop();render();},
      checkpoint(){return structuredClone(state);},
      resume(){suspended=false;render(true);},
      dispose(){stop();disposed=true;removeEventListener('notebookstate',restore);document.removeEventListener('visibilitychange',visibility);}
    });
    notebook.ready(Promise.resolve().then(restore));
    return {get state(){return state},change,render,save,stop};
  }
  return {$,fmt,clamp,line,text,path,circle,svg,axes,point,mount};
})();

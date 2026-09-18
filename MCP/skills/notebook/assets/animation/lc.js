function sampleLC({phase,inductance,capacitance,voltage}) {
  const L=inductance*1e-3,C=capacitance*1e-6,omega=1/Math.sqrt(L*C),Q=C*voltage;
  const angle=2*Math.PI*phase,q=Q*Math.cos(angle),I=-omega*Q*Math.sin(angle);
  return {q,I,Q,Imax:omega*Q,electric:q*q/(2*C),magnetic:L*I*I/2,total:C*voltage*voltage/2,
    period:2*Math.PI/omega,time:2*Math.PI*phase/omega};
}
(() => {
  const $=id=>document.getElementById(id),cycle=v=>((v%1)+1)%1;
  const format=(value,digits=2)=>(Math.abs(value)<0.5*10**-digits?0:value).toFixed(digits).replace('.',',');
  let state,playing=false,frame=0,previous=null;
  const defaults={schema:1,phase:0,inductance:100,capacitance:25,voltage:5};
  function draw() {
    const m=sampleLC(state),q=m.q/m.Q,i=m.I/m.Imax,x=448+352*state.phase;
    $('charge-top').textContent=Math.abs(q)<0.015?'':q>0?'+ + +':'− − −';
    $('charge-bottom').textContent=Math.abs(q)<0.015?'':q>0?'− − −':'+ + +';
    for(const id of ['charge-top','charge-bottom','electric','field-wash'])$(id).style.opacity=Math.abs(q);
    $('electric').innerHTML=[102,126,150].map(x=>`<path d="M${x} ${q>=0?155:186}V${q>=0?185:156}"/>`).join('');
    $('current-arrow').setAttribute('d',i<=0?'M192 80H244':'M244 80H192');
    $('current-arrow').style.opacity=Math.abs(i);
    $('charge').textContent=`q = ${format(m.q*1e6,1)} мкКл`;
    $('current').textContent=`I = ${format(m.I*1e3,1)} мА`;
    $('clock').textContent=`t = ${format(m.time*1e3)} мс · T = ${format(m.period*1e3)} мс`;
    $('electric-energy').textContent=`${format(m.electric*1e6,1)} мкДж`;
    $('magnetic-energy').textContent=`${format(m.magnetic*1e6,1)} мкДж`;
    $('electric-bar').style.width=`${100*m.electric/m.total}%`;
    $('magnetic-bar').style.width=`${100*m.magnetic/m.total}%`;
    $('playhead').setAttribute('d',`M${x} 66V263`);
    for(const [id,y] of [['q-dot',q],['i-dot',i]]){$(id).setAttribute('cx',x);$(id).setAttribute('cy',164-88*y)}
    for(const key of ['phase','inductance','capacitance','voltage'])$(key).value=state[key];
    $('l-value').textContent=`${state.inductance} мГн`;$('c-value').textContent=`${state.capacitance} мкФ`;$('u-value').textContent=`${format(state.voltage,1)} В`;
    $('play').textContent=playing?'Пауза':'Пуск';$('play').setAttribute('aria-pressed',String(playing));
  }
  function stop(){playing=false;previous=null;cancelAnimationFrame(frame)}
  function tick(now){if(!playing)return;if(previous!==null)state.phase=cycle(state.phase+(now-previous)/6000);previous=now;draw();frame=requestAnimationFrame(tick)}
  function save(){notebook.commit({...state})}
  function jump(value){stop();state.phase=cycle(value);draw();save()}
  function restore(){stop();const s=notebook.state??{};state={...defaults};for(const [k,a,b]of [['phase',0,1],['inductance',10,200],['capacitance',10,100],['voltage',1,10]])if(Number.isFinite(s[k]))state[k]=Math.max(a,Math.min(b,s[k]));draw()}
  $('play').addEventListener('click',()=>{if(playing){stop();draw();save()}else{playing=true;previous=null;draw();frame=requestAnimationFrame(tick)}});
  $('back').addEventListener('click',()=>jump(state.phase-.25));$('forward').addEventListener('click',()=>jump(state.phase+.25));$('reset').addEventListener('click',()=>jump(0));
  for(const key of ['phase','inductance','capacitance','voltage']){$(key).addEventListener('input',e=>{stop();state[key]=Number(e.target.value);draw()});$(key).addEventListener('change',save)}
  for(const [id,fn]of [['q-curve',Math.cos],['i-curve',a=>-Math.sin(a)]])$(id).setAttribute('d',Array.from({length:177},(_,n)=>`${n?'L':'M'}${448+n*2},${164-88*fn(n/176*2*Math.PI)}`).join(' '));
  notebook.lifecycle({pause:()=>{stop();draw()},checkpoint:()=>({...state}),resume:()=>draw(),dispose:stop});
  addEventListener('notebookstate',restore);
  document.addEventListener('visibilitychange',()=>{if(document.hidden){stop();draw()}});
  notebook.ready(Promise.resolve().then(restore));
})();

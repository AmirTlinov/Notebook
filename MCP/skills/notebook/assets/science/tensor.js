(() => {
  const {$,fmt,text,line,svg,mount}=Science;
  const defaults={a:[[1,2,0],[-1,1,3]],b:[[2,1],[0,3],[1,-2]],i:0,j:0,k:-1};
  for(const [key,rows,cols] of [['a',2,3],['b',3,2]])for(let i=0;i<rows;i++)for(let j=0;j<cols;j++){
    const el=document.createElement('input');el.type='number';el.min=-9;el.max=9;el.step=1;el.id=`${key}-${i}-${j}`;el.setAttribute('aria-label',`${key.toUpperCase()}, строка ${i+1}, столбец ${j+1}`);$(key==='a'?'matrix-a':'matrix-b').append(el);
    el.addEventListener('change',()=>{const values=app.state[key].map(r=>r.slice());values[i][j]=Number(el.value);app.change({[key]:values});el.value=app.state[key][i][j];});
  }
  for(let i=0;i<2;i++)for(let j=0;j<2;j++){const el=document.createElement('button');el.type='button';el.id=`c-${i}-${j}`;el.setAttribute('aria-label',`Выбрать C, строка ${i+1}, столбец ${j+1}`);$('matrix-c').append(el);el.onclick=()=>app.change({i,j});}
  const app=mount({defaults,ranges:{i:[0,1],j:[0,1],k:[-1,2]},normalize:s=>{
    for(const key of ['a','b'])s[key]=defaults[key].map((row,i)=>row.map((value,j)=>Number.isFinite(s[key]?.[i]?.[j])?Science.clamp(s[key][i][j],-9,9):value));
    for(const k of ['i','j','k'])s[k]=Math.floor(s[k]);return s;
  },draw(s){
    const result=ScienceModels.multiply(s.a,s.b),color='#6658d9';
    svg('tensor-diagram',`<path d="M110 112H790" stroke="#444b5b" stroke-width="2"/><path d="M342 112H558" stroke="${color}" stroke-width="4"/><circle cx="292" cy="112" r="50" fill="#f0eeff" stroke="${color}" stroke-width="2"/><circle cx="608" cy="112" r="50" fill="#f0eeff" stroke="${color}" stroke-width="2"/><text x="292" y="124" text-anchor="middle" style="font:italic 36px Georgia,serif;fill:${color}">A</text><text x="608" y="124" text-anchor="middle" style="font:italic 36px Georgia,serif;fill:${color}">B</text>${text(140,91,`i = ${s.i+1}`)+text(760,91,`j = ${s.j+1}`)+text(450,85,s.k<0?'Σ k':`k = ${s.k+1}`)}`);
    for(const key of ['a','b'])s[key].forEach((row,i)=>row.forEach((value,j)=>{
      const el=$(`${key}-${i}-${j}`);if(document.activeElement!==el)el.value=value;
      el.classList.toggle('active',key==='a'?i===s.i&&(s.k<0||j===s.k):j===s.j&&(s.k<0||i===s.k));
    }));
    result.forEach((row,i)=>row.forEach((value,j)=>{const el=$(`c-${i}-${j}`);el.textContent=fmt(value);el.setAttribute('aria-pressed',String(i===s.i&&j===s.j));}));
    const terms=s.a[s.i].map((a,k)=>({a,b:s.b[k][s.j],v:a*s.b[k][s.j]}));
    $('tensor-equation').innerHTML=`C<sub>${s.i+1}${s.j+1}</sub> = `+terms.map((t,k)=>`<span style="${s.k===k?'color:#6658d9;text-decoration:underline;text-underline-offset:5px':''}">(${fmt(t.a)}) · (${fmt(t.b)})</span>`).join(' + ')+` = <strong>${fmt(result[s.i][s.j])}</strong>`;
    $('tensor-partial').textContent=s.k<0?'Все три слагаемых составляют один выбранный компонент C.':`При k = ${s.k+1}: произведение ${fmt(terms[s.k].v)}; накопленная сумма до этого k: ${fmt(terms.slice(0,s.k+1).reduce((a,t)=>a+t.v,0))}.`;
    $('tensor-index').textContent=s.k<0?'Показана вся сумма':`Общий индекс k = ${s.k+1} из 3`;
  }});
  $('tensor-next').onclick=()=>app.change({k:app.state.k===2?-1:app.state.k+1});$('tensor-all').onclick=()=>app.change({k:-1});$('tensor-reset').onclick=()=>app.change(defaults);
})();

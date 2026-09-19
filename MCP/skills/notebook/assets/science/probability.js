(() => {
  const {$,fmt,text,path,svg,axes,mount}=Science;
  const app=mount({defaults:{p:.5,n:100,seed:20260918},ranges:{p:[0,1],n:[0,1000],seed:[0,4294967295]},normalize:s=>({...s,n:Math.floor(s.n),seed:Math.floor(s.seed)}),draw(s){
    const values=ScienceModels.bernoulli(s.p,s.n,s.seed),a=axes({xmin:0,xmax:Math.max(100,s.n),ymin:0,ymax:1,xticks:2,yticks:2});
    let body=a.body+`<path d="M45 ${a.y(s.p)}H445" stroke="#ec704a" stroke-width="2.5" stroke-dasharray="7 5"/>`;
    if(s.n)body+=`<path class="curve" d="${path(values.frequencies.map((v,i)=>[a.x(i+1),a.y(v)]))}"/><circle cx="${a.x(s.n)}" cy="${a.y(values.total/s.n)}" r="5" fill="#4263eb"/>`;
    svg('frequency-plot',body+text(445,343,'n'));
    let history='';
    values.outcomes.slice(-100).forEach((v,i)=>{history+=`<circle cx="${60+i%10*40}" cy="${36+Math.floor(i/10)*28}" r="9" fill="${v?'#4263eb':'#fff'}" stroke="${v?'#4263eb':'#d7dce9'}" stroke-width="2"/>`;});
    if(!s.n)history=text(240,150,'Серия ещё не началась');
    history+=text(240,342,s.n?`${values.total} из ${s.n}`:'Нажми «Бросить»','axis-label');svg('trials',history);
    $('p').value=s.p;$('p-value').textContent=fmt(s.p);
    $('trial-summary').textContent=s.n?`Частота ${fmt(values.total/s.n,3)} — при вероятности ${fmt(s.p)}.`:'Как быстро частота приблизится к вероятности?' ;
    for(const id of ['trial-one','trial-ten','trial-hundred'])$(id).disabled=s.n>=1000;
  }});
  for(const [id,amount] of [['trial-one',1],['trial-ten',10],['trial-hundred',100]])$(id).onclick=()=>app.change({n:Math.min(1000,app.state.n+amount)});
  $('trial-reset').onclick=()=>app.change({n:0,seed:(app.state.seed+1)>>>0});
  $('p').oninput=()=>app.change({p:Number($('p').value),n:0},false);$('p').onchange=()=>app.save();
})();

(() => {
  const {$,fmt,clamp,text,path,circle,svg,axes,point,mount}=Science;
  const app=mount({defaults:{length:.8,noise:.12,points:[[-2,-.6],[-.9,1.1],[.6,.4],[2,-.7]]},ranges:{length:[.15,2.5],noise:[0,.6]},
    normalize:s=>({...s,points:(Array.isArray(s.points)?s.points:[]).filter(p=>Array.isArray(p)&&p.length===2&&p.every(Number.isFinite)).slice(0,8).map(([x,y])=>[clamp(x,-2.8,2.8),clamp(y,-1.5,1.5)])}),draw(s){
      const a=axes({x0:60,x1:840,y0:380,y1:30,xmin:-3,xmax:3,ymin:-2,ymax:2,xticks:6,yticks:4}),xs=Array.from({length:161},(_,i)=>-3+6*i/160),prediction=ScienceModels.gaussianProcess(s.points,xs,s.length,s.noise);
      const high=prediction.map(p=>[a.x(p.x),a.y(p.mean+1.96*Math.sqrt(p.variance))]),low=prediction.map(p=>[a.x(p.x),a.y(p.mean-1.96*Math.sqrt(p.variance))]).reverse();
      let body=a.body+`<g clip-path="url(#gp-clip)"><path d="${path([...high,...low])}Z" fill="#4263eb" fill-opacity=".1"/><path class="curve" d="${path(prediction.map(p=>[a.x(p.x),a.y(p.mean)]))}"/>`;
      s.points.forEach(([x,y],i)=>{body+=circle(a.x(x),a.y(y),8,'dot');});
      svg('gp-plot',body+'</g>'+text(840,428,'x'));
      const n=s.points.length,cell=n?Math.min(64,264/n):0,left=(480-n*cell)/2,top=35;
      let matrix='';s.points.forEach((p,i)=>{
        matrix+=text(left-15,top+(i+.5)*cell+6,i+1,'axis-label','end')+text(left+(i+.5)*cell,top-12,i+1);
        s.points.forEach((q,j)=>{const k=ScienceModels.kernel(p[0],q[0],s.length),x=left+j*cell,y=top+i*cell;
          matrix+=`<rect x="${x+1}" y="${y+1}" width="${cell-2}" height="${cell-2}" rx="3" fill="rgb(${Math.round(241-210*k)},${Math.round(245-133*k)},${Math.round(244-89*k)})"/><text x="${x+cell/2}" y="${y+cell/2+6}" text-anchor="middle" style="font-size:${n>6?16:20}px;fill:${k>.55?'#fff':'#24333c'}">${fmt(k,1)}</text>`;
        });
      });
      if(!n)matrix=text(240,140,'Нет наблюдений')+text(240,176,'Показано априорное распределение','axis-label');
      svg('kernel-matrix',matrix);$('gp-hint').textContent=n>=8?'Восемь наблюдений. Удали последнее, чтобы добавить другое.':'Нажми на график. Неопределённость сузится рядом с новой точкой.';$('gp-count').textContent=`${n} / 8 наблюдений`;$('gp-add').disabled=n>=8;$('gp-remove').disabled=!n;
    }});
  function add(x,y){if(app.state.points.length>=8||!Number.isFinite(x)||!Number.isFinite(y))return;app.change({points:[...app.state.points,[x,y]]});}
  $('gp-svg').onclick=e=>{const p=point(e,$('gp-svg'));if(p.x>=60&&p.x<=840&&p.y>=30&&p.y<=380)add(-3+(p.x-60)*6/780,2-(p.y-30)*4/350);};
  $('gp-add').onclick=()=>add(Number($('gp-x').value),Number($('gp-y').value));
  $('gp-remove').onclick=()=>app.change({points:app.state.points.slice(0,-1)});
  $('gp-clear').onclick=()=>app.change({points:[]});
})();

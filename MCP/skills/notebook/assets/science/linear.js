(() => {
  const {$,fmt,clamp,text,path,svg,point,mount}=Science;
  const O=[450,280],unit=85,screen=([x,y])=>[O[0]+unit*x,O[1]-unit*y];
  const app=mount({defaults:{a:1,b:.8,c:0,d:1,phase:.65},ranges:{a:[-2,2],b:[-2,2],c:[-2,2],d:[-2,2],phase:[0,1]},
    seek:(s,seconds)=>({phase:Math.min(1,s.phase+seconds/3.2)}),
    tick:(s,dt)=>s.phase>=1?null:{phase:Math.min(1,s.phase+dt/3200)},draw(s){
      const width=$('linear-svg').clientWidth<650?600:900;O[0]=width/2;$('linear-svg').setAttribute('viewBox',`0 0 ${width} 500`);
      const matrix=[s.a,s.b,s.c,s.d],result=ScienceModels.transform(matrix,s.phase,[1,.5]),move=p=>screen(ScienceModels.transform(matrix,s.phase,p).point);
      let body='<g clip-path="url(#linear-clip)">';
      for(let n=-12;n<=12;n++){
        body+=`<path class="grid" d="${path([screen([n,-8]),screen([n,8])])} ${path([screen([-12,n]),screen([12,n])])}"/>`;
        body+=`<path d="${path([move([n,-8]),move([n,8])])} ${path([move([-12,n]),move([12,n])])}" fill="none" stroke="#497bb2" opacity=".65" stroke-width="1.4"/>`;
      }
      body+=`<path d="M0 ${O[1]}H900 M${O[0]} 0V500" stroke="#99adca" opacity=".65" stroke-width="1.5"/>`;
      body+=`<path d="${path([[0,0],[1,0],[1,1],[0,1]].map(move))}Z" fill="#f9cf6d" fill-opacity=".16" stroke="#dfbb68" stroke-width="1.5"/>`;
      // The same coefficients survive the transformation: Bv = Bî + ½Bĵ.
      body+=`<path id="linear-sum" d="${path([move([1,0]),move([1,.5])])}" fill="none" stroke="#8ad7ba" stroke-width="2.5" stroke-dasharray="7 6"/>`;
      for(const [v,color,label] of [[[1,0],'#fa8585','î'],[[0,1],'#8ad7ba','ĵ'],[[1,.5],'#f2d284','Bv']]){
        const [x,y]=move(v),zero=Math.hypot(x-O[0],y-O[1])<1e-6,angle=Math.atan2(y-O[1],x-O[0]),r=14;
        const labelBelow=label==='Bv'&&[[1,0],[0,1]].some(basis=>{const [bx,by]=move(basis);return Math.abs(x-bx)<36&&Math.abs(y-by)<32;});
        body+=`<path ${label==='Bv'?'id="linear-probe"':''} d="M${O[0]} ${O[1]}L${x} ${y}" stroke="${color}" stroke-width="4"/><path d="M${x-r*Math.cos(angle-.4)} ${y-r*Math.sin(angle-.4)}L${x} ${y}L${x-r*Math.cos(angle+.4)} ${y-r*Math.sin(angle+.4)}" fill="none" stroke="${color}" stroke-width="${zero?0:4}"/><circle cx="${x}" cy="${y}" r="${label==='Bv'?4:20}" fill="${color}" fill-opacity="${label==='Bv'?1:.08}"/><text x="${x+18}" y="${y+(labelBelow?28:-17)}" style="fill:${color};font:italic 27px Georgia,serif">${label}</text>`;
      }
      body+='</g><rect x="24" y="20" width="195" height="130" rx="8" fill="#111318" fill-opacity=".94"/>';
      body+=`<path d="M76 48h-10v72h10 M184 48h10v72h-10" stroke="#b7c2d5" fill="none" stroke-width="2"/>`;
      result.matrix.forEach((v,i)=>{body+=`<text x="${102+i%2*56}" y="${76+Math.floor(i/2)*35}" text-anchor="middle" style="fill:${i%2?'#8ad7ba':'#fa8585'};font-size:25px">${fmt(v)}</text>`;});
      body+=`<text x="24" y="425" style="fill:#f2d284;font-size:22px">v = î + ½ĵ</text><text id="linear-equation" x="24" y="458" style="fill:#f2d284;font-size:22px"></text><text x="${width-24}" y="458" text-anchor="end" style="fill:#f2d284;font-size:24px">площадь ${fmt(Math.abs(result.determinant))}</text>`;
      svg('linear-scene',body);
      $('linear-equation').textContent=`Bv = (${fmt(result.point[0])}; ${fmt(result.point[1])})`;
      $('linear-meaning').textContent=Math.abs(result.determinant)<.001?'Плоскость схлопнулась: площадь стала нулевой.':result.determinant<0?'Ориентация перевёрнута.':'Ориентация сохранена.';
      document.querySelectorAll('[data-preset]').forEach(el=>el.setAttribute('aria-pressed',String(presets[el.dataset.preset].every((v,i)=>v===matrix[i]))));
    }});
  new ResizeObserver(()=>app.render()).observe($('linear-svg'));
  const presets={shear:[1,.8,0,1],rotate:[0,-1,1,0],project:[1,0,0,0],reflect:[-1,0,0,1]};
  document.querySelectorAll('[data-preset]').forEach(el=>el.onclick=()=>{const [a,b,c,d]=presets[el.dataset.preset];app.change({a,b,c,d,phase:0});});
  $('linear-start').onclick=()=>app.change({phase:0});
  let dragging=null;const el=$('linear-svg');
  el.onpointerdown=e=>{const p=point(e,el),s=app.state,m=[s.a,s.b,s.c,s.d];for(const [i,v] of [[0,[1,0]],[1,[0,1]]]){const [x,y]=screen(ScienceModels.transform(m,s.phase,v).point);if(Math.hypot(p.x-x,p.y-y)<32){dragging=i;el.setPointerCapture(e.pointerId);app.stop();break;}}};
  el.onpointermove=e=>{if(dragging===null)return;const p=point(e,el),x=Math.round(clamp((p.x-O[0])/unit,-2,2)*10)/10,y=Math.round(clamp((O[1]-p.y)/unit,-2,2)*10)/10;app.change(dragging===0?{a:x,c:y,phase:1}:{b:x,d:y,phase:1},false);};
  function release(){if(dragging!==null){dragging=null;app.save();}}el.onpointerup=release;el.onpointercancel=release;
})();

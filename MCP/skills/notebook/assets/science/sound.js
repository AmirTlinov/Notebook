(() => {
  const {$,fmt,text,path,svg,mount}=Science;
  const app=mount({defaults:{phase:.08,amplitude:.13,wavelength:2},ranges:{phase:[0,1],amplitude:[0,.18],wavelength:[1.5,3]},
    tick:(s,dt)=>({phase:(s.phase+dt/6000)%1}),draw(s){
      const X=q=>90+110*q,base=205,selected=ScienceModels.wave(3,s.phase,s.amplitude,s.wavelength);
      let body='<defs><radialGradient id="sound-dot"><stop offset="0" stop-color="#fafbfe"/><stop offset=".45" stop-color="#a1abc0"/><stop offset="1" stop-color="#65718b"/></radialGradient></defs>';
      // Layers belong to a fixed oblique camera, not an extra physical dimension of the wave.
      for(let z=3;z>=0;z--)for(let row=0;row<7;row++)for(let col=0;col<=60;col++){
        const q=col/10,w=ScienceModels.wave(q,s.phase,s.amplitude,s.wavelength),x=X(q+w.displacement)+z*19,y=base+(row-3)*21-z*15;
        const chosen=col===30&&row===3&&z===0;
        if(!chosen)body+=`<circle cx="${x.toFixed(2)}" cy="${y}" r="${z?3.1:3.8}" fill="url(#sound-dot)" opacity="${1-z*.14}"/>`;
      }
      const x=X(3+selected.displacement),compression=((s.phase+.5)*s.wavelength)%s.wavelength+s.wavelength;
      body+=`<path d="M${X(compression)-30} 48h60m-8 -5 8 5-8 5" stroke="#8b94a6" fill="none" stroke-width="2"/>`;
      body+=text(X(compression),32,'Сжатие','axis-label');
      body+=`<path d="M${X(3)} ${base+14}V300" stroke="#bac1d0" stroke-dasharray="3 5"/><path d="M${X(3)-22} ${base}h44" stroke="#ed875f" stroke-width="2"/><circle cx="${x}" cy="${base}" r="9" fill="#ee784b" stroke="#fff" stroke-width="3"/>`;
      const curve=[];for(let i=0;i<=240;i++){const q=i/40,w=ScienceModels.wave(q,s.phase,s.amplitude,s.wavelength);curve.push([X(q),364-w.pressure*67]);}
      body+=`<path d="M90 364H750" class="grid"/><path d="${path(curve)}" fill="none" stroke="#4c6be4" stroke-width="3"/><circle cx="${X(3)}" cy="${364-selected.pressure*67}" r="5" fill="#ee784b"/>`;
      body+=text(90,320,'Давление','axis-label','start');
      svg('medium',body);
      $('sound-readout').textContent=`Выбранная частица: смещение ${fmt(selected.displacement,3)}, изменение давления ${fmt(selected.pressure,3)}. Число частиц постоянно.`;
    }});
  $('quarter').onclick=()=>app.change({phase:(app.state.phase+.25)%1});
})();

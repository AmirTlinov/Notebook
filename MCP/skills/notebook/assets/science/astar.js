(() => {
  const {$,text,path,svg,point,mount}=Science,W=17,H=11,N=W*H;
  const initialWalls=[];for(let y=0;y<H;y++){if(y!==3)initialWalls.push(y*W+6);if(y!==8)initialWalls.push(y*W+11);}
  const defaults={start:5*W+2,goal:5*W+14,walls:initialWalls,step:18,cursor:5*W+8};
  let cacheKey='',frames=[],carry=0;
  function trace(s){const key=JSON.stringify([s.start,s.goal,s.walls]);if(key!==cacheKey){cacheKey=key;frames=ScienceModels.astar(W,H,s.walls,s.start,s.goal);}return frames;}
  const app=mount({defaults,ranges:{start:[0,N-1],goal:[0,N-1],cursor:[0,N-1],step:[0,N+1]},normalize:s=>{
    s.start=Math.floor(s.start);s.goal=Math.floor(s.goal);s.cursor=Math.floor(s.cursor);
    s.walls=[...new Set((Array.isArray(s.walls)?s.walls:[]).filter(n=>Number.isInteger(n)&&n>=0&&n<N&&n!==s.start&&n!==s.goal))].sort((a,b)=>a-b);
    s.step=Math.min(Math.floor(s.step),trace(s).length-1);return s;
  },tick:(s,dt)=>{if(s.step>=frames.length-1)return null;carry+=dt;if(carry<120)return {};carry=0;return {step:s.step+1};},draw(s){
    const f=trace(s)[s.step],closed=new Set(f.closed),open=new Set(f.open),blocked=new Set(s.walls),center=n=>[36+(n%W+.5)*24,28+(Math.floor(n/W)+.5)*24];
    let body='';for(let n=0;n<N;n++){
      const [x,y]=center(n),fill=blocked.has(n)?'#414857':closed.has(n)?'#dce4ff':'#fff';
      body+=`<rect x="${x-11.5}" y="${y-11.5}" width="23" height="23" fill="${fill}" stroke="#e7e9ee"/>`;
      if(open.has(n))body+=`<circle cx="${x}" cy="${y}" r="3.5" fill="#526de7"/>`;
    }
    if(f.path.length)body+=`<path d="${path(f.path.map(center))}" fill="none" stroke="#e17e50" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/>`;
    for(const [n,label,color] of [[s.start,'S','#526de7'],[s.goal,'T','#e17e50']]){const [x,y]=center(n);body+=`<circle cx="${x}" cy="${y}" r="11" fill="${color}"/><text x="${x}" y="${y+6}" text-anchor="middle" style="font-size:18px;fill:white">${label}</text>`;}
    const [cx,cy]=center(s.cursor);body+=`<rect class="keyboard-cursor" x="${cx-11}" y="${cy-11}" width="22" height="22" fill="none" stroke="#24333c" stroke-width="2" stroke-dasharray="3 2"/>`;

    svg('astar-grid',body);$('step').max=frames.length-1;
    const h=Math.abs(f.current%W-s.goal%W)+Math.abs(Math.floor(f.current/W)-Math.floor(s.goal/W));
    $('astar-score').textContent=f.cost===null?'Пути нет':`f = ${f.cost} + ${h} = ${f.cost+h}`;
    $('astar-status').textContent=f.done?(f.found?`Цель достигнута. Длина кратчайшего пути: ${f.cost}.`:'Фронт пуст: цель отделена препятствиями.'):s.step===0?'Поиск ещё не начат. Во фронте только стартовая клетка.':'Нажми клетку, чтобы изменить препятствия.';
    $('astar-counts').textContent=`Исследовано ${f.closed.length}; во фронте ${f.open.length}. Курсор: (${s.cursor%W}; ${Math.floor(s.cursor/W)}).`;
    $('astar-step').disabled=s.step===frames.length-1;
  }});
  function edit(n){const s=app.state,mode=$('edit-mode').value;let patch={cursor:n,step:0};
    if(mode==='wall'){if(n===s.start||n===s.goal)return;patch.walls=s.walls.includes(n)?s.walls.filter(v=>v!==n):[...s.walls,n];}
    else patch[mode]=n;app.change(patch);
  }
  $('astar-svg').onclick=e=>{const p=point(e,$('astar-svg')),x=Math.floor((p.x-36)/24),y=Math.floor((p.y-28)/24);if(x>=0&&x<W&&y>=0&&y<H)edit(y*W+x);};
  $('astar-svg').onkeydown=e=>{let n=app.state.cursor,x=n%W,y=Math.floor(n/W);if(e.key==='Enter'||e.key===' '){e.preventDefault();edit(n);return;}if(!['ArrowLeft','ArrowRight','ArrowUp','ArrowDown'].includes(e.key))return;e.preventDefault();if(e.key==='ArrowLeft')x=Math.max(0,x-1);if(e.key==='ArrowRight')x=Math.min(W-1,x+1);if(e.key==='ArrowUp')y=Math.max(0,y-1);if(e.key==='ArrowDown')y=Math.min(H-1,y+1);app.change({cursor:y*W+x});};
  $('astar-step').onclick=()=>app.change({step:app.state.step+1});$('astar-first').onclick=()=>app.change({step:0});
  $('astar-clear').onclick=()=>app.change({walls:[],step:0});$('astar-reset').onclick=()=>app.change(defaults);
})();

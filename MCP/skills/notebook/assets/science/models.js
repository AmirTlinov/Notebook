// Original, dependency-free models shared by the illustrations and their tests.
// Coordinates are normalized unless an example explicitly supplies units.
var ScienceModels = (() => {
  const tau = 2 * Math.PI;
  function wave(q, phase, amplitude, wavelength) {
    const angle = tau * (q / wavelength - phase);
    return {displacement: amplitude * Math.sin(angle),
      pressure: -amplitude * tau / wavelength * Math.cos(angle)};
  }
  function transform(matrix, t, vector) {
    const [a, b, c, d] = matrix;
    const m = [1 + t * (a - 1), t * b, t * c, 1 + t * (d - 1)];
    return {matrix:m, point:[m[0]*vector[0]+m[1]*vector[1], m[2]*vector[0]+m[3]*vector[1]],
      determinant:m[0]*m[3]-m[1]*m[2]};
  }
  function gears(phase) {
    // 60:40:24 teeth; two input turns make every marked wheel return exactly.
    return [tau*2*phase, -tau*3*phase + Math.PI/40, tau*5*phase];
  }
  const kernel = (x, y, length) => Math.exp(-0.5*((x-y)/length)**2);
  function cholesky(a) {
    const n=a.length, l=Array.from({length:n},()=>Array(n).fill(0));
    for(let i=0;i<n;i++) for(let j=0;j<=i;j++) {
      let v=a[i][j]; for(let k=0;k<j;k++)v-=l[i][k]*l[j][k];
      l[i][j]=i===j?Math.sqrt(Math.max(v,1e-14)):v/l[j][j];
    }
    return l;
  }
  function lowerSolve(l,b) {
    const x=[]; for(let i=0;i<b.length;i++) {
      let v=b[i];for(let j=0;j<i;j++)v-=l[i][j]*x[j];x.push(v/l[i][i]);
    } return x;
  }
  function upperSolve(l,b) {
    const x=Array(b.length);for(let i=b.length-1;i>=0;i--) {
      let v=b[i];for(let j=i+1;j<b.length;j++)v-=l[j][i]*x[j];x[i]=v/l[i][i];
    }return x;
  }
  function gaussianProcess(points, xs, length, noise) {
    if(!points.length)return xs.map(x=>({x,mean:0,variance:1}));
    const k=points.map((p,i)=>points.map((q,j)=>kernel(p[0],q[0],length)+(i===j?noise*noise+1e-9:0)));
    const l=cholesky(k),alpha=upperSolve(l,lowerSolve(l,points.map(p=>p[1])));
    return xs.map(x=>{
      const ks=points.map(p=>kernel(x,p[0],length)), v=lowerSolve(l,ks);
      return {x,mean:ks.reduce((a,z,i)=>a+z*alpha[i],0),variance:Math.max(0,1-v.reduce((a,z)=>a+z*z,0))};
    });
  }
  function multiply(a,b) {
    return a.map(row=>b[0].map((_,j)=>row.reduce((v,x,k)=>v+x*b[k][j],0)));
  }
  function astar(width,height,walls,start,goal) {
    const blocked=new Set(walls),open=new Set([start]),closed=new Set(),g=new Map([[start,0]]),parent=new Map();
    const h=p=>Math.abs(p%width-goal%width)+Math.abs(Math.floor(p/width)-Math.floor(goal/width));
    const path=p=>{const out=[p];while(parent.has(p)){p=parent.get(p);out.unshift(p);}return out;};
    const frames=[{open:[start],closed:[],current:start,path:[start],done:false,cost:0}];
    while(open.size) {
      const current=[...open].sort((a,b)=>(g.get(a)+h(a))-(g.get(b)+h(b))||h(a)-h(b)||a-b)[0];
      open.delete(current);closed.add(current);
      if(current===goal){frames.push({open:[...open],closed:[...closed],current,path:path(current),done:true,found:true,cost:g.get(current)});return frames;}
      const x=current%width,y=Math.floor(current/width);
      for(const [nx,ny] of [[x+1,y],[x,y+1],[x-1,y],[x,y-1]]) {
        if(nx<0||nx>=width||ny<0||ny>=height)continue;
        const next=ny*width+nx,cost=g.get(current)+1;
        if(blocked.has(next)||closed.has(next)||cost>=(g.get(next)??Infinity))continue;
        g.set(next,cost);parent.set(next,current);open.add(next);
      }
      frames.push({open:[...open],closed:[...closed],current,path:path(current),done:false,cost:g.get(current)});
    }
    frames.push({open:[],closed:[...closed],current:start,path:[],done:true,found:false,cost:null});return frames;
  }
  function bernoulli(p,n,seed) {
    let a=seed>>>0,total=0;const outcomes=[],frequencies=[];
    for(let i=0;i<n;i++) {
      a=(a+0x6D2B79F5)>>>0;let t=a;t=Math.imul(t^(t>>>15),t|1);t^=t+Math.imul(t^(t>>>7),t|61);
      const value=((t^(t>>>14))>>>0)/4294967296<p?1:0;
      total+=value;outcomes.push(value);frequencies.push(total/(i+1));
    }
    return {outcomes,frequencies,total};
  }
  return {tau,wave,transform,gears,kernel,gaussianProcess,multiply,astar,bernoulli};
})();

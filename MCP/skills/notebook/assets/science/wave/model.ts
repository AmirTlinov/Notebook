/** Fixed-edge, small-displacement membrane: metres, seconds and millimetres.
 * Explicit centred 5-point scheme; the first step uses half the acceleration.
 * https://hplgit.github.io/INF5620/doc/pub/H14/wave/html/lecture_wave-1.html
 */
export const size=256, courant=.45;
export type Parameters={speed:number;time:number;seed:number;shape:'pulse'|'mode'};
const finite=(v:unknown,f:number,low:number,high:number)=>typeof v==='number'&&Number.isFinite(v)?Math.max(low,Math.min(high,v)):f;
export function parameters(value:unknown):Parameters {
  const v=value as Partial<Parameters>|null;
  return {speed:finite(v?.speed,1,.5,2),time:finite(v?.time,.65,0,4),seed:Math.round(finite(v?.seed,246,1,9999)),shape:v?.shape==='mode'?'mode':'pulse'};
}
export const same=(a:Parameters,b:Parameters)=>a.speed===b.speed&&a.time===b.time&&a.seed===b.seed&&a.shape===b.shape;
export function center(seed:number) {
  let state=seed>>>0;const random=()=>{state^=state<<13;state^=state>>>17;state^=state<<5;return (state>>>0)/4294967296;};
  return [.28+.44*random(),.28+.44*random()] as const;
}
export function initial(p:Parameters,n=size) {
  const data=new Float32Array(n*n),[cx,cy]=center(p.seed);
  for(let y=1;y<n-1;y++)for(let x=1;x<n-1;x++) {
    const X=x/(n-1),Y=y/(n-1);
    data[y*n+x]=p.shape==='mode'?Math.sin(Math.PI*X)*Math.sin(Math.PI*Y):Math.exp(-((X-cx)**2+(Y-cy)**2)/(2*.045**2));
  }
  return data;
}
export class Wave {
  readonly dx:number;readonly dt:number;readonly steps:number;readonly c2:number;
  field:Float32Array;previous:Float32Array;private next:Float32Array;step=0;baseline=0;
  constructor(readonly p:Parameters,readonly n=size) {
    if(!Number.isInteger(n)||n<8||n>size)throw new Error('Invalid grid');
    this.dx=1/(n-1);this.steps=Math.ceil(p.time/(courant*this.dx/p.speed));
    this.dt=this.steps?p.time/this.steps:courant*this.dx/p.speed;this.c2=(p.speed*this.dt/this.dx)**2;
    this.field=initial(p,n);this.previous=new Float32Array(n*n);this.next=new Float32Array(n*n);
  }
  advance() {
    if(this.step>=this.steps)return false;
    const {n,field:u,previous:v,next:w,c2}=this,first=this.step===0;
    for(let y=1;y<n-1;y++)for(let x=1;x<n-1;x++) {
      const i=y*n+x,lap=u[i-1]!+u[i+1]!+u[i-n]!+u[i+n]!-4*u[i]!;
      w[i]=first?u[i]!+.5*c2*lap:2*u[i]!-v[i]!+c2*lap;
    }
    this.previous=u;this.field=w;this.next=v;this.step++;
    if(first)this.baseline=this.energy();return true;
  }
  /** Conserved discrete energy at the half step, not a calibrated energy in joules. */
  energy() {
    if(!this.step)return 0;
    let sum=0;const {field:u,previous:v,n,dt,dx,p}=this;
    for(let y=0;y<n;y++)for(let x=0;x<n;x++) {
      const i=y*n+x;sum+=((u[i]!-v[i]!)/dt)**2*dx*dx;
      if(x<n-1)sum+=p.speed**2*(u[i+1]!-u[i]!)*(v[i+1]!-v[i]!);
      if(y<n-1)sum+=p.speed**2*(u[i+n]!-u[i]!)*(v[i+n]!-v[i]!);
    }
    return .5*sum;
  }
  report() {
    let error=0,amplitude=0;const t=this.step*this.dt,factor=Math.cos(Math.PI*Math.SQRT2*this.p.speed*t);
    for(let y=0;y<this.n;y++)for(let x=0;x<this.n;x++) {
      const value=this.field[y*this.n+x]!;amplitude=Math.max(amplitude,Math.abs(value));
      if(this.p.shape==='mode')error=Math.max(error,Math.abs(value-Math.sin(Math.PI*x/(this.n-1))*Math.sin(Math.PI*y/(this.n-1))*factor));
    }
    return {time:t,energy:this.baseline?this.energy()/this.baseline:1,error:this.p.shape==='mode'?error:null,amplitude};
  }
}
// One consistent signed scale for Canvas, static snapshots and external video.
export function color(value:number):[number,number,number] {
  const zero=[243,244,248],end=value<0?[45,85,162]:[201,79,47],t=Math.min(1,Math.abs(value));
  return zero.map((v,i)=>Math.round(v+(end[i]!-v)*t)) as [number,number,number];
}
export type Frame={id:number;step:number;total:number;done:boolean;buffer:ArrayBuffer;report:ReturnType<Wave['report']>};
export type Request={kind:'start';id:number;parameters:Parameters}|{kind:'recycle';id:number;buffer:ArrayBuffer};

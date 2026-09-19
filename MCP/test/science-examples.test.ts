import assert from 'node:assert/strict';
import test from 'node:test';
import {readFile} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import {runInNewContext} from 'node:vm';
import {parseFragment} from 'parse5';
import {operationSchema} from '../src/actions.js';
import {executionInput} from '../src/server.js';
const {prepare}=await import(new URL('../skills/notebook/scripts/prepare.mjs',import.meta.url).href);
const {scienceExamples}=await import(new URL('../skills/notebook/scripts/science-examples.mjs',import.meta.url).href);
const models=runInNewContext(await readFile(new URL('../skills/notebook/assets/science/models.js',import.meta.url),'utf8')+'\nScienceModels');
const near=(a:number,b:number,tolerance=1e-7)=>assert.ok(Math.abs(a-b)<tolerance,`${a} != ${b}`);

test('longitudinal wave preserves particle order and pressure equals negative strain',()=>{
  for(const phase of [0,.125,.25,.5,.75,1])for(const amplitude of [0,.13,.18])for(const wavelength of [1.5,2,3]) {
    let previous=-Infinity;
    for(let q=0;q<=6;q+=.05){const w=models.wave(q,phase,amplitude,wavelength),position=q+w.displacement;assert.ok(position>previous);previous=position;
      near(w.pressure,-(models.wave(q+1e-5,phase,amplitude,wavelength).displacement-models.wave(q-1e-5,phase,amplitude,wavelength).displacement)/2e-5);
      near(w.displacement,models.wave(q,phase+1,amplitude,wavelength).displacement);
    }
  }
});
test('linear model agrees with matrix action, oriented area and singular endpoint',()=>{
  const result=models.transform([1,.8,0,1],1,[1,.5]);near(result.point[0],1.4);near(result.point[1],.5);near(result.determinant,1);
  near(models.transform([1,0,0,0],1,[1,1]).determinant,0);
  near(models.transform([-1,0,0,1],1,[1,1]).determinant,-1);
  const identity=models.transform([2,1,-1,0],0,[3,4]);near(identity.point[0],3);near(identity.point[1],4);
});
test('GP posterior interpolates noiseless data and remains finite with duplicate inputs',()=>{
  const points=[[-1,-.4],[1,.8]],xs=[-1,0,1,3];
  const p=models.gaussianProcess(points,xs,.8,0);near(p[0].mean,-.4);near(p[2].mean,.8);assert.ok(p[0].variance<1e-7);assert.ok(p[3].variance>p[0].variance);
  const duplicate=models.gaussianProcess([[0,1],[0,1]],xs,.15,0);assert.ok(duplicate.every((p:any)=>Number.isFinite(p.mean)&&p.variance>=0));
  for(const p of models.gaussianProcess([],xs,1,.2)){near(p.mean,0);near(p.variance,1);}
});
test('A* agrees with breadth-first shortest paths, including an unreachable target',()=>{
  function bfs(w:number,h:number,walls:number[],start:number,goal:number){const blocked=new Set(walls),seen=new Set([start]);const q:Array<[number,number]>=[[start,0]];for(let i=0;i<q.length;i++){
    const [n,d]=q[i]!;if(n===goal)return d;const x=n%w,y=Math.floor(n/w);
    for(const [a,b] of [[x+1,y],[x-1,y],[x,y+1],[x,y-1]] as const){if(a<0||a>=w||b<0||b>=h)continue;const v=b*w+a;if(!blocked.has(v)&&!seen.has(v)){seen.add(v);q.push([v,d+1]);}}
  }return null;}
  for(let seed=0;seed<12;seed++){const w=9,h=7,walls=Array.from({length:w*h},(_,i)=>i).filter(i=>i!==0&&i!==w*h-1&&(i*17+seed*13)%11<3);
    const frames=models.astar(w,h,walls,0,w*h-1),last=frames.at(-1);assert.equal(last.cost,bfs(w,h,walls,0,w*h-1));
    if(last.found){assert.equal(last.path.length-1,last.cost);last.path.forEach((n:number)=>assert.ok(!walls.includes(n)));}
  }
  assert.equal(models.astar(3,3,[3,4,5],0,8).at(-1).found,false);
  assert.equal(models.astar(3,3,[],4,4).at(-1).cost,0);
});
test('contraction computes every result component from the shared index',()=>{
  const c=models.multiply([[1,2,0],[-1,1,3]],[[2,1],[0,3],[1,-2]]);
  assert.equal(JSON.stringify(c),'[[2,7],[1,-4]]');
});
test('Bernoulli experiment has reproducible prefixes, exact counts and boundary probabilities',()=>{
  const a=models.bernoulli(.37,100,5),b=models.bernoulli(.37,1000,5);
  assert.equal(JSON.stringify(a.outcomes),JSON.stringify(b.outcomes.slice(0,100)));
  assert.equal(a.total,a.outcomes.reduce((sum:number,v:number)=>sum+v,0));near(a.frequencies.at(-1),a.total/100);
  assert.equal(models.bernoulli(0,100,3).total,0);assert.equal(models.bernoulli(1,100,3).total,100);assert.equal(models.bernoulli(.5,0,3).total,0);
});
test('six inline examples prepare through animation into valid self-contained Notebook programs',async()=>{
  assert.equal(scienceExamples.filter((e:any)=>!e.format).length,6);
  for(const example of scienceExamples.filter((e:any)=>!e.format))for(const kind of ['page','document']) {
    const request=await prepare('animation',{example:example.id,target:{kind,id:randomUUID()},initialState:{phase:.25}},{runID:randomUUID()});
    executionInput.parse(request);const operation=request.args.operations[0];operationSchema.parse(operation);
    const program=operation.values;assert.ok(program.javaScript.includes('ScienceModels'));assert.ok(program.html.includes(example.source));assert.ok(Buffer.byteLength(JSON.stringify(request))<200_000);
    new Function(program.javaScript);assert.doesNotMatch(program.javaScript,/\bfetch\s*\(|https?:\/\//);
    const ids=new Set();function visit(n:any){for(const attr of n.attrs??[])if(attr.name==='id'){assert.ok(!ids.has(attr.value),`duplicate ${attr.value}`);ids.add(attr.value);}for(const child of n.childNodes??[])visit(child);}
    visit(parseFragment(program.html));
    assert.deepEqual(program.state??program.initialState,{phase:.25});
  }
  await assert.rejects(prepare('animation',{example:'missing',target:{kind:'page',id:randomUUID()}}),/Unknown science/);
  await assert.rejects(prepare('animation',{example:'sound',html:'ambiguous',target:{kind:'page',id:randomUUID()}}),/not both/);
});

test('shared scene runtime keeps frames local, commits controls and restores focused inputs',async()=>{
  const source=await readFile(new URL('../skills/notebook/assets/science/runtime.js',import.meta.url),'utf8');
  const events=new Map<string,Function>(),frames=new Map<number,Function>(),commits:any[]=[];
  const element=(extra:any={})=>({value:'',textContent:'',listeners:{} as Record<string,Function>,...extra,
    addEventListener(key:string,fn:Function){this.listeners[key]=fn},setAttribute(){}});
  const input=element({type:'range',dataset:{key:'phase'}}),live=element({type:'range',dataset:{key:'yaw',pause:'false'}}),play=element(),output=element();
  const elements=new Map([['phase',input],['play',play],['phase-value',output]]);
  let state:any={phase:.2},sequence=0,ready:Promise<unknown>|undefined,drawn:any,lifecycle:any;
  const document={activeElement:null as any,hidden:false,getElementById:(id:string)=>elements.get(id),
    querySelectorAll:()=>[input,live],addEventListener:(name:string,fn:Function)=>events.set(name,fn),removeEventListener:(name:string)=>events.delete(name)};
  const notebook={get state(){return state},commit:(value:any)=>{state=value;commits.push(value)},ready:(promise:Promise<unknown>)=>ready=promise,lifecycle:(hooks:any)=>lifecycle=hooks};
  const Science=new Function('document','notebook','requestAnimationFrame','cancelAnimationFrame','addEventListener','removeEventListener',source+';return Science;')(document,notebook,
    (fn:Function)=>{frames.set(++sequence,fn);return sequence},(id:number)=>frames.delete(id),(name:string,fn:Function)=>events.set(name,fn),(name:string)=>events.delete(name));
  const app=Science.mount({defaults:{phase:0,yaw:0},ranges:{phase:[0,1]},draw:(s:any)=>drawn=s.phase,tick:(s:any,dt:number)=>({phase:s.phase+dt/1000})});
  await ready;assert.equal(drawn,.2);
  play.listeners.click();
  const tick=(time:number)=>{const [id,fn]=[...frames][0]!;frames.delete(id);fn(time)};
  tick(0);tick(100);near(drawn,.3);assert.equal(commits.length,0);
  app.change({yaw:-.2},false,{pause:false});assert.equal(frames.size,1);assert.equal(play.textContent,'Пауза');
  live.value='.4';live.listeners.input();assert.equal(frames.size,1);assert.equal(app.state.yaw,.4);
  tick(200);near(drawn,.4);assert.equal(commits.length,0);
  play.listeners.click();assert.equal(frames.size,0);assert.equal(commits.length,1);near(state.phase,.4);
  document.activeElement=input;input.value='9';input.listeners.input();assert.equal(drawn,1);assert.equal(commits.length,1);
  input.listeners.change();assert.equal(Number(input.value),1);assert.equal(commits.length,2);
  play.listeners.click();state={phase:.75};events.get('notebookstate')!();
  assert.equal(frames.size,0);assert.equal(drawn,.75);assert.equal(Number(input.value),.75);assert.equal(play.textContent,'Пуск');
  play.listeners.click();tick(300);tick(400);near(drawn,.85);
  const beforeCheckpoint=commits.length;
  lifecycle.pause();assert.equal(frames.size,0);near(lifecycle.checkpoint().phase,.85);
  app.change({phase:.1});play.listeners.click();assert.equal(frames.size,0);near(drawn,.85);
  assert.equal(commits.length,beforeCheckpoint,'owner checkpoint, not a second optimistic commit');
  const checkpoint=lifecycle.checkpoint();checkpoint.phase=0;near(lifecycle.checkpoint().phase,.85);
  lifecycle.resume();assert.equal(frames.size,0);near(drawn,.85);
  play.listeners.click();assert.equal(frames.size,1);lifecycle.dispose();assert.equal(frames.size,0);
  assert.equal(events.has('notebookstate'),false);assert.equal(events.has('visibilitychange'),false);
  app.change({phase:.2});near(drawn,.85);
});

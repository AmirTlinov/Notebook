import {Wave,parameters,size,type Frame,type Request} from './model.ts';
const scope=self as DedicatedWorkerGlobalScope;
let wave:Wave|undefined,id=0,timer=0,spare:ArrayBuffer|undefined,lastSent=0,finished=false;
function publish() {
  if(!wave||!spare||finished)return;
  const now=performance.now(),done=wave.step===wave.steps;
  if(!done&&now-lastSent<40)return;
  new Float32Array(spare).set(wave.field);
  const frame:Frame={id,step:wave.step,total:wave.steps,done,buffer:spare,report:wave.report()};
  scope.postMessage(frame,[spare]);spare=undefined;lastSent=now;finished=done;
}
function tick() {
  timer=0;if(!wave||finished)return;
  try {
    const until=performance.now()+6;
    do {if(!wave.advance())break;}while(performance.now()<until);
    publish();if(wave.step<wave.steps)timer=setTimeout(tick,0);
  }catch(error){scope.postMessage({id,error:String(error)});wave=undefined;spare=undefined;}
}
scope.onmessage=(event:MessageEvent<Request>)=>{
  const input=event.data;
  if(input.kind==='start') {
    // A worker has one job. The caller terminates it on replacement; never queue jobs.
    if(wave)return;
    id=input.id;wave=new Wave(parameters(input.parameters));spare=new ArrayBuffer(size*size*4);tick();
  }else if(input.kind==='recycle'&&input.id===id&&!spare&&!finished&&input.buffer.byteLength===size*size*4) {
    spare=input.buffer;publish();if(wave&&wave.step<wave.steps&&!timer)timer=setTimeout(tick,0);
  }
};

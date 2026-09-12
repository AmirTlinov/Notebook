import './voice-audio.js';
class NotebookMicrophone extends AudioWorkletProcessor {
  constructor(){super();this.audio=new globalThis.NotebookVoiceAudio(sampleRate);this.local=true;this.batch=[];this.batchStart=0;this.loud=false;this.lastLoud=0;
    this.port.onmessage=({data})=>{try{
      if(data.type==='activate'){this.audio.activate(data.start);this.local=false;this.batch=[];this.port.postMessage({type:'activated'});}
      else if(data.type==='connected')this.audio.sending=true;
      else if(data.type==='live'){this.audio.clear();this.audio.mode='holding';this.audio.sending=true;this.local=false;}
      else if(data.type==='off'){this.audio.clear();this.local=false;this.batch=[];}
    }catch(e){this.fail(e);}};
  }
  fail(error){this.audio.clear();this.local=false;this.port.postMessage({type:'failed',message:String(error.message)});}
  process(inputs,outputs){const input=inputs[0]?.[0],output=outputs[0]?.[0];if(!output)return true;
    if(!input){output.fill(0);return true;}
    try{
      const start=this.audio.frame;this.audio.append(input);
      if(!this.local&&this.audio.mode!=='off'){
        if(input.some(x=>Math.abs(x)>.015))this.lastLoud=this.audio.frame;
        const loud=this.lastLoud>0&&this.audio.frame-this.lastLoud<sampleRate*.5;
        if(loud!==this.loud){this.loud=loud;this.port.postMessage({type:'input',speaking:loud});}
      }
      if(this.local){if(!this.batch.length)this.batchStart=start;this.batch.push(input.slice());
        if(this.audio.frame-this.batchStart>=sampleRate/10){const pcm=new Float32Array(this.audio.frame-this.batchStart);let at=0;for(const b of this.batch){pcm.set(b,at);at+=b.length;}this.batch=[];this.port.postMessage({type:'pcm',start:this.batchStart,rate:sampleRate,pcm:pcm.buffer},[pcm.buffer]);}}
      output.set(this.audio.output(output.length));
    }catch(e){this.fail(e);output.fill(0);}return true;
  }
}
registerProcessor('notebook-microphone',NotebookMicrophone);

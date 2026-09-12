'use strict';
// One bounded microphone buffer. There is no peer or network writer while waiting.
class NotebookVoiceAudio {
  constructor(rate) { this.rate=rate; this.frame=0; this.mode='waiting'; this.blocks=[]; this.read=0; this.sending=false; }
  append(samples) {
    const start=this.frame; this.frame+=samples.length;
    if(this.mode==='off') return;
    this.blocks.push({start,data:samples.slice()});
    if(this.mode==='waiting') while(this.blocks.length && this.blocks[0].start < this.frame-this.rate*12) this.blocks.shift();
    else if(this.blocks.length && this.frame-this.blocks[0].start > this.rate*40) throw new Error('Не удалось передать начало обращения. Микрофон выключен.');
  }
  activate(start) {
    if(!Number.isSafeInteger(start) || !this.blocks.length || start<this.blocks[0].start || start>=this.frame) throw new Error('Начало обращения уже недоступно. Передача не начата.');
    while(this.blocks.length && this.blocks[0].start+this.blocks[0].data.length<=start)this.blocks.shift();
    this.read=Math.max(0,start-this.blocks[0].start);this.mode='holding';
  }
  output(count) {
    const out=new Float32Array(count);
    if(!this.sending || this.mode==='waiting' || this.mode==='off')return out;
    // Keep the waveform intact, including quiet speech. The one-time connection
    // delay is not removed by guessing which samples are safe to discard.
    let at=0;
    while(at<count && this.blocks.length){const b=this.blocks[0],n=Math.min(count-at,b.data.length-this.read);out.set(b.data.subarray(this.read,this.read+n),at);at+=n;this.read+=n;if(this.read===b.data.length){this.blocks.shift();this.read=0;}}
    return out;
  }
  clear() {this.blocks=[];this.read=0;this.mode='off';this.sending=false;}
}
globalThis.NotebookVoiceAudio=NotebookVoiceAudio;

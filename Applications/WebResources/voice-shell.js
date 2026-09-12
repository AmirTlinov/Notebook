'use strict';
let peer, microphone, channel, context, source, gate, destination, silent, meter, levels;
let activating, prepared, closed=false;
const post=message=>window.webkit.messageHandlers.notebookVoice.postMessage(message);
const capture=async()=>{
  const owner=context;
  const stream=await navigator.mediaDevices.getUserMedia({audio:{echoCancellation:true,noiseSuppression:true,autoGainControl:true},video:false});
  if(closed||context!==owner){for(const track of stream.getTracks())track.stop();throw new Error('Микрофон выключен');}
  microphone=stream;
  for(const track of microphone.getAudioTracks())track.onended=()=>post({type:'failed',message:'Микрофон отключён системой.'});
  source=context.createMediaStreamSource(microphone);source.connect(gate);
};
const stopCapture=()=>{source?.disconnect();source=null;for(const track of microphone?.getTracks()??[]){track.onended=null;track.stop();}microphone=null;};
window.voicePrepare=async()=>{
  if(context)throw new Error('Микрофон уже включён');closed=false;
  context=new AudioContext({sampleRate:24000});const owner=context;await context.audioWorklet.addModule('voice-worklet.js');
  if(closed||context!==owner)throw new Error('Микрофон выключен');
  const firstAudio=new Promise((resolve,reject)=>{prepared={resolve,reject};});
  gate=new AudioWorkletNode(context,'notebook-microphone',{numberOfInputs:1,numberOfOutputs:1,outputChannelCount:[1]});
  destination=context.createMediaStreamDestination();gate.connect(destination);
  silent=context.createGain();silent.gain.value=0;gate.connect(silent);silent.connect(context.destination);
  gate.port.onmessage=({data})=>{
    if(closed)return;
    if(data.type==='pcm'){
      prepared?.resolve();prepared=null;
      const bytes=new Uint8Array(data.pcm);let binary='';for(const b of bytes)binary+=String.fromCharCode(b);
      post({type:'pcm',start:data.start,rate:data.rate,data:btoa(binary)});
    }else if(data.type==='activated'){activating?.resolve();activating=null;}
    else if(data.type==='failed'){prepared?.reject(new Error(data.message));prepared=null;activating?.reject(new Error(data.message));activating=null;post(data);}
    else post(data);
  };
  await Promise.all([capture().then(()=>context.resume()),firstAudio]);
  if(closed)throw new Error('Микрофон выключен');return context.sampleRate;
};
window.voiceOffer=async start=>{
  if(peer||!gate||closed)throw new Error('Нельзя повторить начало голосового разговора');
  // Admission happens only after the local gate confirms the retained address.
  await new Promise((resolve,reject)=>{activating={resolve,reject};gate.port.postMessage({type:'activate',start});});
  if(closed)throw new Error('Микрофон выключен');
  peer=new RTCPeerConnection({iceServers:[]});
  for(const track of destination.stream.getAudioTracks())peer.addTrack(track,destination.stream);
  peer.ontrack=event=>{
    const speaker=document.getElementById('speaker');speaker.srcObject=event.streams[0];
    speaker.play().catch(()=>post({type:'failed',message:'Система не разрешила воспроизвести голос.'}));
    meter=context.createAnalyser();meter.fftSize=1024;context.createMediaStreamSource(event.streams[0]).connect(meter);meter.connect(silent);
    const samples=new Float32Array(meter.fftSize);let speaking=false,last=0;
    levels=setInterval(()=>{meter.getFloatTimeDomainData(samples);if(samples.some(x=>Math.abs(x)>.008))last=performance.now();
      const next=performance.now()-last<350;if(next!==speaking){speaking=next;post({type:'output',speaking});}},100);
  };
  peer.onconnectionstatechange=()=>{if(peer.connectionState==='connected')gate.port.postMessage({type:'connected'});post({type:'connection',state:peer.connectionState});};
  channel=peer.createDataChannel('oai-events');
  channel.onmessage=event=>{
    if(typeof event.data!=='string'||event.data.length>65536)return;
    try{const value=JSON.parse(event.data);
      if(value.type==='error')post({type:'failed',message:String(value.error?.message??'Ошибка голосового сервиса').slice(0,1024)});
      else if(value.type==='input_transcript.added')post({type:'processing'});
    }catch{}
  };
  const offer=await peer.createOffer();await peer.setLocalDescription(offer);return peer.localDescription.sdp;
};
window.voiceAnswer=async sdp=>{if(!peer)throw new Error('Voice closed');await peer.setRemoteDescription({type:'answer',sdp});};
window.voiceMute=async muted=>{
  if(!peer||closed)throw new Error('Voice closed');
  gate.port.postMessage({type:'off'});stopCapture();
  if(!muted){gate.port.postMessage({type:'live'});await capture();await context.resume();}
};
window.voiceEnd=async()=>{
  closed=true;prepared?.reject(new Error('Микрофон выключен'));prepared=null;activating?.reject(new Error('Микрофон выключен'));activating=null;
  gate?.port.postMessage({type:'off'});stopCapture();clearInterval(levels);levels=null;
  if(peer){peer.onconnectionstatechange=null;peer.close();peer=null;}channel=null;
  for(const track of destination?.stream.getTracks()??[])track.stop();
  const speaker=document.getElementById('speaker');speaker.pause();speaker.srcObject=null;
  gate?.disconnect();meter?.disconnect();silent?.disconnect();await context?.close();
  gate=null;meter=null;silent=null;context=null;destination=null;
};

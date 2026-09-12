'use strict';
let peer, microphone, channel;
const post = message => window.webkit.messageHandlers.notebookVoice.postMessage(message);
window.voiceBegin = async () => {
  if(peer) throw new Error('A voice connection already exists');
  microphone=await navigator.mediaDevices.getUserMedia({audio:{echoCancellation:true,noiseSuppression:true,autoGainControl:true},video:false});
  peer=new RTCPeerConnection({iceServers:[]});
  for(const track of microphone.getAudioTracks()) { peer.addTrack(track,microphone); track.onended=()=>post({type:'failed',message:'Микрофон отключён системой.'}); }
  peer.ontrack=event=>{
    const speaker=document.getElementById('speaker');speaker.srcObject=event.streams[0];
    speaker.play().catch(()=>post({type:'failed',message:'Система не разрешила воспроизвести голос.'}));
  };
  peer.onconnectionstatechange=()=>post({type:'connection',state:peer.connectionState});
  channel=peer.createDataChannel('oai-events');
  channel.onmessage=event=>{
    if(typeof event.data !== 'string' || event.data.length>65536) return;
    try { const value=JSON.parse(event.data); if(value.type==='error') post({type:'failed',message:String(value.error?.message ?? 'Ошибка голосового сервиса').slice(0,1024)}); } catch {}
  };
  const offer=await peer.createOffer(); await peer.setLocalDescription(offer);
  return peer.localDescription.sdp;
};
window.voiceAnswer=async sdp=>{if(!peer) throw new Error('Voice closed');await peer.setRemoteDescription({type:'answer',sdp});};
window.voiceMute=muted=>{for(const track of microphone?.getAudioTracks() ?? []) track.enabled=!muted;};
window.voiceEnd=()=>{
  for(const track of microphone?.getTracks() ?? []) { track.onended=null;track.stop(); }
  microphone=null;if(peer) {peer.onconnectionstatechange=null;peer.close();peer=null;}
  channel=null;const speaker=document.getElementById('speaker');speaker.pause();speaker.srcObject=null;
};

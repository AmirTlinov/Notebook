'use strict';
const terminal = new Terminal({cols:80,rows:24,fontSize:13,fontFamily:'Menlo, monospace',scrollback:1000,
  cursorBlink:false,disableStdin:true,theme:{background:'#181a1f',foreground:'#e1e4eb'},
  linkHandler:{activate(){}}});
const fit = new FitAddon.FitAddon(); terminal.loadAddon(fit);
terminal.open(document.getElementById('terminal'));
let writable = false, replaying = false;
const post = message => window.webkit.messageHandlers.notebookTerminal.postMessage(message);
terminal.onData(text => { if(writable && !replaying) post({type:'input',data:btoa(String.fromCharCode(...new TextEncoder().encode(text)))}); });
terminal.onBinary(text => { if(writable && !replaying) post({type:'input',data:btoa(text)}); });
terminal.onResize(({cols,rows}) => { if(cols>=20 && cols<=500 && rows>=4 && rows<=200) post({type:'size',columns:cols,rows}); });
// No clipboard, image, file, socket or link-opening addons are installed.
terminal.parser.registerOscHandler(52, () => true);
new ResizeObserver(() => { const size=fit.proposeDimensions(); if(size) terminal.resize(Math.max(20,Math.min(500,size.cols)),Math.max(4,Math.min(200,size.rows))); }).observe(document.getElementById('terminal'));
window.writeOutput = async (base64, reset, lost, active) => {
  replaying = true;
  if(reset) terminal.reset();
  if(lost) await new Promise(done => terminal.write('\r\n[Начало вывода вышло за сохранённый буфер Mac]\r\n',done));
  const bytes=Uint8Array.from(atob(base64),char=>char.charCodeAt(0));
  await new Promise(done=>terminal.write(bytes,done));
  writable=active; terminal.options.disableStdin=!active; replaying=false;
};
window.setConnected = connected => { terminal.options.disableStdin=!connected || !writable; };
window.closeTerminal = () => { writable=false; terminal.dispose(); };

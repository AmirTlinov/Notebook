/* Transport adapter for the document owner. Public API lives in notebook-program.js. */
function installNotebookDocumentProgram({blockID, token, state, requiresReady, script = null}, createNotebookProgram) {
  const post=message=>parent.postMessage({...message,blockID,token},'*');
  const report=(kind,message)=>post({channel:'notebook-diagnostic',kind,message:String(message)});
  addEventListener('error',e=>report('javascript_error',e.message));
  addEventListener('unhandledrejection',e=>report('javascript_error',e.reason));
  const reportFocus=()=>post({channel:'notebook-program-focus',focused:!!document.activeElement?.matches('input,textarea,[contenteditable=true]')});
  addEventListener('focusin',reportFocus);
  addEventListener('focusout',()=>queueMicrotask(reportFocus));
  const program=createNotebookProgram({state,report,
    onCommit:(state,revision)=>post({channel:'notebook-interactive',state,revision})});
  window.notebook=program.api;let resuming=Promise.resolve();
  addEventListener('pagehide',()=>{void program.dispose().catch(()=>{})});
  addEventListener('message',async event=>{
    if(event.source!==parent||event.data?.token!==token)return;
    try {
      if(event.data.channel==='notebook-suspend'){
        const state=await program.checkpoint();post({channel:'notebook-program-flushed',requestID:event.data.requestID,state});return;
      }
      if(event.data.channel==='notebook-resume'){resuming=program.resume();await resuming;post({channel:'notebook-program-resumed',requestID:event.data.requestID});return;}
      if(event.data.channel==='notebook-dispose'){await program.dispose();return;}
      if(event.data.channel==='notebook-navigation-blur'){document.activeElement?.blur();reportFocus();return;}
      if(event.data.channel!=='notebook-state')return;
      await resuming;const accepted=await program.apply(event.data.state,event.data.revision);
      post({channel:'notebook-state-applied',requestID:event.data.requestID,accepted});
    } catch(error) {
      post({channel:'notebook-program-error',requestID:event.data.requestID,message:String(error)});
    }
  });
  addEventListener('load',async()=>{
    await document.fonts.ready;
    await Promise.all([...document.images].map(image=>image.decode().catch(()=>{})));
    if(document.body.scrollHeight>innerHeight+1||document.body.scrollWidth>innerWidth+1)report('overflow','Content exceeds its frame');
    for(const image of document.images)if(!image.naturalWidth)report('load_error','Image failed to load');
    try{await program.start({requiresReady});post({channel:'notebook-program-ready'});post({channel:'notebook-program-started'})}
    catch(error){report('program_ready_error',error)}
  });
  if(script!==null)addEventListener('DOMContentLoaded',()=>{try{const node=document.createElement('script');node.textContent=script;document.body.append(node)}catch(error){report('javascript_error',error)}});
}

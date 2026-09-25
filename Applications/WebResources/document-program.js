/* Transport adapter for the document owner. Public API lives in notebook-program.js. */
function installNotebookDocumentProgram({blockID, token, state, requiresReady, stateCredit = 0, script = null}, createNotebookProgram) {
  const post=message=>parent.postMessage({...message,blockID,token},'*');
  const report=(kind,message)=>post({channel:'notebook-diagnostic',kind,message:String(message)});
  addEventListener('error',e=>report('javascript_error',e.message));
  addEventListener('unhandledrejection',e=>report('javascript_error',e.reason));
  const reportFocus=()=>post({channel:'notebook-program-focus',focused:!!document.activeElement?.matches('input,textarea,[contenteditable=true]')});
  addEventListener('focusin',reportFocus);
  addEventListener('focusout',()=>queueMicrotask(reportFocus));
  const program=createNotebookProgram({state,report,
    stateTransport:{credit:stateCredit,onSnapshot:snapshot=>post({channel:'notebook-interactive',snapshot}),
      requestCredit:bytes=>post({channel:'notebook-state-credit',bytes})}});
  window.notebook=program.api;let resuming=Promise.resolve();
  addEventListener('pagehide',()=>{void program.dispose().catch(()=>{})});
  addEventListener('message',async event=>{
    if(event.source!==parent||event.data?.token!==token)return;
    try {
      const current=()=>{if(Number.isFinite(event.data.expiresAt)&&Date.now()>=event.data.expiresAt)throw new Error('program_lifecycle_timeout')};
      current();
      if(event.data.channel==='notebook-finish-accepted'){
        program.setCommitEnabled(false);await program.drainCommits();
        post({channel:'notebook-program-reply',requestID:event.data.requestID,result:true});return;
      }
      if(event.data.channel==='notebook-suspend'){
        const snapshot=await program.checkpoint({retry:true,serialized:true});post({channel:'notebook-program-flushed',requestID:event.data.requestID,state:snapshot});return;
      }
      if(event.data.channel==='notebook-snapshot'){
        post({channel:'notebook-program-reply',requestID:event.data.requestID,result:program.readSnapshot(event.data.argument)});return;
      }
      if(event.data.channel==='notebook-snapshot-ack'){
        program.acknowledgeSnapshot(event.data.argument);post({channel:'notebook-program-reply',requestID:event.data.requestID,result:true});return;
      }
      if(event.data.channel==='notebook-state-credit'){
        program.grantStateCredit(event.data.argument);post({channel:'notebook-program-reply',requestID:event.data.requestID,result:true});return;
      }
      if(event.data.channel==='notebook-cancel-lifecycle'){program.cancelLifecycle();return;}
      if(event.data.channel==='notebook-resume'){resuming=program.resume();await resuming;program.setCommitEnabled(true);post({channel:'notebook-program-resumed',requestID:event.data.requestID});return;}
      if(event.data.channel==='notebook-export'){
        const result=await program.exportFrame(event.data.argument);post({channel:'notebook-program-exported',requestID:event.data.requestID,result});return;
      }
      if(event.data.channel==='notebook-dispose'){await program.dispose();return;}
      if(event.data.channel==='notebook-navigation-blur'){document.activeElement?.blur();reportFocus();return;}
      if(event.data.channel!=='notebook-state-window')return;
      await resuming;current();const accepted=await program.receiveStateWindow(event.data.argument);
      post({channel:'notebook-program-reply',requestID:event.data.requestID,result:accepted});
    } catch(error) {
      post({channel:'notebook-program-error',requestID:event.data.requestID,message:String(error)});
    }
  });
  post({channel:'notebook-program-installed'});
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

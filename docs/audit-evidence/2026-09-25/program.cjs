const fs = require('node:fs'), vm = require('node:vm');
const file = require('node:path').join(process.argv[2] || process.cwd(), 'Applications/WebResources/notebook-program.js');
const context = vm.createContext({setTimeout,clearTimeout,AbortController,dispatchEvent:()=>{}});
vm.runInContext(fs.readFileSync(file,'utf8')+';globalThis.makeProgram=createNotebookProgram;',context);
(async()=>{
 let attempts=0;const p=context.makeProgram({state:{count:1}, timeoutMS:20});
 p.api.lifecycle({pause(){},checkpoint(){if(++attempts===1)throw new Error('transient authored checkpoint failure');return {count:2};}});
 const outcomes=[];for(let i=0;i<3;i++){try{outcomes.push(await p.checkpoint())}catch(e){outcomes.push(e.message)}}
 console.log(JSON.stringify({case:'retryAfterTransientAuthoredCheckpointFailure',outcomes,attempts,suspended:p.suspended,commit:p.api.commit({count:3})}));
 await p.resume();console.log(JSON.stringify({case:'explicitResumeRecovery',checkpoint:await p.checkpoint(),attempts}));
 let calls=0;const h=context.makeProgram({state:{count:1},timeoutMS:20});
 h.api.lifecycle({checkpoint(){calls++;return new Promise(()=>{})}});
 const hung=[];for(let i=0;i<2;i++){try{hung.push(await h.checkpoint())}catch(e){hung.push(e.message)}}
 console.log(JSON.stringify({case:'retryAfterLifecycleTimeout',outcomes:hung,hookCalls:calls,suspended:h.suspended}));
})();
{
 const records=[];const p=context.makeProgram({state:null,onCommit:value=>records.push(value.payload.length)});
 const state={payload:'x'.repeat(4*1024*1024)};const t=performance.now();
 const accepted=p.api.commit(state);
 console.log(JSON.stringify({case:'unboundedExplicitState',bytes:JSON.stringify(state).length,accepted,transmitted:records,commitMilliseconds:performance.now()-t}));
}

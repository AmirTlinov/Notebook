import { BridgeError } from "./bridge.js";

// Leave time for JSON/MCP envelope serialization inside the four-second call.
export const toolBudgetMilliseconds=3_900;
export type RuntimeBootstrap=()=>Promise<Record<string,unknown>>;
export type RuntimeAdmission=(deadline:number)=>Promise<Record<string,unknown>|undefined>;

/** Wait only for admission. A caller whose deadline expires never queues its
 * domain command behind the shared bootstrap, which may finish much later. */
export function runtimeAdmission(bootstrap?:RuntimeBootstrap):RuntimeAdmission {
  return async deadline=>{
    if(!bootstrap)return undefined;
    const starting=()=>new BridgeError({code:"runtime_starting",message:"Notebook запускается. Подключение к Codex остаётся открытым; дождитесь запуска или повторите подключение."});
    if(performance.now()>=deadline)throw starting();
    let timer:ReturnType<typeof setTimeout>|undefined;
    try {
      const value=await Promise.race([bootstrap(),new Promise<never>((_resolve,reject)=>{
        timer=setTimeout(()=>reject(starting()),Math.max(0,deadline-performance.now()));
      })]);
      if(performance.now()>=deadline)throw starting();
      return value;
    }catch(cause){
      // The launcher and server have separate module bundles and Error classes.
      const detail=cause instanceof Error&&"detail" in cause?cause.detail:undefined;
      if(detail&&typeof detail==="object"&&"code" in detail&&typeof detail.code==="string"
        &&"message" in detail&&typeof detail.message==="string")throw new BridgeError({...detail});
      throw new BridgeError({code:"runtime_startup_failed",message:cause instanceof Error?cause.message:String(cause)});
    }finally{clearTimeout(timer);}
  };
}

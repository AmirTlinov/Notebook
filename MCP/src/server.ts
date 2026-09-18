import { McpServer } from "@modelcontextprotocol/server";
import * as z from "zod/v4";
import { BridgeError, defaultSocketPath, runBridge } from "./bridge.js";
import { readFile } from "node:fs/promises";
import { operationSchema, targetSchema } from "./actions.js";

const {version} = JSON.parse(await readFile(new URL("../package.json",import.meta.url),"utf8")) as {version:string};
const operationDiagnostic=z.object({index:z.number().int().min(0).max(511),
  kind:z.enum(operationSchema.options.map(schema=>schema.shape.kind.value)),target:targetSchema,
  id:z.string().max(120).optional()}).strict();
const errorFields = {code:z.string(),message:z.string(),operation:operationDiagnostic.optional()};
const error = z.object({status:z.literal("error"),...errorFields}).passthrough();
export const contextOutput = z.union([z.object({status:z.literal("ready"),value:z.json()}),error]);
const pendingOutput=z.object({status:z.literal("error"),code:z.literal("response_pending"),message:z.string(),
  run_id:z.uuid(),op:z.enum(["start","resume","cancel"]),after_seq:z.number().int().nonnegative(),
  admission:z.enum(["unknown","confirmed"]),observed_status:z.string().optional(),
  resume_semantics:z.literal("attach_only_no_replay")}).strict();
const effect = z.object({id:z.uuid(),key:z.string(),method:z.string(),
  state:z.enum(["admitted","committing","saved","notSaved","outcomeUnknown"]),fingerprint:z.string(),
  actionID:z.uuid().optional(),jobID:z.uuid().optional(),presentationID:z.uuid().optional(),
  contextID:z.uuid().optional(),entryID:z.uuid().optional(),error:z.object(errorFields).optional()}).strict();
export const executionOutput = z.union([z.object({
  status:z.enum(["queued","running","completed","failed","cancelled","interrupted"]),run_id:z.uuid(),
  fingerprint:z.string(),api_version:z.literal(2),run_api_version:z.union([z.literal(1),z.literal(2)]),
  language:z.enum(["javascript","typescript"]).optional(),compiler_version:z.string().nullable().optional(),sdk_version:z.string().nullable().optional(),
  events:z.array(z.object({sequence:z.number().int().positive(),kind:z.enum(["value","image"]),value:z.json(),createdAt:z.number()}).strict()),
  next_seq:z.number().int().nonnegative(),has_more:z.boolean(),result:z.json(),error:z.json(),effects:z.array(effect).max(128),
  resume_semantics:z.literal("attach_only_no_replay"),
}).strict(),pendingOutput,error]);
const cursorFields={after_seq:z.number().int().nonnegative().default(0),wait_ms:z.number().int().min(0).max(4000).default(1000)};
export const executionInput=z.discriminatedUnion("op",[
  z.object({op:z.literal("start"),run_id:z.uuid(),api_version:z.literal(2),code:z.string().max(262144),args:z.json().optional(),...cursorFields}).strict(),
  z.object({op:z.literal("resume"),run_id:z.uuid(),...cursorFields}).strict(),
  z.object({op:z.literal("cancel"),run_id:z.uuid(),...cursorFields}).strict(),
]);
const reads=z.enum(["help","observe","read","readMany","board","notebook","page","document","context","attention",
  "code","search","reference","referenceStatus","action","render","pageMap","pageImage","regions","place","exportStatus","presentation","wait"]);
type Value=Record<string,unknown>;
type Image={type:"image";data:string;mimeType:string};
type PendingRun={run_id:string;op:string;after_seq:number;admission:"unknown"|"confirmed";observed_status?:string};
// Leave time for JSON/MCP envelope serialization inside the four-second call.
const toolBudgetMilliseconds=3_900;

async function artifact(socket:string, descriptor:unknown,deadline:number):Promise<Image> {
  const value=await runBridge<{data:string;mimeType:string;sha256:string}>(socket,{command:"scriptArtifact",artifact:descriptor},{deadline});
  return {type:"image",data:value.data,mimeType:value.mimeType};
}
function failure(cause:unknown):Value {
  if(cause instanceof BridgeError) return {...cause.detail,status:"error",code:String(cause.detail.code??"ipc_failed"),message:cause.message};
  return {status:"error",code:"operation_failed",message:cause instanceof Error?cause.message:String(cause)};
}
async function response(operation:(deadline:number)=>Promise<{value:Value;images?:Image[]}>,pending?:PendingRun){
  const deadline=performance.now()+toolBudgetMilliseconds;
  try {
    const {value,images=[]}=await operation(deadline);
    return {content:[{type:"text" as const,text:JSON.stringify(value)},...images],structuredContent:value};
  } catch(cause) {
    const value=cause instanceof BridgeError&&cause.detail.code==="ipc_timeout"&&pending
      ?{status:"error",code:"response_pending",...pending,resume_semantics:"attach_only_no_replay",
        message:"Notebook не вернул весь ответ за четыре секунды. Продолжите resume с теми же run_id и after_seq. Если run_missing при after_seq:0, можно повторить исходный start с прежними code и args; новый ID создаст другую программу. Принятая запись продолжается после разрыва соединения."}
      :{...failure(cause),...(pending?{run_id:pending.run_id}: {})};
    return {isError:true,content:[{type:"text" as const,text:JSON.stringify(value)}],structuredContent:value};
  }
}

/** Transport and formatting only. Every read, program, effect and image is
 * owned by the installed Mac coordinator; no JS eval or store exists here. */
export function createServer(socketPath=defaultSocketPath()):McpServer {
  const server=new McpServer({name:"notebook",version});
  server.registerTool("notebook_context",{
    title:"Read Notebook and discover its JavaScript SDK",
    description:"Read shared attention, documents, pages, board, revisions, receipts and exact images. API v2 reads return {data,basis,coverage,cursor}; transactions accept base from a read. Use method:'help' only for an unknown contract. args:{topic:'operations'} gives a compact index; topic:'operation/createDocument' (or any operation name) gives one exact schema. transaction gives the complete action schema; interactive includes notebook.ready(promise); execution explains terminal status and output pagination. Other method topics give their schemas and examples. Read methods have the same args as nb methods. render/pageMap/place can prepare derived pictures but never change saved content or the camera.",
    inputSchema:z.object({method:reads.default("observe"),args:z.record(z.string(),z.json()).default({})}).strict(),
    outputSchema:contextOutput,
    annotations:{readOnlyHint:true,destructiveHint:false,openWorldHint:false},
  },({method,args})=>response(async(deadline)=>{
    const reply=await runBridge<Value>(socketPath,{command:"scriptContext",scriptContext:{apiVersion:2,method,arguments:args}},{deadline});
    if(reply.api_version!==2 || !("value" in reply)) throw new BridgeError({code:"api_version_mismatch",message:"MCP v2 requires the matching Mac helper."});
    const data=reply.value;
    const outer=data&&typeof data==="object"?data as Value:{};
    const body = outer.data && typeof outer.data === "object" ? outer.data as Value : outer;
    const descriptors=[body.artifact,...(Array.isArray(body.artifacts)?body.artifacts:[]),
      ...(method==="observe"&&body.visual&&typeof body.visual==="object"?[(body.visual as Value).artifact]:[])].filter(Boolean).slice(0,4);
    const images=await Promise.all(descriptors.map(descriptor=>artifact(socketPath,descriptor,deadline)));
    return {value:{status:"ready",value:data},images};
  }));
  server.registerTool("notebook_execute",{
    title:"Run asynchronous JavaScript against Notebook",
    description:"One Mac-owned QuickJS program with args, nb, await emit(value), await emitImage(artifact). No Python/Node/files/network/imports. Start requires a UUID run_id, api_version:2, code. Generate a UUID per program and reuse it for retries and resume; a descriptive string is not a valid run_id. Same identity attaches and changed code/args conflicts. resume returns paginated output without replaying code. A whole tool reply has a four-second deadline, including admission and image reads; response_pending returns the same run_id, never cancels accepted writes and does not prove admission. Resume that ID; if still absent, retry the identical start. Every mutation requires a stable key: nb.transaction, undo, point, present, cancelPresentation, export. nb.help(topic) explains exact APIs. One transaction is atomic/undoable; an entire script can save several effects. cancel stops new work and reports already accepted outcomes. Native PDF jobs continue outside script time. Limits: 256 KiB source, 1 MiB args, 128 MiB heap, 5 CPU/30 wall seconds, four SDK calls in flight, 128 effects, 4 MiB output total, 256 KiB/event or result. Resume with after_seq=next_seq while status is queued/running OR has_more=true. Stop only when status is completed/failed/cancelled/interrupted AND has_more=false; running+has_more=false is normal.",
    inputSchema:executionInput,outputSchema:executionOutput,
    annotations:{readOnlyHint:false,destructiveHint:true,openWorldHint:false,idempotentHint:true},
  },input=>{
    const pending:PendingRun={run_id:input.run_id,op:input.op,after_seq:input.after_seq,admission:"unknown"};
    return response(async(deadline)=>{
      // Leave time for the native polling tick and IPC response before this
      // same tool deadline; a healthy empty 4s poll must not time out itself.
      const waitMilliseconds=Math.max(0,Math.min(input.wait_ms,Math.floor(deadline-performance.now())-100));
      const request:Value={op:input.op,runID:input.run_id,apiVersion:2,afterSequence:input.after_seq,waitMilliseconds};
      if(input.op==="start") {
        request.apiVersion=input.api_version;request.code=input.code;request.arguments=input.args??null;
      }
      const value=await runBridge<Value>(socketPath,{command:"script",script:request},{deadline});
      if (value.api_version !== 2) throw new BridgeError({code:"api_version_mismatch",message:"MCP v2 requires the matching Mac helper; update the installed pair without resetting its data."});
      pending.admission="confirmed";pending.observed_status=String(value.status);
      const descriptors:unknown[]=[];
      for(const event of (value.events??[]) as Value[]) if(event.kind==="image") {
        if(descriptors.length>=4) throw new BridgeError({code:"output_limit",message:"One output page contains more than four images; request smaller image batches."});
        descriptors.push(event.value);
      }
      const images=await Promise.all(descriptors.map(descriptor=>artifact(socketPath,descriptor,deadline)));
      return {value,images};
    },pending);
  });
  return server;
}

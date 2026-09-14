#!/usr/bin/env node
// Acceptance transport only: actual MCP stdio, two public tools, no store or
// private domain commands. Each process attaches to the existing Mac owner.
import {spawn,execFileSync} from "node:child_process";
import {createHash} from "node:crypto";
import {mkdir,mkdtemp,readFile,writeFile} from "node:fs/promises";
import {dirname,isAbsolute,join,resolve} from "node:path";

const tools=["notebook_context","notebook_execute"];
const maximumMessageBytes=64*1024*1024;

function requireValue(condition,message){if(!condition)throw new Error(message);}
async function input(){
  const chunks=[];let size=0;
  for await(const chunk of process.stdin){size+=chunk.length;requireValue(size<=8*1024*1024,"Arguments exceed 8 MiB");chunks.push(chunk);}
  const value=JSON.parse(Buffer.concat(chunks).toString("utf8"));
  requireValue(value&&typeof value==="object"&&!Array.isArray(value),"Tool arguments must be a JSON object on stdin");
  return value;
}

async function endpoint(path){
  requireValue(isAbsolute(path),"Endpoint path must be absolute");
  const value=JSON.parse(await readFile(path,"utf8"));
  requireValue(value.version===1&&/^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$/.test(value.runID)
    &&typeof value.workspaceID==="string"&&/^[a-f0-9]{64}$/.test(value.sourceSHA256),"Invalid acceptance endpoint identity");
  requireValue(value.socket===`/tmp/notebook-acceptance-${value.runID}/bridge.sock`,"Only the private acceptance socket is allowed");
  requireValue(isAbsolute(value.macApp),"Private application path must be absolute");
  const identifier=execFileSync("/usr/bin/plutil",["-extract","CFBundleIdentifier","raw","-o","-",join(value.macApp,"Contents/Info.plist")],{encoding:"utf8"}).trim();
  requireValue(identifier==="com.amirtlinov.notebook.mac.acceptance","The adapter cannot start a production helper or sidecar");
  return {...value,entry:join(value.macApp,"Contents/Resources/NotebookTools/dist/index.mjs"),output:join(dirname(path),"output")};
}

class Session{
  constructor(configuration){
    this.pending=new Map();this.sequence=0;this.buffer=Buffer.alloc(0);this.stderr="";
    this.child=spawn(process.execPath,[configuration.entry],{stdio:["pipe","pipe","pipe"],
      env:{PATH:"/usr/bin:/bin:/usr/sbin:/sbin",LANG:"en_US.UTF-8",NOTEBOOK_SOCKET:configuration.socket}});
    this.child.stderr.on("data",chunk=>{this.stderr=(this.stderr+String(chunk)).slice(-8000);});
    this.child.stdout.on("data",chunk=>{
      try{
        requireValue(this.buffer.length+chunk.length<=maximumMessageBytes,"MCP reply exceeds 64 MiB");
        this.buffer=Buffer.concat([this.buffer,chunk]);
        for(let newline;(newline=this.buffer.indexOf(10))>=0;){
          const line=this.buffer.subarray(0,newline);this.buffer=this.buffer.subarray(newline+1);
          if(!line.length)continue;
          const value=JSON.parse(line.toString("utf8"));
          requireValue(value.jsonrpc==="2.0","Invalid MCP JSON-RPC envelope");
          const pending=this.pending.get(value.id);
          if(!pending)continue;
          this.pending.delete(value.id);clearTimeout(pending.timer);
          if(value.error)pending.reject(new Error(JSON.stringify(value.error)));else pending.resolve(value.result);
        }
      }catch(error){this.fail(error);this.child.kill("SIGTERM");}
    });
    this.child.on("error",error=>this.fail(error));
    this.child.stdin.on("error",error=>this.fail(error));
    this.child.stdout.on("error",error=>this.fail(error));
    this.child.on("exit",()=>this.fail(new Error("The public MCP sidecar exited before replying")));
  }
  fail(error){for(const pending of this.pending.values()){clearTimeout(pending.timer);pending.reject(error);}this.pending.clear();}
  notify(method,params){this.child.stdin.write(JSON.stringify({jsonrpc:"2.0",method,...(params?{params}:{})})+"\n");}
  rpc(method,params){
    const id=++this.sequence;
    return new Promise((resolve,reject)=>{
      const timer=setTimeout(()=>{this.pending.delete(id);reject(new Error("MCP transport did not reply in 10 seconds; an accepted program may still be running. Keep its original run_id."));},10_000);
      this.pending.set(id,{resolve,reject,timer});
      this.child.stdin.write(JSON.stringify({jsonrpc:"2.0",id,method,params})+"\n");
    });
  }
  async initialize(){
    await this.rpc("initialize",{protocolVersion:"2025-11-25",capabilities:{},clientInfo:{name:"notebook-public-acceptance",version:"1"}});
    this.notify("notifications/initialized");
  }
  async close(){
    this.child.stdin.end();
    if(this.child.exitCode===null){
      await new Promise(resolve=>{const timer=setTimeout(resolve,150);this.child.once("exit",()=>{clearTimeout(timer);resolve();});});
      if(this.child.exitCode===null)this.child.kill("SIGTERM");
    }
  }
}

async function publish(configuration,result,stderr){
  await mkdir(configuration.output,{recursive:true,mode:0o700});
  const directory=await mkdtemp(join(configuration.output,"call-"));
  const raw=join(directory,"response.json");
  await writeFile(raw,JSON.stringify(result,null,2)+"\n",{mode:0o600});
  if(stderr)await writeFile(join(directory,"sidecar.log"),stderr,{mode:0o600});
  const images=[];
  const content=[];
  for(const block of result.content??[]){
    if(block.type!=="image"){content.push(block);continue;}
    requireValue(block.mimeType==="image/png"&&typeof block.data==="string","Notebook image is not PNG");
    const bytes=Buffer.from(block.data,"base64");
    requireValue(bytes.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10])),"Notebook returned invalid PNG bytes");
    const path=join(directory,`image-${images.length+1}.png`);
    await writeFile(path,bytes,{mode:0o600});
    const image={type:"image",mimeType:block.mimeType,path,bytes:bytes.length,sha256:createHash("sha256").update(bytes).digest("hex")};
    content.push(image);images.push(image);
  }
  // The raw file preserves the exact MCP result, including base64. This CLI
  // projection replaces only image encoding with viewable local artifacts.
  return {mcp:{...result,content},rawMCPResponse:raw,images};
}

async function main(){
  const [path,operation,name,...extra]=process.argv.slice(2);
  requireValue(path&&(operation==="list-tools"&&!name||operation==="call"&&tools.includes(name))&&!extra.length,
    "Usage: node public-transport.mjs /absolute/endpoint.json list-tools | call notebook_context|notebook_execute < arguments.json");
  const configuration=await endpoint(resolve(path));
  const args=operation==="call"?await input():undefined;
  const session=new Session(configuration);
  try{
    await session.initialize();
    const listed=await session.rpc("tools/list",{});
    requireValue(JSON.stringify(listed.tools.map(tool=>tool.name).sort())===JSON.stringify(tools),"The endpoint must expose exactly the two public Notebook tools");
    const result=operation==="list-tools"?listed:await publish(configuration,
      await session.rpc("tools/call",{name,arguments:args}),session.stderr);
    process.stdout.write(JSON.stringify(result,null,2)+"\n");
  }finally{await session.close();}
}
try{await main();}catch(error){process.stderr.write(JSON.stringify({transportError:String(error.message??error)})+"\n");process.exitCode=1;}

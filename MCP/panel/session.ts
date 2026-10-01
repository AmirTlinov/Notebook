import { App } from "@modelcontextprotocol/ext-apps";
import type { SceneBounds } from "../src/spatial.js";
import type { PanelSnapshot, PanelAddress, PanelMutation, PanelTarget, PanelView } from "./model.js";

type ToolResult={structuredContent?:Record<string,unknown>;content?:{type:string;text?:string}[];isError?:boolean};
class PanelError extends Error {
  constructor(readonly code:string,message:string){super(message);}
}
function body(result:ToolResult):Record<string,unknown> {
  const value=result.structuredContent??JSON.parse(result.content?.find(c=>c.type==="text")?.text??"{}");
  if(result.isError||value.status==="error")throw new PanelError(String(value.code??"panel_failed"),String(value.message??"Notebook не ответил."));
  return value;
}
function isSnapshot(value:Record<string,unknown>):value is Record<string,unknown>&PanelSnapshot {
  return typeof value.workspaceID==="string"&&typeof value.socketKey==="string"&&Array.isArray(value.elements)&&!!value.target;
}
function sameAddress(a:PanelAddress,b:PanelAddress):boolean {
  return a.workspaceID.toLowerCase()===b.workspaceID.toLowerCase()&&a.socketKey===b.socketKey
    &&a.target.kind===b.target.kind&&a.target.id.toLowerCase()===b.target.id.toLowerCase();
}

/** The bridge carries snapshots and completed gestures. Native Notebook owns all saved state. */
export class NotebookSession {
  readonly app=new App({name:"Notebook",version:"1.0.0"},{availableDisplayModes:["fullscreen"]});
  snapshot:PanelSnapshot|undefined;
  busy=false;
  get hasPending(){return !!this.pending;}
  suspended=false;
  onSnapshot:(snapshot:PanelSnapshot)=>void=()=>{};
  onPrepareSnapshot:(snapshot:PanelSnapshot)=>Promise<boolean>=async()=>true;
  onClose:()=>void=()=>{};
  onStatus:(text:string)=>void=()=>{};
  onError:(message:string,retry:(()=>Promise<void>)|null)=>void=()=>{};
  bounds:()=>SceneBounds|undefined=()=>undefined;
  view:(navigation:boolean)=>PanelView=()=>({viewport:{x:834,y:1194},pixelScale:1});
  private timer:ReturnType<typeof setInterval>|undefined;
  private reading=false;
  private closed=false;
  private boundsDirty=true;
  private initialClaimed=false;
  private presented=false;
  private generation=0;
  private navigation=0;
  private refreshQueued=false;
  private settled:ReturnType<typeof setTimeout>|undefined;
  get hasAppearance(){return this.presented;}
  private pending:{name:string;arguments:Record<string,unknown>;resolve:()=>void;reject:(error:unknown)=>void}|undefined;

  async connect() {
    this.app.ontoolresult=result=>{
      // The host hands this view its initial surface. Later tool calls cannot
      // redirect a mounted view or an in-progress human gesture.
      if(this.initialClaimed)return;
      try { const value=body(result as ToolResult);if(isSnapshot(value)){
        this.initialClaimed=true;this.snapshot=value;this.onStatus("Подготовка поверхности…");void this.refresh(true);
      } }
      catch(error){this.report(error,null);}
    };
    this.app.onteardown=async()=>{this.closed=true;this.presented=false;++this.generation;clearInterval(this.timer);clearTimeout(this.settled);
      this.pending?.reject(new Error("Панель закрыта."));this.pending=undefined;this.onClose();this.onStatus("Панель закрыта");return {};};
    await this.app.connect();
    if(this.closed)return;
    this.timer=setInterval(()=>{if(!document.hidden&&!this.suspended&&!this.busy)void this.refresh();},1500);
  }
  address():PanelAddress {
    if(!this.snapshot)throw new Error("Notebook ещё подключается.");
    const {workspaceID,target,socketKey}=this.snapshot;return {workspaceID,target,socketKey};
  }
  viewportChanged(){
    this.boundsDirty=true;++this.generation;clearTimeout(this.settled);
    this.settled=setTimeout(()=>void this.refresh(true),140);
  }
  async openSurface(target:PanelTarget){
    if(this.busy||this.pending||this.closed)return false;
    const navigation=++this.navigation;++this.generation;
    this.busy=true;this.onStatus("Открытие…");
    try {
      while(!this.closed&&navigation===this.navigation){
        const generation=this.generation,request={...this.address(),target,appearance:this.view(true)};
        const value=body(await this.app.callServerTool({name:"notebook_panel_presentation",arguments:request}) as ToolResult);
        if(!isSnapshot(value)||!sameAddress(request,value))throw new Error("Notebook вернул другую поверхность.");
        if(this.closed||navigation!==this.navigation)return false;
        if(generation!==this.generation)continue;
        if(!(await this.onPrepareSnapshot(value)))return false;
        if(this.closed||navigation!==this.navigation)return false;
        // A resized panel still opens the requested target, using a fresh native
        // entry projection for its latest bounds before any pixels are accepted.
        if(generation!==this.generation)continue;
        this.accept(value);this.boundsDirty=false;this.refreshQueued=false;return true;
      }
      return false;
    }catch(error){if(!this.closed)this.report(error,null);return false;}
    finally{this.busy=false;if(this.refreshQueued&&!this.closed)void this.refresh(true);}
  }
  async refresh(force=false) {
    if(this.closed||!this.snapshot)return;
    if(this.reading||this.suspended||this.busy||this.pending){this.refreshQueued=true;return;}
    this.reading=true;this.refreshQueued=false;
    const generation=this.generation;
    const request={...this.address(),appearance:this.view(false),...(!force&&!this.boundsDirty&&this.presented?{
      knownCursor:this.snapshot.cursor,knownRequestID:this.snapshot.appearance?.requestID}: {})};
    try {
      if(force||this.boundsDirty||!this.presented)this.onStatus("Подготовка поверхности…");
      const value=body(await this.app.callServerTool({name:"notebook_panel_presentation",arguments:request}) as ToolResult);
      if(this.stale(request,generation))return;
      if(value.unchanged){
        if(typeof value.workspaceID!=="string"||!value.target
          ||!sameAddress(request,{workspaceID:value.workspaceID,target:value.target as PanelTarget,socketKey:request.socketKey}))throw new Error("Notebook вернул другую поверхность.");
        this.onError("",null);this.onStatus("Подключено");return;
      }
      if(!isSnapshot(value)||!sameAddress(request,value))throw new Error("Notebook вернул другую поверхность.");
      if(!(await this.onPrepareSnapshot(value))||this.stale(request,generation))return;
      this.onError("",null);this.accept(value);
      this.boundsDirty=false;
    }catch(error){if(!this.stale(request,generation))this.report(error,()=>this.refresh(true));}
    finally{this.reading=false;if(this.refreshQueued&&!this.suspended&&!this.busy&&!this.pending&&!this.closed)void this.refresh(true);}
  }
  private stale(request:PanelAddress,generation:number){return this.closed||generation!==this.generation
    ||!sameAddress(request,this.address())||this.suspended||this.busy||!!this.pending;}
  async save(request:PanelMutation){return this.mutate("notebook_panel_edit",request);}
  async undo() {
    const actionID=this.snapshot?.history.undoActionID;if(!actionID)return;
    return this.mutate("notebook_panel_undo",{...this.address(),actionID});
  }
  private async mutate(name:string,args:Record<string,unknown>) {
    if(this.closed)throw new Error("Панель закрыта.");
    if(this.busy||this.pending)throw new Error("Дождитесь сохранения текущей правки.");
    const completion=new Promise<void>((resolve,reject)=>{this.pending={name,arguments:args,resolve,reject};});
    void this.sendPending();return completion;
  }
  private async sendPending() {
    if(!this.pending||this.busy)return;
    this.busy=true;this.onStatus("Сохранение…");
    const pending=this.pending;
    try {
      body(await this.app.callServerTool({name:pending.name,arguments:pending.arguments}) as ToolResult);
      this.pending=undefined;this.onError("",null);pending.resolve();
    }catch(error) {
      const uncertain=!(error instanceof PanelError)||["ipc_timeout","ipc_unavailable","ipc_protocol"].includes(error.code);
      if(!uncertain){this.pending=undefined;pending.reject(error);}
      this.report(error,uncertain?()=>this.sendPending():null);
    }finally {
      this.busy=false;
      if(!this.pending){await this.refresh(true);}
    }
  }
  context(selectedElementID:string|null) {
    if(!this.snapshot)return;
    const snapshot=this.snapshot;
    void this.app.updateModelContext({content:[{type:"text",text:JSON.stringify({
      notebookPanel:{workspaceID:snapshot.workspaceID,target:snapshot.target,cursor:snapshot.cursor,
        selectedElementID,visibleBounds:this.bounds(),
        instruction:"Human is working in this exact Notebook surface. Read canonical content with Notebook tools before editing; panel selection is context, not mutation authority."},
    })}]}).catch(()=>{});
  }
  private accept(value:Record<string,unknown>) {
    if(!isSnapshot(value))throw new Error("Notebook вернул неполную поверхность.");
    if(this.snapshot&&sameAddress(this.snapshot,value)
      &&/^\d+$/.test(value.cursor)&&/^\d+$/.test(this.snapshot.cursor)&&BigInt(value.cursor)<BigInt(this.snapshot.cursor))return;
    if(value.appearance?.status!=="ready")throw new Error("Notebook ещё готовит изображение поверхности.");
    this.snapshot=value;this.presented=true;this.onSnapshot(value);this.onStatus("Подключено");
  }
  private report(error:unknown,retry:(()=>Promise<void>)|null) {
    this.onStatus("Проверьте связь");
    this.onError(error instanceof Error?error.message:String(error),retry);
  }
}

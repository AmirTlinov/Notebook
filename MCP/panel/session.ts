import { App } from "@modelcontextprotocol/ext-apps";
import type { SceneBounds } from "../src/spatial.js";
import type { PanelSnapshot, PanelAddress, PanelMutation, PanelRead, PanelTarget } from "./model.js";

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
  return a.workspaceID===b.workspaceID&&a.socketKey===b.socketKey&&a.target.kind===b.target.kind&&a.target.id===b.target.id;
}

/** The bridge carries snapshots and completed gestures. Native Notebook owns all saved state. */
export class NotebookSession {
  readonly app=new App({name:"Notebook",version:"1.0.0"},{availableDisplayModes:["fullscreen"]});
  snapshot:PanelSnapshot|undefined;
  busy=false;
  get hasPending(){return !!this.pending;}
  suspended=false;
  onSnapshot:(snapshot:PanelSnapshot)=>void=()=>{};
  onStatus:(text:string)=>void=()=>{};
  onError:(message:string,retry:(()=>Promise<void>)|null)=>void=()=>{};
  bounds:()=>SceneBounds|undefined=()=>undefined;
  private timer:ReturnType<typeof setInterval>|undefined;
  private reading=false;
  private closed=false;
  private boundsDirty=true;
  private pending:{name:string;arguments:Record<string,unknown>;resolve:()=>void;reject:(error:unknown)=>void}|undefined;

  async connect() {
    this.app.ontoolresult=result=>{
      // The host hands this view its initial surface. Later tool calls cannot
      // redirect a mounted view or an in-progress human gesture.
      if(this.snapshot)return;
      try { const value=body(result as ToolResult);if(isSnapshot(value))this.accept(value); }
      catch(error){this.report(error,null);}
    };
    this.app.onteardown=async()=>{this.closed=true;clearInterval(this.timer);return {};};
    await this.app.connect();
    this.timer=setInterval(()=>{if(!document.hidden&&!this.suspended&&!this.busy)void this.refresh();},1500);
  }
  address():PanelAddress {
    if(!this.snapshot)throw new Error("Notebook ещё подключается.");
    const {workspaceID,target,socketKey}=this.snapshot;return {workspaceID,target,socketKey};
  }
  viewportChanged(){this.boundsDirty=true;}
  async openSurface(target:PanelTarget){
    if(this.busy||this.pending)return;
    this.busy=true;this.onStatus("Открытие…");
    const request={...this.address(),target};
    try {
      const result=await this.app.callServerTool({name:"notebook_panel_read",arguments:request});
      const value=body(result as ToolResult);
      if(!isSnapshot(value)||!sameAddress(request,value))throw new Error("Notebook вернул другую поверхность.");
      this.accept(value);this.boundsDirty=true;
    }catch(error){this.report(error,null);}
    finally{this.busy=false;}
  }
  async refresh(force=false) {
    if(this.closed||this.reading||!this.snapshot||this.suspended||this.busy||this.pending)return;
    this.reading=true;
    const request:PanelRead={...this.address()};const bounds=this.bounds();if(bounds)request.bounds=bounds;
    if(!force&&!this.boundsDirty)request.knownCursor=this.snapshot.cursor;
    try {
      const result=await this.app.callServerTool({name:"notebook_panel_read",arguments:request});
      if(!sameAddress(request,this.address())||this.suspended||this.busy||this.pending)return;
      const value=body(result as ToolResult);this.onError("",null);if(!value.unchanged)this.accept(value);
      this.boundsDirty=false;
    }catch(error){this.report(error,()=>this.refresh(true));}
    finally{this.reading=false;}
  }
  async save(request:PanelMutation){return this.mutate("notebook_panel_edit",request);}
  async undo() {
    const actionID=this.snapshot?.history.undoActionID;if(!actionID)return;
    return this.mutate("notebook_panel_undo",{...this.address(),actionID});
  }
  private async mutate(name:string,args:Record<string,unknown>) {
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
    this.snapshot=value;this.onSnapshot(value);this.onStatus("Подключено");
  }
  private report(error:unknown,retry:(()=>Promise<void>)|null) {
    this.onStatus("Проверьте связь");
    this.onError(error instanceof Error?error.message:String(error),retry);
  }
}

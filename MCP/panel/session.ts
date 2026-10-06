import { App } from "@modelcontextprotocol/ext-apps";
import type { SceneBounds } from "../src/spatial.js";
import type { PanelSnapshot, PanelAddress, PanelMutation, PanelSelection, PanelTarget, PanelView } from "./model.js";

type ToolResult={structuredContent?:Record<string,unknown>;content?:{type:string;text?:string}[];isError?:boolean};
export type RuntimeStatus={kind:"notebookRuntime";ready:boolean;pid:number;state:"opening"|"ready"|"workspaceRequired"|"failed";workspaceID?:string;socketKey?:string;message?:string};
export type WorkspaceRequest={action:"list"|"create"|"select"|"rename"|"retry";id?:string;name?:string};
export type WorkspaceResult={status:RuntimeStatus;workspaces:{id:string;name:string;local:boolean;remote:boolean;deleting:boolean}[];error?:string;catalogError?:string;snapshot?:PanelSnapshot};
export class PanelError extends Error {
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
  private synchronizing=false;
  private failedWrite=false;
  private contextSelection:PanelSelection|null=null;
  private contextTimer:ReturnType<typeof setTimeout>|undefined;
  private contextWriting=false;
  private contextDirty=false;
  get mutationReady(){return this.presented&&!this.suspended&&!this.busy&&!this.pending&&!this.synchronizing;}
  get hasPending(){return !!this.pending;}
  suspended=false;
  onSnapshot:(snapshot:PanelSnapshot)=>void=()=>{};
  onPrepareSnapshot:(snapshot:PanelSnapshot,view:PanelView)=>Promise<boolean>=async()=>true;
  onClose:()=>void=()=>{};
  onStatus:(text:string)=>void=()=>{};
  onError:(message:string,retry:(()=>Promise<void>)|null)=>void=()=>{};
  onRuntime:(status:RuntimeStatus)=>void=()=>{};
  bounds:()=>SceneBounds|undefined=()=>undefined;
  view:(navigation:boolean,camera?:PanelView["camera"])=>PanelView=()=>({viewport:{x:834,y:1194},pixelScale:1});
  knownAssets:()=>string[]=()=>[];
  needsPresentation:()=>boolean=()=>true;
  private timer:ReturnType<typeof setInterval>|undefined;
  private reading=false;
  private readers:(()=>void)[]=[];
  private closed=false;
  private boundsDirty=true;
  private initialClaimed=false;
  private presented=false;
  private presentedView:PanelView|undefined;
  private generation=0;
  private viewRevision=0;
  private navigation=0;
  private forcedRefreshQueued=false;
  private viewportRefreshQueued=false;
  private refreshTimer:ReturnType<typeof setTimeout>|undefined;
  get hasAppearance(){return this.presented;}
  private pending:{name:string;arguments:Record<string,unknown>;resolve:()=>void;reject:(error:unknown)=>void}|undefined;

  async connect() {
    this.app.ontoolresult=result=>{
      // The host hands this view its initial surface. Later tool calls cannot
      // redirect a mounted view or an in-progress human gesture.
      if(this.closed||this.initialClaimed)return;
      try { const value=body(result as ToolResult);if(isSnapshot(value)){
        this.initialClaimed=true;this.snapshot=value;this.onStatus("Подготовка поверхности…");void this.refresh(true);
      }else if(value.runtime){this.onRuntime(value.runtime as RuntimeStatus);} }
      catch(error){this.report(error,null);}
    };
    this.app.onteardown=async()=>{
      if(this.closed)return {};
      this.closed=true;this.presented=false;++this.generation;
      clearInterval(this.timer);clearTimeout(this.refreshTimer);clearTimeout(this.contextTimer);
      this.timer=undefined;this.refreshTimer=undefined;this.contextTimer=undefined;
      this.pending?.reject(new Error("Панель закрыта."));this.pending=undefined;
      this.busy=false;this.releaseReaders();
      this.onStatus("Панель закрыта");this.onClose();return {};
    };
    try{await this.app.connect();}catch(error){if(!this.closed)throw error;}
    if(this.closed)return;
    this.timer=setInterval(()=>{if(!document.hidden&&!this.suspended&&!this.busy)void this.refresh();},1500);
  }
  address():PanelAddress {
    if(!this.snapshot)throw new Error("Notebook ещё подключается.");
    const {workspaceID,target,socketKey}=this.snapshot;return {workspaceID,target,socketKey};
  }
  async workspace(request:WorkspaceRequest):Promise<WorkspaceResult|undefined>{
    if(this.closed||this.busy||(this.pending&&request.action!=="list"&&request.action!=="retry"))return;
    this.busy=true;this.onStatus("Открытие пространства…");
    const recovering=request.action==="retry"&&this.snapshot!==undefined;
    const command=recovering?{...request,id:this.snapshot!.workspaceID}:request;
    let repaired=false;
    try{
      const value=body(await this.app.callServerTool({name:"notebook_panel_workspace",arguments:command}) as ToolResult) as WorkspaceResult;
      if(this.closed)return;
      if(value.snapshot&&isSnapshot(value.snapshot)){
        if(value.snapshot.workspaceID.toLowerCase()!==value.status.workspaceID?.toLowerCase()||value.snapshot.socketKey!==value.status.socketKey){
          throw new Error("Notebook вернул другое пространство.");
        }
        if(recovering){
          if(value.snapshot.workspaceID.toLowerCase()!==this.snapshot!.workspaceID.toLowerCase()||value.snapshot.socketKey!==this.snapshot!.socketKey){
            throw new Error("Восстановление вернуло другое пространство.");
          }
          repaired=!value.error&&value.status.state==="ready";
          // Recovery keeps this panel's page, camera, selection and accepted
          // action. The runtime's current focus belongs to another surface.
          if(repaired)this.failedWrite=false;
        }else{
          ++this.generation;++this.navigation;
          this.initialClaimed=true;this.presented=false;this.snapshot=value.snapshot;
          this.presentedView=undefined;this.boundsDirty=true;this.failedWrite=false;
          this.contextSelection=null;this.contextDirty=false;
          clearTimeout(this.contextTimer);this.contextTimer=undefined;
        }
      }
      return value;
    }finally{
      this.busy=false;
      if(!this.closed){
        if(repaired&&this.pending)void this.sendPending();
        else if(this.snapshot&&(!this.presented||repaired))void this.refresh(true);
        else this.onStatus(this.presented?"Подключено":"Выберите пространство");
      }
    }
  }
  viewportChanged(){
    if(this.closed)return;
    this.boundsDirty=this.needsPresentation();++this.viewRevision;this.queueContext();
    if(this.boundsDirty){if(!this.viewportRefreshQueued)this.queueRefresh();}
    else {clearTimeout(this.refreshTimer);this.refreshTimer=undefined;this.viewportRefreshQueued=false;}
  }
  private queueRefresh(){
    if(this.closed||this.refreshTimer!==undefined)return;
    this.refreshTimer=setTimeout(()=>{this.refreshTimer=undefined;this.viewportRefreshQueued=true;this.drainRefresh();},80);
  }
  private drainRefresh(){
    if(this.closed)return;
    if(!this.boundsDirty){clearTimeout(this.refreshTimer);this.refreshTimer=undefined;this.viewportRefreshQueued=false;}
    if(this.reading||this.suspended||this.busy||this.pending)return;
    if(this.forcedRefreshQueued||this.viewportRefreshQueued)void this.refresh(this.forcedRefreshQueued);
  }
  async openSurface(target:PanelTarget,camera?:PanelView["camera"]){
    if(this.busy||this.pending||this.closed)return false;
    const navigation=++this.navigation;++this.generation;
    this.busy=true;this.failedWrite=false;this.onError("",null);this.onStatus("Открытие…");
    try {
      while(!this.closed&&navigation===this.navigation){
        const generation=this.generation,viewRevision=this.viewRevision,request={...this.address(),target,appearance:this.view(true,camera),knownAssets:this.knownAssets()};
        const value=body(await this.app.callServerTool({name:"notebook_panel_presentation",arguments:request}) as ToolResult);
        if(!isSnapshot(value)||!sameAddress(request,value))throw new Error("Notebook вернул другую поверхность.");
        if(this.closed||navigation!==this.navigation)return false;
        if(generation!==this.generation||viewRevision!==this.viewRevision)continue;
        if(!(await this.onPrepareSnapshot(value,request.appearance)))return false;
        if(this.closed||navigation!==this.navigation)return false;
        // A resized panel still opens the requested target, using a fresh native
        // entry projection for its latest bounds before any pixels are accepted.
        if(generation!==this.generation||viewRevision!==this.viewRevision)continue;
        this.accept(value,request.appearance);this.boundsDirty=this.needsPresentation();this.viewportRefreshQueued=false;
        clearTimeout(this.refreshTimer);this.refreshTimer=undefined;return true;
      }
      return false;
    }catch(error){if(!this.closed)this.report(error,null);return false;}
    finally{this.busy=false;this.drainRefresh();}
  }
  async requestFit():Promise<SceneBounds|undefined>{
    if(!this.mutationReady||this.suspended||this.closed)return;
    const generation=this.generation,revision=this.viewRevision;
    while(this.reading&&!this.closed)await new Promise<void>(resolve=>this.readers.push(resolve));
    if(this.closed||generation!==this.generation||revision!==this.viewRevision)return;
    const snapshot=await this.refresh(true,true);
    return generation===this.generation&&revision===this.viewRevision?snapshot?.fitBounds:undefined;
  }
  async refresh(force=false,includeFitBounds=false):Promise<PanelSnapshot|undefined> {
    if(this.closed||!this.snapshot)return;
    // Idle polling never queues a forced repaint behind a slow native render.
    if(this.reading||this.suspended||this.busy||this.pending){this.forcedRefreshQueued ||= force;return;}
    clearTimeout(this.refreshTimer);this.refreshTimer=undefined;
    force ||= this.forcedRefreshQueued;
    this.reading=true;this.forcedRefreshQueued=false;this.viewportRefreshQueued=false;
    const generation=this.generation,viewRevision=this.viewRevision;
    const view=!force&&!includeFitBounds&&!this.boundsDirty&&this.presentedView?this.presentedView:this.view(false);
    const request={...this.address(),appearance:view,knownAssets:this.knownAssets(),...(includeFitBounds?{includeFitBounds:true}:{}),...(!force&&!this.boundsDirty&&this.presented?{
      knownCursor:this.snapshot.cursor,knownRequestID:this.snapshot.appearance?.requestID}: {})};
    try {
      if(force||this.boundsDirty||!this.presented)this.onStatus("Подготовка поверхности…");
      const value=body(await this.app.callServerTool({name:"notebook_panel_presentation",arguments:request}) as ToolResult);
      if(this.stale(request,generation))return;
      if(!this.presented&&viewRevision!==this.viewRevision)return;
      if(value.unchanged){
        if(typeof value.workspaceID!=="string"||!value.target
          ||!sameAddress(request,{workspaceID:value.workspaceID,target:value.target as PanelTarget,socketKey:request.socketKey}))throw new Error("Notebook вернул другую поверхность.");
        this.synchronizing=false;if(!this.failedWrite)this.onError("",null);this.onStatus("Подключено");return this.snapshot;
      }
      if(!isSnapshot(value)||!sameAddress(request,value))throw new Error("Notebook вернул другую поверхность.");
      if(!(await this.onPrepareSnapshot(value,request.appearance))||this.stale(request,generation))return;
      if(!this.failedWrite)this.onError("",null);this.accept(value,request.appearance);
      // Camera motion does not invalidate world-placed pixels. Keep the current
      // camera and coalesce the latest projection after accepting useful coverage.
      this.boundsDirty=this.needsPresentation();
      return this.snapshot;
    }catch(error){if(!this.stale(request,generation))this.report(error,async()=>{await this.refresh(true);});}
    finally{
      this.reading=false;
      this.releaseReaders();
      if(!this.closed){
        if(viewRevision!==this.viewRevision){
          this.boundsDirty=this.needsPresentation();
          if(this.boundsDirty&&this.refreshTimer===undefined)this.viewportRefreshQueued=true;
        }
        // A useful intermediate cohort can already cover the final camera. Only
        // unmet viewport demand survives; an elapsed coalesce never waits twice.
        queueMicrotask(()=>this.drainRefresh());
      }
    }
  }
  private releaseReaders(){for(const resolve of this.readers.splice(0))resolve();}
  private stale(request:PanelAddress,generation:number){return this.closed||generation!==this.generation
    ||!sameAddress(request,this.address())||this.suspended||this.busy||!!this.pending;}
  async save(request:PanelMutation){return this.mutate("notebook_panel_edit",request);}
  async undo() {
    const actionID=this.snapshot?.history.undoActionID;if(!actionID)return;
    return this.mutate("notebook_panel_undo",{...this.address(),actionID});
  }
  private async mutate(name:string,args:Record<string,unknown>) {
    if(this.closed)throw new Error("Панель закрыта.");
    if(!this.mutationReady)throw new Error("Дождитесь сохранения текущей правки.");
    ++this.generation;this.failedWrite=false;this.onError("",null);
    const completion=new Promise<void>((resolve,reject)=>{this.pending={name,arguments:args,resolve,reject};});
    void this.sendPending();return completion;
  }
  private async sendPending() {
    if(this.closed||!this.pending||this.busy)return;
    this.busy=true;this.onStatus("Сохранение…");
    const pending=this.pending;
    try {
      const result=await this.app.callServerTool({name:pending.name,arguments:pending.arguments}) as ToolResult;
      if(this.closed||this.pending!==pending)return;
      body(result);
      this.pending=undefined;this.synchronizing=true;this.onError("",null);pending.resolve();
    }catch(error) {
      if(this.closed||this.pending!==pending)return;
      const retryable=!(error instanceof PanelError)||["ipc_timeout","ipc_unavailable","ipc_protocol","operation_failed"].includes(error.code);
      if(!retryable){this.pending=undefined;this.failedWrite=true;pending.reject(error);}
      this.report(error,retryable?()=>this.retryPending():null);
    }finally {
      this.busy=false;
      // The accepted command retires any pre-contact read. Its replacement
      // must survive that reader's slot, even when camera coverage is current.
      if(!this.closed&&!this.pending){await this.refresh(true);}
    }
  }
  private async retryPending(){
    if(this.closed||!this.pending||this.busy)return;
    try{
      const result=await this.workspace({action:"retry"});
      if(result&&(result.error||result.status.state!=="ready")){
        throw new Error(result.error??result.status.message??"Сохранение ещё не восстановлено.");
      }
    }catch(error){this.report(error,()=>this.retryPending());}
  }
  context(selection:PanelSelection|null) {
    if(this.closed)return;
    this.contextSelection=selection;clearTimeout(this.contextTimer);this.contextTimer=undefined;void this.publishContext();
  }
  private queueContext(){
    if(this.closed||!this.presented)return;
    clearTimeout(this.contextTimer);
    this.contextTimer=setTimeout(()=>{this.contextTimer=undefined;void this.publishContext();},120);
  }
  private async publishContext(){
    if(!this.snapshot||this.closed||!this.presented)return;
    if(this.contextWriting){this.contextDirty=true;return;}
    this.contextWriting=true;
    const snapshot=this.snapshot,selection=this.contextSelection;
    try {await this.app.updateModelContext({content:[{type:"text",text:JSON.stringify({
      notebookPanel:{workspaceID:snapshot.workspaceID,target:snapshot.target,cursor:snapshot.cursor,
        selectedElementID:selection?.kind==="element"?selection.id:null,selectedItemID:selection?.kind==="item"?selection.id:null,visibleBounds:this.bounds(),
        instruction:"Human is working in this exact Notebook surface. Read canonical content with Notebook tools before editing; panel selection is context, not mutation authority."},
    })}]});}catch{}finally{
      this.contextWriting=false;
      if(this.contextDirty){this.contextDirty=false;void this.publishContext();}
    }
  }
  private accept(value:Record<string,unknown>,view:PanelView) {
    if(!isSnapshot(value))throw new Error("Notebook вернул неполную поверхность.");
    if(this.snapshot&&sameAddress(this.snapshot,value)
      &&/^\d+$/.test(value.cursor)&&/^\d+$/.test(this.snapshot.cursor)&&BigInt(value.cursor)<BigInt(this.snapshot.cursor))return;
    if(value.appearance?.status!=="ready")throw new Error("Notebook ещё готовит изображение поверхности.");
    this.snapshot=value;this.presentedView={...view,camera:value.appearance.camera};this.presented=true;this.synchronizing=false;this.onSnapshot(value);this.onStatus("Подключено");
  }
  private report(error:unknown,retry:(()=>Promise<void>)|null) {
    if(this.closed)return;
    this.onStatus("Проверьте связь");
    this.onError(error instanceof Error?error.message:String(error),retry);
  }
}

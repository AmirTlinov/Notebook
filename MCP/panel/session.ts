import { App } from "@modelcontextprotocol/ext-apps";
import type {PanelIdentity} from "../panel-bundle.mjs";
import type { SceneBounds } from "../src/spatial.js";
import { isPanelCheckpoint, type PanelCheckpoint, type PanelChanges, type PanelSnapshot, type PanelAddress,
  type PanelMutation, type PanelSelection, type PanelTarget, type PanelView } from "./model.js";

type ToolResult={structuredContent?:Record<string,unknown>;content?:{type:string;text?:string}[];isError?:boolean};
type OpenRequest={target?:PanelTarget;bounds?:SceneBounds};
export type RuntimeStatus={kind:"notebookRuntime";ready:boolean;pid:number;state:"opening"|"ready"|"workspaceRequired"|"failed";workspaceID?:string;socketKey?:string;message?:string};
export type WorkspaceRequest={action:"list"|"create"|"select"|"rename"|"retry";id?:string;name?:string};
export type WorkspaceResult={status:RuntimeStatus;workspaces:{id:string;name:string;local:boolean;remote:boolean;deleting:boolean}[];error?:string;catalogError?:string;snapshot?:PanelSnapshot};
export class PanelError extends Error {
  constructor(readonly code:string,message:string){super(message);}
}
function retryable(error:unknown):boolean {
  return !(error instanceof PanelError)||["ipc_timeout","ipc_unavailable","ipc_protocol","operation_failed","runtime_starting","runtime_startup_failed"].includes(error.code);
}
function body(result:ToolResult):Record<string,unknown> {
  const value=result.structuredContent??JSON.parse(result.content?.find(c=>c.type==="text")?.text??"{}");
  if(result.isError||value.status==="error")throw new PanelError(String(value.code??"panel_failed"),String(value.message??"Notebook не ответил."));
  return value;
}
function isSnapshot(value:Record<string,unknown>):value is Record<string,unknown>&PanelSnapshot {
  return isAddress(value)&&Array.isArray(value.elements);
}
function isAddress(value:Record<string,unknown>):value is Record<string,unknown>&PanelAddress {
  const target=value.target as Record<string,unknown>|undefined;
  const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  return typeof value.workspaceID==="string"&&uuid.test(value.workspaceID)
    &&typeof value.socketKey==="string"&&/^[a-f0-9]{24}$/.test(value.socketKey)&&!!target
    &&["board","page"].includes(String(target.kind))&&typeof target.id==="string"&&uuid.test(target.id);
}
function sameAddress(a:PanelAddress,b:PanelAddress):boolean {
  return a.workspaceID.toLowerCase()===b.workspaceID.toLowerCase()&&a.socketKey===b.socketKey
    &&a.target.kind===b.target.kind&&a.target.id.toLowerCase()===b.target.id.toLowerCase();
}

/** The bridge carries snapshots and completed gestures. Native Notebook owns all saved state. */
export class NotebookSession {
  readonly app:App;
  private readonly uiCohort:string;
  private cohortError:PanelError|undefined;
  private get cohortInvalid(){return this.cohortError!==undefined;}
  constructor(identity:PanelIdentity){
    this.uiCohort=identity.cohort;
    this.app=new App({name:"Notebook",version:identity.version},{availableDisplayModes:["fullscreen"]});
  }
  private revokeCohort(error:PanelError){
    if(this.cohortInvalid)return;
    this.cohortError=error;this.presented=false;++this.generation;
    this.cancelChanges();
    if(!this.cancelNavigation())void this.onCancelSnapshotPreparation();
    clearTimeout(this.openingTimer);this.openingTimer=undefined;
    clearTimeout(this.refreshTimer);this.refreshTimer=undefined;
    this.forcedRefreshQueued=false;this.viewportRefreshQueued=false;
    clearTimeout(this.contextTimer);this.contextTimer=undefined;this.contextDirty=false;
    this.onStateChange();this.report(error,null);
  }
  private async callServerTool(input:Parameters<App["callServerTool"]>[0],options?:Parameters<App["callServerTool"]>[1],retainDispatchedOutcome=false){
    if(this.cohortError)throw this.cohortError;
    const result=await this.app.callServerTool({...input,arguments:{...input.arguments,uiCohort:this.uiCohort}},options);
    // A retired view cannot consume late reads, but a dispatched write still
    // owns its authentic receipt or uncertain outcome.
    if(this.cohortError&&!retainDispatchedOutcome)throw this.cohortError;
    if(result.isError){
      try{body(result as ToolResult);}catch(error){
        if(error instanceof PanelError&&["panel_update_required","runtime_update_required"].includes(error.code))this.revokeCohort(error);
        throw error;
      }
    }
    return result;
  }
  snapshot:PanelSnapshot|undefined;
  private working=false;
  get busy(){return this.working;}
  set busy(value:boolean){
    if(this.working===value)return;
    this.working=value;
    if(!this.closed)this.onStateChange();
  }
  private synchronizing=false;
  private failedWrite=false;
  private contextSelection:PanelSelection|null=null;
  private contextTimer:ReturnType<typeof setTimeout>|undefined;
  private contextWriting=false;
  private contextDirty=false;
  get mutationReady(){return this.presented&&!this.suspended&&!this.busy&&!this.pending&&!this.synchronizing;}
  get hasPending(){return !!this.pending;}
  private contactActive=false;
  get suspended(){return this.contactActive;}
  set suspended(value:boolean){
    if(this.contactActive===value)return;
    this.contactActive=value;
    if(!value&&!this.closed)queueMicrotask(()=>{
      this.forcedRefreshQueued ||= this.changesDirty;this.drainRefresh();
    });
  }
  onSnapshot:(snapshot:PanelSnapshot)=>void=()=>{};
  onPrepareSnapshot:(snapshot:PanelSnapshot,view:PanelView)=>Promise<boolean>=async()=>true;
  onCancelSnapshotPreparation:()=>Promise<void>=async()=>{};
  onClose:()=>void|Promise<void>=()=>{};
  onStatus:(text:string)=>void=()=>{};
  onStateChange:()=>void=()=>{};
  onError:(message:string,retry:(()=>Promise<void>)|null)=>void=()=>{};
  onRuntime:(status:RuntimeStatus)=>void=()=>{};
  bounds:()=>SceneBounds|undefined=()=>undefined;
  view:(navigation:boolean,camera?:PanelView["camera"])=>PanelView=()=>({viewport:{x:834,y:1194},pixelScale:1});
  knownAssets:()=>string[]=()=>[];
  needsPresentation:()=>boolean=()=>true;
  private connected=false;
  private workspaceChanging=false;
  private changesDirty=false;
  private changesFailed=false;
  private changesWait:{controller:AbortController;address:PanelAddress;checkpoint:PanelCheckpoint}|undefined;
  private changesRetryTimer:ReturnType<typeof setTimeout>|undefined;
  private changesRetryDelay=250;
  private visibilityDocument:Document|undefined;
  private readonly visibilityChanged=()=>{
    if(this.hidden){this.cancelChanges();return;}
    this.forcedRefreshQueued ||= this.changesDirty;this.drainRefresh();this.watchChanges();
  };
  private reading=false;
  private readers:(()=>void)[]=[];
  private closed=false;
  private boundsDirty=true;
  private initialClaimed=false;
  private openingRequest:OpenRequest|undefined;
  private openingTimer:ReturnType<typeof setTimeout>|undefined;
  private presented=false;
  private presentedView:PanelView|undefined;
  private generation=0;
  private viewRevision=0;
  private navigation:{controller:AbortController;finished:Promise<void>}|undefined;
  private forcedRefreshQueued=false;
  private viewportRefreshQueued=false;
  private refreshTimer:ReturnType<typeof setTimeout>|undefined;
  get hasAppearance(){return this.presented;}
  private pending:{name:string;arguments:Record<string,unknown>;uncertain:boolean;resolve:()=>void;reject:(error:unknown)=>void}|undefined;

  async connect() {
    this.app.ontoolresult=result=>{
      // The host hands this view its immutable opening request. Later calls cannot
      // redirect a mounted view or an in-progress human gesture.
      if(this.closed||this.cohortInvalid||this.initialClaimed)return;
      try {
        const value=body(result as ToolResult);
        if(!value.open||typeof value.open!=="object"||Array.isArray(value.open))throw new Error("Notebook не передал запрос открытия панели.");
        if(value.uiCohort!==this.uiCohort){const error=new PanelError("panel_update_required",
          "Эта карточка относится к другой версии Notebook. Откройте новую панель через @Notebook в этом чате.");
          this.revokeCohort(error);throw error;}
        this.initialClaimed=true;this.openingRequest=structuredClone(value.open) as OpenRequest;
        void this.connectSurface();
      }
      catch(error){this.report(error,null);}
    };
    this.app.onteardown=async()=>{
      if(this.closed)return {};
      this.closed=true;this.presented=false;++this.generation;
      this.cancelNavigation();this.cancelChanges();
      this.visibilityDocument?.removeEventListener("visibilitychange",this.visibilityChanged);this.visibilityDocument=undefined;
      clearTimeout(this.refreshTimer);clearTimeout(this.contextTimer);clearTimeout(this.openingTimer);
      this.refreshTimer=undefined;this.contextTimer=undefined;this.openingTimer=undefined;this.openingRequest=undefined;
      this.pending?.reject(new Error("Панель закрыта."));this.pending=undefined;
      this.busy=false;this.releaseReaders();
      this.onStatus("Панель закрыта");await this.onClose();return {};
    };
    try{await this.app.connect();}catch(error){if(!this.closed)throw error;}
    if(this.closed)return;
    this.connected=true;
    if(typeof document!=="undefined"&&typeof document.addEventListener==="function"){
      this.visibilityDocument=document;document.addEventListener("visibilitychange",this.visibilityChanged);
    }
    this.watchChanges();
  }
  private get hidden(){return this.visibilityDocument?.hidden===true;}
  private cancelChanges(){
    this.changesWait?.controller.abort();
    clearTimeout(this.changesRetryTimer);this.changesRetryTimer=undefined;
  }
  /** Recovery has one bounded backoff, charged only to failed delivery or dirty pixels. */
  private retryChanges(){
    if(this.closed||this.cohortInvalid||this.hidden||this.changesRetryTimer!==undefined||!this.presented||!this.snapshot?.checkpoint)return;
    const address=this.address(),epoch=this.snapshot.checkpoint.epoch;
    this.changesRetryTimer=setTimeout(()=>{
      this.changesRetryTimer=undefined;
      if(this.closed||this.hidden||!sameAddress(address,this.address())||this.snapshot?.checkpoint?.epoch!==epoch)return;
      if(this.changesDirty){this.forcedRefreshQueued=true;this.drainRefresh();}
      else this.watchChanges();
    },this.changesRetryDelay);
    this.changesRetryDelay=Math.min(4000,this.changesRetryDelay*2);
  }
  private watchChanges(){
    if(!this.connected||this.closed||this.cohortInvalid||this.hidden||!this.presented||this.changesDirty
      ||this.changesWait||this.changesRetryTimer!==undefined||this.workspaceChanging||this.navigation||!this.snapshot?.checkpoint)return;
    const waiting={controller:new AbortController(),address:this.address(),checkpoint:{...this.snapshot.checkpoint}};
    this.changesWait=waiting;void this.readChanges(waiting);
  }
  private async readChanges(waiting:NonNullable<NotebookSession["changesWait"]>){
    const current=()=>!this.closed&&!this.hidden&&!waiting.controller.signal.aborted&&this.changesWait===waiting
      &&sameAddress(waiting.address,this.address());
    try{
      const value=body(await this.callServerTool({name:"notebook_panel_changes",
        arguments:{...waiting.address,checkpoint:waiting.checkpoint}},
      {signal:waiting.controller.signal,timeout:35_000}) as ToolResult);
      if(!current())return;
      if(!isAddress(value)||!sameAddress(waiting.address,value)||!isPanelCheckpoint(value.checkpoint)
        ||typeof value.changed!=="boolean"||(value.reset!==undefined&&typeof value.reset!=="boolean")){
        throw new Error("Notebook вернул неполное наблюдение или другую поверхность.");
      }
      const reply=value as PanelChanges;
      const sameEpoch=reply.checkpoint.epoch.toLowerCase()===waiting.checkpoint.epoch.toLowerCase();
      if(!reply.reset&&(!sameEpoch||BigInt(reply.checkpoint.readCursor)<BigInt(waiting.checkpoint.readCursor)
        ||BigInt(reply.checkpoint.changeCursor)<BigInt(waiting.checkpoint.changeCursor))){
        throw new Error("Наблюдение Notebook требует восстановления после смены владельца.");
      }
      if(!reply.changed&&!reply.reset&&reply.checkpoint.id.toLowerCase()!==waiting.checkpoint.id.toLowerCase()){
        throw new Error("Notebook подтвердил другой снимок поверхности.");
      }
      this.changesWait=undefined;
      const recovered=this.changesFailed;this.changesFailed=false;
      if(reply.changed||reply.reset){
        this.changesDirty=true;this.forcedRefreshQueued=true;this.drainRefresh();
      }else{
        this.changesRetryDelay=250;
        if(recovered&&!this.busy&&!this.reading&&!this.suspended&&!this.pending&&!this.synchronizing&&!this.failedWrite){
          this.onError("",null);this.onStatus("Подключено");
        }
        this.snapshot={...this.snapshot!,checkpoint:reply.checkpoint};this.watchChanges();
      }
    }catch(error){
      if(current()){
        this.changesWait=undefined;
        this.changesFailed=true;
        if(!this.pending&&!this.failedWrite&&!this.busy)this.report(error,this.cohortInvalid?null:async()=>{await this.refresh(true);});
        this.retryChanges();
      }
    }finally{
      // Revoked observations retain this one browser slot until their request
      // settles. A new address never stacks waits behind cancellation.
      if(this.changesWait===waiting){
        this.changesWait=undefined;if(waiting.controller.signal.aborted)this.watchChanges();
      }
    }
  }
  private async connectSurface(){
    if(this.closed||this.cohortInvalid||this.busy||!this.openingRequest)return;
    clearTimeout(this.openingTimer);this.openingTimer=undefined;
    const request=this.openingRequest;
    this.busy=true;this.onError("",null);this.onStatus("Открываем Notebook…");
    let again=false,runtime:RuntimeStatus|undefined;
    try{
      const value=body(await this.callServerTool({name:"notebook_panel_connect",arguments:request}) as ToolResult);
      if(this.closed||this.openingRequest!==request)return;
      if(isSnapshot(value)){
        this.openingRequest=undefined;this.snapshot=value;this.onStatus("Подготовка поверхности…");
      }else if(value.runtime){
        runtime=value.runtime as RuntimeStatus;
        // An admitted process can still be opening its workspace. Retry this
        // same read, preserving target/bounds without selecting another focus.
        if(runtime.state==="opening"){again=true;this.onStatus(runtime.message??"Открываем пространство…");}
      }else throw new Error("Notebook вернул неполный результат подключения.");
    }catch(error){
      if(this.closed)return;
      if(error instanceof PanelError&&error.code==="runtime_starting")again=true;
      else this.report(error,retryable(error)?()=>this.connectSurface():null);
    }finally{
      this.busy=false;
      if(!this.closed){
        if(again&&this.openingRequest===request)this.openingTimer=setTimeout(()=>{void this.connectSurface();},250);
        else if(runtime)this.onRuntime(runtime);
        else if(this.snapshot)void this.refresh(true);
      }
    }
  }
  address():PanelAddress {
    if(!this.snapshot)throw new Error("Notebook ещё подключается.");
    const {workspaceID,target,socketKey}=this.snapshot;return {workspaceID,target,socketKey};
  }
  async workspace(request:WorkspaceRequest):Promise<WorkspaceResult|undefined>{
    if(this.closed||this.cohortInvalid||this.busy||(this.pending&&request.action!=="list"&&request.action!=="retry"))return;
    this.workspaceChanging=request.action==="select"||request.action==="create";
    if(this.workspaceChanging)this.cancelChanges();
    this.busy=true;this.onStatus("Открытие пространства…");
    const recovering=request.action==="retry"&&this.snapshot!==undefined;
    const command={...(recovering?{...request,id:this.snapshot!.workspaceID}:request),
      ...(!recovering&&this.openingRequest?{open:this.openingRequest}:{})};
    let repaired=false;
    try{
      const value=body(await this.callServerTool({name:"notebook_panel_workspace",arguments:command}) as ToolResult) as WorkspaceResult;
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
          this.cancelChanges();this.changesDirty=false;this.changesFailed=false;this.changesRetryDelay=250;
          this.openingRequest=undefined;clearTimeout(this.openingTimer);this.openingTimer=undefined;
          ++this.generation;this.cancelNavigation();
          this.initialClaimed=true;this.presented=false;this.snapshot=value.snapshot;
          this.presentedView=undefined;this.boundsDirty=true;this.failedWrite=false;
          this.contextSelection=null;this.contextDirty=false;
          clearTimeout(this.contextTimer);this.contextTimer=undefined;
        }
      }
      return value;
    }finally{
      this.workspaceChanging=false;
      this.busy=false;
      if(!this.closed){
        if(repaired&&this.pending)void this.sendPending();
        else if(this.snapshot&&(!this.presented||repaired))void this.refresh(true);
        else this.onStatus(this.presented?"Подключено":"Выберите пространство");
        this.drainRefresh();this.watchChanges();
      }
    }
  }
  viewportChanged(){
    if(this.closed||this.cohortInvalid)return;
    this.boundsDirty=this.needsPresentation();++this.viewRevision;this.queueContext();
    if(this.boundsDirty){if(!this.viewportRefreshQueued)this.queueRefresh();}
    else {clearTimeout(this.refreshTimer);this.refreshTimer=undefined;this.viewportRefreshQueued=false;}
  }
  /** A measured view intent owns the currently installed surface immediately. */
  beginCameraInteraction():Promise<void>|undefined {
    if(this.closed)return;
    ++this.viewRevision;
    return this.cancelNavigation();
  }
  private cancelNavigation():Promise<void>|undefined {
    const navigation=this.navigation;if(!navigation)return;
    this.navigation=undefined;++this.generation;
    navigation.controller.abort();
    void this.onCancelSnapshotPreparation();
    return navigation.finished;
  }
  private queueRefresh(){
    if(this.closed||this.cohortInvalid||this.refreshTimer!==undefined)return;
    this.refreshTimer=setTimeout(()=>{this.refreshTimer=undefined;this.viewportRefreshQueued=true;this.drainRefresh();},80);
  }
  private drainRefresh(){
    if(this.closed||this.cohortInvalid||this.hidden)return;
    if(!this.boundsDirty){clearTimeout(this.refreshTimer);this.refreshTimer=undefined;this.viewportRefreshQueued=false;}
    if(this.reading||this.suspended||this.busy||this.pending)return;
    if(this.changesDirty&&this.changesRetryTimer!==undefined&&!this.viewportRefreshQueued)return;
    if(this.forcedRefreshQueued||this.viewportRefreshQueued)void this.refresh(this.forcedRefreshQueued);
  }
  async openSurface(target:PanelTarget,camera?:PanelView["camera"]){
    if(this.busy||this.pending||this.closed||this.cohortInvalid)return false;
    this.cancelChanges();
    let finish!:()=>void;
    const navigation={controller:new AbortController(),finished:new Promise<void>(resolve=>{finish=resolve;})};
    this.navigation=navigation;
    const generation=++this.generation;
    const current=()=>!this.closed&&this.navigation===navigation&&generation===this.generation;
    const priorPreparation=this.onCancelSnapshotPreparation();
    this.busy=true;this.failedWrite=false;this.onError("",null);this.onStatus("Открытие…");
    try {
      const request={...this.address(),target,appearance:this.view(true,camera),knownAssets:this.knownAssets()};
      const result=await this.callServerTool({name:"notebook_panel_presentation",arguments:request},
        {signal:navigation.controller.signal}) as ToolResult;
      if(!current())return false;
      const value=body(result);
      if(!isSnapshot(value)||!sameAddress(request,value))throw new Error("Notebook вернул другую поверхность.");
      this.requirePresentationCheckpoint(value);
      await priorPreparation;
      if(!current()||!(await this.onPrepareSnapshot(value,request.appearance))||!current())return false;
      if(!this.accept(value,request.appearance))return false;
      // Resize keeps this destination. World pixels install at its current
      // viewport; only uncovered demand asks for a coalesced projection read.
      this.boundsDirty=this.needsPresentation();this.viewportRefreshQueued=this.boundsDirty;
      clearTimeout(this.refreshTimer);this.refreshTimer=undefined;return true;
    }catch(error){if(current())this.report(error,null);return false;}
    finally{
      await priorPreparation;
      const revoked=!current();
      if(this.navigation===navigation)this.navigation=undefined;
      this.busy=false;finish();
      if(revoked&&!this.closed&&this.presented)this.onStatus("Подключено");
      this.drainRefresh();
      if(this.changesDirty)this.retryChanges();
      this.watchChanges();
    }
  }
  async requestFit():Promise<SceneBounds|undefined>{
    if(this.suspended||this.closed||!this.presented)return;
    const withdrawn=this.beginCameraInteraction();
    const generation=this.generation,revision=this.viewRevision;
    await withdrawn;
    if(!this.mutationReady||this.closed||generation!==this.generation||revision!==this.viewRevision)return;
    while(this.reading&&!this.closed)await new Promise<void>(resolve=>this.readers.push(resolve));
    if(this.closed||generation!==this.generation||revision!==this.viewRevision)return;
    const snapshot=await this.refresh(true,true);
    return generation===this.generation&&revision===this.viewRevision?snapshot?.fitBounds:undefined;
  }
  async refresh(force=false,includeFitBounds=false):Promise<PanelSnapshot|undefined> {
    if(this.closed||this.cohortInvalid||!this.snapshot)return;
    if(this.reading||this.suspended||this.busy||this.pending){this.forcedRefreshQueued ||= force;return;}
    clearTimeout(this.refreshTimer);this.refreshTimer=undefined;
    force ||= this.forcedRefreshQueued||this.changesDirty;
    this.reading=true;this.forcedRefreshQueued=false;this.viewportRefreshQueued=false;
    const generation=this.generation,viewRevision=this.viewRevision;
    const view=!force&&!includeFitBounds&&!this.boundsDirty&&this.presentedView?this.presentedView:this.view(false);
    const request={...this.address(),appearance:view,knownAssets:this.knownAssets(),...(includeFitBounds?{includeFitBounds:true}:{}),...(!force&&!this.boundsDirty&&this.presented?{
      knownCursor:this.snapshot.cursor,knownRequestID:this.snapshot.appearance?.requestID}: {})};
    try {
      if(force||this.boundsDirty||!this.presented)this.onStatus("Подготовка поверхности…");
      const value=body(await this.callServerTool({name:"notebook_panel_presentation",arguments:request}) as ToolResult);
      if(this.stale(request,generation))return;
      if(!this.presented&&viewRevision!==this.viewRevision)return;
      if(value.unchanged){
        if(typeof value.workspaceID!=="string"||!value.target
          ||!sameAddress(request,{workspaceID:value.workspaceID,target:value.target as PanelTarget,socketKey:request.socketKey}))throw new Error("Notebook вернул другую поверхность.");
        if(this.changesDirty){this.forcedRefreshQueued=true;return;}
        this.synchronizing=false;if(!this.failedWrite)this.onError("",null);this.onStatus("Подключено");return this.snapshot;
      }
      if(!isSnapshot(value)||!sameAddress(request,value))throw new Error("Notebook вернул другую поверхность.");
      this.requirePresentationCheckpoint(value);
      const prepared=await this.onPrepareSnapshot(value,request.appearance);
      if(this.stale(request,generation))return;
      if(!prepared){
        this.boundsDirty=this.needsPresentation();
        if(this.presented&&!this.boundsDirty&&!this.synchronizing&&!this.failedWrite&&!this.changesDirty){
          this.onError("",null);this.onStatus("Подключено");
        }
        if(this.changesDirty)this.retryChanges();
        return;
      }
      if(!this.accept(value,request.appearance)){
        if(this.changesDirty)this.retryChanges();return;
      }
      if(!this.failedWrite)this.onError("",null);
      // Camera motion does not invalidate world-placed pixels. Keep the current
      // camera and coalesce the latest projection after accepting useful coverage.
      this.boundsDirty=this.needsPresentation();
      return this.snapshot;
    }catch(error){if(!this.stale(request,generation)){
      this.report(error,async()=>{await this.refresh(true);});
      if(this.changesDirty)this.retryChanges();
    }}
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
        this.watchChanges();
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
    if(this.cohortError)throw this.cohortError;
    if(!this.mutationReady)throw new Error("Дождитесь сохранения текущей правки.");
    ++this.generation;this.failedWrite=false;this.onError("",null);
    const completion=new Promise<void>((resolve,reject)=>{this.pending={name,arguments:args,uncertain:false,resolve,reject};});
    void this.sendPending();return completion;
  }
  private async sendPending() {
    if(this.closed||!this.pending||this.busy)return;
    this.busy=true;this.onStatus("Сохранение…");
    const pending=this.pending;
    try {
      const result=await this.callServerTool({name:pending.name,arguments:pending.arguments},undefined,true) as ToolResult;
      if(this.closed||this.pending!==pending)return;
      body(result);
      this.pending=undefined;this.synchronizing=!this.cohortInvalid;
      if(!this.cohortInvalid)this.onError("",null);
      pending.resolve();
    }catch(error) {
      if(this.closed||this.pending!==pending)return;
      const canRetry=retryable(error);
      if(canRetry&&(!(error instanceof PanelError)||!["runtime_starting","runtime_startup_failed"].includes(error.code)))pending.uncertain=true;
      // Refusing a later send cannot settle an earlier unknown write.
      if(!canRetry&&!pending.uncertain){this.pending=undefined;this.failedWrite=true;pending.reject(error);}
      this.report(error,canRetry?()=>this.retryPending():null);
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
    this.requirePresentationCheckpoint(value);
    if(this.snapshot&&sameAddress(this.snapshot,value)
      &&this.snapshot.checkpoint?.epoch.toLowerCase()===value.checkpoint!.epoch.toLowerCase()
      &&/^\d+$/.test(value.cursor)&&/^\d+$/.test(this.snapshot.cursor)&&BigInt(value.cursor)<BigInt(this.snapshot.cursor))return false;
    if(value.appearance?.status!=="ready")throw new Error("Notebook ещё готовит изображение поверхности.");
    this.cancelChanges();this.changesDirty=false;this.changesFailed=false;this.changesRetryDelay=250;
    this.snapshot=value;this.presentedView={...view,camera:value.appearance.camera};this.presented=true;this.synchronizing=false;this.onSnapshot(value);this.onStatus("Подключено");
    this.watchChanges();
    return true;
  }
  private requirePresentationCheckpoint(value:PanelSnapshot){
    if(!isPanelCheckpoint(value.checkpoint))throw new Error("Notebook не передал checkpoint готовой поверхности.");
  }
  private report(error:unknown,retry:(()=>Promise<void>)|null) {
    if(this.closed)return;
    this.onStatus("Проверьте связь");
    let message=error instanceof Error?error.message:String(error);
    if(this.cohortError){
      message=error===this.cohortError?this.cohortError.message:`${this.cohortError.message}\n${message}`;
      retry=null;
    }
    this.onError(message,retry);
  }
}

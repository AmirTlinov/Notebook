import type { NotebookSession, RuntimeStatus, WorkspaceRequest, WorkspaceResult } from "./session.js";

/** Workspace choices belong to the existing runtime library. This adapter owns
 * only the dialog's focus, pending request and system text input. */
export class WorkspacePicker {
  private readonly dialog=document.createElement("dialog");
  private readonly list=document.createElement("div");
  private readonly message=document.createElement("p");
  private readonly name=document.createElement("input");
  private readonly form=document.createElement("form");
  private readonly retry=document.createElement("button");
  private readonly close=document.createElement("button");
  private busy=false;
  private closed=false;
  private pendingCreation:WorkspaceRequest|undefined;
  constructor(private readonly session:NotebookSession,signal:AbortSignal){
    this.dialog.className="workspaces";
    this.dialog.setAttribute("aria-label","Пространства Notebook");
    const title=document.createElement("h2");title.textContent="Пространства";
    this.message.setAttribute("role","status");
    this.name.name="name";this.name.required=true;this.name.maxLength=200;
    this.name.placeholder="Название нового пространства";
    this.name.setAttribute("aria-label","Название нового пространства");
    const create=document.createElement("button");create.type="submit";create.textContent="Создать";
    create.dataset.changesWorkspace="true";this.name.dataset.changesWorkspace="true";
    this.form.append(this.name,create);
    this.close.type="button";this.close.textContent="Вернуться к доске";
    this.close.addEventListener("click",()=>this.dialog.close(),{signal});
    this.retry.type="button";this.retry.textContent="Повторить открытие";
    this.retry.addEventListener("click",()=>{void this.request({action:"retry"});},{signal});
    this.form.addEventListener("submit",event=>{
      event.preventDefault();const name=this.name.value.trim();
      if(name){
        if(this.pendingCreation?.name!==name)this.pendingCreation={action:"create",id:crypto.randomUUID(),name};
        void this.request(this.pendingCreation);
      }
    },{signal});
    this.dialog.addEventListener("cancel",event=>{
      if(!this.session.hasAppearance||this.busy)event.preventDefault();
    },{signal});
    this.dialog.append(title,this.message,this.list,this.form,this.retry,this.close);
    document.body.append(this.dialog);
    signal.addEventListener("abort",()=>{this.closed=true;this.dialog.remove();},{once:true});
  }
  async open(){
    if(this.closed||this.busy)return;
    if(!this.dialog.open)this.dialog.showModal();
    await this.request({action:"list"});
  }
  start(status:RuntimeStatus){
    if(this.closed)return;
    if(!this.dialog.open)this.dialog.showModal();
    this.message.textContent=status.message??"Открываем Notebook…";
    this.form.hidden=status.state==="failed"||status.state==="opening";
    void this.request({action:status.state==="opening"?"retry":"list"});
  }
  private setBusy(value:boolean){
    this.busy=value;
    this.dialog.querySelectorAll<HTMLButtonElement|HTMLInputElement>("button,input").forEach(element=>element.disabled=value||element.dataset.retired==="true"||(this.session.hasPending&&element.dataset.changesWorkspace==="true"));
    this.close.hidden=!this.session.hasAppearance;
  }
  private async request(request:WorkspaceRequest){
    if(this.closed||this.busy)return;
    this.setBusy(true);
    try{
      const result=await this.session.workspace(request);
      if(this.closed||!result)return;
      this.render(result);
      if(result.snapshot&&!result.error){this.pendingCreation=undefined;this.name.value="";this.dialog.close();}
    }catch(error){if(!this.closed)this.message.textContent=error instanceof Error?error.message:String(error);}
    finally{if(!this.closed)this.setBusy(false);}
  }
  private render(result:WorkspaceResult){
    this.list.replaceChildren();
    this.message.textContent=result.error??result.catalogError??(result.status.state==="ready"?"":result.status.message??"Выберите или создайте пространство.");
    this.retry.hidden=!this.session.hasPending&&(result.status.state==="ready"||result.status.state==="workspaceRequired");
    this.form.hidden=result.status.state==="failed"||result.status.state==="opening";
    for(const workspace of result.workspaces){
      const button=document.createElement("button");button.type="button";
      button.dataset.changesWorkspace="true";
      button.textContent=workspace.name;button.disabled=workspace.deleting;button.dataset.retired=String(workspace.deleting);
      if(workspace.id.toLowerCase()===result.status.workspaceID?.toLowerCase())button.setAttribute("aria-current","true");
      button.addEventListener("click",()=>{void this.request({action:"select",id:workspace.id});});
      this.list.append(button);
    }
  }
}

import Foundation
import CSQLite
@testable import NotebookCore

final class Count { var vm = 0 }
func timed<T>(_ label: String, store: NotebookStore, read: Bool = true, _ body: @escaping () throws -> T) throws -> T {
  let c=Count(), start=ContinuousClock.now
  let run: () throws -> T = {
    sqlite3_progress_handler(store.currentSQL!.handle,1,{ raw in
      Unmanaged<Count>.fromOpaque(raw!).takeUnretainedValue().vm += 1; return 0
    },Unmanaged.passUnretained(c).toOpaque())
    defer { sqlite3_progress_handler(store.currentSQL!.handle,0,nil,nil) }
    return try body()
  }
  let result = try read ? store.readTransaction { _ in try run() } : store.commandTransaction { try run() }
  print("\(label) vm=\(c.vm) elapsed=\(start.duration(to:.now))")
  return result
}
let base=FileManager.default.temporaryDirectory.appendingPathComponent("notebook-audit-core-"+UUID().uuidString)
try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
defer { try? FileManager.default.removeItem(at:base) }
func fresh(_ name:String) throws -> (NotebookStore,UUID,NotebookWorkspaceHeader) {
  let s=NotebookStore(root:base.appendingPathComponent(name)), a=UUID()
  return try (s,a,s.initializeWorkspace(actor:a,pageSize:.init(width:400,height:600)))
}

// Reproduce the exact arrival acknowledgement query after one offline batch.
do {
 let (s,a,h)=try fresh("arrival"), t=CollaborationTarget(kind:.board,id:h.rootBoardID)
 let first=try s.applyCollaborationAction(.init(summary:"First offline edit",expected:[.init(target:t,revision:s.targetContentRevision(target:t))],operations:[
  .init(kind:.insertElement,target:t,id:"control",values:["kind":.string("web"),"source":.string("<button>Value</button>"),"state":.number(0),"frame":try .encode(PageRect(x:0,y:0,width:200,height:80)),"worldOrigin":try .encode(WorldPoint.zero)])]),actor:a)
 for i in 0..<70 {
  _=try s.applyCollaborationAction(.init(summary:"Offline edit \(i)",expected:[.init(target:t,revision:s.targetContentRevision(target:t))],operations:[.init(kind:.setElementState,target:t,id:"control",values:["state":.number(Double(i+1))])]),actor:a)
 }
 let device=UUID(); try s.acknowledgeReceivedActions(deviceID:device)
 let after1=try s.deviceActionReceipts()
 try s.acknowledgeReceivedActions(deviceID:device)
 let after2=try s.deviceActionReceipts()
 print("ACK_WINDOW allActions=\(try s.collaborationActions().count) acknowledgedFirst=\(after1.count) acknowledgedSecond=\(after2.count) firstStillMissing=\(try s.deviceActionReceipts(actionIDs:[first.id]).isEmpty)")
}

// Document runtime identity controls include only the content field.
do {
 let (s,a,h)=try fresh("document")
 var index=try s.loadIndex(), tree=try s.loadBoard(items:index.items)
 let item=index.createDocument(title:"Runtime",actor:a)!
 _=tree.addItem(item.id,to:h.rootBoardID,near:.zero,actor:a)
 let old=DocumentBlock.interactive(id:"p",html:"<output></output>",javaScript:"old",initialState:.number(0))
 var doc=DocumentDocument(id:item.id,actor:a,blocks:[old])
 try s.saveDocumentWorkspaceBundle(index:index,document:doc,state:.init(id:item.id,actor:a),board:tree)
 doc=try s.loadDocument(item.id)
 let before=try s.readDocumentBlock(documentID:item.id,blockID:"p")!
 let new=DocumentBlock.interactive(id:"p",html:"<output></output>",javaScript:"new",initialState:.number(0))
 _=doc.replaceContent(blocks:[new],actor:a)
 _=try s.saveMergedDocument(doc)
 let changed=try s.readDocumentBlock(documentID:item.id,blockID:"p")!
 let accepted=try s.checkpointDocumentState(documentID:item.id,blockID:"p",value:.number(777),sourceVersion:before.sourceVersion,stateVersion:before.stateVersion,actor:a)
 print("DOCUMENT_SOURCE_GUARD blockChanged=\(changed.block != before.block) versionUnchanged=\(changed.sourceVersion == before.sourceVersion) staleCheckpointAccepted=\(accepted != nil) currentState=\(try s.readDocumentBlock(documentID:item.id,blockID:"p")!.state)")
}

// Whole-surface read versus its metadata-only control. All ink is off viewport.
do {
 let (s,a,h)=try fresh("ink")
 let surface=SurfaceID.board(h.rootBoardID)
 let empty=try timed("SPATIAL_EMPTY",store:s) { try s.readSpatialInk(surfaces:[surface]) }
 let actions=(0..<2000).map { i in SpatialInkAction(tool:.pen,spans:[.init(surface:surface,samples:[.init(point:.init(x:0,y:0),worldPoint:.init(x:100_000+Double(i),y:100_000),timeOffset:0,width:2,opacity:1,force:1,azimuth:0,altitude:1)])],stamp:.init(counter:UInt64(i+1),actor:a)) }
 try s.saveSpatialInk(.init(actions:actions,stamp:.init(counter:2000,actor:a)))
 let loaded=try timed("SPATIAL_2000_OFFSCREEN",store:s) { try s.readSpatialInk(surfaces:[surface]) }
 _=try timed("SPATIAL_METADATA_ONLY",store:s) { try s.readSpatialInk(surfaces:[]) }
 let second=try timed("SPATIAL_2000_REPEAT_READ",store:s) { try s.readSpatialInk(surfaces:[surface]) }
 print("SPATIAL_READ empty=\(empty.actions.count) first=\(loaded.actions.count) second=\(second.actions.count)")
}

// Native page state follows savePage; checkpoint already has an addressed alternative.
do {
 let (s,a,_)=try fresh("page")
 var page=try s.loadPage(s.loadIndex().selectedPageID!)
 let web=AgentElement(id:"p",kind:.web,frame:.init(x:0,y:0,width:200,height:80),source:"<button>+</button>",html:"<button>+</button>",state:.number(0))
 _=page.replaceElements([web],actor:a)
 var drawing=PageInkDrawing()
 for i in 0..<400 {
  let samples: [SpatialInkSample]=(0..<64).map { j in
   let x = Double(j) + sin(Double(i+j))
   let y = Double(i % 400) + cos(Double(j))
   let width = 2.0 + sin(Double(j)) * 0.1
   return SpatialInkSample(point: .init(x:x,y:y), timeOffset:Double(j)*0.01, width:width, opacity:1, force:1, azimuth:0, altitude:1)
  }
  drawing=try drawing.appending(.init(tool:.pen,samples:samples))
 }
 _=page.replaceDrawing(try drawing.dataRepresentation(),actor:a)
 _=try s.savePage(page)
 page=try s.loadPage(page.id)
 let id=page.id
 _=try timed("PAGE_400x64_READ",store:s) { try s.loadPage(id) }
 let uiStart=ContinuousClock.now
 _=page.replaceElements([page.elements[0].updating(state:.number(1))],actor:a)
 print("PAGE_STATE_MAIN_MODEL elapsed=\(uiStart.duration(to:.now))")
 page=try timed("PAGE_STATE_FULL_SAVE",store:s,read:false) { try s.savePage(page) }
 let rendered=page.elements[0], basis=page.programStateBasis("p")!
 _=try timed("PAGE_STATE_ADDRESSED_CHECKPOINT_CONTROL",store:s,read:false) { try s.checkpointProgramState(target:.init(kind:.page,id:id),rendered:rendered,state:.number(2),basis:basis,actor:a) }
 print("PAGE_400x64 bytes=\(page.drawingData.count)")
}

// Already-admitted prefix versus incoming validation of a one-page append.
do {
 let (s,_,_)=try fresh("page-order")
 let ids=(0..<100_000).map { _ in UUID() }
 let root=try s.commandTransaction { try NotebookPageOrderVector.build(ids,write:{ try s.writePageOrderNode($0) }) }
 let next=try s.commandTransaction { try NotebookPageOrderVector.append(to:root,pageID:UUID(),read:{try s.readPageOrderNode($0)},write:{try s.writePageOrderNode($0)}) }
 try timed("INCOMING_PAGE_ORDER_100001_FULL_VALIDATION",store:s) { try s.validateIncomingPageOrderValues([next]) }
 var changed=0
 try timed("PAGE_ORDER_100001_CHANGED_PREFIX_CONTROL",store:s) { try NotebookPageOrderVector.visitChangedPages(from:root,to:next,read:{try s.readPageOrderNode($0)},visit:{ _,_ in changed += 1 }) }
 print("PAGE_ORDER changed=\(changed)")
}

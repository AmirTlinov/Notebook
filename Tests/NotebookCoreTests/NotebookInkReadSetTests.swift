import Foundation
import Testing
@testable import NotebookCore

private func readSetStroke(_ sequence:UInt64,_ y:Double,tool:SpatialInkTool = .pen)->PageInkAction {
  .init(tool:tool,samples:[20.0,100].map {
    .init(point:.init(x:$0,y:y),timeOffset:0,width:8,opacity:1,force:1,azimuth:0,altitude:1)
  },sequence:sequence)
}

@Test func livePageAdmissionRequiresPreparedRootAndSharesAcceptedSource() throws {
  let actor=UUID(),first=readSetStroke(1,40)
  var page=PageDocument(size:.init(width:834,height:1194),actor:actor,
    drawingData:try PageInkDrawing(actions:[first]).dataRepresentation())
  #expect(page.preparedInkDrawing == nil)
  #expect(throws:CollaborationError.self) {
    try page.prepareLiveInkChange(.append(readSetStroke(2,80)),stamp:.init(counter:1,actor:actor))
  }
  #expect(page.preparedInkDrawing == nil,"First lift must not perform a deferred decode")
  try page.prepareInkForPresentation()
  let change=try page.prepareLiveInkChange(.append(readSetStroke(2,80)),stamp:.init(counter:1,actor:actor))
  let old=page.inkSource
  let published=page.publishInkChange(change)
  #expect(published)
  #expect(page.inkSource.identity == change.inkSource.identity)
  #expect(old.preparedDrawing?.actionCount == 1)
  #expect(page.preparedInkDrawing?.actionCount == 2)
  #expect(try PageInkDrawing.decode(change.data) == change.drawing)
}

@Test func contactReadSetIgnoresUnrelatedAppendButTracksLaterCutsAndVisibility() throws {
  let actor=UUID(),first=readSetStroke(1,40)
  var page=PageDocument(size:.init(width:834,height:1194),actor:actor,
    drawingData:try PageInkDrawing(actions:[first]).dataRepresentation())
  try page.prepareInkForPresentation()
  let set=try #require(page.inkSource.readSet(for:first.id,on:.page(page.id)))
  func append(_ action:PageInkAction) throws {
    let change=try page.prepareLiveInkChange(.append(action),stamp:.init(counter:page.drawingStamp.counter+1,actor:actor))
    let published=page.publishInkChange(change)
    #expect(published)
  }
  try append(readSetStroke(2,40)) // A new pen may even cross the selected one.
  try append(readSetStroke(3,400,tool:.eraser))
  #expect(set.matches(page.inkSource))
  let cut=readSetStroke(4,40,tool:.eraser)
  try append(cut)
  #expect(!set.matches(page.inkSource))
  let cutSet=try #require(page.inkSource.readSet(for:first.id,on:.page(page.id)))
  let undo=try page.prepareLiveInkChange(.setActive([cut.id],false),stamp:.init(counter:4,actor:actor))
  let publishedUndo=page.publishInkChange(undo)
  #expect(publishedUndo)
  #expect(!cutSet.matches(page.inkSource))
  #expect(set.matches(page.inkSource))
}

@Test func hundredThousandCutsHaveStreamingWriterProofAndDoNotBlockANewerPen() throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer {try? FileManager.default.removeItem(at:root)}
  let store=NotebookStore(root:root),actor=UUID()
  let (_,pages)=try store.loadOrCreate(actor:actor,pageSize:.init(width:834,height:1194))
  _=try store.loadOrCreateSpatialInk(actor:actor)
  var page=try #require(pages.values.first)
  let first=readSetStroke(1,40),latest=readSetStroke(100_002,40)
  let cuts=(2...100_001).map {readSetStroke(UInt64($0),40,tool:.eraser)}
  let replaced=page.replaceDrawing(try PageInkDrawing(actions:[first]+cuts+[latest]).dataRepresentation(),actor:actor)
  #expect(replaced)
  page=try store.savePage(page)
  try page.prepareInkForPresentation()
  let set=try #require(page.inkSource.readSet(for:first.id,on:.page(page.id)))
  let top=try #require(page.inkSource.readSet(for:latest.id,on:.page(page.id)))
  #expect(set.erasers.count == 100_000)
  #expect(top.erasers.isEmpty)
  let target=CollaborationTarget(kind:.page,id:page.id)
  try store.commandTransaction(readAllowance:NotebookStore.inkSelectionReadAllowance([set,top])) {
    try store.validateInkReadSets([set,top],target:target)
  }
  let frame=PageRect(x:0,y:0,width:140,height:100)
  let graphic=NotebookGraphic(shape:.freehand,sourceInkIDs:[latest.id],freehand:.init(layers:[
    .init(tool:.pen,color:.black,measured:.init(sourceID:latest.id,measurements:latest.samples,frame:frame))]))
  _=try store.applyNativeElementEdits([.init(kind:.convertInkToElement,target:target,id:"newest",values:[
    "kind":.string("graphic"),"source":.string(""),"frame":try .encode(frame),"graphic":try .encode(graphic)])],
    summary:"Select newest pen above old cuts",sources:[.init(target:target,id:"newest")],inkReadSets:[top],actor:actor)
}

@Test(arguments:[false,true],[2,257])
func nativeSelectionWriterChecksTheSameAddressedContact(onBoard:Bool,sampleCount:Int) throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer {try? FileManager.default.removeItem(at:root)}
  let store=NotebookStore(root:root),actor=UUID()
  let (workspace,pages)=try store.loadOrCreate(actor:actor,pageSize:.init(width:834,height:1194))
  _=try store.loadOrCreateSpatialInk(actor:actor)
  var page=try #require(pages.values.first)
  let target=CollaborationTarget(kind:onBoard ? .board:.page,id:onBoard ? workspace.rootBoardID:page.id)
  let surface=onBoard ? SurfaceID.board(target.id):.page(target.id)
  var journal=SpatialInkJournal(stamp:.init(counter:0,actor:actor))
  func append(_ action:PageInkAction) throws {
    if onBoard {
      let stamp=VersionStamp(counter:action.sequence,actor:actor)
      let samples=action.samples.map { sample in
        SpatialInkSample(point:sample.point,worldPoint:.init(x:sample.point.x,y:sample.point.y),
          timeOffset:sample.timeOffset,width:sample.width,opacity:sample.opacity,
          force:sample.force,azimuth:sample.azimuth,altitude:sample.altitude)
      }
      let spatial=SpatialInkAction(id:action.id,tool:action.tool,spans:[.init(surface:surface,samples:samples)],stamp:stamp)
      _=try store.commitSpatialInk(.append(spatial,journalStamp:stamp))
      journal=try store.readSpatialInk(surfaces:[surface])
    } else {
      try page.prepareInkForPresentation()
      let change=try page.prepareLiveInkChange(.append(action),stamp:.init(counter:action.sequence,actor:actor))
      _=try store.commitPageInk(pageID:page.id,command:.init(change))
      let published=page.publishInkChange(change)
      #expect(published)
    }
  }
  let first=PageInkAction(tool:.pen,samples:(0..<sampleCount).map { i in
    .init(point:.init(x:20+80*Double(i)/Double(sampleCount-1),y:40+sin(Double(i))*3),
      timeOffset:Double(i)/60,width:8+Double(i%7)/4,opacity:1,force:0.5,azimuth:0,altitude:1)
  },sequence:1)
  #expect((try first.samples.encodedRelations().count>1024) == (sampleCount>2))
  try append(first)
  try store.readTransaction { _ in
    let address=(onBoard ? "spatial-ink.json#/actions/@":pageFile(page.id)+"#/drawingData/actions/@")
      + first.id.uuidString.lowercased() + (onBoard ? "/spans":"/samples")
    let database=try #require(store.currentSQL)
    let bytes=try #require(database.rows("SELECT b.data FROM records r JOIN blobs b ON b.hash=r.hash WHERE r.address=?",[.text(address)]).first?[0].blob)
    let fragment=try database.decodeFragmentEnvelope(bytes)
    #expect(fragment.inkBodies == (sampleCount>2 ? [onBoard ? ["0","samples"]:[]]:[]),
      "The same native selection must validate inline NIM1 and external inkBody envelopes")
  }
  let readSet=try #require(onBoard ? journal.readSet(for:first.id,on:surface):page.inkSource.readSet(for:first.id,on:surface))
  try append(readSetStroke(2,300))
  try store.readTransaction {_ in try store.validateInkReadSets([readSet],target:target)}
  let frame=PageRect(x:0,y:0,width:140,height:100)
  let graphic=NotebookGraphic(shape:.freehand,sourceInkIDs:[first.id],freehand:.init(layers:[
    .init(tool:.pen,color:.black,measured:.init(sourceID:first.id,measurements:first.samples,frame:frame))]))
  var values:[String:JSONValue]=["kind":.string("graphic"),"source":.string(""),"frame":try .encode(frame),"graphic":try .encode(graphic)]
  if onBoard {values["worldOrigin"]=try .encode(WorldPoint.zero)}
  _=try store.applyNativeElementEdits([.init(kind:.convertInkToElement,target:target,id:"selected",values:values)],
    summary:"Move selected contact after unrelated append",sources:[.init(target:target,id:"selected")],inkReadSets:[readSet],actor:actor)
  try append(readSetStroke(3,40,tool:.eraser))
  #expect(throws:CollaborationError.self) {
    try store.readTransaction {_ in try store.validateInkReadSets([readSet],target:target)}
  }
}

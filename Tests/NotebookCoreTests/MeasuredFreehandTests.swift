import CoreGraphics
import Foundation
import Testing
@testable import NotebookCore

@Suite("Primary measured freehand")
struct MeasuredFreehandTests {
  private func source() throws -> InkSampleRelations {
    let points: [SpatialInkSample]=(0..<100).map { i in
      .init(point:.init(x:Double(i)/2,y:64+sin(Double(i)/8)*20),timeOffset:Double(i)/128,
        width:4,opacity:0.5,force:Double(i)/128,azimuth:0,altitude:1)
    }
    return try #require(InkSampleRelations(sourceID:UUID(),revision:UUID(),samples:points,header:.init(tool:.pen,color:.black))
      .settingExit(.init(x:InkDyadic(64)!,y:.zero,time:.one),revision:UUID()).repeated(10_000,revision:UUID()))
  }
  @Test func millionEventWholeSharesItsBodyAndQueriesOnlyLocalGeometry() throws {
    let source=try source(),frame=PageRect(x:-4,y:40,width:640_004,height:48)
    let ink=NotebookFreehand(layers:[.init(tool:.pen,color:.black,
      measured:.init(sourceID:source.sourceID,measurements:source.measurements,frame:frame))])
    #expect(ink.isValid)
    #expect(ink.layers[0].measured!.measurements.storage === source.storage)
    #expect(ink.geometry.preparedNodeCount == 0)
    #expect(ink.geometry.sourceNodeCount == 1_000_000)
    let q=ink.geometry.query(.init(x:320_004/frame.width,y:0,width:128/frame.width,height:1))
    #expect(q.indices.count < 10)
    #expect(q.indices.reduce(0) { $0+ink.geometry.prepared(at:$1).geometry.nodes.count } < 1000)
    let size=CGSize(width:frame.width,height:frame.height)
    #expect(ink.contains(.init(x:320_004,y:24),size:size,transform:nil))
    let graphic=NotebookGraphic(shape:.freehand,freehand:ink)
    let pageID=UUID(),graph=NotebookGraphicGraph([.init(id:"million",graphic:graphic,frame:frame,surface:.page(pageID),shown:true)])
    let started=ContinuousClock.now
    #expect(graph.visiblePageGraphics(pageID,in:.init(x:320_000,y:40,width:128,height:48)).layouts["million"] != nil)
    #expect(started.duration(to:.now) < .seconds(1),"Scene bounds must not expand the million-event whole")
    let turned=try graphic.applying(.object(["transform":try .encode(NotebookGraphicTransform(a:0,b:1,c:-1,d:0,tx:1,ty:0))]))
    #expect(turned.freehand?.geometry === ink.geometry)
    let bytes=try JSONEncoder().encode(turned),copy=try JSONDecoder().decode(NotebookGraphic.self,from:bytes)
    #expect(bytes.count < 20_000)
    #expect(copy == turned)
    let restored=try #require(copy.freehand?.layers[0].measured?.measurements)
    #expect(try restored.encodedRelations() == source.measurements.encodedRelations())
  }
  @Test(arguments:[false,true]) func exactBodySurvivesConversionOrPoseWriteReopenAndUndo(poseEdit: Bool) throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("measured-conversion-\(UUID())")
    defer { try? FileManager.default.removeItem(at:root) }
    let actor=UUID(),store=NotebookStore(root:root)
    let (_,pages)=try store.loadOrCreate(actor:actor,pageSize:.init(width:600,height:800))
    _=try store.loadOrCreateSpatialInk(actor:actor)
    var page=try #require(pages.values.first)
    let source=try source(),original=try PageInkDrawing(actions:[source.restoredAction()]).dataRepresentation()
    _=page.replaceDrawing(original,actor:actor);try store.savePage(page)
    let frame=PageRect(x:0,y:0,width:640_000,height:128),target=CollaborationTarget(kind:.page,id:page.id)
    let ink=NotebookFreehand(layers:[.init(tool:.pen,color:.black,
      measured:.init(sourceID:source.sourceID,measurements:source.measurements,frame:frame))])
    let graphic=NotebookGraphic(shape:.freehand,sourceInkIDs:[source.sourceID],freehand:ink)
    let converted=try store.applyNativeElementEdits([.init(kind:.convertInkToElement,target:target,id:"ink",values:[
      "kind":.string("graphic"),"source":.string(""),"frame":try .encode(PageRect(x:0,y:0,width:600,height:128)),"graphic":try .encode(graphic)])],
      summary:"Выбор измеренного целого",sources:[.init(target:target,id:"ink")],expectedInkRevision:page.drawingStamp.revision,actor:actor)
    let saved=try #require(try NotebookStore(root:root).readPageElement(pageID:page.id,elementID:"ink"))
    #expect(saved.graphic == graphic)
    let readStart=ContinuousClock.now,reopened=NotebookStore(root:root)
    let addressed=try reopened.readPageElementSnapshot(pageID:page.id,elementID:"ink")
    let projected=try reopened.loadPage(page.id).graphicReadProjection()
    #expect(readStart.duration(to:.now) < .seconds(1),"Appearance metadata must not expand a million-event contour")
    #expect(addressed?.appearance["state"] == .string("intact"))
    #expect(projected["elements"]?.array.first?["appearance"] == addressed?.appearance)
    #expect(try addressed?.element.graphic?.freehand?.layers[0].measured?.measurements.encodedRelations() == source.measurements.encodedRelations())
    if !poseEdit {
      let peer=NotebookStore(root:root.appendingPathComponent("peer"))
      try peer.prepareEmptyWorkspace(workspaceID:store.workspaceHeader().workspaceID)
      try receiveFixtureChanges(from:store,to:peer,peerID:actor)
      #expect(try peer.readPageElement(pageID:page.id,elementID:"ink")?.graphic == graphic)
      #expect(try peer.collaborationAction(converted.receipt.id).action == converted.receipt.action)
      _=try peer.undoCollaborationAction(converted.receipt.id,actor:UUID())
      #expect(try peer.loadPage(page.id).graphicPresentation.suppressedInkIDs.isEmpty)
      #expect(try peer.loadPage(page.id).drawingData == original)
      let undone=try store.undoCollaborationAction(converted.receipt.id,actor:actor)
      #expect(undone.undo?.preserved.isEmpty == true)
      #expect(try store.loadPage(page.id).graphicPresentation.suppressedInkIDs.isEmpty)
      #expect(try store.loadPage(page.id).drawingData == original)
      return
    }
    let pose=NotebookGraphicTransform(a:0,b:1,c:-1,d:0,tx:1,ty:0)
    let moved=try store.applyNativeElementEdits([.init(kind:.updateElement,target:target,id:"ink",values:[
      "graphic":.object(["transform":try .encode(pose)])])],summary:"Поворот целого",
      sources:[.init(target:target,id:"ink",page:saved)],actor:actor)
    let reloaded=try NotebookStore(root:root).loadPage(page.id)
    #expect(reloaded.elements.first?.graphic?.transform == pose)
    #expect(try reloaded.elements.first?.graphic?.freehand?.layers[0].measured?.measurements.encodedRelations() == source.measurements.encodedRelations())
    #expect(reloaded.drawingData == original)
    _=try store.undoCollaborationAction(moved.receipt.id,actor:actor)
    #expect(try store.loadPage(page.id).elements.first?.graphic == graphic)
    let undone=try NotebookStore(root:root).undoCollaborationAction(converted.receipt.id,actor:actor)
    #expect(undone.undo?.preserved.isEmpty == true)
    #expect(try store.loadPage(page.id).graphicPresentation.suppressedInkIDs.isEmpty)
    #expect(try store.loadPage(page.id).drawingData == original)
  }
}

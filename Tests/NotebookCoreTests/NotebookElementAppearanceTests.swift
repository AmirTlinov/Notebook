import CoreGraphics
import Foundation
import Testing
@testable import NotebookCore

@Suite struct NotebookElementAppearanceTests {
  let frame = PageRect(x:100,y:200,width:160,height:100)
  func cut(_ points: [SpatialPoint], width: Double = 20) -> InkElementErasure {
    .init(target:.init(elementID:"box",frame:frame),samples:points.map {
      .init(point:.init(x:$0.x+frame.x,y:$0.y+frame.y),timeOffset:0,width:width,opacity:1,force:1,azimuth:0,altitude:1)
    })
  }
  func appearance(_ cuts: [InkElementErasure], size: CGSize = .init(width:160,height:100), graphic: NotebookGraphic? = .init(shape:.rectangle,style:.init(strokeWidth:4))) -> NotebookElementAppearance {
    .init(graphic:graphic,layout:nil,size:size,erasures:cuts)
  }
  @Test func fullyErasedHollowContourHasNoGhostInterior() {
    let rim = cut([.init(x:0,y:0),.init(x:160,y:0),.init(x:160,y:100),.init(x:0,y:100),.init(x:0,y:0)])
    let result = appearance([rim])
    #expect(result.state == .erased)
    #expect(!result.contains(.init(x:80,y:50),tolerance:12))
    #expect(!result.contains(.init(x:0,y:50),tolerance:12))
    #expect(result.readProjection()["sourceIsCompleteAppearance"] == .bool(false))
    #expect(appearance([]).state == .intact)
  }
  @Test func partialEraseKeepsOnlySurvivingPaintAcrossResizeAndOverlap() {
    let erased = cut([.init(x:-10,y:50),.init(x:30,y:50)])
    let result = appearance([erased,erased])
    #expect(result.state == .partial)
    #expect(!result.contains(.init(x:0,y:50),tolerance:12))
    #expect(result.contains(.init(x:160,y:50),tolerance:12))
    #expect(!result.contains(.init(x:80,y:50),tolerance:12))
    let scaled = appearance([erased],size:.init(width:320,height:200))
    #expect(!scaled.contains(.init(x:0,y:100),tolerance:12))
    #expect(scaled.contains(.init(x:320,y:100),tolerance:12))
  }
  @Test func erasedWebEnvelopeCannotBePickedButPartialSourceIsExplicit() {
    let whole = appearance([cut([.init(x:80,y:50)],width:400)],graphic:nil)
    #expect(whole.state == .erased)
    #expect(!whole.contains(.init(x:80,y:50),tolerance:12))
    let part = appearance([cut([.init(x:80,y:50)])],graphic:nil)
    #expect(part.state == .partial)
    #expect(!part.contains(.init(x:80,y:50),tolerance:12))
    #expect(part.contains(.init(x:10,y:10),tolerance:0))
  }
  @Test func addressedIndexSurvivesMigrationAndUndo() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let store = NotebookStore(root:root), actor = UUID()
    let header = try store.initializeWorkspace(actor:actor,pageSize:.init(width:834,height:1194))
    let pageID = try #require(store.loadIndex().selectedPageID), surface = SurfaceID.board(header.rootBoardID)
    let erase = cut([.init(x:80,y:50)],width:400)
    var page = try store.loadPage(pageID)
    let action = PageInkAction(tool:.eraser,samples:erase.samples).erasingElements([erase.target])
    let change = try page.prepareInkChange(.append(action),stamp:.init(counter:10,actor:actor))
    let changed = page.publishInkChange(change); #expect(changed); try store.savePage(page)
    let spatial = SpatialInkAction(tool:.eraser,spans:[SpatialInkSpan(surface:surface,samples:erase.samples.map { .init(point:$0.point,worldPoint:WorldPoint(x:$0.point.x,y:$0.point.y),timeOffset:$0.timeOffset,width:$0.width,opacity:1,force:1,azimuth:0,altitude:1) }).erasingElements([.init(elementID:erase.target.elementID,frame:erase.target.frame,worldOrigin:.zero)])],stamp:.init(counter:11,actor:actor))
    try store.commitSpatialInk(.append(spatial,journalStamp:spatial.stamp))
    #expect(try store.readElementErasures(on:.page(pageID),elementID:"box").count == 1)
    #expect(try store.readElementErasures(on:surface,elementID:"box").count == 1)
    #expect(try store.readElementErasures(on:surface,elementID:"absent").isEmpty)
    // Exact v6 store admission rebuilds only a disposable index, not content.
    let cursor = try store.currentReadCursor()
    try store.commandTransaction(advancesReadRevision:false) {
      try store.currentSQL!.run("DROP TABLE ink_element_erasures")
      try store.currentSQL!.run("PRAGMA user_version=6")
    }
    let reopened = NotebookStore(root:root)
    #expect(try reopened.readElementErasures(on:.page(pageID),elementID:"box").count == 1)
    #expect(try reopened.readElementErasures(on:surface,elementID:"box").count == 1)
    #expect(try reopened.currentReadCursor() == cursor)
    let undo = try page.prepareInkChange(.remove([action.id]),stamp:.init(counter:12,actor:actor))
    let undone = page.publishInkChange(undo); #expect(undone); try reopened.savePage(page)
    try reopened.commitSpatialInk(.state(actionID:spatial.id,creationStamp:spatial.stamp,isActive:false,
      stateStamp:.init(counter:13,actor:actor),journalStamp:.init(counter:13,actor:actor)))
    #expect(try reopened.readElementErasures(on:.page(pageID),elementID:"box").isEmpty)
    #expect(try reopened.readElementErasures(on:surface,elementID:"box").isEmpty)
  }
}

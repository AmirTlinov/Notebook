import NotebookCore
import ImageIO
import SwiftUI
import UIKit
import XCTest
@testable import Notebook

@MainActor final class NotebookGraphicInteractionTests: XCTestCase {
  func testAgentFeedbackUsesTheInstalledPageAndBoardGeometry() async throws {
    for onBoard in [false,true] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent("feedback-scene-\(UUID())")
      let model = NotebookAppModel(store:.init(root:root),startsNearbySync:false)
      retainNotebookUntilTeardown(model,removing:root)
      await model.start(pageSize:NotebookAppModel.defaultPageSize)
      let workspace = try XCTUnwrap(model.workspace), pageID = try XCTUnwrap(workspace.selectedPageID)
      let target = CollaborationTarget(kind:onBoard ? .board : .page,id:onBoard ? workspace.rootBoardID : pageID)
      let origin = WorldPoint(tileX:90_000_000,tileY:-120_000_000,localX:1,localY:2)
      let viewport = SpatialPoint(x:834,y:1194)
      if onBoard { model.moveItem(workspace.selectedItemID,to:.init(x:100_000,y:100_000)) }
      let center = onBoard ? origin.offsetBy(x:417,y:597)
        : try XCTUnwrap(model.boardHierarchy?.focusedCenter(of:workspace.selectedItemID,in:workspace.rootBoardID))
      model.updatePresence(.init(boardID:workspace.rootBoardID,mode:onBoard ? .board : .page,
        camera:.init(center:center,scale:0.8),viewport:viewport,
        focusedItemID:onBoard ? nil : workspace.selectedItemID,openProgress:onBoard ? 0 : 1),settled:true)
      let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
      let window = try await mountNotebookScene(model)
      let graphic = NotebookGraphic(shape:.triangle,vertices:[.init(x:0,y:0.12),.init(x:1,y:0),.init(x:0.7,y:1)])
      var values: [String: JSONValue] = ["kind":.string("graphic"),"source":.string(""),
        "frame":try .encode(PageRect(x:260,y:420,width:220,height:180)),"graphic":try .encode(graphic)]
      if onBoard { values["worldOrigin"] = try .encode(origin) }
      var neighbour = values
      neighbour["frame"] = try .encode(PageRect(x:520,y:420,width:200,height:180))
      neighbour["graphic"] = try .encode(NotebookGraphic(shape:.rectangle,style:.init(strokeWidth:3,fill:.init(red:0.97,green:0.96,blue:0.94))))
      _ = try model.store.applyCollaborationAction(.init(summary:"Agent feedback scene",
        expected:[.init(target:target,revision:model.store.targetContentRevision(target:target))],
        operations:[.init(kind:.insertElement,target:target,id:"feedback",values:values),
          .init(kind:.insertElement,target:target,id:"feedback-neighbour",values:neighbour)]),actor:UUID())
      await model.reloadExternalChanges()?.value
      let deadline = ContinuousClock.now + .seconds(5)
      while (onBoard ? model.compositionTiles.published?.frame.index.element(id:"feedback",boardID:target.id) == nil
        : model.activePage.map { !model.pagePresentations.isPresented($0) } == true), ContinuousClock.now < deadline {
        try await Task.sleep(for:.milliseconds(10))
      }
      let feedbackDeadline = ContinuousClock.now + .seconds(5)
      while model.agentFeedback.episodes.isEmpty, ContinuousClock.now < feedbackDeadline {
        try await Task.sleep(for:.milliseconds(40))
      }
      XCTAssertFalse(model.agentFeedback.episodes.isEmpty,"A real installed source starts feedback without opening history")
      let presence = try XCTUnwrap(model.presence)
      let reference = CollaborationReference(target:target,elementID:"feedback",revision:"fixture")
      let projected = try XCTUnwrap(NotebookAttentionProjection.agentFeedback(.init(reference:reference,expected:.init(target:target,revision:"fixture")),model:model,presence:presence))
      let editable: EditableElementReference = onBoard ? .spatial(boardID:target.id,elementID:"feedback") : .page(pageID:pageID,elementID:"feedback")
      XCTAssertEqual(projected.rect,NotebookAttentionProjection.editingFrame(editable,model:model,presence:presence))
      XCTAssertEqual(projected.graphic,graphic)
      XCTAssertEqual(projected.layout,model.graphicLayout(editable))
      XCTAssertEqual(projected.rect.width/projected.scale,220,accuracy:0.01)
      XCTAssertEqual(projected.rect.height/projected.scale,180,accuracy:0.01)
      XCTAssertEqual(projected.clipRect != nil,!onBoard)
      try await Task.sleep(for:.milliseconds(400))
      func capture() -> UIImage { UIGraphicsImageRenderer(bounds:window.bounds).image { _ in
        window.drawHierarchy(in:window.bounds,afterScreenUpdates:true)
      } }
      let lit = capture()
      let attachment = XCTAttachment(image:lit)
      attachment.name = "feedback-installed-\(onBoard ? "board" : "page")"; attachment.lifetime = .keepAlways; add(attachment)
      let allowed = model.agentFeedback.episodes.values.compactMap {
        NotebookAttentionProjection.agentFeedback($0.subject,model:model,presence:presence)?.rect.insetBy(dx:-2,dy:-2)
      }
      XCTAssertEqual(allowed.count,2)
      model.agentFeedback.stop()
      try await Task.sleep(for:.milliseconds(80))
      let plain = capture()
      let changes = try changedPixels(lit,plain,inside:allowed)
      XCTAssertGreaterThan(changes.inside,20,"Material must actually reach its installed objects")
      XCTAssertEqual(changes.outside,0,"Timeline children share one viewport, never vertically stack their screen coordinates")
      let strokeID = UUID()
      var inkValues: [String:JSONValue] = ["width":.number(5),"opacity":.number(1),
        "points":.array([.object(["x":.number(270),"y":.number(460)]),.object(["x":.number(430),"y":.number(510)])])]
      if onBoard { inkValues["worldOrigin"] = try .encode(origin) }
      let inkRevision = try onBoard ? model.store.readSpatialInk(surfaces:[]).stamp.revision : model.store.loadPage(pageID).drawingStamp.revision
      _ = try model.store.applyCollaborationAction(.init(summary:"Agent ink feedback",expected:[.init(target:target,
        revision:model.store.targetContentRevision(target:target),inkRevision:inkRevision)],operations:[
          .init(kind:.appendInkStroke,target:target,id:strokeID.uuidString,values:inkValues)]),actor:UUID())
      await model.reloadExternalChanges()?.value
      let inkDeadline = ContinuousClock.now + .seconds(5)
      while !model.agentFeedback.episodes.values.contains(where: { $0.subject.strokeID == strokeID }), ContinuousClock.now < inkDeadline {
        try await Task.sleep(for:.milliseconds(40))
      }
      let inkEpisode = try XCTUnwrap(model.agentFeedback.episodes.values.first { $0.subject.strokeID == strokeID })
      let inkMaterial = try XCTUnwrap(NotebookAttentionProjection.agentFeedback(inkEpisode.subject,model:model,presence:try XCTUnwrap(model.presence)))
      XCTAssertFalse(try XCTUnwrap(inkMaterial.ink).isEmpty,"Pen feedback uses its canonical brush footprint")
      await model.shutdown()
    }
  }

  private func changedPixels(_ left: UIImage, _ right: UIImage, inside rects: [CGRect]) throws -> (inside:Int,outside:Int) {
    func pixels(_ image: UIImage) throws -> (CGImage,[UInt8]) {
      let cg = try XCTUnwrap(image.cgImage)
      let context = try XCTUnwrap(CGContext(data:nil,width:cg.width,height:cg.height,bitsPerComponent:8,
        bytesPerRow:cg.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(cg,in:.init(x:0,y:0,width:cg.width,height:cg.height))
      let data = try XCTUnwrap(context.data).assumingMemoryBound(to:UInt8.self)
      return (cg,Array(UnsafeBufferPointer(start:data,count:cg.width*cg.height*4)))
    }
    let (a,first) = try pixels(left), (_,second) = try pixels(right)
    var inside = 0, outside = 0
    for y in 0..<a.height { for x in 0..<a.width {
      let offset = (y*a.width+x)*4
      guard (0..<3).contains(where: { abs(Int(first[offset+$0])-Int(second[offset+$0])) > 8 }) else { continue }
      let point = CGPoint(x:Double(x)/left.scale,y:Double(y)/left.scale)
      if rects.contains(where: { $0.contains(point) }) { inside += 1 } else { outside += 1 }
    } }
    return (inside,outside)
  }

  func testErasedGeometryCannotSelectItsOldContourOrEmptyInterior() {
    let surface = SurfaceID.page(UUID()), frame = PageRect(x:100,y:200,width:160,height:100)
    let graphic = NotebookGraphic(shape:.rectangle,style:.init(strokeWidth:4))
    let element = AgentElement(id:"ghost",kind:.graphic,frame:frame,source:"",html:"",graphic:graphic)
    let graph = NotebookGraphicGraph([.init(id:"ghost",graphic:graphic,frame:frame,surface:surface,shown:true)])
    func cut(_ points: [SpatialPoint]) -> InkElementErasure {
      .init(target:.init(elementID:"ghost",frame:frame),samples:points.map {
        .init(point:$0,timeOffset:0,width:20,opacity:1,force:1,azimuth:0,altitude:1)
      })
    }
    let rim = cut([.init(x:100,y:200),.init(x:260,y:200),.init(x:260,y:300),.init(x:100,y:300),.init(x:100,y:200)])
    func pick(_ point: SpatialPoint, cuts: [InkElementErasure]) -> String? {
      NotebookAttentionProjection.pickElement(in:[element],graph:graph,erasures:["ghost":cuts],
        appearance: { _,graphic,layout,size,cuts in .init(graphic:graphic,layout:layout,size:size,erasures:cuts) }, scale:1,
        viewport:.init(x:834,y:1194),presentation:{ .init($0,placement:$1) },project:{ ($0.id,$0.graphic,point) })?.id
    }
    XCTAssertNil(pick(.init(x:180,y:250),cuts:[rim]))
    XCTAssertNil(pick(.init(x:100,y:250),cuts:[rim]))
    XCTAssertEqual(pick(.init(x:180,y:250),cuts:[]),"ghost","Undo restores ordinary interior picking")
    let partial = cut([.init(x:80,y:250),.init(x:130,y:250)])
    XCTAssertNil(pick(.init(x:100,y:250),cuts:[partial]))
    XCTAssertEqual(pick(.init(x:260,y:250),cuts:[partial]),"ghost")
  }

  func testHollowSelectionUsesActualPolygonAndKeepsItsChildrenReachable() throws {
    let pageID = UUID()
    func element(_ id: String, _ shape: NotebookGraphic.Shape, _ frame: PageRect) -> AgentElement {
      .init(id:id,kind:.graphic,frame:frame,source:"",html:"",graphic:.init(shape:shape))
    }
    let outer = element("outer",.rectangle,.init(x:0,y:0,width:600,height:700))
    let triangle = element("triangle",.triangle,.init(x:100,y:100,width:240,height:240))
    let diamond = element("diamond",.diamond,.init(x:150,y:210,width:80,height:80))
    let child = AgentElement(id:"child",kind:.web,frame:.init(x:175,y:250,width:24,height:20),source:"",html:"<p>x</p>")
    func pick(_ point: SpatialPoint, _ elements: [AgentElement]) -> String? {
      let actor=UUID()
      let spatial=elements.map { e in SpatialElement(id:e.id,surface:.board(pageID),kind:e.kind == .graphic ? .graphic : .web,
        frame:.init(x:e.frame.x,y:e.frame.y,width:e.frame.width,height:e.frame.height),worldOrigin:.zero,
        source:e.source,html:e.html,graphic:e.graphic,stamp:.init(counter:0,actor:actor)) }
      let graph=BoardDocument(freeItems:[],elements:spatial,stamp:.init(counter:0,actor:actor)).graphicGraph()
      return NotebookAttentionProjection.pickElement(in:elements,graph:graph,scale:1,viewport:.init(x:834,y:1194),presentation:{ .init($0,placement:$1) },
        project:{ ($0.id,$0.graphic,point) })?.id
    }
    XCTAssertEqual(pick(.init(x:220,y:200),[triangle]),"triangle")
    XCTAssertNil(pick(.init(x:100,y:100),[triangle]),"A polygon is not its bounding rectangle")
    XCTAssertEqual(pick(.init(x:190,y:250),[diamond,triangle,outer]),"diamond","Small inner shape wins even under a later enclosing outline")
    XCTAssertEqual(pick(.init(x:185,y:260),[child,diamond,triangle,outer]),"child")
    let oversized = element("canvas",.rectangle,.init(x:-1000,y:-1000,width:3000,height:3000))
    XCTAssertEqual(pick(.init(x:400,y:500),[oversized]),"canvas","A visible figure stays selectable when zoomed beyond the viewport")
  }

  func testGraphicPickingStaysCloseToTheVisibleStrokeAtEveryZoom() throws {
    let surface = SurfaceID.page(UUID()), frame = PageRect(x:100,y:200,width:240,height:180)
    for scale in [0.25,1.0,3.0] {
      for graphic in [NotebookGraphic(shape:.rectangle,style:.init(strokeWidth:2)),
        NotebookGraphic(shape:.connector,style:.init(strokeWidth:2),connection:.init(
          start:.init(point:.zero),end:.init(point:.init(x:240,y:0))))] {
        let element = AgentElement(id:"shape",kind:.graphic,frame:frame,source:"",html:"",graphic:graphic)
        let graph = NotebookGraphicGraph([.init(id:"shape",graphic:graphic,frame:frame,surface:surface,shown:true)])
        let layout = try XCTUnwrap(graph.resolve("shape").layout)
        func pick(outsideStroke distance: Double) -> String? {
          let offset = graphic.style.strokeWidth/2 + distance/scale
          let point = graphic.shape == .connector
            ? SpatialPoint(x:layout.frame.x+(layout.start.x+layout.end.x)/2,y:layout.frame.y+layout.start.y-offset)
            : SpatialPoint(x:frame.x-offset,y:frame.y+frame.height/2)
          return NotebookAttentionProjection.pickElement(in:[element],graph:graph,scale:scale,
            viewport:.init(x:834,y:1194),presentation:{ .init($0,placement:$1) },project:{ ($0.id,$0.graphic,point) })?.id
        }
        XCTAssertEqual(pick(outsideStroke:4),"shape","A little finger tolerance remains at scale \(scale)")
        XCTAssertNil(pick(outsideStroke:9),"Blank paper is not a broad invisible outline at scale \(scale)")
      }
    }
  }

}

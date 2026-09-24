import NotebookCore
import UIKit
import XCTest
@testable import Notebook

@MainActor final class NotebookDrawingGuideTests: XCTestCase {
  func testCaptureIsSurfaceLocalScreenDistanceLimitedAndImmutable() throws {
    let board=UUID(),origin=WorldPoint(x:8_000,y:-12_000)
    let owner=NotebookToolAddress(surface:.board(board),boardID:board,worldOrigin:origin,bounds:nil)
    var guide=NotebookDrawingGuide(address:owner,start:.init(x:30,y:40),length:200)
    let source=NotebookToolAddress(surface:owner.surface,boardID:board,
      worldOrigin:origin.offsetBy(x:20,y:10),bounds:nil)
    let frozen=try XCTUnwrap(guide.constraint(at:.init(x:80,y:32),from:source,screenScale:2))
    XCTAssertEqual(frozen.project(SpatialPoint(x:140,y:100)),.init(x:140,y:30))
    XCTAssertNil(guide.constraint(at:.init(x:80,y:37),from:source,screenScale:2))
    XCTAssertNotNil(guide.constraint(at:.init(x:80,y:37),from:source,screenScale:1))
    XCTAssertNil(guide.constraint(at:.zero,from:.init(surface:.page(UUID()),boardID:nil,worldOrigin:nil,bounds:nil),screenScale:1))
    guide.angle=90;guide.length=40
    XCTAssertEqual(frozen.project(SpatialPoint(x:140,y:100)),.init(x:140,y:30))
    let transform=CGAffineTransform(rotationAngle:.pi/3).scaledBy(x:2,y:2).translatedBy(x:40,y:60)
    let input=CGPoint(x:80,y:37).applying(transform)
    let expected=CGPoint(x:80,y:30).applying(transform)
    let projected=frozen.projected(using:transform).project(input)
    XCTAssertEqual(projected.x,expected.x,accuracy:1e-9);XCTAssertEqual(projected.y,expected.y,accuracy:1e-9)
  }

  func testProtractorSelectsTwoSidesOrItsArcAndCompassKeepsExactRadius() throws {
    let owner=NotebookToolAddress(surface:.page(UUID()),boardID:nil,worldOrigin:nil,bounds:nil)
    var protractor=NotebookDrawingGuide(address:owner,kind:.protractor,start:.init(x:100,y:100),length:100)
    protractor.openingAngle=90
    let first=try XCTUnwrap(protractor.constraint(at:.init(x:145,y:103),from:owner,screenScale:1))
    XCTAssertEqual(first.project(SpatialPoint(x:165,y:180)),.init(x:165,y:100))
    let second=try XCTUnwrap(protractor.constraint(at:.init(x:103,y:145),from:owner,screenScale:1))
    let point=second.project(SpatialPoint(x:180,y:165))
    XCTAssertEqual(point.x,100,accuracy:1e-9);XCTAssertEqual(point.y,165,accuracy:1e-9)
    let arc=try XCTUnwrap(protractor.constraint(at:.init(x:170,y:170),from:owner,screenScale:1))
    let radial=arc.project(SpatialPoint(x:150,y:190))
    XCTAssertEqual(hypot(radial.x-100,radial.y-100),100,accuracy:1e-9)
    let clamped=arc.project(SpatialPoint(x:0,y:200))
    XCTAssertEqual(clamped.x,100,accuracy:1e-9);XCTAssertEqual(clamped.y,200,accuracy:1e-9)
    protractor.kind = .compass
    let circle=try XCTUnwrap(protractor.constraint(at:.init(x:0,y:100),from:owner,screenScale:1))
    for degree in stride(from:0.0,to:360,by:0.5) {
      let a=degree * .pi/180,p=circle.project(SpatialPoint(x:100+123*cos(a),y:100+123*sin(a)))
      XCTAssertEqual(hypot(p.x-100,p.y-100),100,accuracy:1e-9)
    }
  }

  func testToggleAndDeferredPoseNeverChangeMainStyleOrCreateHistory() async throws {
    try await fixture { model in
      let presence=try XCTUnwrap(model.presence)
      model.updatePresence(.init(boardID:presence.boardID,mode:.page,camera:presence.camera,viewport:presence.viewport,
        focusedItemID:model.workspace?.selectedItemID,openProgress:1),settled:true)
      model.selectDrawingTool(.marker)
      let style=model.activePenStyle,revision=try model.store.workspaceHeader().cursor
      model.drawingTools.toggleGuide()
      let original=try XCTUnwrap(model.drawingTools.guide)
      var moved=original;moved.start = .init(x:original.start.x+80,y:original.start.y);moved.angle=32.1
      let contact=UUID();XCTAssertTrue(model.inputGate.beginPencilAction(source:contact))
      model.drawingTools.updateGuide(moved);model.drawingTools.toggleGuide()
      XCTAssertEqual(model.drawingTools.guide,original);XCTAssertTrue(model.drawingTools.guideEnabled)
      model.inputGate.endPencilAction(source:contact)
      XCTAssertEqual(model.drawingTools.guide,moved);XCTAssertFalse(model.drawingTools.guideEnabled)
      model.drawingTools.toggleGuide()
      XCTAssertEqual(model.drawingTools.guide,moved);XCTAssertTrue(model.drawingTools.guideEnabled)
      XCTAssertEqual(model.drawingTool,.marker);XCTAssertEqual(model.activePenStyle,style)
      let saved=await model.finishPendingPersistence();XCTAssertTrue(saved)
      XCTAssertEqual(try model.store.workspaceHeader().cursor,revision)
      model.updatePresence(.init(boardID:presence.boardID,mode:.board,camera:presence.camera,viewport:presence.viewport),settled:true)
      XCTAssertNil(model.drawingTools.guide);XCTAssertFalse(model.drawingTools.guideEnabled)
      model.drawingTools.updateGuide(moved)
      XCTAssertNil(model.drawingTools.guide,"A deferred pose cannot resurrect a previous surface")
    }
  }

  func testGuidedPageSamplesKeepNativePressureTimeAndQuickShapeOwnership() async throws {
    try await fixture { model in
      let page=try XCTUnwrap(model.activePage),presence=try XCTUnwrap(model.presence)
      model.updatePresence(.init(boardID:presence.boardID,mode:.page,camera:presence.camera,viewport:presence.viewport,
        focusedItemID:model.workspace?.selectedItemID,openProgress:1),settled:true)
      model.drawingTools.toggleGuide()
      var guide=try XCTUnwrap(model.drawingTools.guide)
      guide.start = .init(x:20,y:100);guide.length=300;guide.angle=0;guide.snapToGrid=false
      model.drawingTools.updateGuide(guide)
      for tool in [DrawingTool.pen,.marker] {
        model.selectDrawingTool(tool)
        let paper=PaperInputView(frame:.init(x:0,y:0,width:page.size.width,height:page.size.height))
        paper.toolController=model.drawingTools;paper.quickShapePageID=page.id
        paper.configure(penStyle:.standard,eraserStyle:.standard,drawingTool:tool)
        var action:PageInkAction?
        paper.onDrawingMutation = { action=$0 }
        let touch=GuidePencilTouch();touch.point = .init(x:40,y:104)
        paper.touchesBegan([touch],with:nil)
        for index in 1...25 {
          touch.point = .init(x:40+index*8,y:105+index);touch.sampleTime += 0.02;touch.pressure=CGFloat(index)/25
          paper.touchesMoved([touch],with:nil)
        }
        try await Task.sleep(for:.milliseconds(600))
        XCTAssertNil(paper.completedQuickShape)
        paper.touchesEnded([touch],with:nil)
        let guided=try XCTUnwrap(action),samples=guided.samples
        XCTAssertGreaterThan(samples.count,10)
        XCTAssertTrue(samples.allSatisfy { abs($0.point.y-100) < 0.001 })
        if tool == .marker { XCTAssertEqual(samples.first?.opacity ?? 0,0.3,accuracy:1.0/255) }
        else { XCTAssertGreaterThan(samples.last!.opacity,samples.first!.opacity) }
        XCTAssertGreaterThan(samples.last!.force,samples.first!.force)
        XCTAssertEqual(samples.last!.timeOffset-samples.first!.timeOffset,0.5,accuracy:0.001)
        let stamp=try XCTUnwrap(model.reserveDrawingAction(pageID:page.id))
        XCTAssertNotNil(model.acceptDrawingAction(guided,pageID:page.id,stamp:stamp))
        let saved=await model.finishPendingPersistence();XCTAssertTrue(saved)
        let reopened=try NotebookStore(root:model.store.root).loadPage(page.id).inkDrawing()
        XCTAssertEqual(reopened.action(id:guided.id)?.samples,samples)
        XCTAssertNotNil(model.acceptDrawingUndo())
        XCTAssertFalse(try model.activePage!.inkDrawing().activeActions.contains { $0.id == guided.id })
        XCTAssertNotNil(model.acceptDrawingRedo())
        let repeated=await model.finishPendingPersistence();XCTAssertTrue(repeated)
        XCTAssertEqual(try NotebookStore(root:model.store.root).loadPage(page.id).inkDrawing().action(id:guided.id)?.samples,samples)
        // The next, distant contact must not inherit the previous constraint.
        action=nil;touch.point = .init(x:40,y:250);touch.sampleTime += 1
        paper.touchesBegan([touch],with:nil);touch.point.y=300;touch.sampleTime += 0.1
        paper.touchesMoved([touch],with:nil);paper.touchesEnded([touch],with:nil)
        XCTAssertTrue(try XCTUnwrap(action).samples.allSatisfy { $0.point.y > 200 })
      }
    }
  }

  private func fixture(_ body:(NotebookAppModel) async throws -> Void) async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model=NotebookAppModel(store:.init(root:root),startsNearbySync:false,preferences:UserDefaults(suiteName:UUID().uuidString)!)
    retainNotebookUntilTeardown(model,removing:root)
    await model.start(pageSize:NotebookAppModel.defaultPageSize)
    _ = await model.finishPendingPersistence()
    try await body(model)
  }
}

@MainActor private final class GuidePencilTouch: UITouch {
  var point=CGPoint.zero
  var sampleTime:TimeInterval=1
  var pressure:CGFloat=0.1
  override var type:UITouch.TouchType { .pencil }
  override var timestamp:TimeInterval { sampleTime }
  override var force:CGFloat { pressure }
  override var maximumPossibleForce:CGFloat { 1 }
  override var altitudeAngle:CGFloat { .pi/2 }
  override func preciseLocation(in view:UIView?) -> CGPoint { point }
  override func location(in view:UIView?) -> CGPoint { point }
  override func azimuthAngle(in view:UIView?) -> CGFloat { 0 }
}

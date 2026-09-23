import NotebookCore
import UIKit
import XCTest
@testable import Notebook

final class AcceptedPageInputTests: XCTestCase {
  @MainActor
  func testLiveElementEraserStaysInNativePresentationUntilLift() async throws {
    let paper=PaperInputView(frame:.init(x:0,y:0,width:500,height:500))
    let page=PageDocument(size:.init(width:500,height:500),actor:UUID(),elements:[
      .init(id:"object",kind:.graphic,frame:.init(x:0,y:0,width:500,height:500),source:"",html:"",
        graphic:.init(shape:.rectangle,style:.init(fill:.black)))])
    paper.quickShapePageID=page.id
    paper.configure(penStyle:.standard,eraserStyle:.standard,drawingTool:.eraser)
    paper.pageEraserSource = {
      .init(page:page,graph:page.graphicGraph(),changedTargets:[:],excludedElementIDs:[])
    }
    let presentation=NotebookLiveElementEraserPresentation()
    var updates=0
    paper.onLiveElementErasing = { event in
      if case .update = event { updates += 1 }
      presentation.display(event)
    }
    let touch=AcceptedInputTouch();touch.point = .init(x:20,y:20)
    paper.touchesBegan([touch],with:nil)
    for index in 1...60 {
      touch.point = .init(x:CGFloat(20+index*4),y:CGFloat(20+index*2));touch.sampleTime += 1.0/120
      paper.touchesMoved([touch],with:nil)
    }
    XCTAssertGreaterThan(updates,50)
    paper.touchesEnded([touch],with:nil)
    try await Task.sleep(for:.milliseconds(150))
    XCTAssertTrue(presentation.isActive,"Lift must keep coverage until the permanent mask is visible")
    let action=try XCTUnwrap(presentation.pending.first)
    presentation.presented([:])
    XCTAssertTrue(presentation.isActive,"An older ready overlay cannot acknowledge this cut")
    presentation.presented(PageInkDrawing(actions:[action]).elementErasures)
    XCTAssertFalse(presentation.isActive)
    XCTAssertTrue(presentation.pending.isEmpty)
  }

  @MainActor
  func testPencilLiftPublishesOneJournalDeltaBeforeWaitingInputRuns() async throws {
    let (model,root)=await makeModel()
    let page=try XCTUnwrap(model.activePage)
    let coordinator=makeCoordinator(model)
    let paper=PaperCanvasContainerView()
    coordinator.attach(to:paper);coordinator.setPageFinisherCurrent(true)
    coordinator.apply(page.inkSource,pageID:page.id,to:paper)
    await waitForSource(paper)

    let touch=AcceptedInputTouch()
    paper.touchView.touchesBegan([touch],with:nil)
    var released=false
    model.inputGate.performAfterPageInput { released=true }
    XCTAssertFalse(released)
    touch.point = .init(x:180,y:240);touch.sampleTime = 1.01
    paper.touchView.touchesEnded([touch],with:nil)

    XCTAssertTrue(released,"The command waits only for measured lift, not SQLite publication")
    XCTAssertEqual(try model.activePage?.inkDrawing().activeActions.count,1)
    let persisted = await model.finishPendingPersistence()
    XCTAssertTrue(persisted)
    XCTAssertEqual(try NotebookStore(root:root).loadPage(page.id).inkDrawing().activeActions.count,1)
    coordinator.detach(from:paper)
  }

  @MainActor
  func testUnmountTransfersMeasuredContactWithoutASecondDeliveryOwner() async throws {
    let (model,root)=await makeModel()
    let page=try XCTUnwrap(model.activePage)
    let coordinator=makeCoordinator(model)
    let paper=PaperCanvasContainerView()
    coordinator.attach(to:paper);coordinator.setPageFinisherCurrent(true)
    coordinator.apply(page.inkSource,pageID:page.id,to:paper)
    await waitForSource(paper)
    let touch=AcceptedInputTouch()
    paper.touchView.touchesBegan([touch],with:nil)
    touch.point = .init(x:180,y:240);touch.sampleTime = 1.01
    paper.touchView.touchesMoved([touch],with:nil)
    coordinator.detach(from:paper)
    XCTAssertFalse(model.inputGate.hasActivePencil)
    XCTAssertEqual(model.pendingPageDrawingReservationCount,0)
    XCTAssertEqual(try model.activePage?.inkDrawing().activeActions.count,1)
    let persisted = await model.finishPendingPersistence()
    XCTAssertTrue(persisted)
    XCTAssertEqual(try NotebookStore(root:root).loadPage(page.id).inkDrawing().activeActions.count,1)
  }

  @MainActor
  func testSourcePublicationCannotCancelAnAdmittedContact() async throws {
    let (model,_)=await makeModel()
    let page=try XCTUnwrap(model.activePage)
    let coordinator=makeCoordinator(model)
    let paper=PaperCanvasContainerView()
    coordinator.attach(to:paper);coordinator.setPageFinisherCurrent(true)
    coordinator.apply(page.inkSource,pageID:page.id,to:paper)
    await waitForSource(paper)
    let touch=AcceptedInputTouch()
    paper.touchView.touchesBegan([touch],with:nil)
    XCTAssertEqual(model.pendingPageDrawingReservationCount,1)
    paper.apply(try page.inkDrawing())
    XCTAssertTrue(paper.touchView.hasActiveAction)
    XCTAssertTrue(model.inputGate.hasActivePencil)
    XCTAssertEqual(model.pendingPageDrawingReservationCount,1,"A source update cannot release somebody else's contact")
    touch.point = .init(x:180,y:240);touch.sampleTime=1.01
    paper.touchView.touchesEnded([touch],with:nil)
    XCTAssertEqual(model.pendingPageDrawingReservationCount,0)
    XCTAssertEqual(try model.activePage?.inkDrawing().activeActions.count,1)
    coordinator.detach(from:paper)
  }

  @MainActor
  func testFirstLiftBeforeColdDecodeKeepsTheStoredBaseAndMeasuredTail() async throws {
    let (model,_)=await makeModel()
    let page=try XCTUnwrap(model.activePage),base=stroke(y:100)
    let stamp=try XCTUnwrap(model.reserveDrawingAction(pageID:page.id))
    XCTAssertNotNil(model.acceptDrawingAction(base,pageID:page.id,stamp:stamp))
    let coordinator=makeCoordinator(model),paper=PaperCanvasContainerView()
    coordinator.attach(to:paper);coordinator.setPageFinisherCurrent(true)
    coordinator.apply(page.inkSource,pageID:page.id,to:paper)
    // No suspension: both contact and acceptance beat the queued cold decoder.
    let touch=AcceptedInputTouch()
    paper.touchView.touchesBegan([touch],with:nil)
    touch.point = .init(x:180,y:240);touch.sampleTime=1.01
    paper.touchView.touchesEnded([touch],with:nil)
    XCTAssertEqual(try model.activePage?.inkDrawing().activeActions.count,2)
    let deadline=ContinuousClock.now + .seconds(2)
    while !paper.inkView.pageGeometryIsReady,ContinuousClock.now < deadline {
      try await Task.sleep(for:.milliseconds(5))
    }
    XCTAssertTrue(paper.inkView.pageGeometryIsReady)
    XCTAssertEqual(paper.inkView.committedSourceNodeCount,4,"Acceptance must install the old line and the new contact exactly once")
    XCTAssertFalse(model.inputGate.hasActivePencil)
    XCTAssertEqual(model.pendingPageDrawingReservationCount,0)
    coordinator.detach(from:paper)
  }

  @MainActor
  func testUndoAndLassoReadTheSameImmediateVectorJournal() async throws {
    let (model,_)=await makeModel()
    let page=try XCTUnwrap(model.activePage),action=stroke(y:220)
    let stamp=try XCTUnwrap(model.reserveDrawingAction(pageID:page.id))
    XCTAssertNotNil(model.acceptDrawingAction(action,pageID:page.id,stamp:stamp))
    let polygon=[SpatialPoint(x:0,y:190),.init(x:220,y:190),.init(x:220,y:280),.init(x:0,y:280)]
    let before=model.lassoInkSnapshot(page)
    XCTAssertEqual(try before.selection(polygon:polygon,surface:.page(page.id),origin:nil,bounds:nil)?.graphic.sourceInkIDs,[action.id])
    XCTAssertNotNil(model.acceptDrawingUndo())
    let activePage = try XCTUnwrap(model.activePage)
    let after=model.lassoInkSnapshot(activePage)
    XCTAssertNil(try after.selection(polygon:polygon,surface:.page(page.id),origin:nil,bounds:nil))
  }

  @MainActor
  private func makeModel() async -> (NotebookAppModel,URL) {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model=NotebookAppModel(store:.init(root:root),startsNearbySync:false)
    retainNotebookUntilTeardown(model,removing:root)
    await model.start(pageSize:NotebookAppModel.defaultPageSize)
    let persisted = await model.finishPendingPersistence()
    XCTAssertTrue(persisted)
    return (model,root)
  }

  @MainActor
  private func makeCoordinator(_ model:NotebookAppModel) -> PencilCanvasView.Coordinator {
    .init(inputGate:model.inputGate,reserveAction:model.reserveDrawingAction,
      releaseAction:{ model.releaseDrawingReservation(pageID:$0,stamp:$1) },
      acceptAction:{ model.acceptDrawingAction($0,pageID:$1,stamp:$2,quickShape:$3) })
  }

  @MainActor
  private func waitForSource(_ paper:PaperCanvasContainerView) async {
    // Source decoding is deliberately non-blocking for Pencil. Give the first
    // retained snapshot a scheduler turn; input admission does not depend on it.
    for _ in 0..<20 { await Task.yield() }
  }

  private func stroke(y:Double) -> PageInkAction {
    .init(tool:.pen,samples:[
      .init(point:.init(x:20,y:y),timeOffset:0,width:2,opacity:1,force:1,azimuth:0,altitude:1),
      .init(point:.init(x:180,y:y+30),timeOffset:0.01,width:3,opacity:1,force:0.7,azimuth:0.1,altitude:1.2),
    ])
  }
}

@MainActor
private final class AcceptedInputTouch:UITouch {
  var point=CGPoint(x:120,y:220)
  var sampleTime:TimeInterval=1
  var inputType:UITouch.TouchType = .pencil
  override var type:UITouch.TouchType { inputType }
  override var timestamp:TimeInterval { sampleTime }
  override var force:CGFloat { 1 }
  override var maximumPossibleForce:CGFloat { 1 }
  override var altitudeAngle:CGFloat { .pi/2 }
  override func location(in view:UIView?) -> CGPoint { point }
  override func preciseLocation(in view:UIView?) -> CGPoint { point }
  override func azimuthAngle(in view:UIView?) -> CGFloat { 0 }
}

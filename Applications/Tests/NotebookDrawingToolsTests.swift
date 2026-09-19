import NotebookCore
import XCTest
import UIKit
@testable import Notebook

@MainActor final class NotebookDrawingToolsTests: XCTestCase {
  func testMarkerUsesConstantOpacityAndKeepsIndependentStyle() {
    let settings = NotebookDrawingToolSettings(), marker = settings.marker
    XCTAssertEqual(marker.width,18)
    for force in [0.0,0.1,0.5,1,2] { XCTAssertEqual(marker.opacity(force:force),0.3) }
    XCTAssertNotEqual(PenStyle.standard.opacity(force:0),PenStyle.standard.opacity(force:1))
    XCTAssertTrue(DrawingTool.marker.usesInkJournal)
    for tool in [DrawingTool.lasso,.shape,.text,.connector,.ruler,.laser] { XCTAssertFalse(tool.usesInkJournal) }
  }

  func testShapesAndRulerSharePhysicalGeometryInEveryDragDirection() throws {
    for (x,y) in [(-1.0,-1.0),(-1,1),(1,-1),(1,1)] {
      let fit = try XCTUnwrap(NotebookToolGeometry.figure(from:.init(x:100,y:100),to:.init(x:100+x*80,y:100+y*50),
        shape:.rectangle,preservesAspect:true,width:2))
      XCTAssertEqual(fit.frame.width,80); XCTAssertEqual(fit.frame.height,80)
      XCTAssertEqual(fit.frame.x,x < 0 ? 20 : 100); XCTAssertEqual(fit.frame.y,y < 0 ? 20 : 100)
    }
    let line = try XCTUnwrap(NotebookToolGeometry.figure(from:.init(x:80,y:70),to:.init(x:10,y:20),shape:.arrow,preservesAspect:false,width:2))
    XCTAssertEqual(line.connection?.start.point,.init(x:70,y:50)); XCTAssertEqual(line.connection?.end.point,.zero)
    XCTAssertEqual(line.connection?.endArrowhead,.arrow)
    let point = NotebookToolGeometry.rulerEnd(from:.init(x:10,y:20),to:.init(x:87,y:45),angle:0,grid:10)
    XCTAssertEqual(point,.init(x:90,y:20))
  }

  func testTemporaryToolsDoNotCreateInkOrAuthoredObjectsAndCancellationDropsPreview() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults = UserDefaults(suiteName:UUID().uuidString)!
    let model = NotebookAppModel(store:.init(root:root),startsNearbySync:false,preferences:defaults)
    await model.start(pageSize:NotebookAppModel.defaultPageSize)
    let board = try XCTUnwrap(model.presence?.boardID)
    let address = NotebookToolAddress(surface:.board(board),boardID:board,worldOrigin:.zero,bounds:nil)
    let before = model.spatialInk
    model.selectDrawingTool(.laser)
    XCTAssertTrue(model.drawingTools.begin(at:.zero,address:address,screenScale:1))
    model.drawingTools.move(to:.init(x:50,y:80)); model.drawingTools.finish()
    XCTAssertEqual(model.spatialInk,before); XCTAssertTrue(model.workingGraphics.isEmpty)
    model.selectDrawingTool(.shape)
    XCTAssertTrue(model.drawingTools.begin(at:.zero,address:address,screenScale:1))
    model.drawingTools.move(to:.init(x:150,y:80)); XCTAssertEqual(model.workingGraphics.count,1)
    model.selectDrawingTool(.pen)
    XCTAssertNil(model.drawingTools.contact); XCTAssertTrue(model.workingGraphics.isEmpty)
    let stopped = await model.shutdown(); XCTAssertTrue(stopped)
    if stopped { try FileManager.default.removeItem(at:root) }
  }
  func testMarkerRunsThroughMeasuredPageInputWithoutPressureOrQuickShape() async throws {
    let paper = PaperInputView(frame:.init(x:0,y:0,width:500,height:500))
    let style = NotebookDrawingToolSettings().marker
    paper.configure(penStyle:style,eraserStyle:.standard,drawingTool:.marker)
    let touch = DrawingToolPencilTouch()
    var accepted: PageInkAction?
    paper.onDrawingMutation = { accepted = $0 }
    touch.point = .init(x:50,y:80); touch.pressure = 0.1
    paper.touchesBegan([touch],with:nil)
    for i in 1...20 {
      touch.point.x += 5; touch.sampleTime += 0.01; touch.pressure = CGFloat(i)/20
      paper.touchesMoved([touch],with:nil)
    }
    try await Task.sleep(for:.milliseconds(600))
    XCTAssertNil(paper.completedQuickShape)
    paper.touchesEnded([touch],with:nil)
    let ink = try XCTUnwrap(accepted)
    XCTAssertEqual(ink.tool,.pen); XCTAssertEqual(ink.color.red,1)
    let opacities = ink.samples.map(\.opacity)
    XCTAssertEqual(opacities.min()!,opacities.max()!,accuracy:0.000001,"Marker ignores pressure over the whole contact")
    XCTAssertEqual(opacities[0],0.3,accuracy:1.0/255,"PKStrokePoint quantizes opacity")
    XCTAssertTrue(ink.samples.allSatisfy { abs($0.width-18) < 0.000001 },"Widths: \(ink.samples.map(\.width))")
    XCTAssertFalse(paper.hasActiveAction)
  }

  func testNonInkPageContactUsesNoInkReservationAndCancellationReleasesGate() async throws {
    try await fixture { model in
      let page = try XCTUnwrap(model.activePage)
      let paper = PaperInputView(frame:.init(x:0,y:0,width:page.size.width,height:page.size.height))
      paper.toolController = model.drawingTools; paper.toolInputGate = model.inputGate; paper.quickShapePageID = page.id
      var reservations = 0, inkActions = 0
      paper.onActionWillBegin = { reservations += 1; return true }
      paper.onDrawingMutation = { _ in inkActions += 1 }
      let touch = DrawingToolPencilTouch()
      for tool in [DrawingTool.shape,.connector,.ruler,.text,.laser,.lasso] {
        model.selectDrawingTool(tool)
        paper.configure(penStyle:.standard,eraserStyle:.standard,drawingTool:tool)
        touch.point = .init(x:100,y:100); paper.touchesBegan([touch],with:nil)
        XCTAssertTrue(model.inputGate.hasActivePencil)
        touch.point = .init(x:230,y:190); touch.sampleTime += 0.1; paper.touchesMoved([touch],with:nil)
        model.selectDrawingTool(.pen)
        XCTAssertFalse(model.inputGate.hasActivePencil,"Changing a tool cancels its admitted non-ink contact")
        paper.touchesCancelled([touch],with:nil)
        XCTAssertTrue(model.workingGraphics.isEmpty)
      }
      model.selectDrawingTool(.shape)
      paper.configure(penStyle:.standard,eraserStyle:.standard,drawingTool:.shape)
      for offset in [0.0,40] {
        touch.point = .init(x:100+offset,y:100); paper.touchesBegan([touch],with:nil)
        touch.point = .init(x:230+offset,y:190); touch.sampleTime += 0.1
        paper.touchesMoved([touch],with:nil); paper.touchesEnded([touch],with:nil)
        XCTAssertFalse(model.inputGate.hasActivePencil); XCTAssertFalse(paper.hasActiveAction)
      }
      await assertSaved(model)
      XCTAssertEqual(try model.store.loadPage(page.id).elements.count,2,"Lift commits each native contact exactly once; a stale adapter cannot swallow the next one")
      XCTAssertEqual(reservations,0); XCTAssertEqual(inkActions,0)
      XCTAssertEqual(try model.store.loadPage(page.id).drawingData,page.drawingData)
    }
  }

  func testLassoFeedbackStaysAboveCoversAndReleasesItsWindowLayer() async throws {
    try await fixture { model in
      let window = UIWindow(frame:.init(x:0,y:0,width:600,height:800))
      let ink = UIView(frame:.init(x:20,y:40,width:500,height:700))
      window.addSubview(ink)
      let cover = UIView(frame:window.bounds); window.addSubview(cover)
      let page = try XCTUnwrap(model.activePage)
      model.selectDrawingTool(.lasso)
      let contact = try XCTUnwrap(NotebookToolInputContact(controller:model.drawingTools,gate:model.inputGate,view:ink,
        address:.init(surface:.page(page.id),boardID:nil,worldOrigin:nil,bounds:nil),
        point:.init(x:10,y:20),screenScale:2,toOwner:{ .init(x:$0.x,y:$0.y) }))
      let layer = try XCTUnwrap(window.layer.sublayers?.last as? CAShapeLayer)
      XCTAssertEqual(layer.name,"notebook-tool-feedback")
      contact.move(to:.init(x:110,y:120))
      XCTAssertEqual(layer.path?.boundingBoxOfPath,.init(x:30,y:60,width:100,height:100))
      XCTAssertTrue(model.inputGate.hasActivePencil)
      contact.finish(cancelled:true)
      XCTAssertNil(layer.superlayer); XCTAssertFalse(model.inputGate.hasActivePencil)
    }
  }

  func testAuthoredToolsPersistOnPageBoardAndCoverThroughOneUndoQueue() async throws {
    try await fixture { model in
      let page = try XCTUnwrap(model.activePage), board = try XCTUnwrap(model.presence?.boardID)
      let item = try XCTUnwrap(model.workspace?.selectedItemID)
      let addresses: [NotebookToolAddress] = [
        .init(surface:.page(page.id),boardID:nil,worldOrigin:nil,bounds:.init(x:0,y:0,width:page.size.width,height:page.size.height)),
        .init(surface:.board(board),boardID:board,worldOrigin:.zero,bounds:nil),
        .init(surface:.cover(item),boardID:board,worldOrigin:nil,bounds:.init(x:0,y:0,width:600,height:800))]
      for address in addresses {
        for tool in [DrawingTool.shape,.connector,.ruler] {
          model.selectDrawingTool(tool)
          XCTAssertTrue(model.drawingTools.begin(at:.init(x:80,y:100),address:address,screenScale:1))
          model.drawingTools.move(to:.init(x:260,y:210)); model.drawingTools.finish()
          await assertSaved(model)
          await model.reloadExternalChanges()?.value
        }
        model.selectDrawingTool(.text)
        XCTAssertTrue(model.drawingTools.begin(at:.init(x:160,y:280),address:address,screenScale:1))
        model.drawingTools.finish(); model.drawingTools.textDraft?.text = "Текст на своей поверхности"
        model.drawingTools.saveText(); XCTAssertNil(model.drawingTools.textDraft)
        await assertSaved(model); await model.reloadExternalChanges()?.value
      }
      let saved = try model.store.loadPage(page.id)
      XCTAssertEqual(saved.elements.count,4); XCTAssertEqual(saved.elements.last?.kind,.nativeText)
      XCTAssertEqual(saved.elements.last?.textStyle?.fontSize,24)
      XCTAssertEqual(try model.store.loadBoard(items:model.store.loadIndex().items).board(board)?.elements.count,8)
      let action = try XCTUnwrap(model.store.collaborationActions(afterID:nil).first { $0.action.summary == "Добавить текст" })
      model.undoCollaboration(action.id); await assertSaved(model)
      XCTAssertEqual(try model.store.loadBoard(items:model.store.loadIndex().items).board(board)?.elements.count,7)
    }
  }

  func testLassoRetainsPressureCutsCopyRotationAndOriginalJournal() async throws {
    try await fixture { model in
      var page = try XCTUnwrap(model.activePage)
      func sample(_ x:Double,_ y:Double,_ width:Double = 8,_ opacity:Double = 1) -> SpatialInkSample {
        .init(point:.init(x:x,y:y),timeOffset:0,width:width,opacity:opacity,force:opacity,azimuth:0,altitude:.pi/2)
      }
      let stroke = PageInkAction(tool:.pen,color:.init(red:0,green:0.2,blue:0.8),samples:[sample(100,100,8,0.2),sample(200,100,8,0.9)])
      let eraser = PageInkAction(tool:.eraser,samples:[sample(150,80,18),sample(150,120,18)])
      let drawing = PageInkDrawing(actions:[stroke,eraser])
      let data = try drawing.dataRepresentation(); XCTAssertTrue(page.replaceDrawing(data,actor:model.actorID))
      try model.store.savePage(page); await model.reloadExternalChanges()?.value
      let polygon = [SpatialPoint(x:80,y:60),.init(x:220,y:60),.init(x:220,y:140),.init(x:80,y:140)]
      let selection = try XCTUnwrap(NotebookLassoInkSource.page(page).selection(polygon:polygon,surface:.page(page.id),origin:nil,bounds:nil))
      let ink = try XCTUnwrap(selection.graphic.freehand)
      XCTAssertFalse(ink.layers.filter { $0.tool == .eraser }.isEmpty)
      XCTAssertLessThan(ink.layers[0].vertices.map(\.opacity).min()!,0.3)
      XCTAssertGreaterThan(ink.layers[0].vertices.map(\.opacity).max()!,0.8)
      let size = CGSize(width:selection.frame.width,height:selection.frame.height)
      let paint = ink.paintPath(size:size,transform:nil)
      XCTAssertTrue(paint.contains(.init(x:110-selection.frame.x,y:100-selection.frame.y)))
      XCTAssertFalse(paint.contains(.init(x:150-selection.frame.x,y:100-selection.frame.y)))
      let address = NotebookToolAddress(surface:.page(page.id),boardID:nil,worldOrigin:nil,bounds:nil)
      let object = NotebookWorkingGraphic(id:UUID(),surface:address.surface,frame:selection.frame,worldOrigin:nil,graphic:selection.graphic)
      XCTAssertTrue(model.acceptAuthoredGraphic(object,at:address,expectedInkRevision:page.drawingStamp.revision))
      await assertSaved(model); await model.reloadExternalChanges()?.value
      model.selectElements([address.reference(object.id)])
      model.transformGraphicSelection(radians:.pi/2)
      await assertSaved(model); await model.reloadExternalChanges()?.value
      model.duplicateGraphicSelection()
      await assertSaved(model); await model.reloadExternalChanges()?.value
      let saved = try model.store.loadPage(page.id)
      XCTAssertEqual(saved.drawingData,data,"Manipulation never rewrites immutable measured samples")
      XCTAssertEqual(saved.elements.count,2)
      XCTAssertEqual(saved.elements[0].graphic?.sourceInkIDs,[stroke.id])
      XCTAssertTrue(saved.elements[1].graphic?.sourceInkIDs.isEmpty == true)
      XCTAssertEqual(saved.elements[0].graphic?.freehand,saved.elements[1].graphic?.freehand)
      XCTAssertNotNil(saved.elements[0].graphic?.transform)
      let actualFrame = saved.elements[0].frame
      let actual = NotebookGraphicGeometry.paintPath(saved.elements[0].graphic!,layout:nil,size:.init(width:actualFrame.width,height:actualFrame.height))
      XCTAssertFalse(actual.contains(.init(x:actualFrame.width/2,y:actualFrame.height/2)),"The cut rotates with ink")
    }
  }

  private func assertSaved(_ model: NotebookAppModel, file: StaticString = #filePath, line: UInt = #line) async {
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved,model.persistenceFailure ?? "",file:file,line:line)
  }

  private func fixture(_ body: (NotebookAppModel) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("drawing-tools-\(UUID())")
    let model = NotebookAppModel(store:.init(root:root),startsNearbySync:false,preferences:UserDefaults(suiteName:UUID().uuidString)!)
    retainNotebookUntilTeardown(model,removing:root)
    await model.start(pageSize:NotebookAppModel.defaultPageSize); await model.finishPendingPersistence()
    try await body(model)
  }

}

@MainActor private final class DrawingToolPencilTouch: UITouch {
  var point = CGPoint(x:100,y:100)
  var sampleTime: TimeInterval = 1
  var pressure: CGFloat = 1
  override var type: UITouch.TouchType { .pencil }
  override var timestamp: TimeInterval { sampleTime }
  override var force: CGFloat { pressure }
  override var maximumPossibleForce: CGFloat { 1 }
  override var altitudeAngle: CGFloat { .pi/2 }
  override func preciseLocation(in view: UIView?) -> CGPoint { point }
  override func location(in view: UIView?) -> CGPoint { point }
  override func azimuthAngle(in view: UIView?) -> CGFloat { 0 }
}

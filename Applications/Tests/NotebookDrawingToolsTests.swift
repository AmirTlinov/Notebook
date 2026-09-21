import NotebookCore
import XCTest
import UIKit
@testable import Notebook

@MainActor final class NotebookDrawingToolsTests: XCTestCase {
  func testObjectLassoReadsAuthoredCutsWithoutDependingOnPaintCache() async throws {
    try await fixture { model in
      var page = try XCTUnwrap(model.activePage)
      let frame = PageRect(x: 100, y: 200, width: 200, height: 120)
      let graphic = NotebookGraphic(shape: .rectangle, style: .init(strokeWidth: 4, fill: .black))
      let element = AgentElement(id: "cold-cut", kind: .graphic, frame: frame, source: "", html: "", graphic: graphic)
      XCTAssertTrue(page.replaceElements([element], actor: model.actorID))
      let cut = PageInkAction(tool: .eraser, samples: [200.0, 320.0].map {
        .init(point: .init(x: 100, y: $0), timeOffset: 0, width: 40, opacity: 1,
          force: 1, azimuth: 0, altitude: .pi / 2)
      }).erasingElements([.init(elementID: element.id, frame: frame)])
      XCTAssertTrue(page.replaceDrawing(try PageInkDrawing(actions: [cut]).dataRepresentation(), actor: model.actorID))
      try model.store.savePage(page); await model.reloadExternalChanges()?.value
      let address = NotebookToolAddress(surface: .page(page.id), boardID: nil, worldOrigin: nil, bounds: nil)
      model.selectDrawingTool(.lasso)
      model.drawingToolSettings.lassoMode = .elements
      let polygon = [SpatialPoint(x: 90, y: 190), .init(x: 310, y: 190), .init(x: 310, y: 330), .init(x: 90, y: 330)]
      let preparations = model.elementErasureCache.preparationCount
      XCTAssertTrue(model.drawingTools.begin(at: polygon[0], address: address, screenScale: 1))
      for point in polygon.dropFirst() { model.drawingTools.move(to: point) }
      model.drawingTools.finish()
      let deadline = ContinuousClock.now + .seconds(2)
      while !model.selectionSession.contains(address.reference(element.id)), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      XCTAssertEqual(model.elementErasureCache.preparationCount, preparations)
      XCTAssertTrue(model.selectionSession.contains(address.reference(element.id)),
        "Selection reads authored geometry directly, before any paint cache exists")

      // Only the removed strip intersects this second polygon.
      let removed = [SpatialPoint(x: 101, y: 230), .init(x: 110, y: 230), .init(x: 110, y: 270), .init(x: 101, y: 270)]
      XCTAssertTrue(model.drawingTools.begin(at: removed[0], address: address, screenScale: 1))
      for point in removed.dropFirst() { model.drawingTools.move(to: point) }
      model.drawingTools.finish()
      XCTAssertTrue(model.selectionSession.elements.isEmpty)

      // Evicting derived paint paths emulates reopening. Selection remains a
      // geometry query and never schedules a paint-cache preparation.
      model.elementErasureCache.retain(pages: [:])
      XCTAssertTrue(model.drawingTools.begin(at: polygon[0], address: address, screenScale: 1))
      for point in polygon.dropFirst() { model.drawingTools.move(to: point) }
      model.drawingTools.finish()
      XCTAssertTrue(model.selectionSession.contains(address.reference(element.id)))
      XCTAssertNil(model.elementErasureCache.pendingPreparation(surface: address.surface, id: element.id))
    }
  }

  func testTextEditorIsAdmittedBeforeInsertPublicationAndKeepsEarlyStyledTyping() async throws {
    try await fixture { model in
      let page = try XCTUnwrap(model.activePage)
      let address = NotebookToolAddress(surface:.page(page.id),boardID:nil,worldOrigin:nil,
        bounds:.init(x:0,y:0,width:page.size.width,height:page.size.height))
      var settings = model.drawingToolSettings; settings.textFontName = "Georgia"
      model.drawingToolSettings = settings
      let id = try XCTUnwrap(model.beginToolText(at:.init(x:80,y:120),address:address,screenScale:1))
      let target = try XCTUnwrap(model.selectionSession.nativeText)
      XCTAssertTrue(model.selectionSession.isInteractive)
      XCTAssertEqual(target.reference,address.reference(id)); XCTAssertEqual(target.frame.x,80)
      XCTAssertEqual(target.frame.y,120); XCTAssertEqual(target.style.format?.fontName,"Georgia")
      XCTAssertFalse(model.activePage?.elements.contains { $0.id == id } ?? false,
        "The editable target exists synchronously before the addressed insert publishes")
      var style = target.style
      style.runs = [.init(location:0,length:5,format:.init(fontName:"Georgia",bold:true,italic:true,link:"https://example.com"))]
      model.commitNativeText(reference:target.reference,text:"Hello",finish:true,style:style,draftTarget:target)
      model.clearSelection()
      await assertSaved(model)
      let saved = try XCTUnwrap(model.store.loadPage(page.id).elements.first { $0.id == id })
      XCTAssertEqual(saved.source,"Hello"); XCTAssertEqual(saved.textStyle,style)
    }
  }
  func testEmptyTextNeverPersistsAndQueuedTypingThenDeleteHasOneOwner() async throws {
    try await fixture { model in
      let page = try XCTUnwrap(model.activePage)
      let address = NotebookToolAddress(surface:.page(page.id),boardID:nil,worldOrigin:nil,bounds:nil)
      let empty = try XCTUnwrap(model.beginToolText(at:.init(x:40,y:40),address:address,screenScale:1))
      let abandoned = try XCTUnwrap(model.selectionSession.nativeText)
      model.clearSelection()
      model.commitNativeText(reference:address.reference(empty),text:"",finish:true,draftTarget:abandoned)
      await assertSaved(model)
      XCTAssertTrue(try model.store.loadPage(page.id).elements.isEmpty)
      let id = try XCTUnwrap(model.beginToolText(at:.init(x:40,y:40),address:address,screenScale:1))
      model.commitNativeText(reference:address.reference(id),text:"First",finish:false)
      model.commitNativeText(reference:address.reference(id),text:"Second",finish:true)
      model.deleteElement(address.reference(id))
      await assertSaved(model)
      XCTAssertTrue(try model.store.loadPage(page.id).elements.isEmpty,"Deletion follows accepted typing, never a competing page snapshot")
    }
  }

  func testTextToolSelectsExistingTextAndWholeObjectFormattingUsesSameContent() async throws {
    try await fixture { model in
      let page = try XCTUnwrap(model.activePage)
      let address = NotebookToolAddress(surface:.page(page.id),boardID:nil,worldOrigin:nil,bounds:nil)
      let id = try XCTUnwrap(model.beginToolText(at:.init(x:100,y:100),address:address,screenScale:1))
      model.commitNativeText(reference:address.reference(id),text:"Styled",finish:true)
      await assertSaved(model); await model.reloadExternalChanges()?.value
      model.clearSelection()
      XCTAssertNil(model.beginToolText(at:.init(x:110,y:110),address:address,screenScale:1))
      XCTAssertEqual(model.selectionSession.element,address.reference(id))
      XCTAssertFalse(model.selectionSession.isInteractive)
      model.formatNativeText(address.reference(id)) { $0.bold = true }
      model.formatNativeText(address.reference(id)) { $0.italic = true }
      await assertSaved(model)
      let saved = try XCTUnwrap(model.store.loadPage(page.id).elements.first)
      XCTAssertEqual(saved.source,"Styled"); XCTAssertEqual(saved.textStyle?.format?.bold,true)
      XCTAssertEqual(saved.textStyle?.format?.italic,true)
      XCTAssertEqual(try model.store.loadPage(page.id).elements.count,1)
    }
  }

  func testLassoSelectionIsReadOnlyUntilEditAndCanCutTheRemainderAgain() async throws {
    try await fixture { model in
      var page=try XCTUnwrap(model.activePage)
      func sample(_ x:Double,_ y:Double)->SpatialInkSample {
        .init(point:.init(x:x,y:y),timeOffset:0,width:8,opacity:1,force:1,azimuth:0,altitude:.pi/2)
      }
      let pen=PageInkAction(tool:.pen,samples:[sample(100,100),sample(220,100)])
      let drawing=try PageInkDrawing(actions:[pen]).dataRepresentation()
      XCTAssertTrue(page.replaceDrawing(drawing,actor:model.actorID));try model.store.savePage(page)
      await model.reloadExternalChanges()?.value
      let address=NotebookToolAddress(surface:.page(page.id),boardID:nil,worldOrigin:nil,bounds:nil)
      let text=try XCTUnwrap(model.beginToolText(at:.init(x:120,y:120),address:address,screenScale:1))
      model.commitNativeText(reference:address.reference(text),text:"Object",finish:true)
      await assertSaved(model);await model.reloadExternalChanges()?.value
      model.selectDrawingTool(.lasso);model.drawingToolSettings.lassoMode = .region
      @MainActor func lasso(_ polygon:[SpatialPoint]) {
        XCTAssertTrue(model.drawingTools.begin(at:polygon[0],address:address,screenScale:1))
        for point in polygon.dropFirst() { model.drawingTools.move(to:point) };model.drawingTools.finish()
      }
      let left=[SpatialPoint(x:90,y:90),.init(x:150,y:90),.init(x:150,y:110),.init(x:90,y:110)]
      lasso(left)
      let deadline = ContinuousClock.now + .seconds(5)
      while model.selectionSession.region == nil,ContinuousClock.now < deadline { try await Task.sleep(for:.milliseconds(10)) }
      let region=try XCTUnwrap(model.selectionSession.region)
      XCTAssertEqual(region.rawInk?.graphic.sourceInkIDs,[pen.id])
      XCTAssertEqual(try model.store.loadPage(page.id).drawingData,drawing)
      XCTAssertEqual(try model.store.loadPage(page.id).elements.count,1,"Selection itself must not author content")
      model.deleteElement(region.reference)
      await assertSaved(model);await model.reloadExternalChanges()?.value
      let saved=try model.store.loadPage(page.id)
      XCTAssertEqual(saved.drawingData,drawing)
      XCTAssertEqual(saved.elements.filter { $0.graphic?.visible == true }.count,1,"Only the compact outside relation remains visible")

      let right=[SpatialPoint(x:180,y:90),.init(x:230,y:90),.init(x:230,y:110),.init(x:180,y:110)]
      let firstSelection=model.selectionSession.id
      lasso(right)
      let secondDeadline = ContinuousClock.now + .seconds(5)
      while model.selectionSession.id == firstSelection,ContinuousClock.now < secondDeadline { try await Task.sleep(for:.milliseconds(10)) }
      let second=try XCTUnwrap(model.selectionSession.region)
      XCTAssertNil(second.rawInk,"The original journal is already claimed")
      XCTAssertFalse(second.graphics.isEmpty,"A retained remainder must be lassoable again")

      model.drawingToolSettings.lassoMode = .elements
      let object=[SpatialPoint(x:115,y:115),.init(x:145,y:115),.init(x:145,y:150),.init(x:115,y:150)]
      lasso(object)
      XCTAssertTrue(model.selectionSession.contains(address.reference(text)),"Whole-object selection is a separate mode")

      var next=try model.store.loadPage(page.id)
      let raw=PageInkAction(tool:.pen,samples:[sample(350,200),sample(450,200)])
      let ink=try PageInkDrawing.decode(next.drawingData).appending(raw)
      XCTAssertTrue(next.replaceDrawing(try ink.dataRepresentation(),actor:model.actorID));try model.store.savePage(next)
      await model.reloadExternalChanges()?.value
      let previousSelection=model.selectionSession.id
      model.drawingTools.selectInk(at:.init(x:400,y:200),address:address,screenScale:1)
      let tapDeadline = ContinuousClock.now + .seconds(5)
      while model.selectionSession.id == previousSelection,ContinuousClock.now < tapDeadline {
        try await Task.sleep(for:.milliseconds(10))
      }
      XCTAssertEqual(model.selectionSession.region?.rawInk?.graphic.sourceInkIDs,[raw.id])
      XCTAssertEqual(try model.store.loadPage(page.id).drawingData,try ink.dataRepresentation())
    }
  }

  func testLassoMaterializesAGroupedRegionInPlaceWithItsTightFrame() async throws {
    try await fixture { model in
      var page=try XCTUnwrap(model.activePage)
      let group=AgentElement(id:"rotated-group",kind:.group,
        frame:.init(x:200,y:200,width:200,height:100),source:"",html:"",
        basis:.init(size:.init(x:200,y:100),transform:.init(a:0,b:1,c:-1,d:0,tx:1,ty:0)))
      let measurements=InkMeasurements([
        .init(point:.init(x:10,y:30),timeOffset:0,width:8,opacity:1,force:1,azimuth:0,altitude:.pi/2),
        .init(point:.init(x:150,y:30),timeOffset:1,width:8,opacity:1,force:1,azimuth:0,altitude:.pi/2)])
      let freehand=NotebookFreehand(layers:[.init(tool:.pen,color:.black,measured:.init(
        sourceID:UUID(),measurements:measurements,frame:.init(x:0,y:0,width:160,height:60)))])
      let child=AgentElement(id:"grouped-ink",kind:.graphic,frame:.init(x:20,y:20,width:160,height:60),
        source:"",html:"",graphic:.init(shape:.freehand,freehand:freehand),parentID:group.id)
      XCTAssertTrue(page.replaceElements([group,child],actor:model.actorID));try model.store.savePage(page)
      await model.reloadExternalChanges()?.value
      let address=NotebookToolAddress(surface:.page(page.id),boardID:nil,worldOrigin:nil,bounds:nil)
      let source=address.reference(child.id),layout=try XCTUnwrap(model.graphicLayout(source))
      let f=layout.frame,polygon=[SpatialPoint(x:f.x,y:f.y),.init(x:f.x+f.width/2,y:f.y),
        .init(x:f.x+f.width/2,y:f.y+f.height),.init(x:f.x,y:f.y+f.height)]
      func placed(_ point:SpatialPoint,_ layout:NotebookGraphicLayout)->CGPoint {
        let p=layout.displayedPoint(point)
        return .init(x:layout.frame.x+p.x,y:layout.frame.y+p.y)
      }
      let probes=[SpatialPoint.zero,.init(x:160,y:0),.init(x:0,y:60),.init(x:160,y:60)]
      let expected=probes.map { placed($0,layout) }
      model.selectRegion(.init(id:UUID(),address:address,polygon:polygon,
        frame:.init(x:f.x,y:f.y,width:f.width/2,height:f.height),rawInk:nil,
        expectedInkRevision:nil,graphics:[source]))
      let selected=try XCTUnwrap(model.materializeRegionSelection()?.first)
      let live=try XCTUnwrap(model.acceptedWorkingGraphic(selected))
      XCTAssertNotNil(live.basis,"The accepted preview owns the same detached basis as durable content")
      XCTAssertEqual(live.frame.width,f.width,accuracy:0.000001)
      await assertSaved(model);await model.reloadExternalChanges()?.value
      let savedPage=try model.store.loadPage(page.id)
      let saved=try XCTUnwrap(savedPage.element(id:selected.elementID))
      XCTAssertNil(saved.parentID);XCTAssertNotNil(saved.basis)
      let placedLayout=try XCTUnwrap(model.graphicGraph(page:savedPage,preview:false).resolve(selected.elementID).layout)
      let visible=try XCTUnwrap(placedLayout.visibleFrame(mask:try XCTUnwrap(saved.graphic?.mask)))
      XCTAssertEqual(visible.width,f.width/2,accuracy:0.000001)
      for (actual,wanted) in zip(probes.map { placed($0,placedLayout) },expected) {
        XCTAssertEqual(actual.x,wanted.x,accuracy:0.000001)
        XCTAssertEqual(actual.y,wanted.y,accuracy:0.000001)
      }
    }
  }

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
    let line = try XCTUnwrap(NotebookToolGeometry.connection(from:.init(x:80,y:70),to:.init(x:10,y:20),width:2))
    XCTAssertEqual(line.connection?.start.point,.init(x:70,y:50)); XCTAssertEqual(line.connection?.end.point,.zero)
    XCTAssertEqual(line.connection?.endArrowhead,.arrow)
    let address = NotebookToolAddress(surface:.page(UUID()),boardID:nil,worldOrigin:nil,bounds:nil)
    let ruler = NotebookRuler(address:address,start:.init(x:10,y:20),angle:90,length:PhysicalPaper.pointsPerCentimeter*10)
    let point = ruler.project(.init(x:87,y:20+PhysicalPaper.pointsPerCentimeter),from:address,snap:true)
    XCTAssertEqual(point.x,10,accuracy:0.000001)
    XCTAssertEqual(point.y,20+PhysicalPaper.gridSpacing*2,accuracy:0.000001)
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

  func testInlineTextKeepsItsTappedOriginAndScreenSizeAtDeepZoom() async throws {
    try await fixture { model in
      let board = try XCTUnwrap(model.presence?.boardID)
      let origin = WorldPoint.zero.offsetBy(x:2000,y:-8000)
      let address = NotebookToolAddress(surface:.board(board),boardID:board,worldOrigin:origin,bounds:nil)
      let id = try XCTUnwrap(model.beginToolText(at:.init(x:0,y:0),address:address,screenScale:0.03787425024543671))
      XCTAssertTrue(model.selectionSession.isInteractive)
      await assertSaved(model); await model.reloadExternalChanges()?.value
      XCTAssertNil(try model.store.readSpatialElement(boardID:board,elementID:id),"Empty drafts never enter the store")
      let target = try XCTUnwrap(model.selectionSession.nativeText)
      XCTAssertEqual(target.address.worldOrigin,origin)
      XCTAssertEqual(target.frame.x,0); XCTAssertEqual(target.frame.y,0)
      XCTAssertEqual(target.style.fontSize*0.03787425024543671,24,accuracy:0.000001)
      let fitted = PageRect(x:0,y:0,width:target.frame.width,height:target.style.fontSize*2.5)
      model.commitNativeText(reference:address.reference(id),text:"Plain **text**",finish:false,height:fitted.height)
      await assertSaved(model)
      let saved = try XCTUnwrap(model.store.loadBoard(items:model.store.loadIndex().items).board(board)?.elements.first { $0.id == id })
      XCTAssertEqual(saved.source,"Plain **text**"); XCTAssertEqual(saved.kind,.nativeText)
      XCTAssertEqual(saved.frame.height,fitted.height)
      model.commitNativeText(reference:address.reference(id),text:"",finish:true)
      await assertSaved(model)
      XCTAssertFalse(try model.store.loadBoard(items:model.store.loadIndex().items).board(board)?.elements.contains { $0.id == id } ?? true)
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
        model.drawingTools.finish()
        let reference = try XCTUnwrap(model.selectionSession.element)
        XCTAssertTrue(model.selectionSession.isInteractive)
        await assertSaved(model); await model.reloadExternalChanges()?.value
        model.commitNativeText(reference:reference,text:"Текст на своей поверхности",finish:true)
        await assertSaved(model); await model.reloadExternalChanges()?.value
      }
      let saved = try model.store.loadPage(page.id)
      XCTAssertEqual(saved.elements.count,4); XCTAssertEqual(saved.elements.last?.kind,.nativeText)
      XCTAssertEqual(saved.elements.last?.textStyle?.fontSize,24)
      XCTAssertEqual(try model.store.loadBoard(items:model.store.loadIndex().items).board(board)?.elements.count,8)
      let actions = try model.store.collaborationActions(afterID:nil)
      let action = try XCTUnwrap(actions.first { $0.action.summary == "Добавить текст" })
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
      let opacity=try XCTUnwrap(ink.layers[0].measured).measurements.materialized().map(\.opacity)
      XCTAssertLessThan(try XCTUnwrap(opacity.min()),0.3)
      XCTAssertGreaterThan(try XCTUnwrap(opacity.max()),0.8)
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
      // Ordinary undo owns all three accepted actions: copy, first rotation,
      // then conversion. Returning an optional basis to nil is not adoption.
      for _ in 0..<3 {
        model.undoLastSurfaceAction();await assertSaved(model);await model.reloadExternalChanges()?.value
      }
      let restored=try NotebookStore(root:model.store.root).loadPage(page.id)
      XCTAssertTrue(restored.graphicPresentation.suppressedInkIDs.isEmpty)
      XCTAssertEqual(restored.drawingData,data)
      XCTAssertEqual(restored.elements.first?.graphic?.freehand,ink)
    }
  }

  func testElementSelectionRequiresWholeBoundsInsideLoop() async throws {
    let polygon = [SpatialPoint(x:90,y:90),.init(x:110,y:90),.init(x:110,y:110),.init(x:90,y:110)]
    XCTAssertTrue(NotebookToolGeometry.intersects(.init(x:100,y:100,width:200,height:200),polygon:polygon))
    XCTAssertTrue(NotebookToolGeometry.intersects(.init(x:0,y:0,width:200,height:200),polygon:polygon))
    XCTAssertTrue(NotebookToolGeometry.intersects(from:.init(x:0,y:100),to:.init(x:200,y:100),polygon:polygon))
    XCTAssertFalse(NotebookToolGeometry.intersects(.init(x:120,y:120,width:20,height:20),polygon:polygon))
    XCTAssertFalse(NotebookToolGeometry.encloses(.init(x:0,y:0,width:200,height:200),polygon:polygon))
    XCTAssertTrue(NotebookToolGeometry.encloses(.init(x:92,y:92,width:16,height:16),polygon:polygon))
    try await fixture { model in
      let page = try XCTUnwrap(model.activePage)
      let address = NotebookToolAddress(surface:.page(page.id),boardID:nil,worldOrigin:nil,bounds:nil)
      let text = try XCTUnwrap(model.beginToolText(at:.init(x:100,y:100),address:address,screenScale:1))
      model.commitNativeText(reference:address.reference(text),text:"Lasso",finish:true)
      await assertSaved(model); await model.reloadExternalChanges()?.value
      let enclosing = [SpatialPoint(x:80,y:80),.init(x:500,y:80),.init(x:500,y:200),.init(x:80,y:200)]
      let refs = model.elementsIntersecting(enclosing,at:address,graph:.init([]))
      XCTAssertTrue(refs.contains(address.reference(text)))
      model.selectDrawingTool(.lasso)
      model.drawingToolSettings.lassoMode = .elements
      XCTAssertTrue(model.drawingTools.begin(at:enclosing[0],address:address,screenScale:1))
      for point in enclosing.dropFirst() { model.drawingTools.move(to:point) }
      model.drawingTools.finish()
      XCTAssertTrue(model.selectionSession.contains(address.reference(text)))
    }
  }

  func testLaserExpiresFromOldestToNewestAndRetainsWorldWidth() {
    let address = NotebookToolAddress(surface:.board(UUID()),boardID:nil,worldOrigin:.zero,bounds:nil)
    let trace = NotebookLaserTrace(id:UUID(),address:address,color:.red,width:40,lifetime:0.6,
      samples:[.init(point:.init(x:0,y:0),time:0),.init(point:.init(x:100,y:0),time:0.2),.init(point:.init(x:200,y:0),time:0.4)])
    let visible = trace.points(at:0.7)
    XCTAssertEqual(visible.first!.x,50,accuracy:0.00001)
    XCTAssertEqual(visible.last!.x,200)
    XCTAssertTrue(trace.points(at:1.01).isEmpty)
    XCTAssertEqual(trace.width*0.1,4); XCTAssertEqual(trace.width*0.05,2)
  }

  func testPencilEraserDiameterDoesNotPumpWithPressure() {
    let paper = PaperInputView(frame:.init(x:0,y:0,width:500,height:500))
    paper.configure(penStyle:.standard,eraserStyle:.init(maximumWidth:80),drawingTool:.eraser)
    let touch = DrawingToolPencilTouch()
    var accepted: PageInkAction?
    paper.onDrawingMutation = { accepted = $0 }
    touch.pressure = 0.01; paper.touchesBegan([touch],with:nil)
    for force in [0.9,0.03,1,0.05,0.5] {
      touch.pressure = force; touch.sampleTime += 0.02; touch.point.x += 10
      paper.touchesMoved([touch],with:nil)
    }
    paper.touchesEnded([touch],with:nil)
    XCTAssertNotNil(accepted)
    XCTAssertTrue(accepted?.samples.allSatisfy { abs($0.width-80) < 0.001 } == true)
  }

  func testShapeSubtractionPersistsOneEditableContourAndUndoRestoresRectangle() async throws {
    try await fixture { model in
      let page = try XCTUnwrap(model.activePage)
      let address = NotebookToolAddress(surface:.page(page.id),boardID:nil,worldOrigin:nil,bounds:nil)
      let original = NotebookWorkingGraphic(id:UUID(),surface:address.surface,frame:.init(x:80,y:80,width:240,height:220),worldOrigin:nil,
        graphic:.init(shape:.rectangle,style:.init(strokeWidth:2,fill:.black)))
      XCTAssertTrue(model.acceptAuthoredGraphic(original,at:address)); await assertSaved(model); await model.reloadExternalChanges()?.value
      let cutter = NotebookWorkingGraphic(id:UUID(),surface:address.surface,frame:.init(x:140,y:140,width:80,height:70),worldOrigin:nil,
        graphic:.init(shape:.ellipse,style:.init(stroke:.init(red:1,green:0,blue:0),strokeWidth:2,fill:.init(red:1,green:1,blue:0))))
      model.combineAuthoredShape(cutter,at:address,graph:model.graphicGraph(page:try XCTUnwrap(model.activePage),preview:false),operation:.subtract)
      await assertSaved(model); await model.reloadExternalChanges()?.value
      let edited = try XCTUnwrap(model.store.loadPage(page.id).elements.first { $0.id == original.id })
      XCTAssertEqual(edited.graphic?.shape,.path)
      XCTAssertNotEqual(edited.graphic?.style.stroke,edited.graphic?.style.fill)
      let paint = NotebookGraphicGeometry.paintPath(try XCTUnwrap(edited.graphic),layout:nil,size:.init(width:edited.frame.width,height:edited.frame.height))
      XCTAssertFalse(paint.contains(.init(x:180-edited.frame.x,y:170-edited.frame.y)))
      model.undoLastSurfaceAction(); await assertSaved(model); await model.reloadExternalChanges()?.value
      XCTAssertEqual(try model.store.loadPage(page.id).elements.first { $0.id == original.id }?.graphic?.shape,.rectangle)
    }
  }

  func testImmediateBooleanContactsUseAcceptedGeometryBeforePublication() async throws {
    try await fixture { model in
      let page = try XCTUnwrap(model.activePage), board = try XCTUnwrap(model.presence?.boardID)
      let item = try XCTUnwrap(model.workspace?.selectedItemID)
      for address in [NotebookToolAddress(surface:.page(page.id),boardID:nil,worldOrigin:nil,bounds:nil),
        .init(surface:.board(board),boardID:board,worldOrigin:.zero,bounds:nil),
        .init(surface:.cover(item),boardID:board,worldOrigin:nil,bounds:nil)] {
        model.selectDrawingTool(.shape)
        model.drawingToolSettings.shapeFilled = true
        @MainActor func draw(_ operation: NotebookShapeOperation, _ start: SpatialPoint, _ end: SpatialPoint) {
          model.drawingToolSettings.shapeOperation = operation
          XCTAssertTrue(model.drawingTools.begin(at:start,address:address,screenScale:1))
          model.drawingTools.move(to:end); model.drawingTools.finish()
        }
        @MainActor func graph() -> NotebookGraphicGraph {
          address.surface.kind == .page ? model.graphicGraph(page:model.pages[page.id]!) : model.authoredGraphicGraph(boardID:board)
        }
        draw(.normal,.init(x:80,y:80),.init(x:300,y:300))
        let original = try XCTUnwrap(graph().nodes.values.first { $0.surface == address.surface && $0.shown && $0.graphic.showsGeometry })
        for (operation,start,end) in [(NotebookShapeOperation.union,SpatialPoint(x:260,y:100),SpatialPoint(x:420,y:260)),
          (.subtract,.init(x:130,y:130),.init(x:170,y:170)),
          (.intersect,.init(x:180,y:100),.init(x:380,y:280)),
          (.exclude,.init(x:300,y:140),.init(x:440,y:240))] {
          draw(operation,start,end)
          XCTAssertEqual(graph().nodes.values.filter { $0.surface == address.surface && $0.shown && $0.graphic.showsGeometry }.count,1)
          XCTAssertEqual(graph().nodes[original.id]?.graphic.shape,.path)
        }
        let expected = try XCTUnwrap(graph().nodes[original.id])
        await assertSaved(model); await model.reloadExternalChanges()?.value
        let saved = address.surface.kind == .page ? try model.store.loadPage(page.id).elements.first { $0.id == original.id }?.graphic
          : try model.store.readSpatialElement(boardID:board,elementID:original.id)?.graphic
        XCTAssertEqual(saved,expected.graphic,"Quick contacts chain accepted predecessors, not whichever raster happened to publish")
        XCTAssertEqual(graph().nodes[original.id]?.graphic,expected.graphic,"An old working insertion retained for raster handoff cannot replace a newer admitted boolean result")
        XCTAssertEqual(model.graphicElement(address.reference(original.id)),expected.graphic)
        draw(.subtract,.init(x:600,y:600),.init(x:700,y:700))
        XCTAssertEqual(graph().nodes.values.filter { $0.surface == address.surface && $0.shown && $0.graphic.showsGeometry }.count,2,"No intersection establishes a new base instead of dropping the drawn shape")
        await assertSaved(model); await model.reloadExternalChanges()?.value
      }
    }
  }

  func testPrimaryColorHasOnePreferenceOwnerAndDoesNotSwitchTools() async throws {
    try await fixture { model in
      for tool in [DrawingTool.pen,.marker,.shape,.text,.connector,.ruler,.laser] {
        model.selectDrawingTool(tool); model.selectDrawingColor(.green)
        XCTAssertEqual(model.drawingTool,tool); XCTAssertEqual(model.drawingColor,.green)
      }
      XCTAssertNotEqual(model.drawingToolSettings.shapeFillColor ?? .yellow,.green)
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

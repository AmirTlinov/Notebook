import AppKit
import NotebookCore
import SwiftUI
import XCTest
@testable import Notebook

@MainActor final class MacMaterialInputTests: XCTestCase {
  func testPassiveMeasuredMaterialReceivesRealWindowClickAndStationaryDragWithoutBoardCohort() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fixture = MacCommandFixture(root:root), model = fixture.model
    retainNotebookUntilTeardown(model,removing:root)
    try await fixture.start(showingPage:true)
    var page = try XCTUnwrap(model.activePage)
    let graphic = measuredCut()
    page.replaceElements([.init(id:"measured",kind:.graphic,frame:.init(x:100,y:120,width:260,height:110),
      source:"",html:"",graphic:graphic)],actor:model.actorID)
    try fixture.store.savePage(page); await model.reloadExternalChanges()?.value
    let host = NSHostingView(rootView:NotebookMacCanvas(documentLayout:.constant(nil)).environment(model))
    let window = NSWindow(contentRect:.init(x:0,y:0,width:900,height:800),styleMask:.borderless,backing:.buffered,defer:false)
    window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
    defer { window.contentView = nil; window.close() }
    try await fixture.waitUntil { self.descendant(MacMaterialInputView.self,in:host) != nil && model.presence?.viewport.x == 900 }
    host.layoutSubtreeIfNeeded()
    let input = try XCTUnwrap(descendant(MacMaterialInputView.self,in:host))
    let reference = EditableElementReference.page(pageID:page.id,elementID:"measured")
    // Desktop reading has no board paint receipt. Both picking and controls
    // must use the same actual paper instead of requiring that unrelated owner.
    XCTAssertNil(model.compositionTiles.published)
    let presence = input.presence
    let box = try XCTUnwrap(NotebookAttentionProjection.readingPaperFrame(model:model,presence:presence))
    let start = CGPoint(x:box.minX+140*presence.camera.scale,y:box.minY+175*presence.camera.scale)
    let windowStart = input.convert(start,to:nil)
    let hit = host.hitTest(host.convert(windowStart,from:nil))
    XCTAssertNotNil(hit)
    XCTAssertTrue(input.hitTest(input.superview!.convert(windowStart,from:nil)) === input)
    // AppKit may return a SwiftUI hosting bridge; dispatch through the window,
    // not directly to our adapter, to prove the actual responder route.
    window.sendEvent(try event(.leftMouseDown,at:windowStart,window:window))
    window.sendEvent(try event(.leftMouseUp,at:windowStart,window:window))
    XCTAssertEqual(model.selectionSession.element,reference)
    let controls = try XCTUnwrap(NotebookAttentionProjection.editingFrame(reference,model:model,presence:presence))
    XCTAssertEqual(controls.minX,box.minX+100*presence.camera.scale,accuracy:0.001)
    window.sendEvent(try event(.leftMouseDown,at:windowStart,window:window))
    for delta in [20.0,40.0,70.0] {
      let moved = CGPoint(x:windowStart.x+delta*presence.camera.scale,y:windowStart.y-30*presence.camera.scale)
      window.sendEvent(try event(.leftMouseDragged,at:moved,window:window))
      let movement = try XCTUnwrap(model.selectionSession.manipulation?.movement)
      XCTAssertEqual(movement.x,delta,accuracy:1e-9); XCTAssertEqual(movement.y,30,accuracy:1e-9)
      host.layoutSubtreeIfNeeded()
    }
    let end = CGPoint(x:windowStart.x+70*presence.camera.scale,y:windowStart.y-30*presence.camera.scale)
    window.sendEvent(try event(.leftMouseUp,at:end,window:window))
    XCTAssertEqual(try XCTUnwrap(model.elementCommandDrafts[reference]?.frame.x),170,accuracy:1e-9,"Lift must accept the shown move before persistence: \(model.actionCue ?? "none")")
    let saved = await model.finishPendingInteraction(); XCTAssertTrue(saved)
    let moved = try XCTUnwrap(fixture.store.loadPage(page.id).element(id:"measured"))
    XCTAssertEqual(moved.frame.x,170,accuracy:1e-9,model.actionCue ?? "none"); XCTAssertEqual(moved.frame.y,150,accuracy:1e-9,model.actionCue ?? "none")
    XCTAssertEqual(moved.frame.width,260); XCTAssertEqual(moved.frame.height,110)
    XCTAssertEqual(moved.graphic,graphic,"Movement cannot rematerialize pressure, color or cuts")
    XCTAssertEqual(model.presence?.camera,presence.camera)
    input.undo(nil)
    let undone = await model.finishPendingInteraction(); XCTAssertTrue(undone)
    XCTAssertEqual(try fixture.store.loadPage(page.id).element(id:"measured")?.frame,page.element(id:"measured")?.frame)
  }

  func testCutAndHollowInteriorRespectLowerPaintAndEmptyMaterialPassesThrough() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fixture = MacCommandFixture(root:root), model = fixture.model
    retainNotebookUntilTeardown(model,removing:root)
    try await fixture.start(showingPage:true)
    var page = try XCTUnwrap(model.activePage)
    page.replaceElements([
      .init(id:"below",kind:.graphic,frame:.init(x:100,y:120,width:260,height:110),source:"",html:"",
        graphic:.init(shape:.rectangle,style:.init(stroke:.black,strokeWidth:1,fill:.black))),
      .init(id:"cut",kind:.graphic,frame:.init(x:100,y:120,width:260,height:110),source:"",html:"",graphic:measuredCut()),
      .init(id:"hollow",kind:.graphic,frame:.init(x:90,y:110,width:280,height:130),source:"",html:"",
        graphic:.init(shape:.rectangle,style:.init(stroke:.black,strokeWidth:2)))
    ],actor:model.actorID)
    try fixture.store.savePage(page); await model.reloadExternalChanges()?.value
    let p = try XCTUnwrap(model.presence)
    let input = MacMaterialInputView(model:model,presence:p,cohort:nil)
    let window = NSWindow(contentRect:.init(x:0,y:0,width:p.viewport.x,height:p.viewport.y),styleMask:.borderless,backing:.buffered,defer:false)
    window.isReleasedWhenClosed = false; window.contentView = input; window.orderBack(nil)
    defer { input.cancel(); window.contentView = nil; window.close() }
    let box = try XCTUnwrap(NotebookAttentionProjection.readingPaperFrame(model:model,presence:p))
    func click(_ x:Double,_ y:Double) throws {
      let point = input.convert(.init(x:box.minX+x*p.camera.scale,y:box.minY+y*p.camera.scale),to:nil)
      input.mouseDown(with:try event(.leftMouseDown,at:point,window:window))
      input.mouseUp(with:try event(.leftMouseUp,at:point,window:window))
    }
    try click(230,175)
    XCTAssertEqual(model.selectionSession.element?.elementID,"below","A true cut and a hollow enclosure cannot steal lower paint")
    try click(140,175)
    XCTAssertEqual(model.selectionSession.element?.elementID,"cut")
    XCTAssertNil(input.hitTest(.init(x:box.minX+450*p.camera.scale,y:box.minY+400*p.camera.scale)),"Paper stays available to camera navigation")
    model.macInputTool = .pen
    XCTAssertNil(input.hitTest(.init(x:box.minX+140*p.camera.scale,y:box.minY+175*p.camera.scale)))
  }

  func testPencilArrivalCancelsMouseAndExplicitEditorKeepsItsContact() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fixture = MacCommandFixture(root:root), model = fixture.model
    retainNotebookUntilTeardown(model,removing:root)
    try await fixture.start(showingPage:true)
    var page = try XCTUnwrap(model.activePage)
    page.replaceElements([.init(id:"text",kind:.nativeText,frame:.init(x:100,y:120,width:260,height:110),
      source:"Editable material",html:"")],actor:model.actorID)
    try fixture.store.savePage(page); await model.reloadExternalChanges()?.value
    let p = try XCTUnwrap(model.presence)
    let input = MacMaterialInputView(model:model,presence:p,cohort:nil)
    let window = NSWindow(contentRect:.init(x:0,y:0,width:p.viewport.x,height:p.viewport.y),styleMask:.borderless,backing:.buffered,defer:false)
    window.isReleasedWhenClosed = false; window.contentView = input; window.orderBack(nil)
    defer { input.cancel(); window.contentView = nil; window.close() }
    let box = try XCTUnwrap(NotebookAttentionProjection.readingPaperFrame(model:model,presence:p))
    let local = CGPoint(x:box.minX+110*p.camera.scale,y:box.minY+130*p.camera.scale)
    let point = input.convert(local,to:nil)
    input.mouseDown(with:try event(.leftMouseDown,at:point,window:window))
    input.mouseDragged(with:try event(.leftMouseDragged,at:.init(x:point.x+20,y:point.y),window:window))
    XCTAssertNotNil(model.selectionSession.manipulation)
    let pencil = UUID(); XCTAssertTrue(model.inputGate.beginPencilAction(source:pencil))
    XCTAssertNil(model.selectionSession.manipulation)
    input.mouseUp(with:try event(.leftMouseUp,at:.init(x:point.x+100,y:point.y),window:window))
    model.inputGate.endPencilAction(source:pencil)
    let saved = await model.finishPendingInteraction(); XCTAssertTrue(saved)
    XCTAssertEqual(try fixture.store.loadPage(page.id).element(id:"text")?.frame,page.element(id:"text")?.frame)
    let reference = EditableElementReference.page(pageID:page.id,elementID:"text")
    model.selectElement(reference); model.editSelectedElement(reference)
    XCTAssertTrue(model.selectionSession.isInteractive)
    XCTAssertNil(input.hitTest(local))
  }

  func testInstalledBoardAndCoverUseTheSameMaterialContactWhileAHoleSelectsTheNotebook() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fixture = MacCommandFixture(root:root), model = fixture.model
    retainNotebookUntilTeardown(model,removing:root)
    try await fixture.start()
    let workspace = try XCTUnwrap(model.workspace), boardID = workspace.rootBoardID, itemID = workspace.selectedItemID
    model.moveItem(itemID,to:.init(x:800,y:0))
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    let graphic = measuredCut()
    XCTAssertEqual(try JSONValue.encode(graphic).decode(NotebookGraphic.self),graphic)
    try await fixture.apply([
      .init(kind:.insertElement,target:.init(kind:.board,id:boardID),id:"board-cut",values:[
        "kind":.string("graphic"),"source":.string(""),"frame":try .encode(PageRect(x:0,y:0,width:260,height:110)),
        "worldOrigin":try .encode(WorldPoint(x:-200,y:0)),"graphic":try .encode(graphic)]),
      .init(kind:.insertElement,target:.init(kind:.cover,id:itemID,boardID:boardID),id:"cover-cut",values:[
        "kind":.string("graphic"),"source":.string(""),"frame":try .encode(PageRect(x:100,y:120,width:260,height:110)),"graphic":try .encode(graphic)])
    ])
    model.updatePresence(.init(boardID:boardID,mode:.board,camera:.init(center:.init(x:300,y:0),scale:0.6),
      viewport:.init(x:1000,y:800)),settled:true)
    let host = NSHostingView(rootView:NotebookMacCanvas(documentLayout:.constant(nil)).environment(model))
    let window = NSWindow(contentRect:.init(x:0,y:0,width:1000,height:800),styleMask:.borderless,backing:.buffered,defer:false)
    window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
    defer { window.contentView = nil; window.close() }
    try await fixture.waitUntil(seconds:8) {
      model.compositionTiles.published?.isPaintInstalled == true && !model.compositionTiles.isPreparing
    }
    let input = try XCTUnwrap(descendant(MacMaterialInputView.self,in:host)), p = input.presence
    func click(_ point:CGPoint) throws {
      let position = input.convert(point,to:nil)
      window.sendEvent(try event(.leftMouseDown,at:position,window:window))
      window.sendEvent(try event(.leftMouseUp,at:position,window:window))
    }
    let boardPoint = p.camera.worldToScreen(.init(x:-160,y:55),viewport:p.viewport)
    try click(.init(x:boardPoint.x,y:boardPoint.y))
    XCTAssertEqual(model.selectionSession.element,.spatial(boardID:boardID,elementID:"board-cut"))
    let paper = model.itemGeometry(itemID).screenFrame(center:.init(x:800,y:0),camera:p.camera,viewport:p.viewport)
    try click(.init(x:paper.x+140*p.camera.scale,y:paper.y+175*p.camera.scale))
    XCTAssertEqual(model.selectionSession.element,.spatial(boardID:boardID,elementID:"cover-cut"))
    let hole = CGPoint(x:paper.x+230*p.camera.scale,y:paper.y+175*p.camera.scale)
    XCTAssertNil(input.hitTest(input.superview!.convert(input.convert(hole,to:nil),from:nil)))
    try click(hole)
    try await fixture.waitUntil { model.selectionSession.itemID(on:boardID) == itemID }
    XCTAssertNil(model.selectionSession.element)
  }

  private func measuredCut() -> NotebookGraphic {
    let frame = PageRect(x:0,y:0,width:260,height:110)
    let samples = (0..<1024).map { i in SpatialInkSample(point:.init(x:10+Double(i)*240/1023,y:55),
      timeOffset:Double(i)/240,width:8,opacity:0.5+Double(i%3)*0.2,force:0.5,azimuth:0.2,altitude:1) }
    let source = InkSampleRelations(sourceID:UUID(),revision:UUID(),samples:samples,header:.init(tool:.pen,color:.init(red:0.1,green:0.4,blue:0.8)))
    let freehand = NotebookFreehand(layers:[.init(tool:.pen,color:.init(red:0.1,green:0.4,blue:0.8),measured:.init(sourceID:source.sourceID,
      measurements:source.measurements,frame:frame)),.init(eraser:.init(size:.init(x:260,y:110),
        samples:[.init(point:.init(x:130,y:10),width:30),.init(point:.init(x:130,y:100),width:30)]))])
    return .init(shape:.freehand,style:.init(stroke:.init(red:0.1,green:0.4,blue:0.8),strokeWidth:1),freehand:freehand)
  }
  private func event(_ type:NSEvent.EventType,at point:CGPoint,window:NSWindow) throws -> NSEvent {
    try XCTUnwrap(NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
      windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1))
  }
  private func descendant<T:NSView>(_ type:T.Type,in view:NSView) -> T? {
    if let value = view as? T { return value }
    return view.subviews.lazy.compactMap { self.descendant(type,in:$0) }.first
  }
}

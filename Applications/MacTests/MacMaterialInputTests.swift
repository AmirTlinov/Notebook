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

  func testSelectedRawBodyUsesRealMouseRouteWithCutsAndVisibleTargetGuards() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fixture=MacCommandFixture(root:root),model=fixture.model
    retainNotebookUntilTeardown(model,removing:root)
    try await fixture.start(showingPage:true)
    var page=try XCTUnwrap(model.activePage)
    let samples=(0..<4_097).map { i in
      SpatialInkSample(point:.init(x:100+260*Double(i)/4_096,y:175),timeOffset:Double(i)/240,
        width:8,opacity:1,force:1,azimuth:0,altitude:.pi/2)
    } + [.init(point:.init(x:360,y:220),timeOffset:18,width:8,opacity:1,force:1,azimuth:0,altitude:.pi/2)]
    let pen=PageInkAction(tool:.pen,samples:samples,sequence:1)
    let cut=PageInkAction(tool:.eraser,samples:[150.0,200].map { y in
      .init(point:.init(x:230,y:y),timeOffset:0,width:30,opacity:1,force:1,azimuth:0,altitude:.pi/2)
    },sequence:2)
    let below=AgentElement(id:"below",kind:.graphic,frame:.init(x:100,y:120,width:100,height:110),source:"",html:"",
      graphic:.init(shape:.rectangle,style:.init(stroke:.black,strokeWidth:1,fill:.black)))
    let peer=AgentElement(id:"peer",kind:.graphic,frame:.init(x:400,y:150,width:50,height:50),source:"",html:"",
      graphic:.init(shape:.ellipse,style:.init(stroke:.black,strokeWidth:1,fill:.black)))
    XCTAssertTrue(page.replaceElements([below,peer],actor:model.actorID))
    XCTAssertTrue(page.replaceDrawing(try PageInkDrawing(actions:[pen,cut]).dataRepresentation(),actor:model.actorID))
    try fixture.store.savePage(page);await model.reloadExternalChanges()?.value
    let host=NSHostingView(rootView:NotebookMacCanvas(documentLayout:.constant(nil)).environment(model))
    let window=NSWindow(contentRect:.init(x:0,y:0,width:900,height:800),styleMask:.borderless,backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false;window.contentView=host;window.center()
    NSApp.activate();window.makeKeyAndOrderFront(nil);window.orderFrontRegardless()
    defer { window.contentView=nil;window.close() }
    try await fixture.waitUntil {
      self.descendant(MacMaterialInputView.self,in:host) != nil && model.presence?.viewport.x == 900
        && model.pageInkPublication.currentCanvas(on:page.id)?.isStableFramePresented == true
    }
    let input=try XCTUnwrap(descendant(MacMaterialInputView.self,in:host))
    let address=NotebookToolAddress(surface:.page(page.id),boardID:nil,worldOrigin:nil,
      bounds:.init(x:0,y:0,width:page.size.width,height:page.size.height))
    // The ordinary closed contour chooses the contact's right side and its
    // authored peer. The rectangle under its left side remains unselected.
    model.selectDrawingTool(.lasso);model.drawingToolSettings.lassoMode = .elements
    let contour=[SpatialPoint(x:300,y:130),.init(x:480,y:130),.init(x:480,y:250),.init(x:300,y:250),.init(x:300,y:130)]
    XCTAssertTrue(model.drawingTools.begin(at:contour[0],address:address,screenScale:input.presence.camera.scale))
    for point in contour.dropFirst() { model.drawingTools.move(to:point) };model.drawingTools.finish()
    try await fixture.waitUntil { model.drawingTools.pendingLasso == nil }
    let raw=try XCTUnwrap(model.selectionSession.ink.first),selectionID=model.selectionSession.id
    XCTAssertEqual(raw.actionID,pen.id)
    XCTAssertEqual(model.selectionSession.elements,[address.reference(peer.id)])
    let p=input.presence,box=try XCTUnwrap(NotebookAttentionProjection.readingPaperFrame(model:model,presence:p))
    func point(_ x:Double,_ y:Double)->CGPoint { .init(x:box.minX+x*p.camera.scale,y:box.minY+y*p.camera.scale) }
    func selected(_ point:CGPoint,_ presence:SessionPresence)->NotebookSelectedInk.Key? {
      NotebookAttentionProjection.selectedInk(at:point,model:model,presence:presence,cohort:nil)
    }
    XCTAssertEqual(NotebookAttentionProjection.pointContact(at:point(140,175),model:model,presence:p,cohort:nil)?.elementID,below.id)
    XCTAssertEqual(selected(point(140,175),p),raw.key,"The physical raw plane is above the authored rectangle")
    XCTAssertNil(selected(point(230,175),p),"Captured erasure is not a draggable bounding box")
    XCTAssertNil(selected(point(200,210),p),"The empty interior of the L-shaped contact is not its body")
    let otherPage=SessionPresence(boardID:p.boardID,mode:.page,camera:p.camera,viewport:p.viewport,
      focusedItemID:p.focusedItemID,openProgress:1,selectedItemID:p.selectedItemID,notebookPageID:UUID())
    let otherBoard=SessionPresence(boardID:UUID(),mode:.board,camera:p.camera,viewport:p.viewport)
    XCTAssertNil(selected(point(140,175),otherPage));XCTAssertNil(selected(point(140,175),otherBoard))
    let start=input.convert(point(140,175),to:nil),end=input.convert(point(140,215),to:nil)
    XCTAssertTrue(input.hitTest(input.superview!.convert(start,from:nil)) === input)
    for location in [start,input.convert(point(425,175),to:nil)] {
      let menu=try XCTUnwrap(input.menu(for:try event(.rightMouseDown,at:location,window:window)))
      XCTAssertEqual(menu.items.map(\.title),["Дублировать","Удалить","Снять выделение"])
      XCTAssertTrue(menu.items.allSatisfy(\.isEnabled))
      XCTAssertEqual(model.selectionSession.id,selectionID,"Menu on either member preserves the whole mixed selection")
      XCTAssertEqual(model.selectionSession.ink.map(\.actionID),[pen.id])
      XCTAssertEqual(model.selectionSession.elements,[address.reference(peer.id)])
    }
    window.sendEvent(try event(.leftMouseDown,at:start,window:window))
    window.sendEvent(try event(.leftMouseUp,at:start,window:window))
    XCTAssertEqual(model.selectionSession.id,selectionID,"A click on the selected raw member cannot replace the whole choice")
    window.sendEvent(try event(.leftMouseDown,at:start,window:window))
    window.sendEvent(try event(.leftMouseDragged,at:end,window:window))
    XCTAssertEqual(try XCTUnwrap(model.selectionSession.manipulation?.movement.y),40,accuracy:1e-8)
    XCTAssertEqual(model.selectionSession.count,2)
    try await fixture.waitUntil {
      guard model.selectionSession.manipulation?.inkPresentation?.installed == true,
        let body=model.pageInkPublication.currentCanvas(on:page.id)?.orderedInkPlan.bodies.first else { return false }
      return abs(body.layout.frame.y-(raw.material.frame.y+40))<1e-8
    }
    window.sendEvent(try event(.leftMouseUp,at:end,window:window))
    let saved=await model.finishPendingInteraction();XCTAssertTrue(saved)
    let moved=try fixture.store.loadPage(page.id),body=try XCTUnwrap(moved.element(id:raw.memberID))
    XCTAssertEqual(body.frame.y,raw.material.frame.y+40,accuracy:1e-8)
    XCTAssertEqual(body.graphic?.freehand,raw.material.graphic.freehand,"Move retains the complete contact and captured cut")
    XCTAssertEqual(try XCTUnwrap(moved.element(id:peer.id)?.frame.y),peer.frame.y+40,accuracy:1e-8)
    XCTAssertEqual(moved.element(id:below.id)?.frame,below.frame)
    XCTAssertEqual(moved.drawingData,page.drawingData)
    XCTAssertEqual(model.presence?.camera,p.camera)
    input.undo(nil)
    let undone=await model.finishPendingInteraction();XCTAssertTrue(undone)
    let restored=try fixture.store.loadPage(page.id)
    XCTAssertTrue(restored.graphicPresentation.suppressedInkIDs.isEmpty)
    XCTAssertEqual(restored.element(id:peer.id)?.frame,peer.frame)
    XCTAssertTrue(model.drawingTools.begin(at:contour[0],address:address,screenScale:p.camera.scale))
    for point in contour.dropFirst() {model.drawingTools.move(to:point)};model.drawingTools.finish()
    try await fixture.waitUntil {model.drawingTools.pendingLasso == nil}
    XCTAssertEqual(model.selectionSession.ink.map(\.actionID),[pen.id])
    model.setMultipleSelectionAdding(true)
    window.sendEvent(try event(.leftMouseDown,at:start,window:window))
    window.sendEvent(try event(.leftMouseUp,at:start,window:window))
    XCTAssertTrue(model.selectionSession.ink.isEmpty)
    XCTAssertEqual(model.selectionSession.elements,[address.reference(peer.id)])
    XCTAssertTrue(model.selectionSession.addingElements,"Removing one raw member keeps additive picking with the selection owner")
    XCTAssertNil(model.selectionSession.manipulation)
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

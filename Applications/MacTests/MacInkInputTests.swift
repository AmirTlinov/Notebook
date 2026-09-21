import AppKit
@testable import NotebookCore
import XCTest
@testable import Notebook

@MainActor final class MacInkInputTests: XCTestCase {
  func testBackToBackMouseContactsAreAdmittedBeforeAnyDeliveryCanRun() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fixture=MacCommandFixture(root:root),model=fixture.model
    retainNotebookUntilTeardown(model,removing:root)
    try await fixture.start(showingPage:true)
    let page=try XCTUnwrap(model.activePage)
    let canvas=MacPageInkCanvas(model:model,pageID:page.id)
    let window=NSWindow(contentRect:.init(x:0,y:0,width:400,height:400),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false;window.contentView=canvas;window.makeKeyAndOrderFront(nil)
    defer { canvas.uninstall();window.close() }
    canvas.update(page:page,enabled:true,current:true,onReady:{ _ in })
    try await fixture.waitUntil { canvas.ink.pageGeometryIsReady }
    model.selectMacInputTool(.pen)
    try await fixture.waitUntil { model.drawingTool == .pen }
    func event(_ type:NSEvent.EventType,_ x:Double,_ y:Double,_ t:Double) throws -> NSEvent {
      try XCTUnwrap(NSEvent.mouseEvent(with:type,location:canvas.convert(.init(x:x,y:y),to:nil),
        modifierFlags:[],timestamp:t,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1))
    }
    // No await between contacts: the old delivery gate dropped contacts 2–10.
    for i in 0..<10 {
      let y=Double(30+i*20),t=Double(i)
      XCTAssertTrue(canvas.hitTest(.init(x:30,y:y)) === canvas)
      canvas.mouseDown(with:try event(.leftMouseDown,30,y,t))
      canvas.mouseUp(with:try event(.leftMouseUp,160,y,t+0.01))
    }
    XCTAssertEqual(model.pendingAcceptedPageInkCount,10)
    let saved=await model.finishPendingInteraction();XCTAssertTrue(saved)
    let drawing=try PageInkDrawing.decode(fixture.store.loadPage(page.id).drawingData)
    XCTAssertEqual(drawing.activeActions.count,10)
    XCTAssertEqual(drawing.activeActions.map { $0.samples[0].point.y },(0..<10).map { Double(30+$0*20) })
  }

  func testNativeMouseContactPersistsItsExactSourceAndEraserUndoKeepsThePen() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fixture=MacCommandFixture(root:root),model=fixture.model
    retainNotebookUntilTeardown(model,removing:root)
    try await fixture.start(showingPage:true)
    let page=try XCTUnwrap(model.activePage)
    let canvas=MacPageInkCanvas(model:model,pageID:page.id)
    let window=NSWindow(contentRect:.init(x:0,y:0,width:400,height:400),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false;window.contentView=canvas;window.makeKeyAndOrderFront(nil)
    defer { canvas.uninstall();window.close() }
    canvas.update(page:page,enabled:true,current:true,onReady:{ _ in })
    try await fixture.waitUntil { canvas.ink.pageGeometryIsReady }
    func event(_ type: NSEvent.EventType,_ x: Double,_ y: Double,_ time: Double) throws -> NSEvent {
      try XCTUnwrap(NSEvent.mouseEvent(with:type,location:canvas.convert(.init(x:x,y:y),to:nil),
        modifierFlags:[],timestamp:time,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1))
    }
    model.selectMacInputTool(.pen)
    try await fixture.waitUntil { model.drawingTool == .pen }
    canvas.mouseDown(with:try event(.leftMouseDown,30,60,1))
    canvas.mouseDragged(with:try event(.leftMouseDragged,180,80,1.125))
    canvas.mouseUp(with:try event(.leftMouseUp,210,90,1.25))
    let saved=await model.finishPendingInteraction();XCTAssertTrue(saved)
    var drawing=try PageInkDrawing.decode(fixture.store.loadPage(page.id).drawingData)
    let pen=try XCTUnwrap(drawing.activeActions.first)
    XCTAssertEqual(pen.tool,.pen);XCTAssertEqual(pen.samples.count,3)
    XCTAssertEqual(pen.samples.map(\.point),[.init(x:30,y:60),.init(x:180,y:80),.init(x:210,y:90)])
    XCTAssertEqual(pen.samples.map(\.timeOffset),[0,0.125,0.25])
    XCTAssertTrue(pen.samples.allSatisfy { $0.opacity.bitPattern == Double(1).bitPattern })
    model.selectMacInputTool(.eraser)
    try await fixture.waitUntil { model.drawingTool == .eraser }
    canvas.mouseDown(with:try event(.leftMouseDown,120,40,2))
    canvas.mouseUp(with:try event(.leftMouseUp,120,120,2.25))
    let erased=await model.finishPendingInteraction();XCTAssertTrue(erased)
    drawing=try PageInkDrawing.decode(fixture.store.loadPage(page.id).drawingData)
    XCTAssertEqual(drawing.activeActions.map(\.tool),[.pen,.eraser])
    canvas.undo(nil)
    let undone=await model.finishPendingInteraction();XCTAssertTrue(undone)
    let reopened=try NotebookStore(root:root).loadPage(page.id)
    drawing=try PageInkDrawing.decode(reopened.drawingData)
    XCTAssertEqual(drawing.activeActions.map(\.id),[pen.id])
    XCTAssertTrue(zip(drawing.activeActions[0].samples,pen.samples).allSatisfy(InkSampleRelations.sameBits))
  }
}

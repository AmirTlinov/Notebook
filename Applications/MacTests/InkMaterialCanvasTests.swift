import AppKit
import NotebookCore
import XCTest
@testable import Notebook

@MainActor final class InkMaterialCanvasTests: XCTestCase {
  func testNativeMaterialKeepsItsBuffersAcrossCameraAndStopsWhenDetached() async throws {
    let canvas=InkCanvasView(frame:.zero)
    let window=NSWindow(contentRect:.init(x:0,y:0,width:300,height:300),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false;window.contentView=canvas;window.makeKeyAndOrderFront(nil)
    defer { Task { await canvas.finishSpatialHandoffFrames() };window.close() }
    let samples=(0..<2400).map { i in SpatialInkSample(point:.init(x:150+cos(Double(i)*0.2)*30,y:150+sin(Double(i)*0.2)*30),
      timeOffset:Double(i)/240,width:8,opacity:1,force:1,azimuth:0,altitude:1) }
    let ink=NotebookFreehand(layers:[.init(tool:.pen,color:.black,measured:.init(sourceID:UUID(),
      measurements:.init(samples),frame:.init(x:0,y:0,width:300,height:300)))])
    let content=NotebookInkMaterialView.Content(freehand:ink,erasures:[],transform:nil,layout:nil)
    canvas.updateMaterial(content)
    canvas.projectPage(region:.init(x:0,y:0,width:300,height:300),sourceSize:.init(width:300,height:300),pixelDensity:2)
    try await ready(canvas,after:0)
    let nodes=canvas.materialUploadedNodeCount,frames=canvas.drawableRequestCount
    XCTAssertGreaterThan(nodes,0)
    canvas.projectPage(region:.init(x:10,y:10,width:280,height:280),sourceSize:.init(width:300,height:300),pixelDensity:2)
    try await ready(canvas,after:frames)
    XCTAssertEqual(canvas.materialUploadedNodeCount,nodes)
    window.contentView=nil
    canvas.updateMaterial(.init(freehand:ink,erasures:[],transform:.init(a:1,b:0.1,c:0.2,d:1,tx:0,ty:0),layout:nil))
    XCTAssertTrue(canvas.isPaused)
  }
  func testMaterialReadinessRequiresEveryExactVisibleSource() {
    let a=NotebookInkMaterialView.Content(freehand:nil,erasures:[],transform:nil,layout:nil)
    let b=NotebookInkMaterialView.Content(freehand:nil,erasures:[],transform:.init(a:0,b:1,c:-1,d:0,tx:1,ty:0),layout:nil)
    let first=UUID(),second=UUID()
    var receipt=NotebookInkMaterialReadiness()
    XCTAssertFalse(receipt.isReady(for:[a]))
    receipt.record(first,content:a,ready:false)
    XCTAssertFalse(receipt.isReady(for:[a]))
    receipt.record(first,content:a,ready:true)
    XCTAssertTrue(receipt.isReady(for:[a]))
    XCTAssertFalse(receipt.isReady(for:[b]),"A changed basis has no receipt yet")
    XCTAssertFalse(receipt.isReady(for:[a,b]),"The visible ink cannot acknowledge a pending mask")
    receipt.record(second,content:b,ready:true)
    XCTAssertTrue(receipt.isReady(for:[a,b]))
    receipt.record(first,content:nil,ready:false)
    XCTAssertFalse(receipt.isReady(for:[a,b]))
    XCTAssertTrue(receipt.isReady(for:[b]),"Retiring a different host cannot revoke this source")
  }

  func testReadyNativeMaterialTransfersToANewRecipientWithoutRedrawing() async throws {
    let host=InkMaterialHost()
    let window=NSWindow(contentRect:.init(x:0,y:0,width:300,height:300),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false;window.contentView=host;window.makeKeyAndOrderFront(nil)
    defer { host.stop();window.close() }
    let content=NotebookInkMaterialView.Content(freehand:nil,erasures:[],transform:nil,layout:nil)
    var first=false,second=false
    host.update(content,projection:nil,report:.init(id:UUID(),report:{ _,_,ready in first=ready }))
    host.layoutSubtreeIfNeeded()
    try await ready(host.canvas,after:0)
    XCTAssertTrue(first)
    let frames=host.canvas.drawableRequestCount
    host.update(content,projection:nil,report:.init(id:UUID(),report:{ _,_,ready in second=ready }))
    await Task.yield()
    XCTAssertTrue(second,"A reused visible layer must acknowledge its new cohort")
    XCTAssertEqual(host.canvas.drawableRequestCount,frames,"Changing the recipient does not render another frame")
  }

  private func ready(_ canvas:InkCanvasView,after frames:Int) async throws {
    let deadline=ContinuousClock.now + .seconds(5)
    while !canvas.isStableFramePresented,ContinuousClock.now < deadline { try await Task.sleep(for:.milliseconds(10)) }
    XCTAssertTrue(canvas.isStableFramePresented)
  }
}

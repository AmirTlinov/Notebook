import AppKit
import NotebookCore
import PencilKit
import XCTest
@testable import Notebook

final class CollaborationVisionTests: XCTestCase {
  @MainActor
  func testSharedMetalGeometryErasesFinalPixels() throws {
    let points = [20.0,180.0].map { x in PKStrokePoint(location: .init(x:x,y:80), timeOffset:x/1000,
      size:.init(width:12,height:12), opacity:1, force:1, azimuth:0, altitude:.pi/2) }
    let eraser = [10.0,190.0].map { x in PKStrokePoint(location: .init(x:x,y:80), timeOffset:x/1000,
      size:.init(width:40,height:40), opacity:1, force:1, azimuth:0, altitude:.pi/2) }
    let cache = SpatialInkRasterCache.shared
    let size = CGSize(width:200,height:160)
    let ink = try XCTUnwrap(cache.render(layers:[.ink(points:points,color:.black)],size:size))
    XCTAssertFalse(cache.occupiedRegions(ink,size:size).isEmpty)
    let erased = try XCTUnwrap(cache.render(layers:[.ink(points:points,color:.black),.erase(points:eraser)],size:size))
    XCTAssertTrue(cache.occupiedRegions(erased,size:size).isEmpty)
  }

  @MainActor
  func testTargetPageCompositeKeepsCameraAndReportsRuntimeDiagnostics() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let model = NotebookAppModel(store:.init(root:root),startsNearbySync:false)
    model.start(pageSize:NotebookAppModel.defaultPageSize)
    let page = try XCTUnwrap(model.activePage)
    let target = CollaborationTarget(kind:.page,id:page.id)
    let action = CollaborationAction(summary:"Объяснение с диагностикой",expected:[.init(target:target,revision:page.agentStamp.revision)],operations:[
      .init(kind:.insertElement,target:target,id:"explanation",values:["kind":.string("web"),"source":.string("<h1>Understanding</h1>"),
        "html":.string("<h1>Understanding</h1><div style='height:800px'>Overflow</div>"),
        "javaScript":.string("throw Error('test diagnostic')"),
        "frame":.object(["x":.number(60),"y":.number(80),"width":.number(300),"height":.number(160)])])])
    _ = try model.store.applyCollaborationAction(action,actor:UUID())
    model.reloadExternalChanges()
    let original = model.presence
    let request = try model.store.requestTargetRender(target:target,expectedRevision:try XCTUnwrap(model.activePage).agentStamp.revision)
    try await CurrentViewPreviewWriter.writeTarget(request,model:model)
    let receipt = try JSONDecoder().decode(TargetRenderReceipt.self,from:Data(contentsOf:model.store.targetReceiptURL(request.id)))
    XCTAssertEqual(receipt.status,"ready")
    XCTAssertTrue(receipt.diagnostics.contains { $0.kind == "javascript_error" })
    XCTAssertTrue(receipt.diagnostics.contains { $0.kind == "overflow" })
    XCTAssertEqual(model.presence,original)
    XCTAssertNotNil(NSImage(contentsOf:model.store.targetPNGURL(request.id)))
  }
}

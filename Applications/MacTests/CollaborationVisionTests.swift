import AppKit
import NotebookCore
import PencilKit
import XCTest
@testable import Notebook

final class CollaborationVisionTests: XCTestCase {
  @MainActor
  func testSharedMetalGeometryErasesFinalPixels() async throws {
    let points = [20.0,180.0].map { x in PKStrokePoint(location: .init(x:x,y:80), timeOffset:x/1000,
      size:.init(width:12,height:12), opacity:1, force:1, azimuth:0, altitude:.pi/2) }
    let eraser = [10.0,190.0].map { x in PKStrokePoint(location: .init(x:x,y:80), timeOffset:x/1000,
      size:.init(width:40,height:40), opacity:1, force:1, azimuth:0, altitude:.pi/2) }
    let cache = InkRasterRenderer.shared
    let size = CGSize(width:200,height:160)
    let ink = try XCTUnwrap(cache.render(layers:[.ink(points:points,color:.black)],size:size))
    XCTAssertFalse(try SpatialInkRasterSnapshot.occupiedRegions(ink,size:size).isEmpty)
    let erased = try XCTUnwrap(cache.render(layers:[.ink(points:points,color:.black),.erase(points:eraser)],size:size))
    XCTAssertTrue(try SpatialInkRasterSnapshot.occupiedRegions(erased,size:size).isEmpty)
  }

  @MainActor
  func testTargetPageCompositeKeepsCameraAndReportsRuntimeDiagnostics() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store:.init(root:root),startsNearbySync:false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize:NotebookAppModel.defaultPageSize)
    let page = try XCTUnwrap(model.activePage)
    let target = CollaborationTarget(kind:.page,id:page.id)
    let action = CollaborationAction(summary:"Объяснение с диагностикой",expected:[.init(target:target,revision:page.agentStamp.revision)],operations:[
      .init(kind:.insertElement,target:target,id:"explanation",values:["kind":.string("web"),"source":.string("<h1>Understanding</h1>"),
        "html":.string("<h1>Understanding</h1><div style='height:800px'>Overflow</div>"),
        "javaScript":.string("throw Error('test diagnostic')"),
        "frame":.object(["x":.number(60),"y":.number(80),"width":.number(300),"height":.number(160)])])])
    _ = try model.store.applyCollaborationAction(action,actor:UUID())
    await model.reloadExternalChanges()?.value
    let original = model.presence
    let request = try model.store.requestTargetRender(target:target,expectedRevision:try XCTUnwrap(model.activePage).agentStamp.revision)
    try await CurrentViewPreviewWriter.writeTarget(request,model:model)
    let receipt = try JSONDecoder().decode(TargetRenderReceipt.self,from:Data(contentsOf:model.store.targetReceiptURL(request.id)))
    XCTAssertEqual(receipt.status,"ready")
    XCTAssertTrue(receipt.diagnostics.contains { $0.kind == "javascript_error" })
    XCTAssertTrue(receipt.diagnostics.contains { $0.kind == "overflow" })
    XCTAssertEqual(model.presence,original)
    XCTAssertNotNil(NSImage(contentsOf:model.store.targetPNGURL(request.id)))
    let crop = try model.store.requestTargetRender(target:target,expectedRevision:try XCTUnwrap(model.activePage).agentStamp.revision,
      region:.init(x:60,y:80,width:300,height:160))
    try await CurrentViewPreviewWriter.writeTarget(crop,model:model)
    let cropped = try JSONDecoder().decode(TargetRenderReceipt.self,from:Data(contentsOf:model.store.targetReceiptURL(crop.id)))
    XCTAssertEqual(cropped.pixelSize?.x,600)
    XCTAssertEqual(cropped.pixelSize?.y,320)
    XCTAssertEqual(model.presence,original)
  }
  @MainActor
  func testTargetPageLargerThanTheRasterCachePublishesOneOrderedResult() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    var page = try XCTUnwrap(model.activePage)
    let elements = (0..<12).map { index in
      AgentElement(id: "large-\(UUID().uuidString)", kind: .web,
        frame: .init(x: 17, y: 29, width: 800, height: 1100), source: "unique layer \(index)",
        html: "<svg width='800' height='1100'><rect width='800' height='1100' fill='\(index == 11 ? "red" : "blue")'/></svg>",
        javaScript: index == 0 ? "throw Error('first source diagnostic')" : "")
    }
    let total = elements.reduce(0) { $0 + Int($1.frame.width * $1.frame.height * 4 * 4 * 2) }
    XCTAssertGreaterThan(total, SceneRenderResources.shared.byteLimit)
    XCTAssertTrue(page.replaceElements(elements, actor: UUID()))
    _ = try model.store.savePage(page)
    await model.reloadExternalChanges()?.value
    let original = model.presence
    let target = CollaborationTarget(kind: .page, id: page.id)
    let request = try model.store.requestTargetRender(target: target, expectedRevision: page.agentStamp.revision)
    try await CurrentViewPreviewWriter.writeTarget(request, model: model)
    let receipt = try JSONDecoder().decode(TargetRenderReceipt.self,
      from: Data(contentsOf: model.store.targetReceiptURL(request.id)))
    XCTAssertEqual(receipt.status, "ready")
    XCTAssertTrue(receipt.diagnostics.contains { $0.kind == "javascript_error" && $0.elementID == elements[0].id }, "\(receipt.diagnostics)")
    XCTAssertEqual(model.presence, original)
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: model.store.targetPNGURL(request.id))))
    let pixel = try XCTUnwrap(bitmap.colorAt(x: 500, y: 500)?.usingColorSpace(.deviceRGB))
    XCTAssertGreaterThan(pixel.redComponent, 0.95)
    XCTAssertLessThan(pixel.blueComponent, 0.05)
    // The app publisher can be composing the current view at this instant.
    // Private-owner tests check release to zero; the shared owner checks its total budget.
    XCTAssertLessThanOrEqual(SceneRenderResources.shared.residentBytes + SceneRenderResources.shared.reservedBytes,
      SceneRenderResources.shared.byteLimit)
    await model.finishPendingPersistence()
  }

  @MainActor
  func testRegionalReferenceIgnoresOutsideInkAndFollowsItsPhysicalOwner() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    var page = try XCTUnwrap(model.activePage)
    let actor = UUID(), target = CollaborationTarget(kind: .page, id: page.id)
    func stroke(_ y: Double, tool: SpatialInkTool = .pen) -> PageInkAction {
      .init(tool: tool, samples: [40.0, 120.0].map {
        .init(point: .init(x: $0, y: y), timeOffset: $0 / 1000, width: tool == .pen ? 8 : 40, opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
      })
    }
    var actions: [PageInkAction] = []
    func save() async throws {
      _ = page.replaceDrawing(try PageInkDrawing(actions: actions).dataRepresentation(), actor: actor)
      _ = try model.store.savePage(page); await model.reloadExternalChanges()?.value
    }
    try await save()
    let reference = CollaborationReference(target: target, region: .init(x: 20, y: 20, width: 140, height: 100),
      revision: try model.store.referenceRevision(target: target))
    XCTAssertEqual(try model.store.referenceStatus(reference).status, .checking)
    func render() async throws {
      let request = try model.store.requestTargetRender(target: target, expectedRevision: page.agentStamp.revision, region: reference.region)
      try await CurrentViewPreviewWriter.writeTarget(request, model: model)
    }
    try await render()
    XCTAssertEqual(try model.store.referenceStatus(reference).status, .current)
    actions.append(stroke(300)); try await save()
    XCTAssertEqual(try model.store.referenceStatus(reference).status, .checking)
    try await render()
    XCTAssertEqual(try model.store.referenceStatus(reference).status, .current, "Чернила вне области не меняют понимание")
    let workspace = try XCTUnwrap(model.workspace)
    model.moveItem(workspace.selectedItemID, to: .init(x: 800, y: 500))
    XCTAssertEqual(try model.store.referenceStatus(reference).status, .current, "Положение предмета не входит в исходник")
    actions.append(stroke(90)); try await save(); try await render()
    XCTAssertEqual(try model.store.referenceStatus(reference).status, .changed)
    let reopened = NotebookStore(root: root)
    XCTAssertEqual(try reopened.referenceStatus(reference).status, .changed, "Перезапуск сохраняет рассмотренные пиксели")
    actions.append(stroke(90, tool: .eraser)); try await save(); try await render()
    XCTAssertEqual(try reopened.referenceStatus(reference).status, .current, "Окончательное стирание возвращает тот же фрагмент")
  }

}

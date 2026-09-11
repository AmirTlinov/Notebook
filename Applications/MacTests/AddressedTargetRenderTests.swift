import AppKit
import NotebookCore
import XCTest
@testable import Notebook

final class AddressedTargetRenderTests: XCTestCase {
  @MainActor
  func testTargetUsesSavedPageWithoutLoadingTheArchiveIntoTheAppModel() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = NotebookStore(root: root), actor = UUID()
    var (workspace, pages) = try store.loadOrCreate(actor: actor, pageSize: .init(width: 100, height: 140))
    var page = try XCTUnwrap(pages.values.first)
    XCTAssertTrue(page.replaceElements([.init(id: "explicit-red-source", kind: .web,
      frame: .init(x: 20, y: 20, width: 70, height: 90), source: "The requested page",
      html: "<svg width='70' height='90'><rect width='70' height='90' fill='red'/></svg>")], actor: actor))
    try store.savePage(page)
    let other = try XCTUnwrap(workspace.createNotebook(title: "Not requested", actor: actor, pageSize: page.size))
    try store.saveWorkspaceBundle(index: workspace, page: other.page,
      board: .initial(rootBoardID: workspace.rootBoardID, itemIDs: workspace.items.map(\.id), actor: actor))
    _ = try store.loadOrCreateSpatialInk(actor: actor)
    var unrelated = other.page
    XCTAssertTrue(unrelated.replaceElements([.init(id: "unrequested-program", kind: .web,
      frame: .init(x: 0, y: 0, width: 100, height: 140), source: "An unrelated saved program",
      html: "<div>Not requested</div>", javaScript: "throw Error('unrequested owner executed')")], actor: actor))
    try store.savePage(unrelated)
    let request = try store.requestTargetRender(target: .init(kind: .page, id: page.id),
      expectedRevision: page.agentStamp.revision)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    XCTAssertTrue(model.pages.isEmpty)
    XCTAssertNil(model.workspace)
    try await CurrentViewPreviewWriter.writeTarget(request, model: model)
    let receipt = try JSONDecoder().decode(TargetRenderReceipt.self, from: Data(contentsOf: store.targetReceiptURL(request.id)))
    XCTAssertEqual(receipt.status, "ready")
    XCTAssertFalse(receipt.diagnostics.contains { $0.elementID == "unrequested-program" })
    XCTAssertEqual(receipt.request.sourceRevision, try store.referenceRevision(target: request.target))
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: store.targetPNGURL(request.id))))
    let pixel = try XCTUnwrap(bitmap.colorAt(x: 100, y: 100)?.usingColorSpace(.deviceRGB))
    XCTAssertGreaterThan(pixel.redComponent, 0.95)
    XCTAssertLessThan(pixel.blueComponent, 0.05)
    XCTAssertTrue(model.pages.isEmpty)
    XCTAssertNil(model.presence)
  }

  @MainActor
  func testSavedLetterCoverUsesItsOwnPaperWithoutLoadingDocumentPrograms() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = NotebookStore(root: root), actor = UUID()
    var (workspace, _) = try store.loadOrCreate(actor: actor, pageSize: .init(width: 100, height: 140))
    let item = try XCTUnwrap(workspace.createDocument(title: "Letter", actor: actor))
    let document = DocumentDocument(id: item.id, actor: actor, paperSize: .letter,
      blocks: [.interactive(id: "body", html: "<h1>Not this cover</h1>", javaScript: "throw Error('the document program is not its cover')")])
    var hierarchy = BoardHierarchy.initial(rootBoardID: workspace.rootBoardID, itemIDs: workspace.items.map(\.id), actor: actor)
    try store.saveDocumentWorkspaceBundle(index: workspace, document: document,
      state: .init(id: document.id, actor: actor), board: hierarchy)
    _ = try store.loadOrCreateSpatialInk(actor: actor)
    // The saved document and state stay outside this cover-only render projection.
    let target = CollaborationTarget(kind: .cover, id: item.id, boardID: workspace.rootBoardID)
    let request = try store.requestTargetRender(target: target,
      expectedRevision: try XCTUnwrap(hierarchy.board(workspace.rootBoardID)).stamp.revision)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    try await CurrentViewPreviewWriter.writeTarget(request, model: model)
    let receipt = try JSONDecoder().decode(TargetRenderReceipt.self, from: Data(contentsOf: store.targetReceiptURL(request.id)))
    XCTAssertEqual(receipt.status, "ready", "\(receipt.diagnostics)")
    let size = WorkspaceItemGeometry.document(.letter)
    XCTAssertEqual(receipt.pixelSize?.x, ceil(size.width * 2))
    XCTAssertEqual(receipt.pixelSize?.y, ceil(size.height * 2))
    XCTAssertTrue(model.documents.isEmpty)
    XCTAssertTrue(model.documentStates.isEmpty)
    XCTAssertNil(model.presence)
    let originalPNG = try Data(contentsOf: store.targetPNGURL(request.id))
    let neighbor = SpatialElement(id: "not-this-cover", surface: .board(workspace.rootBoardID), kind: .web,
      frame: .init(x: 0, y: 0, width: 1800, height: 1800), worldOrigin: .init(x: -900, y: -900),
      source: "Neighbour", html: "<div style='background:red;width:1800px;height:1800px'></div>",
      javaScript: "throw Error('a neighbour is not part of this cover')", stamp: .init(counter: 0, actor: actor))
    XCTAssertTrue(hierarchy.upsertElement(neighbor, in: workspace.rootBoardID, expected: nil, actor: actor))
    try store.saveBoard(hierarchy, items: workspace.items)
    let repeated = try store.requestTargetRender(target: target,
      expectedRevision: try XCTUnwrap(hierarchy.board(workspace.rootBoardID)).stamp.revision)
    XCTAssertEqual(repeated.id, request.id)
    try await CurrentViewPreviewWriter.writeTarget(repeated, model: model)
    let finalPNG = try Data(contentsOf: store.targetPNGURL(request.id))
    let before = try rgba(originalPNG), after = try rgba(finalPNG)
    XCTAssertEqual(before.count, after.count)
    let maximumDifference = zip(before, after).map { abs(Int($0) - Int($1)) }.max() ?? 0
    if maximumDifference > 1 {
      for (name, png) in [("cover-before", originalPNG), ("cover-after", finalPNG)] {
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
      }
    }
    // Independent SwiftUI/Core Graphics draws differ by one quantization unit
    // at antialiased artwork edges. The full physical raster, including its
    // transparent corners, must otherwise remain the same, not just its centre.
    XCTAssertLessThanOrEqual(maximumDifference, 1,
      "A neighbour cannot change the physical cover's pixels under the same source identity")
    XCTAssertEqual(stride(from: 3, to: before.count, by: 4).map { before[$0] },
      stride(from: 3, to: after.count, by: 4).map { after[$0] })
    let finalReceipt = try JSONDecoder().decode(TargetRenderReceipt.self, from: Data(contentsOf: store.targetReceiptURL(request.id)))
    XCTAssertTrue(finalReceipt.diagnostics.isEmpty)
  }

  @MainActor
  func testPortalCoverRendersItsSavedChildAndChangesIdentityWithIt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = NotebookStore(root: root), actor = UUID()
    let author = NotebookAppModel(store: store, startsNearbySync: false)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    addTeardownBlock { @MainActor in
      let rendererStopped = await model.shutdown()
      let authorStopped = await author.shutdown()
      XCTAssertTrue(rendererStopped && authorStopped,
        "Every model must acknowledge shutdown before the shared test store is removed")
      guard rendererStopped && authorStopped else { return }
      try FileManager.default.removeItem(at: root)
    }
    await author.start(pageSize: NotebookAppModel.defaultPageSize)
    let portal = try XCTUnwrap(author.createBoard(at: .zero))
    let authorStopped = await author.shutdown()
    XCTAssertTrue(authorStopped, "The restored renderer cannot run beside the preceding writer")
    guard authorStopped else { return }
    let workspace = try store.loadIndex()
    var hierarchy = try store.loadBoard(items: workspace.items)
    let target = CollaborationTarget(kind: .cover, id: portal, boardID: workspace.rootBoardID)
    var previous: TargetRenderRequest?
    for (counter, color) in ["red", "blue"].enumerated() {
      let element = SpatialElement(id: "child-program", surface: .board(portal), kind: .web,
        frame: .init(x: 0, y: 0, width: 500, height: 500), worldOrigin: .init(x: -250, y: -250),
        source: color, html: "<svg width='500' height='500'><rect width='500' height='500' fill='\(color)'/></svg>",
        stamp: .init(counter: UInt64(counter), actor: actor))
      XCTAssertTrue(hierarchy.upsertElement(element, in: portal, expected: nil, actor: actor))
      try store.saveBoard(hierarchy, items: workspace.items)
      let request = try store.requestTargetRender(target: target,
        expectedRevision: try XCTUnwrap(hierarchy.board(workspace.rootBoardID)).stamp.revision)
      if let previous {
        XCTAssertNotEqual(request.sourceRevision, previous.sourceRevision)
        XCTAssertNotEqual(request.id, previous.id)
      }
      try await CurrentViewPreviewWriter.writeTarget(request, model: model)
      let png = try Data(contentsOf: store.targetPNGURL(request.id))
      let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
      attachment.name = "portal-\(color)"; attachment.lifetime = .keepAlways; add(attachment)
      let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
      XCTAssertEqual(bitmap.bitsPerSample, 8)
      XCTAssertEqual(bitmap.samplesPerPixel, 4)
      var pixel = [Int](repeating: 0, count: 4)
      bitmap.getPixel(&pixel, atX: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)
      XCTAssertEqual(pixel, color == "red" ? [255, 0, 0, 255] : [0, 0, 255, 255],
        "Compare encoded sRGB channels, without AppKit's display-colour conversion")
      previous = request
    }
    XCTAssertNil(model.workspace)
    XCTAssertNil(model.presence)
  }

  @MainActor
  func testAnotherRenderingRecipeIsRefusedBeforeReadingOrPublishingTheTarget() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = NotebookStore(root: root), actor = UUID()
    _ = try store.loadOrCreate(actor: actor, pageSize: .init(width: 100, height: 140))
    let document = DocumentDocument(actor: actor, blocks: [.markdown(id: "formula", source: "$x^2$")])
    try store.saveDocument(document); try store.saveDocumentState(.init(id: document.id, actor: actor))
    let current = try store.requestTargetRender(target: .init(kind: .document, id: document.id), expectedRevision: document.contentStamp.revision)
    var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
    encoded["id"] = UUID().uuidString
    let other = try JSONDecoder().decode(TargetRenderRequest.self, from: JSONSerialization.data(withJSONObject: encoded))
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    do {
      try await CurrentViewPreviewWriter.writeTarget(other, model: model)
      XCTFail("Today's pixels cannot certify another recipe's request")
    } catch let error as CollaborationError {
      XCTAssertEqual(error.code, "render_recipe_unavailable")
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.targetPNGURL(other.id).path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.targetReceiptURL(other.id).path))
    XCTAssertTrue(model.documents.isEmpty); XCTAssertNil(model.workspace)
  }

  private func rgba(_ png: Data) throws -> [UInt8] {
    let image = try XCTUnwrap(NSBitmapImageRep(data: png)?.cgImage)
    let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
      bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: .init(x: 0, y: 0, width: image.width, height: image.height))
    let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
    return Array(UnsafeBufferPointer(start: bytes, count: context.bytesPerRow * context.height))
  }
}

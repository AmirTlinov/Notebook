import AppKit
import NotebookCore
import XCTest
@testable import Notebook

final class PageVisionDemandTests: XCTestCase {
  @MainActor
  func testArchivePreparesOnlySelectedAndExplicitlyRequestedInkPages() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    let size = PageSize(width: 100, height: 140)
    var (workspace, pages) = try store.loadOrCreate(actor: actor, pageSize: size)
    let firstID = try XCTUnwrap(workspace.selectedPageID)
    var first = try XCTUnwrap(pages[firstID])
    XCTAssertTrue(first.replaceElements([.init(id: "not-part-of-ink", kind: .web,
      frame: .init(x: 2, y: 2, width: 90, height: 60), source: "An offscreen interactive source",
      html: "<h1>Not ink</h1>", javaScript: "throw Error('must not execute for ink map')")], actor: actor))
    try store.savePage(first)
    pages[first.id] = first
    for number in 1..<64 {
      let created = try XCTUnwrap(workspace.createNotebook(title: "Source \(number)", actor: actor, pageSize: size))
      try store.savePage(created.page)
    }
    let selectedID = try XCTUnwrap(workspace.selectedPageID)
    XCTAssertNotEqual(selectedID, firstID)
    let selectedPage = try store.loadPage(selectedID)
    try store.saveWorkspaceBundle(index: workspace, page: selectedPage,
      board: .initial(rootBoardID: workspace.rootBoardID, itemIDs: workspace.items.map(\.id), actor: actor))
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    model.start(pageSize: size)
    defer { model.inputGate.beginContact(source: UUID()) }
    XCTAssertEqual(model.pages.count, 64)
    try await waitUntil { store.hasCurrentPageVision(selectedPage) }
    XCTAssertEqual(try visionIDs(store), [selectedID.uuidString.lowercased()])
    let original = model.presence
    let contact = UUID()
    model.inputGate.beginContact(source: contact)
    let request = try store.requestPageVision(pageID: first.id, expectedRevision: first.drawingStamp.revision)
    try await Task.sleep(for: .milliseconds(1_200))
    XCTAssertFalse(store.hasCurrentPageVision(first), "The active contact owns the preparation budget")
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.targetReceiptURL(request.id).path))
    model.inputGate.endContact(source: contact)
    try await waitUntil { FileManager.default.fileExists(atPath: store.targetReceiptURL(request.id).path) }
    let receipt = try JSONDecoder().decode(TargetRenderReceipt.self,
      from: Data(contentsOf: store.targetReceiptURL(request.id)))
    XCTAssertEqual(receipt.status, "ready", "\(receipt.diagnostics)")
    XCTAssertTrue(receipt.diagnostics.isEmpty)
    XCTAssertTrue(store.hasCurrentPageVision(first))
    XCTAssertTrue(receipt.inkRegions.isEmpty, "A text or interactive layer is not Pencil ink")
    XCTAssertEqual(model.presence, original)
    XCTAssertEqual(model.workspace?.selectedPageID, selectedID)
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.targetPNGURL(request.id).path),
      "The ink map is not an all-layer target snapshot")
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertEqual(try visionIDs(store), Set([selectedID, first.id].map { $0.uuidString.lowercased() }))
    await model.finishPendingPersistence()
  }

  @MainActor
  func testCapturedInkRequestCannotPublishTheNextDrawingUnderTheOldIdentity() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    model.start(pageSize: .init(width: 100, height: 140))
    defer { model.inputGate.beginContact(source: UUID()) }
    var page = try XCTUnwrap(model.activePage)
    let captured = try store.requestPageVision(pageID: page.id, expectedRevision: page.drawingStamp.revision)
    let contact = UUID()
    model.inputGate.beginContact(source: contact)
    let ink = PageInkDrawing(actions: [.init(tool: .pen, samples: [.init(point: .init(x: 30, y: 40),
      timeOffset: 0, width: 6, opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)])])
    XCTAssertTrue(page.replaceDrawing(try ink.dataRepresentation(), actor: UUID()))
    _ = try store.saveMergedPage(page)
    model.inputGate.endContact(source: contact)
    await model.reloadExternalChanges()?.value
    do {
      try await CurrentViewPreviewWriter.writeTarget(captured, model: model)
      XCTFail("A captured source must not silently follow new ink")
    } catch { }
    if let data = try? Data(contentsOf: store.targetReceiptURL(captured.id)),
      let receipt = try? JSONDecoder().decode(TargetRenderReceipt.self, from: data) {
      XCTAssertNotEqual(receipt.status, "ready")
    }
    await model.finishPendingPersistence()
  }

  private func visionIDs(_ store: NotebookStore) throws -> Set<String> {
    Set(try FileManager.default.contentsOfDirectory(atPath: store.root.appendingPathComponent("previews").path)
      .filter { $0.hasSuffix(".vision.json") }.map { String($0.dropLast(".vision.json".count)) })
  }

  @MainActor
  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(40)) }
    XCTAssertTrue(condition(), "The bounded publisher did not complete the requested page")
  }
}

import AppKit
import NotebookCore
import XCTest
@testable import Notebook

final class PageVisionDemandTests: XCTestCase {
  @MainActor
  func testArchivePreparesOnlySelectedAndExplicitlyRequestedInkPages() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = NotebookStore(root: root), actor = UUID()
    let size = PageSize(width: 100, height: 140)
    var (workspace, pages) = try store.loadOrCreate(actor: actor, pageSize: size)
    let firstID = try XCTUnwrap(workspace.selectedPageID)
    var first = try XCTUnwrap(pages[firstID])
    XCTAssertTrue(first.replaceElements([.init(id: "not-part-of-ink-\(UUID())", kind: .web,
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
    let hierarchy = BoardHierarchy.initial(rootBoardID: workspace.rootBoardID,
      itemIDs: workspace.items.map(\.id), actor: actor)
    try store.saveWorkspaceBundle(index: workspace, page: selectedPage, board: hierarchy)
    let selectedItemID = workspace.selectedItemID
    let selectedCenter = try XCTUnwrap(hierarchy.board(workspace.rootBoardID)?.focusedCenter(of: selectedItemID))
    try store.savePresence(.init(boardID: workspace.rootBoardID, mode: .page,
      camera: .init(center: selectedCenter, scale: 1), viewport: .init(x: size.width, y: size.height),
      focusedItemID: selectedItemID, openProgress: 1, selectedItemID: selectedItemID, notebookPageID: selectedID))
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    removeAfterShutdown(model, root: root)
    await model.start(pageSize: size)
    XCTAssertEqual(try store.workspaceHeader().itemCount, 64)
    let canonicalPageCount = try store.readWorkspaceItems(limit: 128).reduce(0) { count, item in
      count + (try store.pageCount(in: item.id))
    }
    XCTAssertEqual(canonicalPageCount, 64)
    XCTAssertLessThanOrEqual(model.pages.count, 4, "The live model is a bounded working set, not the saved archive")
    XCTAssertNotNil(model.pages[selectedID])
    XCTAssertNil(model.pages[firstID])
    try await waitUntil { store.hasCurrentPageVision(selectedPage) }
    XCTAssertEqual(try visionIDs(store), [selectedID.uuidString.lowercased()])
    let original = model.presence
    let contact = UUID()
    model.inputGate.beginContact(source: contact)
    let request = try await requestVision(first, model: model)
    try await Task.sleep(for: .milliseconds(1_200))
    XCTAssertFalse(store.hasCurrentPageVision(first), "The active contact owns the preparation budget")
    XCTAssertNil(try store.loadTargetRenderReceipt(request.id))
    model.inputGate.endContact(source: contact)
    try await waitUntil { try store.loadTargetRenderReceipt(request.id) != nil }
    let receipt = try XCTUnwrap(store.loadTargetRenderReceipt(request.id))
    XCTAssertEqual(receipt.status, "ready", "\(receipt.diagnostics)")
    XCTAssertTrue(receipt.diagnostics.isEmpty)
    XCTAssertTrue(store.hasCurrentPageVision(first))
    XCTAssertTrue(receipt.inkRegions.isEmpty, "A text or interactive layer is not Pencil ink")
    XCTAssertEqual(model.presence, original)
    XCTAssertEqual(model.presence?.notebookPageID, selectedID)
    XCTAssertNil(model.pages[firstID], "An addressed ink request cannot import its owner into the live working set")
    XCTAssertLessThanOrEqual(model.pages.count, 4)
    XCTAssertTrue(SceneRenderResources.shared.diagnostics(for: first.elements).isEmpty)
    XCTAssertNil(SceneRenderResources.shared.image(for: first.elements[0]),
      "The ink-only path must not prepare the page's HTML layer")
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.targetPNGURL(request.id).path),
      "The ink map is not an all-layer target snapshot")
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertEqual(try visionIDs(store), Set([selectedID, first.id].map { $0.uuidString.lowercased() }))
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved)
  }

  @MainActor
  func testCapturedInkRequestCannotPublishTheNextDrawingUnderTheOldIdentity() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = NotebookStore(root: root)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    removeAfterShutdown(model, root: root)
    let contact = UUID()
    model.inputGate.beginContact(source: contact)
    await model.start(pageSize: .init(width: 100, height: 140))
    let page = try XCTUnwrap(model.activePage)
    let captured = try await requestVision(page, model: model)
    let stamp = try XCTUnwrap(model.reserveDrawingAction(pageID: page.id))
    let change = await model.acceptDrawingAction(.init(tool: .pen, samples: [.init(point: .init(x: 30, y: 40),
      timeOffset: 0, width: 6, opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)]), pageID: page.id, stamp: stamp).value
    XCTAssertNotNil(change)
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved)
    model.inputGate.endContact(source: contact)
    try await waitUntil { model.permitsBackgroundPreparation }
    do {
      try await CurrentViewPreviewWriter.writeTarget(captured, model: model)
      XCTFail("A captured source must not silently follow new ink")
    } catch {
      XCTAssertEqual(String(describing: error), "sourceChanged")
    }
    if let receipt = try store.loadTargetRenderReceipt(captured.id) {
      XCTAssertNotEqual(receipt.status, "ready")
    }
  }

  @MainActor
  func testShutdownDrainsPublisherAndIgnoresLateSnapshotNotifications() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = NotebookStore(root: root)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    removeAfterShutdown(model, root: root)
    await model.start(pageSize: .init(width: 100, height: 140))
    let page = try XCTUnwrap(model.activePage)
    try await waitUntil { store.hasCurrentPageVision(page) }
    let stopped = await model.shutdown()
    XCTAssertTrue(stopped)
    let cursor = try store.currentReadCursor()
    let before = try store.loadRuntimeStatus()?.updatedAt
    for _ in 0..<8 {
      NotificationCenter.default.post(name: DocumentSnapshotCache.didChange, object: UUID())
      NotificationCenter.default.post(name: SceneRenderResources.didChange, object: nil)
    }
    try await Task.sleep(for: .milliseconds(1_200))
    XCTAssertEqual(try store.currentReadCursor(), cursor, "Shutdown acknowledges only after every accepted writer has drained")
    XCTAssertEqual(try store.loadRuntimeStatus()?.updatedAt, before,
      "A late snapshot callback cannot restart the stopped publisher's reconciliation")
  }

  @MainActor
  private func requestVision(_ page: PageDocument, model: NotebookAppModel) async throws -> TargetRenderRequest {
    var command = NotebookCommand(command: .pageVision)
    command.target = .init(kind: .page, id: page.id)
    command.expectedRevision = page.drawingStamp.revision
    return try await model.executeLocalCommand(command).decode(TargetRenderRequest.self)
  }

  @MainActor
  private func removeAfterShutdown(_ model: NotebookAppModel, root: URL) {
    addTeardownBlock { @MainActor in
      let stopped = await model.shutdown()
      XCTAssertTrue(stopped, "The test must not remove a store still owned by accepted work")
      guard stopped else { return }
      try FileManager.default.removeItem(at: root)
    }
  }

  private func visionIDs(_ store: NotebookStore) throws -> Set<String> {
    Set(try FileManager.default.contentsOfDirectory(atPath: store.root.appendingPathComponent("previews").path)
      .filter { $0.hasSuffix(".vision.json") }.map { String($0.dropLast(".vision.json".count)) })
  }

  @MainActor
  private func waitUntil(_ condition: () throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(40)) }
    XCTAssertTrue(try condition(), "The bounded publisher did not complete the requested page")
  }
}

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
    _ = try store.loadOrCreateSpatialInk(actor: actor)
    let firstID = try XCTUnwrap(workspace.selectedPageID)
    var first = try XCTUnwrap(pages[firstID])
    XCTAssertTrue(first.replaceElements([.init(id: "not-part-of-ink-\(UUID())", kind: .web,
      frame: .init(x: 2, y: 2, width: 90, height: 60), source: "An offscreen interactive source",
      html: "<h1>Not ink</h1>", javaScript: "throw Error('must not execute for ink map')")], actor: actor))
    try store.savePage(first)
    pages[first.id] = first
    let before = workspace, beforeBoard = try store.loadBoard(items: workspace.items)
    var hierarchy = beforeBoard, createdPages: [PageDocument] = []
    for number in 1..<64 {
      let created = try XCTUnwrap(workspace.createNotebook(title: "Source \(number)", actor: actor, pageSize: size))
      createdPages.append(created.page)
      XCTAssertTrue(hierarchy.addItem(created.item.id, to: workspace.rootBoardID, near: .zero, actor: actor))
    }
    let selectedID = try XCTUnwrap(workspace.selectedPageID)
    XCTAssertNotEqual(selectedID, firstID)
    // Fixture pages have the same atomic membership admission as native
    // creation, not a direct writer that can publish an orphaned page first.
    _ = try store.saveWorkspaceEdits(before: before, after: workspace,
      boardBefore: beforeBoard, boardAfter: hierarchy, pages: createdPages)
    let selectedPage = try store.loadPage(selectedID)
    let selectedItemID = workspace.selectedItemID
    let selectedCenter = try XCTUnwrap(hierarchy.board(workspace.rootBoardID)?.focusedCenter(of: selectedItemID))
    try store.savePresence(.init(boardID: workspace.rootBoardID, mode: .page,
      camera: .init(center: selectedCenter, scale: 1), viewport: .init(x: size.width, y: size.height),
      focusedItemID: selectedItemID, openProgress: 1, selectedItemID: selectedItemID, notebookPageID: selectedID))
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    removeAfterShutdown(model, root: root)
    await model.start(pageSize: size)
    XCTAssertEqual(try store.workspaceHeader().itemCount, 64)
    let canonicalPageCount = try store.readItemHeaders(limit: 128).reduce(0) { count, item in
      count + item.pageCount
    }
    XCTAssertEqual(canonicalPageCount, 64)
    XCTAssertLessThanOrEqual(model.pages.count, 4, "The live model is a bounded working set, not the saved archive")
    XCTAssertNotNil(model.pages[selectedID])
    XCTAssertNil(model.pages[firstID])
    try await waitUntil { store.hasCurrentPageVision(selectedPage) }
    XCTAssertEqual(try visionIDs(store), [selectedID.uuidString.lowercased()])

    // A different page advances the workspace cursor, not the selected pixels.
    try await waitUntil { try store.loadCurrentViewReceipt()?.presence.notebookPageID == selectedID }
    let pngBefore = try FileManager.default.attributesOfItem(atPath: store.currentViewPreviewURL.path)[.modificationDate] as? Date
    let visionBefore = try FileManager.default.attributesOfItem(atPath: store.previewVisionReceiptURL(selectedID).path)[.modificationDate] as? Date
    let beforeIdentity = try PreviewSourceIdentity.read(store, presence: XCTUnwrap(model.observedPresence))
    var unrelated = first
    XCTAssertTrue(unrelated.replaceElements([], actor: actor))
    try store.savePage(unrelated)
    let afterIdentity = try PreviewSourceIdentity.read(store, presence: XCTUnwrap(model.observedPresence))
    XCTAssertEqual(beforeIdentity, afterIdentity)
    await model.reloadExternalChanges()?.value
    try await Task.sleep(for: .milliseconds(1_200))
    try await waitUntil { try store.loadCurrentViewReceipt()?.workspaceStamp == store.workspaceHeader().stamp }
    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: store.currentViewPreviewURL.path)[.modificationDate] as? Date, pngBefore)
    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: store.previewVisionReceiptURL(selectedID).path)[.modificationDate] as? Date, visionBefore)
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
    let change = model.acceptDrawingAction(.init(tool: .pen, samples: [.init(point: .init(x: 30, y: 40),
      timeOffset: 0, width: 6, opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)]), pageID: page.id, stamp: stamp)
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
  func testQueuedCurrentViewDoesNotPublishAfterCameraChanges() async throws {
    try await assertQueuedCurrentViewIsRevoked(by: .camera)
  }

  @MainActor
  func testQueuedCurrentViewDoesNotPublishDuringNewInput() async throws {
    try await assertQueuedCurrentViewIsRevoked(by: .input)
  }

  @MainActor
  func testQueuedCurrentViewDoesNotPublishAfterPublisherCancellation() async throws {
    try await assertQueuedCurrentViewIsRevoked(by: .shutdown)
  }

  @MainActor
  func testBoardSelectionUpdatesReceiptWithoutRewritingTheSamePixels() async throws {
    let (model, store, queue, firstItemID) = try await boardPreviewFixture()
    let before = try XCTUnwrap(store.loadCurrentViewReceipt())
    let png = try Data(contentsOf: store.currentViewPreviewURL)
    // A fixed old timestamp makes an unnecessary same-byte atomic rewrite
    // observable independently of filesystem timestamp resolution.
    let publishedAt = Date(timeIntervalSince1970: 1_000)
    try FileManager.default.setAttributes([.modificationDate: publishedAt], ofItemAtPath: store.currentViewPreviewURL.path)
    model.selectItem(firstItemID)
    let selected = try XCTUnwrap(model.observedPresence)
    XCTAssertNotEqual(selected.selectedItemID, before.presence.selectedItemID)
    XCTAssertEqual(selected.camera, before.presence.camera)
    XCTAssertEqual(selected.mode, .board)
    try await waitUntil { try store.loadCurrentViewReceipt()?.presence == selected }
    try await waitUntil { queue.pendingCount == 0 }
    let receipt = try XCTUnwrap(store.loadCurrentViewReceipt())
    XCTAssertEqual(receipt.presence, selected, "Selection is current receipt metadata even when it does not paint a pixel")
    XCTAssertEqual(receipt.pngSHA256, before.pngSHA256)
    XCTAssertEqual(try Data(contentsOf: store.currentViewPreviewURL), png)
    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: store.currentViewPreviewURL.path)[.modificationDate] as? Date,
      publishedAt, "Changing a board selection must not encode or replace the same PNG")
  }

  @MainActor
  func testRevokedMetadataRefreshRetriesTheSameSelectionAfterInputEnds() async throws {
    let (model, store, queue, firstItemID) = try await boardPreviewFixture()
    let beforeReceipt = try Data(contentsOf: store.currentViewRevisionURL)
    let beforePNG = try Data(contentsOf: store.currentViewPreviewURL)
    let publishedAt = Date(timeIntervalSince1970: 1_000)
    try FileManager.default.setAttributes([.modificationDate: publishedAt], ofItemAtPath: store.currentViewPreviewURL.path)
    // Metadata-only refresh reads its witnesses outside the FIFO. Blocking it
    // before selection therefore queues the final receipt write, not a render's
    // preliminary content read.
    let release = DispatchSemaphore(value: 0)
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let preparation = Task<@Sendable (NotebookStore) throws -> Void, Error> {
      return { _ in
        entered.continuation.yield(()); entered.continuation.finish()
        guard release.wait(timeout: .now() + 10) == .success else { throw PreviewBarrierTimeout() }
      }
    }
    let blocked = queue.enqueuePreparedCommand(preparation)
    defer { release.signal() }
    for await _ in entered.stream { break }
    model.selectItem(firstItemID)
    let selected = try XCTUnwrap(model.observedPresence)
    let acceptedSelectionCount = queue.pendingCount
    XCTAssertGreaterThan(acceptedSelectionCount, 1, "The real selection command is accepted behind the barrier")
    try await waitUntil { queue.pendingCount > acceptedSelectionCount }
    let contact = UUID()
    model.inputGate.beginContact(source: contact)
    defer { model.inputGate.endContact(source: contact) }
    XCTAssertFalse(model.permitsBackgroundPreparation)
    let inspected = AsyncThrowingStream<(Data, SessionPresence), Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
    queue.enqueueCommand { store in
      (try Data(contentsOf: store.currentViewRevisionURL), try store.loadPresence())
    } completion: { result in
      switch result {
      case .success(let value): inspected.continuation.yield(value); inspected.continuation.finish()
      case .failure(let error): inspected.continuation.finish(throwing: error)
      }
    }
    release.signal()
    try await blocked.value
    var iterator = inspected.stream.makeAsyncIterator()
    let inspectedValue = try await iterator.next()
    let (receiptDuringInput, savedPresence) = try XCTUnwrap(inspectedValue)
    XCTAssertEqual(savedPresence.selectedItemID, selected.selectedItemID,
      "The accepted selection still persists: only derived publication is revoked")
    XCTAssertEqual(receiptDuringInput, beforeReceipt, "A queued metadata-only refresh must respect input revocation")
    XCTAssertNil(queue.failure)

    // There is deliberately no second selection, camera edit or notification.
    // The same demand must become eligible again when the contact ends.
    model.inputGate.endContact(source: contact)
    try await waitUntil { try store.loadCurrentViewReceipt()?.presence == selected }
    XCTAssertEqual(model.observedPresence, selected)
    XCTAssertEqual(try Data(contentsOf: store.currentViewPreviewURL), beforePNG)
    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: store.currentViewPreviewURL.path)[.modificationDate] as? Date,
      publishedAt, "Retrying receipt metadata must not regenerate already current pixels")
  }

  private enum PreviewRevocation { case camera, input, shutdown }
  private struct PreviewBarrierTimeout: Error {}

  @MainActor
  private func assertQueuedCurrentViewIsRevoked(by revocation: PreviewRevocation,
    file: StaticString = #filePath, line: UInt = #line) async throws {
    let (model, store, queue, _) = try await boardPreviewFixture()
    let beforePNG = try Data(contentsOf: store.currentViewPreviewURL)
    let beforeReceipt = try Data(contentsOf: store.currentViewRevisionURL)
    let initial = try XCTUnwrap(model.observedPresence)
    let rendering = initial.replacingCamera(.init(center: initial.camera.center.offsetBy(x: 20, y: 10), scale: initial.camera.scale))
    model.updatePresence(rendering, settled: true)
    let persisted = await model.finishPendingPersistence()
    XCTAssertTrue(persisted)
    // The publisher's normal delayed render first reads addressed materials on
    // the FIFO. Put the barrier immediately behind that read, not in front of
    // it: rendering can finish, while its final publication must wait.
    let deadline = ContinuousClock.now + .seconds(8)
    while queue.pendingCount == 0 && ContinuousClock.now < deadline { await Task.yield() }
    XCTAssertGreaterThan(queue.pendingCount, 0, "The normal publisher must reach its content read", file: file, line: line)
    let release = DispatchSemaphore(value: 0)
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let preparation = Task<@Sendable (NotebookStore) throws -> Void, Error> {
      return { _ in
        entered.continuation.yield(()); entered.continuation.finish()
        guard release.wait(timeout: .now() + 10) == .success else { throw PreviewBarrierTimeout() }
      }
    }
    let blocked = queue.enqueuePreparedCommand(preparation)
    defer { release.signal() }
    for await _ in entered.stream { break }
    try await waitUntil { queue.pendingCount >= 2 }
    XCTAssertEqual(try Data(contentsOf: store.currentViewRevisionURL), beforeReceipt,
      "Fixture barrier must precede publication, not capture an already published frame", file: file, line: line)

    let contact = UUID()
    var shutdown: Task<Bool, Never>?
    switch revocation {
    case .camera:
      let changed = rendering.replacingCamera(.init(center: rendering.camera.center.offsetBy(x: 40, y: 30), scale: rendering.camera.scale))
      model.updatePresence(changed, settled: true)
      // Deliver ordinary Observation callbacks while the derived write is
      // still queued. This is not a direct cancellation of the render task.
      for _ in 0..<8 { await Task.yield() }
    case .input:
      model.inputGate.beginContact(source: contact)
      XCTAssertFalse(model.permitsBackgroundPreparation)
      for _ in 0..<8 { await Task.yield() }
    case .shutdown:
      shutdown = Task { await model.shutdown() }
      while model.shutdownPhase == .running && ContinuousClock.now < deadline { await Task.yield() }
      XCTAssertNotEqual(model.shutdownPhase, .running)
    }
    // This accepted command must still execute. Revoking derived publication
    // must never cancel the shared FIFO or unrelated accepted work.
    let inspected = AsyncThrowingStream<(Data, Data), Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
    queue.enqueueCommand { store in
      (try Data(contentsOf: store.currentViewPreviewURL), try Data(contentsOf: store.currentViewRevisionURL))
    } completion: { result in
      switch result {
      case .success(let value): inspected.continuation.yield(value); inspected.continuation.finish()
      case .failure(let error): inspected.continuation.finish(throwing: error)
      }
    }
    release.signal()
    try await blocked.value
    var iterator = inspected.stream.makeAsyncIterator()
    let observed = try await iterator.next()
    let (png, receipt) = try XCTUnwrap(observed)
    XCTAssertEqual(png, beforePNG, "A revoked queued render must not publish its old camera PNG", file: file, line: line)
    XCTAssertEqual(receipt, beforeReceipt, "A revoked queued render must not publish a receipt", file: file, line: line)
    if revocation == .input { model.inputGate.endContact(source: contact) }
    if let shutdown { let stopped = await shutdown.value; XCTAssertTrue(stopped) }
  }

  @MainActor
  private func boardPreviewFixture() async throws -> (NotebookAppModel, NotebookStore, NotebookPersistenceQueue, UUID) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = NotebookStore(root: root), actor = UUID()
    let size = PageSize(width: 100, height: 140)
    var (workspace, _) = try store.loadOrCreate(actor: actor, pageSize: size)
    _ = try store.loadOrCreateSpatialInk(actor: actor)
    let firstItemID = workspace.selectedItemID
    let before = workspace, beforeBoard = try store.loadBoard(items: workspace.items)
    var hierarchy = beforeBoard
    let created = try XCTUnwrap(workspace.createNotebook(title: "Second", actor: actor, pageSize: size))
    XCTAssertTrue(hierarchy.addItem(created.item.id, to: workspace.rootBoardID, near: .zero, actor: actor))
    _ = try store.saveWorkspaceEdits(before: before, after: workspace,
      boardBefore: beforeBoard, boardAfter: hierarchy, pages: [created.page])
    try store.savePresence(.init(boardID: workspace.rootBoardID, mode: .board,
      camera: .init(center: .zero, scale: 0.2), viewport: .init(x: 120, y: 160),
      selectedItemID: created.item.id, notebookPageID: created.page.id))
    let queue = NotebookPersistenceQueue(store: store)
    let model = NotebookAppModel(store: store, startsNearbySync: false, persistenceQueue: queue)
    removeAfterShutdown(model, root: root)
    await model.start(pageSize: size)
    try await waitUntil { try store.loadCurrentViewReceipt()?.presence == model.observedPresence }
    try await waitUntil { store.hasCurrentPageVision(created.page) && queue.pendingCount == 0 }
    return (model, store, queue, firstItemID)
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
  private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ condition: () throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(40)) }
    XCTAssertTrue(try condition(), "The bounded publisher did not complete the requested page", file: file, line: line)
  }
}

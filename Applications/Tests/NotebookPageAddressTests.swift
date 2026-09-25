import CSQLite
import Foundation
import XCTest
@testable import NotebookCore
@testable import Notebook

final class NotebookPageAddressTests: XCTestCase {
  /// Holds an actual WAL read after its requested body/history have been read.
  /// It neither replaces the read result nor occupies the application's writer.
  private final class PageReadGate: @unchecked Sendable {
    let captured: XCTestExpectation
    private let bodyQuery: String
    private let lock = NSLock()
    private let releaseSignal = DispatchSemaphore(value: 0)
    private var reads = 0
    private var held = false
    private var expired = false
    var bodyReads: Int { lock.withLock { reads } }
    var didHold: Bool { lock.withLock { held } }
    var timedOut: Bool { lock.withLock { expired } }

    init(pageID: UUID, captured: XCTestExpectation) {
      bodyQuery = "SELECT b.data FROM records r JOIN blobs b ON b.hash=r.hash WHERE r.file='pages/"
        + pageID.uuidString.lowercased() + ".json'"
      self.captured = captured
    }

    func release() { releaseSignal.signal() }

    private func visit(_ sql: String) {
      let shouldHold = lock.withLock { () -> Bool in
        if sql == bodyQuery { reads += 1 }
        guard sql == "COMMIT", reads == 1, !held else { return false }
        held = true
        return true
      }
      if shouldHold {
        captured.fulfill()
        let result = releaseSignal.wait(timeout: .now() + 10)
        lock.withLock { expired = result == .timedOut }
      }
    }

    func install(on reader: NotebookSceneReader) async throws {
      let result = try await reader.read { [self] store in
        let database = try XCTUnwrap(store.currentSQL)
        return sqlite3_trace_v2(database.handle, UInt32(SQLITE_TRACE_STMT), { _, context, statement, _ in
          guard let context, let statement,
            let text = sqlite3_expanded_sql(OpaquePointer(statement)) else { return 0 }
          defer { sqlite3_free(text) }
          Unmanaged<PageReadGate>.fromOpaque(context).takeUnretainedValue().visit(String(cString: text))
          return 0
        }, Unmanaged.passUnretained(self).toOpaque())
      }
      XCTAssertEqual(result, SQLITE_OK)
    }

    func uninstall(from reader: NotebookSceneReader) async throws {
      release()
      let result = try await reader.read { store in
        sqlite3_trace_v2(try XCTUnwrap(store.currentSQL).handle, 0, nil, nil)
      }
      XCTAssertEqual(result, SQLITE_OK)
    }
  }

  @MainActor
  private func preparationFixture() async throws ->
    (model: NotebookAppModel, reader: NotebookSceneReader, item: UUID, ids: [UUID], order: String) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = NotebookStore(root: root), actor = UUID(), size = NotebookAppModel.defaultPageSize
    _ = try store.initializeWorkspace(actor: actor, pageSize: size)
    var workspace = try store.loadIndex()
    let item = workspace.selectedItemID, first = try XCTUnwrap(workspace.selectedPageID)
    let presence = SessionPresence(boardID: workspace.rootBoardID, mode: .page, camera: .init(),
      viewport: .init(x: 834, y: 1194), focusedItemID: item, openProgress: 1,
      selectedItemID: item, notebookPageID: first)
    try store.savePresence(presence)
    var ids = [first]
    for _ in 1..<8 {
      let appended = try XCTUnwrap(workspace.appendPage(in: item, actor: actor, pageSize: size))
      _ = try store.saveWorkspaceSelection(index: workspace, createdPage: appended.createdPage)
      ids.append(appended.pageID)
    }
    try store.savePresence(presence)
    let reader = NotebookSceneReader(store: store)
    let model = NotebookAppModel(store: store, startsNearbySync: false, sceneReader: reader)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: size)
    await model.prepareNotebookPage(at: 1, in: item)
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    let order = try XCTUnwrap(model.notebookPageRoot(item))
    XCTAssertEqual(model.activePage?.id, first)
    XCTAssertNil(model.notebookPage(at: 6, in: item))
    model.retainNotebookPageWindow([0, 1, 6], in: item, root: order)
    return (model, reader, item, ids, order)
  }

  @MainActor
  private func installPageReadGate(_ reader: NotebookSceneReader, pageID: UUID) async throws -> PageReadGate {
    let gate = PageReadGate(pageID: pageID, captured: expectation(description: "Addressed page snapshot captured"))
    // XCTest tears this down before the model, retaining the callback context
    // until SQLite no longer references it, even when an assertion throws.
    addTeardownBlock { try await gate.uninstall(from: reader) }
    try await gate.install(on: reader)
    return gate
  }

  @MainActor
  private func assertPreparedPageRebindReusesGeometry(elementCount: Int) async throws {
    let f = try await preparationFixture(), model = f.model
    let workspace = try XCTUnwrap(model.workspace), boardID = workspace.rootBoardID
    let stamp = workspace.stamp
    let elements = (0..<elementCount).map { index in
      SpatialElement(id: "retained-\(index)", surface: .board(boardID), kind: .nativeText,
        frame: .init(x: 0, y: 0, width: 100, height: 80), worldOrigin: .zero,
        source: "Retained", html: "", stamp: stamp)
    }
    let hierarchy = BoardHierarchy(rootBoardID: boardID, boards: [.init(id: boardID,
      board: .init(freeItems: [.init(itemID: f.item, center: .zero, zIndex: 0, stamp: stamp)],
        elements: elements, stamp: stamp))], stamp: stamp)
    let original = WorkspaceSceneIndex(workspace: workspace, hierarchy: hierarchy, paperSizes: [:])
    let bounds = WorkspaceSpatialBounds(origin: .init(x: -1000, y: -1000), width: 2000, height: 2000)
    let first = try XCTUnwrap(original.readPaintOrder(boardID: boardID, bounds: bounds))
    let cursor = try XCTUnwrap(first.next, "A continuation belongs to the actual spatial tree, not the scene UUID")
    let presence = try XCTUnwrap(model.presence)
    let oldFrame = WorkspaceSceneFrame(index: original, presence: presence, portalCamera: { _ in nil })
    XCTAssertNil(original.pageOwner(pageID: f.ids[6]))
    await model.prepareNotebookPage(at: 6, in: f.item)
    let current = try XCTUnwrap(model.workspace)
    XCTAssertTrue(current.selectedItem.pageIDs.contains(f.ids[6]))
    let started = ContinuousClock.now
    let rebound = WorkspaceSceneIndex(workspace: current, hierarchy: hierarchy, paperSizes: [:], reusing: original)
    let elapsed = started.duration(to: .now)
    let measurement = XCTAttachment(string: "objects: \(elementCount); catalog rebind: \(elapsed)")
    measurement.name = "Prepared catalog reuses the retained spatial tree"
    measurement.lifetime = .keepAlways; add(measurement)
    XCTAssertEqual(rebound.generationID, original.generationID)
    XCTAssertEqual(rebound.pageOwner(pageID: f.ids[6]), f.item)
    XCTAssertNil(original.pageOwner(pageID: f.ids[6]), "A previously shown cohort is an immutable source cut")
    XCTAssertEqual(original.capturedWorkspace, workspace)
    XCTAssertEqual(rebound.capturedWorkspace, current)
    XCTAssertEqual(rebound.renderedItem(id: f.item, presence: presence)?.item, current.item(id: f.item))
    XCTAssertEqual(original.renderedItem(id: f.item, presence: presence)?.item, workspace.item(id: f.item))
    let next = try XCTUnwrap(rebound.readPaintOrder(boardID: boardID, bounds: bounds, after: cursor))
    let expected = try XCTUnwrap(original.readPaintOrder(boardID: boardID, bounds: bounds, after: cursor))
    XCTAssertEqual(next.entries.map(\.id), expected.entries.map(\.id),
      "Rebuilding a tree with a copied scene UUID must not satisfy this continuation")
    let newFrame = WorkspaceSceneFrame(index: rebound, presence: presence, portalCamera: { _ in nil })
    XCTAssertEqual(newFrame.sourceIdentity, oldFrame.sourceIdentity)
    if elementCount == 64 {
      let resized = WorkspaceSceneIndex(workspace: current, hierarchy: hierarchy,
        paperSizes: [UUID(): .a4], reusing: rebound)
      XCTAssertNotEqual(resized.generationID, rebound.generationID)
    }
  }

  @MainActor
  func testPreparedPageCatalogRebindPreservesExactTreesAndFrozenOwners() async throws {
    try await assertPreparedPageRebindReusesGeometry(elementCount: 64)
  }

  @MainActor
  func testPreparedPageCatalogRebindReusesTheHundredThousandObjectIndex() async throws {
    try await assertPreparedPageRebindReusesGeometry(elementCount: 100_000)
  }

  @MainActor
  func testPreparedNeighbourReusesThePreparedPageComposition() async throws {
    let f = try await preparationFixture(), model = f.model
    let presence = try XCTUnwrap(model.presence)
    var phases: [String] = []
    model.compositionTiles.onPreparationPhase = { _, phase in phases.append(phase) }
    defer { model.compositionTiles.onPreparationPhase = nil; model.compositionTiles.cancelPreparation() }
    @MainActor func prepare() async throws -> WorkspaceSceneIndex {
      let deadline = ContinuousClock.now + .seconds(10)
      while model.scenePreparationPending, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      guard !model.scenePreparationPending, model.permitsScenePreparation else {
        throw NSError(domain: "NotebookPageAddressTests", code: 1, userInfo: [NSLocalizedDescriptionKey:
          "The current scene did not admit preparation"])
      }
      let index = try XCTUnwrap(model.sceneIndex)
      let frame = WorkspaceSceneFrame(index: index, presence: presence,
        portalCamera: { model.scenePortalCamera(boardID: $0) }, pinned: [.item(f.item)])
      model.prepareComposition(presence: presence, frame: frame, pinned: [.item(f.item)],
        displayScale: 2, installedItemOwners: [f.item: presence.boardID])
      while model.compositionTiles.isPreparing, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      guard !model.compositionTiles.isPreparing, model.compositionTiles.failure == nil,
        model.compositionTiles.published != nil else {
        throw NSError(domain: "NotebookPageAddressTests", code: 2, userInfo: [NSLocalizedDescriptionKey:
          model.compositionTiles.failure ?? "The stationary page composition was not prepared"])
      }
      return index
    }
    // Exercise the production composition owner directly, as the SQL
    // composition suite does. No mounted PageTurnSurface is given a foreign
    // prewarm window, and preparation is not claimed as installed pixel proof.
    let index = try await prepare(), shown = try XCTUnwrap(model.compositionTiles.published)
    XCTAssertTrue(phases.contains("plan") && phases.contains("live_source") && phases.contains("native_ink"),
      "Positive control: the observer sees actual initial planning, SQL source work and native preparation: \(phases)")
    XCTAssertNil(model.notebookPage(at: 6, in: f.item))
    let geometryGeneration = model.sceneIndexGeneration, publication = model.scenePublicationGeneration
    let revision = try XCTUnwrap(model.workspaceHeader).cursor
    let rasters = shown.rasters.mapValues(\.entryID)
    phases.removeAll()
    await model.prepareNotebookPage(at: 6, in: f.item)
    XCTAssertNotNil(model.notebookPage(at: 6, in: f.item))
    let current = try await prepare()
    XCTAssertEqual(model.presence, presence, "This admission neither navigates nor moves the camera")
    XCTAssertEqual(model.sceneIndexGeneration, geometryGeneration)
    XCTAssertEqual(current.generationID, index.generationID)
    XCTAssertGreaterThan(model.scenePublicationGeneration, publication)
    XCTAssertEqual(current.pageOwner(pageID: f.ids[6]), f.item)
    XCTAssertNil(index.pageOwner(pageID: f.ids[6]))
    XCTAssertEqual(model.workspaceHeader?.cursor, revision, "This is read projection churn, not a content edit")
    XCTAssertEqual(model.compositionTiles.published?.id, shown.id)
    XCTAssertEqual(model.compositionTiles.published?.rasters.mapValues(\.entryID), rasters)
    XCTAssertTrue(phases.isEmpty, "Catalog-only publication must reuse paint without plan, SQL/live-source or native preparation: \(phases)")
  }

  @MainActor
  func testUnrelatedPresenceAndSelectionReuseThePageBodyWithoutHoldingTheWriter() async throws {
    let f = try await preparationFixture(), model = f.model
    let gate = try await installPageReadGate(f.reader, pageID: f.ids[6])
    defer { gate.release() }
    let preparation = Task { await model.prepareNotebookPage(at: 6, in: f.item) }
    await fulfillment(of: [gate.captured], timeout: 2)
    XCTAssertTrue(gate.didHold, "The requested body must run through the supplied read owner")
    XCTAssertEqual(model.selectNotebookPage(1, notebookID: f.item, expectedRoot: f.order), 1)
    let selected = try XCTUnwrap(model.presence), contact = UUID()
    model.inputGate.beginPencilAction(source: contact)
    let moved = SessionPresence(boardID: selected.boardID, mode: selected.mode,
      camera: .init(center: .init(x: 20, y: 30), scale: 1.4), viewport: selected.viewport,
      focusedItemID: selected.focusedItemID, openProgress: selected.openProgress,
      selectedItemID: selected.selectedItemID, notebookPageID: selected.notebookPageID)
    model.updatePresence(moved, settled: false)
    model.inputGate.endPencilAction(source: contact)
    model.updatePresence(moved, settled: true)
    let acceptedPresence = try XCTUnwrap(model.presence)
    XCTAssertNotEqual(acceptedPresence.camera, selected.camera, "Negative control: a real camera change was accepted")
    let writerFinished = expectation(description: "Accepted writes are not behind the page read")
    let writer = Task {
      defer { writerFinished.fulfill() }
      return try await model.performStoreCommand { try $0.loadPresence().notebookPageID }
    }
    await fulfillment(of: [writerFinished], timeout: 2)
    XCTAssertFalse(gate.timedOut)
    gate.release()
    let savedSelection = try await writer.value
    XCTAssertEqual(savedSelection, f.ids[1])
    await preparation.value
    XCTAssertEqual(gate.bodyReads, 1, "Unrelated epochs may revalidate metadata, not decode the same page again")
    XCTAssertEqual(model.workspace?.selectedPageID, f.ids[1], "A captured WorkspaceIndex cannot overwrite current selection")
    XCTAssertEqual(model.presence?.notebookPageID, f.ids[1])
    XCTAssertEqual(model.presence?.camera, acceptedPresence.camera)
    XCTAssertEqual(model.notebookPage(at: 6, in: f.item)?.id, f.ids[6])
  }

  @MainActor
  func testTargetChangeDuringPagePreparationRejectsTheOldBodyAndUndoHistory() async throws {
    let f = try await preparationFixture(), model = f.model
    let gate = try await installPageReadGate(f.reader, pageID: f.ids[6])
    defer { gate.release() }
    let preparation = Task { await model.prepareNotebookPage(at: 6, in: f.item) }
    await fulfillment(of: [gate.captured], timeout: 2)
    XCTAssertTrue(gate.didHold)
    let actor = model.actorID, pageID = f.ids[6]
    let action = PageInkAction(tool: .pen, samples: [.init(point: .init(x: 40, y: 40),
      timeOffset: 0, width: 4, opacity: 1, force: 1, azimuth: 0, altitude: 1)])
    let writerFinished = expectation(description: "Target mutation commits while the old WAL snapshot is held")
    let writer = Task {
      defer { writerFinished.fulfill() }
      try await model.performStoreCommand(publishesChanges: true) { store in
        let page = try store.loadPage(pageID)
        let stamp = try XCTUnwrap(page.drawingStamp.advanced(by: actor))
        let change = try page.prepareInkChange(.append(action), stamp: stamp)
        _ = try store.commitPageInk(pageID: pageID, command: .init(change))
      }
    }
    await fulfillment(of: [writerFinished], timeout: 2)
    XCTAssertFalse(gate.timedOut)
    gate.release(); try await writer.value; await preparation.value
    let page = try XCTUnwrap(model.notebookPage(at: 6, in: f.item))
    XCTAssertEqual(try page.inkDrawing().action(id: action.id)?.isActive, true,
      "A completed target write invalidates the captured body even without a SwiftUI echo")
    XCTAssertEqual(gate.bodyReads, 2, "Only changed source requires another body decode")
    XCTAssertEqual(model.selectNotebookPage(6, notebookID: f.item, expectedRoot: f.order), 6)
    let inverse = try XCTUnwrap(model.acceptDrawingUndo(), "History must come from the same current cut as the body")
    XCTAssertEqual(inverse.drawing.action(id: action.id)?.isActive, false)
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    XCTAssertEqual(try model.store.loadPage(pageID).inkDrawing().action(id: action.id)?.isActive, false)
  }

  @MainActor
  func testWithdrawalDuringTheActualPageReadCannotReplaceTheRetainedWindow() async throws {
    let f = try await preparationFixture(), model = f.model
    model.retainNotebookPageWindow([0, 1, 2, 3], in: f.item, root: f.order)
    for index in 2...3 { await model.prepareNotebookPage(at: index, in: f.item) }
    let retained = (0...3).compactMap { model.notebookPage(at: $0, in: f.item)?.id }
    XCTAssertEqual(retained, Array(f.ids.prefix(4)))
    let gate = try await installPageReadGate(f.reader, pageID: f.ids[6])
    defer { gate.release() }
    model.retainNotebookPageWindow([0, 1, 3, 6], in: f.item, root: f.order)
    let preparation = Task { await model.prepareNotebookPage(at: 6, in: f.item) }
    await fulfillment(of: [gate.captured], timeout: 2)
    XCTAssertTrue(gate.didHold)
    model.retainNotebookPageWindow([0, 1, 2, 3], in: f.item, root: f.order)
    gate.release(); await preparation.value
    XCTAssertFalse(gate.timedOut)
    XCTAssertNil(model.notebookPage(at: 6, in: f.item))
    XCTAssertEqual((0...3).compactMap { model.notebookPage(at: $0, in: f.item)?.id }, retained)
    XCTAssertEqual(model.pages.count, 4)
    XCTAssertEqual(model.workspace?.selectedPageID, f.ids[0])
  }

  @MainActor
  func testUnchangedReloadRetainsThePreparedPageSourceIdentity() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    let page = try XCTUnwrap(model.activePage)
    _ = page.graphicGraph()
    await model.reloadExternalChanges()?.value
    let after = try XCTUnwrap(model.activePage)
    XCTAssertEqual(after, page)
    XCTAssertEqual(after.elementSourceIdentity, page.elementSourceIdentity,
      "An unchanged SQL read cannot invalidate the live page's graph, viewport and installed material receipt")
    let changed = PageDocument(id: page.id, size: page.size, actor: page.agentStamp.actor,
      elements: [.init(id: "new-source", kind: .nativeText,
        frame: .init(x: 20, y: 20, width: 200, height: 80), source: "Changed material", html: "")])
    XCTAssertEqual(changed.agentStamp, page.agentStamp, "Negative control: stamps alone are insufficient")
    let read = try NotebookSceneState.read(store: model.store, presence: model.presence,
      viewport: try XCTUnwrap(model.presence).viewport, reusingPages: [page.id: changed])
    XCTAssertEqual(read.pages[page.id]?.elements, page.elements)
    XCTAssertNotEqual(read.pages[page.id]?.elementSourceIdentity, changed.elementSourceIdentity,
      "A different same-stamp candidate must not replace the accepted disk source")
    var edited = page
    XCTAssertTrue(edited.replaceElements(changed.elements, actor: model.actorID))
    try model.store.savePage(edited)
    await model.reloadExternalChanges()?.value
    let replaced = try XCTUnwrap(model.activePage)
    XCTAssertEqual(replaced.elements, changed.elements)
    XCTAssertNotEqual(replaced.elementSourceIdentity, page.elementSourceIdentity)
  }
  @MainActor
  func testAWithdrawnNeighbourReadCannotEvictTheCurrentPageWindow() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let item = try XCTUnwrap(model.workspace?.selectedItemID)
    for index in 1..<8 {
      XCTAssertEqual(model.selectNotebookPage(index, notebookID: item, expectedRoot: model.notebookPageRoot(item)!), index)
    }
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    let order = try XCTUnwrap(model.notebookPageRoot(item))
    await model.prepareNotebookPage(at: 0, in: item)
    _ = model.selectNotebookPage(0, notebookID: item, expectedRoot: order)
    model.retainNotebookPageWindow([0, 1, 2, 3], in: item, root: order)
    for index in 1...3 { await model.prepareNotebookPage(at: index, in: item) }
    let drained = await model.finishPendingPersistence(); XCTAssertTrue(drained)
    let expected = try (0...3).map { try XCTUnwrap(model.notebookPage(at: $0, in: item)?.id) }
    XCTAssertNil(model.notebookPage(at: 6, in: item))

    for reenter in [false, true] {
      // Pause storage, not MainActor. A direction change withdraws the old read
      // while it waits behind an accepted write; the next swipe can demand it again.
      let (entered, start) = AsyncStream<Void>.makeStream()
      let release = DispatchSemaphore(value: 0)
      let writer = Task {
        try await model.performStoreCommand { _ in
          start.yield(); start.finish(); _ = release.wait(timeout: .now() + 5)
        }
      }
      defer { release.signal() }
      for await _ in entered { break }
      model.retainNotebookPageWindow([0, 1, 3, 6], in: item, root: order)
      let obsolete = Task { await model.prepareNotebookPage(at: 6, in: item) }
      await Task.yield()
      model.retainNotebookPageWindow([0, 1, 2, 3], in: item, root: order)
      var renewed: Task<Void, Never>?
      if reenter {
        model.retainNotebookPageWindow([0, 1, 3, 6], in: item, root: order)
        renewed = Task { await model.prepareNotebookPage(at: 6, in: item) }
        await Task.yield()
      }
      release.signal(); try await writer.value; await obsolete.value; await renewed?.value
      if reenter {
        XCTAssertNotNil(model.notebookPage(at: 6, in: item), "A renewed consumer cannot inherit the withdrawn read's cancellation")
        XCTAssertTrue([0, 1, 3, 6].allSatisfy { model.notebookPage(at: $0, in: item) != nil })
      } else {
        XCTAssertNil(model.notebookPage(at: 6, in: item), "Withdrawn preparation cannot occupy a live page slot")
        XCTAssertEqual((0...3).compactMap { model.notebookPage(at: $0, in: item)?.id }, expected,
          "A completed obsolete read must not remove a sheet already admitted for immediate reverse")
      }
      XCTAssertEqual(model.activePage?.id, expected[0])
      XCTAssertEqual(model.pages.count, 4)
    }
  }

  @MainActor
  func testColdNotebookReadsCurrentPaperBeforeUnrequestedPageBodies() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = NotebookStore(root: root), actor = UUID()
    let size = NotebookAppModel.defaultPageSize
    _ = try store.initializeWorkspace(actor: actor, pageSize: size)
    var workspace = try store.loadIndex()
    let itemID = workspace.selectedItemID, firstID = try XCTUnwrap(workspace.selectedPageID)
    let presence = SessionPresence(boardID: workspace.rootBoardID, mode: .page, camera: .init(),
      viewport: .init(x: 834, y: 1194), focusedItemID: itemID, openProgress: 1,
      selectedItemID: itemID, notebookPageID: firstID)
    try store.savePresence(presence)
    var appended: [UUID] = []
    for index in 1..<4 {
      let value = try XCTUnwrap(workspace.appendPage(in: itemID, actor: actor, pageSize: size))
      var page = try XCTUnwrap(value.createdPage)
      if index > 1 {
        page = PageDocument(id: page.id, size: size, actor: actor, elements: [.init(id: "far-source", kind: .markdown,
          frame: .init(x: 20, y: 20, width: 300, height: 200),
          source: String(repeating: "Far paper.", count: 60_000), html: "<p>Far paper</p>")])
      }
      _ = try store.saveWorkspaceSelection(index: workspace, createdPage: page)
      appended.append(page.id)
    }
    try store.savePresence(presence)
    XCTAssertThrowsError(try store.readTransaction { store in
      try store.currentSQL!.limitReads(.init(rows: 512, bytes: 256 * 1_024, valueBytes: 64 * 1_024,
        reason: "whole_directory_body_negative_control"))
      return try store.readNotebookPageWindow(itemID: itemID, pages: ([firstID] + appended).map { .page($0) })
    }, "Reading all directory bodies, as cold startup previously did, exceeds the same budget")
    let cold = try store.readTransaction { store in
      try store.currentSQL!.limitReads(.init(rows: 512, bytes: 256 * 1_024, valueBytes: 64 * 1_024,
        reason: "cold_notebook_current_paper"))
      return try NotebookSceneState.read(store: store, presence: presence, viewport: presence.viewport)
    }
    XCTAssertEqual(Set(cold.pages.keys), [firstID])
    XCTAssertEqual(cold.pagePositions.count, 4, "The directory remains independent from its page bodies")
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: size)
    XCTAssertEqual(model.notebookPageCount(itemID), 4)
    XCTAssertEqual(model.activePage?.id, firstID)
    XCTAssertNil(model.notebookPage(at: 3, in: itemID))
    await model.prepareNotebookPage(at: 3, in: itemID)
    XCTAssertEqual(model.notebookPage(at: 3, in: itemID)?.id, appended[2])
    XCTAssertEqual(model.notebookPage(at: 3, in: itemID)?.elements.first?.source.count, 600_000)
  }

  @MainActor
  func testCoverageRetainsThePreparedDistantUUIDInsteadOfReinterpretingItsIndex() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let itemID = try XCTUnwrap(model.workspace?.selectedItemID)
    for index in 1..<12 {
      XCTAssertEqual(model.selectNotebookPage(index, notebookID: itemID, expectedRoot: model.notebookPageRoot(itemID) ?? ""), index)
    }
    var saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    await model.prepareNotebookPage(at: 0, in: itemID)
    _ = model.selectNotebookPage(0, notebookID: itemID, expectedRoot: model.notebookPageRoot(itemID) ?? "")
    saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    await model.prepareNotebookPage(at: 9, in: itemID)
    let prepared = try XCTUnwrap(model.notebookPage(at: 9, in: itemID)), presence = try XCTUnwrap(model.presence)
    // A real coverage request republishes metadata without reading page bodies.
    let distant = SessionPresence(boardID: presence.boardID, mode: .page,
      camera: .init(center: .init(x: 40_000, y: 40_000), scale: 1), viewport: presence.viewport,
      focusedItemID: itemID, openProgress: 1, selectedItemID: itemID, notebookPageID: presence.notebookPageID)
    model.updatePresence(distant, settled: true)
    _ = model.sceneWorkset(presence: distant)
    saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    XCTAssertEqual(model.notebookPage(at: 9, in: itemID)?.id, prepared.id)
    await model.reloadExternalChanges()?.value
    saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    XCTAssertEqual(model.notebookPage(at: 9, in: itemID)?.id, prepared.id)
    XCTAssertEqual(model.selectNotebookPage(9, notebookID: itemID, expectedRoot: model.notebookPageRoot(itemID) ?? ""), 9)
    XCTAssertEqual(model.presence?.notebookPageID, prepared.id)
    XCTAssertLessThanOrEqual(model.pages.count, 4)
  }

  @MainActor
  func testConcurrentDurableAppendReconcilesTheAcceptedUUIDAtItsActualTail() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    var saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    let itemID = try XCTUnwrap(model.workspace?.selectedItemID), oldRoot = try XCTUnwrap(model.notebookPageRoot(itemID))
    var peer = try model.store.loadIndex()
    let append = try XCTUnwrap(peer.appendPage(in: itemID, actor: UUID(), pageSize: NotebookAppModel.defaultPageSize))
    _ = try model.store.saveWorkspaceSelection(index: peer, createdPage: append.createdPage)
    XCTAssertEqual(model.selectNotebookPage(1, notebookID: itemID, expectedRoot: oldRoot), 1)
    let acceptedID = try XCTUnwrap(model.presence?.notebookPageID)
    saved = await model.finishPendingPersistence(); XCTAssertTrue(saved, model.persistenceFailure ?? "")
    XCTAssertEqual(model.notebookPageCount(itemID), 3)
    XCTAssertEqual(model.presence?.notebookPageID, acceptedID)
    XCTAssertEqual(model.notebookPageIndex(acceptedID, in: itemID), 2)
    XCTAssertEqual(try model.store.resolveNotebookPage(append.pageID, in: itemID)?.index, 1)
    XCTAssertEqual(try model.store.resolveNotebookPage(acceptedID, in: itemID)?.index, 2)
  }

  @MainActor
  func testOneHundredThousandSheetsUseBoundedSceneAndDistantUUIDNavigation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-page-address-" + UUID().uuidString)
    let store = NotebookStore(root: root), actor = UUID(), itemID = UUID()
    let size = NotebookAppModel.defaultPageSize
    let ids = try await Task.detached {
      // The archive-sized constructor is a seed only. No UI read below receives
      // this array, its causal fields, or a complete workspace snapshot.
      let pages = (0..<100_000).map { _ in PageDocument(size: size, actor: actor) }
      let workspace = WorkspaceIndex(items: [.notebook(id: itemID, title: "100000 sheets", pageIDs: pages.map(\.id))],
        selectedItemID: itemID, selectedPageID: pages[50_000].id, stamp: .init(counter: 0, actor: actor))
      let board = BoardHierarchy.initial(rootBoardID: workspace.rootBoardID, itemIDs: [itemID], actor: actor)
      try store.commandTransaction {
        for page in pages { try store.savePage(page) }
        try store.saveWorkspaceBundle(index: workspace, page: pages[0], board: board)
        try store.saveSpatialInk(.init(stamp: workspace.stamp))
        try store.savePresence(.init(boardID: workspace.rootBoardID, mode: .page, camera: .init(), viewport: .init(x: 834, y: 1194),
          focusedItemID: itemID, openProgress: 1, selectedItemID: itemID, notebookPageID: pages[50_000].id))
      }
      // An unrequested membership's encoded body cannot be read accidentally.
      // Its indexed UUID/position and immutable order remain intact.
      let database = try NotebookSQLConnection(url: store.databaseURL, writable: true)
      let address = "workspace.json#/items/@" + itemID.uuidString.lowercased() + "/pageIDs/@" + pages[17].id.uuidString.lowercased()
      try database.run("UPDATE blobs SET data=? WHERE hash=(SELECT hash FROM records WHERE address=?)", [.blob(Data("{".utf8)), .text(address)])
      return (pages[0].id, pages[50_000].id, pages[77_777].id, pages.last!.id)
    }.value
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: size)
    let drained = await model.finishPendingPersistence()
    XCTAssertTrue(drained, model.persistenceFailure ?? "")
    XCTAssertEqual(model.loadState, .ready)
    XCTAssertEqual(model.notebookPageCount(itemID), 100_000)
    XCTAssertEqual(model.presence?.notebookPageID, ids.1)
    XCTAssertEqual(model.notebookPageIndex(ids.1, in: itemID), 50_000)
    XCTAssertLessThanOrEqual(model.pages.count, 4)
    XCTAssertLessThanOrEqual(try XCTUnwrap(model.workspace?.selectedItem.pageIDs.count), 5)
    XCTAssertNil(model.notebookPage(at: 77_777, in: itemID), "Unloaded existing paper is not a ready blank")
    await model.prepareNotebookPage(at: 77_777, in: itemID)
    let readRoot = try XCTUnwrap(model.notebookPageRoot(itemID))
    XCTAssertEqual(model.notebookPage(at: 77_777, in: itemID)?.id, ids.2)
    XCTAssertEqual(model.selectNotebookPage(77_777, notebookID: itemID, expectedRoot: readRoot), 77_777)
    XCTAssertEqual(model.presence?.notebookPageID, ids.2)
    XCTAssertLessThanOrEqual(model.pages.count, 4)
    let resolved = await model.navigateToNotebookPage(id: ids.3, isCurrent: { true })
    XCTAssertTrue(resolved)
    XCTAssertEqual(model.notebookPageIndex(ids.3, in: itemID), 99_999)
    XCTAssertEqual(model.selectNotebookPage(100_000, notebookID: itemID, expectedRoot: readRoot), 100_000)
    let newID = try XCTUnwrap(model.presence?.notebookPageID)
    XCTAssertNil(model.selectNotebookPage(0, notebookID: itemID, expectedRoot: readRoot), "A previous root cannot commit a newly interpreted slot")
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved, model.persistenceFailure ?? "")
    XCTAssertEqual(try store.resolveNotebookPage(newID, in: itemID)?.index, 100_000)
    XCTAssertEqual(model.notebookPageCount(itemID), 100_001)
    XCTAssertLessThanOrEqual(model.pages.count, 4)
    XCTAssertLessThanOrEqual(try XCTUnwrap(model.workspace?.selectedItem.pageIDs.count), 5)
  }
}

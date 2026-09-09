import AppKit
import NotebookCore
import XCTest
@testable import Notebook

final class MacModelLifecycleTests: XCTestCase {
  @MainActor
  func testCoherentIPCReadsDoNotCreateDurableChanges() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fixture = MacCommandFixture(root: root)
    retainNotebookUntilTeardown(fixture.model, removing: root)
    try await fixture.start()
    let saved = await fixture.model.finishPendingPersistence()
    XCTAssertTrue(saved)
    let cursor = try fixture.store.currentChangeCursor()
    let header = try await fixture.read(.init(kind: .workspaceHeader)).decode(NotebookWorkspaceHeader.self)
    for _ in 0..<5 {
      let next = try await fixture.read(.init(kind: .workspaceHeader)).decode(NotebookWorkspaceHeader.self)
      XCTAssertEqual(next.stamp, header.stamp)
      _ = try await fixture.read(.init(kind: .actions, limit: 10))
      _ = try await fixture.read(.init(kind: .contexts, limit: 10))
    }
    XCTAssertEqual(try fixture.store.currentChangeCursor(), cursor,
      "A read does not become another publication or trigger synchronization echo")
    for name in ["workspace.json", "board.json", "pages", "documents", "spatial-ink.json"] {
      XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path))
    }
  }

  @MainActor
  func testAtomicIncomingCatalogPreservesIndependentLocalBoardAndPortalEdits() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fixture = MacCommandFixture(root: root), peer = UUID()
    retainNotebookUntilTeardown(fixture.model, removing: root)
    let store = fixture.store, model = fixture.model
    try await fixture.start()
    let childID = try XCTUnwrap(model.createBoard(at: .zero))
    XCTAssertTrue(model.enterBoard(childID))
    let notebookID = try XCTUnwrap(model.createNotebook(at: .zero))
    let created = await model.finishPendingPersistence()
    XCTAssertTrue(created)
    let remote = NotebookStore(root: root.appendingPathComponent("peer"))
    try NotebookPeerFixture.copy(from: store, to: remote, peerID: model.actorID)
    var incomingIndex = try remote.loadIndex()
    var incomingBoard = try remote.loadBoard(items: incomingIndex.items)
    let item = try XCTUnwrap(incomingIndex.createDocument(title: "Remote document", actor: peer))
    XCTAssertTrue(incomingBoard.addItem(item.id, to: incomingIndex.rootBoardID, near: .zero, actor: peer))
    try remote.saveDocumentWorkspaceBundle(index: incomingIndex,
      document: .init(id: item.id, actor: peer, blocks: [.markdown(id: "body", source: "# Delivered")]),
      state: .init(id: item.id, actor: peer), board: incomingBoard)

    let movedCenter = WorldPoint(x: 370, y: -240)
    model.moveItem(notebookID, to: movedCenter)
    let childPresence = SessionPresence(boardID: childID, mode: .board,
      camera: .init(center: movedCenter, scale: 0.51), viewport: .init(x: 834, y: 1_194))
    model.updatePresence(childPresence, settled: true)
    XCTAssertTrue(model.leaveBoard())
    let humanSelection = model.presence?.selectedItemID
    let humanSaved = await model.finishPendingPersistence()
    XCTAssertTrue(humanSaved)

    try await NotebookPeerFixture.deliver(from: remote, to: model, peerID: peer)
    try await fixture.waitUntil { model.workspace?.item(id: item.id) != nil }
    let published = try store.loadBoard(items: store.loadIndex().items)
    XCTAssertEqual(try store.workspaceHeader().itemCount, incomingIndex.items.count)
    XCTAssertEqual(try store.loadDocument(item.id).blocks.first?.source, "# Delivered")
    XCTAssertEqual(model.presence?.selectedItemID, humanSelection,
      "A peer catalogue publication cannot change the human's local selection")
    XCTAssertEqual(published.board(childID)?.focusedCenter(of: notebookID), movedCenter)
    XCTAssertEqual(published.portalCamera(childID), BoardPortalProjection.portalCamera(
      from: childPresence.camera, viewport: childPresence.viewport))
    let cursor = try store.currentChangeCursor()
    try await NotebookPeerFixture.deliver(from: remote, to: model, peerID: peer)
    XCTAssertEqual(try store.currentChangeCursor(), cursor, "A durable retransmission is idempotent")
  }

  @MainActor
  func testPortalExitPreservesAnIndependentIPCBoardEdit() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fixture = MacCommandFixture(root: root)
    retainNotebookUntilTeardown(fixture.model, removing: root)
    let store = fixture.store, model = fixture.model
    try await fixture.start()
    let notebookID = try XCTUnwrap(model.presence?.selectedItemID)
    let boardID = try XCTUnwrap(model.workspace?.rootBoardID)
    let childID = try XCTUnwrap(model.createBoard(at: .zero))
    XCTAssertTrue(model.enterBoard(childID))
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved)
    let movedCenter = WorldPoint(x: 1_400, y: 320)
    try await fixture.move(notebookID, boardID: boardID, to: movedCenter)
    model.updatePresence(.init(boardID: childID, mode: .board,
      camera: .init(center: .init(x: 90, y: 120), scale: 0.7), viewport: .init(x: 834, y: 1_194)), settled: true)
    XCTAssertTrue(model.leaveBoard())
    let exitSaved = await model.finishPendingPersistence()
    XCTAssertTrue(exitSaved, model.persistenceFailure ?? "")
    XCTAssertEqual(try store.readBoardItem(notebookID)?.board.focusedCenter(of: notebookID), movedCenter)
    let published = try XCTUnwrap(store.readBoardNodeHeader(childID))
    XCTAssertEqual(published.portalCamera, BoardPortalProjection.portalCamera(
      from: .init(center: .init(x: 90, y: 120), scale: 0.7), viewport: .init(x: 834, y: 1_194)))
  }
  @MainActor
  func testElementEditingSessionIsTheSingleTransientOwner() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)

    let model = NotebookAppModel(
      store: NotebookStore(root: root),
      startsNearbySync: false
    )
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let page = try XCTUnwrap(model.activePage)
    let pageReference = EditableElementReference.page(
      pageID: page.id,
      elementID: "page-element"
    )
    let boardReference = EditableElementReference.spatial(
      elementID: "board-element"
    )

    model.selectElementTool()
    model.selectElement(pageReference)
    model.updateElementDrag(
      pageReference,
      translation: SpatialPoint(x: 32, y: 48)
    )
    XCTAssertEqual(model.elementEditingSession.selection, pageReference)
    XCTAssertEqual(
      model.elementEditingSession.translation,
      SpatialPoint(x: 32, y: 48)
    )

    model.selectElement(boardReference)
    XCTAssertEqual(model.elementEditingSession.selection, boardReference)
    XCTAssertEqual(model.elementEditingSession.translation, .zero)

    model.updateElementDrag(
      pageReference,
      translation: SpatialPoint(x: 500, y: 500)
    )
    XCTAssertEqual(model.elementEditingSession.selection, boardReference)
    XCTAssertEqual(model.elementEditingSession.translation, .zero)

    model.finishElementDrag(
      pageReference,
      translation: SpatialPoint(x: 500, y: 500)
    )
    XCTAssertEqual(model.elementEditingSession.selection, boardReference)

    model.selectDrawingTool(.eraser)
    XCTAssertFalse(model.isElementEditingEnabled)
    XCTAssertEqual(model.elementEditingSession, ElementEditingSession())
  }

  @MainActor
  func testPersonCanMoveAndRemoveIPCAuthoredElements() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fixture = MacCommandFixture(root: root)
    retainNotebookUntilTeardown(fixture.model, removing: root)
    let store = fixture.store, model = fixture.model
    try await fixture.start(showingPage: true)
    let page = try XCTUnwrap(model.activePage)
    let pageTarget = CollaborationTarget(kind: .page, id: page.id)
    try await fixture.apply([.init(kind: .insertElement, target: pageTarget, id: "shared-shape", values: [
      "kind": .string("web"), "source": .string(""), "html": .string("<svg></svg>"),
      "frame": try .encode(PageRect(x: 100, y: 120, width: 240, height: 180))])])
    try await fixture.waitUntil { model.pages[page.id]?.elements.first?.id == "shared-shape" }
    XCTAssertTrue(model.transformPageElement(pageID: page.id, elementID: "shared-shape", by: .init(x: 10_000, y: -10_000)))
    let moved = try XCTUnwrap(model.pages[page.id]?.elements.first)
    XCTAssertEqual(moved.frame.x, page.size.width - 240)
    XCTAssertEqual(moved.frame.y, 0)
    XCTAssertTrue(model.transformPageElement(pageID: page.id, elementID: moved.id, by: .zero, resizeBy: .init(x: -40, y: 80)))
    let resized = try XCTUnwrap(model.pages[page.id]?.elements.first)
    XCTAssertEqual(resized.frame.width, 200)
    XCTAssertEqual(resized.frame.height, 260)
    XCTAssertEqual(resized.source, moved.source)
    XCTAssertEqual(resized.state, moved.state)
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved)

    let itemID = try XCTUnwrap(model.presence?.selectedItemID)
    let boardID = try XCTUnwrap(model.presence?.boardID)
    let coverTarget = CollaborationTarget(kind: .cover, id: itemID, boardID: boardID)
    try await fixture.apply([.init(kind: .insertElement, target: coverTarget, id: "shared-cover-shape", values: [
      "kind": .string("web"), "source": .string(""), "html": .string("<svg></svg>"),
      "frame": try .encode(SpatialRect(x: 90, y: 110, width: 260, height: 190))])])
    try await fixture.waitUntil { model.board?.elements.contains(where: { $0.id == "shared-cover-shape" }) == true }
    XCTAssertTrue(model.transformSpatialElement(elementID: "shared-cover-shape", by: .init(x: -10_000, y: 10_000)))
    let movedCover = try XCTUnwrap(model.board?.elements.first(where: { $0.id == "shared-cover-shape" }))
    XCTAssertEqual(movedCover.frame.x, 0)
    XCTAssertEqual(movedCover.frame.y, WorkspaceItemGeometry.notebook.height - 190)
    XCTAssertTrue(model.removePageElement(pageID: page.id, elementID: moved.id))
    XCTAssertTrue(model.removeSpatialElement(elementID: movedCover.id))
    let removed = await model.finishPendingPersistence()
    XCTAssertTrue(removed)
    XCTAssertTrue(model.pages[page.id]?.elements.isEmpty == true)
    XCTAssertTrue(try store.loadPage(page.id).elements.isEmpty)
    XCTAssertNil(try store.readSpatialElement(boardID: boardID, elementID: movedCover.id))
  }

  @MainActor
  func testSettledPageReadoutUsesTheVerifiedPageRaster() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)

    let fixture = MacCommandFixture(root: root)
    retainNotebookUntilTeardown(fixture.model, removing: root)
    let store = fixture.store, model = fixture.model
    try await fixture.start(showingPage: true)
    let page = try XCTUnwrap(model.activePage)
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(4)
    var current: CurrentViewReceipt?
    var vision: PageVisionReceipt?
    repeat {
      try await Task.sleep(for: .milliseconds(20))
      current = try? JSONDecoder().decode(
        CurrentViewReceipt.self,
        from: Data(contentsOf: store.currentViewRevisionURL)
      )
      vision = try? JSONDecoder().decode(
        PageVisionReceipt.self,
        from: Data(contentsOf: store.previewVisionReceiptURL(page.id))
      )
    } while (current == nil || vision == nil) && clock.now < deadline

    let receipt = try XCTUnwrap(current)
    let pageVision = try XCTUnwrap(vision)
    guard case .page(_, let revision, let snapshotHash) = receipt.surface else {
      return XCTFail("Текущий вид должен принадлежать листу")
    }
    XCTAssertEqual(revision.pageID, page.id)
    let composed = try await PageCompositionRenderer.render(page) { _ in
      throw CocoaError(.featureUnsupported)
    }
    XCTAssertEqual(snapshotHash, PageVisionRenderer.sha256(composed.png),
      "The current surface certifies the common physical composition, not the separately encoded ink-map preview")
    XCTAssertEqual(pageVision.pageID, page.id)
    XCTAssertEqual(pageVision.drawingStamp, page.drawingStamp)
    XCTAssertEqual(pageVision.previewPNG_SHA256,
      PageVisionRenderer.sha256(try Data(contentsOf: store.previewURL(page.id))))

    let data = try Data(contentsOf: store.currentViewPreviewURL)
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
    var saturatedRedPixels = 0
    for y in stride(from: 0, to: bitmap.pixelsHigh, by: 16) {
      for x in stride(from: 0, to: bitmap.pixelsWide, by: 16) {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
        else { continue }
        if color.redComponent > 0.8,
          color.greenComponent < 0.3,
          color.blueComponent < 0.3
        {
          saturatedRedPixels += 1
        }
      }
    }
    XCTAssertEqual(saturatedRedPixels, 0)
  }

  @MainActor
  func testVisualReadoutPublishesIPCChangesWithoutAMountedWindow() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fixture = MacCommandFixture(root: root)
    retainNotebookUntilTeardown(fixture.model, removing: root)
    let store = fixture.store, model = fixture.model
    try await fixture.start(showingPage: true)
    try await fixture.waitUntil(seconds: 3) { (try? store.loadCurrentViewReceipt()) != nil }
    let original = try XCTUnwrap(store.loadCurrentViewReceipt())
    XCTAssertEqual(original.workspaceStamp, model.workspace?.stamp)
    XCTAssertEqual(original.presence, model.presence)
    XCTAssertEqual(original.renderViewport, .init(x: NotebookAppModel.defaultPageSize.width, y: NotebookAppModel.defaultPageSize.height))
    let itemID = try XCTUnwrap(model.presence?.selectedItemID), boardID = try XCTUnwrap(model.presence?.boardID)
    try await fixture.move(itemID, boardID: boardID, to: .init(x: 700, y: 900))
    let revision = try XCTUnwrap(store.workspaceHeader().boardRevision)
    try await fixture.waitUntil(seconds: 3) { (try? store.loadCurrentViewReceipt())?.boardRevision == revision }
    XCTAssertNotEqual(revision, original.boardRevision)
    XCTAssertEqual(try store.readBoardItem(itemID)?.board.focusedCenter(of: itemID), .init(x: 700, y: 900))
  }

  @MainActor
  func testIPCCommitReloadsWithoutAMountedWindow() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fixture = MacCommandFixture(root: root), center = WorldPoint(x: 740, y: 960)
    retainNotebookUntilTeardown(fixture.model, removing: root)
    let model = fixture.model
    try await fixture.start()
    let boardID = try XCTUnwrap(model.presence?.boardID), itemID = try XCTUnwrap(model.presence?.selectedItemID)
    try await fixture.move(itemID, boardID: boardID, to: center)
    try await fixture.waitUntil { model.board?.focusedCenter(of: itemID) == center }
    XCTAssertEqual(try fixture.store.readBoardItem(itemID)?.board.focusedCenter(of: itemID), center)
  }

  @MainActor
  func testVisualReadoutReachesFinalPageAfterAnIPCInkBurst() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fixture = MacCommandFixture(root: root)
    retainNotebookUntilTeardown(fixture.model, removing: root)
    let store = fixture.store, model = fixture.model
    try await fixture.start(showingPage: true)
    let page = try XCTUnwrap(model.activePage), target = CollaborationTarget(kind: .page, id: try XCTUnwrap(model.activePage).id)
    for counter in 1...24 {
      try await fixture.apply([.init(kind: .appendInkStroke, target: target, id: UUID().uuidString, values: [
        "width": .number(4), "points": .array([
          .object(["x": .number(20), "y": .number(20)]),
          .object(["x": .number(Double(40 + counter)), "y": .number(40)])])])])
    }
    let final = try store.loadPage(page.id)
    XCTAssertEqual(try PageInkDrawing.decode(final.drawingData).activeActions.count, 24)
    try await fixture.waitUntil(seconds: 5) {
      (try? store.loadPageVisionReceipt(page.id))?.drawingStamp == final.drawingStamp
    }
    XCTAssertEqual(model.pages[page.id]?.drawingStamp, final.drawingStamp)
  }

  @MainActor
  func testIPCDocumentBundleAndPatchPreserveHumanSelectionWithoutAMountedWindow() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fixture = MacCommandFixture(root: root)
    retainNotebookUntilTeardown(fixture.model, removing: root)
    let model = fixture.model, store = fixture.store
    try await fixture.start()
    let human = model.presence
    let boardID = try XCTUnwrap(human?.boardID), documentID = UUID()
    try await fixture.apply([.init(kind: .createDocument, target: .init(kind: .board, id: boardID), id: documentID.uuidString, values: [
      "title": .string("MCP"), "center": try .encode(WorldPoint.zero), "paperSize": .string("a4"),
      "blocks": try .encode([DocumentBlock.markdown(id: "body", source: "# Первый текст")])])])
    try await fixture.waitUntil { model.workspace?.item(id: documentID) != nil }
    XCTAssertEqual(try store.loadDocument(documentID).blocks.first?.source, "# Первый текст")
    XCTAssertEqual(model.presence?.selectedItemID, human?.selectedItemID)
    XCTAssertEqual(model.presence?.camera, human?.camera)
    model.selectItem(documentID)
    let selected = await model.finishPendingPersistence()
    XCTAssertTrue(selected)
    try await fixture.apply([.init(kind: .updateBlock, target: .init(kind: .document, id: documentID), id: "body",
      values: ["source": .string("# Изменено агентом")])])
    try await fixture.waitUntil { model.documents[documentID]?.blocks.first?.source == "# Изменено агентом" }
    XCTAssertEqual(try store.loadDocument(documentID).blocks.first?.source, "# Изменено агентом")
    XCTAssertEqual(model.presence?.selectedItemID, documentID)
  }
}

import AppKit
import NotebookCore
import PencilKit
import XCTest
@testable import Notebook

final class MacModelLifecycleTests: XCTestCase {
  @MainActor
  func testCoherentReadsLeaveTheWatchedDirectoryQuiet() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let store = NotebookStore(root:root), actor = UUID()
    _ = try store.loadOrCreate(actor:actor,pageSize:.init(width:834,height:1194))
    _ = try store.loadOrCreateSpatialInk(actor:actor)
    try store.migrateCollaborationStorage()
    var notifications = 0
    let watcher = DirectoryWatcher(urls:[root,store.collaborationURL]) { notifications += 1 }
    watcher.start(); defer { watcher.stop() }
    for _ in 0..<5 { _ = try store.collaborationSnapshot(); _ = try store.collaborationActions() }
    try await Task.sleep(for:.milliseconds(250))
    XCTAssertEqual(notifications,0,"Завершённое чтение сохраняет файловое наблюдение спокойным")
  }

  @MainActor
  func testIncomingCatalogPreservesIndependentLocalBoardAndPortalEdits() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = NotebookStore(root: root)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    model.start(pageSize: NotebookAppModel.defaultPageSize)
    let childID = try XCTUnwrap(model.createBoard(at: .zero))
    model.enterBoard(childID)
    let notebookID = try XCTUnwrap(model.createNotebook(at: .zero))
    var incomingIndex = try XCTUnwrap(model.workspace)
    var incomingBoard = try XCTUnwrap(model.boardHierarchy)
    let actor = UUID()
    let documentItem = try XCTUnwrap(incomingIndex.createDocument(
      title: "Remote document",
      actor: actor
    ))
    XCTAssertTrue(incomingBoard.addItem(
      documentItem.id,
      to: incomingIndex.rootBoardID,
      near: .zero,
      actor: actor
    ))
    let movedCenter = WorldPoint(x: 370, y: -240)
    model.moveItem(notebookID, to: movedCenter)
    let childPresence = SessionPresence(
      boardID: childID,
      mode: .board,
      camera: SpatialCamera(center: movedCenter, scale: 0.51),
      viewport: SpatialPoint(x: 834, y: 1_194)
    )
    model.updatePresence(childPresence, settled: true)
    XCTAssertTrue(model.leaveBoard())
    // Selection on exit advances the local catalog. Give the remote catalog
    // the later selection while keeping its independently captured board.
    XCTAssertTrue(incomingIndex.selectItem(childID, actor: actor))
    XCTAssertTrue(incomingIndex.selectItem(documentItem.id, actor: actor))
    XCTAssertGreaterThan(incomingIndex.stamp, model.workspace!.stamp)

    model.receivePeerMessage(.board(incomingBoard))
    model.receivePeerMessage(.document(DocumentDocument(
      id: documentItem.id,
      actor: actor,
      blocks: [.markdown(id: "body", source: "# Delivered")]
    )))
    model.receivePeerMessage(.documentState(DocumentStateJournal(
      id: documentItem.id,
      actor: actor
    )))
    model.receivePeerMessage(.index(incomingIndex))

    XCTAssertEqual(model.workspace, incomingIndex)
    let published = try store.loadBoard(items: incomingIndex.items)
    XCTAssertEqual(model.boardHierarchy, published)
    XCTAssertEqual(published.board(childID)?.focusedCenter(of: notebookID), movedCenter)
    XCTAssertEqual(published.portalCamera(childID), BoardPortalProjection.portalCamera(
      from: childPresence.camera, viewport: childPresence.viewport
    ))
  }

  @MainActor
  func testPortalExitMergesAnIndependentBoardEditAlreadyOnDisk() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = NotebookStore(root: root)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    model.start(pageSize: NotebookAppModel.defaultPageSize)
    let notebookID = try XCTUnwrap(model.workspace?.selectedItemID)
    let childID = try XCTUnwrap(model.createBoard(at: .zero))
    model.enterBoard(childID)
    var diskBoard = try XCTUnwrap(model.boardHierarchy)
    let workspace = try XCTUnwrap(model.workspace)
    let movedCenter = WorldPoint(x: 1_400, y: 320)
    XCTAssertTrue(diskBoard.moveItem(
      notebookID,
      in: workspace.rootBoardID,
      to: movedCenter,
      actor: UUID()
    ))
    try store.saveBoard(diskBoard, items: workspace.items)
    model.updatePresence(SessionPresence(
      boardID: childID,
      mode: .board,
      camera: SpatialCamera(center: WorldPoint(x: 90, y: 120), scale: 0.7),
      viewport: SpatialPoint(x: 834, y: 1_194)
    ), settled: true)

    XCTAssertTrue(model.leaveBoard())

    let published = try store.loadBoard(items: workspace.items)
    XCTAssertEqual(model.boardHierarchy, published)
    XCTAssertEqual(
      published.board(workspace.rootBoardID)?.focusedCenter(of: notebookID),
      movedCenter
    )
  }

  @MainActor
  func testElementEditingSessionIsTheSingleTransientOwner() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let model = NotebookAppModel(
      store: NotebookStore(root: root),
      startsNearbySync: false
    )
    model.start(pageSize: NotebookAppModel.defaultPageSize)
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
  func testPersonCanMoveAndRemoveAgentElements() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = NotebookStore(root: root)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    model.start(pageSize: NotebookAppModel.defaultPageSize)
    let page = try XCTUnwrap(model.activePage)
    let remoteActor = UUID()
    let pageElement = AgentElement(
      id: "shared-shape",
      kind: .web,
      frame: PageRect(x: 100, y: 120, width: 240, height: 180),
      source: "",
      html: "<svg></svg>"
    )
    model.receivePeerMessage(
      .elements(
        pageID: page.id,
        elements: [pageElement],
        stamp: VersionStamp(counter: 1, actor: remoteActor),
        collaboration: nil
      )
    )

    XCTAssertTrue(
      model.transformPageElement(
        pageID: page.id,
        elementID: pageElement.id,
        by: SpatialPoint(x: 10_000, y: -10_000)
      )
    )
    let movedPageElement = try XCTUnwrap(
      model.pages[page.id]?.elements.first
    )
    XCTAssertEqual(movedPageElement.frame.x, page.size.width - 240)
    XCTAssertEqual(movedPageElement.frame.y, 0)
    let source = movedPageElement.source, state = movedPageElement.state
    XCTAssertTrue(model.transformPageElement(pageID: page.id, elementID: pageElement.id, by: .zero, resizeBy: .init(x: -40, y: 80)))
    let resized = try XCTUnwrap(model.pages[page.id]?.elements.first)
    XCTAssertEqual(resized.frame.width, 200)
    XCTAssertEqual(resized.frame.height, 260)
    XCTAssertEqual(resized.source, source)
    XCTAssertEqual(resized.state, state)


    let itemID = try XCTUnwrap(model.workspace?.selectedItemID)
    var board = try XCTUnwrap(model.boardHierarchy)
    let boardID = try XCTUnwrap(model.presence?.boardID)
    let coverElement = SpatialElement(
      id: "shared-cover-shape",
      surface: .cover(itemID),
      kind: .web,
      frame: SpatialRect(x: 90, y: 110, width: 260, height: 190),
      source: "",
      html: "<svg></svg>",
      stamp: VersionStamp(counter: 0, actor: remoteActor)
    )
    XCTAssertTrue(
      board.upsertElement(
        coverElement,
        in: boardID,
        expected: nil,
        actor: remoteActor
      )
    )
    model.receivePeerMessage(.board(board))

    XCTAssertTrue(
      model.transformSpatialElement(
        elementID: coverElement.id,
        by: SpatialPoint(x: -10_000, y: 10_000)
      )
    )
    let movedCoverElement = try XCTUnwrap(
      model.board?.elements.first(where: { $0.id == coverElement.id })
    )
    XCTAssertEqual(movedCoverElement.frame.x, 0)
    XCTAssertEqual(
      movedCoverElement.frame.y,
      WorkspaceItemGeometry.notebook.height - coverElement.frame.height
    )

    XCTAssertTrue(
      model.removePageElement(pageID: page.id, elementID: pageElement.id)
    )
    XCTAssertTrue(model.pages[page.id]?.elements.isEmpty == true)
    XCTAssertTrue(model.removeSpatialElement(elementID: coverElement.id))
    XCTAssertTrue(model.board?.elements.isEmpty == true)
    XCTAssertTrue(try store.loadPage(page.id).elements.isEmpty)
    XCTAssertTrue(
      try XCTUnwrap(
        store.loadBoard(items: model.workspace!.items).board(boardID)
      ).elements.isEmpty
    )
  }

  @MainActor
  func testSettledPageReadoutUsesTheVerifiedPageRaster() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = NotebookStore(root: root)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    model.start(pageSize: NotebookAppModel.defaultPageSize)
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
    XCTAssertEqual(snapshotHash, pageVision.previewPNG_SHA256)

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
  func testVisualReadoutPublishesWithoutAMountedWindow() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = NotebookStore(root: root)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    model.start(pageSize: NotebookAppModel.defaultPageSize)

    let clock = ContinuousClock()
    var deadline = clock.now + .seconds(3)
    while !FileManager.default.fileExists(
      atPath: store.currentViewRevisionURL.path
    ), clock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }

    var receipt = try JSONDecoder().decode(
      CurrentViewReceipt.self,
      from: Data(contentsOf: store.currentViewRevisionURL)
    )
    XCTAssertEqual(receipt.workspaceStamp, model.workspace?.stamp)
    XCTAssertEqual(receipt.presence, model.presence)
    XCTAssertEqual(
      receipt.renderViewport,
      SpatialPoint(
        x: NotebookAppModel.defaultPageSize.width,
        y: NotebookAppModel.defaultPageSize.height
      )
    )

    var changed = try XCTUnwrap(model.boardHierarchy)
    let workspace = try XCTUnwrap(model.workspace)
    let boardID = try XCTUnwrap(model.presence?.boardID)
    let itemID = try XCTUnwrap(model.workspace?.selectedItemID)
    XCTAssertTrue(
      changed.moveItem(
        itemID,
        in: boardID,
        to: WorldPoint(x: 700, y: 900),
        actor: UUID()
      )
    )
    try store.saveBoard(changed, items: workspace.items)
    deadline = clock.now + .seconds(3)
    repeat {
      try await Task.sleep(for: .milliseconds(20))
      receipt = try JSONDecoder().decode(
        CurrentViewReceipt.self,
        from: Data(contentsOf: store.currentViewRevisionURL)
      )
    } while receipt.boardRevision != changed.revision && clock.now < deadline

    XCTAssertEqual(model.boardHierarchy?.stamp, changed.stamp)
    XCTAssertEqual(receipt.boardRevision, changed.revision)
  }

  @MainActor
  func testMCPStyleFileChangeReloadsWithoutAMountedWindow() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = NotebookStore(root: root)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    model.start(pageSize: NotebookAppModel.defaultPageSize)

    var changed = try XCTUnwrap(model.boardHierarchy)
    let workspace = try XCTUnwrap(model.workspace)
    let boardID = try XCTUnwrap(model.presence?.boardID)
    let itemID = try XCTUnwrap(model.workspace?.selectedItemID)
    let center = WorldPoint(x: 740, y: 960)
    XCTAssertTrue(
      changed.moveItem(itemID, in: boardID, to: center, actor: UUID())
    )
    try store.saveBoard(changed, items: workspace.items)

    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(2)
    while model.boardHierarchy?.stamp != changed.stamp,
      clock.now < deadline
    {
      try await Task.sleep(for: .milliseconds(20))
    }

    XCTAssertEqual(model.boardHierarchy?.stamp, changed.stamp)
    XCTAssertEqual(model.board?.focusedCenter(of: itemID), center)
  }

  @MainActor
  func testVisualReadoutReachesFinalPageAfterABurst() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = NotebookStore(root: root)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    model.start(pageSize: NotebookAppModel.defaultPageSize)
    let page = try XCTUnwrap(model.activePage)
    let actor = UUID()
    var finalStamp = page.drawingStamp

    for counter in 1 ... 24 {
      finalStamp = VersionStamp(counter: UInt64(counter), actor: actor)
      let points = [
        PKStrokePoint(
          location: CGPoint(x: 20, y: 20),
          timeOffset: 0,
          size: CGSize(width: 4, height: 4),
          opacity: 1,
          force: 1,
          azimuth: 0,
          altitude: .pi / 2
        ),
        PKStrokePoint(
          location: CGPoint(x: 40 + counter, y: 40),
          timeOffset: 0.1,
          size: CGSize(width: 4, height: 4),
          opacity: 1,
          force: 1,
          azimuth: 0,
          altitude: .pi / 2
        ),
      ]
      let drawing = PKDrawing(strokes: [
        PKStroke(
          ink: PKInk(.monoline, color: .black),
          path: PKStrokePath(controlPoints: points, creationDate: Date())
        ),
      ])
      model.receivePeerMessage(.drawing(
        pageID: page.id,
        data: try PageInkMigration.importDrawing(drawing.dataRepresentation(), size: page.size).dataRepresentation(),
        stamp: finalStamp
      ))
      await Task.yield()
    }

    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(5)
    var receipt: PageVisionReceipt?
    repeat {
      try await Task.sleep(for: .milliseconds(20))
      receipt = try? JSONDecoder().decode(
        PageVisionReceipt.self,
        from: Data(contentsOf: store.previewVisionReceiptURL(page.id))
      )
    } while receipt?.drawingStamp != finalStamp && clock.now < deadline

    XCTAssertEqual(model.pages[page.id]?.drawingStamp, finalStamp)
    XCTAssertEqual(receipt?.drawingStamp, finalStamp)
  }

  @MainActor
  func testMCPDocumentBundleAndPatchReloadWithoutAMountedWindow() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = NotebookStore(root: root)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    model.start(pageSize: NotebookAppModel.defaultPageSize)
    let actor = UUID()
    var workspace = try XCTUnwrap(model.workspace)
    var board = try XCTUnwrap(model.boardHierarchy)
    let boardID = try XCTUnwrap(model.presence?.boardID)
    let item = try XCTUnwrap(
      workspace.createDocument(title: "MCP", actor: actor)
    )
    XCTAssertTrue(
      board.addItem(item.id, to: boardID, near: .zero, actor: actor)
    )
    var document = DocumentDocument(
      id: item.id,
      actor: actor,
      blocks: [.markdown(id: "body", source: "# Первый текст")]
    )
    let state = DocumentStateJournal(id: item.id, actor: actor)
    try store.saveDocumentWorkspaceBundle(
      index: workspace,
      document: document,
      state: state,
      board: board
    )

    let clock = ContinuousClock()
    var deadline = clock.now + .seconds(2)
    while model.documents[item.id]?.blocks.first?.source != "# Первый текст",
      clock.now < deadline
    {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(model.workspace?.selectedItemID, item.id)
    XCTAssertEqual(model.documents[item.id]?.blocks.first?.source, "# Первый текст")

    XCTAssertTrue(document.replaceBlockSource(
      id: "body",
      source: "# Изменено агентом",
      actor: actor
    ))
    try store.saveDocument(document)
    deadline = clock.now + .seconds(2)
    while model.documents[item.id]?.contentStamp != document.contentStamp,
      clock.now < deadline
    {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(
      model.documents[item.id]?.blocks.first?.source,
      "# Изменено агентом"
    )
  }
}

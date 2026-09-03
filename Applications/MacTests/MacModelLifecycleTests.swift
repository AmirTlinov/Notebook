import AppKit
import NotebookCore
import PencilKit
import XCTest
@testable import Notebook

final class MacModelLifecycleTests: XCTestCase {
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
        stamp: VersionStamp(counter: 1, actor: remoteActor)
      )
    )

    XCTAssertTrue(
      model.movePageElement(
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

    let itemID = try XCTUnwrap(model.workspace?.selectedItemID)
    var board = try XCTUnwrap(model.board)
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
      board.upsertElement(coverElement, expected: nil, actor: remoteActor)
    )
    model.receivePeerMessage(.board(board))

    XCTAssertTrue(
      model.moveSpatialElement(
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
      NotebookGeometry.height - coverElement.frame.height
    )

    XCTAssertTrue(
      model.removePageElement(pageID: page.id, elementID: pageElement.id)
    )
    XCTAssertTrue(model.pages[page.id]?.elements.isEmpty == true)
    XCTAssertTrue(model.removeSpatialElement(elementID: coverElement.id))
    XCTAssertTrue(model.board?.elements.isEmpty == true)
    XCTAssertTrue(try store.loadPage(page.id).elements.isEmpty)
    XCTAssertTrue(
      try store.loadBoard(itemIDs: [itemID]).elements.isEmpty
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

    var changed = try XCTUnwrap(model.board)
    let itemID = try XCTUnwrap(model.workspace?.selectedItemID)
    XCTAssertTrue(
      changed.moveItem(itemID, to: WorldPoint(x: 700, y: 900), actor: UUID())
    )
    try store.saveBoard(changed, itemIDs: [itemID])
    deadline = clock.now + .seconds(3)
    repeat {
      try await Task.sleep(for: .milliseconds(20))
      receipt = try JSONDecoder().decode(
        CurrentViewReceipt.self,
        from: Data(contentsOf: store.currentViewRevisionURL)
      )
    } while receipt.boardStamp != changed.stamp && clock.now < deadline

    XCTAssertEqual(model.board?.stamp, changed.stamp)
    XCTAssertEqual(receipt.boardStamp, changed.stamp)
  }

  @MainActor
  func testMCPStyleFileChangeReloadsWithoutAMountedWindow() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = NotebookStore(root: root)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    model.start(pageSize: NotebookAppModel.defaultPageSize)

    var changed = try XCTUnwrap(model.board)
    let itemID = try XCTUnwrap(model.workspace?.selectedItemID)
    let center = WorldPoint(x: 740, y: 960)
    XCTAssertTrue(
      changed.moveItem(itemID, to: center, actor: UUID())
    )
    try store.saveBoard(changed, itemIDs: [itemID])

    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(2)
    while model.board?.stamp != changed.stamp,
      clock.now < deadline
    {
      try await Task.sleep(for: .milliseconds(20))
    }

    XCTAssertEqual(model.board?.stamp, changed.stamp)
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
        data: drawing.dataRepresentation(),
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
    var board = try XCTUnwrap(model.board)
    let item = try XCTUnwrap(
      workspace.createDocument(title: "MCP", actor: actor)
    )
    XCTAssertTrue(board.addItem(item.id, near: .zero, actor: actor))
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

import NotebookCore
import PencilKit
import XCTest
@testable import Notebook

final class MacModelLifecycleTests: XCTestCase {
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

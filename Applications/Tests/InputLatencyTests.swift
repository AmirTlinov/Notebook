import XCTest
import Darwin
import NotebookCore
@testable import Notebook

final class InputLatencyTests: XCTestCase {
  @MainActor
  func testCameraFinishesContactWithoutWaitingForArchivePublication() async throws {
    let gate = NotebookInputGate()
    let page = PageDocument(size: .init(width: 834, height: 1194), actor: UUID())
    let stamp = VersionStamp(counter: 1, actor: UUID())
    var release: CheckedContinuation<PreparedPageInkChange?, Never>?
    let began = expectation(description: "preparation suspended")
    let coordinator = PencilCanvasView.Coordinator(inputGate: gate, reserveAction: { _ in stamp }, releaseAction: { _, _ in }, acceptAction: { _, _, _ in
      Task { await withCheckedContinuation { continuation in release = continuation; began.fulfill() } }
    })
    let paper = PaperCanvasContainerView()
    coordinator.attach(to: paper)
    coordinator.setPageFinisherCurrent(true)
    coordinator.apply(Data(), pageID: page.id, to: paper)
    let action = PageInkAction(tool: .pen, samples: [.init(point: .init(x: 10, y: 20), timeOffset: 0,
      width: 2, opacity: 1, force: 1, azimuth: 0, altitude: 1)])
    XCTAssertTrue(paper.touchView.onActionWillBegin?() == true)
    coordinator.commit(action, on: paper)
    await fulfillment(of: [began], timeout: 2)
    var cameraStarted = false, publicationFinished = false
    gate.performAfterPageContact { cameraStarted = true }
    gate.performAfterPageInput { publicationFinished = true }
    XCTAssertTrue(cameraStarted)
    XCTAssertFalse(publicationFinished)
    let change = try page.prepareInkChange(.append(action), stamp: stamp)
    release?.resume(returning: change)
    for _ in 0..<100 where !publicationFinished { await Task.yield() }
    XCTAssertTrue(publicationFinished)
    XCTAssertEqual(paper.touchView.accessibilityValue, "1 действий пера")
    coordinator.detach(from: paper)
  }
  @MainActor
  func testDiskLockCannotBlockCameraOrOverwriteInkPreparedDuringReload() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = NotebookStore(root: root)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    await model.finishPendingPersistence()
    let page = try XCTUnwrap(model.activePage)
    func stroke(_ x: Double) -> PageInkAction {
      .init(tool: .pen, samples: [.init(point: .init(x: x, y: 20), timeOffset: 0,
        width: 2, opacity: 1, force: 1, azimuth: 0, altitude: 1)])
    }
    let remote = stroke(30), local = stroke(50)
    var disk = page
    let change = try disk.prepareInkChange(.append(remote), stamp: .init(counter: 5, actor: UUID()))
    XCTAssertTrue(disk.publishInkChange(change))
    _ = try store.savePage(disk)
    let descriptor = try NotebookSQLWriteBlocker(store: store)
    defer { try? descriptor.release() }
    let clock = ContinuousClock(), began = clock.now
    let initial = try XCTUnwrap(model.presence)
    var presence = SessionPresence(boardID: initial.boardID, mode: .board,
      camera: .init(center: .init(x: 80, y: 90), scale: 0.7), viewport: initial.viewport)
    presence = presence.selecting(itemID: model.presence?.selectedItemID, pageID: model.presence?.notebookPageID)
    model.updatePresence(presence, settled: true)
    model.reloadExternalChanges()
    XCTAssertLessThan(began.duration(to: clock.now), .milliseconds(50))
    try await Task.sleep(for: .milliseconds(30))
    let stamp = try XCTUnwrap(model.reserveDrawingAction(pageID: page.id))
    let accepted = await model.acceptDrawingAction(local, pageID: page.id, stamp: stamp).value
    XCTAssertNotNil(accepted, "Подготовка пера не ждёт транзакцию SQLite")
    try descriptor.release()
    await model.finishPendingPersistence()
    let drawing = try PageInkDrawing.decode(XCTUnwrap(model.pages[page.id]).drawingData)
    XCTAssertEqual(Set(drawing.activeActions.map(\.id)), [local.id, remote.id])
    XCTAssertEqual(try store.loadPresence(), presence)
  }

}

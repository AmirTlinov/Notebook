import AppKit
import Foundation
import NotebookCore
import SQLite3
import XCTest
@testable import Notebook

@MainActor
final class MacShutdownTests: XCTestCase {
  func testShutdownRetiresCachedAppKitRasterWithoutRevokingAnotherBorrower() async throws {
    let (model, _) = try await fixture()
    let resources = SceneRenderResources()
    let element = AgentElement(id: UUID().uuidString, kind: .web,
      frame: .init(x: 0, y: 0, width: 32, height: 32), source: "Native raster", html: "red")
    let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
      bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(NSColor.red.cgColor); context.fill(.init(x: 0, y: 0, width: 32, height: 32))
    let image = NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: .init(width: 32, height: 32))
    XCTAssertTrue(resources.store(image, for: element))
    let borrowed = try XCTUnwrap(resources.retainRaster(for: element))
    let view = AgentSnapshotRasterView()
    view.bindSceneLifecycle(to: model)
    view.updateRaster(borrowed, displayScale: 1)
    XCTAssertNotNil(view.image)
    let parent = NSView(); parent.addSubview(view); view.removeFromSuperview()
    XCTAssertNotNil(view.image, "Temporary transfer does not retire a prepared presenter")
    let stopped = await model.shutdown()
    XCTAssertTrue(stopped)
    XCTAssertNil(view.image)
    XCTAssertFalse(borrowed.isReleased)
    XCTAssertEqual(resources.rasterAdmission.pinnedBytes, borrowed.accountedByteCount)
    view.updateRaster(borrowed, displayScale: 1)
    XCTAssertNil(view.image, "A late update cannot revive a terminal AppKit owner")
    borrowed.release()
    XCTAssertEqual(resources.rasterAdmission.pinnedBytes, 0)
  }

  func testReadPublicationFailureCanBeRepairedAfterARefusedShutdown() async throws {
    let (model, fault) = try await fixture()
    XCTAssertEqual(model.shutdownPhase, .running)
    let presentation = ShutdownPresentationProbe(model: model)
    model.registerScenePresentation(presentation)
    let page = try XCTUnwrap(model.activePage)
    try fault.rejectReadsAndWrites()
    await model.reloadExternalChanges()?.value
    XCTAssertNotNil(model.persistenceFailure)
    let beforeRepair = await model.finishPendingPersistence()
    XCTAssertFalse(beforeRepair, "A failed disk refresh cannot acknowledge a completed publication")
    // A failed read does not poison the native write queue. The error retained
    // above belongs to the real refresh owner, not an injected queue failure.
    let queueRemainsAvailable = try await model.performStoreCommand { _ in true }
    XCTAssertTrue(queueRemainsAvailable)
    let refused = await model.shutdown()
    XCTAssertFalse(refused)
    XCTAssertEqual(model.shutdownPhase, .closing)
    XCTAssertTrue(presentation.terminalPhases.isEmpty, "A failed publication cannot retire the human's scene")
    XCTAssertFalse(model.inputGate.permitsNewContact)
    XCTAssertFalse(model.inputGate.beginPencilAction(source: UUID()))
    XCTAssertNil(model.inputGate.beginFingerSequence())
    do {
      _ = try await model.performStoreCommand { _ in true }
      XCTFail("A refused quit keeps external admission closed during explicit repair")
    } catch let error as CollaborationError { XCTAssertEqual(error.code, "owner_unavailable") }

    try fault.restore()
    model.retryPendingPersistence()
    let repaired = await model.finishPendingPersistence()
    XCTAssertTrue(repaired, model.persistenceFailure ?? "The refresh owner did not recover")
    XCTAssertNil(model.persistenceFailure)
    XCTAssertEqual(try model.store.loadPage(page.id), page)
    let stopped = await model.shutdown()
    XCTAssertTrue(stopped, "A refused quit must leave the refresh owner available for explicit repair")
    XCTAssertEqual(model.shutdownPhase, .stopped)
    XCTAssertEqual(presentation.terminalPhases, [.stopped])
    XCTAssertFalse(model.permitsBackgroundPreparation)
    let stoppedAgain = await model.shutdown()
    XCTAssertTrue(stoppedAgain)
    XCTAssertEqual(presentation.terminalPhases, [.stopped], "The terminal ACK is delivered once")
  }

  func testAcceptedInkSurvivesWriteFailureRefusedShutdownAndExplicitRetry() async throws {
    let (model, fault) = try await fixture()
    XCTAssertEqual(model.shutdownPhase, .running)
    let presentation = ShutdownPresentationProbe(model: model)
    model.registerScenePresentation(presentation)
    let page = try XCTUnwrap(model.activePage)
    try fault.rejectReadsAndWrites()
    await model.reloadExternalChanges()?.value
    XCTAssertNotNil(model.persistenceFailure)

    let action = PageInkAction(tool: .pen, samples: [
      .init(point: .init(x: 20, y: 30), timeOffset: 0, width: 5,
        opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2),
      .init(point: .init(x: 70, y: 90), timeOffset: 0.04, width: 5,
        opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
    ])
    let stamp = try XCTUnwrap(model.reserveDrawingAction(pageID: page.id))
    let accepted = await model.acceptDrawingAction(action, pageID: page.id, stamp: stamp).value
    XCTAssertNotNil(accepted, "The native contact has already been accepted in memory")
    let inMemory = try PageInkDrawing.decode(XCTUnwrap(model.activePage).drawingData)
    XCTAssertEqual(inMemory.activeActions.map(\.id), [action.id])
    let savedBeforeRepair = await model.finishPendingPersistence()
    XCTAssertFalse(savedBeforeRepair)
    XCTAssertNotNil(model.persistenceFailure)
    do {
      _ = try await model.performStoreCommand { _ in true }
      XCTFail("The failed accepted write must remain at the head of the same queue")
    } catch is NotebookPersistenceQueue.Failure { }
    let refused = await model.shutdown()
    XCTAssertFalse(refused)
    XCTAssertEqual(model.shutdownPhase, .closing)
    XCTAssertTrue(presentation.terminalPhases.isEmpty)

    try fault.restore()
    XCTAssertEqual(try model.store.loadPage(page.id), page,
      "Repairing access alone cannot silently replay an accepted write")
    model.retryPendingPersistence()
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved, model.persistenceFailure ?? "The accepted contact was not saved")
    XCTAssertNil(model.persistenceFailure)
    let durable = try model.store.loadPage(page.id)
    let drawing = try PageInkDrawing.decode(durable.drawingData)
    XCTAssertEqual(durable.drawingStamp, stamp)
    XCTAssertEqual(drawing.activeActions.map(\.id), [action.id])
    XCTAssertEqual(drawing.actions.filter { $0.id == action.id }.count, 1)
    XCTAssertEqual(drawing.activeActions.first?.samples, action.samples)

    let cursor = try model.store.currentChangeCursor()
    model.retryPendingPersistence()
    let repeated = await model.finishPendingPersistence()
    XCTAssertTrue(repeated)
    XCTAssertEqual(try model.store.currentChangeCursor(), cursor, "Retry cannot append the contact a second time")
    let stopped = await model.shutdown()
    XCTAssertTrue(stopped)
    XCTAssertEqual(model.shutdownPhase, .stopped)
    XCTAssertEqual(presentation.terminalPhases, [.stopped])
    XCTAssertEqual(try model.store.currentChangeCursor(), cursor)
  }

  func testSceneRegistrationIsWeakAndALateOwnerReceivesTheTerminalBoundary() async throws {
    let (model, _) = try await fixture()
    var temporary: ShutdownPresentationProbe? = ShutdownPresentationProbe(model: model)
    weak let released = temporary
    model.registerScenePresentation(try XCTUnwrap(temporary))
    temporary = nil
    XCTAssertNil(released, "The model owns a terminal signal, not the lifetime of a cached UIKit host")
    let stopped = await model.shutdown()
    XCTAssertTrue(stopped)
    let late = ShutdownPresentationProbe(model: model)
    model.registerScenePresentation(late)
    XCTAssertEqual(late.terminalPhases, [.stopped], "A stale mount cannot recreate a terminal presentation")
  }

  func testShutdownClosesNewContactsBeforeItWaitsForTheMeasuredPencil() async throws {
    let (model, _) = try await fixture()
    let pencil = UUID()
    XCTAssertTrue(model.inputGate.beginPencilAction(source: pencil))
    defer { model.inputGate.endPencilAction(source: pencil) }
    let closing = Task { await model.shutdown() }
    let deadline = ContinuousClock.now + .seconds(3)
    while model.shutdownPhase == .running, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(model.shutdownPhase, .closing)
    XCTAssertTrue(model.inputGate.hasActivePencil, "Closing does not discard the already measured contact")
    XCTAssertFalse(model.inputGate.permitsNewContact)
    XCTAssertFalse(model.inputGate.beginPencilAction(source: UUID()), "A second native contact cannot race the final drain")
    XCTAssertTrue(model.inputGate.beginPencilAction(source: pencil), "The same accepted source keeps its completion route")
    XCTAssertNil(model.inputGate.beginFingerSequence())
    model.inputGate.endPencilAction(source: pencil)
    let stopped = await closing.value
    XCTAssertTrue(stopped)
    XCTAssertEqual(model.shutdownPhase, .stopped)
    XCTAssertFalse(model.inputGate.hasActivePencil)
  }

  private func fixture() async throws -> (NotebookAppModel, SchemaVersionFault) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-shutdown-\(UUID())")
    let store = NotebookStore(root: root)
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 100, height: 140))
    let fault = try SchemaVersionFault(database: store.databaseURL)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    addTeardownBlock { @MainActor in
      try fault.restore()
      model.retryPendingPersistence()
      let stopped = await model.shutdown()
      XCTAssertTrue(stopped, "Keep the failure evidence if accepted work cannot drain")
      guard stopped else { return }
      try FileManager.default.removeItem(at: root)
    }
    await model.start(pageSize: .init(width: 100, height: 140))
    let ready = await model.finishPendingPersistence()
    XCTAssertTrue(ready, model.persistenceFailure ?? "The isolated fixture did not finish startup")
    return (model, fault)
  }
}

@MainActor
private final class ShutdownPresentationProbe: NotebookScenePresentationOwner {
  private weak var model: NotebookAppModel?
  private(set) var terminalPhases: [NotebookAppModel.ShutdownPhase] = []
  init(model: NotebookAppModel) { self.model = model }
  func uninstall() {
    guard terminalPhases.isEmpty, let model else { return }
    terminalPhases.append(model.shutdownPhase)
  }
}

/// A real on-disk format rejection exercises both readers and the accepted
/// native writer. Connections stay valid; no open SQLite file is unlinked.
private struct SchemaVersionFault {
  let database: URL
  let supportedVersion: Int32

  init(database: URL) throws {
    self.database = database
    supportedVersion = try Self.withConnection(database) { connection in
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(connection, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
        let statement else { throw Self.failure(connection) }
      defer { sqlite3_finalize(statement) }
      guard sqlite3_step(statement) == SQLITE_ROW else { throw Self.failure(connection) }
      return sqlite3_column_int(statement, 0)
    }
  }

  func rejectReadsAndWrites() throws { try setVersion(supportedVersion + 1) }
  func restore() throws { try setVersion(supportedVersion) }

  private func setVersion(_ version: Int32) throws {
    try Self.withConnection(database) { connection in
      guard sqlite3_exec(connection, "PRAGMA user_version=\(version)", nil, nil, nil) == SQLITE_OK else {
        throw Self.failure(connection)
      }
    }
  }

  private static func withConnection<T>(_ url: URL, _ operation: (OpaquePointer) throws -> T) throws -> T {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
      let handle else {
      if let handle { sqlite3_close(handle) }
      throw CocoaError(.fileReadUnknown)
    }
    defer { sqlite3_close(handle) }
    sqlite3_busy_timeout(handle, 4_000)
    return try operation(handle)
  }

  private static func failure(_ connection: OpaquePointer) -> NSError {
    .init(domain: "NotebookShutdownFixture", code: Int(sqlite3_errcode(connection)),
      userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(connection))])
  }
}

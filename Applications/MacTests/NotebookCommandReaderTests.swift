import Foundation
@testable import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class NotebookCommandReaderTests: XCTestCase {
  private typealias Blocker = NotebookPersistenceFenceContract.Blocker
  private typealias Signal<Value: Sendable> = NotebookPersistenceFenceContract.Signal<Value>

  func testReadFenceCapturesTheAcceptedPrefixAndTheReaderDoesNotBlockLaterWrites() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    let header = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    let queue = NotebookPersistenceQueue(store: store), reader = NotebookCommandReader(store: store)
    let prefix = Blocker(), laterWrite = Blocker(), reading = Blocker(), committed = Signal<Bool>()
    defer { prefix.release(); laterWrite.release(); reading.release() }
    let baseline = try store.currentReadCursor()
    queue.enqueue { store in
      try prefix.hold()
      try store.publishRecords(writes: ["accepted-prefix.json": .object(["value": .number(1)])])
      return false
    }
    let generation = queue.acceptedMutationGeneration
    let fence = queue.captureReadFence()
    XCTAssertEqual(queue.acceptedMutationGeneration, generation, "An observation never invalidates the accepted-input generation")
    queue.enqueue { store in
      try laterWrite.hold()
      try store.publishRecords(writes: ["accepted-later.json": .object(["value": .number(2)])])
      return false
    }
    queue.onCommit = { _ in committed.set(true) }
    let result = Task {
      try await fence.wait()
      try await NotebookPersistenceFenceContract.until { laterWrite.entered.value == true }
      return try await reader.read(workspaceID: header.workspaceID) { cut in
        let before = try cut.currentReadCursor()
        try reading.hold()
        return (before, try cut.currentReadCursor())
      }
    }
    try await NotebookPersistenceFenceContract.until { prefix.entered.value == true }
    XCTAssertNil(reading.entered.value, "The reader cannot overtake its accepted prefix")
    prefix.release()
    try await NotebookPersistenceFenceContract.until { laterWrite.entered.value == true && reading.entered.value == true }
    // The later writer already owns BEGIN IMMEDIATE while this independent
    // reader retains the earlier WAL cut. Neither owner holds the other's FIFO.
    committed.set(false)
    laterWrite.release()
    try await NotebookPersistenceFenceContract.until { committed.value == true && queue.pendingCount == 0 }
    XCTAssertTrue(try NotebookStore(root: root).hasStoredValue("accepted-later.json"))
    reading.release()
    let (first, last) = try await result.value
    XCTAssertEqual(first, baseline + 1); XCTAssertEqual(last, first)
    let next = try await reader.read(workspaceID: header.workspaceID) { try $0.currentReadCursor() }
    XCTAssertEqual(next, baseline + 2, "The idle reader starts a fresh cut after the held one closes")
    await reader.close()
  }

  func testCancellingAReadFenceLeavesTheAcceptedHeadAndItsResultIntact() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    let queue = NotebookPersistenceQueue(store: store), accepted = Blocker()
    defer { accepted.release() }
    queue.enqueue { store in
      try accepted.hold()
      try store.publishRecords(writes: ["after-observer-cancel.json": .object(["value": .string("kept")])])
      return false
    }
    let fence = queue.captureReadFence(), observer = Task { try await fence.wait() }
    try await NotebookPersistenceFenceContract.until { accepted.entered.value == true }
    observer.cancel()
    do { try await observer.value; XCTFail("The caller's observation must cancel") }
    catch is CancellationError { }
    XCTAssertEqual(queue.pendingCount, 2); XCTAssertNil(queue.failure)
    accepted.release()
    let saved = await queue.flush()
    XCTAssertTrue(saved); XCTAssertEqual(queue.pendingCount, 0)
    XCTAssertTrue(try NotebookStore(root: root).hasStoredValue("after-observer-cancel.json"))
  }

  func testStopClosesAdmissionAndCloseJoinsTheActualBorrowedCut() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    let header = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    let reader = NotebookCommandReader(store: store), reading = Blocker()
    let closeRequested = Signal<Bool>(), closed = Signal<Bool>()
    defer { reading.release() }
    let observer = Task {
      try await reader.read(workspaceID: header.workspaceID) { cut in
        _ = try cut.workspaceHeader()
        try reading.hold()
        // Even a caller which catches the cancellation cannot publish a result
        // from a withdrawn cut: the enclosing transaction rechecks its latch.
        _ = try? cut.currentReadCursor()
        return 99
      }
    }
    try await NotebookPersistenceFenceContract.until { reading.entered.value == true }
    reader.stop()
    let closing = Task { closeRequested.set(true); await reader.close(); closed.set(true) }
    try await NotebookPersistenceFenceContract.until { closeRequested.value == true }
    XCTAssertNil(closed.value, "Closing cannot claim completion while a source borrow is alive")
    reading.release()
    do { _ = try await observer.value; XCTFail("Stop withdraws this observer result") }
    catch is CancellationError { }
    await closing.value
    XCTAssertEqual(closed.value, true)
    do {
      _ = try await reader.read(workspaceID: header.workspaceID) { try $0.workspaceHeader() }
      XCTFail("A stopped reader cannot accept another source")
    } catch is CancellationError { }
  }

  func testTheReaderRefusesAWrongWorkspaceAndAReplacementDatabaseBeforeTheOperation() async throws {
    let root = temporaryRoot(), otherRoot = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: otherRoot) }
    let store = NotebookStore(root: root), other = NotebookStore(root: otherRoot)
    let original = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    let replacement = try other.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    let reader = NotebookCommandReader(store: store), touched = Signal<Bool>()
    do {
      _ = try await reader.read(workspaceID: replacement.workspaceID) { _ in touched.set(true); return 0 }
      XCTFail("The caller cannot retarget the reader to another workspace")
    } catch let error as CollaborationError { XCTAssertEqual(error.code, "workspace_changed") }
    XCTAssertNil(touched.value)
    let admitted = try await reader.read(workspaceID: original.workspaceID) { try $0.workspaceHeader() }
    XCTAssertEqual(admitted.workspaceID, original.workspaceID)
    try other.sqlRead { _ = try $0.rows("PRAGMA wal_checkpoint(TRUNCATE)") }
    try store.sqlRead { _ = try $0.rows("PRAGMA wal_checkpoint(TRUNCATE)") }
    try Data(contentsOf: other.databaseURL).write(to: store.databaseURL, options: .atomic)
    do {
      _ = try await reader.read(workspaceID: original.workspaceID) { _ in touched.set(true); return 0 }
      XCTFail("An idle connection cannot read a replaced database")
    } catch let error as NotebookStorageError {
      XCTAssertEqual(error, .invalidTransaction("database file identity changed"))
    }
    XCTAssertNil(touched.value)
    await reader.close()
  }

  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("command-reader-\(UUID())")
  }
}

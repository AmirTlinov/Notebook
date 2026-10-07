import CryptoKit
import Foundation
@testable import NotebookCore
import NotebookTypesetter
import XCTest
@testable import Notebook

@MainActor
final class NotebookPortableDocumentImportOwnerTests: XCTestCase {
  private enum FixtureFailure: Error { case disk, timeout }
  private var imports: [Task<NotebookDocumentImportOwner.Result, Error>] = []
  private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("portable-owner-" + UUID().uuidString) }
  private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
  private func fixture(_ store: NotebookStore, cache: Bool = false) throws -> (URL, UUID, String) {
    let actor = UUID(), header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let document = DocumentDocument(actor: actor, files: [.init(id: "main", path: "main.tex", source: "Useful authored source.")])
    let cut = try NotebookExportCut(document: document, state: .init(id: document.id, actor: actor))
    var derived: NotebookPortableDocument.Derived?
    if cache {
      let pdf = Data("%PDF-1.4\noptional fixture".utf8), revision = String(repeating: "a", count: 64)
      let map = try DocumentPrintSourceMap(document: document, source: document.files[0].source, pdf: pdf, compilerRevision: revision)
      derived = .init(pdf: pdf, syncTeX: Data([0x1f, 0x8b]), interactiveMap: Data(), sourceMap: map)
    }
    let bytes = try store.exportPortableDocument(cut: cut, derived: derived), file = store.root.appendingPathComponent("selected.notex")
    try bytes.write(to: file)
    return (file, header.rootBoardID, hash(bytes))
  }
  private func until(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    guard condition() else { throw FixtureFailure.timeout }
  }

  func testByteAndCountRefusalPrecedeAnyFileWorker() async throws {
    let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
    let missing = directory.appendingPathComponent("never-opened.notex")
    for limits in [NotebookPersistenceAdmission.Limits(maximumBytes: NotebookPortableDocumentImport.directoryCost.bytes-1,
      maximumOperations: 512), .init(maximumBytes: 256*1_048_576, maximumOperations: 0)] {
      let queue = NotebookPersistenceQueue(store: .init(root: directory), admissionLimits: limits)
      let owner = NotebookDocumentImportOwner(persistence: queue, actor: UUID())
      do { _ = try await owner.run(file: missing, targetBoardID: UUID(), center: .zero); XCTFail("Unreserved source work started") }
      catch { XCTAssertTrue(error is NotebookPersistenceQueue.Failure, "A file-system error would prove the worker ran before admission") }
      XCTAssertEqual(queue.admittedOperationCount, 0); XCTAssertEqual(queue.reservedWriteBytes, 0)
      XCTAssertEqual(queue.pendingCount, 0); XCTAssertNil(queue.failure)
      XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
      await owner.close()
    }
  }

  func testFailedWriterBurstPlateausAndRetryPreservesAcceptedImportOrder() async throws {
    let directory = root()
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let peer = NotebookStore(root: directory), (file, boardID, digest) = try fixture(peer)
    let ready = directory.appendingPathComponent("storage-ready")
    let unavailable = NotebookStore(root: directory) { phase in
      if phase == .beforeCommit, !FileManager.default.fileExists(atPath: ready.path) { throw FixtureFailure.disk }
    }
    let queue = NotebookPersistenceQueue(store: unavailable,
      admissionLimits: .init(maximumBytes: 128*1_048_576, maximumOperations: 3))
    let actor = UUID(), owner = NotebookDocumentImportOwner(persistence: queue, actor: actor)
    addTeardownBlock { @MainActor [self] in
      // An assertion/phase timeout still owns accepted producers. Repair and
      // drain them before joining the owner and removing its source directory.
      try? Data().write(to: ready)
      owner.stop(); queue.retry()
      let drained = await queue.flush(); XCTAssertTrue(drained)
      await owner.close()
      for task in imports { _ = await task.result }
      imports.removeAll()
    }
    let headCost = NotebookPersistenceAdmission.Cost(payloadBytes: 256)
    let head = try XCTUnwrap(queue.reserveWrite(headCost))
    try queue.enqueueReserved(owner: .pageInk(UUID()), reservation: head, cost: headCost) { _ in false }
    let blocked = await queue.flush(); XCTAssertFalse(blocked)
    let ids = [UUID(), UUID()]
    let first = Task { try await owner.run(.init(id: ids[0], filePath: file.path, sha256: digest, targetBoardID: boardID, center: .zero)) }
    imports.append(first)
    try await until { queue.pendingCount == 2 }
    let second = Task { try await owner.run(.init(id: ids[1], filePath: file.path, sha256: digest, targetBoardID: boardID, center: .init(x: 20, y: 30))) }
    imports.append(second)
    try await until { queue.pendingCount == 3 }
    let held = queue.reservedWriteBytes, payload = queue.acceptedPayloadBytes, finish = queue.acceptedCompletionBytes
    XCTAssertGreaterThan(finish, 0); XCTAssertEqual(queue.admittedOperationCount, 3)
    do {
      _ = try await owner.run(file: directory.appendingPathComponent("missing-next.notex"), targetBoardID: boardID, center: .zero)
      XCTFail("The full FIFO accepted another source")
    } catch { XCTAssertTrue(error is NotebookPersistenceQueue.Failure) }
    XCTAssertEqual(queue.pendingCount, 3); XCTAssertEqual(queue.reservedWriteBytes, held)
    XCTAssertEqual(queue.acceptedPayloadBytes, payload); XCTAssertEqual(queue.acceptedCompletionBytes, finish)
    XCTAssertEqual(try hash(Data(contentsOf: file)), digest)
    try Data().write(to: ready); queue.retry()
    let saved = await queue.flush(); XCTAssertTrue(saved)
    let results = try await [first.value, second.value]
    let expected = ids.map { NotebookStore.submissionID($0, suffix: "document") }
    XCTAssertEqual(results.map(\.documentID), expected)
    XCTAssertEqual(Set(try peer.loadIndex().items.filter { $0.kind == .document }.map(\.id)), Set(expected))
    XCTAssertEqual(try peer.nativeHistory(domain: .board(boardID), actor: actor), ids.map(PencilUndoHistory.Entry.command),
      "The durable authored action directory keeps FIFO, independently of catalogue projection order")
    XCTAssertEqual(queue.pendingCount, 0); XCTAssertEqual(queue.reservedWriteBytes, 0)
    await owner.close()
  }

  func testUsefulCommitReturnsWhileCacheActorIsBlockedAndCloseJoinsItsCredit() async throws {
    let directory = root()
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let store = NotebookStore(root: directory), (file, boardID, _) = try fixture(store, cache: true)
    let printStore = NotebookPrintedDocumentStore(resources: directory.appendingPathComponent("unused-resources"),
      directory: directory.appendingPathComponent("unused-cache"))
    let entered = expectation(description: "The concrete print-cache actor holds its revision reader")
    let release = DispatchSemaphore(value: 0), finished = PortableCacheBlockWitness()
    let blocked = Task.detached { await printStore.holdPortableImportRevision(entered: entered, release: release, finished: finished) }
    let queue = NotebookPersistenceQueue(store: store), owner = NotebookDocumentImportOwner(persistence: queue, actor: UUID(), printStore: printStore)
    addTeardownBlock { @MainActor in
      release.signal()
      await blocked.value
      owner.stop()
      let drained = await queue.flush(); XCTAssertTrue(drained)
      await owner.close()
    }
    await fulfillment(of: [entered], timeout: 2)
    let result = try await owner.run(file: file, targetBoardID: boardID, center: .zero)
    XCTAssertFalse(finished.value, "Authored import waited for an unrelated print-cache actor")
    XCTAssertFalse(result.cachedPrint)
    XCTAssertEqual(try store.loadDocument(result.documentID).files[0].source, "Useful authored source.")
    XCTAssertEqual(owner.optionalJobCount, 1)
    XCTAssertFalse(owner.hasPendingAuthoredPreparation)
    let saved = await queue.flush(); XCTAssertTrue(saved)
    XCTAssertGreaterThan(queue.reservedWriteBytes, 0, "The optional cache still owns source/phase credit")
    let seal = try XCTUnwrap(queue.sealWorkspaceSelection(expectedGeneration: queue.acceptedMutationGeneration))
    queue.finishWorkspaceSelection(seal)
    var closed = false
    let closing = Task { await owner.close(); closed = true }
    await Task.yield()
    XCTAssertFalse(closed); XCTAssertGreaterThan(queue.reservedWriteBytes, 0)
    release.signal(); await blocked.value; await closing.value
    XCTAssertTrue(closed); XCTAssertEqual(owner.optionalJobCount, 0); XCTAssertEqual(queue.reservedWriteBytes, 0)
    XCTAssertEqual(try store.loadDocument(result.documentID).files[0].source, "Useful authored source.")
  }
}

private final class PortableCacheBlockWitness: @unchecked Sendable {
  private let lock = NSLock()
  private var finished = false
  var value: Bool { lock.lock(); defer { lock.unlock() }; return finished }
  func finish() { lock.lock(); finished = true; lock.unlock() }
}

private extension NotebookPrintedDocumentStore {
  func holdPortableImportRevision(entered: XCTestExpectation, release: DispatchSemaphore,
    finished: PortableCacheBlockWitness) {
    entered.fulfill()
    _ = release.wait(timeout: .now()+3)
    finished.finish()
  }
}

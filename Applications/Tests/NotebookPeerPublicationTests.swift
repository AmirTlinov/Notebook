import Foundation
import NotebookCore
import XCTest
@testable import Notebook

@MainActor final class NotebookPeerPublicationTests: XCTestCase {
  func testSupersededOpeningAndNavigationFinishBeforeBlockedLookupAndCannotRevive() async throws {
    try await NotebookPersistenceFenceContract.fixture { _, queue, _ in
      let blocker = NotebookPersistenceFenceContract.Blocker()
      defer { blocker.release() }
      queue.enqueue { _ in try blocker.hold(); return false }
      try await NotebookPersistenceFenceContract.until { blocker.entered.value == true }
      let peer = UUID(), session = UUID(), opening = UUID()
      let target = CollaborationTarget(kind: .board, id: UUID())
      let owner = NotebookPeerPublication(persistence: queue, actorID: UUID())
      defer { owner.stop() }
      owner.navigationChanged(to: 4)
      XCTAssertTrue(owner.receive(.init(deviceID: peer, sessionID: session, sequence: 1, targets: [target])))
      var openingStarted = false, navigationStarted = false
      var openingCancelled = false, navigationCancelled = false
      let openingTask = Task {
        openingStarted = true
        do { try await owner.wait(to: target, opening: opening); XCTFail("Cancelled opening was admitted") }
        catch is CancellationError { openingCancelled = true }
        catch { XCTFail("Unexpected opening failure: \(error)") }
      }
      let navigationTask = Task {
        navigationStarted = true
        do { try await owner.wait(to: target, navigation: 4); XCTFail("Superseded navigation was admitted") }
        catch is CancellationError { navigationCancelled = true }
        catch { XCTFail("Unexpected navigation failure: \(error)") }
      }
      try await NotebookPersistenceFenceContract.until { openingStarted && navigationStarted }
      owner.cancelOpening(opening)
      owner.navigationChanged(to: 5)
      try await NotebookPersistenceFenceContract.until { openingCancelled && navigationCancelled }
      XCTAssertTrue(owner.receive(.init(deviceID: peer, sessionID: session, sequence: 2, targets: [])))
      XCTAssertTrue(owner.allows(target))
      blocker.release()
      let flushed = await queue.flush()
      XCTAssertTrue(flushed)
      await openingTask.value; await navigationTask.value
      XCTAssertTrue(owner.allows(target), "The cancelled old scope lookup cannot revive a lifted contact")
      XCTAssertFalse(owner.isActive)
    }
  }

  func testFailedScopeReadTerminatesPublicationAndExplicitRetryReopensOnlyUnrelatedTarget() async throws {
    try await NotebookPersistenceFenceContract.fixture { _, queue, _ in
      let blocker = NotebookPersistenceFenceContract.Blocker()
      let repaired = NotebookPersistenceFenceContract.Signal<Bool>()
      defer { blocker.release() }
      queue.enqueue { _ in
        if repaired.value != true {
          try blocker.hold()
          throw NotebookPersistenceFenceContract.Failure.contract("scope predecessor failed")
        }
        return false
      }
      try await NotebookPersistenceFenceContract.until { blocker.entered.value == true }
      let target = CollaborationTarget(kind: .board, id: UUID())
      let other = CollaborationTarget(kind: .board, id: UUID())
      let otherScope = NotebookInputScope(target: other, carrier: other.id, boards: [other.id])
      let owner = NotebookPeerPublication(persistence: queue, actorID: UUID())
      defer { owner.stop() }
      owner.receive(.init(deviceID: UUID(), sessionID: UUID(), sequence: 1, targets: [target]))
      var entered = false, failed = false
      let task = Task {
        entered = true
        do { try await owner.wait(to: other, scope: otherScope); XCTFail("Unknown ancestry was admitted") }
        catch { failed = true }
      }
      try await NotebookPersistenceFenceContract.until { entered }
      blocker.release()
      try await NotebookPersistenceFenceContract.until { failed }
      XCTAssertFalse(owner.allows(other, scope: otherScope), "Failure cannot silently make unknown ancestry safe")
      repaired.set(true); queue.retry(); owner.retry()
      try await NotebookPersistenceFenceContract.until { owner.allows(other, scope: otherScope) }
      XCTAssertFalse(owner.allows(target, scope: .init(target: target, carrier: target.id, boards: [target.id])))
      await task.value
      let flushed = await queue.flush()
      XCTAssertTrue(flushed)
    }
  }
}

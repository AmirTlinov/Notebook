import XCTest
@testable import Notebook

@MainActor final class NotebookPersistenceFenceTests: XCTestCase {
  func testAcceptedPrefixFinishesBeforeLaterWorkAndCoalescing() async throws {
    try await NotebookPersistenceFenceContract.acceptedPrefixExcludesLaterWorkAndCoalescing()
  }
  func testCancellationPreservesAllAcceptedWrites() async throws {
    try await NotebookPersistenceFenceContract.cancellationReleasesOnlyTheWaiter()
  }
  func testFailedPredecessorRetainsLastWriteForRetry() async throws {
    try await NotebookPersistenceFenceContract.failedPredecessorRemainsRetryable()
  }
  func testLaterFailureCannotRevokeCompletedPrefix() async throws {
    try await NotebookPersistenceFenceContract.laterFailureCannotRevokeCompletedPrefix()
  }
  func testEmptyFencesDoNotPublishCommitsOrRetainMarkers() async throws {
    try await NotebookPersistenceFenceContract.emptyFenceDoesNotPublishACommit()
  }
}

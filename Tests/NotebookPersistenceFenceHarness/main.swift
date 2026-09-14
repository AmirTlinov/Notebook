import Foundation
@main struct PersistenceFenceProof {
  @MainActor static func main() async throws {
    try await NotebookPersistenceFenceContract.acceptedPrefixExcludesLaterWorkAndCoalescing()
    try await NotebookPersistenceFenceContract.cancellationReleasesOnlyTheWaiter()
    try await NotebookPersistenceFenceContract.failedPredecessorRemainsRetryable()
    try await NotebookPersistenceFenceContract.laterFailureCannotRevokeCompletedPrefix()
    try await NotebookPersistenceFenceContract.emptyFenceDoesNotPublishACommit()
    print("{\"passed\":5,\"failed\":0,\"skipped\":0,\"scope\":\"production FIFO owner with controlled operations; no application or UI\"}")
  }
}

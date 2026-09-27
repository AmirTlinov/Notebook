import Foundation
@testable import NotebookCore

extension NotebookStore {
  /// Synchronous fixture driver for the production read-plan/bounded-write API.
  func prepareCloudUpload(account: String, source: NotebookReplicationSource) throws {
    var pending = try pendingCloudUploadPlan(account: account)
    if pending == nil, let plan = try prepareCloudUploadPlan(account: account, source: source) {
      if try beginCloudUpload(plan, account: account) { pending = plan.id }
      else { try discardCloudUploadSpool(plan.id) }
    }
    if let pending {
      while let batch = try prepareCloudUploadBatch(pending, account: account) {
        if try installCloudUploadBatch(batch, account: account) { break }
      }
      try discardCloudUploadSpool(pending)
    }
  }
  func cloudSnapshot(source: NotebookReplicationSource) throws -> NotebookReplicationDelivery {
    try prepareCloudSnapshot(source: source) { try currentSQL!.putBlob($0) }
  }
}

import Foundation

extension NotebookStore {
  func historyPhysicalClosureRead(_ query: NotebookReadQuery) throws -> JSONValue {
    guard let database = currentSQL, !database.writable,
      let snapshotID = database.readSnapshotIdentity else { throw NotebookStorageError.readOnlyTransaction }
    guard let transactionID = query.id, let hash = query.revision,
      NotebookPageOrderRegister.validHash(hash), query.after == nil, query.limit == nil,
      query.next == nil, query.scope == nil, query.replicaSection == nil else {
      throw CollaborationError("invalid_history_query", "Нужны ID принятой транзакции и точный manifest SHA-256.")
    }
    let workspaceID = try storedWorkspaceID()
    let closure = try actionHistoryPhysicalClosure(workspaceID: workspaceID, transactionID: transactionID,
      manifestHash: hash, receiptID: query.referenceID)
    guard closure.borrowedSnapshotID == snapshotID else { throw NotebookStorageError.readOnlyTransaction }
    let complete = closure.declaredRecords.status == .authenticatedDeclaredClosure && closure.receipts.allSatisfy {
      $0.status == .authenticatedDeclaredClosure
    }
    return .object(["cut": .object(["workspaceID": .string(workspaceID.uuidString),
      "snapshotID": .string(snapshotID.uuidString), "readCursor": .string(String(try currentReadCursor()))]),
      "transactionID": .string(transactionID.uuidString), "manifestHash": .string(hash),
      "proof": try .encode(closure), "complete": .bool(complete), "jointReadiness": .bool(false)])
  }
}

import Foundation

extension NotebookStore {
  /// The existing command reader lends this snapshot. This observation exposes
  /// acceptance and closure evidence, never a migration seal or write authority.
  func actionHistoryPreflight(_ query: NotebookReadQuery) throws -> JSONValue {
    guard let database = currentSQL, !database.writable,
      let snapshotID = database.readSnapshotIdentity else {
      throw NotebookStorageError.readOnlyTransaction
    }
    let workspaceID = try storedWorkspaceID(), cursor = String(try currentReadCursor())
    let cut: JSONValue = .object(["workspaceID": .string(workspaceID.uuidString),
      "snapshotID": .string(snapshotID.uuidString), "readCursor": .string(cursor)])
    if let transactionID = query.id {
      guard query.after == nil, query.limit == nil, let manifestHash = query.revision,
        manifestHash.utf8.count == 64,
        manifestHash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
        throw CollaborationError("invalid_history_query", "Транзакция требует точный manifest SHA-256; after и limit относятся к реестру.")
      }
      let fact = try actionHistoryFact(transactionID: transactionID, manifestHash: manifestHash,
        receiptID: query.referenceID)
      guard fact.workspaceID == workspaceID, fact.borrowedSnapshotID == snapshotID else {
        throw NotebookStorageError.invalidTransaction("action history preflight cut changed")
      }
      let receipts: [JSONValue] = fact.receipts.map { receipt in
        var fields: [String: JSONValue] = ["id": .string(receipt.id.uuidString),
          "fragmentCount": .number(Double(receipt.fragments.count)),
          "fragmentBytes": .number(Double(receipt.fragments.reduce(0) { $0 + ($1.rawPayload?.count ?? 0) }))]
        switch receipt.disposition {
        case .completeSelfContained:
          fields["closure"] = .string("completeSelfContained")
        case .completeOriginalBody(_, let anchor):
          fields["closure"] = .string("completeOriginalBody")
          fields["originalAnchor"] = .object(["originalVersion": .string(anchor.originalVersion),
            "originalRootHash": .string(anchor.originalRootHash), "modelRootHash": .string(anchor.modelRootHash),
            "resultRootHash": .string(anchor.resultRootHash)])
        case .unprovenClosure(let reason):
          fields["closure"] = .string("unprovenClosure")
          fields["reason"] = .string(reason.rawValue)
        }
        return .object(fields)
      }
      return .object(["mode": .string("transaction"), "cut": cut,
        "transactionID": .string(transactionID.uuidString), "manifestHash": .string(fact.manifestHash),
        "manifestFormat": .number(Double(fact.manifestFormat)), "receipts": .array(receipts)])
    }
    guard query.referenceID == nil else {
      throw CollaborationError("invalid_history_query", "Квитанция требует ID принятой транзакции.")
    }
    if query.after != nil || query.revision != nil {
      guard query.revision == cursor else {
        throw CollaborationError("read_cursor_stale", "Реестр принятых изменений изменился. Начните новое чтение.")
      }
    }
    let page = try NotebookActionHistoryInventory.page(in: database, workspaceID: workspaceID,
      afterTransactionID: query.after, limit: query.limit ?? 32)
    var fields: [String: JSONValue] = ["mode": .string("inventory"), "cut": cut,
      "transactions": .array(page.occurrences.map(Self.historyOccurrenceSummary))]
    if page.next != nil, let last = page.occurrences.last {
      fields["nextTransactionID"] = .string(last.transactionID.uuidString)
    }
    return .object(fields)
  }

  private static func historyOccurrenceSummary(_ value: NotebookActionHistoryInventory.Occurrence) -> JSONValue {
    var fields: [String: JSONValue] = ["transactionID": .string(value.transactionID.uuidString),
      "manifestHash": .string(value.manifestHash)]
    if let local = value.localJournal {
      fields["localJournal"] = .object(["sequence": .string(String(local.sequence)),
        "manifestByteCount": .number(Double(local.manifestByteCount))])
    }
    if let received = value.firstReceived {
      fields["firstReceived"] = .object(["deviceID": .string(received.source.deviceID.uuidString),
        "generation": .string(received.source.generation.uuidString),
        "senderSequence": .string(String(received.senderSequence))])
    }
    return .object(fields)
  }
}

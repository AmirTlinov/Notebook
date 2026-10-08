import Foundation

extension NotebookStore {
  /// One finite metadata page. A native sealed reader owns exhaustive traversal;
  /// this portable projection grants no joint-readiness or migration authority.
  func replicaInventoryRead(_ query: NotebookReadQuery) throws -> JSONValue {
    guard let database = currentSQL, !database.writable else {
      throw NotebookStorageError.readOnlyTransaction
    }
    guard query.id == nil, query.after == nil, query.referenceID == nil,
      query.revision == nil, query.next == nil, query.scope == nil,
      query.limit.map({ (1...64).contains($0) }) ?? true else {
      throw CollaborationError("invalid_replica_query", "Метаданные реплики читаются отдельной конечной страницей.")
    }
    let cut = try NotebookReplicaInventory.cut(in: database)
    var result: [String: JSONValue] = ["cut": try Self.replicaCutProjection(cut),
      "complete": .bool(true), "jointReadiness": .bool(false)]
    switch query.replicaSection {
    case nil:
      result["mode"] = .string("cut")
    case .endpoints:
      let page = try NotebookReplicaInventory.endpoints(in: database, cut: cut, after: nil, limit: query.limit ?? 64)
      result["mode"] = .string("endpoints")
      result["entries"] = .array(try page.entries.map(Self.replicaEndpointProjection))
      result["complete"] = .bool(page.complete)
      result["scalarWitnessHash"] = .string(page.scalarWitnessHash)
    case .cloudAccounts:
      let page = try NotebookReplicaCloudInventory.accounts(in: database, cut: cut, after: nil, limit: query.limit ?? 64)
      result["mode"] = .string("cloudAccounts")
      result["entries"] = .array(try page.entries.map { entry in
        var fields = try JSONValue.encode(entry).object
        fields["uploadedThrough"] = .string(String(entry.uploadedThrough))
        return .object(fields)
      })
      result["complete"] = .bool(page.complete)
      result["scalarWitnessHash"] = .string(page.scalarWitnessHash)
    case .cloudPending:
      let page = try NotebookReplicaCloudInventory.pending(in: database, cut: cut, after: nil, limit: query.limit ?? 64)
      result["mode"] = .string("cloudPending")
      result["entries"] = .array(try page.entries.map(Self.replicaPendingProjection))
      result["complete"] = .bool(page.complete)
      result["scalarWitnessHash"] = .string(page.scalarWitnessHash)
    case .cloudReceipts:
      let page = try NotebookReplicaCloudInventory.receipts(in: database, cut: cut, after: nil, limit: query.limit ?? 64)
      result["mode"] = .string("cloudReceipts")
      result["entries"] = .array(try page.entries.map { try .encode($0) })
      result["receiptCount"] = .number(Double(page.receiptCount))
      result["complete"] = .bool(page.complete)
      result["scalarWitnessHash"] = .string(page.scalarWitnessHash)
    }
    return .object(result)
  }

  static func replicaCutProjection(_ cut: NotebookReplicaInventoryCut) throws -> JSONValue {
    var fields = try JSONValue.encode(cut).object
    fields["readRevision"] = .string(String(cut.readRevision))
    fields["readCursor"] = .string(String(cut.readRevision))
    if let head = cut.acceptedLocalPrefix {
      var value = try JSONValue.encode(head).object
      value["sequence"] = .string(String(head.sequence))
      fields["acceptedLocalPrefix"] = .object(value)
    }
    var floors: [String: JSONValue] = [:]
    for (key, value) in [("placement", cut.deliveryFloors.placement),
      ("ink", cut.deliveryFloors.ink), ("document", cut.deliveryFloors.document)] {
      if let value { floors[key] = .string(String(value)) }
    }
    fields["deliveryFloors"] = .object(floors)
    return .object(fields)
  }

  private static func replicaEndpointProjection(_ entry: NotebookReplicaEndpointObservation) throws -> JSONValue {
    var value = try JSONValue.encode(entry).object
    switch entry {
    case .incoming(_, let sequence):
      value["incoming"] = value["incoming"]?.setting("acceptedThrough", .string(String(sequence)))
    case .outgoing(_, let sequence):
      value["outgoing"] = value["outgoing"]?.setting("acknowledgedThrough", .string(String(sequence)))
    case .firstReceived(_, _, let sequence, _):
      value["firstReceived"] = value["firstReceived"]?.setting("senderSequence", .string(String(sequence)))
    case .snapshotCoverage(_, let sequence):
      value["snapshotCoverage"] = value["snapshotCoverage"]?.setting("coveredThrough", .string(String(sequence)))
    case .retirement(let retirement):
      value["retirement"] = value["retirement"]?.setting("_0",
        value["retirement"]?["_0"]?.setting("sourceCursor", .string(String(retirement.sourceCursor)))
          .setting("acknowledgedCursor", .string(String(retirement.acknowledgedCursor))))
    case .admittedGeneration: break
    }
    return .object(value)
  }

  private static func replicaPendingProjection(_ entry: NotebookReplicaCloudPendingObservation) throws -> JSONValue {
    var value = try JSONValue.encode(entry).object
    switch entry {
    case .export(_, _, _, _, _, let blob, let record):
      value["export"] = value["export"]?.setting("blobCursor", .string(String(blob)))
        .setting("recordCursor", .string(String(record)))
    case .incoming(_, _, _, let sequence, _, _):
      value["incoming"] = value["incoming"]?.setting("senderSequence", .string(String(sequence)))
    case .outbox(_, _, _, let offset, let total, _):
      value["outbox"] = value["outbox"]?.setting("offset", .string(String(offset)))
        .setting("totalBytes", .string(String(total)))
    case .chunk(_, _, let offset, let total, _):
      value["chunk"] = value["chunk"]?.setting("offset", .string(String(offset)))
        .setting("totalBytes", .string(String(total)))
    }
    return .object(value)
  }
}

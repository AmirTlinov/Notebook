import Foundation

extension NotebookStore {
  func updateAgentMetadata(_ fragment: NotebookStoredFragment, database: NotebookSQLConnection) throws {
    if fragment.file.hasPrefix("agent/requests/") {
      let request = try fragment.value.decode(AgentRequest.self)
      try request.validate()
      let status = try database.rows("SELECT status FROM metadata_index WHERE address=?", [.text(agentExecutionFile(request.id) + "#")]).first?[0].text ?? "queued"
      try database.run("INSERT INTO metadata_index(address,kind,context_id,created_at,status) VALUES(?,'agentRequest',?,?,?) ON CONFLICT(address) DO UPDATE SET status=excluded.status", [.text(fragment.address), .text(request.contextID.uuidString.lowercased()), .real(request.createdAt.timeIntervalSince1970), .text(status)])
    } else if fragment.file.hasPrefix("agent/executions/") {
      let execution = try fragment.value.decode(AgentExecution.self)
      try execution.validate()
      try database.run("INSERT INTO metadata_index(address,kind,context_id,created_at,status) VALUES(?,'agentExecution',?,0,?) ON CONFLICT(address) DO UPDATE SET status=excluded.status", [.text(fragment.address), .text(execution.requestID.uuidString.lowercased()), .text(execution.status.rawValue)])
      try database.run("UPDATE metadata_index SET status=? WHERE address=?", [.text(execution.status.rawValue), .text(agentRequestFile(execution.requestID) + "#")])
    }
  }

  public func readAgentRequestHeaders(afterID: UUID? = nil, limit: Int = 64) throws -> [AgentRequest] {
    guard (1...128).contains(limit) else { throw NotebookStorageError.limitExceeded("request_page") }
    return try readTransaction { _ in
      var clause = "", arguments: [NotebookSQLValue] = []
      if let afterID {
        let address = agentRequestFile(afterID) + "#"
        guard let time = try currentSQL!.rows("SELECT created_at FROM metadata_index WHERE address=? AND kind='agentRequest'", [.text(address)]).first?[0] else { throw NotebookStorageError.transactionConflict }
        clause = " AND (created_at<? OR (created_at=? AND address<?))"
        arguments = [time, time, .text(address)]
      }
      arguments.append(.integer(Int64(limit)))
      let rows = try currentSQL!.rows("SELECT address FROM metadata_index WHERE kind='agentRequest'" + clause + " ORDER BY created_at DESC,address DESC LIMIT ?", arguments)
      return try rows.map { try storedValue(String($0[0].text!.dropLast()))!.decode(AgentRequest.self) }
    }
  }

  /// Completed history cannot hide a queued offline question. This indexed
  /// worker page loads immutable request headers, never accumulated responses.
  public func pendingAgentRequests(limit: Int = 16) throws -> [AgentRequest] {
    guard (1...16).contains(limit) else { throw NotebookStorageError.limitExceeded("pending_requests") }
    return try readTransaction { _ in
      let rows = try currentSQL!.rows("SELECT address FROM metadata_index WHERE kind='agentRequest' AND status IN ('queued','running') ORDER BY created_at,address LIMIT ?", [.integer(Int64(limit))])
      return try rows.map { try storedValue(String($0[0].text!.dropLast()))!.decode(AgentRequest.self) }
    }
  }

  func mergeAgentRecord(file: String, value: JSONValue, previous: JSONValue?) throws -> JSONValue {
    let parts = file.split(separator: "/").map(String.init)
    guard parts.count >= 3, let requestID = UUID(uuidString: String(parts[2].prefix(36))) else { throw NotebookStorageError.invalidTransaction("agent record address") }
    switch parts[1] {
    case "requests":
      let request = try value.decode(AgentRequest.self)
      try request.validate()
      guard request.id == requestID, file == agentRequestFile(requestID) else { throw NotebookStorageError.invalidTransaction("request identity") }
    case "sources":
      let source = try value.decode(AgentPinnedSource.self)
      try source.validate()
      guard source.requestID == requestID, file == agentSourceFile(requestID, source.id) else { throw NotebookStorageError.invalidTransaction("source identity") }
    case "chunks":
      let chunk = try value.decode(AgentResponseChunk.self)
      try chunk.validate()
      guard chunk.requestID == requestID, file == agentChunkFile(requestID, chunk.sequence) else { throw NotebookStorageError.invalidTransaction("response identity") }
    case "stops":
      let stop = try value.decode(AgentStopIntent.self)
      guard stop.requestID == requestID, file == agentStopFile(requestID) else { throw NotebookStorageError.invalidTransaction("stop identity") }
    case "executions":
      let next = try value.decode(AgentExecution.self)
      try next.validate()
      guard next.requestID == requestID, file == agentExecutionFile(requestID) else { throw NotebookStorageError.invalidTransaction("execution identity") }
      if let previous {
        let old = try previous.decode(AgentExecution.self)
        try old.validate()
        guard old.executionID == next.executionID, old.stamp.actor == next.stamp.actor else { throw NotebookStorageError.transactionConflict }
        if old.stamp > next.stamp { return previous }
        if old.stamp == next.stamp {
          guard old == next else { throw NotebookStorageError.transactionConflict }
          return previous
        }
        guard old.status == .running || old.status == next.status,
          next.responseSequence >= old.responseSequence, next.responseBytes >= old.responseBytes,
          next.receiptIDs.starts(with: old.receiptIDs),
          old.answerEntryID == nil || old.answerEntryID == next.answerEntryID else { throw NotebookStorageError.transactionConflict }
      }
      return value
    default: throw NotebookStorageError.invalidTransaction("agent record kind")
    }
    if let previous, previous != value { throw NotebookStorageError.transactionConflict }
    return value
  }

  func validateReplicatedAgentDependencies(writes: [String: JSONValue], previous: [String: JSONValue]) throws {
    let requests = Set(writes.keys.filter { $0.hasPrefix("agent/") }.compactMap { file in
      file.split(separator: "/").dropFirst(2).first.flatMap { UUID(uuidString: String($0.prefix(36))) }
    })
    for id in requests {
      guard let request = try storedValue(agentRequestFile(id))?.decode(AgentRequest.self),
        let question = try storedMember(file: contextFile(request.contextID), collection: "entries", id: request.questionEntryID.uuidString)?.decode(SharedContextEntry.self),
        question.author == .human, !(question.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        question.references == request.grant.references else { throw NotebookStorageError.invalidTransaction("request context dependency") }
      try request.validate()
      var sourceBytes = 0
      for sourceID in request.sourceIDs {
        guard let source = try storedValue(agentSourceFile(id, sourceID))?.decode(AgentPinnedSource.self),
          source.requestID == id, source.id == sourceID, request.grant.references.contains(source.reference) else { throw NotebookStorageError.invalidTransaction("request source dependency") }
        try source.validate()
        sourceBytes += try Self.storageEncoder.encode(source).count
      }
      guard sourceBytes <= 8_388_608 else { throw NotebookStorageError.limitExceeded("request_sources") }
      if let stop = try storedValue(agentStopFile(id))?.decode(AgentStopIntent.self) {
        guard stop.authorDeviceID == request.authorDeviceID else { throw NotebookStorageError.invalidTransaction("request stop author") }
      }
      if let execution = try storedValue(agentExecutionFile(id))?.decode(AgentExecution.self) {
        try execution.validate()
        let old = try previous[agentExecutionFile(id)]?.decode(AgentExecution.self)
        var bytes = old?.responseBytes ?? 0
        let first = (old?.responseSequence ?? 0) + 1
        if first <= execution.responseSequence {
          for sequence in first...execution.responseSequence {
            guard let chunk = try storedValue(agentChunkFile(id, sequence))?.decode(AgentResponseChunk.self),
              chunk.requestID == id, chunk.executionID == execution.executionID, chunk.sequence == sequence else { throw NotebookStorageError.invalidTransaction("response sequence dependency") }
            try chunk.validate(); bytes += chunk.text.utf8.count
          }
        }
        guard bytes == execution.responseBytes else { throw NotebookStorageError.invalidTransaction("response byte count") }
        for receiptID in execution.receiptIDs where old?.receiptIDs.contains(receiptID) != true {
          guard let receipt = try storedValue("collaboration/actions/" + receiptID.uuidString.lowercased() + ".json")?.decode(CollaborationReceipt.self),
            receipt.id == receiptID, receipt.action.requestID == id else { throw NotebookStorageError.invalidTransaction("agent receipt dependency") }
        }
        if let answerID = execution.answerEntryID {
          guard let answer = try storedMember(file: contextFile(request.contextID), collection: "entries", id: answerID.uuidString)?.decode(SharedContextEntry.self),
            answer.author == .agent, answer.replyTo == request.questionEntryID else { throw NotebookStorageError.invalidTransaction("agent answer dependency") }
        }
      }
    }
  }
}

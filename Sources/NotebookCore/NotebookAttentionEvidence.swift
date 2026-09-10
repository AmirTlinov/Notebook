import Foundation

extension NotebookStore {
  private func attentionEvidenceFile(_ contextID: UUID, _ referenceID: UUID) -> String {
    "collaboration/attention/\(contextID.uuidString.lowercased())/\(referenceID.uuidString.lowercased()).json"
  }

  /// Reuses the existing frozen-source value, not an AgentRequest or execution
  /// grant. Here requestID names the human SharedContext that owns the evidence.
  public func saveAttentionEvidence(_ sources: [AgentPinnedSource], contextID: UUID) throws {
    guard !sources.isEmpty, sources.count <= 32 else { throw NotebookStorageError.limitExceeded("attention sources") }
    try commandTransaction {
      for source in sources {
        let file = attentionEvidenceFile(contextID, source.id)
        let value = try JSONValue.encode(source)
        try validateAttentionEvidence(file: file, value: value, previous: storedValue(file))
        try publishRecords(writes: [file: value])
      }
    }
  }

  public func attentionEvidence(contextID: UUID, referenceID: UUID) throws -> AgentPinnedSource? {
    try readTransaction { _ in
      let file = attentionEvidenceFile(contextID, referenceID)
      guard let value = try storedValue(file) else { return nil }
      try validateAttentionEvidence(file: file, value: value, previous: nil)
      return try value.decode(AgentPinnedSource.self)
    }
  }

  public func hasAttentionEvidence(contextID: UUID) throws -> Bool {
    try readTransaction { _ in
      guard let context = try storedValue(contextFile(contextID))?.decode(SharedContext.self),
        let entry = context.entries.first(where: { $0.author == .human }) else { return false }
      return try entry.references.allSatisfy { try attentionEvidence(contextID: contextID, referenceID: $0.id) != nil }
    }
  }

  func validateAttentionEvidence(file: String, value: JSONValue, previous: JSONValue?) throws {
    let source = try value.decode(AgentPinnedSource.self)
    try source.validate()
    guard file == attentionEvidenceFile(source.requestID, source.id), previous == nil || previous == value,
      let context = try storedValue(contextFile(source.requestID))?.decode(SharedContext.self),
      context.entries.contains(where: { $0.author == .human && $0.references.contains(source.reference) }) else {
      throw NotebookStorageError.invalidTransaction("immutable attention owner")
    }
  }
}

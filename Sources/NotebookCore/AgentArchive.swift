import Foundation

/// Read-only addressed preservation of historical Notebook executor records.
/// Codex chat never creates, claims, advances or stops these archived values.
extension NotebookStore {
  func agentRequestFile(_ id: UUID) -> String { "agent/requests/\(id.uuidString.lowercased()).json" }
  func agentExecutionFile(_ id: UUID) -> String { "agent/executions/\(id.uuidString.lowercased()).json" }
  func agentStopFile(_ id: UUID) -> String { "agent/stops/\(id.uuidString.lowercased()).json" }
  func agentSourceFile(_ requestID: UUID, _ id: UUID) -> String { "agent/sources/\(requestID.uuidString.lowercased())/\(id.uuidString.lowercased()).json" }
  func agentChunkFile(_ id: UUID, _ sequence: UInt64) -> String { "agent/chunks/\(id.uuidString.lowercased())/\(String(format: "%020llu", sequence)).json" }

  public func agentRequest(_ id: UUID, includesResponse: Bool = true) throws -> AgentRequestSnapshot? {
    try readTransaction { _ in
      guard let request = try storedValue(agentRequestFile(id))?.decode(AgentRequest.self) else { return nil }
      try request.validate()
      let execution = try storedValue(agentExecutionFile(id))?.decode(AgentExecution.self)
      try execution?.validate()
      return try .init(request: request, execution: execution,
        stopRequested: hasStoredValue(agentStopFile(id)), responseText: includesResponse ? agentResponseText(execution) : "")
    }
  }

  private func agentResponseText(_ execution: AgentExecution?) throws -> String {
    guard let execution else { return "" }
    guard execution.responseSequence <= 2_048 else { throw agentMissing() }
    var parts: [String] = [], bytes = 0
    if execution.responseSequence > 0 {
      for sequence in 1...execution.responseSequence {
        guard let chunk = try storedValue(agentChunkFile(execution.requestID, sequence))?.decode(AgentResponseChunk.self),
          chunk.executionID == execution.executionID, chunk.sequence == sequence else { throw agentMissing() }
        try chunk.validate()
        parts.append(chunk.text); bytes += chunk.text.utf8.count
        guard bytes <= 1_048_576 else { throw agentMissing() }
      }
    }
    guard bytes == execution.responseBytes else { throw agentMissing() }
    return parts.joined()
  }
  private func agentMissing() -> CollaborationError { .init("request_missing", "Архивный запрос или его закреплённое содержание отсутствует.") }
}

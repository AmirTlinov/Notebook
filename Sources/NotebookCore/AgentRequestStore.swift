import Foundation

/// Immutable input for one request. This is a redacted physical fragment, not
/// a path to the latest document or permission to read the current selection.
public struct AgentPinnedSource: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let requestID: UUID
  public let reference: CollaborationReference
  public let payload: JSONValue
  public var image: AgentPinnedImage?

  public func withVisual(_ image: AgentPinnedImage?, unavailable: String? = nil) throws -> Self {
    var content = payload.object
    content["visual"] = .object(["status": .string(image == nil ? "unavailable" : "source_pixels"),
      "reason": unavailable.map { .string(String($0.prefix(2_048))) } ?? .null])
    let value = Self(id: id, requestID: requestID, reference: reference, payload: .object(content), image: image)
    try value.validate(); return value
  }

  public func validate() throws {
    guard id == reference.id, payload.isValid,
      try NotebookStore.storageEncoder.encode(payload).count <= 1_048_576 else {
      throw CollaborationError("invalid_request_source", "Закреплённый исходник превышает допустимый размер.")
    }
    try RequestGrant(mode: .question, references: [reference]).validate()
    try image?.validate(reference: reference)
  }

  public static func capture(requestID: UUID, reference: CollaborationReference,
    files: [String: JSONValue]) throws -> Self {
    guard try NotebookStore.referenceRevision(target: reference.target, elementID: reference.elementID, files: files) == reference.revision else {
      throw CollaborationError("source_conflict", "Выделение и закреплённый исходник имеют разные версии.")
    }
    let grant = try RequestGrant(mode: .question, references: [reference])
    let target = reference.target
    let suffix = target.id.uuidString.lowercased() + ".json"
    let elements: [JSONValue]
    var payload: [String: JSONValue] = ["reference": try .encode(reference)]
    switch target.kind {
    case .page:
      guard let page = files["pages/" + suffix] else { throw missing() }
      elements = page["elements"]?.array ?? []
      payload["paperSize"] = page["size"]
      // Ink is represented by an exact regional image, never by raw strokes
      // whose endpoints could disclose content outside an area permission.
    case .document:
      guard let document = files["documents/" + suffix] else { throw missing() }
      if let blockID = reference.elementID {
        guard let block = document["blocks"]?.array.first(where: { $0["id"]?.string == blockID }) else { throw missing() }
        payload["block"] = block
        if let state = files["document-states/" + suffix]?["records"]?.array.first(where: { $0["blockID"]?.string == blockID }) {
          payload["state"] = state["value"]
        }
      }
      // Pagination geometry alone does not authorize every program in a file.
      elements = []
    case .board, .cover:
      let boardID = target.kind == .board ? target.id : target.boardID!
      guard let node = files["board.json"]?["boards"]?.array.first(where: {
        $0["id"]?.string?.lowercased() == boardID.uuidString.lowercased()
      }) else { throw missing() }
      let surface = target.kind == .board ? SurfaceID.board(target.id) : .cover(target.id)
      elements = try (node["board"]?["elements"]?.array ?? []).filter {
        try $0["surface"]?.decode(SurfaceID.self) == surface
      }
    case .workspace: throw CollaborationError("grant_denied", "Запрос не получает весь архив.")
    }
    payload["elements"] = try .array(elements.filter { value in
      guard let id = value["id"]?.string, let frame = value["frame"] else { return false }
      return try grant.permits(target: target, elementID: id, region: frame.decode(PageRect.self),
        worldOrigin: value["worldOrigin"]?.decode(WorldPoint.self))
    })
    let result = Self(id: reference.id, requestID: requestID, reference: reference, payload: .object(payload))
    try result.validate(); return result
  }

  private static func missing() -> CollaborationError { .init("source_missing", "Закреплённый владелец отсутствует.") }
}

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

  /// A bounded request page is enough for recovery; the executor claims an ID
  /// once rather than interpreting every reconnect as a new human question.
  public func agentRequests(afterID: UUID? = nil, limit: Int = 64) throws -> [AgentRequestSnapshot] {
    try readTransaction { _ in
      try readAgentRequestHeaders(afterID: afterID, limit: limit).compactMap { try agentRequest($0.id) }
    }
  }

  @discardableResult
  public func createAgentRequest(id: UUID, contextID: UUID, replyTo: UUID, question: String,
    grant: RequestGrant, sources: [AgentPinnedSource], actor: UUID) throws -> AgentRequest {
    try grant.validate()
    guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, question.utf8.count <= 65_536,
      sources.count == grant.references.count, Set(sources.map(\.id)) == Set(grant.references.map(\.id)),
      sources.allSatisfy({ $0.requestID == id && grant.references.contains($0.reference) }),
      try sources.reduce(0, { $0 + (try Self.storageEncoder.encode($1).count) }) <= 8_388_608 else {
      throw CollaborationError("invalid_request", "Вопрос сохраняет текст и закреплённые исходники выбранных фрагментов.")
    }
    guard sources.reduce(0, { $0 + ($1.image?.png.count ?? 0) }) <= 4_194_304 else {
      throw CollaborationError("request_image_limit", "Изображения вопроса превышают 4 МиБ.")
    }
    for source in sources { try source.validate() }
    return try commandTransaction {
      if let previous = try storedValue(agentRequestFile(id))?.decode(AgentRequest.self) {
        guard previous.contextID == contextID, previous.grant == grant, previous.authorDeviceID == actor,
          Set(previous.sourceIDs) == Set(sources.map(\.id)),
          let entry = try storedMember(file: contextFile(contextID), collection: "entries",
            id: previous.questionEntryID.uuidString)?.decode(SharedContextEntry.self),
          entry.text == question, entry.replyTo == replyTo else {
          throw CollaborationError("request_id_conflict", "Этот ID уже принадлежит другому вопросу.")
        }
        for source in sources {
          guard try storedValue(agentSourceFile(id, source.id))?.decode(AgentPinnedSource.self) == source else {
            throw CollaborationError("request_id_conflict", "Повтор вопроса не может заменить закреплённый исходник.")
          }
        }
        return previous
      }
      guard var context = try storedValue(contextFile(contextID))?.decode(SharedContext.self),
        context.entries.contains(where: { $0.id == replyTo }) else {
        throw CollaborationError("context_missing", "Вопрос продолжает существующее указание.")
      }
      let stamp = try agentContextStamp(context, actor: actor)
      let entry = SharedContextEntry(author: .human, references: grant.references, replyTo: replyTo, text: question, stamp: stamp)
      try context.merge(.init(id: contextID, entries: [entry]))
      let request = AgentRequest(id: id, contextID: contextID, questionEntryID: entry.id,
        grant: grant, authorDeviceID: actor, sourceIDs: sources.map(\.id))
      var writes = [agentRequestFile(id): try JSONValue.encode(request), contextFile(contextID): try .encode(context)]
      for source in sources { writes[agentSourceFile(id, source.id)] = try .encode(source) }
      try publishRecords(writes: writes)
      return request
    }
  }

  public func claimAgentRequest(_ id: UUID, actor: UUID) throws -> AgentActionAuthority {
    try commandTransaction {
      guard let request = try storedValue(agentRequestFile(id))?.decode(AgentRequest.self) else { throw agentMissing() }
      try request.validate()
      guard try !hasStoredValue(agentExecutionFile(id)) else { throw CollaborationError("request_claimed", "Вопрос уже исполнялся; повторная доставка не запускает его заново.") }
      let authority = AgentActionAuthority(requestID: id, executionID: UUID())
      let stopped = try hasStoredValue(agentStopFile(id))
      let execution = AgentExecution(requestID: id, executionID: authority.executionID,
        status: stopped ? .stopped : .running, stamp: .init(counter: 0, actor: actor),
        responseSequence: 0, responseBytes: 0, receiptIDs: [])
      try publishRecords(writes: [agentExecutionFile(id): .encode(execution)])
      return authority
    }
  }

  public func agentQuestion(_ authority: AgentActionAuthority) throws -> String {
    try readTransaction { _ in
      let (request, _) = try requireAgentExecution(authority)
      guard let entry = try storedMember(file: contextFile(request.contextID), collection: "entries",
        id: request.questionEntryID.uuidString)?.decode(SharedContextEntry.self),
        entry.author == .human, let text = entry.text else { throw agentMissing() }
      return text
    }
  }

  public func agentPinnedSource(_ authority: AgentActionAuthority, referenceID: UUID) throws -> AgentPinnedSource {
    try readTransaction { _ in
      let (request, _) = try requireAgentExecution(authority)
      guard request.sourceIDs.contains(referenceID),
        let source = try storedValue(agentSourceFile(request.id, referenceID))?.decode(AgentPinnedSource.self),
        source.requestID == request.id, request.grant.references.contains(source.reference) else { throw agentMissing() }
      try source.validate(); return source
    }
  }

  public func agentPinnedSources(_ authority: AgentActionAuthority) throws -> [AgentPinnedSource] {
    try readTransaction { _ in
      let (request, _) = try requireAgentExecution(authority)
      return try request.sourceIDs.map { id in
        guard let source = try storedValue(agentSourceFile(request.id, id))?.decode(AgentPinnedSource.self) else { throw agentMissing() }
        try source.validate(); return source
      }
    }
  }

  public func requestAgentStop(_ id: UUID, actor: UUID) throws {
    try commandTransaction {
      guard let request = try storedValue(agentRequestFile(id))?.decode(AgentRequest.self), request.authorDeviceID == actor else { throw agentMissing() }
      if try hasStoredValue(agentStopFile(id)) { return }
      try publishRecords(writes: [agentStopFile(id): .encode(AgentStopIntent(requestID: id, authorDeviceID: actor))])
    }
  }

  public func appendAgentResponse(_ authority: AgentActionAuthority, sequence: UInt64, text: String) throws {
    guard !text.isEmpty, text.utf8.count <= 8_192 else { throw CollaborationError("response_limit", "Порция ответа содержит до 8 КиБ текста.") }
    try commandTransaction {
      let (_, current) = try requireAgentExecution(authority)
      if let old = try storedValue(agentChunkFile(authority.requestID, sequence))?.decode(AgentResponseChunk.self) {
        guard old.executionID == authority.executionID, old.text == text else { throw CollaborationError("response_conflict", "Номер порции уже занят другим текстом.") }
        return
      }
      guard sequence == current.responseSequence + 1, sequence <= 2_048,
        current.responseBytes + text.utf8.count <= 1_048_576 else { throw CollaborationError("response_limit", "Ответ превысил ограничение либо пропущена предыдущая порция.") }
      var next = current
      next.responseSequence = sequence; next.responseBytes += text.utf8.count
      next.stamp = try nextAgentStamp(current.stamp)
      let chunk = AgentResponseChunk(requestID: authority.requestID, executionID: authority.executionID, sequence: sequence, text: text)
      try publishRecords(writes: [agentChunkFile(authority.requestID, sequence): .encode(chunk), agentExecutionFile(authority.requestID): .encode(next)])
    }
  }

  /// Cancellation reaches this method only after the Mac observes the turn's
  /// terminal state or process exit. Its SQL commit fences all late actions.
  public func finishAgentRequest(_ authority: AgentActionAuthority, status: AgentExecution.Status,
    error: String? = nil) throws -> AgentExecution {
    guard status != .running else { throw CollaborationError("invalid_completion", "Ожидание не является завершением запроса.") }
    return try commandTransaction {
      guard let current = try storedValue(agentExecutionFile(authority.requestID))?.decode(AgentExecution.self),
        current.executionID == authority.executionID else { throw agentMissing() }
      if current.status != .running { return current }
      let (request, _) = try requireAgentExecution(authority)
      var next = current
      next.status = status; next.error = error.map { String($0.prefix(2_048)) }; next.stamp = try nextAgentStamp(current.stamp)
      var writes: [String: JSONValue] = [:]
      if status == .completed {
        guard request.grant.mode == .question || !current.receiptIDs.isEmpty else {
          throw CollaborationError("mutation_unconfirmed", "Агент не сохранил изменение: нет квитанции выполненного хода.")
        }
        let answer = try agentResponseText(current)
        guard !answer.isEmpty || !current.receiptIDs.isEmpty else { throw CollaborationError("empty_response", "Нет ни ответа, ни сохранённого изменения.") }
        guard var context = try storedValue(contextFile(request.contextID))?.decode(SharedContext.self) else { throw agentMissing() }
        let entry = SharedContextEntry(author: .agent, references: request.grant.references,
          replyTo: request.questionEntryID, text: answer.isEmpty ? "Изменение сохранено." : answer,
          stamp: try agentContextStamp(context, actor: current.stamp.actor))
        try context.merge(.init(id: context.id, entries: [entry])); next.answerEntryID = entry.id
        writes[contextFile(context.id)] = try .encode(context)
      }
      writes[agentExecutionFile(authority.requestID)] = try .encode(next)
      try publishRecords(writes: writes); return next
    }
  }

  func requireAgentExecution(_ authority: AgentActionAuthority) throws -> (AgentRequest, AgentExecution) {
    guard let request = try storedValue(agentRequestFile(authority.requestID))?.decode(AgentRequest.self),
      let execution = try storedValue(agentExecutionFile(authority.requestID))?.decode(AgentExecution.self),
      execution.executionID == authority.executionID, execution.status == .running else {
      throw CollaborationError("request_not_running", "Разрешение запроса уже завершено или не принадлежит этому исполнителю.")
    }
    try request.validate(); try execution.validate(); return (request, execution)
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
  private func agentContextStamp(_ context: SharedContext, actor: UUID) throws -> VersionStamp {
    try nextAgentStamp(.init(counter: context.entries.map(\.stamp.counter).max() ?? 0, actor: actor))
  }
  func nextAgentStamp(_ stamp: VersionStamp) throws -> VersionStamp {
    guard let next = stamp.advanced(by: stamp.actor) else { throw CollaborationError("version_exhausted", "Версия исполнения достигла предела.") }
    return next
  }
  private func agentMissing() -> CollaborationError { .init("request_missing", "Запрос или его закреплённое содержание отсутствует.") }
}

import Foundation
import CryptoKit

public struct NotebookScriptRequest: Codable, Sendable {
  public enum Operation: String, Codable, Sendable { case start, resume, cancel }
  public var op: Operation
  public var runID: UUID
  public var apiVersion: Int?
  public var code: String?
  public var arguments: JSONValue?
  public var afterSequence: Int?
  public var waitMilliseconds: Int?
  public init(op: Operation, runID: UUID, apiVersion: Int? = nil, code: String? = nil,
    arguments: JSONValue? = nil, afterSequence: Int? = nil, waitMilliseconds: Int? = nil) {
    self.op = op; self.runID = runID; self.apiVersion = apiVersion; self.code = code
    self.arguments = arguments; self.afterSequence = afterSequence; self.waitMilliseconds = waitMilliseconds
  }
}

public struct NotebookScriptContextRequest: Codable, Sendable {
  public var method: String
  public var arguments: JSONValue
  public init(method: String = "observe", arguments: JSONValue = .object([:])) { self.method = method; self.arguments = arguments }
}

public struct NotebookScriptRun: Codable, Equatable, Sendable, Identifiable {
  public enum State: String, Codable, Sendable { case queued, running, completed, failed, cancelled, interrupted }
  public let id: UUID
  public let workspaceID: UUID
  public let fingerprint: String
  public let apiVersion: Int
  public let code: String
  public let arguments: JSONValue
  public var state: State
  public var lastSequence: Int
  public var outputBytes: Int
  public let createdAt: Date
  public var finishedAt: Date?
  public var result: JSONValue?
  public var error: JSONValue?
  public var cancellationRequestedAt: Date?
  public var isTerminal: Bool { ![.queued, .running].contains(state) }
}

public struct NotebookScriptEvent: Codable, Equatable, Sendable {
  public let sequence: Int
  public let kind: String
  public let value: JSONValue
  public let createdAt: Date
}

public struct NotebookScriptEffect: Codable, Equatable, Sendable {
  public enum State: String, Codable, Sendable { case admitted, committing, saved, notSaved, outcomeUnknown }
  public let id: UUID
  public let key: String
  public let method: String
  public let fingerprint: String
  public let arguments: JSONValue
  public var state: State
  public var value: JSONValue?
  public var error: JSONValue?
}

extension NotebookStore {
  private func scriptFile(_ id: UUID) -> String { "local/script-runs/\(id.uuidString.lowercased())/run.json" }
  private func scriptPrefix(_ id: UUID) -> String { "local/script-runs/\(id.uuidString.lowercased())/" }

  public func scriptRun(_ id: UUID) throws -> NotebookScriptRun? {
    try readTransaction { _ in try storedValue(scriptFile(id))?.decode(NotebookScriptRun.self) }
  }

  public func admitScriptRun(_ request: NotebookScriptRequest) throws -> NotebookScriptRun {
    guard request.op == .start, request.apiVersion == 1, let code = request.code,
      code.utf8.count <= 262_144 else { throw CollaborationError("invalid_script", "API v1 принимает JavaScript до 256 КиБ.") }
    let args = request.arguments ?? .null
    guard try JSONEncoder().encode(args).count <= 1_048_576 else { throw CollaborationError("resource_limit", "Аргументы превышают 1 МиБ.") }
    return try commandTransaction(advancesReadRevision: false) {
      let workspace = try workspaceHeader().workspaceID
      let fingerprint = try collaborationHash(JSONValue.object(["domain": .string("notebook.script-run.v1"),
        "workspaceID": .string(workspace.uuidString.lowercased()), "apiVersion": .number(1), "code": .string(code), "arguments": args]))
      if let previous = try scriptRun(request.runID) {
        guard previous.fingerprint == fingerprint else { throw CollaborationError("run_id_conflict", "Этот run_id уже принадлежит другой программе или аргументам.") }
        return previous
      }
      let active = try unfinishedScriptRuns()
      guard active.count < 9 else { throw CollaborationError("script_queue_full", "На Mac выполняется одна программа и ожидают не более восьми.") }
      let value = NotebookScriptRun(id: request.runID, workspaceID: workspace, fingerprint: fingerprint,
        apiVersion: 1, code: code, arguments: args, state: .queued, lastSequence: 0, outputBytes: 0, createdAt: Date())
      try publishRecords(writes: [scriptFile(value.id): try .encode(value)])
      try publishRecords(writes: [scriptPrefix(value.id) + "effect-index.json": .array([])])
      try publishRecords(writes: ["local/script-active.json": try .encode(active.map(\.id) + [value.id])])
      return value
    }
  }

  public func unfinishedScriptRuns() throws -> [NotebookScriptRun] {
    try readTransaction { _ in
      let ids = try storedValue("local/script-active.json")?.decode([UUID].self) ?? []
      guard ids.count <= 9 else { throw NotebookStorageError.corruptRecord("script admission window") }
      return try ids.compactMap { try scriptRun($0) }.filter { !$0.isTerminal }.sorted { $0.createdAt < $1.createdAt }
    }
  }

  public func setScriptRunState(_ id: UUID, state: NotebookScriptRun.State,
    result: JSONValue? = nil, error: JSONValue? = nil) throws -> NotebookScriptRun {
    return try commandTransaction(advancesReadRevision: false) {
      guard var value = try scriptRun(id) else { throw CollaborationError("run_missing", "Программа не найдена.") }
      if value.isTerminal { return value }
      let finishing = ![NotebookScriptRun.State.queued, .running].contains(state)
      if state == .cancelled || (finishing && value.cancellationRequestedAt != nil) {
        // The same writer orders cancellation against completion. A worker
        // crash/success reply cannot overwrite an already accepted cancel.
        value.state = .cancelled; value.result = nil; value.error = try .encode(Self.scriptCancellationError)
      } else {
        guard try result.map({ try JSONEncoder().encode($0).count <= 262_144 }) ?? true else {
          throw CollaborationError("output_limit", "Возвращаемое значение программы ограничено 256 КиБ; выводите материал ограниченными порциями.")
        }
        value.state = state; value.result = result; value.error = error
      }
      if value.isTerminal { value.finishedAt = Date() }
      try publishRecords(writes: [scriptFile(id): try .encode(value)])
      if value.isTerminal {
        let active = try storedValue("local/script-active.json")?.decode([UUID].self) ?? []
        try publishRecords(writes: ["local/script-active.json": try .encode(active.filter { $0 != id })])
      }
      return value
    }
  }

  public static var scriptCancellationError: CollaborationError {
    .init("run_cancelled", "Программа отменена. Уже принятые изменения сохраняются в квитанциях effects.")
  }

  /// Running code closes only after accepted native effects settle. Queued
  /// code has no worker/effect to drain and closes at this writer fence.
  public func requestScriptRunCancellation(_ id: UUID) throws -> NotebookScriptRun {
    try commandTransaction(advancesReadRevision: false) {
      guard var value = try scriptRun(id) else { throw CollaborationError("run_missing", "Программа не найдена.") }
      guard !value.isTerminal else { return value }
      if value.cancellationRequestedAt == nil {
        value.cancellationRequestedAt = Date()
        try publishRecords(writes: [scriptFile(id): try .encode(value)])
      }
      return value.state == .queued ? try setScriptRunState(id, state: .cancelled) : value
    }
  }

  public func appendScriptEvent(_ id: UUID, kind: String, value payload: JSONValue,
    additionalByteCount: Int = 0) throws -> NotebookScriptEvent {
    let bytes = try JSONEncoder().encode(payload).count
    return try commandTransaction(advancesReadRevision: false) {
      guard var value = try scriptRun(id), !value.isTerminal else { throw CollaborationError("run_closed", "Программа уже завершена.") }
      guard additionalByteCount >= 0, additionalByteCount <= 4*1_048_576,
        bytes <= 262_144, value.outputBytes + bytes + additionalByteCount <= 4*1_048_576, value.lastSequence < 128 else {
        throw CollaborationError("output_limit", "Вывод ограничен 4 МиБ и 128 событиями до 256 КиБ; верните меньший срез.")
      }
      value.lastSequence += 1; value.outputBytes += bytes + additionalByteCount
      let event = NotebookScriptEvent(sequence: value.lastSequence, kind: kind, value: payload, createdAt: Date())
      try publishRecords(writes: [scriptFile(id): try .encode(value),
        scriptPrefix(id) + "events/\(String(format: "%06d", event.sequence)).json": try .encode(event)])
      return event
    }
  }

  /// Emitted pixels are immutable output, not a pointer to a preview that the
  /// next camera movement may overwrite before the client resumes.
  public func appendScriptImageEvent(_ id: UUID, png: Data, expectedSHA256: String) throws -> NotebookScriptEvent {
    let hash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
    guard hash == expectedSHA256, png.starts(with: Data([137,80,78,71,13,10,26,10])) else {
      throw CollaborationError("invalid_artifact", "Пиксели не соответствуют прочитанному изображению.")
    }
    return try commandTransaction(advancesReadRevision: false) {
      let artifact = NotebookArtifactRequest(kind: .scriptImage, expectedSHA256: hash)
      let event = try appendScriptEvent(id, kind: "image", value: .encode(artifact), additionalByteCount: png.count)
      let path = root.appendingPathComponent("local/script-images/\(hash).png")
      try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      if !FileManager.default.fileExists(atPath: path.path) { try png.write(to: path, options: .atomic) }
      return event
    }
  }

  public func scriptRunPage(_ id: UUID, after: Int = 0) throws -> JSONValue {
    guard after >= 0 else { throw CollaborationError("invalid_cursor", "after_seq неотрицателен.") }
    return try readTransaction { _ in
      guard let run = try scriptRun(id), after <= run.lastSequence else { throw CollaborationError("run_missing", "Программа или последовательность не найдена.") }
      var events: [NotebookScriptEvent] = [], bytes = 0, images = 0
      if after < run.lastSequence {
        for sequence in (after + 1)...run.lastSequence {
          guard let value = try storedValue(scriptPrefix(id) + "events/\(String(format: "%06d", sequence)).json") else {
            throw NotebookStorageError.corruptRecord("script event gap")
          }
          let size = try JSONEncoder().encode(value).count
          if !events.isEmpty && bytes + size > 524_288 { break }
          if value["kind"] == .string("image") {
            if images == 4 { break }
            images += 1
          }
          events.append(try value.decode(NotebookScriptEvent.self)); bytes += size
        }
      }
      let next = events.last?.sequence ?? after
      return .object(["status": .string(run.state.rawValue), "run_id": .string(id.uuidString.lowercased()),
        "fingerprint": .string(run.fingerprint), "api_version": .number(Double(run.apiVersion)),
        "events": try .encode(events), "next_seq": .number(Double(next)), "has_more": .bool(next < run.lastSequence),
        "result": run.result ?? .null, "error": run.error ?? .null,
        "effects": .array(try scriptEffectIndex(id)),
        "resume_semantics": .string("attach_only_no_replay")])
    }
  }

  private static func publicScriptEffect(_ effect: NotebookScriptEffect) -> JSONValue {
    var result: [String: JSONValue] = ["id": .string(effect.id.uuidString.lowercased()), "key": .string(effect.key),
      "method": .string(effect.method), "state": .string(effect.state.rawValue), "fingerprint": .string(effect.fingerprint)]
    if let error = effect.error {
      var detail: [String: JSONValue] = ["code": .string(String((error["code"]?.string ?? "operation_failed").prefix(120))),
        "message": .string(String((error["message"]?.string ?? "").prefix(256)))]
      if let operation = try? error["operation"]?.decode(CollaborationOperationDiagnostic.self),
        (0..<512).contains(operation.index), (operation.id?.count ?? 0) <= 120 {
        detail["operation"] = try? .encode(operation)
      }
      result["error"] = .object(detail)
    }
    if effect.method == "undo" { result["actionID"] = effect.arguments["actionID"] }
    if effect.method == "transaction" { result["actionID"] = .string(effect.id.uuidString.lowercased()) }
    if effect.method == "export" { result["jobID"] = .string(effect.id.uuidString.lowercased()) }
    if effect.method == "present" { result["presentationID"] = .string(effect.id.uuidString.lowercased()) }
    if effect.method == "cancelPresentation" { result["presentationID"] = effect.arguments["id"] }
    if effect.method == "point" { result["contextID"] = effect.value?["id"]; result["entryID"] = effect.value?["entry"]?["id"] }
    return .object(result)
  }

  private func scriptEffectIndex(_ id: UUID) throws -> [JSONValue] {
    guard let value = try storedValue(scriptPrefix(id) + "effect-index.json"), case .array(let entries) = value,
      entries.count <= 128 else { throw NotebookStorageError.corruptRecord("script effect index") }
    let ids = entries.compactMap { $0["id"]?.string.flatMap(UUID.init(uuidString:)) }
    guard ids.count == entries.count, Set(ids).count == ids.count else { throw NotebookStorageError.corruptRecord("script effect identities") }
    return entries
  }

  public func unfinishedScriptEffectIDs(_ id: UUID) throws -> [UUID] {
    try readTransaction { _ in
      try scriptEffectIndex(id).filter { ["admitted", "committing", "outcomeUnknown"].contains($0["state"]?.string ?? "") }
        .compactMap { $0["id"]?.string.flatMap(UUID.init(uuidString:)) }
    }
  }

  public func scriptEffect(_ runID: UUID, id: UUID) throws -> NotebookScriptEffect {
    guard let effect = try storedValue(scriptPrefix(runID) + "effects/\(id.uuidString.lowercased()).json")?.decode(NotebookScriptEffect.self) else {
      throw NotebookStorageError.corruptRecord("script effect body")
    }
    return effect
  }

  public func admitScriptEffect(_ runID: UUID, key: String, method: String, arguments: JSONValue) throws -> NotebookScriptEffect {
    guard !key.isEmpty, key.utf8.count <= 120 else { throw CollaborationError("effect_key_required", "Изменение получает устойчивый key до 120 байт.") }
    return try commandTransaction(advancesReadRevision: false) {
      guard let run = try scriptRun(runID), run.state == .running else { throw CollaborationError("run_closed", "Программа не принимает новые изменения.") }
      let id = Self.submissionID(runID, suffix: "effect:" + key)
      let fingerprint = try collaborationHash(JSONValue.object(["method": .string(method), "arguments": arguments]))
      let file = scriptPrefix(runID) + "effects/\(id.uuidString.lowercased()).json"
      if let previous = try storedValue(file)?.decode(NotebookScriptEffect.self) {
        guard previous.fingerprint == fingerprint else { throw CollaborationError("effect_id_conflict", "Тот же key получил другой метод или аргументы.") }
        return previous
      }
      guard run.cancellationRequestedAt == nil else { throw Self.scriptCancellationError }
      var index = try scriptEffectIndex(runID)
      guard index.count < 128 else { throw CollaborationError("effect_limit", "Одна программа принимает до 128 отдельных изменений.") }
      let effect = NotebookScriptEffect(id: id, key: key, method: method, fingerprint: fingerprint, arguments: arguments, state: .admitted)
      index.append(Self.publicScriptEffect(effect))
      try publishRecords(writes: [file: try .encode(effect), scriptPrefix(runID) + "effect-index.json": .array(index),
        scriptEffectRecoveryFile(id): try .encode(NotebookScriptEffectAddress(runID: runID, effectID: id))])
      return effect
    }
  }

  public func saveScriptEffect(_ runID: UUID, effect: NotebookScriptEffect) throws {
    try commandTransaction(advancesReadRevision: false) {
      let file = scriptPrefix(runID) + "effects/\(effect.id.uuidString.lowercased()).json"
      guard let previous = try storedValue(file)?.decode(NotebookScriptEffect.self), previous.fingerprint == effect.fingerprint else {
        throw CollaborationError("effect_id_conflict", "Нельзя заменить идентичность принятого изменения.")
      }
      if previous.state == .saved || previous.state == .notSaved { return }
      var index = try scriptEffectIndex(runID)
      guard let offset = index.firstIndex(where: { $0["id"]?.string == effect.id.uuidString.lowercased() }) else {
        throw NotebookStorageError.corruptRecord("script effect admission")
      }
      index[offset] = Self.publicScriptEffect(effect)
      try publishRecords(writes: [file: try .encode(effect), scriptPrefix(runID) + "effect-index.json": .array(index)],
        removals: [.saved, .notSaved].contains(effect.state) ? [scriptEffectRecoveryFile(effect.id)] : [])
    }
  }

  public func scriptExportJob(_ id: UUID) throws -> JSONValue? {
    try readTransaction { _ in try storedValue("local/script-exports/\(id.uuidString.lowercased()).json") }
  }

  public func saveScriptExportJob(_ id: UUID, value: JSONValue) throws {
    try commandTransaction(advancesReadRevision: false) {
      if try scriptExportJob(id)?["status"] == .string("saved") { return }
      var active = try storedValue("local/script-export-active.json")?.decode([UUID].self) ?? []
      active.removeAll { $0 == id }
      if ["queued", "running"].contains(value["status"]?.string ?? "") { active.append(id) }
      guard active.count <= 2 else { throw CollaborationError("export_limit", "На Mac собираются до двух PDF.") }
      try publishRecords(writes: ["local/script-exports/\(id.uuidString.lowercased()).json": value])
      try publishRecords(writes: ["local/script-export-active.json": try .encode(active)])
    }
  }

  public func interruptUnfinishedScriptExports() throws {
    try commandTransaction(advancesReadRevision: false) {
      let active = try storedValue("local/script-export-active.json")?.decode([UUID].self) ?? []
      guard active.count <= 2 else { throw NotebookStorageError.corruptRecord("script export admission window") }
      for id in active {
        try saveScriptExportJob(id, value: .object(["status": .string("interrupted"),
          "jobID": .string(id.uuidString.lowercased()), "error": .object(["code": .string("owner_restarted"),
            "message": .string("The compiler did not publish a native receipt before restart. No automatic replay.")])]))
      }
    }
  }

  public func scriptPointReceipt(_ id: UUID) throws -> JSONValue? {
    try readTransaction { _ in
      guard let record = try storedValue("local/script-points/\(id.uuidString.lowercased()).json") else { return nil }
      guard let result = record["result"], case .object = result else {
        throw NotebookStorageError.corruptRecord("script point receipt")
      }
      return result
    }
  }

  public func appendScriptPoint(_ id: UUID, references: [CollaborationReference],
    contextID: UUID?, replyTo: UUID?, actor: UUID) throws -> JSONValue {
    try commandTransaction {
      let request = JSONValue.object(["references": try .encode(references),
        "contextID": try .encode(contextID), "replyTo": try .encode(replyTo)])
      let fingerprint = try collaborationHash(request)
      let file = "local/script-points/\(id.uuidString.lowercased()).json"
      if let previous = try storedValue(file) {
        guard previous["fingerprint"] == .string(fingerprint), let result = previous["result"] else {
          throw CollaborationError("effect_id_conflict", "Указание с этим ID уже имеет другой исходный запрос.")
        }
        return result
      }
      let result = try JSONValue.encode(appendContext(references: references, author: .agent,
        actor: actor, contextID: contextID, replyTo: replyTo))
      try publishRecords(writes: [file: .object(["fingerprint": .string(fingerprint), "result": result])])
      return result
    }
  }
}

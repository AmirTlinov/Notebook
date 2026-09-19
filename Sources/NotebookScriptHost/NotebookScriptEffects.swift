import Foundation
import NotebookCore

extension NotebookScriptCoordinator {
  func effect(runID: UUID, method: String, arguments args: JSONValue, trackedByHost: Bool = false) async throws -> JSONValue {
    // Count before the first await: admission may be durably accepted while
    // its reply is still in flight, before effectTasks can contain the task.
    if !trackedByHost { beginEffectCall() }
    defer { if !trackedByHost { endEffectCall() } }
    guard let key = args.string("key") else { throw CollaborationError("effect_key_required", "Каждое изменение получает устойчивый key.") }
    let admitted = try await persistence { try .encode($0.admitScriptEffect(runID, key: key, method: method, arguments: args)) }.decode(NotebookScriptEffect.self)
    if admitted.state == .saved { return admitted.value ?? .null }
    if admitted.state == .notSaved { throw Self.effectFailure(admitted) }
    if let task = effectTasks[admitted.id] { return try await task.value }
    if [.committing, .outcomeUnknown].contains(admitted.state) {
      let resolved = try await reconcileEffect(runID: runID, id: admitted.id)
      if resolved.state == .saved { return resolved.value ?? .null }
      throw Self.effectFailure(resolved)
    }
    if cancelled.contains(runID) || finishedWorkers.contains(runID) {
      let resolved = try await reconcileEffect(runID: runID, id: admitted.id, failure: .encode(NotebookStore.scriptCancellationError))
      if resolved.state == .saved { return resolved.value ?? .null }
      throw Self.effectFailure(resolved)
    }
    let task = Task<JSONValue, Error> { [self] in try await performEffect(runID: runID, effect: admitted) }
    effectTasks[admitted.id] = task
    do {
      let value = try await task.value
      effectTasks.removeValue(forKey: admitted.id); return value
    } catch {
      effectTasks.removeValue(forKey: admitted.id); throw error
    }
  }

  private func performEffect(runID: UUID, effect original: NotebookScriptEffect) async throws -> JSONValue {
    var effect = original
    do {
      let args = effect.arguments, id = effect.id
      var prepared: JSONValue?
      if effect.method == "transaction" {
        guard var fields = args["action"]?.fields, !fields.isEmpty else { throw CollaborationError("invalid_action", "Нужен исходный action.") }
        if let supplied = fields["id"], supplied != .string(id.uuidString.lowercased()) {
          throw CollaborationError("effect_id_owned", "ID хода принадлежит run_id и key; не задавайте action.id.")
        }
        fields["id"] = .string(id.uuidString.lowercased())
        fields["references"] = fields["references"] ?? .array([])
        guard fields["expected"] == nil, let supplied = fields.removeValue(forKey: "base") else {
          throw CollaborationError("basis_required", "SDK v2 принимает base из чтения, не вручную собранный expected.")
        }
        let bases: [NotebookReadBasis]
        if case .array = supplied { bases = try supplied.decode([NotebookReadBasis].self) }
        else { bases = [try supplied.decode(NotebookReadBasis.self)] }
        let base = try NotebookReadBasis.merging(bases)
        let operations = try (fields["operations"] ?? .null).decode([CollaborationOperation].self)
        fields["expected"] = try await persistence { try .encode($0.expectations(base: base, operations: operations)) }

        let admission = try await send(["command": .string("admitAction"), "action": .object(fields)])
        if admission.string("state") == "saved" {
          let recovered = try await reconcileEffect(runID: runID, id: id)
          guard recovered.state == .saved else {
            throw CollaborationError("receipt_unavailable", "Владелец подтвердил запись, но квитанция ещё не прочитана.")
          }
          return recovered.value ?? .null
        }
        guard let fingerprint = admission.string("fingerprint") else { throw CollaborationError("invalid_admission", "Нет исходной идентичности хода.") }
        let preparation = try await send(["command": .string("prepareAction"), "actionID": .string(id.uuidString), "fingerprint": .string(fingerprint)])
        // Distinct XPC service/queue: the user interpreter is awaiting this
        // effect, so normalization can never wait behind its user-run slot.
        let normalized = try await markup.normalize(.object(["kind": .string("action"), "preparation": preparation]))
        prepared = .object(["command": .string("commitAction"), "action": normalized, "fingerprint": .string(fingerprint)])
      }
      if effect.method == "point" {
        var references: [JSONValue] = []
        guard (1...32).contains(args.array("references").count) else { throw CollaborationError("invalid_reference", "Нужны от одной до 32 ссылок.") }
        for (index, value) in args.array("references").enumerated() {
          var reference = value.fields
          reference["id"] = reference["id"] ?? .string(NotebookStore.submissionID(id, suffix: "reference:\(index)").uuidString.lowercased())
          reference["label"] = reference["label"] ?? .string("")
          if reference["revision"] == nil {
            var request: [String: JSONValue] = ["command": .string("reference"), "target": reference["target"] ?? .null]
            request["elementID"] = reference["elementID"]
            reference["revision"] = try await send(request)["revision"]
          }
          references.append(.object(reference))
        }
        var request: [String: JSONValue] = ["command": .string("point"), "actionID": .string(id.uuidString), "references": .array(references)]
        request["contextID"] = args["contextID"]; request["replyTo"] = args["replyTo"]
        prepared = .object(request)
      }
      guard !cancelled.contains(runID), !finishedWorkers.contains(runID) else { throw CollaborationError("run_cancelled", "Подготовка завершилась после отмены; запись не принята.") }
      effect.state = .committing
      let committing = effect
      _ = try await persistence { try $0.saveScriptEffect(runID, effect: committing); return .null }
      // The journal reply is an await too: cancellation can win while that
      // reply is in flight, before the native queue has accepted a command.
      if cancelled.contains(runID) || finishedWorkers.contains(runID) {
        // Unlike a missing transient receipt, this is observed non-dispatch.
        // Persist that fact before throwing; no late response can reopen key.
        effect.state = .notSaved; effect.error = try .encode(NotebookStore.scriptCancellationError)
        let stopped = effect
        _ = try await persistence { try $0.saveScriptEffect(runID, effect: stopped); return .null }
        throw NotebookStore.scriptCancellationError
      }
      let result: JSONValue
      switch effect.method {
      case "transaction":
        guard let prepared else { throw CollaborationError("normalization_required", "Нет нормализованного хода.") }
        var request = prepared.fields
        request["scriptEffect"] = .object(["runID": .string(runID.uuidString), "effectID": .string(id.uuidString)])
        result = try await send(request)
      case "undo":
        guard let actionID = args["actionID"] else { throw CollaborationError("action_required", "Отмена называет исходный actionID.") }
        result = try await send(["command": .string("undo"), "actionID": actionID,
          "scriptEffect": .object(["runID": .string(runID.uuidString), "effectID": .string(id.uuidString)])])
      case "point":
        guard let prepared else { throw CollaborationError("invalid_reference", "Нет подготовленных ссылок.") }
        result = try await send(prepared.fields)
      case "present":
        let presentation = JSONValue.object(["id": .string(id.uuidString), "view": args["view"] ?? .null, "steps": args["steps"] ?? .null])
        result = try await send(["command": .string("presentation"), "actionID": .string(id.uuidString), "presentation": presentation])
      case "cancelPresentation":
        guard let presentationID = args["id"] else { throw CollaborationError("invalid_presentation", "Нужен ID показа.") }
        result = try await send(["command": .string("presentation"), "actionID": presentationID, "cancel": .bool(true)])
      case "export": result = try await startExport(id: id, arguments: args)
      case "cancelExport":
        guard let jobID = args.string("jobID").flatMap(UUID.init(uuidString:)) else { throw CollaborationError("invalid_export", "Нужен jobID.") }
        result = try await persistence { try $0.cancelScriptExport(jobID, effect: .init(runID: runID, effectID: id)) }
        if result.string("status") == "cancelled" { exportTasks[jobID]?.cancel() }
      default: throw CollaborationError("unknown_effect", "Неизвестное изменение.")
      }
      if ["transaction", "undo", "cancelExport"].contains(effect.method) { return result }
      effect.state = .saved; effect.value = result; effect.error = nil
      let saved = effect
      _ = try await persistence { try $0.saveScriptEffect(runID, effect: saved); return .null }
      return result
    } catch {
      // The native command has settled. This fence uses the same writer, so a
      // missing witness proves absence; read failure is a different outcome.
      // No list of validation error strings determines whether content saved.
      if let resolved = try? await reconcileEffect(runID: runID, id: effect.id, failure: Self.error(error)) {
        if resolved.state == .saved { return resolved.value ?? .null }
        throw Self.effectFailure(resolved)
      }
      // An unavailable writer leaves the durable unfinished record indexed.
      // Startup can reconcile it; no in-memory guess is recorded as notSaved.
      throw error
    }
  }

  func reconcileEffect(runID: UUID, id: UUID, failure: JSONValue? = nil) async throws -> NotebookScriptEffect {
    try await persistence { try .encode($0.reconcileScriptEffect(runID, id: id, failure: failure)) }.decode(NotebookScriptEffect.self)
  }

  private static func effectFailure(_ effect: NotebookScriptEffect) -> CollaborationError {
    if effect.state == .notSaved, let stored = effect.error, let error = try? stored.decode(CollaborationError.self) { return error }
    return CollaborationError(effect.state == .notSaved ? "effect_not_saved" : "effect_outcome_unknown",
      effect.state == .notSaved ? "Изменение не было сохранено; этот key не выполняется повторно."
        : "Окончательная квитанция недоступна; этот key не выполняется повторно.")
  }
}

extension JSONValue {
  var optionalValue: JSONValue? { self == .null ? nil : self }
}

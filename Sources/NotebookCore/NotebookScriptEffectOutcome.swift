import Foundation

/// These are statements about a durable witness, not classes of thrown errors.
/// Call through the sole writer after an accepted command has returned, or
/// during startup before accepting commands from a new interpreter.
public enum NotebookScriptEffectOutcome: Equatable, Sendable {
  case saved(JSONValue)
  case notSaved
  case unavailable
}

public struct NotebookScriptEffectAddress: Codable, Equatable, Sendable {
  public let runID: UUID
  public let effectID: UUID
  public init(runID: UUID, effectID: UUID) { self.runID = runID; self.effectID = effectID }
}

extension NotebookStore {
  func scriptEffectRecoveryFile(_ id: UUID) -> String {
    "local/script-effect-recovery/\(id.uuidString.lowercased()).json"
  }

  /// A separate local index keeps an uncertain effect recoverable even when
  /// its JavaScript run has completed or failed. Each read is one SQL page;
  /// historical run bodies and their potentially large arguments are not read.
  public func unfinishedScriptEffects(after: UUID? = nil, limit: Int = 64) throws -> [NotebookScriptEffectAddress] {
    try addressedValues(prefix: "local/script-effect-recovery/", after: after.map(scriptEffectRecoveryFile), limit: limit).map { file, value in
      let address = try value.decode(NotebookScriptEffectAddress.self)
      guard file == scriptEffectRecoveryFile(address.effectID) else {
        throw NotebookStorageError.corruptRecord("script effect recovery address")
      }
      return address
    }
  }

  /// Explicit attachment can repair the index of one older stopped run. The
  /// compact per-run index contains at most 128 IDs. A running/queued run may
  /// still have an accepted command in flight, so absence is not evidence yet.
  public func terminalScriptEffectsForRecovery(_ runID: UUID) throws -> [UUID] {
    try commandTransaction(advancesReadRevision: false) {
      guard let run = try scriptRun(runID) else { throw CollaborationError("run_missing", "Программа не найдена.") }
      guard run.isTerminal else { return [] }
      let ids = try unfinishedScriptEffectIDs(runID)
      var writes: [String: JSONValue] = [:]
      for id in ids {
        let address = NotebookScriptEffectAddress(runID: runID, effectID: id)
        let file = scriptEffectRecoveryFile(id)
        if let previous = try storedValue(file) {
          guard try previous.decode(NotebookScriptEffectAddress.self) == address else {
            throw NotebookStorageError.corruptRecord("script effect recovery identity")
          }
        } else { writes[file] = try .encode(address) }
      }
      if !writes.isEmpty { try publishRecords(writes: writes) }
      return ids
    }
  }

  public func scriptEffectOutcome(_ effect: NotebookScriptEffect) throws -> NotebookScriptEffectOutcome {
    try readTransaction { _ in
      switch effect.method {
      case "transaction":
        guard let receipt = try collaborationActionIfPresent(effect.id) else { return .notSaved }
        guard let result = try savedActionResult(receipt.id) else { return .unavailable }
        return .saved(result)
      case "point":
        guard let receipt = try scriptPointReceipt(effect.id) else { return .notSaved }
        return .saved(receipt)
      case "undo":
        guard let id = effect.arguments["actionID"]?.string.flatMap(UUID.init(uuidString:)),
          let receipt = try collaborationActionIfPresent(id), receipt.undo != nil else { return .notSaved }
        return .unavailable
      case "export":
        guard let job = try scriptExportJob(effect.id) else { return .notSaved }
        guard case .object = job, let status = job["status"]?.string,
          ["queued", "running", "saved", "failed", "interrupted", "cancelled"].contains(status),
          job["jobID"]?.string.flatMap(UUID.init(uuidString:)) == effect.id else {
          throw NotebookStorageError.corruptRecord("script export receipt")
        }
        // The effect admits a job. The compiler's later failure/interruption
        // does not erase that accepted job or run JavaScript a second time.
        return .saved(job)
      case "cancelExport":
        // Its receipt is atomic with the effect itself. Reconciliation has
        // already returned any terminal effect before consulting this method.
        return .notSaved
      default:
        // Presentation is transient. Absence from memory is not proof that
        // the iPad did not receive or display the previous command.
        return .unavailable
      }
    }
  }

  /// Reads the native witness and records its meaning in one writer cut.
  /// Storage/decode failures remain uncertain; they never become absence.
  public func reconcileScriptEffect(_ runID: UUID, id: UUID, failure: JSONValue? = nil) throws -> NotebookScriptEffect {
    try commandTransaction(advancesReadRevision: false) {
      var effect = try scriptEffect(runID, id: id)
      if effect.state == .saved || effect.state == .notSaved { return effect }
      let outcome: NotebookScriptEffectOutcome
      do { outcome = try scriptEffectOutcome(effect) }
      catch { outcome = .unavailable }
      switch outcome {
      case .saved(let value):
        effect.state = .saved; effect.value = value; effect.error = nil
      case .notSaved:
        effect.state = .notSaved; effect.value = nil
      case .unavailable:
        // No command can be dispatched until committing is durable. An
        // admitted effect interrupted during preparation never reached it.
        effect.state = effect.state == .admitted ? .notSaved : .outcomeUnknown
        effect.value = nil
      }
      if effect.state != .saved {
        effect.error = failure ?? effect.error ?? .object([
          "code": .string(effect.state == .notSaved ? "effect_not_saved" : "effect_outcome_unknown"),
          "message": .string(effect.state == .notSaved
            ? "Владелец подтвердил отсутствие записи; этот key не выполняется повторно."
            : "Нет доступной окончательной квитанции; этот key не выполняется повторно.")])
      }
      try saveScriptEffect(runID, effect: effect)
      return effect
    }
  }
}

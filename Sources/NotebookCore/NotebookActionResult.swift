import Foundation

extension NotebookLifecycleChange {
  var actionResultValue: JSONValue {
    get throws {
      guard target.kind == .cover, target.boardID != nil else {
        throw NotebookStorageError.corruptRecord("lifecycle result cover")
      }
      switch kind {
      case .appendPage:
        guard let pageID, let item = afterItem, item.id == target.id else {
          throw NotebookStorageError.corruptRecord("append page result")
        }
        return .object(["change": .string("appendPage"), "target": try .encode(target),
          "pageID": try .encode(pageID), "item": try .encode(item)])
      case .deleteItem:
        guard let item = beforeItem, item.id == target.id else {
          throw NotebookStorageError.corruptRecord("deleted item result")
        }
        return .object(["change": .string("deletedItem"), "target": try .encode(target), "item": try .encode(item)])
      }
    }
  }
}

extension NotebookLifecycleUndoChange {
  var actionResultValue: JSONValue {
    get throws {
      guard target.kind == .cover, target.boardID != nil, item == nil || item?.id == target.id else {
        throw NotebookStorageError.corruptRecord("lifecycle undo result cover")
      }
      var value: [String: JSONValue] = ["change": .string(kind.rawValue), "target": try .encode(target)]
      switch kind {
      case .restoreItem:
        guard let item else { throw NotebookStorageError.corruptRecord("restored item result") }
        value["item"] = try .encode(item)
      case .removePage:
        guard let pageID else { throw NotebookStorageError.corruptRecord("removed page result") }
        value["pageID"] = try .encode(pageID)
        if let item { value["item"] = try .encode(item) }
      }
      return .object(value)
    }
  }
}

/// Immutable commit evidence. It is written by the same physical writer and
/// transaction as content and its undo receipt, never reconstructed from a
/// later projection of the workspace.
extension NotebookStore {
  private func actionVersionPrefix(_ id: UUID, _ version: String) throws -> String {
    guard version.count == 64, version.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
      throw CollaborationError("invalid_action_version", "Нужна точная версия квитанции.")
    }
    return "local/action-results/\(id.uuidString.lowercased())/\(version)/"
  }

  func freezeActionResult(_ receipt: CollaborationReceipt, changed: [CollaborationFieldChange]) throws {
    let version = try receipt.deliveryVersion(), prefix = try actionVersionPrefix(receipt.id, version)
    if try hasStoredValue(prefix + "result.json") { return }
    let model = try NotebookActionReadModel(receipt)
    let basis = NotebookReadBasis(workspaceID: try workspaceHeader().workspaceID, owners: receipt.revisions)
    var values = try changed.map { field -> JSONValue in
      var value: [String: JSONValue] = ["file": .string(field.file), "path": try .encode(field.path),
        "change": .string(field.after == nil ? "deleted" : "updated"),
        "afterDigest": try NotebookActionReadModel.Field.digest(field.after, file: field.file, path: field.path).map(JSONValue.string) ?? .null]
      if let after = field.after {
        if try Self.storageEncoder.encode(after).count <= 2048 { value["value"] = after }
        else { value["valueOmitted"] = .bool(true) }
      }
      return .object(value)
    }
    if let undo = receipt.undo {
      values += try (undo.lifecycleChanges ?? []).map { try $0.actionResultValue }
    } else {
      values += try (receipt.lifecycleChanges ?? []).map { try $0.actionResultValue }
    }
    let next = values.count > 32 ? try actionResultCursor(receipt.id, version: version, offset: 32) : nil
    var result: [String: JSONValue] = ["actionID": try .encode(receipt.id), "actionVersion": .string(version),
      "summary": .string(receipt.summary), "basis": try .encode(basis),
      "publication": .object(["saved": .string("confirmed"), "receivedByIPad": .string("awaiting_device"),
        "shownOnIPad": .string(values.isEmpty && receipt.revisions.isEmpty ? "not_required" : "awaiting_display")]),
      "changed": .array(Array(values.prefix(32))), "changeCount": .number(Double(values.count))]
    result["next"] = next.map(JSONValue.string)
    if let undo = receipt.undo {
      result["undo"] = .object(["restored": .number(Double(undo.restored)),
        "preservedCount": .number(Double(undo.preserved.count + (undo.preservedLifecycle?.count ?? 0))),
        "completedAt": try .encode(undo.completedAt)])
    }
    var writes: [String: JSONValue] = [prefix + "result.json": .object(result), prefix + "model.json": try .encode(model)]
    for offset in stride(from: 32, to: values.count, by: 32) {
      writes[prefix + "changes-\(offset).json"] = .array(Array(values[offset..<min(offset + 32, values.count)]))
    }
    // An undo gets its own immutable version and cannot replace the original
    // result used by an interrupted transaction's recovery.
    if receipt.undo == nil {
      writes["local/action-results/\(receipt.id.uuidString.lowercased())/original.json"] = .string(version)
    }
    try publishRecords(writes: writes)
  }

  public func savedActionResult(_ id: UUID, version: String? = nil) throws -> JSONValue? {
    try readTransaction { _ in
      guard let version = try version ?? storedValue("local/action-results/\(id.uuidString.lowercased())/original.json")?.string else { return nil }
      return try storedValue(actionVersionPrefix(id, version) + "result.json")
    }
  }

  public func actionVersionModel(_ id: UUID, version: String) throws -> NotebookActionReadModel {
    guard let model = try storedValue(actionVersionPrefix(id, version) + "model.json") else {
      throw CollaborationError("action_version_unavailable", "Эта историческая версия квитанции не сохранена; новое состояние не подставляется.")
    }
    return try model.decode(NotebookActionReadModel.self)
  }

  private struct ResultCursor: Codable { let actionID: UUID; let actionVersion: String; let offset: Int }
  private func actionResultCursor(_ id: UUID, version: String, offset: Int) throws -> String {
    try Self.storageEncoder.encode(ResultCursor(actionID: id, actionVersion: version, offset: offset)).base64EncodedString()
  }
  public func actionResultPage(_ id: UUID, version: String, next: String) throws -> JSONValue {
    guard next.utf8.count < 1024, let bytes = Data(base64Encoded: next),
      let cursor = try? JSONDecoder().decode(ResultCursor.self, from: bytes), cursor.actionID == id, cursor.actionVersion == version,
      cursor.offset >= 32, cursor.offset % 32 == 0 else {
      throw CollaborationError("action_cursor_mismatch", "Продолжение принадлежит точной версии действия.")
    }
    return try readTransaction { _ in
      guard let result = try savedActionResult(id, version: version),
        let values = try storedValue(actionVersionPrefix(id, version) + "changes-\(cursor.offset).json") else {
        throw CollaborationError("action_version_unavailable", "Страница сохранённого результата недоступна.")
      }
      var page = result.object
      page["changed"] = values
      let total = try result["changeCount"]?.decode(Int.self) ?? 0
      page["next"] = total > cursor.offset + 32
        ? .string(try actionResultCursor(id, version: version, offset: cursor.offset + 32)) : nil
      return .object(page)
    }
  }

  func completeScriptAction(_ address: NotebookScriptEffectAddress?, receipt: CollaborationReceipt, method: String) throws -> JSONValue {
    let result: JSONValue
    if method == "transaction" {
      guard let original = try savedActionResult(receipt.id) else {
        throw CollaborationError("action_version_unavailable", "Исходный результат действия недоступен; версия отмены не подставляется.")
      }
      result = original
    } else {
      result = try scriptActionOutcome(receipt)
    }
    if let address {
      var effect = try scriptEffect(address.runID, id: address.effectID)
      guard effect.method == method, effect.state == .committing,
        method == "transaction" ? effect.id == receipt.id : effect.arguments["actionID"]?.string.flatMap(UUID.init(uuidString:)) == receipt.id else {
        throw CollaborationError("effect_id_conflict", "Квитанция не принадлежит допущенному эффекту.")
      }
      effect.state = .saved; effect.value = result; effect.error = nil
      try saveScriptEffect(address.runID, effect: effect)
    }
    return result
  }
}

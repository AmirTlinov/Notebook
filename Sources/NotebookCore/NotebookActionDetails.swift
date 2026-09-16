import Foundation

/// A receipt projection never repeats document bodies or field inverses.
/// The original receipt remains intact for native idempotency and undo.
public struct NotebookActionDetailsPage: Codable, Sendable {
  public enum Section: String, Codable, Sendable {
    case operations, revisions, changes, continuations, undo, snapshots
  }
  public var section: Section?
  public var offset: Int?
  public var limit: Int?
  public var after: UUID?
  public init(section: Section? = nil, offset: Int? = nil, limit: Int? = nil, after: UUID? = nil) {
    self.section = section; self.offset = offset; self.limit = limit; self.after = after
  }
}

extension NotebookStore {
  static func actionCompletion(_ receipt: CollaborationReceipt) -> JSONValue {
    .object(["id": .string(receipt.id.uuidString.lowercased()), "status": .string("saved"),
      "requestFingerprint": receipt.requestFingerprint.map(JSONValue.string) ?? .null,
      "undoComplete": .bool(receipt.undo != nil)])
  }

  public func scriptActionOutcome(_ receipt: CollaborationReceipt) throws -> JSONValue {
    .array([try actionDetails(receipt, page: nil, includeCurrentState: false)])
  }

  func actionDetails(_ receipt: CollaborationReceipt, page: NotebookActionDetailsPage?, includeCurrentState: Bool = true) throws -> JSONValue {
    try actionDetails(NotebookActionReadModel(receipt), page: page, includeCurrentState: includeCurrentState)
  }

  func actionDetails(_ receipt: NotebookActionReadModel, page: NotebookActionDetailsPage?, includeCurrentState: Bool = true) throws -> JSONValue {
    let offset = page?.offset ?? 0, limit = page?.limit ?? 32
    guard offset >= 0, (1...64).contains(limit) else {
      throw CollaborationError("invalid_cursor", "Раздел квитанции читается порциями от 1 до 64 записей, offset неотрицателен.")
    }
    let operations = try receipt.action.operations.map { operation -> JSONValue in
      var value: [String: JSONValue] = ["kind": .string(operation.kind.rawValue), "target": try .encode(operation.target)]
      value["id"] = operation.id.map(JSONValue.string)
      if let frame = operation.frame { value["frame"] = try .encode(frame) }
      return .object(value)
    }
    let revisions = try receipt.revisions.map(JSONValue.encode)
    let changes = try receipt.changes.map(Self.fieldAddress)
    let undo = try receipt.undo?.preserved.map(Self.fieldAddress) ?? []
    var projected: [String: JSONValue] = [
      "id": try .encode(receipt.id), "createdAt": try .encode(receipt.createdAt),
      "requestFingerprint": try .encode(receipt.requestFingerprint),
      "projection": .string("summary"), "changeCount": .number(Double(receipt.changes.count)),
      "action": .object(["summary": .string(receipt.summary), "contextID": try .encode(receipt.action.resolvedContextID),
        "references": try .encode(receipt.action.references), "operations": .array(Array(operations.prefix(limit)))]),
      "revisions": .array(Array(revisions.prefix(limit))), "changes": .array(Array(changes.prefix(limit))),
    ]
    if let value = receipt.undo {
      projected["undo"] = .object(["restored": .number(Double(value.restored)), "completedAt": try .encode(value.completedAt),
        "preserved": .array(Array(undo.prefix(limit))), "preservedCount": .number(Double(undo.count))])
    }
    func cursors(_ pages: [(NotebookActionDetailsPage.Section, [JSONValue])]) -> JSONValue {
      .object(Dictionary(uniqueKeysWithValues: pages.map { section, values in
        (section.rawValue, .object(["total": .number(Double(values.count)),
          "nextOffset": values.count > limit ? .number(Double(limit)) : .null]))
      }))
    }
    if !includeCurrentState {
      return .object(["receipt": .object(projected), "publication": .object(["saved": .string("confirmed")]),
        "pages": cursors([(.operations, operations), (.revisions, revisions), (.changes, changes), (.undo, undo)]),
        "readDetails": .object(["method": .string("action"), "args": .object(["actionID": try .encode(receipt.id)])])])
    }
    func continuations() throws -> [JSONValue] {
      try actionContinuations(receipt).map(JSONValue.encode)
    }
    func snapshots() throws -> [JSONValue] {
      try loadActionSnapshots(receipt).map { snapshot in .object([
        "requestID": try .encode(snapshot.request.id), "target": try .encode(snapshot.request.target),
        "sourceRevision": .string(snapshot.request.sourceRevision),
        "region": try .encode(snapshot.request.region), "pageIndex": try .encode(snapshot.request.pageIndex),
        "pngSHA256": try .encode(snapshot.pngSHA256), "diagnostics": try .encode(snapshot.diagnostics)]) }
    }
    func slice(_ values: [JSONValue], section: NotebookActionDetailsPage.Section, start: Int = 0) throws -> JSONValue {
      guard start <= values.count else { throw CollaborationError("invalid_cursor", "Offset находится за концом раздела квитанции.") }
      let end = min(values.count, start + limit)
      return .object(["section": .string(section.rawValue), "offset": .number(Double(start)),
        "total": .number(Double(values.count)), "nextOffset": end < values.count ? .number(Double(end)) : .null,
        "items": .array(Array(values[start..<end]))])
    }
    if let section = page?.section {
      let values: [JSONValue]
      switch section {
      case .operations: values = operations
      case .revisions: values = revisions
      case .changes: values = changes
      case .continuations: values = try continuations()
      case .undo: values = undo
      case .snapshots: values = try snapshots()
      }
      return .object(["actionID": try .encode(receipt.id), "page": try slice(values, section: section, start: offset)])
    }
    guard offset == 0 else { throw CollaborationError("invalid_cursor", "Для offset укажите section.") }
    let continued = try continuations(), rendered = try snapshots()
    let pages: [(NotebookActionDetailsPage.Section, [JSONValue])] = [
      (.operations, operations), (.revisions, revisions), (.changes, changes),
      (.continuations, continued), (.undo, undo), (.snapshots, rendered)]
    let delivery = try deviceActionReceipts(actionIDs: [receipt.id])
    let actionVersion = receipt.actionVersion
    projected["actionVersion"] = .string(actionVersion)
    let received = delivery.first.map { $0.matches(receipt) } ?? false
    let shown = received && (delivery.first?.displayComplete ?? false)
    // A saved effect without changed content creates no new pixels to display.
    // Its completion is distinct from a native installed-surface ACK. Ink may
    // have no field changes, so the actual revised targets must also be empty.
    let noVisualChangeReason: String?
    if let undo = receipt.undo {
      noVisualChangeReason = undo.restored == 0 && receipt.revisions.isEmpty ? "undo_without_visual_changes" : nil
    } else {
      noVisualChangeReason = receipt.changes.isEmpty && receipt.revisions.isEmpty ? "action_without_visual_changes" : nil
    }
    var publication: [String: JSONValue] = [
      "saved": .string("confirmed"),
      "receivedByIPad": .string(received ? "confirmed" : "awaiting_device"),
      "shownOnIPad": .string(noVisualChangeReason != nil ? "not_required" : shown ? "confirmed" : "awaiting_display")]
    if let noVisualChangeReason { publication["shownOnIPadReason"] = .string(noVisualChangeReason) }
    return .object(["receipt": .object(projected), "continuations": .array(Array(continued.prefix(limit))),
      "delivery": .array(try delivery.map { value in .object([
        "id": try .encode(value.id), "deviceID": try .encode(value.deviceID), "receivedAt": try .encode(value.receivedAt),
        "actionVersion": try .encode(value.actionVersion), "sameActionVersion": .bool(value.matches(receipt)),
        "sameRevisions": .bool(value.revisions == receipt.revisions), "displayComplete": .bool(value.displayComplete),
        "visibleRegions": try .encode(value.visibleRegions)]) }),
      "snapshots": .array(Array(rendered.prefix(limit))),
      "pages": cursors(pages),
      "publication": .object(publication),
      "snapshotCoverage": .string("matching receipts in the latest 80 native render requests")])
  }

  private static func fieldAddress(_ change: NotebookActionReadModel.Field) throws -> JSONValue {
    .object(["file": .string(change.file), "path": try .encode(change.path)])
  }
}

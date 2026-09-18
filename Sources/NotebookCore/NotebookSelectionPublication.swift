import Foundation

/// A serialization of the native selection owner, never a command or permission.
public struct NotebookSelection: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable { case empty, item, element, elements, context, reference }
  public let id: UUID
  public let kind: Kind
  public let surface: CollaborationTarget
  public var pageIndex: Int?
  public var target: CollaborationTarget?
  public var elementID: String?
  public var elementIDs: [String]?
  public var itemID: UUID?
  public var contextID: UUID?
  public var reference: CollaborationReference?
  public var resolving: Bool

  public init(id: UUID, kind: Kind, surface: CollaborationTarget, pageIndex: Int? = nil,
    target: CollaborationTarget? = nil, elementID: String? = nil, itemID: UUID? = nil,
    elementIDs: [String]? = nil, contextID: UUID? = nil, reference: CollaborationReference? = nil, resolving: Bool = false) {
    self.id = id; self.kind = kind; self.surface = surface; self.pageIndex = pageIndex
    self.target = target; self.elementID = elementID; self.itemID = itemID
    self.elementIDs = elementIDs; self.contextID = contextID; self.reference = reference; self.resolving = resolving
  }

  public var isValid: Bool {
    func validTarget(_ value: CollaborationTarget) -> Bool {
      value.kind != .workspace && ((value.kind == .cover) == (value.boardID != nil))
    }
    guard [.board, .cover, .page, .document].contains(surface.kind), validTarget(surface), target.map(validTarget) ?? true,
      pageIndex.map({ surface.kind == .document && (0...100_000).contains($0) }) ?? true,
      elementID.map({ !$0.isEmpty && $0.utf16.count <= 120 }) ?? true else { return false }
    guard kind == .elements || elementIDs == nil else { return false }
    switch kind {
    case .empty: return target == nil && elementID == nil && itemID == nil && reference == nil && contextID == nil && !resolving
    case .item: return itemID != nil && surface.kind == .board && target == nil && elementID == nil && reference == nil
    case .element: return target.map { [.page, .board, .cover].contains($0.kind) } == true && elementID != nil && itemID == nil && reference == nil
    case .elements:
      return target.map { [.page,.board,.cover].contains($0.kind) } == true && elementID == nil && itemID == nil && reference == nil
        && elementIDs.map { (2...32).contains($0.count) && Set($0).count == $0.count && $0.allSatisfy { !$0.isEmpty && $0.utf16.count <= 120 } } == true
    case .context: return (contextID != nil || resolving) && target == nil && elementID == nil && itemID == nil && reference == nil
    case .reference:
      return reference.map {
        validTarget($0.target) && !$0.revision.isEmpty && $0.revision.utf8.count <= 256 && $0.label.count <= 1000
          && ($0.elementID?.utf8.count ?? 0) <= 512 && ($0.pageIndex ?? 0) >= 0 && $0.worldOrigin?.isValid != false
          && $0.region.map { $0.x.isFinite && $0.y.isFinite && $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 } != false
      } == true
        && target == nil && elementID == nil && itemID == nil
    }
  }
}

/// One replaceable transient slot. A process restart changes sessionID;
/// sequence advances for semantic selection/surface changes, not camera frames.
public struct NotebookSelectionEnvelope: Codable, Equatable, Sendable {
  public let deviceID: UUID
  public let sessionID: UUID
  public let sequence: UInt64
  public let selection: NotebookSelection?
  public init(deviceID: UUID, sessionID: UUID, sequence: UInt64, selection: NotebookSelection?) {
    self.deviceID = deviceID; self.sessionID = sessionID; self.sequence = sequence; self.selection = selection
  }
  public var isValid: Bool { sequence > 0 && sequence <= VersionStamp.maximumCounter && (selection?.isValid ?? true) }
}

public struct NotebookSelectionSnapshot: Codable, Equatable, Sendable {
  public let status: String
  public let deviceID: UUID?
  public let sessionID: UUID?
  public let generation: UInt64?
  public let selection: NotebookSelection?
}

private struct SelectionConnection: Codable {
  let deviceID: UUID
  let connectionID: UUID
  var publication: NotebookSelectionEnvelope?
  var presence: PresenceEnvelope?
}

extension NotebookStore {
  private func selectionConnection() throws -> SelectionConnection? {
    guard let value = try storedValue("runtime/selection.json"), value != .null else { return nil }
    return try value.decode(SelectionConnection.self)
  }

  public func readSelectionPublication() throws -> NotebookSelectionSnapshot {
    try readTransaction { _ in
      let connection = try selectionConnection()
      let publication = try connection == nil
        ? storedValue("runtime/local-selection.json").flatMap { $0 == .null ? nil : try $0.decode(NotebookSelectionEnvelope.self) }
        : connection?.publication
      return .init(status: publication?.selection == nil ? "unknown" : "known", deviceID: publication?.deviceID,
        sessionID: publication?.sessionID, generation: publication?.sequence, selection: publication?.selection)
    }
  }

  /// Local navigation stays in last-context.json. The authenticated peer's
  /// published context is a separate read model, never the Mac window camera.
  public func readObservedPresenceIfAvailable() throws -> SessionPresence? {
    try readTransaction { _ in
      if let connection = try selectionConnection() { return connection.presence?.presence }
      return try readPresenceIfAvailable()
    }
  }

  public func saveLocalSelectionPublication(_ publication: NotebookSelectionEnvelope) throws {
    guard publication.isValid else { throw NotebookStorageError.invalidTransaction("local selection") }
    try prepare()
    try commandTransaction(advancesReadRevision: false) {
      try publishRecords(writes: ["runtime/local-selection.json": try .encode(publication)])
    }
  }

  @discardableResult
  public func acceptPresencePublication(_ envelope: PresenceEnvelope, deviceID: UUID, connectionID: UUID) throws -> Bool {
    guard envelope.isValid, envelope.phase == .settled else {
      throw NotebookStorageError.invalidTransaction("settled peer presence")
    }
    try prepare()
    return try commandTransaction(advancesReadRevision: false) {
      guard var active = try selectionConnection(), active.deviceID == deviceID,
        active.connectionID == connectionID else { return false }
      if let previous = active.presence {
        guard previous.sessionID == envelope.sessionID, previous.sequence < envelope.sequence else { return false }
      }
      active.presence = envelope
      try publishRecords(writes: ["runtime/selection.json": try .encode(active)])
      try advancePresenceGeneration()
      return true
    }
  }

  /// Invoked by the same writer as authenticated connect/disconnect callbacks.
  public func beginSelectionPublication(deviceID: UUID, connectionID: UUID) throws {
    try prepare()
    try commandTransaction(advancesReadRevision: false) {
      if let old = try selectionConnection(), old.deviceID == deviceID, old.connectionID == connectionID { return }
      try publishRecords(writes: ["runtime/selection.json": try .encode(SelectionConnection(deviceID: deviceID, connectionID: connectionID))])
      try advancePresenceGeneration()
    }
  }

  @discardableResult
  public func acceptSelectionPublication(_ value: NotebookSelectionEnvelope, connectionID: UUID) throws -> Bool {
    guard value.isValid else { throw CollaborationError("invalid_selection", "Выделение требует точного физического адреса и поколения сессии.") }
    try prepare()
    return try commandTransaction(advancesReadRevision: false) {
      guard var active = try selectionConnection(), active.deviceID == value.deviceID, active.connectionID == connectionID else { return false }
      if let previous = active.publication {
        // A new process must first establish a new authenticated connection.
        guard previous.sessionID == value.sessionID, previous.sequence < value.sequence else { return false }
      }
      active.publication = value
      try publishRecords(writes: ["runtime/selection.json": try .encode(active)])
      return true
    }
  }

  public func endSelectionPublication(deviceID: UUID, connectionID: UUID) throws {
    try prepare()
    try commandTransaction(advancesReadRevision: false) {
      guard let active = try selectionConnection(), active.deviceID == deviceID, active.connectionID == connectionID else { return }
      try publishRecords(writes: ["runtime/selection.json": .null])
      try advancePresenceGeneration()
    }
  }

  public func resetSelectionPublication() throws {
    try prepare()
    try commandTransaction(advancesReadRevision: false) {
      try publishRecords(writes: ["runtime/selection.json": .null, "runtime/local-selection.json": .null])
      try advancePresenceGeneration()
    }
  }
}

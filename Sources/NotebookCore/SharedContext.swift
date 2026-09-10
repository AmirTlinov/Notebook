import Foundation

/// A context records what was considered; content continues to belong to its physical owner.
public struct SharedContext: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public private(set) var entries: [SharedContextEntry]

  public init(id: UUID = UUID(), entries: [SharedContextEntry] = []) {
    self.id = id
    self.entries = entries
  }

  public mutating func merge(_ other: Self) throws {
    guard id == other.id else { throw CollaborationError("context_mismatch", "Указания принадлежат разным контекстам.") }
    try validate()
    guard Set(other.entries.map(\.id)).count == other.entries.count else {
      throw CollaborationError("context_entry_conflict", "Указания имеют устойчивые уникальные ID.")
    }
    var byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
    for entry in other.entries {
      if let previous = byID[entry.id], previous != entry {
        throw CollaborationError("context_entry_conflict", "ID указания уже принадлежит другому содержанию.")
      }
      byID[entry.id] = entry
    }
    let merged = Self(id: id, entries: byID.values.sorted {
      $0.stamp == $1.stamp ? $0.id.uuidString < $1.id.uuidString : $0.stamp < $1.stamp
    })
    // A rejected packet cannot replace the accepted history with an orphan or
    // invalid entry. Partial replies may still address the existing context.
    try merged.validate()
    entries = merged.entries
  }

  public func validate() throws {
    var counters: [UUID: UInt64] = [:]
    counters.reserveCapacity(entries.count)
    for entry in entries {
      guard entry.stamp.counter <= VersionStamp.maximumCounter else {
        throw CollaborationError("invalid_context_clock", "Версия указания выходит за предел точного причинного счётчика.")
      }
      guard counters.updateValue(entry.stamp.counter, forKey: entry.id) == nil else {
        throw CollaborationError("context_entry_conflict", "Указания имеют устойчивые уникальные ID.")
      }
    }
    for entry in entries {
      try entry.validate(sourceCounter: entry.replyTo.flatMap { counters[$0] })
    }
  }
}

public struct SharedContextEntry: Codable, Equatable, Sendable, Identifiable {
  public enum Author: String, Codable, Sendable { case human, agent }
  public let id: UUID
  public let author: Author
  public let references: [CollaborationReference]
  public let text: String?
  public let replyTo: UUID?
  public let stamp: VersionStamp
  public let requiresReview: Bool
  public let createdAt: Date

  public init(id: UUID = UUID(), author: Author, references: [CollaborationReference],
    replyTo: UUID? = nil, text: String? = nil, stamp: VersionStamp, requiresReview: Bool = false, createdAt: Date = Date()) {
    self.id = id; self.author = author; self.references = references
    self.replyTo = replyTo; self.text = text; self.stamp = stamp; self.requiresReview = requiresReview; self.createdAt = createdAt
  }

  func validate(sourceCounter: UInt64?) throws {
    guard stamp.counter <= VersionStamp.maximumCounter else {
      throw CollaborationError("invalid_context_clock", "Версия указания выходит за предел точного причинного счётчика.")
    }
    guard (text?.utf8.count ?? 0) <= 1_048_576,
      !references.isEmpty || !(text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
      references.count <= 32, references.allSatisfy({ $0.label.count <= 1000 }),
      Set(references.map(\.id)).count == references.count else {
      throw CollaborationError("invalid_reference", "Указание содержит до 32 уникальных фрагментов.")
    }
    if replyTo != nil {
      guard let sourceCounter, sourceCounter < stamp.counter else {
        throw CollaborationError("source_missing", "Ответ называет ранее рассмотренное указание этого контекста.")
      }
    }
  }

}

/// Selection changes attention, never the address of an already started action.
public struct SharedContextSelection: Codable, Equatable, Sendable {
  public let contextID: UUID?
  public let stamp: VersionStamp
  public init(contextID: UUID?, stamp: VersionStamp) { self.contextID = contextID; self.stamp = stamp }
}

public struct SharedContextSnapshot: Codable, Equatable, Sendable {
  public let contexts: [SharedContext]
  public let selection: SharedContextSelection?
  public init(contexts: [SharedContext] = [], selection: SharedContextSelection? = nil) {
    self.contexts = contexts; self.selection = selection
  }
}

extension NotebookStore {
  func contextFile(_ id: UUID) -> String { "collaboration/contexts/\(id.uuidString.lowercased()).json" }

  func readSharedContexts() throws -> [SharedContext] {
    try storedValues(prefix: "collaboration/contexts/").map {
      let context = try $0.decode(SharedContext.self)
      try context.validate(); return context
    }
  }

  func readContextSelection() throws -> SharedContextSelection? {
    try storedValue("collaboration/selection.json")?.decode(SharedContextSelection.self)
  }

  public func sharedContexts() throws -> SharedContextSnapshot {
    try prepare()
    return try readTransaction { _ in .init(contexts: try readSharedContexts(), selection: try readContextSelection()) }
  }

  func contextWrites(_ incoming: [SharedContext], selection: SharedContextSelection?) throws -> [String: JSONValue] {
    var stored: [UUID: SharedContext] = [:]
    let ids = Set(incoming.map(\.id)).union(selection?.contextID.map { [$0] } ?? [])
    for id in ids { stored[id] = try storedValue(contextFile(id))?.decode(SharedContext.self) }
    var writes: [String: JSONValue] = [:]
    for context in incoming {
      try context.validate()
      var merged = stored[context.id] ?? .init(id: context.id)
      try merged.merge(context)
      if merged != stored[context.id] { writes[contextFile(context.id)] = try .encode(merged) }
      stored[context.id] = merged
    }
    if let selection, try readContextSelection().map({ $0.stamp < selection.stamp }) ?? true {
      guard selection.contextID == nil || stored[selection.contextID!] != nil else {
        throw CollaborationError("context_missing", "Выбранный контекст ещё не получен.")
      }
      writes["collaboration/selection.json"] = try .encode(selection)
    }
    return writes
  }

  @discardableResult
  public func appendContext(references: [CollaborationReference], author: SharedContextEntry.Author,
    actor: UUID, contextID: UUID? = nil, replyTo: UUID? = nil, text: String? = nil, select: Bool = false,
    sourceWorkspaceID: UUID? = nil) throws -> SharedContextAppend {
    try prepare()
    return try withMutationLock {
      // A newly captured native context seals its exact sources in this write
      // transaction. Imported/historical context entries keep their own cut.
      if let sourceWorkspaceID {
        guard try workspaceHeader().workspaceID == sourceWorkspaceID else {
          throw CollaborationError("capture_source_changed", "Рабочее пространство указания изменилось.")
        }
        for reference in references {
          guard try referenceRevision(target: reference.target, elementID: reference.elementID) == reference.revision else {
            throw CollaborationError("capture_source_changed", "Источник указания изменился до сохранения. Укажите фрагмент снова.")
          }
        }
      }
      let id = contextID ?? UUID(), file = contextFile(id), root = contextFile(id) + "#"
      let database = currentSQL!
      let parent: SharedContextEntry?
      if contextID != nil {
        guard try hasStoredValue(file) else { throw CollaborationError("context_missing", "Общий фрагмент не найден.") }
        guard let replyTo else { throw CollaborationError("source_required", "Продолжение называет исходное указание.") }
        parent = try sharedContextEntry(contextID: id, entryID: replyTo)
        guard parent != nil else { throw CollaborationError("source_missing", "Исходное указание отсутствует в этом контексте.") }
      } else {
        guard replyTo == nil else { throw CollaborationError("context_required", "Для ответа нужен контекст.") }
        parent = nil
      }
      try requireContextOrderIndex()
      let last = try database.rows("SELECT counter FROM context_entry_order WHERE context=? ORDER BY counter DESC,actor DESC,address DESC LIMIT 1", [.text(root)]).first
      let counter = max(parent?.stamp.counter ?? 0, UInt64(last?[0].integer ?? 0))
      guard let stamp = VersionStamp(counter: counter, actor: actor).advanced(by: actor) else {
        throw CollaborationError("version_exhausted", "Версия указания достигла предела.")
      }
      let entry = SharedContextEntry(author: author, references: references, replyTo: replyTo, text: text, stamp: stamp)
      try entry.validate(sourceCounter: parent?.stamp.counter)
      if contextID == nil {
        let header = try NotebookRecordCodec.encode(.encode(SharedContext(id: id)), file: file).first!
        try writeFragment(header, database: database)
      }
      try writeFragment(.init(address: root + "/entries/@" + entry.id.uuidString.lowercased(), file: file,
        parent: root, collection: "entries", member: entry.id.uuidString.lowercased(),
        position: 0, value: .encode(entry), collections: []), database: database)
      if select {
        try publishCollaboration(writes: ["collaboration/selection.json": .encode(nextContextSelection(id, actor: actor))])
      }
      return .init(id: id, entry: entry)
    }
  }

  func nextContextSelection(_ id: UUID?, actor: UUID) throws -> SharedContextSelection {
    let previous = try readContextSelection()?.stamp ?? .init(counter: 0, actor: actor)
    guard let stamp = previous.advanced(by: actor) else { throw CollaborationError("version_exhausted", "Версия выбора достигла предела.") }
    return .init(contextID: id, stamp: stamp)
  }

  public func selectSharedContext(_ id: UUID?, actor: UUID) throws {
    try prepare()
    try withMutationLock {
      guard try id == nil || hasStoredValue(contextFile(id!)) else {
        throw CollaborationError("context_missing", "Выбранный контекст ещё не получен.")
      }
      try publishCollaboration(writes: ["collaboration/selection.json": .encode(nextContextSelection(id, actor: actor))])
    }
  }
}

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
    var byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
    for entry in other.entries {
      if let previous = byID[entry.id], previous != entry {
        throw CollaborationError("context_entry_conflict", "ID указания уже принадлежит другому содержанию.")
      }
      byID[entry.id] = entry
    }
    entries = byID.values.sorted { $0.stamp == $1.stamp ? $0.id.uuidString < $1.id.uuidString : $0.stamp < $1.stamp }
    try validate()
  }

  public func validate() throws {
    guard Set(entries.map(\.id)).count == entries.count else {
      throw CollaborationError("context_entry_conflict", "Указания имеют устойчивые уникальные ID.")
    }
    for entry in entries {
      guard entry.references.count <= 32, entry.references.allSatisfy({ $0.label.count <= 1000 }),
        Set(entry.references.map(\.id)).count == entry.references.count else {
        throw CollaborationError("invalid_reference", "Указание содержит до 32 уникальных фрагментов.")
      }
      if let reply = entry.replyTo {
        guard let source = entries.first(where: { $0.id == reply }), source.stamp.counter < entry.stamp.counter else {
          throw CollaborationError("source_missing", "Ответ называет ранее рассмотренное указание этого контекста.")
        }
      }
    }
  }
}

public struct SharedContextEntry: Codable, Equatable, Sendable, Identifiable {
  public enum Author: String, Codable, Sendable { case human, agent }
  public let id: UUID
  public let author: Author
  public let references: [CollaborationReference]
  public let replyTo: UUID?
  public let stamp: VersionStamp
  public let requiresReview: Bool
  public let createdAt: Date

  public init(id: UUID = UUID(), author: Author, references: [CollaborationReference],
    replyTo: UUID? = nil, stamp: VersionStamp, requiresReview: Bool = false, createdAt: Date = Date()) {
    self.id = id; self.author = author; self.references = references
    self.replyTo = replyTo; self.stamp = stamp; self.requiresReview = requiresReview; self.createdAt = createdAt
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
    let directory = collaborationURL.appendingPathComponent("contexts", isDirectory: true)
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
       .map {
        let context = try JSONDecoder().decode(SharedContext.self, from: Data(contentsOf: $0))
        try context.validate()
        return context
      }
  }

  func readContextSelection() throws -> SharedContextSelection? {
    let url = collaborationURL.appendingPathComponent("selection.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try JSONDecoder().decode(SharedContextSelection.self, from: Data(contentsOf: url))
  }

  public func sharedContexts() throws -> SharedContextSnapshot {
    try prepare()
    return try withMutationLock { .init(contexts: try readSharedContexts(), selection: try readContextSelection()) }
  }

  func contextWrites(_ incoming: [SharedContext], selection: SharedContextSelection?) throws -> [String: JSONValue] {
    var stored = Dictionary(uniqueKeysWithValues: try readSharedContexts().map { ($0.id, $0) })
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
    actor: UUID, contextID: UUID? = nil, replyTo: UUID? = nil, select: Bool = false) throws -> SharedContext {
    try prepare()
    return try withMutationLock {
      let contexts = try readSharedContexts()
      var context: SharedContext
      if let contextID {
        guard let existing = contexts.first(where: { $0.id == contextID }) else {
          throw CollaborationError("context_missing", "Общий фрагмент не найден.")
        }
        guard replyTo != nil else { throw CollaborationError("source_required", "Продолжение называет исходное указание.") }
        context = existing
      } else {
        guard replyTo == nil else { throw CollaborationError("context_required", "Для ответа нужен контекст.") }
        context = .init()
      }
      guard !references.isEmpty else { throw CollaborationError("invalid_reference", "Укажите хотя бы один фрагмент.") }
      let previous = context.entries.map(\.stamp.counter).max() ?? 0
      guard let stamp = VersionStamp(counter: previous, actor: actor).advanced(by: actor) else {
        throw CollaborationError("version_exhausted", "Версия указания достигла предела.")
      }
      let entry = SharedContextEntry(author: author, references: references, replyTo: replyTo, stamp: stamp)
      try context.merge(.init(id: context.id, entries: [entry]))
      let selection = select ? try nextContextSelection(context.id, actor: actor) : nil
      try publishCollaboration(writes: contextWrites([context], selection: selection))
      return context
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
      try publishCollaboration(writes: contextWrites([], selection: nextContextSelection(id, actor: actor)))
    }
  }
}

extension NotebookStore {
  func migrateSharedContexts() throws {
    try prepare()
    try withMutationLock {
      let marker = collaborationURL.appendingPathComponent("format.json")
      let format = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: marker))["format"]
      if format == .number(2) { return }
      guard format == .number(1) else { throw CollaborationError("unsupported_format", "Обновите согласованную пару Notebook.") }
      let backup = root.appendingPathComponent("migrations/before-collaboration-v2", isDirectory: true)
      var paths = ["workspace.json", "board.json", "spatial-ink.json", "last-context.json"]
      for folder in ["pages", "documents", "document-states", "collaboration"] {
        let directory = root.appendingPathComponent(folder)
        if FileManager.default.fileExists(atPath: directory.path) {
          for relative in try FileManager.default.subpathsOfDirectory(atPath: directory.path) {
            var isDirectory: ObjCBool = false
            let source = directory.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue {
              paths.append(folder + "/" + relative)
            }
          }
        }
      }
      for path in paths where FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) {
        let destination = backup.appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: destination.path) { continue }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contentsOf: root.appendingPathComponent(path)).write(to: destination, options: .atomic)
      }
      var writes: [String: JSONValue] = [:]
      for receipt in try loadMigrationActions() {
        let entry = SharedContextEntry(id: receipt.id, author: .agent, references: receipt.action.references,
          stamp: .init(counter: 1, actor: receipt.id), requiresReview: true, createdAt: receipt.createdAt)
        writes[contextFile(receipt.action.resolvedContextID)] = try .encode(SharedContext(id: receipt.action.resolvedContextID, entries: [entry]))
      }
      struct PreviousAttention: Decodable {
        let author: SharedContextEntry.Author
        let reference: CollaborationReference?
        let stamp: VersionStamp
      }
      var removals: [String] = []
      for author in ["human", "agent"] {
        let path = "collaboration/attention-\(author).json"
        let url = root.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else { continue }
        let previous = try JSONDecoder().decode(PreviousAttention.self, from: Data(contentsOf: url))
        if let reference = previous.reference {
          let entry = SharedContextEntry(id: reference.id, author: previous.author, references: [reference],
            stamp: previous.stamp, requiresReview: true, createdAt: .distantPast)
          writes[contextFile(reference.id)] = try .encode(SharedContext(id: reference.id, entries: [entry]))
          if previous.author == .human {
            writes["collaboration/selection.json"] = try .encode(SharedContextSelection(contextID: reference.id, stamp: previous.stamp))
          }
        }
        removals.append(path)
      }
      writes["collaboration/format.json"] = .object(["format": .number(2), "backup": .string("migrations/before-collaboration-v2")])
      try publishCollaboration(writes: writes, removals: removals)
    }
  }

  private func loadMigrationActions() throws -> [CollaborationReceipt] {
    guard FileManager.default.fileExists(atPath: collaborationActionsURL.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(at: collaborationActionsURL, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(CollaborationReceipt.self, from: Data(contentsOf: $0)) }
  }
}

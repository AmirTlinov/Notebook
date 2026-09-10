import Foundation

/// An append acknowledges exactly the new immutable entry, not an unbounded history.
public struct SharedContextAppend: Codable, Equatable, Sendable {
  public let id: UUID
  public let entry: SharedContextEntry
}

/// Directory previews are not canonical SharedContext values and cannot be merged.
public struct SharedContextSummary: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let firstEntry: SharedContextEntry?
  public let lastEntry: SharedContextEntry?
  public var previewEntries: [SharedContextEntry] {
    guard let firstEntry else { return [] }
    return lastEntry.map { $0.id == firstEntry.id ? [firstEntry] : [firstEntry, $0] } ?? [firstEntry]
  }
}

public struct SharedContextDirectory: Codable, Equatable, Sendable {
  public let contexts: [SharedContextSummary]
  public let selection: SharedContextSelection?
  public let selectedContext: SharedContextSummary?
  public let nextContextID: UUID?
  public let readCursor: String
}

/// The cursor belongs to this history, not unrelated camera or document writes.
/// A changed history refuses continuation rather than skipping a reordered reply.
public struct SharedContextPage: Codable, Equatable, Sendable {
  public let id: UUID
  public let entries: [SharedContextEntry]
  public let nextEntryID: UUID?
  public let readCursor: String
}

extension NotebookStore {
  func storedEntry(at address: String) throws -> SharedContextEntry? {
    guard let row = try currentSQL!.rows("SELECT r.hash,length(b.data) FROM records r JOIN blobs b ON b.hash=r.hash WHERE r.address=?", [.text(address)]).first else { return nil }
    guard let bytes = row[1].integer, bytes <= 2_097_152 else { throw NotebookStorageError.limitExceeded("context_entry") }
    let fragment = try JSONDecoder().decode(NotebookStoredFragment.self, from: currentSQL!.blob(row[0].text!))
    guard fragment.address == address, fragment.collections.isEmpty,
      fragment.collection == "entries", fragment.parent == fragment.file + "#" else { throw NotebookStorageError.corruptRecord(address) }
    let entry = try fragment.value.decode(SharedContextEntry.self)
    guard fragment.member == entry.id.uuidString.lowercased(),
      address == fragment.file + "#/entries/@" + fragment.member else { throw NotebookStorageError.corruptRecord(address) }
    return entry
  }

  public func sharedContextEntry(contextID: UUID, entryID: UUID) throws -> SharedContextEntry? {
    try readTransaction { _ in
      guard let entry = try storedEntry(at: contextFile(contextID) + "#/entries/@" + entryID.uuidString.lowercased()) else { return nil }
      let source = try entry.replyTo.flatMap { try storedEntry(at: contextFile(contextID) + "#/entries/@" + $0.uuidString.lowercased()) }
      try entry.validate(sourceCounter: source?.stamp.counter)
      return entry
    }
  }

  /// Revision indexes change in the same transaction as every physical history
  /// write, including replication and removal. No entry body is read to advance them.
  func noteContextHistoryChange(file: String, database: NotebookSQLConnection) throws {
    guard file.hasPrefix("collaboration/contexts/") else { return }
    let revision = try currentReadCursor()
    guard revision < UInt64(Int64.max) else { throw NotebookStorageError.limitExceeded("read_revision") }
    for key in ["context_history_revision", "context_history_revision:" + file] {
      try database.run("INSERT INTO metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value WHERE value!=excluded.value",
        [.text(key), .text(String(revision + 1))])
    }
  }

  private func contextReadCursor(_ expected: String?, file: String? = nil) throws -> String {
    let key = "context_history_revision" + (file.map { ":" + $0 } ?? "")
    let current = try currentSQL!.rows("SELECT value FROM metadata WHERE key=?", [.text(key)]).first?[0].text ?? "0"
    guard expected == nil || expected == current else { throw NotebookStorageError.transactionConflict }
    return current
  }

  public func sharedContextPage(contextID: UUID, afterEntryID: UUID? = nil,
    expectedCursor: String? = nil, limit: Int = 32) throws -> SharedContextPage {
    guard (1...64).contains(limit), afterEntryID == nil || expectedCursor != nil else { throw NotebookStorageError.limitExceeded("context_page") }
    return try readTransaction { _ in
      let cursor = try contextReadCursor(expectedCursor, file: contextFile(contextID)), root = contextFile(contextID) + "#"
      guard try hasStoredValue(contextFile(contextID)) else { throw CollaborationError("context_missing", "Общий фрагмент не найден.") }
      var position: Int64 = -1, member = ""
      if let afterEntryID {
        guard let row = try currentSQL!.rows("SELECT position,member FROM records WHERE parent=? AND collection='entries' AND member=?", [.text(root), .text(afterEntryID.uuidString.lowercased())]).first else { throw NotebookStorageError.transactionConflict }
        position = row[0].integer!; member = row[1].text!
      }
      let rows = try currentSQL!.rows("SELECT r.address,length(b.data) FROM records r JOIN blobs b ON b.hash=r.hash WHERE r.parent=? AND r.collection='entries' AND (r.position,r.member)>(?,?) ORDER BY r.position,r.member LIMIT ?", [.text(root), .integer(position), .text(member), .integer(Int64(limit + 1))])
      var entries: [SharedContextEntry] = [], bytes: Int64 = 0
      for row in rows.prefix(limit) {
        let size = row[1].integer!
        guard size <= 2_097_152 else { throw NotebookStorageError.limitExceeded("context_entry") }
        if bytes + size > 4_194_304 { break }
        guard let entry = try storedEntry(at: row[0].text!) else { throw NotebookStorageError.transactionConflict }
        let source = try entry.replyTo.flatMap { try sharedContextEntry(contextID: contextID, entryID: $0) }
        try entry.validate(sourceCounter: source?.stamp.counter)
        entries.append(entry); bytes += size
      }
      return .init(id: contextID, entries: entries, nextEntryID: rows.count > entries.count ? entries.last?.id : nil, readCursor: cursor)
    }
  }

  public func sharedContexts(contextID: UUID?, limit: Int = 64, afterContextID: UUID? = nil,
    expectedCursor: String? = nil) throws -> SharedContextDirectory {
    guard (1...64).contains(limit), afterContextID == nil || (expectedCursor != nil && contextID == nil) else { throw NotebookStorageError.limitExceeded("context_directory") }
    return try readTransaction { _ in
      let cursor = try contextReadCursor(expectedCursor), selection = try readContextSelection()
      var files: [String]
      if let contextID { files = [contextFile(contextID)] }
      else if let afterContextID {
        guard let row = try currentSQL!.rows("SELECT created_at,address FROM metadata_index WHERE kind='context' AND address=?", [.text(contextFile(afterContextID) + "#")]).first else { throw NotebookStorageError.transactionConflict }
        files = try currentSQL!.rows("SELECT address FROM metadata_index WHERE kind='context' AND (created_at,address)<(?,?) ORDER BY created_at DESC,address DESC LIMIT ?", [row[0], row[1], .integer(Int64(limit + 1))]).map { String($0[0].text!.dropLast()) }
      } else {
        files = try currentSQL!.rows("SELECT address FROM metadata_index WHERE kind='context' ORDER BY created_at DESC,address DESC LIMIT ?", [.integer(Int64(limit + 1))]).map { String($0[0].text!.dropLast()) }
      }
      var summaries: [SharedContextSummary] = [], bytes = 0
      for file in files.prefix(limit) {
        guard let id = UUID(uuidString: String(file.dropFirst("collaboration/contexts/".count).dropLast(5))), try hasStoredValue(file) else { continue }
        let root = file + "#"
        let first = try currentSQL!.rows("SELECT address FROM records WHERE parent=? AND collection='entries' ORDER BY position,member LIMIT 1", [.text(root)]).first?[0].text
        let last = try currentSQL!.rows("SELECT address FROM records WHERE parent=? AND collection='entries' ORDER BY position DESC,member DESC LIMIT 1", [.text(root)]).first?[0].text
        let firstEntry = try first.flatMap { try storedEntry(at: $0) }
        let lastEntry = try last == first ? firstEntry : last.flatMap { try storedEntry(at: $0) }
        let summary = SharedContextSummary(id: id, firstEntry: firstEntry, lastEntry: lastEntry)
        let size = try Self.storageEncoder.encode(summary).count
        guard size <= 4_194_304 else { throw NotebookStorageError.limitExceeded("context_summary") }
        if bytes + size > 4_194_304 { break }
        summaries.append(summary); bytes += size
      }
      let selectedContext: SharedContextSummary?
      if contextID == nil, afterContextID == nil, let selected = selection?.contextID,
        !summaries.contains(where: { $0.id == selected }) {
        selectedContext = try sharedContexts(contextID: selected, limit: 1).contexts.first
      } else { selectedContext = nil }
      return .init(contexts: summaries, selection: selection, selectedContext: selectedContext,
        nextContextID: files.count > summaries.count ? summaries.last?.id : nil, readCursor: cursor)
    }
  }
}

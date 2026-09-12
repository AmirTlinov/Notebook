import CryptoKit
import Darwin
import Foundation

public struct NotebookArchiveContentProof: Codable, Equatable, Sendable {
  public let workspaceID: UUID
  public let sharedRecordsSHA256: String
  public let sharedRecordCount: Int
  public let totalRecordCount: Int

  func validate() throws {
    guard Self.isSHA256(sharedRecordsSHA256), sharedRecordCount > 0,
      totalRecordCount >= sharedRecordCount else { throw NotebookStorageError.invalidTransaction("invalid archive content proof") }
  }

  static func isSHA256(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
}

extension NotebookStore {
  /// Prepare one device from every shared record, not a lossy domain envelope.
  /// The continuing iPad keeps its drafts/jobs; Mac receives its own presence.
  /// Both start a new delivery journal, never reinterpret historic wire deltas.
  public func prepareDeviceSnapshot(at output: URL, presence: SessionPresence,
    preservingLocalState: Bool, resumingFrom sourcePeer: UUID? = nil) throws -> NotebookArchiveContentProof {
    guard sourcePeer == nil || !preservingLocalState else { throw NotebookStorageError.invalidTransaction("a new replica cannot inherit device-local work") }
    let manager = FileManager.default
    let source = root.standardizedFileURL.resolvingSymlinksInPath(), destination = output.standardizedFileURL.resolvingSymlinksInPath()
    guard source != destination, !source.path.hasPrefix(destination.path + "/"),
      !destination.path.hasPrefix(source.path + "/"), !manager.fileExists(atPath: destination.path) else {
      throw NotebookStorageError.invalidTransaction("replica requires an independent new destination")
    }
    let original = try NotebookArchiveFingerprint.read(source)
    let staging = destination.deletingLastPathComponent().appendingPathComponent(".replica-" + UUID().uuidString)
    defer { try? manager.removeItem(at: staging) }
    try manager.copyItem(at: source, to: staging)
    guard try NotebookArchiveFingerprint.read(staging) == original else { throw NotebookStorageError.transactionConflict }
    let replica = NotebookStore(root: staging)
    try replica.prepareContextOrderIndexForTransfer()
    let before = try replica.archiveContentProof(), sourceCursor = try replica.currentChangeCursor()
    try replica.commandTransaction {
      let database = replica.currentSQL!
      var after = ""
      while true {
        let files = try database.rows("SELECT DISTINCT file FROM records WHERE file>? ORDER BY file LIMIT 64", [.text(after)]).compactMap { $0[0].text }
        if files.isEmpty { break }
        for file in files {
          after = file
          if !preservingLocalState, Self.localRecord(file) { try replica.removeFragment(file + "#", database: database) }
        }
      }
      try replica.savePresence(presence)
      for table in ["peer_cursors", "received_transactions", "manifest_order_nodes", "manifest_parts", "manifest_records", "manifests", "change_records", "change_log"] {
        try database.run("DELETE FROM \(table)")
      }
      try database.run("DELETE FROM sqlite_sequence WHERE name='change_log'")
      try database.run("DELETE FROM metadata WHERE key='placement_outgoing_floor'")
      if let sourcePeer {
        try database.run("INSERT INTO peer_cursors(peer_id,direction,sequence) VALUES(?,'incoming',?)",
          [.text(sourcePeer.uuidString.lowercased()), .integer(Int64(sourceCursor))])
      }
      if !preservingLocalState {
        for table in ["chat_jobs", "chat_panel", "chat_active_computer", "run_output", "project_runs", "run_commands", "file_drafts", "file_window", "file_version_files", "file_versions", "file_uploads", "file_commits", "file_renames"] { try database.run("DELETE FROM \(table)") }
      }
      // The seed declares every shared value under the current wire contract.
      // Existing content/receipt hashes stay identical; only delivery restarts.
      after = ""
      while true {
        let records = try database.rows("SELECT address,file,collection,hash FROM records WHERE address>? ORDER BY address LIMIT 64", [.text(after)])
        if records.isEmpty { break }
        for row in records {
          after = row[0].text!
          guard !Self.localRecord(row[1].text!) else { continue }
          try database.recordChange(.init(address: after, blobHash: row[3].text!))
          if row[1].text == "workspace.json", row[2].text == "pageOrders" {
            let fragment = try JSONDecoder().decode(NotebookStoredFragment.self, from: database.blob(row[3].text!))
            let order = try fragment.value.decode(NotebookPageOrderRegister.self)
            try database.noteOwner(.orderRoot, order.visibleRoot)
            for head in order.heads { try database.noteOwner(.orderRoot, head.valueRoot) }
          }
        }
      }
    }
    let proof = try replica.validateArchiveSnapshot()
    guard proof.workspaceID == before.workspaceID, proof.sharedRecordsSHA256 == before.sharedRecordsSHA256,
      proof.sharedRecordCount == before.sharedRecordCount,
      try NotebookArchiveFingerprint.read(source) == original else { throw NotebookStorageError.transactionConflict }
    let prepared = try NotebookArchiveFingerprint.read(staging)
    try NotebookArchiveFiles.syncTree(staging, proof: prepared)
    guard renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
      throw NotebookArchiveFiles.failure("publish private replica without replacing a destination")
    }
    try NotebookArchiveFiles.syncDirectory(destination.deletingLastPathComponent())
    return proof
  }

  /// Offline validation of a private prepared copy, not an ordinary scene read.
  /// Every immutable value is checked, including requests not represented by a
  /// CollaborationEnvelope. No connection or row escapes this WAL snapshot.
  public func validateArchiveSnapshot() throws -> NotebookArchiveContentProof {
    try readTransaction { store in
      let database = store.currentSQL!
      let integrity = try database.rows("PRAGMA integrity_check")
      guard integrity.count == 1, integrity.first?[0].text == "ok",
        try database.rows("PRAGMA foreign_key_check").isEmpty else {
        throw NotebookStorageError.corruptRecord("archive integrity")
      }
      try store.validateContextOrderIndex()
      let header = try store.workspaceHeader(), contexts = try store.sharedContexts()
      let checkpoint = try NotebookCheckpoint(workspaceID: header.workspaceID,
        envelope: .init(content: store.collaborationContent(), actions: store.collaborationActions(),
          contexts: contexts.contexts, selection: contexts.selection, delivery: store.deviceActionReceipts()),
        presence: store.loadPresence())
      try checkpoint.validate()
      var cursor: UInt64 = 0
      while true {
        let changes = try store.storedJournalPage(after: cursor, limit: 16, database: database)
        if changes.isEmpty { break }
        for change in changes {
          let manifest = try store.validatedManifest(change, historical: true)
          for part in manifest.parts { _ = try store.validatedManifest(change, partHash: part, historical: true) }
          cursor = change.sequence
        }
      }
      var lastHash = ""
      while let row = try database.rows("SELECT hash,data FROM blobs WHERE hash>? ORDER BY hash LIMIT 1", [.text(lastHash)]).first {
        let hash = row[0].text!, data = row[1].blob!
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == hash else {
          throw NotebookStorageError.blobHashMismatch
        }
        lastHash = hash
      }
      return try store.archiveContentProof()
    }
  }

  func archiveContentProof() throws -> NotebookArchiveContentProof {
    try sqlRead { database in
      var after = "", hasher = SHA256(), shared = 0, total = 0
      while true {
        let rows = try database.rows("SELECT address,file,hash,parent,collection,member,position FROM records WHERE address>? ORDER BY address LIMIT 64", [.text(after)])
        if rows.isEmpty { break }
        for row in rows {
          let address = row[0].text!, file = row[1].text!, hash = row[2].text!
          after = address; total += 1
          if !Self.localRecord(file) {
            // JSON frames delimit arbitrary addresses without separator ambiguity.
            let frame: [JSONValue] = [.string(address), .string(file), .string(hash),
              row[3].text.map(JSONValue.string) ?? .null, .string(row[4].text!), .string(row[5].text!),
              .string(String(row[6].integer!))]
            hasher.update(data: try Self.storageEncoder.encode(frame)); shared += 1
          }
        }
      }
      return try .init(workspaceID: workspaceHeader().workspaceID,
        sharedRecordsSHA256: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
        sharedRecordCount: shared, totalRecordCount: total)
    }
  }
}

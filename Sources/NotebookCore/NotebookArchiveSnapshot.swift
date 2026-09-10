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
  /// Seed the second device from all shared records, not a lossy domain
  /// envelope. Device-local drafts/jobs stay in the original device's archive;
  /// this private replica gets its own presence and no inherited network ACKs.
  public func prepareReplicaSnapshot(at output: URL, presence: SessionPresence) throws -> NotebookArchiveContentProof {
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
    let replica = NotebookStore(root: staging), before = try replica.validateArchiveSnapshot()
    try replica.commandTransaction {
      let database = replica.currentSQL!
      var after = ""
      while true {
        let files = try database.rows("SELECT DISTINCT file FROM records WHERE file>? ORDER BY file LIMIT 64", [.text(after)]).compactMap { $0[0].text }
        if files.isEmpty { break }
        for file in files {
          after = file
          if Self.localRecord(file) { try replica.removeFragment(file + "#", database: database) }
        }
      }
      try replica.savePresence(presence)
      for table in ["peer_cursors", "received_transactions", "manifest_order_nodes", "manifest_parts", "manifest_records", "manifests", "chat_jobs", "chat_panel"] {
        try database.run("DELETE FROM \(table)")
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
      let header = try store.workspaceHeader(), contexts = try store.sharedContexts()
      let checkpoint = try NotebookCheckpoint(workspaceID: header.workspaceID,
        envelope: .init(content: store.collaborationContent(), actions: store.collaborationActions(),
          contexts: contexts.contexts, selection: contexts.selection, delivery: store.deviceActionReceipts()),
        presence: store.loadPresence())
      try checkpoint.validate()
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

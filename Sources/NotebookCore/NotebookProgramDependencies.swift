import Foundation

extension NotebookStore {
  /// Dependencies belong to authored program fields, never hash-looking strings
  /// in a program's state, source text, or an arbitrary nested JSON value.
  func programPackageHashes(in fragment: NotebookStoredFragment) throws -> Set<String> {
    var hashes: Set<String> = []
    func add(_ value: JSONValue?) throws {
      guard let value, value != .null else { return }
      guard let hash = value.string, NotebookProgramPackage.validHash(hash) else {
        throw NotebookStorageError.invalidTransaction("program package reference")
      }
      hashes.insert(hash)
    }
    let isElement = (fragment.file.hasPrefix("pages/") && fragment.collection == "elements")
      || (fragment.file == "board.json" && fragment.collection == "board/elements")
    let isBlock = fragment.file.hasPrefix("documents/") && fragment.collection == "blocks"
    if isElement || isBlock {
      try add(fragment.value["programPackage"])
    }
    let isCausal = (fragment.file.hasPrefix("pages/") || fragment.file.hasPrefix("documents/"))
      ? fragment.collection == "collaboration/fields"
      : fragment.file == "board.json" && fragment.collection == "board/collaboration/fields"
    let key = fragment.member.components(separatedBy: "/")
    let collection = fragment.file.hasPrefix("documents/") ? "blocks" : "elements"
    if isCausal, key.count == 3, key[0] == collection, key[2] == "content" {
      let version = try fragment.value.decode(ContentFieldVersion.self)
      guard version.isValid else { throw NotebookStorageError.invalidTransaction("program causal source") }
      for value in version.retainedContentValues { try add(value["programPackage"]) }
    }
    return hashes
  }

  func validateProgramPackageClosure(_ hash: String) throws {
    let package = try readProgramPackage(hash)
    for part in package.files.flatMap(\.parts) {
      guard try blobSize(hash: part.sha256) == part.byteCount else { throw NotebookStorageError.blobHashMismatch }
    }
  }

  private func prepareProgramDependencies() throws {
    let db = currentSQL!
    try db.run("CREATE TABLE IF NOT EXISTS manifest_program_discovery(manifest_hash TEXT PRIMARY KEY REFERENCES manifests(hash)) WITHOUT ROWID")
    try db.run("CREATE TABLE IF NOT EXISTS manifest_program_roots(manifest_hash TEXT NOT NULL REFERENCES manifests(hash),hash TEXT NOT NULL,expanded INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(manifest_hash,hash)) WITHOUT ROWID")
    try db.run("CREATE TABLE IF NOT EXISTS manifest_program_parts(manifest_hash TEXT NOT NULL REFERENCES manifests(hash),hash TEXT NOT NULL,byte_count INTEGER NOT NULL,PRIMARY KEY(manifest_hash,hash)) WITHOUT ROWID")
  }

  func noteProgramDependencies(manifestHash: String, fragment: NotebookStoredFragment) throws {
    let hashes = try programPackageHashes(in: fragment)
    guard !hashes.isEmpty else { return }
    try prepareProgramDependencies()
    for hash in hashes {
      try currentSQL!.run("INSERT OR IGNORE INTO manifest_program_roots(manifest_hash,hash) VALUES(?,?)", [.text(manifestHash), .text(hash)])
    }
  }

  /// The existing manifest/part admission owns availability. This SQL index is
  /// derived discovery state, not a second asset store or delivery journal.
  func missingProgramBlobs(change: NotebookDurableChange, limit: Int) throws -> [String] {
    try prepareProgramDependencies()
    let db = currentSQL!, manifest = change.manifestHash
    if try db.rows("SELECT 1 FROM manifest_program_discovery WHERE manifest_hash=?", [.text(manifest)]).isEmpty {
      var after = "", admittedDocumentProgram: String?
      while true {
        try Task.checkCancellation()
        let rows = try db.rows("""
          SELECT address,blob_hash,(SELECT length(data) FROM blobs WHERE hash=blob_hash) FROM manifest_records WHERE manifest_hash=? AND address>? AND blob_hash IS NOT NULL AND (
            address GLOB 'pages/*#/elements/@*' OR address GLOB 'documents/*#/blocks/@*' OR
            address GLOB 'board.json#/boards/@*/board/elements/@*' OR
            address GLOB 'pages/*#/collaboration/fields/@*' OR address GLOB 'documents/*#/collaboration/fields/@*' OR
            address GLOB 'board.json#/boards/@*/board/collaboration/fields/@*')
          ORDER BY address LIMIT 64
          """, [.text(manifest), .text(after)])
        guard let last = rows.last else { break }
        for row in rows {
          let address = row[0].text!
          if address.hasPrefix("documents/") {
            if let block = address.range(of: "#/blocks/@") {
              let end = address[block.upperBound...].firstIndex(of: "/") ?? address.endIndex
              let root = String(address[..<end])
              if admittedDocumentProgram != root {
                _ = try incomingDocumentProgramRecords(root, manifestHash: manifest)
                admittedDocumentProgram = root
              }
              // initialState children do not own programPackage references.
              guard address == root else { continue }
            }
            guard let bytes = row[2].integer else { throw NotebookStorageError.blobMissing(row[1].text!) }
            guard bytes <= Self.documentProgramReplicationBytes else { throw NotebookStorageError.limitExceeded("document_replication_block") }
          }
          let fragment = try JSONDecoder().decode(NotebookStoredFragment.self, from: db.blob(row[1].text!))
          guard fragment.address == row[0].text else { throw NotebookStorageError.invalidTransaction("program dependency address") }
          try noteProgramDependencies(manifestHash: manifest, fragment: fragment)
        }
        after = last[0].text!
      }
      try db.run("INSERT INTO manifest_program_discovery VALUES(?)", [.text(manifest)])
    }
    if try !db.rows("SELECT 1 FROM manifest_program_roots WHERE manifest_hash=? LIMIT 1", [.text(manifest)]).isEmpty {
      guard try validatedManifest(change).format >= 10 else { throw NotebookStorageError.invalidTransaction("program package requires wire format 10") }
    }
    // Recheck even expanded roots: cached discovery is not proof of presence.
    let missingRoots = try db.rows("SELECT r.hash FROM manifest_program_roots r LEFT JOIN blobs b ON b.hash=r.hash WHERE r.manifest_hash=? AND b.hash IS NULL ORDER BY r.hash LIMIT ?", [.text(manifest), .integer(Int64(limit))]).compactMap { $0[0].text }
    if !missingRoots.isEmpty { return missingRoots }
    while let hash = try db.rows("SELECT hash FROM manifest_program_roots WHERE manifest_hash=? AND expanded=0 ORDER BY hash LIMIT 1", [.text(manifest)]).first?[0].text {
      try Task.checkCancellation()
      for part in try readProgramPackage(hash).files.flatMap(\.parts) {
        try db.run("INSERT OR IGNORE INTO manifest_program_parts VALUES(?,?,?)", [.text(manifest), .text(part.sha256), .integer(Int64(part.byteCount))])
        guard try db.rows("SELECT byte_count FROM manifest_program_parts WHERE manifest_hash=? AND hash=?", [.text(manifest), .text(part.sha256)]).first?[0].integer == Int64(part.byteCount) else { throw NotebookStorageError.blobHashMismatch }
      }
      try db.run("UPDATE manifest_program_roots SET expanded=1 WHERE manifest_hash=? AND hash=?", [.text(manifest), .text(hash)])
    }
    let missing = try db.rows("SELECT p.hash FROM manifest_program_parts p LEFT JOIN blobs b ON b.hash=p.hash WHERE p.manifest_hash=? AND b.hash IS NULL ORDER BY p.hash LIMIT ?", [.text(manifest), .integer(Int64(limit))]).compactMap { $0[0].text }
    if !missing.isEmpty { return missing }
    var after = ""
    while let hash = try db.rows("SELECT hash FROM manifest_program_roots WHERE manifest_hash=? AND hash>? ORDER BY hash LIMIT 1", [.text(manifest), .text(after)]).first?[0].text {
      try validateProgramPackageClosure(hash); after = hash
    }
    return []
  }

  func visitProgramDependencyHashes(manifestHash: String, _ visit: (String) throws -> Void) throws {
    let db = currentSQL!
    var after = ""
    while true {
      try Task.checkCancellation()
      let hashes = try db.rows("SELECT hash FROM manifest_program_roots WHERE manifest_hash=? AND hash>? UNION SELECT hash FROM manifest_program_parts WHERE manifest_hash=? AND hash>? ORDER BY hash LIMIT 64", [.text(manifestHash), .text(after), .text(manifestHash), .text(after)]).compactMap { $0[0].text }
      guard let last = hashes.last else { break }
      for hash in hashes { try visit(hash) }; after = last
    }
  }
}

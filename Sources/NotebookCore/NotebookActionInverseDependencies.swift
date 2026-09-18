import CSQLite
import Foundation

private struct NotebookLifecycleInverseReceiptHeader: Codable {
  struct Action: Codable { let id: UUID }
  struct Undo: Codable { let restorationInverse: NotebookLifecycleInverseReference? }
  let id: UUID
  let action: Action
  let lifecycleInverse: NotebookLifecycleInverseReference?
  let undo: Undo?
}

extension NotebookStore {
  /// Derived discovery state in the same SQLite store. Existing format-8
  /// databases create it lazily; no content migration or second journal.
  static func prepareLifecycleInverseDependencies(_ database: NotebookSQLConnection) throws {
    try database.run("CREATE TABLE IF NOT EXISTS manifest_inverse_discovery(manifest_hash TEXT PRIMARY KEY REFERENCES manifests(hash),record_count INTEGER NOT NULL DEFAULT 0,order_count INTEGER NOT NULL DEFAULT 0,order_bytes INTEGER NOT NULL DEFAULT 0) WITHOUT ROWID")
    try database.run("CREATE TABLE IF NOT EXISTS manifest_inverse_roots(manifest_hash TEXT NOT NULL REFERENCES manifests(hash),action_id TEXT NOT NULL,purpose INTEGER NOT NULL,receipt_hash TEXT NOT NULL,root_hash TEXT NOT NULL,record_count INTEGER NOT NULL,loaded INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(manifest_hash,action_id,purpose)) WITHOUT ROWID")
    try database.run("CREATE INDEX IF NOT EXISTS manifest_inverse_root_pending ON manifest_inverse_roots(manifest_hash,loaded,action_id,purpose)")
    try database.run("CREATE TABLE IF NOT EXISTS manifest_inverse_parts(manifest_hash TEXT NOT NULL REFERENCES manifests(hash),action_id TEXT NOT NULL,purpose INTEGER NOT NULL,ordinal INTEGER NOT NULL,hash TEXT NOT NULL,loaded INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(manifest_hash,action_id,purpose,ordinal)) WITHOUT ROWID")
    try database.run("CREATE INDEX IF NOT EXISTS manifest_inverse_part_pending ON manifest_inverse_parts(manifest_hash,loaded,action_id,purpose,ordinal)")
    try database.run("CREATE INDEX IF NOT EXISTS manifest_inverse_part_hash ON manifest_inverse_parts(manifest_hash,hash)")
    try database.run("CREATE INDEX IF NOT EXISTS manifest_inverse_root_hash ON manifest_inverse_roots(manifest_hash,root_hash)")
    try database.run("CREATE TABLE IF NOT EXISTS manifest_inverse_blobs(manifest_hash TEXT NOT NULL REFERENCES manifests(hash),hash TEXT NOT NULL,kind INTEGER NOT NULL,expanded INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(manifest_hash,hash,kind)) WITHOUT ROWID")
    try database.run("CREATE INDEX IF NOT EXISTS manifest_inverse_blob_pending ON manifest_inverse_blobs(manifest_hash,expanded,hash,kind)")
    try database.run("CREATE INDEX IF NOT EXISTS manifest_inverse_blob_kind ON manifest_inverse_blobs(manifest_hash,kind,hash)")
  }

  /// Read the compact reference in the physical receipt root, not the receipt's
  /// fields or an additional wire root list. Two purposes share the same
  /// action binding: original evidence and the actual authored undo writes.
  func lifecycleInverseReceiptReference(hash: String, actionID: UUID, purpose: Int64 = 0) throws -> NotebookLifecycleInverseReference? {
    let data = try lifecycleInverseBlob(hash, maximumBytes: NotebookLifecycleInverseLimits.bytes)
    let fragment = try JSONDecoder().decode(NotebookStoredPayload<NotebookLifecycleInverseReceiptHeader>.self, from: data)
    let file = "collaboration/actions/" + actionID.uuidString.lowercased() + ".json"
    guard fragment.file == file, fragment.address == file + "#", fragment.parent == nil,
      fragment.value.id == actionID, fragment.value.action.id == actionID else {
      throw NotebookStorageError.invalidTransaction("inverse receipt identity")
    }
    let reference: NotebookLifecycleInverseReference?
    switch purpose {
    case 0: reference = fragment.value.lifecycleInverse
    case 1: reference = fragment.value.undo?.restorationInverse
    default: throw NotebookStorageError.invalidTransaction("inverse receipt purpose")
    }
    guard let reference else { return nil }
    guard NotebookPageOrderRegister.validHash(reference.rootHash), (1...NotebookLifecycleInverseLimits.records).contains(reference.recordCount) else {
      throw NotebookStorageError.invalidTransaction("inverse receipt reference")
    }
    return reference
  }

  func discoverLifecycleInverseReferences(change: NotebookDurableChange) throws {
    let database = currentSQL!, manifest = change.manifestHash
    if try !database.rows("SELECT 1 FROM manifest_inverse_discovery WHERE manifest_hash=?", [.text(manifest)]).isEmpty { return }
    let format = try validatedManifest(change).format
    var after = "collaboration/actions/"
    while let address = try database.rows("SELECT address FROM manifest_records WHERE manifest_hash=? AND address>? AND address<'collaboration/actions0' ORDER BY address LIMIT 1", [.text(manifest), .text(after)]).first?[0].text {
      let file = String(address.split(separator: "#", maxSplits: 1)[0]); after = file + "$"
      let name = String(file.dropFirst("collaboration/actions/".count).dropLast(".json".count))
      guard let actionID = UUID(uuidString: name), actionID.uuidString.lowercased() == name else { throw NotebookStorageError.invalidTransaction("inverse receipt address") }
      let incoming = try database.rows("SELECT blob_hash FROM manifest_records WHERE manifest_hash=? AND address=?", [.text(manifest), .text(file + "#")]).first
      let hash: String?
      if let incoming { hash = incoming[0].text }
      else { hash = try database.rows("SELECT hash FROM records WHERE address=?", [.text(file + "#")]).first?[0].text }
      guard let hash else { continue }
      for purpose in [Int64(0), Int64(1)] {
        guard let reference = try lifecycleInverseReceiptReference(hash: hash, actionID: actionID, purpose: purpose) else { continue }
        guard format >= 8 else { throw NotebookStorageError.invalidTransaction("lifecycle inverse requires wire format 8") }
        try database.run("INSERT INTO manifest_inverse_roots(manifest_hash,action_id,purpose,receipt_hash,root_hash,record_count) VALUES(?,?,?,?,?,?)",
          [.text(manifest), .text(name), .integer(purpose), .text(hash), .text(reference.rootHash), .integer(Int64(reference.recordCount))])
      }
    }
    try database.run("INSERT INTO manifest_inverse_discovery(manifest_hash) VALUES(?)", [.text(manifest)])
  }

  /// Expansion is keyset/index bounded and disk-backed. Admission never writes
  /// any inverse body into records: a receipt is evidence, not an undo command.
  func missingLifecycleInverseBlobs(change: NotebookDurableChange, limit: Int) throws -> [String] {
    let database = currentSQL!, manifest = change.manifestHash
    try Self.prepareLifecycleInverseDependencies(database)
    try discoverLifecycleInverseReferences(change: change)
    let totals = try database.rows("SELECT record_count,order_count,order_bytes FROM manifest_inverse_discovery WHERE manifest_hash=?", [.text(manifest)]).first!
    var recordCount = totals[0].integer!, orderCount = totals[1].integer!, orderBytes = totals[2].integer!
    func finish(_ missing: [String]) throws -> [String] {
      try database.run("UPDATE manifest_inverse_discovery SET record_count=?,order_count=?,order_bytes=? WHERE manifest_hash=?",
        [.integer(recordCount), .integer(orderCount), .integer(orderBytes), .text(manifest)])
      return missing
    }
    func present(_ hash: String) throws -> Bool { try !database.rows("SELECT 1 FROM blobs WHERE hash=?", [.text(hash)]).isEmpty }
    func dependency(_ hash: String, kind: Int64) throws {
      try database.run("INSERT OR IGNORE INTO manifest_inverse_blobs(manifest_hash,hash,kind) VALUES(?,?,?)", [.text(manifest), .text(hash), .integer(kind)])
      if sqlite3_changes64(database.handle) == 1 {
        if kind == 0 { recordCount += 1 } else { orderCount += 1 }
        guard recordCount <= Int64(NotebookLifecycleInverseLimits.records) * 2,
          orderCount <= NotebookPageOrderVector.maximumNodes else { throw NotebookStorageError.limitExceeded("lifecycle_inverse_dependencies") }
      }
    }
    while true {
      try Task.checkCancellation()
      let roots = try database.rows("SELECT action_id,purpose,root_hash,record_count FROM manifest_inverse_roots WHERE manifest_hash=? AND loaded=0 ORDER BY action_id,purpose LIMIT 64", [.text(manifest)])
      if roots.isEmpty { break }
      var missing: [String] = []
      for row in roots {
        let action = row[0].text!, purpose = row[1].integer!, hash = row[2].text!
        guard try present(hash) else { missing.append(hash); if missing.count == limit { return try finish(missing) }; continue }
        let root = try readLifecycleInverseRoot(reference: .init(rootHash: hash, recordCount: Int(row[3].integer!)), actionID: UUID(uuidString: action)!)
        for (ordinal, hash) in root.parts.enumerated() {
          try database.run("INSERT INTO manifest_inverse_parts(manifest_hash,action_id,purpose,ordinal,hash) VALUES(?,?,?,?,?)", [.text(manifest), .text(action), .integer(purpose), .integer(Int64(ordinal)), .text(hash)])
        }
        try database.run("UPDATE manifest_inverse_roots SET loaded=1 WHERE manifest_hash=? AND action_id=? AND purpose=?", [.text(manifest), .text(action), .integer(purpose)])
      }
      if !missing.isEmpty { return try finish(missing) }
    }
    while true {
      try Task.checkCancellation()
      let parts = try database.rows("SELECT action_id,purpose,ordinal,hash FROM manifest_inverse_parts WHERE manifest_hash=? AND loaded=0 ORDER BY action_id,purpose,ordinal LIMIT 64", [.text(manifest)])
      if parts.isEmpty { break }
      var missing: [String] = []
      for row in parts {
        let action = row[0].text!, purpose = row[1].integer!, ordinal = row[2].integer!, hash = row[3].text!
        guard try present(hash) else { missing.append(hash); if missing.count == limit { return try finish(missing) }; continue }
        let part = try readLifecycleInversePart(hash: hash, actionID: UUID(uuidString: action)!, ordinal: Int(ordinal))
        for record in part.records {
          if let hash = record.beforeHash { try dependency(hash, kind: 0) }
          if let hash = record.afterHash { try dependency(hash, kind: 0) }
        }
        try database.run("UPDATE manifest_inverse_parts SET loaded=1 WHERE manifest_hash=? AND action_id=? AND purpose=? AND ordinal=?", [.text(manifest), .text(action), .integer(purpose), .integer(ordinal)])
      }
      if !missing.isEmpty { return try finish(missing) }
    }
    while true {
      try Task.checkCancellation()
      let dependencies = try database.rows("SELECT hash,kind FROM manifest_inverse_blobs WHERE manifest_hash=? AND expanded=0 ORDER BY hash,kind LIMIT 256", [.text(manifest)])
      if dependencies.isEmpty { break }
      var missing: [String] = []
      for row in dependencies {
        let hash = row[0].text!, kind = row[1].integer!
        guard try present(hash) else { missing.append(hash); if missing.count == limit { return try finish(missing) }; continue }
        if kind == 0 {
          for root in try lifecycleInverseOrderRoots(readLifecycleInverseFragment(hash: hash)) { try dependency(root, kind: 1) }
        } else {
          let node = try readPageOrderNode(hash)
          orderBytes += Int64(try node.canonicalData().count)
          guard orderBytes <= NotebookPageOrderVector.maximumBytes else { throw NotebookStorageError.limitExceeded("lifecycle_inverse_order_bytes") }
          if try !lifecycleInverseOrderIsAdmitted(hash, node: node) {
            for child in node.children { try dependency(child, kind: 1) }
          }
        }
        try database.run("UPDATE manifest_inverse_blobs SET expanded=1 WHERE manifest_hash=? AND hash=? AND kind=?", [.text(manifest), .text(hash), .integer(kind)])
      }
      if !missing.isEmpty { return try finish(missing) }
    }
    // Expanded is a discovery cache, never a proof. Recheck immutable bytes,
    // identity, cross-part order/count and canonical closure before every ACK.
    var after = "", afterPurpose: Int64 = -1
    while true {
      try Task.checkCancellation()
      let roots = try database.rows("SELECT action_id,purpose,receipt_hash,root_hash,record_count FROM manifest_inverse_roots WHERE manifest_hash=? AND (action_id,purpose)>(?,?) ORDER BY action_id,purpose LIMIT 64", [.text(manifest), .text(after), .integer(afterPurpose)])
      if roots.isEmpty { break }
      for row in roots {
        after = row[0].text!; afterPurpose = row[1].integer!
        let action = UUID(uuidString: after)!, reference = NotebookLifecycleInverseReference(rootHash: row[3].text!, recordCount: Int(row[4].integer!))
        guard try lifecycleInverseReceiptReference(hash: row[2].text!, actionID: action, purpose: afterPurpose) == reference else { throw NotebookStorageError.invalidTransaction("inverse receipt changed") }
        try visitLifecycleInverse(reference: reference, actionID: action) { _ in }
      }
    }
    return try finish([])
  }

  func visitLifecycleInverseDependencyHashes(manifestHash: String, _ visit: (String) throws -> Void) throws {
    let database = currentSQL!
    var after = ""
    while true {
      try Task.checkCancellation()
      let hashes = try database.rows("SELECT root_hash AS hash FROM manifest_inverse_roots WHERE manifest_hash=? AND root_hash>? UNION SELECT hash FROM manifest_inverse_parts WHERE manifest_hash=? AND hash>? UNION SELECT hash FROM manifest_inverse_blobs WHERE manifest_hash=? AND hash>? ORDER BY hash LIMIT 64",
        [.text(manifestHash), .text(after), .text(manifestHash), .text(after), .text(manifestHash), .text(after)]).compactMap { $0[0].text }
      guard let last = hashes.last else { break }
      for hash in hashes { try visit(hash) }; after = last
    }
  }

  func validateStoredLifecycleInverses() throws {
    let database = currentSQL!
    var after = "collaboration/actions/"
    while let row = try database.rows("SELECT address,hash FROM records WHERE address>? AND address<'collaboration/actions0' ORDER BY address LIMIT 1", [.text(after)]).first {
      let file = String(row[0].text!.split(separator: "#", maxSplits: 1)[0]); after = file + "$"
      guard row[0].text == file + "#", let actionID = UUID(uuidString: String(file.dropFirst("collaboration/actions/".count).dropLast(".json".count))) else {
        throw NotebookStorageError.invalidTransaction("archive inverse receipt root")
      }
      for purpose in [Int64(0), Int64(1)] {
        if let reference = try lifecycleInverseReceiptReference(hash: row[1].text!, actionID: actionID, purpose: purpose) {
          try visitLifecycleInverse(reference: reference, actionID: actionID) { _ in }
        }
      }
    }
  }
}

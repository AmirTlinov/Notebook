import CryptoKit
import Foundation

/// Derived export work, never a second content owner. The mutable record cut
/// is captured once; its immutable dependency graph is walked in short reads.
/// Writer batches import the result before making any descriptor sendable.
public struct NotebookCloudUploadPlan: Sendable {
  public let id: UUID
  public let delivery: NotebookReplicationDelivery
  let account: String
  let accountCursor: UInt64
}

/// One authenticated worker result. Its bytes/cursors travel together across
/// the FIFO boundary; the writer neither reads a spool nor hashes its payload.
public struct NotebookCloudUploadBatch: Sendable {
  struct Payload: Sendable { let ordinal: Int64; let hash: String; let data: Data }
  struct Chunk: Sendable { let ordinal: Int64; let record: NotebookCloudRecord }
  let id: UUID
  let account: String
  let blobCursor: Int64
  let recordCursor: Int64
  let payload: Payload?
  let chunks: [Chunk]
  let delivery: (id: String, data: Data)?
}

extension NotebookStore {
  func cloudPlanURL(_ id: UUID) -> URL {
    root.appendingPathComponent("runtime/cloud-upload-plans", isDirectory: true)
      .appendingPathComponent(id.uuidString.lowercased() + ".sqlite")
  }

  /// Called by the serial upload worker before it creates another spool.
  /// Unsealed exports retain their exact plan; sealed exports use main blobs.
  public func retireUnclaimedCloudUploadSpools() throws {
    let retained = try sqlRead { db in
      Set(try db.rows("SELECT plan FROM cloud_exports WHERE ready=0 AND plan IS NOT NULL").compactMap { $0[0].text })
    }
    let directory = cloudPlanURL(UUID()).deletingLastPathComponent()
    guard FileManager.default.fileExists(atPath: directory.path) else { return }
    for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
      let name = url.lastPathComponent.components(separatedBy: ".sqlite").first ?? ""
      guard let id = UUID(uuidString: name),
        [".sqlite", ".sqlite-journal", ".sqlite-wal", ".sqlite-shm"].contains(String(url.lastPathComponent.dropFirst(name.count))),
        !retained.contains(id.uuidString.lowercased()) else { continue }
      try discardCloudUploadSpool(id)
    }
  }

  public func prepareCloudUploadPlan(account: String, source: NotebookReplicationSource) throws -> NotebookCloudUploadPlan? {
    // The worker owns the read cuts. An outer transaction would accidentally
    // retain its WAL snapshot through the entire dependency graph again.
    guard currentSQL == nil else { throw NotebookStorageError.invalidTransaction("cloud plan requires its own read session") }
    try Task.checkCancellation()
    // An idle request must not create a spool. The export captures/revalidates
    // its actual cut below; a later local commit schedules its own demand.
    guard try NotebookReadSession(store: self).read({ _ in
      try cloudUploadWork(account: account, source: source) != nil
    }) else { return nil }
    try Task.checkCancellation()
    try retireUnclaimedCloudUploadSpools()
    try Task.checkCancellation()
    let id = UUID(), url = cloudPlanURL(id)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var completed = false
    defer { if !completed { try? discardCloudUploadSpool(id) } }
    // The helper releases its SQLite handle before an abandoned spool is removed.
    let result = try buildCloudUploadPlan(id: id, account: account, source: source)
    completed = result != nil
    return result
  }

  private func cloudUploadWork(account: String, source: NotebookReplicationSource)
    throws -> (cursor: UInt64, next: NotebookDurableChange?)? {
    try requireCloudAccount(account)
    let database = currentSQL!
    guard let binding = try database.rows("SELECT cursor,generation FROM cloud_accounts WHERE account=?", [.text(account)]).first,
      let stored = binding[0].integer, stored >= 0,
      binding[1].text == source.generation.uuidString.lowercased() else {
      throw NotebookStorageError.invalidTransaction("cloud source generation")
    }
    guard try hasWorkspaceContent(),
      try database.rows("SELECT 1 FROM cloud_exports WHERE account=? LIMIT 1", [.text(account)]).isEmpty else { return nil }
    let cursor = UInt64(stored)
    let next = cursor == 0 ? nil : try changeJournal(after: cursor, limit: 1).first
    return cursor == 0 || next != nil ? (cursor, next) : nil
  }

  private func buildCloudUploadPlan(id: UUID, account: String, source: NotebookReplicationSource) throws -> NotebookCloudUploadPlan? {
    let plan = try NotebookSQLConnection(url: cloudPlanURL(id), writable: true, create: true)
    try plan.run("CREATE TABLE payloads(ordinal INTEGER PRIMARY KEY,hash TEXT UNIQUE NOT NULL,data BLOB NOT NULL)")
    try plan.run("CREATE TABLE outbox(ordinal INTEGER PRIMARY KEY,id TEXT UNIQUE NOT NULL,hash TEXT NOT NULL,offset INTEGER NOT NULL,total INTEGER NOT NULL)")
    try plan.run("CREATE TABLE work(hash TEXT NOT NULL,kind INTEGER NOT NULL,address TEXT,action TEXT,position INTEGER,done INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(hash,kind))")
    try plan.run("CREATE INDEX pending_work ON work(done,kind,hash)")
    try plan.run("CREATE TABLE receipts(address TEXT PRIMARY KEY,hash TEXT,resolved INTEGER NOT NULL DEFAULT 0)")
    try plan.run("BEGIN")
    let reader = NotebookReadSession(store: self)
    func publish(_ data: Data) throws -> String {
      guard data.count <= 67_108_864 else { throw NotebookStorageError.limitExceeded("cloud_manifest_bytes") }
      let hash = NotebookHexEncoding.encode(SHA256.hash(data: data))
      try plan.run("INSERT OR IGNORE INTO payloads(hash,data) VALUES(?,?)", [.text(hash), .blob(data)])
      return hash
    }
    func bytes(_ hash: String) throws -> Data {
      if let data = try plan.rows("SELECT data FROM payloads WHERE hash=?", [.text(hash)]).first?[0].blob { return data }
      return try currentSQL!.blob(hash)
    }
    // Plain blob, record envelope, order node, ink graph, program package,
    // inverse root, inverse part, receipt discovery. No measurement replay.
    func enqueue(_ hash: String, kind: Int64 = 0, address: String? = nil,
      action: UUID? = nil, position: Int64? = nil) throws {
      try plan.run("INSERT OR IGNORE INTO work(hash,kind,address,action,position) VALUES(?,?,?,?,?)",
        [.text(hash), .integer(kind), address.map(NotebookSQLValue.text) ?? .null,
          action.map { .text($0.uuidString.lowercased()) } ?? .null, position.map(NotebookSQLValue.integer) ?? .null])
    }
    let capture: (NotebookReplicationDelivery, UInt64)? = try reader.read { _ in
      guard let work = try cloudUploadWork(account: account, source: source) else { return nil }
      let database = currentSQL!
      let cursor = work.cursor
      let delivery = try cursor == 0 ? prepareCloudSnapshot(source: source, publish: publish)
        : NotebookReplicationDelivery(source: source, change: work.next!)
      let workspaceID = try workspaceHeader().workspaceID
      func manifest(_ hash: String, part: Bool) throws -> NotebookChangeManifest {
        try Task.checkCancellation()
        let data = try bytes(hash)
        guard data.count <= 67_108_864, part || data.count == delivery.change.byteCount,
          NotebookHexEncoding.encode(SHA256.hash(data: data)) == hash else { throw NotebookStorageError.blobHashMismatch }
        let value = try JSONDecoder().decode(NotebookChangeManifest.self, from: data)
        guard value.format == NotebookChangeManifest.currentFormat,
          value.transactionID == delivery.change.transactionID, value.workspaceID == workspaceID,
          value.records.count <= 16_384, value.parts.count <= 512,
          value.records.isEmpty || value.parts.isEmpty,
          !part || (value.parts.isEmpty && value.pageOrderRoots.isEmpty),
          Set(value.parts).count == value.parts.count,
          Set(value.records.map(\.address)).count == value.records.count,
          value.pageOrderRoots.count <= 131_072 else { throw NotebookStorageError.invalidTransaction("cloud manifest identity") }
        try enqueue(hash)
        for record in value.records {
          if let hash = record.blobHash { try enqueue(hash, kind: 1, address: record.address) }
          if record.address.hasPrefix("collaboration/actions/") {
            let file = String(record.address.split(separator: "#", maxSplits: 1)[0]), root = file + "#"
            try plan.run("INSERT OR IGNORE INTO receipts(address) VALUES(?)", [.text(root)])
            if record.address == root {
              try plan.run("UPDATE receipts SET hash=?,resolved=1 WHERE address=?", [record.blobHash.map(NotebookSQLValue.text) ?? .null, .text(root)])
            }
          }
        }
        for root in value.pageOrderRoots { try enqueue(root, kind: 2) }
        return value
      }
      let root = try manifest(delivery.change.manifestHash, part: false)
      for part in root.parts { _ = try manifest(part, part: true) }
      // A field-only receipt delta inherits the receipt root from THIS cut,
      // never from a later edit encountered while walking immutable bodies.
      var after = ""
      while let row = try plan.rows("SELECT address,hash,resolved FROM receipts WHERE address>? ORDER BY address LIMIT 1", [.text(after)]).first {
        try Task.checkCancellation()
        let address = row[0].text!; after = address
        let hash = try row[2].integer == 1 ? row[1].text
          : database.rows("SELECT hash FROM records WHERE address=?", [.text(address)]).first?[0].text
        let name = String(address.dropFirst("collaboration/actions/".count).dropLast(".json#".count))
        guard let action = UUID(uuidString: name), action.uuidString.lowercased() == name else { throw NotebookStorageError.invalidTransaction("cloud receipt identity") }
        if let hash { try enqueue(hash, kind: 7, action: action) }
      }
      return (delivery, cursor)
    }
    guard let (delivery, cursor) = capture else { return nil }
    // Blobs are append-only in the authoritative store (including old inverse
    // bodies). Every subsequent read follows captured hashes, not live records.
    // This releases the mutable WAL cut before a large ink/order/history walk.
    while let row = try plan.rows("SELECT hash,kind,address,action,position FROM work WHERE done=0 ORDER BY kind,hash LIMIT 1").first {
      try Task.checkCancellation()
      try reader.read { _ in
        try requireCloudAccount(account)
        let database = currentSQL!, hash = row[0].text!, kind = row[1].integer!
        var needsUpload = false
        if kind != 7 {
          let size = try plan.rows("SELECT length(data) FROM payloads WHERE hash=?", [.text(hash)]).first?[0].integer ?? blobSize(hash: hash)
          guard (0...NotebookTransportLimits.maximumBlobBytes).contains(size) else { throw NotebookTransportError.blobTooLarge }
          var offset: Int64 = 0
          repeat {
            let record = try NotebookCloudRecord.chunk(hash: hash, offset: offset, totalBytes: size)
            if try database.rows("SELECT 1 FROM cloud_uploaded WHERE account=? AND id=?", [.text(account), .text(record.id)]).isEmpty {
              needsUpload = true
              try plan.run("INSERT OR IGNORE INTO outbox(id,hash,offset,total) VALUES(?,?,?,?)",
                [.text(record.id), .text(hash), .integer(offset), .integer(size)])
            }
            offset += Int64(NotebookCloudRecord.chunkBytes)
          } while offset < size
        }
        switch kind {
        case 1:
          // Source blobs already passed the material admission owner. Discovery
          // validates references without expanding NIB2 into all old strokes.
          let fragment = try database.decodeFragmentEnvelope(bytes(hash))
          guard fragment.address == row[2].text else { throw NotebookStorageError.invalidTransaction("cloud source address") }
          for root in try programPackageHashes(in: fragment) { try enqueue(root, kind: 4) }
          for part in try documentResourceParts(in: fragment) {
            guard try blobSize(hash: part.sha256) == part.byteCount else { throw NotebookStorageError.blobHashMismatch }
            try enqueue(part.sha256)
          }
          for root in try fragment.inkBodyHashes { try enqueue(root, kind: 3) }
          for root in try lifecycleInverseOrderRoots(fragment) { try enqueue(root, kind: 2) }
        case 2:
          // A previously completed export covered this immutable root. An
          // unfinished export resumes its sealed plan instead of replanning.
          if needsUpload { for child in try readPageOrderNode(hash).children { try enqueue(child, kind: 2) } }
        case 3:
          for child in try InkStoredBody.dependencies(database.inkBlob(hash)) { try enqueue(child, kind: 3) }
        case 4:
          for part in try readProgramPackage(hash).files.flatMap(\.parts) {
            guard try blobSize(hash: part.sha256) == part.byteCount else { throw NotebookStorageError.blobHashMismatch }
            try enqueue(part.sha256)
          }
        case 5:
          let action = UUID(uuidString: row[3].text!)!
          let inverse = try readLifecycleInverseRoot(reference: .init(rootHash: hash, recordCount: Int(row[4].integer!)), actionID: action)
          for (ordinal, part) in inverse.parts.enumerated() { try enqueue(part, kind: 6, action: action, position: Int64(ordinal)) }
        case 6:
          let part = try readLifecycleInversePart(hash: hash, actionID: UUID(uuidString: row[3].text!)!, ordinal: Int(row[4].integer!))
          for record in part.records {
            for hash in [record.beforeHash, record.afterHash].compactMap({ $0 }) { try enqueue(hash, kind: 1, address: record.address) }
          }
        case 7:
          let action = UUID(uuidString: row[3].text!)!
          for purpose in [Int64(0), Int64(1)] {
            if let reference = try lifecycleInverseReceiptReference(hash: hash, actionID: action, purpose: purpose) {
              try enqueue(reference.rootHash, kind: 5, action: action, position: Int64(reference.recordCount))
            }
          }
        default: break
        }
        try plan.run("UPDATE work SET done=1 WHERE hash=? AND kind=?", [.text(hash), .integer(kind)])
      }
    }
    try plan.run("DROP TABLE work")
    try plan.run("DROP TABLE receipts")
    try plan.run("COMMIT")
    return .init(id: id, delivery: delivery, account: account, accountCursor: cursor)
  }

  public func beginCloudUpload(_ plan: NotebookCloudUploadPlan, account: String) throws -> Bool {
    try commandTransaction(advancesReadRevision: false) {
      try requireCloudAccount(account)
      let db = currentSQL!
      guard plan.account == account,
        let binding = try db.rows("SELECT cursor,generation FROM cloud_accounts WHERE account=?", [.text(account)]).first,
        binding[0].integer == Int64(plan.accountCursor), binding[1].text == plan.delivery.source.generation.uuidString.lowercased(),
        try db.rows("SELECT 1 FROM cloud_exports WHERE account=?", [.text(account)]).isEmpty,
        FileManager.default.fileExists(atPath: cloudPlanURL(plan.id).path) else { return false }
      try db.run("INSERT INTO cloud_exports(account,delivery,plan,ready,blob_cursor,record_cursor) VALUES(?,?,?,0,0,0)",
        [.text(account), .blob(try Self.storageEncoder.encode(plan.delivery)), .text(plan.id.uuidString.lowercased())])
      return true
    }
  }

  /// Returns nil for an already sealed export/no export. A crash before seal
  /// resumes the exact spool. A missing unexposed spool is safely rebuilt.
  public func pendingCloudUploadPlan(account: String) throws -> UUID? {
    try commandTransaction(advancesReadRevision: false) {
      try requireCloudAccount(account)
      guard let row = try currentSQL!.rows("SELECT plan FROM cloud_exports WHERE account=? AND ready=0", [.text(account)]).first else { return nil }
      guard let text = row[0].text, let id = UUID(uuidString: text),
        FileManager.default.fileExists(atPath: cloudPlanURL(id).path) else {
        try currentSQL!.run("DELETE FROM cloud_outbox WHERE account=?", [.text(account)])
        try currentSQL!.run("DELETE FROM cloud_exports WHERE account=?", [.text(account)])
        return nil
      }
      return id
    }
  }

  /// Read/validate one bounded unit on the upload worker, before FIFO admission.
  public func prepareCloudUploadBatch(_ id: UUID, account: String) throws -> NotebookCloudUploadBatch? {
    let state = try sqlRead { db -> [NotebookSQLValue]? in
      try requireCloudAccount(account)
      return try db.rows("SELECT delivery,blob_cursor,record_cursor FROM cloud_exports WHERE account=? AND plan=? AND ready=0",
        [.text(account), .text(id.uuidString.lowercased())]).first
    }
    guard let state else { return nil }
    try Task.checkCancellation()
    let plan = try NotebookSQLConnection(url: cloudPlanURL(id), writable: false)
    let blobCursor = state[1].integer!, recordCursor = state[2].integer!
    if let blob = try plan.rows("SELECT ordinal,hash,data FROM payloads WHERE ordinal>? ORDER BY ordinal LIMIT 1", [.integer(blobCursor)]).first {
      let data = blob[2].blob!, hash = blob[1].text!
      guard data.count <= 67_108_864, NotebookHexEncoding.encode(SHA256.hash(data: data)) == hash else { throw NotebookStorageError.blobHashMismatch }
      return .init(id: id, account: account, blobCursor: blobCursor, recordCursor: recordCursor,
        payload: .init(ordinal: blob[0].integer!, hash: hash, data: data), chunks: [], delivery: nil)
    }
    let records = try plan.rows("SELECT ordinal,id,hash,offset,total FROM outbox WHERE ordinal>? ORDER BY ordinal LIMIT 64", [.integer(recordCursor)])
    let chunks: [NotebookCloudUploadBatch.Chunk] = try records.map { row in
      let record = try NotebookCloudRecord.chunk(hash: row[2].text!, offset: row[3].integer!, totalBytes: row[4].integer!)
      guard record.id == row[1].text else { throw NotebookTransportError.invalidBlob }
      return .init(ordinal: row[0].integer!, record: record)
    }
    let delivery: (id: String, data: Data)?
    if chunks.isEmpty {
      let data = state[0].blob!, descriptor = try NotebookCloudRecord.delivery(JSONDecoder().decode(NotebookReplicationDelivery.self, from: data))
      delivery = (descriptor.id, data)
    } else { delivery = nil }
    return .init(id: id, account: account, blobCursor: blobCursor, recordCursor: recordCursor,
      payload: nil, chunks: chunks, delivery: delivery)
  }

  /// One prepared manifest part OR 64 chunk descriptors per writer admission.
  public func installCloudUploadBatch(_ batch: NotebookCloudUploadBatch, account: String) throws -> Bool {
    try commandTransaction(advancesReadRevision: false) {
      try requireCloudAccount(account)
      guard batch.account == account else { throw NotebookTransportError.invalidBlob }
      let db = currentSQL!
      guard let row = try db.rows("SELECT blob_cursor,record_cursor FROM cloud_exports WHERE account=? AND plan=? AND ready=0",
        [.text(account), .text(batch.id.uuidString.lowercased())]).first else { return true }
      guard row[0].integer == batch.blobCursor, row[1].integer == batch.recordCursor else { return false }
      if let payload = batch.payload {
        // The worker authenticated these immutable bytes before admission.
        try db.run("INSERT OR IGNORE INTO blobs(hash,data) VALUES(?,?)", [.text(payload.hash), .blob(payload.data)])
        try db.run("UPDATE cloud_exports SET blob_cursor=? WHERE account=?", [.integer(payload.ordinal), .text(account)])
        return false
      }
      for chunk in batch.chunks {
        let record = chunk.record
        try db.run("INSERT OR IGNORE INTO cloud_outbox(account,id,delivery,hash,offset,total) SELECT ?,?,NULL,?,?,? WHERE NOT EXISTS(SELECT 1 FROM cloud_uploaded WHERE account=? AND id=?)",
          [.text(account), .text(record.id), .text(record.hash!), .integer(record.offset), .integer(record.totalBytes), .text(account), .text(record.id)])
      }
      if let last = batch.chunks.last {
        try db.run("UPDATE cloud_exports SET record_cursor=? WHERE account=?", [.integer(last.ordinal), .text(account)])
        return false
      }
      guard let delivery = batch.delivery else { throw NotebookTransportError.invalidBlob }
      try db.run("INSERT OR IGNORE INTO cloud_outbox VALUES(?,?,?,NULL,0,0)", [.text(account), .text(delivery.id), .blob(delivery.data)])
      try db.run("UPDATE cloud_exports SET ready=1 WHERE account=?", [.text(account)])
      return true
    }
  }

  public func discardCloudUploadSpool(_ id: UUID) throws {
    let url = cloudPlanURL(id)
    for suffix in ["", "-journal", "-wal", "-shm"] {
      let file = URL(fileURLWithPath: url.path + suffix)
      if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
  }
}

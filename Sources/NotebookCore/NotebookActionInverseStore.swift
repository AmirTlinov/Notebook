import CryptoKit
import Foundation

/// A receipt names one immutable, workspace/action-bound stream. Historical
/// bodies stay in the existing blob store; this is not another content owner.
public struct NotebookLifecycleInverseReference: Codable, Equatable, Sendable {
  public let rootHash: String
  public let recordCount: Int
  public init(rootHash: String, recordCount: Int) { self.rootHash = rootHash; self.recordCount = recordCount }
}

struct NotebookLifecycleInverseRoot: Codable {
  let format: Int
  let workspaceID: UUID
  let actionID: UUID
  let recordCount: Int
  let parts: [String]
}

struct NotebookLifecycleInversePart: Codable {
  let format: Int
  let workspaceID: UUID
  let actionID: UUID
  let ordinal: Int
  let records: [NotebookActionRecordChange]
}

enum NotebookLifecycleInverseLimits {
  static let records = 8_388_608
  static let partRecords = 16_384
  static let parts = 512
  static let bytes = 64 * 1_024 * 1_024
}

extension NotebookStore {
  /// The caller has closed its content capture, but still owns the transaction
  /// that will publish the receipt. No receipt/context/local result is captured.
  func saveLifecycleInverse(actionID: UUID, captureID: UUID? = nil) throws -> NotebookLifecycleInverseReference? {
    guard let database = currentSQL, database.writable else { throw NotebookStorageError.readOnlyTransaction }
    guard database.activeActionRecordCapture == nil else { throw NotebookStorageError.invalidTransaction("open lifecycle capture") }
    let capturedActionID = captureID ?? actionID
    let count = try database.actionRecordCaptureCount(actionID: capturedActionID)
    guard count > 0 else { return nil }
    guard count <= NotebookLifecycleInverseLimits.records else { throw NotebookStorageError.limitExceeded("lifecycle_inverse_records") }
    let workspaceID = try lifecycleInverseWorkspaceID()
    var parts: [String] = [], records: [NotebookActionRecordChange] = [], bytes = 0, after = "", visited = 0
    func flush() throws {
      guard !records.isEmpty else { return }
      guard parts.count < NotebookLifecycleInverseLimits.parts else { throw NotebookStorageError.limitExceeded("lifecycle_inverse_parts") }
      let part = NotebookLifecycleInversePart(format: 1, workspaceID: workspaceID, actionID: actionID,
        ordinal: parts.count, records: records)
      let data = try Self.storageEncoder.encode(part)
      guard data.count <= NotebookLifecycleInverseLimits.bytes else { throw NotebookStorageError.limitExceeded("lifecycle_inverse_part_bytes") }
      parts.append(try database.putBlob(data)); records.removeAll(keepingCapacity: true); bytes = 0
    }
    while true {
      try Task.checkCancellation()
      let page = try database.actionRecordCapturePage(actionID: capturedActionID, after: after, limit: 256)
      if page.isEmpty { break }
      for record in page {
        try validateLifecycleInverseRecord(record)
        let size = try Self.storageEncoder.encode(record).count + 1
        // Reserve bounded framing/identity bytes without ever encoding an
        // oversized part. Address strings, too, are charged before appending.
        guard size <= NotebookLifecycleInverseLimits.bytes - 1_024 else { throw NotebookStorageError.limitExceeded("lifecycle_inverse_record_bytes") }
        if records.count == NotebookLifecycleInverseLimits.partRecords || bytes + size > NotebookLifecycleInverseLimits.bytes - 1_024 { try flush() }
        records.append(record); bytes += size; after = record.address; visited += 1
      }
    }
    try flush()
    guard visited == count else { throw NotebookStorageError.invalidTransaction("lifecycle capture count") }
    let root = NotebookLifecycleInverseRoot(format: 1, workspaceID: workspaceID, actionID: actionID, recordCount: count, parts: parts)
    return try .init(rootHash: database.putBlob(Self.storageEncoder.encode(root)), recordCount: count)
  }

  /// Bounded parts and individual immutable bodies, never a full owner JSON or
  /// a Swift array of all changed addresses. The surrounding transaction rolls
  /// back any visitor work if a later part fails admission.
  func visitLifecycleInverse(reference: NotebookLifecycleInverseReference, actionID: UUID,
    _ visit: (NotebookActionRecordChange) throws -> Void) throws {
    try readTransaction { store in
      let root = try store.readLifecycleInverseRoot(reference: reference, actionID: actionID)
      var previous = "", count = 0
      for (ordinal, hash) in root.parts.enumerated() {
        try Task.checkCancellation()
        let part = try store.readLifecycleInversePart(hash: hash, actionID: actionID, ordinal: ordinal)
        for record in part.records {
          guard previous.utf8.lexicographicallyPrecedes(record.address.utf8), count < root.recordCount else { throw NotebookStorageError.invalidTransaction("lifecycle inverse stream order") }
          for hash in [record.beforeHash, record.afterHash].compactMap({ $0 }) {
            let fragment = try store.readLifecycleInverseFragment(hash: hash, address: record.address,expandingInk:false)
            var orderWork = 0
            for root in try store.lifecycleInverseOrderRoots(fragment) {
              let node = try store.readPageOrderNode(root)
              orderWork += node.count
              guard orderWork <= 4_000_000 else { throw NotebookStorageError.limitExceeded("inverse_page_order_admission_work") }
              if fragment.collection == "pageOrders" {
                guard node.height == 0 || node.children.count >= 2 else { throw NotebookStorageError.invalidTransaction("inverse page order root height") }
              }
              try store.validateLifecycleInverseOrder(root)
            }
          }
          try visit(record); previous = record.address; count += 1
        }
      }
      guard count == root.recordCount else { throw NotebookStorageError.invalidTransaction("lifecycle inverse stream count") }
    }
  }

  func lifecycleInverseWorkspaceID() throws -> UUID {
    guard let id = try currentSQL!.rows("SELECT value FROM metadata WHERE key='workspace_id'").first?[0].text.flatMap(UUID.init(uuidString:)) else {
      throw NotebookStorageError.invalidTransaction("lifecycle inverse workspace")
    }
    return id
  }

  func lifecycleInverseBlob(_ hash: String, maximumBytes: Int) throws -> Data {
    guard NotebookPageOrderRegister.validHash(hash) else { throw NotebookStorageError.invalidTransaction("lifecycle inverse hash") }
    let database = currentSQL!
    guard let size = try database.rows("SELECT length(data) FROM blobs WHERE hash=?", [.text(hash)]).first?[0].integer else { throw NotebookStorageError.blobMissing(hash) }
    guard size > 0, size <= maximumBytes else { throw NotebookStorageError.limitExceeded("lifecycle_inverse_blob_bytes") }
    let data = try database.blob(hash)
    guard NotebookHexEncoding.encode(SHA256.hash(data: data)) == hash else { throw NotebookStorageError.blobHashMismatch }
    return data
  }

  func readLifecycleInverseRoot(reference: NotebookLifecycleInverseReference, actionID: UUID) throws -> NotebookLifecycleInverseRoot {
    let data = try lifecycleInverseBlob(reference.rootHash, maximumBytes: NotebookLifecycleInverseLimits.bytes)
    let root = try JSONDecoder().decode(NotebookLifecycleInverseRoot.self, from: data)
    guard root.format == 1, root.workspaceID == (try lifecycleInverseWorkspaceID()), root.actionID == actionID,
      (1...NotebookLifecycleInverseLimits.records).contains(root.recordCount), root.recordCount == reference.recordCount,
      (1...NotebookLifecycleInverseLimits.parts).contains(root.parts.count), root.parts.count <= root.recordCount,
      root.recordCount <= root.parts.count * NotebookLifecycleInverseLimits.partRecords,
      root.parts.allSatisfy(NotebookPageOrderRegister.validHash), Set(root.parts).count == root.parts.count,
      try Self.storageEncoder.encode(root) == data else { throw NotebookStorageError.invalidTransaction("lifecycle inverse root identity") }
    return root
  }

  func readLifecycleInversePart(hash: String, actionID: UUID, ordinal: Int) throws -> NotebookLifecycleInversePart {
    let data = try lifecycleInverseBlob(hash, maximumBytes: NotebookLifecycleInverseLimits.bytes)
    let part = try JSONDecoder().decode(NotebookLifecycleInversePart.self, from: data)
    guard part.format == 1, part.workspaceID == (try lifecycleInverseWorkspaceID()), part.actionID == actionID,
      part.ordinal == ordinal, (1...NotebookLifecycleInverseLimits.partRecords).contains(part.records.count),
      try Self.storageEncoder.encode(part) == data else { throw NotebookStorageError.invalidTransaction("lifecycle inverse part identity") }
    var previous = ""
    for record in part.records {
      try validateLifecycleInverseRecord(record)
      // Physical address keys use SQLite BINARY order, not Unicode collation.
      guard previous.utf8.lexicographicallyPrecedes(record.address.utf8) else { throw NotebookStorageError.invalidTransaction("lifecycle inverse part order") }
      previous = record.address
    }
    return part
  }

  func validateLifecycleInverseRecord(_ record: NotebookActionRecordChange) throws {
    let components = record.address.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
    guard components.count == 2, components[0].hasSuffix(".json"), !record.address.hasPrefix("/"),
      !record.address.contains(".."), !Self.localRecord(String(components[0])),
      !components[0].hasPrefix("collaboration/"), !components[0].hasPrefix("agent/"),
      record.beforeHash != record.afterHash,
      record.beforeHash.map(NotebookPageOrderRegister.validHash) ?? true,
      record.afterHash.map(NotebookPageOrderRegister.validHash) ?? true else { throw NotebookStorageError.invalidTransaction("lifecycle inverse record") }
  }

  func readLifecycleInverseFragment(hash: String, address: String? = nil,expandingInk:Bool = true) throws -> NotebookStoredFragment {
    let data = try lifecycleInverseBlob(hash, maximumBytes: 256 * 1_024 * 1_024)
    let fragment = try currentSQL!.decodedStoredFragment(from:data,expandingInk:expandingInk)
    try validateLifecycleInverseRecord(.init(address: fragment.address, beforeHash: hash, afterHash: nil))
    guard address.map({ fragment.address.utf8.elementsEqual($0.utf8) }) ?? true,
      fragment.address.hasPrefix(fragment.file + "#"), !fragment.file.contains("#"),
      fragment.position >= 0, fragment.value.isValid else { throw NotebookStorageError.invalidTransaction("lifecycle inverse fragment identity") }
    if let parent = fragment.parent {
      guard parent.hasPrefix(fragment.file + "#"), fragment.address.hasPrefix(parent + "/"), !fragment.collection.isEmpty else {
        throw NotebookStorageError.invalidTransaction("lifecycle inverse fragment parent")
      }
    } else {
      guard fragment.address == fragment.file + "#", fragment.collection.isEmpty, fragment.member.isEmpty, fragment.position == 0 else {
        throw NotebookStorageError.invalidTransaction("lifecycle inverse fragment root")
      }
    }
    return fragment
  }

  /// Only the actual physical page-order owner declares canonical dependencies.
  /// A hash-looking string in another record has no such interpretation.
  func lifecycleInverseOrderRoots(_ fragment: NotebookStoredFragment) throws -> [String] {
    guard fragment.file == "workspace.json" else { return [] }
    if fragment.collection == "pageOrders" {
      guard fragment.parent == "workspace.json#", fragment.position == 0,
        UUID(uuidString: fragment.member)?.uuidString.lowercased() == fragment.member,
        fragment.address == "workspace.json#/pageOrders/@" + fragment.member,
        fragment.collections.isEmpty else { throw NotebookStorageError.invalidTransaction("inverse page order address") }
      let order = try fragment.value.decode(NotebookPageOrderRegister.self)
      try order.validate()
      return Array(Set([order.visibleRoot] + order.heads.map(\.valueRoot))).sorted()
    }
    if fragment.collection == "pageOrderNodes" {
      let node = try fragment.value.decode(NotebookPageOrderNode.self)
      guard fragment.parent == "workspace.json#", fragment.position == 0, fragment.collections.isEmpty,
        fragment.address == "workspace.json#/pageOrderNodes/@" + fragment.member,
        try node.hash == fragment.member else { throw NotebookStorageError.invalidTransaction("inverse page order node address") }
      return [fragment.member]
    }
    return []
  }

  /// Exact immutable hash admission, never an inference from accepted children.
  /// This is the existing typed node cache and its retained blob closure. As in
  /// the live order writer, a cache hit is not a fresh physical scrub of every
  /// previously admitted descendant; the root bytes themselves are rechecked.
  func lifecycleInverseOrderIsAdmitted(_ hash: String, node: NotebookPageOrderNode) throws -> Bool {
    guard let row = try currentSQL!.rows("SELECT height,count FROM page_order_nodes WHERE hash=?", [.text(hash)]).first else { return false }
    guard row[0].integer == Int64(node.height), row[1].integer == Int64(node.count) else {
      throw NotebookStorageError.invalidTransaction("inverse page order admitted metadata")
    }
    return true
  }

  /// Depth is at most four. Strictly falling heights prove acyclicity without
  /// retaining an all-node Set; TEMP identities reject duplicates across leaves.
  func validateLifecycleInverseOrder(_ root: String) throws {
    let database = currentSQL!, rootNode = try readPageOrderNode(root)
    if try lifecycleInverseOrderIsAdmitted(root, node: rootNode) { return }
    try database.run("CREATE TEMP TABLE IF NOT EXISTS lifecycle_inverse_order_pages(id TEXT PRIMARY KEY) WITHOUT ROWID")
    try database.run("DELETE FROM lifecycle_inverse_order_pages")
    var nodes = 0, bytes = 0
    func walk(_ hash: String, height: Int? = nil) throws -> Int {
      try Task.checkCancellation()
      let node = try height == nil ? rootNode : readPageOrderNode(hash)
      nodes += 1; bytes += try node.canonicalData().count
      guard nodes <= NotebookPageOrderVector.maximumNodes, bytes <= NotebookPageOrderVector.maximumBytes,
        height == nil || node.height == height else { throw NotebookStorageError.invalidTransaction("inverse page order closure") }
      for page in node.pages { try database.run("INSERT INTO lifecycle_inverse_order_pages(id) VALUES(?)", [.text(page.uuidString.lowercased())]) }
      if node.height > 0 {
        var total = 0
        let capacity = (0..<node.height).reduce(1) { value, _ in value * 32 }
        for (index, child) in node.children.enumerated() {
          let count = try walk(child, height: node.height - 1)
          guard count > 0, index == node.children.count - 1 || count == capacity else { throw NotebookStorageError.invalidTransaction("inverse page order packing") }
          total += count
        }
        guard total == node.count else { throw NotebookStorageError.invalidTransaction("inverse page order count") }
      }
      // A new root must walk every identity, even under accepted children:
      // two individually valid subtrees may overlap. Only a completed subtree
      // gets an intrinsic proof; this never publishes a content record.
      if database.writable {
        try database.run("INSERT OR IGNORE INTO page_order_nodes(hash,height,count) VALUES(?,?,?)",
          [.text(hash), .integer(Int64(node.height)), .integer(Int64(node.count))])
      }
      return node.count
    }
    _ = try walk(root)
    try database.run("DELETE FROM lifecycle_inverse_order_pages")
  }
}

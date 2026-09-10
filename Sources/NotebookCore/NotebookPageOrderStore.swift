import CSQLite
import CryptoKit
import Foundation

extension NotebookStore {
  func readPageOrder(_ itemID: UUID) throws -> NotebookPageOrderRegister {
    let address = "workspace.json#/pageOrders/@" + itemID.uuidString.lowercased()
    guard let value = try storedFragments(address: address, descendants: false).first?.value else {
      throw NotebookStorageError.corruptRecord(address)
    }
    let order = try value.decode(NotebookPageOrderRegister.self)
    try order.validate(); return order
  }

  func readPageOrderNode(_ hash: String) throws -> NotebookPageOrderNode {
    guard NotebookPageOrderRegister.validHash(hash), let database = currentSQL else {
      throw NotebookStorageError.invalidTransaction("page order node read")
    }
    guard let byteCount = try database.rows("SELECT length(data) FROM blobs WHERE hash=?", [.text(hash)]).first?[0].integer else {
      throw NotebookStorageError.blobMissing(hash)
    }
    guard byteCount <= NotebookPageOrderVector.maximumNodeBytes else { throw NotebookStorageError.limitExceeded("page_order_node_bytes") }
    let data = try database.blob(hash)
    guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == hash else { throw NotebookStorageError.blobHashMismatch }
    let node = try JSONDecoder().decode(NotebookPageOrderNode.self, from: data)
    guard try node.canonicalData() == data, try node.hash == hash else { throw NotebookStorageError.blobHashMismatch }
    try node.validate(); return node
  }

  @discardableResult
  func writePageOrderNode(_ node: NotebookPageOrderNode) throws -> String {
    guard let database = currentSQL, database.writable else { throw NotebookStorageError.readOnlyTransaction }
    let hash = try node.hash
    try writeFragment(.init(address: "workspace.json#/pageOrderNodes/@" + hash, file: "workspace.json",
      parent: "workspace.json#", collection: "pageOrderNodes", member: hash, position: 0,
      value: try .encode(node), collections: []), database: database)
    return hash
  }

  func writePageOrder(_ order: NotebookPageOrderRegister, itemID: UUID) throws {
    guard let database = currentSQL, database.writable else { throw NotebookStorageError.readOnlyTransaction }
    try order.validate()
    let id = itemID.uuidString.lowercased()
    try writeFragment(.init(address: "workspace.json#/pageOrders/@" + id, file: "workspace.json",
      parent: "workspace.json#", collection: "pageOrders", member: id, position: 0,
      value: try .encode(order), collections: []), database: database)
  }

  /// Only new roots need closure verification. Existing accepted nodes are
  /// immutable; append verifies its changed right spine, not an old prefix.
  func validateChangedPageOrders(database: NotebookSQLConnection) throws {
    var visiting = Set<String>(), loaded = Set<String>(), work = 0, bytes = 0
    try database.visitOwners(.orderRoot) { root in
      var stack: [(String, Bool)] = [(root, false)]
      while let (hash, finishing) = stack.popLast() {
        if loaded.contains(hash) { continue }
        if try !database.rows("SELECT 1 FROM page_order_nodes WHERE hash=?", [.text(hash)]).isEmpty {
          loaded.insert(hash); continue
        }
        let node = try readPageOrderNode(hash)
        if !finishing {
          guard visiting.insert(hash).inserted else { throw NotebookStorageError.invalidTransaction("page order node cycle") }
          work += 1; bytes += try node.canonicalData().count
          guard work <= 131_072, bytes <= 64 * 1024 * 1024 else { throw NotebookStorageError.limitExceeded("page_order_dependencies") }
          stack.append((hash, true))
          for child in node.children.reversed() where !loaded.contains(child) { stack.append((child, false)) }
        } else {
          if node.height > 0 {
            var total = 0
            for (offset, child) in node.children.enumerated() {
              guard let row = try database.rows("SELECT height,count FROM page_order_nodes WHERE hash=?", [.text(child)]).first,
                row[0].integer == Int64(node.height - 1), let count = row[1].integer, count > 0 else {
                throw NotebookStorageError.invalidTransaction("page order child height")
              }
              let capacity = (0..<node.height).reduce(1) { value, _ in value * 32 }
              guard offset == node.children.count - 1 || count == capacity else { throw NotebookStorageError.invalidTransaction("page order packing") }
              total += Int(count)
            }
            guard total == node.count else { throw NotebookStorageError.invalidTransaction("page order node count") }
          }
          try database.run("INSERT OR IGNORE INTO page_order_nodes(hash,height,count) VALUES(?,?,?)", [.text(hash), .integer(Int64(node.height)), .integer(Int64(node.count))])
          loaded.insert(hash); visiting.remove(hash)
        }
      }
    }
    try database.visitOwners(.pageOrder) { item in
      let itemAddress = "workspace.json#/items/@" + item
      guard let kind = try storedFragments(address: itemAddress, descendants: false).first?.value["kind"]?.string else { return }
      guard kind == "notebook", let id = UUID(uuidString: item) else { throw NotebookStorageError.invalidTransaction("page order owner") }
      let order = try readPageOrder(id), node = try readPageOrderNode(order.visibleRoot)
      guard try node.count == pageCount(in: id), node.height == 0 || node.children.count >= 2 else {
        throw NotebookStorageError.invalidTransaction("page order visible count")
      }
      let maximum = try database.rows("SELECT MAX(position) FROM records INDEXED BY record_order WHERE parent=? AND collection='pageIDs'", [.text(itemAddress)]).first?[0].integer
      guard maximum == Int64(node.count - 1) else { throw NotebookStorageError.invalidTransaction("noncontiguous page order") }
      if try database.hasOwner(.capturedPageOrder, item) {
        try NotebookPageOrderVector.visitChangedPages(from: database.ownerValue(.capturedPageOrder, item), to: order.visibleRoot,
          read: { try readPageOrderNode($0) }, visit: { position, page in
            let address = itemAddress + "/pageIDs/@" + page.uuidString.lowercased()
            guard try database.rows("SELECT position FROM records WHERE address=?", [.text(address)]).first?[0].integer == Int64(position) else {
              throw NotebookStorageError.invalidTransaction("page order position")
            }
          })
      }
    }
    try database.visitOwners(.pageMembership) { address in
      guard let row = try database.rows("SELECT parent,member,position FROM records WHERE address=?", [.text(address)]).first,
        let item = row[0].text?.components(separatedBy: "@").last.flatMap(UUID.init(uuidString:)),
        let page = row[1].text.flatMap(UUID.init(uuidString:)), let position = row[2].integer else { return }
      let order = try readPageOrder(item)
      guard try NotebookPageOrderVector.pageID(at: Int(position), in: order.visibleRoot, read: { try readPageOrderNode($0) }) == page else {
        throw NotebookStorageError.invalidTransaction("page membership position")
      }
    }
  }

  /// Dependency discovery is persisted and paged; an incremental manifest
  /// names its roots, not a copy of every node in the notebook's old value.
  func missingPageOrderBlobs(manifestHash: String, limit: Int) throws -> [String] {
    let database = currentSQL!
    let totals = try database.rows("SELECT order_node_count,order_node_bytes FROM manifests WHERE hash=?", [.text(manifestHash)]).first!
    var count = Int(totals[0].integer!), bytes = Int(totals[1].integer!), work = 0
    func persistTotals() throws {
      try database.run("UPDATE manifests SET order_node_count=?,order_node_bytes=? WHERE hash=?", [.integer(Int64(count)), .integer(Int64(bytes)), .text(manifestHash)])
    }
    while true {
      let pending = try database.rows("SELECT hash FROM manifest_order_nodes WHERE manifest_hash=? AND expanded=0 ORDER BY hash LIMIT 256", [.text(manifestHash)]).compactMap { $0[0].text }
      if pending.isEmpty { try persistTotals(); return [] }
      var missing: [String] = []
      for hash in pending {
        guard try !database.rows("SELECT 1 FROM blobs WHERE hash=?", [.text(hash)]).isEmpty else {
          missing.append(hash); if missing.count == limit { try persistTotals(); return missing }; continue
        }
        let node = try readPageOrderNode(hash)
        bytes += try node.canonicalData().count
        guard bytes <= 64 * 1024 * 1024 else { throw NotebookStorageError.limitExceeded("page_order_dependency_bytes") }
        let accepted = try !database.rows("SELECT 1 FROM page_order_nodes WHERE hash=?", [.text(hash)]).isEmpty
        if !accepted {
          for child in node.children {
            try database.run("INSERT OR IGNORE INTO manifest_order_nodes(manifest_hash,hash) VALUES(?,?)", [.text(manifestHash), .text(child)])
            count += Int(sqlite3_changes64(database.handle))
            guard count <= 131_072 else { throw NotebookStorageError.limitExceeded("page_order_dependency_nodes") }
          }
        }
        try database.run("UPDATE manifest_order_nodes SET expanded=1 WHERE manifest_hash=? AND hash=?", [.text(manifestHash), .text(hash)])
        work += 1
        guard work <= 131_072 else { throw NotebookStorageError.limitExceeded("page_order_dependencies") }
      }
      if !missing.isEmpty { try persistTotals(); return missing }
    }
  }

  func validateIncomingPageOrderValues(_ roots: [String]) throws {
    var cache: [String: NotebookPageOrderNode] = [:], bytes = 0, work = 0
    func read(_ hash: String) throws -> NotebookPageOrderNode {
      if let node = cache[hash] { return node }
      let node = try readPageOrderNode(hash)
      bytes += try node.canonicalData().count
      guard cache.count < 131_072, bytes <= 64 * 1024 * 1024 else { throw NotebookStorageError.limitExceeded("page_order_admission_nodes") }
      cache[hash] = node; return node
    }
    for root in Set(roots) {
      let count = try read(root).count
      guard count <= 4_000_000 - work else { throw NotebookStorageError.limitExceeded("page_order_admission_work") }
      work += count
      _ = try NotebookPageOrderVector.materialize(root, read: read)
    }
  }

  func installPageOrderDependencies(manifestHash: String) throws {
    let database = currentSQL!
    // A dependency is still only immutable data here. Typed merge and all
    // receipt/ownership checks must pass before the surrounding SQL commit.
    for row in try database.rows("SELECT d.hash FROM manifest_order_nodes d LEFT JOIN records r ON r.address='workspace.json#/pageOrderNodes/@'||d.hash WHERE d.manifest_hash=? AND r.address IS NULL ORDER BY d.hash", [.text(manifestHash)]) {
      _ = try writePageOrderNode(readPageOrderNode(row[0].text!))
    }
  }
}

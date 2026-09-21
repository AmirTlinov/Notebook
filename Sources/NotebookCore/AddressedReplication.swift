import Foundation

/// An indexed view of one incoming transaction. This is not a second merger:
/// values still go through their existing typed causal owners and row writer.
struct NotebookIncomingRecords {
  let store: NotebookStore
  let manifestHash: String
  var database: NotebookSQLConnection { store.currentSQL! }

  func visit(from lower: String, to upper: String, _ body: (String) throws -> Void) throws {
    var cursor = lower
    var inclusive = true
    while true {
      let rows = try database.rows("SELECT address FROM manifest_records WHERE manifest_hash=? AND address\(inclusive ? ">=" : ">")? AND address<? ORDER BY address LIMIT 64",
        [.text(manifestHash), .text(cursor), .text(upper)])
      if rows.isEmpty { return }
      for row in rows { cursor = row[0].text!; try body(cursor) }
      inclusive = false
    }
  }

  func mutation(_ address: String) throws -> [NotebookSQLValue]? {
    try database.rows("SELECT blob_hash FROM manifest_records WHERE manifest_hash=? AND address=?",
      [.text(manifestHash), .text(address)]).first
  }

  func fragment(_ address: String) throws -> NotebookStoredFragment? {
    guard let row = try mutation(address), let hash = row[0].text else { return nil }
    let value = try database.decodedStoredFragment(from:database.blob(hash))
    guard value.address == address, value.file + "#" == String(address.prefix(through: address.firstIndex(of: "#")!)),
      value.position >= 0, value.value.isValid else { throw NotebookStorageError.invalidTransaction("fragment identity") }
    return value
  }

  func previous(_ address: String) throws -> NotebookStoredFragment? {
    try store.storedFragments(address: address, descendants: false).first
  }

  func candidate(_ address: String) throws -> NotebookStoredFragment? {
    try mutation(address) == nil ? previous(address) : fragment(address)
  }

  func overlay(_ address: String, previous: [NotebookStoredFragment]) throws -> [NotebookStoredFragment] {
    var rows = Dictionary(uniqueKeysWithValues: previous.map { ($0.address, $0) })
    if try mutation(address) != nil { rows[address] = try fragment(address) }
    try visit(from: address + "/", to: address + "0") { key in rows[key] = try fragment(key) }
    return Array(rows.values)
  }

  func field(parent: String, collection: String, key: String, delivered: Bool) throws -> ContentFieldVersion? {
    let address = parent + "/" + collection + "/@" + fieldKey([key])
    if delivered, let mutation = try mutation(address), mutation[0].text == nil {
      throw NotebookStorageError.invalidTransaction("causal fields are retained")
    }
    guard let row = try delivered ? candidate(address) : previous(address) else { return nil }
    let version = try row.value.decode(ContentFieldVersion.self)
    guard key.utf8.count <= 2048, version.isValid,
      row == NotebookStoredFragment(address: address, file: row.file, parent: parent,
        collection: collection, member: key, position: 0, value: try .encode(version), collections: []) else {
      throw NotebookStorageError.corruptRecord(address)
    }
    return version
  }

  @discardableResult
  func publishField(file: String, parent: String, collection: String, key: String, version: ContentFieldVersion) throws -> Bool {
    let address = parent + "/" + collection + "/@" + fieldKey([key])
    let allocated = try previous(address) == nil
    try store.writeFragment(.init(address: address, file: file, parent: parent, collection: collection,
      member: key, position: 0, value: .encode(version), collections: []), database: database)
    return allocated
  }

  func validateFieldCount(parent: String, collection: String, maximum: Int = CollaborativeContent.maximumFieldCount) throws {
    let count = try database.rows("SELECT count(*) FROM records WHERE parent=? AND collection=?", [.text(parent), .text(collection)]).first![0].integer!
    guard count <= maximum else { throw NotebookStorageError.limitExceeded("causal_fields") }
  }

  func publishSubtree(_ value: JSONValue?, old: [NotebookStoredFragment], file: String,
    address: String, parent: String, collection: String, member: String, position: Int) throws {
    guard let value else { try store.removeFragment(address, database: database); return }
    let rows = try NotebookRecordCodec.encode(value, file: file, address: address, parent: parent,
      collection: collection, member: member, position: position)
    let retained = Set(rows.map(\.address))
    for row in rows { try store.writeFragment(row, database: database) }
    for row in old where !retained.contains(row.address) { try store.removeFragment(row.address, database: database) }
  }

  /// A member edit never reads another member's body, order, or retired clocks.
  /// A real sequence edit reads ID/slot metadata, then only rewrites changed slots.
  /// All field conflict decisions remain in CollaborativeContent.merge.
  func mergeElements(file: String, parent: String, collection: String, fields: String,
    localStamp: VersionStamp?, incomingStamp: VersionStamp,
    validate: (JSONValue) throws -> Void) throws -> Bool {
    let memberPrefix = parent + "/" + collection + "/@", fieldPrefix = parent + "/" + fields + "/@"
    let orderKey = "elements/order", orderAddress = fieldPrefix + fieldKey([orderKey])
    let orderChanged = try mutation(orderAddress) != nil
    let oldOrderRows = try orderChanged ? database.rows("SELECT member,position FROM records WHERE parent=? AND collection=? ORDER BY position,member", [.text(parent), .text(collection)]) : []
    let oldOrder = oldOrderRows.map { $0[0].text! }
    var candidateSlots = Dictionary(uniqueKeysWithValues: oldOrderRows.map { ($0[0].text!, Int($0[1].integer!)) })
    let oldOrderVersion = try field(parent: parent, collection: fields, key: orderKey, delivered: false)
    let nextOrderVersion = try field(parent: parent, collection: fields, key: orderKey, delivered: true)
    try database.run("CREATE TEMP TABLE IF NOT EXISTS replication_elements(scope TEXT,member TEXT,PRIMARY KEY(scope,member))")
    try database.run("DELETE FROM replication_elements WHERE scope=?", [.text(parent)])
    func include(_ member: String) throws {
      guard !member.isEmpty, member.utf16.count <= 120, collaborationIdentity(member) == member else {
        throw NotebookStorageError.invalidTransaction("element identity")
      }
      try database.run("INSERT OR IGNORE INTO replication_elements VALUES(?,?)", [.text(parent), .text(member)])
    }
    try visit(from: memberPrefix, to: parent + "/" + collection + "0") { address in
      let escaped = String(address.dropFirst(memberPrefix.count).split(separator: "/", omittingEmptySubsequences: false)[0])
      let member = unescape(escaped)
      guard fieldKey([member]) == escaped else { throw NotebookStorageError.invalidTransaction("element address") }
      try include(member)
    }
    try visit(from: fieldPrefix, to: parent + "/" + fields + "0") { address in
      let key = unescape(String(address.dropFirst(fieldPrefix.count)))
      _ = try field(parent: parent, collection: fields, key: key, delivered: true)
      let parts = key.components(separatedBy: "/")
      if parts.count >= 3, parts[0] == "elements" { try include(unescape(parts[1])) }
    }
    var cursor = "", differsFromNewest = false, allocatedFields = false
    func put(_ key: String, _ version: ContentFieldVersion) throws {
      allocatedFields = try publishField(file: file, parent: parent, collection: fields, key: key, version: version) || allocatedFields
    }
    while true {
      let members = try database.rows("SELECT member FROM replication_elements WHERE scope=? AND member>? ORDER BY member LIMIT 64", [.text(parent), .text(cursor)])
      if members.isEmpty { break }
      for row in members {
        let member = row[0].text!; cursor = member
        let address = memberPrefix + fieldKey([member])
        let oldRows = try store.storedFragments(address: address)
        let nextRows = try overlay(address, previous: oldRows)
        func content(_ rows: [NotebookStoredFragment]) throws -> JSONValue? {
          guard let header = rows.first(where: { $0.address == address }) else { return nil }
          let value = try NotebookRecordCodec.decode(rows, root: address)
          try validate(value)
          guard value.memberIdentity == member else { throw NotebookStorageError.corruptRecord(address) }
          let canonical = try NotebookRecordCodec.encode(value, file: file, address: address, parent: parent,
            collection: collection, member: member, position: header.position)
          guard Dictionary(uniqueKeysWithValues: canonical.map { ($0.address, $0) }) == Dictionary(uniqueKeysWithValues: rows.map { ($0.address, $0) }) else {
            throw NotebookStorageError.corruptRecord(address)
          }
          return value
        }
        let old = try content(oldRows), next = try content(nextRows)
        let a = JSONValue.object(["elements": .array(old.map { [$0] } ?? [])])
        let b = JSONValue.object(["elements": .array(next.map { [$0] } ?? [])])
        var keys = Set(contentFields(a).keys).union(contentFields(b).keys)
        let keyPrefix = fieldPrefix + fieldKey([fieldKey(["elements", member]) + "/"])
        for row in try database.rows("SELECT member FROM records WHERE address>=? AND address<?", [.text(keyPrefix), .text(keyPrefix + "\u{10ffff}")]) { keys.insert(row[0].text!) }
        try visit(from: keyPrefix, to: keyPrefix + "\u{10ffff}") { keyAddress in keys.insert(unescape(String(keyAddress.dropFirst(fieldPrefix.count)))) }
        keys.remove(orderKey)
        var local: [String: ContentFieldVersion] = [:], incoming: [String: ContentFieldVersion] = [:]
        for key in keys {
          local[key] = try field(parent: parent, collection: fields, key: key, delivered: false)
          incoming[key] = try field(parent: parent, collection: fields, key: key, delivered: true)
        }
        let result = try CollaborativeContent.merge(local: a, incoming: b,
          localState: .init(fields: local), incomingState: .init(fields: incoming),
          localStamp: localStamp ?? incomingStamp, incomingStamp: incomingStamp, includeOrder: false)
        let resolved = result.value["elements"]?.array.first
        if let resolved { try validate(resolved) }
        let newest = localStamp.map { $0 > incomingStamp ? old : next } ?? next
        differsFromNewest = differsFromNewest || resolved != newest
        let previousPosition = oldRows.first { $0.address == address }?.position
        let deliveredPosition = nextRows.first { $0.address == address }?.position
        if orderChanged { candidateSlots[member] = deliveredPosition }
        let position = try previousPosition ?? Int(database.rows("SELECT COALESCE(MAX(position),-1)+1 FROM records WHERE parent=? AND collection=?", [.text(parent), .text(collection)]).first![0].integer!)
        try publishSubtree(resolved, old: oldRows, file: file, address: address, parent: parent,
          collection: collection, member: member, position: position)
        for (key, version) in result.state.fields where key != orderKey {
          try put(key, version)
        }
      }
    }
    // Keep historical, non-element metadata, without reconstructing its owner.
    try visit(from: fieldPrefix, to: parent + "/" + fields + "0") { address in
      let key = unescape(String(address.dropFirst(fieldPrefix.count))), parts = key.components(separatedBy: "/")
      guard key != orderKey, !(parts.count >= 3 && parts[0] == "elements") else { return }
      guard let next = try field(parent: parent, collection: fields, key: key, delivered: true) else { throw NotebookStorageError.corruptRecord(address) }
      let old = try field(parent: parent, collection: fields, key: key, delivered: false)
      try put(key, old.map { try $0.joining(next) } ?? next)
    }
    if orderChanged {
      let candidateOrder = candidateSlots.keys.sorted { candidateSlots[$0] == candidateSlots[$1] ? $0 < $1 : candidateSlots[$0]! < candidateSlots[$1]! }
      let av = oldOrderVersion ?? .init(stamp: localStamp ?? incomingStamp, human: true)
      let bv = nextOrderVersion ?? .init(stamp: incomingStamp, human: true)
      let result = try localStamp.map { _ in try av.resolving(value: .array(oldOrder.map(JSONValue.string)), with: bv, incomingValue: .array(candidateOrder.map(JSONValue.string))) }
      let preferred = result?.value?.array.compactMap(\.string) ?? candidateOrder
      let stored = try database.rows("SELECT member,position FROM records WHERE parent=? AND collection=? ORDER BY position,member", [.text(parent), .text(collection)])
      let order = contentMemberOrder(preferred: preferred, escapedMembers: stored.map { fieldKey([$0[0].text!]) })
      let positions = Dictionary(uniqueKeysWithValues: stored.map { ($0[0].text!, Int($0[1].integer!)) })
      for (position, member) in order.enumerated() where positions[member] != position {
        let address = memberPrefix + fieldKey([member])
        let row = try previous(address)!
        try store.writeFragment(row.replacing(value: row.value, position: position), database: database)
      }
      let version = result?.version ?? bv
      try put(orderKey, order == preferred ? version : version.retainingValue(.array(preferred.map(JSONValue.string))))
      let newest = localStamp.map { $0 > incomingStamp ? oldOrder : candidateOrder } ?? candidateOrder
      differsFromNewest = differsFromNewest || order != newest
    }
    try database.run("DELETE FROM replication_elements WHERE scope=?", [.text(parent)])
    if allocatedFields { try validateFieldCount(parent: parent, collection: fields) }
    return differsFromNewest
  }

  private func unescape(_ string: String) -> String {
    string.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
  }
}

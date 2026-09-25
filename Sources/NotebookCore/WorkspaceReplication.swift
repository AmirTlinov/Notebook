import Foundation

extension NotebookStore {
  /// Catalog admission visits changed identities. A title/placement edit does
  /// not hydrate the catalog, page vectors, or the content of other items.
  func applyReplicatedWorkspace(manifestHash: String, declaredOrderRoots: Set<String>) throws {
    let incoming = NotebookIncomingRecords(store: self, manifestHash: manifestHash), database = currentSQL!
    let file = "workspace.json", root = file + "#", prefix = root + "/items/@"
    let fields = "collaboration/fields", fieldPrefix = root + "/" + fields + "/@"
    let oldRoot = try incoming.previous(root)
    guard let nextRoot = try incoming.candidate(root), nextRoot.parent == nil,
      nextRoot.collection.isEmpty, nextRoot.member.isEmpty, nextRoot.position == 0,
      nextRoot.value["format"] == .number(Double(WorkspaceIndex.formatVersion)),
      nextRoot.value["isProjection"] == .bool(false),
      Set(nextRoot.value.object.keys) == ["format", "rootBoardID", "stamp", "collaboration", "isProjection"],
      nextRoot.value["collaboration"] == .object([:]),
      let rootID = try nextRoot.value["rootBoardID"]?.decode(UUID.self), rootID.uuidString != "00000000-0000-0000-0000-000000000000",
      oldRoot == nil || oldRoot?.value["rootBoardID"] == nextRoot.value["rootBoardID"],
      let nextStamp = try nextRoot.value["stamp"]?.decode(VersionStamp.self), nextStamp.counter <= VersionStamp.maximumCounter,
      nextRoot.collections == [NotebookStoredCollection(path: ["collaboration", "fields"], kind: .dictionary),
        .init(path: ["items"], kind: .array), .init(path: ["pageOrderNodes"], kind: .dictionary), .init(path: ["pageOrders"], kind: .dictionary)] else {
      throw NotebookStorageError.invalidTransaction("workspace header")
    }
    let oldStamp = try oldRoot?.value["stamp"]?.decode(VersionStamp.self)
    let frontier = max(oldStamp ?? nextStamp, nextStamp)
    var differsFromNewest = false
    try database.run("CREATE TEMP TABLE IF NOT EXISTS replication_catalog_items(id TEXT PRIMARY KEY)")
    try database.run("CREATE TEMP TABLE IF NOT EXISTS replication_catalog_fields(key TEXT PRIMARY KEY,allocated INTEGER NOT NULL)")
    try database.run("DELETE FROM replication_catalog_items")
    try database.run("DELETE FROM replication_catalog_fields")
    func include(_ id: String) throws {
      guard let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id, uuid != rootID else {
        throw NotebookStorageError.invalidTransaction("catalog item address")
      }
      try database.run("INSERT OR IGNORE INTO replication_catalog_items VALUES(?)", [.text(id)])
    }
    func put(_ key: String, _ version: ContentFieldVersion) throws {
      let allocated = try incoming.publishField(file: file, parent: root, collection: fields, key: key, version: version)
      try database.run("INSERT INTO replication_catalog_fields VALUES(?,?) ON CONFLICT(key) DO UPDATE SET allocated=MAX(allocated,excluded.allocated)", [.text(key), .integer(allocated ? 1 : 0)])
    }
    func resolve(_ key: String, _ old: JSONValue?, _ next: JSONValue?) throws -> JSONValue? {
      guard let b = try incoming.field(parent: root, collection: fields, key: key, delivered: true) else { return old }
      guard let a = try incoming.field(parent: root, collection: fields, key: key, delivered: false) else {
        try put(key, b); return next
      }
      let result = try a.resolving(value: old, with: b, incomingValue: next)
      try put(key, result.version); return result.value
    }
    func unescape(_ value: String) -> String { value.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~") }
    try incoming.visit(from: root + "/", to: file + "$") { address in
      if address.hasPrefix(prefix) {
        let parts = address.dropFirst(prefix.count).components(separatedBy: "/")
        guard parts.count == 1 || (parts.count == 3 && parts[1] == "pageIDs" && parts[2].hasPrefix("@")) else { throw NotebookStorageError.invalidTransaction("catalog membership address") }
        try include(parts[0])
      } else if address.hasPrefix(fieldPrefix) {
        let key = unescape(String(address.dropFirst(fieldPrefix.count)))
        _ = try incoming.field(parent: root, collection: fields, key: key, delivered: true)
        let parts = key.components(separatedBy: "/")
        if parts.count >= 3, parts[0] == "items" { try include(parts[1]) }
      } else if address.hasPrefix(root + "/pageOrders/@") {
        try include(String(address.dropFirst((root + "/pageOrders/@").count)))
      } else if address.hasPrefix(root + "/pageOrderNodes/@") {
        guard let row = try incoming.fragment(address), row.parent == root, row.collection == "pageOrderNodes",
          row.position == 0, row.collections.isEmpty, address == root + "/pageOrderNodes/@" + row.member,
          try row.value.decode(NotebookPageOrderNode.self).hash == row.member else { throw NotebookStorageError.blobHashMismatch }
        if let previous = try incoming.previous(address) {
          guard previous == row else { throw NotebookStorageError.blobHashMismatch }
        } else { try writeFragment(row, database: database) }
      } else { throw NotebookStorageError.invalidTransaction("catalog address") }
    }
    let changesOrder = try incoming.mutation(fieldPrefix + fieldKey(["items/order"])) != nil
    let oldOrderRows = try changesOrder ? database.rows("SELECT member,position FROM records WHERE parent=? AND collection='items' ORDER BY position,member", [.text(root)]) : []
    let oldOrder = oldOrderRows.map { $0[0].text! }
    var candidateSlots = Dictionary(uniqueKeysWithValues: oldOrderRows.map { ($0[0].text!, Int($0[1].integer!)) })
    var after = ""
    while true {
      let ids = try database.rows("SELECT id FROM replication_catalog_items WHERE id>? ORDER BY id LIMIT 64", [.text(after)])
      if ids.isEmpty { break }
      for row in ids {
        let id = row[0].text!, uuid = UUID(uuidString: id)!, address = prefix + id; after = id
        let old = try incoming.previous(address), next = try incoming.candidate(address)
        if changesOrder { candidateSlots[id] = next?.position }
        let existsKey = fieldKey(["items", id, "exists"])
        let live = try resolve(existsKey, .bool(old != nil), .bool(next != nil)) == .bool(true)
        if !live {
          differsFromNewest = differsFromNewest || ((oldStamp ?? nextStamp) > nextStamp ? old != nil : next != nil)
          // Retirement removes catalogue visibility, not the admitted PAGE
          // source. Fresh snapshots also carry the retained typed order owner.
          let orderAddress = root + "/pageOrders/@" + id
          if let orderRow = try incoming.candidate(orderAddress) {
            let candidateOrder = try orderRow.value.decode(NotebookPageOrderRegister.self)
            try candidateOrder.validate()
            let delivered = try incoming.mutation(orderAddress) != nil
            guard orderRow.parent == root, orderRow.collection == "pageOrders", orderRow.member == id,
              orderRow.position == 0, orderRow.collections.isEmpty,
              !delivered || Set(candidateOrder.heads.map(\.valueRoot) + [candidateOrder.visibleRoot]).isSubset(of: declaredOrderRoots) else {
              throw NotebookStorageError.invalidTransaction("retired page order dependencies")
            }
            let prior = try incoming.previous(orderAddress)?.value.decode(NotebookPageOrderRegister.self)
            let joined = try mergeRetiredNotebookOrder(candidateOrder, previous: prior)
            try writePageOrder(joined, itemID: uuid)
            try put(fieldKey(["items", id, "pageIDs"]), joined.fieldVersion)
          }
          try removeFragment(address, database: database); continue
        }
        guard let selected = old ?? next else { throw NotebookStorageError.invalidTransaction("item payload missing") }
        func itemHeader(_ fragment: NotebookStoredFragment) throws -> WorkspaceItem {
          let item = try fragment.value.setting("pageIDs", .array([])).decode(WorkspaceItem.self)
          guard item.id == uuid, item.title.utf16.count <= WorkspaceIndex.maximumTitleLength,
            fragment.parent == root, fragment.collection == "items", fragment.member == id,
            fragment.collections == [.init(path: ["pageIDs"], kind: .array)] else { throw NotebookStorageError.corruptRecord(address) }
          guard try JSONValue.encode(item).setting("pageIDs", nil) == fragment.value else { throw NotebookStorageError.corruptRecord(address) }
          return item
        }
        let a = try old.map(itemHeader), b = try next.map(itemHeader)
        guard a == nil || b == nil || a?.kind == b?.kind else { throw NotebookStorageError.transactionConflict }
        var item = try itemHeader(selected)
        if let a, let b { item.title = try resolve(fieldKey(["items", id, "title"]), .string(a.title), .string(b.title))?.string ?? a.title }
        let newest = (oldStamp ?? nextStamp) > nextStamp ? a : b
        differsFromNewest = differsFromNewest || newest == nil || item.title != newest?.title
        let position = try old?.position ?? Int(database.rows("SELECT COALESCE(MAX(position),-1)+1 FROM records WHERE parent=? AND collection='items'", [.text(root)]).first![0].integer!)
        try writeFragment(selected.replacing(value: selected.value.setting("title", .string(item.title)), position: position), database: database)
        let pagePrefix = address + "/pageIDs/@", orderAddress = root + "/pageOrders/@" + id
        let hasPages = try !database.rows("SELECT 1 FROM manifest_records WHERE manifest_hash=? AND address>=? AND address<? LIMIT 1", [.text(manifestHash), .text(pagePrefix), .text(address + "/pageIDs0")]).isEmpty
        let hasPageOrder = try incoming.mutation(orderAddress) != nil
        if hasPages || hasPageOrder || old == nil {
          if item.kind != .notebook {
            guard !hasPages, !hasPageOrder else { throw NotebookStorageError.invalidTransaction("non-notebook pages") }
            continue
          }
          let previousOrder = try incoming.previous(orderAddress)?.value.decode(NotebookPageOrderRegister.self)
          guard let orderRow = try incoming.candidate(orderAddress) else { throw NotebookStorageError.invalidTransaction("missing authored page order") }
          let candidateOrder = try orderRow.value.decode(NotebookPageOrderRegister.self)
          try candidateOrder.validate()
          guard orderRow.parent == root, orderRow.collection == "pageOrders", orderRow.member == id,
            orderRow.position == 0, orderRow.collections.isEmpty,
            !hasPageOrder || Set(candidateOrder.heads.map(\.valueRoot) + [candidateOrder.visibleRoot]).isSubset(of: declaredOrderRoots) else {
            throw NotebookStorageError.invalidTransaction("undeclared page order dependencies")
          }
          for value in Set(candidateOrder.heads.map(\.valueRoot) + [candidateOrder.visibleRoot]) {
            try validatePageOrderValue(value, previous: previousOrder?.visibleRoot, itemID: previousOrder == nil ? nil : uuid)
          }
          try database.run("CREATE TEMP TABLE IF NOT EXISTS replication_page_memberships(address TEXT PRIMARY KEY,position INTEGER NOT NULL)")
          try database.run("DELETE FROM replication_page_memberships")
          try incoming.visit(from: pagePrefix, to: address + "/pageIDs0") { pageAddress in
            let pageID = String(pageAddress.dropFirst(pagePrefix.count))
            guard let page = UUID(uuidString: pageID), page.uuidString.lowercased() == pageID else { throw NotebookStorageError.invalidTransaction("page membership identity") }
            let previous = try incoming.previous(pageAddress), delivered = try incoming.candidate(pageAddress)
            if let delivered {
              guard delivered.parent == address, delivered.collection == "pageIDs", delivered.member == pageID,
                delivered.value.string?.lowercased() == pageID, delivered.collections.isEmpty else { throw NotebookStorageError.corruptRecord(pageAddress) }
            }
            if let previous { try database.run("INSERT INTO replication_page_memberships VALUES(?,?)", [.text(pageAddress), .integer(Int64(previous.position))]) }
            let key = fieldKey(["items", id, "pageIDs", pageID])
            let exists = try resolve(key, .bool(previous != nil), .bool(delivered != nil)) == .bool(true)
            if exists {
              guard let value = previous ?? delivered else { throw NotebookStorageError.corruptRecord(pageAddress) }
              try writeFragment(value, database: database)
            } else { try removeFragment(pageAddress, database: database) }
          }
          let normalized = try normalizeReplicatedPageOrder([candidateOrder] + (previousOrder.map { [$0] } ?? []),
            itemID: uuid, previousRoot: previousOrder?.visibleRoot)
          try writePageOrder(normalized, itemID: uuid)
          try put(fieldKey(["items", id, "pageIDs"]), normalized.fieldVersion)
          let newestRoot = (oldStamp ?? nextStamp) > nextStamp ? previousOrder?.visibleRoot : candidateOrder.visibleRoot
          differsFromNewest = differsFromNewest || normalized.visibleRoot != newestRoot
          try database.run("DELETE FROM replication_page_memberships")
        }
      }
    }
    if changesOrder {
      let candidateOrder = candidateSlots.keys.sorted { candidateSlots[$0] == candidateSlots[$1] ? $0 < $1 : candidateSlots[$0]! < candidateSlots[$1]! }
      // Catalog's authored order uses canonical UUID spelling, unlike element IDs.
      let encodeOrder: ([String]) -> JSONValue = { .array($0.map { .string(UUID(uuidString: $0)!.uuidString) }) }
      let preferredValue = try resolve("items/order", encodeOrder(oldOrder), encodeOrder(candidateOrder))
      let preferred = preferredValue?.array.compactMap { $0.string?.lowercased() } ?? oldOrder
      let live = try database.rows("SELECT member,position FROM records WHERE parent=? AND collection='items' ORDER BY position,member", [.text(root)])
      let positions = Dictionary(uniqueKeysWithValues: live.map { ($0[0].text!, Int($0[1].integer!)) })
      let order = contentMemberOrder(preferred: preferred, escapedMembers: Array(positions.keys))
      for (position, id) in order.enumerated() where positions[id] != position {
        let row = try incoming.previous(prefix + id)!
        try writeFragment(row.replacing(value: row.value, position: position), database: database)
      }
      if encodeOrder(order) != preferredValue, let version = try incoming.field(parent: root, collection: fields, key: "items/order", delivered: false) {
        try put("items/order", version.retainingValue(preferredValue))
      }
      differsFromNewest = differsFromNewest || order != ((oldStamp ?? nextStamp) > nextStamp ? oldOrder : candidateOrder)
    }
    try incoming.visit(from: fieldPrefix, to: root + "/" + fields + "0") { address in
      let key = unescape(String(address.dropFirst(fieldPrefix.count)))
      guard try database.rows("SELECT 1 FROM replication_catalog_fields WHERE key=?", [.text(key)]).isEmpty else { return }
      guard let next = try incoming.field(parent: root, collection: fields, key: key, delivered: true) else { throw NotebookStorageError.corruptRecord(address) }
      let old = try incoming.field(parent: root, collection: fields, key: key, delivered: false)
      try put(key, old.map { try $0.joining(next) } ?? next)
    }
    let stamp = differsFromNewest ? frontier.advanced(by: frontier.actor) ?? frontier : frontier
    try writeFragment(nextRoot.replacing(value: nextRoot.value.setting("stamp", .encode(stamp))), database: database)
    var retiredCursor = ""
    while true {
      let rows = try database.rows("SELECT id FROM replication_catalog_items WHERE id>? ORDER BY id LIMIT 64", [.text(retiredCursor)])
      guard let last = rows.last?[0].text else { break }
      for row in rows { try refreshRetiredNotebookPages(itemID: UUID(uuidString: row[0].text!)!) }
      retiredCursor = last
    }
    try database.run("DELETE FROM replication_catalog_items")
    if try !database.rows("SELECT 1 FROM replication_catalog_fields WHERE allocated=1 LIMIT 1").isEmpty {
      try incoming.validateFieldCount(parent: root, collection: fields, maximum: 1_000_000)
    }
    try database.run("DELETE FROM replication_catalog_fields")
  }
}

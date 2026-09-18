import Foundation

struct NotebookDeletedItemUndoPreparation {
  fileprivate let restoration: DeletedItemRestoration
  fileprivate let plans: [DeletedItemRestoration.Plan]
  fileprivate let preserved: [CollaborationTarget]

  func clear() throws { try restoration.clear() }
}

extension NotebookStore {
  /// All lifecycle ownership is decided before this action's own ordinary
  /// inverse writes. TEMP evidence stays inside that same SQL transaction.
  func prepareDeletedItemUndo(receipt: CollaborationReceipt, actor: UUID) throws -> NotebookDeletedItemUndoPreparation? {
    guard let database = currentSQL, database.writable else { throw NotebookStorageError.readOnlyTransaction }
    let deleted = (receipt.lifecycleChanges ?? []).filter { $0.kind == .deleteItem }
    guard deleted.count <= 512 else { throw NotebookStorageError.limitExceeded("lifecycle_restore_items") }
    guard Set(deleted.map { $0.target.id }).count == deleted.count else {
      throw NotebookStorageError.invalidTransaction("duplicate deleted item restoration")
    }
    guard !deleted.isEmpty else { return nil }
    guard let inverse = receipt.lifecycleInverse else { throw NotebookStorageError.invalidTransaction("missing deletion inverse") }
    let restoration = DeletedItemRestoration(store: self, database: database, receipt: receipt, actor: actor)
    do {
      try restoration.prepare(inverse)
      var plans: [DeletedItemRestoration.Plan] = [], preserved: [CollaborationTarget] = []
      for change in deleted {
        if let plan = try restoration.preflight(change) { plans.append(plan) }
        else { preserved.append(change.target) }
      }
      // A child removed before its now-empty parent is one dependency group.
      // Preflight every owner first; a foreign parent continuation preserves
      // its children too, and no partial resurrection is published as success.
      let ordered = try restoration.orderPlans(plans)
      preserved += ordered.preserved
      return .init(restoration: restoration, plans: ordered.plans, preserved: preserved)
    } catch {
      try? restoration.clear()
      throw error
    }
  }

  func publishDeletedItemUndo(_ prepared: NotebookDeletedItemUndoPreparation?) throws -> NotebookLifecycleUndoResult {
    guard let prepared else { return .init() }
    guard let database = currentSQL, database === prepared.restoration.database,
      database.activeActionRecordCapture != nil else {
      throw NotebookStorageError.invalidTransaction("deleted item undo publication scope")
    }
    var result = NotebookLifecycleUndoResult(preserved: prepared.preserved)
    for plan in prepared.plans {
      let item = try prepared.restoration.publish(plan)
      result.changes.append(.init(kind: .restoreItem, target: plan.change.target, pageID: nil, item: item))
    }
    return result
  }
}

/// Only scalar row identities/hashes live in TEMP. Memory is one inverse part,
/// one bounded source atom and at most 512 compact item plans, never whole source bodies.
fileprivate final class DeletedItemRestoration {
  struct Plan {
    let change: NotebookLifecycleChange
    let item: NotebookStoredFragment
    let placement: NotebookStoredFragment
    let previousPose: WorkspacePlacementPose
    let currentPlacement: WorkspacePlacement
    let notebook: NotebookPlan?
    let retiredParent: UUID?
    let restoresCatalogueOrder: Bool
  }

  struct NotebookPlan {
    let order: NotebookPageOrderRegister
    let currentOrder: NotebookPageOrderRegister
    let retainedAppends: [UUID]
    let removedAppends: [UUID]
  }

  let store: NotebookStore
  let database: NotebookSQLConnection
  let receipt: CollaborationReceipt
  let actor: UUID
  let deletedBoards: Set<UUID>

  init(store: NotebookStore, database: NotebookSQLConnection, receipt: CollaborationReceipt, actor: UUID) {
    self.store = store; self.database = database; self.receipt = receipt; self.actor = actor
    deletedBoards = Set((receipt.lifecycleChanges ?? []).filter { $0.kind == .deleteItem && $0.beforeItem?.kind == .board }.map { $0.target.id })
  }

  func orderPlans(_ plans: [Plan]) throws -> (plans: [Plan], preserved: [CollaborationTarget]) {
    let byID = Dictionary(uniqueKeysWithValues: plans.map { ($0.change.target.id, $0) })
    var ordered: [Plan] = [], preserved: [CollaborationTarget] = []
    var visiting = Set<UUID>(), accepted = Set<UUID>(), rejected = Set<UUID>()
    func admit(_ id: UUID) throws -> Bool {
      if accepted.contains(id) { return true }
      if rejected.contains(id) { return false }
      guard let plan = byID[id] else { return false }
      guard visiting.insert(id).inserted else { throw NotebookStorageError.invalidTransaction("deleted board restoration cycle") }
      defer { visiting.remove(id) }
      if let parent = plan.retiredParent, try !admit(parent) {
        rejected.insert(id); preserved.append(plan.change.target); return false
      }
      accepted.insert(id); ordered.append(plan); return true
    }
    for plan in plans { _ = try admit(plan.change.target.id) }
    return (ordered, preserved)
  }

  func prepare(_ inverse: NotebookLifecycleInverseReference) throws {
    try database.run("CREATE TEMP TABLE IF NOT EXISTS notebook_restore_inverse(address TEXT PRIMARY KEY,file TEXT NOT NULL,parent TEXT,collection TEXT NOT NULL,member TEXT NOT NULL,before_hash TEXT,after_hash TEXT) WITHOUT ROWID")
    try database.run("CREATE INDEX IF NOT EXISTS notebook_restore_inverse_file ON notebook_restore_inverse(file,address)")
    try database.run("CREATE TEMP TABLE IF NOT EXISTS notebook_restore_pages(page_id TEXT PRIMARY KEY,item_id TEXT NOT NULL,position INTEGER NOT NULL,UNIQUE(item_id,position)) WITHOUT ROWID")
    try database.run("CREATE TEMP TABLE IF NOT EXISTS notebook_restore_covers(address TEXT PRIMARY KEY,item_id TEXT NOT NULL,member TEXT NOT NULL) WITHOUT ROWID")
    try database.run("PRAGMA temp.cache_size=-2048")
    try clear()
    // Authentication includes every part, raw address/hash and order dependency,
    // not just the records later selected by a convenient prefix.
    try store.visitLifecycleInverse(reference: inverse, actionID: receipt.id) { record in
      let hash = record.beforeHash ?? record.afterHash!
      let fragment = try store.readLifecycleInverseFragment(hash: hash, address: record.address)
      try database.run("INSERT INTO notebook_restore_inverse VALUES(?,?,?,?,?,?,?)", [
        .text(record.address), .text(fragment.file), fragment.parent.map(NotebookSQLValue.text) ?? .null,
        .text(fragment.collection), .text(fragment.member), record.beforeHash.map(NotebookSQLValue.text) ?? .null,
        record.afterHash.map(NotebookSQLValue.text) ?? .null])
    }
  }

  func clear() throws {
    for table in ["notebook_restore_inverse", "notebook_restore_pages", "notebook_restore_covers"] {
      try database.run("DELETE FROM " + table)
    }
  }

  private func image(_ address: String, before: Bool) throws -> NotebookStoredFragment? {
    let column = before ? "before_hash" : "after_hash"
    guard let hash = try database.rows("SELECT " + column + " FROM notebook_restore_inverse WHERE address=?", [.text(address)]).first?[0].text else { return nil }
    return try store.readLifecycleInverseFragment(hash: hash, address: address)
  }

  private func current(_ address: String) throws -> NotebookStoredFragment? {
    try store.storedFragments(address: address, descendants: false).first
  }

  private func visit(_ predicate: String, arguments: [NotebookSQLValue] = [],
    _ body: (String) throws -> Void) throws {
    var after = ""
    while true {
      let rows = try database.rows("SELECT address FROM notebook_restore_inverse WHERE (" + predicate + ") AND address>? ORDER BY address LIMIT 64", arguments + [.text(after)])
      guard let last = rows.last?[0].text else { return }
      for row in rows { try Task.checkCancellation(); try body(row[0].text!) }
      after = last
    }
  }

  private func fieldAddress(parent: String = "workspace.json#", collection: String = "collaboration/fields", key: String) -> String {
    parent + "/" + collection + "/@" + fieldKey([key])
  }

  private func sameFieldAsPostimage(_ address: String) throws -> Bool {
    guard let expected = try image(address, before: false)?.value.decode(ContentFieldVersion.self),
      let actual = try current(address)?.value.decode(ContentFieldVersion.self) else { return false }
    return expected.isValid && actual == expected
  }

  func preflight(_ change: NotebookLifecycleChange) throws -> Plan? {
    guard change.target.kind == .cover, let boardID = change.target.boardID,
      let summary = change.beforeItem, summary.id == change.target.id, change.afterItem == nil,
      receipt.action.operations.contains(where: { $0.kind == .deleteItem && $0.target == change.target }) else {
      throw NotebookStorageError.invalidTransaction("deletion inverse target")
    }
    let id = summary.id.uuidString.lowercased(), itemAddress = "workspace.json#/items/@" + id
    guard let item = try image(itemAddress, before: true), try image(itemAddress, before: false) == nil,
      item.parent == "workspace.json#", item.collection == "items", item.member == id,
      item.value["id"]?.string.flatMap(UUID.init(uuidString:)) == summary.id,
      item.value["kind"] == .string(summary.kind.rawValue), item.value["title"] == .string(summary.title),
      item.collections == [.init(path: ["pageIDs"], kind: .array)] else {
      throw NotebookStorageError.invalidTransaction("pre-action item header")
    }
    guard try current(itemAddress) == nil,
      try store.ownerBoardID(of: summary.id) == nil,
      try sameFieldAsPostimage(fieldAddress(key: fieldKey(["items", id, "exists"]))) else { return nil }
    let boardAddress = "board.json#/boards/@" + boardID.uuidString.lowercased()
    let liveParent = try store.isLiveBoard(boardID)
    guard liveParent || deletedBoards.contains(boardID), try current(boardAddress) != nil else { return nil }
    let placementAddress = boardAddress + "/board/placements/@" + id
    guard let priorPlacement = try image(placementAddress, before: true)?.value.decode(WorkspacePlacement.self),
      priorPlacement.itemID == summary.id, let priorPose = priorPlacement.pose,
      let afterPlacement = try image(placementAddress, before: false)?.value.decode(WorkspacePlacement.self),
      let placement = try current(placementAddress),
      afterPlacement.itemID == summary.id, afterPlacement.pose == nil else {
      throw NotebookStorageError.invalidTransaction("deletion placement evidence")
    }
    let currentPlacement = try placement.value.decode(WorkspacePlacement.self)
    guard currentPlacement.itemID == summary.id, currentPlacement.heads == afterPlacement.heads else { return nil }

    var available = true
    let notebook: NotebookPlan?
    if summary.kind == .notebook {
      var pageCount = 0, first: UUID?
      try visit("parent=? AND collection='pageIDs' AND before_hash IS NOT NULL", arguments: [.text(itemAddress)]) { address in
        guard let membership = try image(address, before: true), try image(address, before: false) == nil,
          let pageID = UUID(uuidString: membership.member), pageID.uuidString.lowercased() == membership.member,
          membership.value.string.flatMap(UUID.init(uuidString:)) == pageID,
          membership.address == itemAddress + "/pageIDs/@" + membership.member,
          membership.collections.isEmpty else { throw NotebookStorageError.invalidTransaction("pre-action page membership") }
        try database.run("INSERT INTO notebook_restore_pages VALUES(?,?,?)", [.text(membership.member), .text(id), .integer(Int64(membership.position))])
        pageCount += 1; if membership.position == 0 { first = pageID }
        if try store.ownerItemID(ofPage: pageID) != nil { available = false }
        // Deletion removes public membership, not the sole mergeable PAGE
        // baseline. Accepted concurrent source is never hydrated from history.
        _ = try store.requireRetiredPageBaseline(pageID: pageID, itemID: summary.id)
      }
      guard pageCount == summary.pageCount, pageCount > 0, first == summary.firstPageID else {
        throw NotebookStorageError.invalidTransaction("incomplete pre-action notebook extent")
      }
      guard available else { return nil }
      let currentOrder = try store.readPageOrder(summary.id)
      let orderAddress = "workspace.json#/pageOrders/@" + id
      let oldOrder: NotebookPageOrderRegister
      if let previous = try image(orderAddress, before: true) {
        guard let after = try image(orderAddress, before: false)?.value.decode(NotebookPageOrderRegister.self) else {
          throw NotebookStorageError.invalidTransaction("deleted notebook page order evidence")
        }
        guard after == currentOrder else { return nil }
        oldOrder = try previous.value.decode(NotebookPageOrderRegister.self)
      } else { oldOrder = currentOrder }
      try oldOrder.validate()
      guard try current(fieldAddress(key: fieldKey(["items", id, "pageIDs"])))?.value.decode(ContentFieldVersion.self) == currentOrder.fieldVersion else { return nil }
      // A pure delete did not rewrite its order register. Its full historical
      // frontier is not invented from the capture: the retained typed register
      // and every authenticated original membership must agree exactly.
      var position = 0
      func walk(_ hash: String) throws {
        let node = try store.readPageOrderNode(hash)
        for page in node.pages {
          guard let found = try database.rows("SELECT page_id FROM notebook_restore_pages WHERE item_id=? AND position=?", [.text(id), .integer(Int64(position))]).first?[0].text,
            found == page.uuidString.lowercased() else { throw NotebookStorageError.invalidTransaction("pre-action page order membership") }
          position += 1
        }
        for child in node.children { try walk(child) }
      }
      try walk(oldOrder.visibleRoot)
      guard position == pageCount else { throw NotebookStorageError.invalidTransaction("pre-action page order extent") }

      // An append followed by deletion belongs to this same original action.
      // Undo removes only its still-owned birth. A later source author keeps the
      // page, attached after the restored pre-action pages rather than orphaned.
      var retainedAppends: [UUID] = [], removedAppends: [UUID] = []
      for operation in receipt.action.operations where operation.kind == .appendPage && operation.target == change.target {
        guard let pageID = operation.id.flatMap(UUID.init(uuidString:)) else {
          throw NotebookStorageError.invalidTransaction("deleted appended page identity")
        }
        let file = pageFile(pageID), member = pageID.uuidString.lowercased()
        guard try database.rows("SELECT 1 FROM notebook_restore_pages WHERE page_id=?", [.text(member)]).isEmpty,
          try image(file + "#", before: true) == nil, try image(file + "#", before: false) != nil,
          try database.rows("SELECT 1 FROM notebook_restore_inverse WHERE file=? AND before_hash IS NOT NULL LIMIT 1", [.text(file)]).isEmpty else {
          throw NotebookStorageError.invalidTransaction("deleted appended page birth")
        }
        _ = try store.requireRetiredPageBaseline(pageID: pageID, itemID: summary.id)
        let birthAddress = fieldAddress(key: fieldKey(["items", id, "pageIDs", member]))
        guard try image(birthAddress, before: true) == nil,
          let birth = try image(birthAddress, before: false)?.value.decode(ContentFieldVersion.self), birth.isValid else {
          throw NotebookStorageError.invalidTransaction("deleted appended page birth version")
        }
        let ownedBirth = try current(birthAddress)?.value.decode(ContentFieldVersion.self) == birth
        let changed = try database.rows("SELECT 1 FROM records r LEFT JOIN notebook_restore_inverse i ON i.address=r.address WHERE r.file=? AND (i.after_hash IS NULL OR r.hash!=i.after_hash) LIMIT 1", [.text(file)])
        let missing = try database.rows("SELECT 1 FROM notebook_restore_inverse i LEFT JOIN records r ON r.address=i.address WHERE i.file=? AND i.after_hash IS NOT NULL AND (r.hash IS NULL OR r.hash!=i.after_hash) LIMIT 1", [.text(file)])
        if ownedBirth && changed.isEmpty && missing.isEmpty { removedAppends.append(pageID) }
        else {
          // Appends in the operation stream have deterministic relative order;
          // their original root is authenticated by currentOrder above.
          retainedAppends.append(pageID)
        }
      }

      notebook = .init(order: oldOrder, currentOrder: currentOrder,
        retainedAppends: retainedAppends, removedAppends: removedAppends)
    } else {
      guard summary.pageCount == 0, summary.firstPageID == nil,
        try database.rows("SELECT 1 FROM notebook_restore_inverse WHERE parent=? AND collection='pageIDs' AND before_hash IS NOT NULL LIMIT 1", [.text(itemAddress)]).isEmpty else {
        throw NotebookStorageError.invalidTransaction("non-notebook restoration extent")
      }
      switch summary.kind {
      case .document: _ = try store.requireRetiredDocumentBaseline(itemID: summary.id)
      case .board: _ = try store.requireRetiredBoardBaseline(itemID: summary.id)
      case .notebook: preconditionFailure("notebook restoration is prepared above")
      }
      notebook = nil
    }

    // Source ownership is decoded from the authenticated pre-action record,
    // not inferred from the currently visible/rendered subset of a cover.
    try visit("parent=? AND collection='board/elements' AND before_hash IS NOT NULL", arguments: [.text(boardAddress)]) { address in
      guard let row = try image(address, before: true),
        try row.value["surface"]?.decode(SurfaceID.self) == .cover(summary.id) else { return }
      guard try image(address, before: false) == nil else { throw NotebookStorageError.invalidTransaction("deleted cover source remains") }
      try database.run("INSERT INTO notebook_restore_covers VALUES(?,?,?)", [.text(address), .text(id), .text(row.member)])
      if try current(address) != nil || !sameFieldAsPostimage(fieldAddress(parent: boardAddress,
        collection: "board/collaboration/fields", key: fieldKey(["elements", row.member, "exists"]))) { available = false }
      let keyPrefix = fieldKey(["elements", row.member]) + "/"
      try visit("parent=? AND collection='board/collaboration/fields' AND member>=? AND member<?", arguments: [.text(boardAddress), .text(keyPrefix), .text(keyPrefix + "\u{10ffff}")]) { field in
        if try !sameFieldAsPostimage(field) { available = false }
      }
    }
    // A renamed-then-deleted title has a retained post-action owner too.
    for key in ["title", "kind"] {
      let address = fieldAddress(key: fieldKey(["items", id, key]))
      if try image(address, before: false) != nil, try !sameFieldAsPostimage(address) { available = false }
    }
    guard available else { return nil }
    return .init(change: change, item: item, placement: placement, previousPose: priorPose,
      currentPlacement: currentPlacement, notebook: notebook, retiredParent: liveParent ? nil : boardID,
      restoresCatalogueOrder: try sameFieldAsPostimage(fieldAddress(key: "items/order")))
  }

  private func authorField(parent: String = "workspace.json#", collection: String = "collaboration/fields",
    file: String = "workspace.json", key: String, stamp: VersionStamp) throws {
    let address = fieldAddress(parent: parent, collection: collection, key: key)
    let previous = try current(address)?.value.decode(ContentFieldVersion.self)
    let version = ContentFieldVersion(stamp: stamp, human: true, previous: previous)
    guard version.isValid else { throw NotebookStorageError.limitExceeded("lifecycle_restore_causal_actors") }
    try store.writeFragment(.init(address: address, file: file, parent: parent, collection: collection,
      member: key, position: 0, value: .encode(version), collections: []), database: database)
  }

  func publish(_ plan: Plan) throws -> NotebookItemHeader {
    let id = plan.change.target.id.uuidString.lowercased(), boardID = plan.change.target.boardID!
    let boardAddress = "board.json#/boards/@" + boardID.uuidString.lowercased()
    guard let workspace = try current("workspace.json#"), let board = try current(boardAddress), let tree = try current("board.json#") else {
      throw NotebookStorageError.invalidTransaction("restoration owners disappeared")
    }
    var counter: UInt64 = 0
    func include(_ version: ContentFieldVersion) { counter = max(counter, max(version.stamp.counter, version.observed.values.max() ?? 0)) }
    for value in [workspace.value["stamp"], tree.value["stamp"], board.value["board"]?["stamp"]].compactMap({ $0 }) {
      counter = max(counter, try value.decode(VersionStamp.self).counter)
    }
    for head in plan.currentPlacement.heads { include(head.version) }
    for head in plan.notebook?.currentOrder.heads ?? [] { include(head.version) }
    // Current causal rows can carry a frontier above the owner's cached stamp.
    // Scan only this item/its cover metadata, in bounded SQL batches.
    let itemPrefix = fieldKey(["items", id]) + "/"
    var cursor = ""
    while true {
      let rows = try database.rows("SELECT address FROM records WHERE parent='workspace.json#' AND collection='collaboration/fields' AND member>=? AND member<? AND address>? ORDER BY address LIMIT 64", [.text(itemPrefix), .text(itemPrefix + "\u{10ffff}"), .text(cursor)])
      guard let last = rows.last?[0].text else { break }
      for row in rows { if let version = try current(row[0].text!)?.value.decode(ContentFieldVersion.self) { include(version) } }
      cursor = last
    }
    if let orderVersion = try current(fieldAddress(key: "items/order"))?.value.decode(ContentFieldVersion.self) { include(orderVersion) }
    var sourceCursor = ""
    while true {
      let sources = try database.rows("SELECT address,member FROM notebook_restore_covers WHERE item_id=? AND address>? ORDER BY address LIMIT 64", [.text(id), .text(sourceCursor)])
      guard let last = sources.last?[0].text else { break }
      for source in sources {
        let prefix = fieldKey(["elements", source[1].text!]) + "/"
        var fieldCursor = ""
        while true {
          let fields = try database.rows("SELECT address FROM records WHERE parent=? AND collection='board/collaboration/fields' AND member>=? AND member<? AND address>? ORDER BY address LIMIT 64", [.text(boardAddress), .text(prefix), .text(prefix + "\u{10ffff}"), .text(fieldCursor)])
          guard let last = fields.last?[0].text else { break }
          for field in fields { if let version = try current(field[0].text!)?.value.decode(ContentFieldVersion.self) { include(version) } }
          fieldCursor = last
        }
      }
      sourceCursor = last
    }
    if let orderVersion = try current(fieldAddress(parent: boardAddress, collection: "board/collaboration/fields", key: "elements/order"))?.value.decode(ContentFieldVersion.self) { include(orderVersion) }
    let stamp = try requireNext(counter)
    // All plans capture ownership before the first publication. Our own prior
    // item restoration in this transaction is not a foreign order continuation.
    let restoreCatalogOrder = plan.restoresCatalogueOrder
    let position: Int
    if restoreCatalogOrder { position = plan.item.position }
    else {
      position = Int(try database.rows("SELECT COALESCE(MAX(position),-1)+1 FROM records WHERE parent='workspace.json#' AND collection='items'").first![0].integer!)
    }
    try store.writeFragment(plan.item.replacing(value: plan.item.value, position: position), database: database)
    try authorField(key: fieldKey(["items", id, "exists"]), stamp: stamp)
    if restoreCatalogOrder { try authorField(key: "items/order", stamp: stamp) }
    for key in ["title", "kind"] {
      if try image(fieldAddress(key: fieldKey(["items", id, key])), before: false) != nil {
        try authorField(key: fieldKey(["items", id, key]), stamp: stamp)
      }
    }
    if let notebook = plan.notebook {
      try visit("parent=? AND collection='pageIDs' AND before_hash IS NOT NULL", arguments: [.text(plan.item.address)]) { address in
        let row = try image(address, before: true)!
        try store.writeFragment(row, database: database)
        try authorField(key: fieldKey(["items", id, "pageIDs", row.member]), stamp: stamp)
      }
      var restoredRoot = notebook.order.visibleRoot
      var pagePosition = plan.change.beforeItem!.pageCount
      for page in notebook.retainedAppends {
        let member = page.uuidString.lowercased()
        try store.writeFragment(.init(address: plan.item.address + "/pageIDs/@" + member, file: "workspace.json",
          parent: plan.item.address, collection: "pageIDs", member: member, position: pagePosition,
          value: .encode(page), collections: []), database: database)
        try authorField(key: fieldKey(["items", id, "pageIDs", member]), stamp: stamp)
        restoredRoot = try NotebookPageOrderVector.append(to: restoredRoot, pageID: page,
          read: { try store.readPageOrderNode($0) }, write: { try store.writePageOrderNode($0) })
        pagePosition += 1
      }
      for page in notebook.removedAppends { try store.removeFragment(pageFile(page) + "#", database: database) }
      let order = try NotebookPageOrderRegister.authored(root: restoredRoot, stamp: stamp, human: true, previous: notebook.currentOrder)
      try store.writePageOrder(order, itemID: plan.change.target.id)
      let orderKey = fieldKey(["items", id, "pageIDs"])
      try store.writeFragment(.init(address: fieldAddress(key: orderKey), file: "workspace.json", parent: "workspace.json#",
        collection: "collaboration/fields", member: orderKey, position: 0, value: .encode(order.fieldVersion), collections: []), database: database)

      // Existing PAGE values and causal dots survive untouched. The ordinary
      // inverse below restores only still-owned edits made inside this action.
      try store.refreshRetiredNotebookPages(itemID: plan.change.target.id)
    }
    var coverCursor = "", restoredCover = false
    while true {
      let rows = try database.rows("SELECT address,member FROM notebook_restore_covers WHERE item_id=? AND address>? ORDER BY address LIMIT 64", [.text(id), .text(coverCursor)])
      guard let last = rows.last?[0].text else { break }
      for row in rows {
        let address = row[0].text!, member = row[1].text!
        try visit("(address=? OR (address>=? AND address<?)) AND before_hash IS NOT NULL", arguments: [.text(address), .text(address + "/"), .text(address + "0")]) { source in
          try store.writeFragment(image(source, before: true)!, database: database)
        }
        _ = try store.validateStoredSourceAtom(address: address) { value in
          let source = try value.decode(SpatialElement.self)
          guard source.isValid, source.surface == .cover(plan.change.target.id),
            collaborationIdentity(source.id) == member else { throw NotebookStorageError.invalidTransaction("restored cover source") }
          return try .encode(source)
        }
        let keyPrefix = fieldKey(["elements", member]) + "/"
        try visit("parent=? AND collection='board/collaboration/fields' AND member>=? AND member<? AND after_hash IS NOT NULL", arguments: [.text(boardAddress), .text(keyPrefix), .text(keyPrefix + "\u{10ffff}")]) { field in
          let row = try image(field, before: false)!
          try authorField(parent: boardAddress, collection: "board/collaboration/fields", file: "board.json", key: row.member, stamp: stamp)
        }
        restoredCover = true
      }
      coverCursor = last
    }
    if restoredCover {
      // Preserve every current sibling's relative order. The authored order
      // admits restored source positions without repainting/deleting siblings.
      try authorField(parent: boardAddress, collection: "board/collaboration/fields", file: "board.json", key: "elements/order", stamp: stamp)
    }
    let placement = try WorkspacePlacement.authored(itemID: plan.change.target.id, pose: plan.previousPose,
      stamp: stamp, human: true, previous: plan.currentPlacement)
    try store.writeFragment(plan.placement.replacing(value: .encode(placement)), database: database)
    try store.writeFragment(board.replacing(value: board.value.setting("board", board.value["board"]!.setting("stamp", .encode(stamp)))), database: database)
    try store.writeFragment(tree.replacing(value: tree.value.setting("stamp", .encode(stamp))), database: database)
    try store.writeFragment(workspace.replacing(value: workspace.value.setting("stamp", .encode(stamp))), database: database)
    guard let item = try store.readItemHeader(plan.change.target.id) else { throw NotebookStorageError.invalidTransaction("restored item header") }
    return item
  }

  private func requireNext(_ counter: UInt64) throws -> VersionStamp {
    guard let stamp = VersionStamp(counter: counter, actor: actor).advanced(by: actor) else {
      throw NotebookStorageError.limitExceeded("lifecycle_restore_clock")
    }
    return stamp
  }

}

import Foundation

/// A derived ownership edge, never a new birth or permission to resurrect an
/// item. Only a deleted notebook's retained, typed order can provide this edge.
struct NotebookRetiredPageMembership {
  let itemID: UUID
  let position: Int
}

extension NotebookStore {
  static func createRetiredNotebookPageIndex(_ database: NotebookSQLConnection) throws {
    try database.run("CREATE TABLE IF NOT EXISTS retired_notebook_orders(item_id TEXT PRIMARY KEY,order_hash TEXT NOT NULL)")
    try database.run("CREATE TABLE IF NOT EXISTS retired_notebook_pages(page_id TEXT PRIMARY KEY,item_id TEXT NOT NULL,birth_address TEXT NOT NULL REFERENCES records(address) ON DELETE CASCADE,position INTEGER NOT NULL)")
    try database.run("CREATE INDEX IF NOT EXISTS retired_notebook_page_owner ON retired_notebook_pages(item_id,page_id)")
  }

  /// Rebuildable from existing typed records. Admission never recovers a body
  /// from manifests, receipts or blobs that have lost their canonical address.
  func rebuildRetiredNotebookPageIndex(database: NotebookSQLConnection) throws {
    try database.run("DELETE FROM retired_notebook_pages")
    try database.run("DELETE FROM retired_notebook_orders")
    var cursor = ""
    while true {
      let rows = try database.rows("SELECT member FROM records WHERE parent='workspace.json#' AND collection='pageOrders' AND member>? ORDER BY member LIMIT 64", [.text(cursor)])
      guard let last = rows.last?[0].text else { return }
      for row in rows {
        guard let item = row[0].text.flatMap(UUID.init(uuidString:)) else { throw NotebookStorageError.corruptRecord("retired order owner") }
        try refreshRetiredNotebookPages(itemID: item)
      }
      cursor = last
    }
  }

  /// Called for catalogue lifecycle changes, not PAGE/Pencil writes. A cached
  /// register hash avoids rewalking the same deleted notebook in final checks.
  func refreshRetiredNotebookPages(itemID: UUID) throws {
    guard let database = currentSQL, database.writable else { throw NotebookStorageError.readOnlyTransaction }
    let item = itemID.uuidString.lowercased(), itemAddress = "workspace.json#/items/@" + item
    func clear() throws {
      try database.run("DELETE FROM retired_notebook_pages WHERE item_id=?", [.text(item)])
      try database.run("DELETE FROM retired_notebook_orders WHERE item_id=?", [.text(item)])
    }
    guard try storedSourceFragment(itemAddress) == nil else { try clear(); return }
    let orderAddress = "workspace.json#/pageOrders/@" + item
    guard let hash = try database.rows("SELECT hash FROM records WHERE address=?", [.text(orderAddress)]).first?[0].text,
      let exists = try storedSourceFragment(Self.sourceMembershipField(["items", item, "exists"]))?.value.decode(ContentFieldVersion.self), exists.isValid else {
      try clear(); return
    }
    if try database.rows("SELECT order_hash FROM retired_notebook_orders WHERE item_id=?", [.text(item)]).first?[0].text == hash { return }
    let order = try readPageOrder(itemID)
    guard try storedSourceFragment(Self.sourceMembershipField(["items", item, "pageIDs"]))?.value.decode(ContentFieldVersion.self) == order.fieldVersion else {
      throw NotebookStorageError.invalidTransaction("retired notebook page order version")
    }
    try clear()
    let root = try readPageOrderNode(order.visibleRoot)
    var position = 0
    func walk(_ hash: String, height: Int) throws {
      try Task.checkCancellation()
      let node = try readPageOrderNode(hash)
      guard node.height == height else { throw NotebookStorageError.invalidTransaction("retired page order height") }
      let first = position
      for page in node.pages {
        let id = page.uuidString.lowercased(), key = fieldKey(["items", item, "pageIDs", id])
        let address = Self.sourceMembershipField(["items", item, "pageIDs", id])
        guard let row = try storedSourceFragment(address), let version = try? row.value.decode(ContentFieldVersion.self), version.isValid,
          row == NotebookStoredFragment(address: address, file: "workspace.json", parent: "workspace.json#",
            collection: "collaboration/fields", member: key, position: 0, value: try .encode(version), collections: []) else {
          throw NotebookStorageError.invalidTransaction("retired notebook page birth")
        }
        try database.run("INSERT INTO retired_notebook_pages VALUES(?,?,?,?)", [.text(id), .text(item), .text(address), .integer(Int64(position))])
        position += 1
      }
      for child in node.children { try walk(child, height: height - 1) }
      guard position - first == node.count else { throw NotebookStorageError.invalidTransaction("retired page order count") }
    }
    try walk(order.visibleRoot, height: root.height)
    guard position == root.count else { throw NotebookStorageError.invalidTransaction("retired notebook extent") }
    try database.run("INSERT INTO retired_notebook_orders VALUES(?,?)", [.text(item), .text(hash)])
  }

  /// Eligibility alone is not source admission: an ordinary orphan delta may
  /// not allocate a PAGE even if it supplies an independently valid field key.
  func retiredNotebookMembership(ofPage pageID: UUID) throws -> NotebookRetiredPageMembership? {
    try sqlRead { database in
      let rows = try database.rows("""
        SELECT p.item_id,p.position FROM retired_notebook_pages p
        JOIN retired_notebook_orders o ON o.item_id=p.item_id
        JOIN records birth ON birth.address=p.birth_address
        JOIN records ordering ON ordering.address='workspace.json#/pageOrders/@'||p.item_id AND ordering.hash=o.order_hash
        WHERE p.page_id=? AND NOT EXISTS(SELECT 1 FROM records item WHERE item.address='workspace.json#/items/@'||p.item_id)
        """, [.text(pageID.uuidString.lowercased())])
      guard let row = rows.first, let id = row[0].text.flatMap(UUID.init(uuidString:)), let position = row[1].integer else { return nil }
      return .init(itemID: id, position: Int(position))
    }
  }

  func pageSourceOwnerID(ofPage pageID: UUID) throws -> UUID? {
    if let live = try ownerItemID(ofPage: pageID) { return live }
    guard try hasStoredValue(pageFile(pageID)) else { return nil }
    return try retiredNotebookMembership(ofPage: pageID)?.itemID
  }

  @discardableResult
  func requireRetiredPageBaseline(pageID: UUID, itemID: UUID) throws -> NotebookStoredFragment {
    guard try ownerItemID(ofPage: pageID) == nil,
      try retiredNotebookMembership(ofPage: pageID)?.itemID == itemID,
      let root = try storedSourceFragment(pageFile(pageID) + "#") else {
      throw NotebookStorageError.invalidTransaction("retired PAGE baseline is not admitted")
    }
    // This body was admitted by the native PAGE writer. Undo changes only
    // membership: it must not decode every old element/stroke a second time.
    _ = try pageSourceHeader(root, id: pageID)
    guard let drawing = try storedSourceFragment(root.address + "/drawingData"),
      drawing.file == root.file, drawing.parent == root.address,
      drawing.collection == "drawingData", drawing.member.isEmpty, drawing.position == 0 else {
      throw NotebookStorageError.invalidTransaction("retired PAGE drawing identity")
    }
    return root
  }

  /// Atomic append + delete has no live intermediate item on another replica.
  /// Admit that PAGE only with its complete typed birth in this very manifest;
  /// receiving metadata earlier cannot grant a later arbitrary orphan source.
  func hasRetiredPageBirthClosure(pageID: UUID, membership: NotebookRetiredPageMembership,
    records: NotebookIncomingRecords) throws -> Bool {
    let item = membership.itemID.uuidString.lowercased(), page = pageID.uuidString.lowercased()
    let root = pageFile(pageID) + "#", orderAddress = "workspace.json#/pageOrders/@" + item
    let birthKey = fieldKey(["items", item, "pageIDs", page]), existsKey = fieldKey(["items", item, "exists"])
    guard try records.fragment(root) != nil, try records.fragment(root + "/drawingData") != nil,
      let orderRow = try records.fragment(orderAddress),
      try records.fragment(Self.sourceMembershipField(["items", item, "pageIDs", page])) != nil,
      try records.fragment(Self.sourceMembershipField(["items", item, "exists"])) != nil,
      try records.field(parent: "workspace.json#", collection: "collaboration/fields", key: birthKey, delivered: true) != nil,
      try records.field(parent: "workspace.json#", collection: "collaboration/fields", key: existsKey, delivered: true) != nil else { return false }
    let incoming = try orderRow.value.decode(NotebookPageOrderRegister.self)
    try incoming.validate()
    let admitted = try readPageOrder(membership.itemID)
    if incoming.visibleRoot == admitted.visibleRoot { return true } // Derived membership binds this exact root.
    // A rare concurrent order join can change slots; prove membership in the
    // delivered root as well, using the existing bounded streaming vector.
    var contains = false
    try NotebookPageOrderVector.visitChangedPages(from: nil, to: incoming.visibleRoot,
      read: { try readPageOrderNode($0) }, visit: { _, id in if id == pageID { contains = true } })
    return contains
  }

  private static func sourceMembershipField(_ parts: [String]) -> String {
    "workspace.json#/collaboration/fields/@" + fieldKey([fieldKey(parts)])
  }

  private func storedSourceFragment(_ address: String) throws -> NotebookStoredFragment? {
    try storedFragments(address: address, descendants: false).first
  }
}

extension NotebookStore {
  /// Reuse the native source types and physical codec for one atom at a time.
  /// The source budget is the existing agent-command 8 MiB value boundary, not
  /// a lower UI read-window limit. Exhaustion refuses the whole transaction.
  @discardableResult
  func validateStoredSourceAtom(address: String, maximumBytes: Int64 = 8 * 1_024 * 1_024,
    canonical: (JSONValue) throws -> JSONValue) throws -> Int {
    let rows = try boundedStoredFragments([(address, true)], maximumCount: NotebookSQLReadAllowance.agentCommand.rows,
      maximumBytes: maximumBytes, budget: "lifecycle_restore_source")
    guard let root = rows.first(where: { $0.address == address }) else { throw NotebookStorageError.corruptRecord(address) }
    let value = try canonical(NotebookRecordCodec.decode(rows, root: address))
    let encoded = try NotebookRecordCodec.encode(value, file: root.file, address: address,
      parent: root.parent, collection: root.collection, member: root.member, position: root.position)
    guard Dictionary(uniqueKeysWithValues: encoded.map { ($0.address, $0) })
      == Dictionary(uniqueKeysWithValues: rows.map { ($0.address, $0) }) else {
      throw NotebookStorageError.invalidTransaction("noncanonical restored source")
    }
    return rows.count
  }

  private func visitStoredSourceMembers(parent: String, collection: String,
    _ body: (NotebookStoredFragment) throws -> Void) throws {
    let database = currentSQL!; var member = ""
    while true {
      let rows = try database.rows("SELECT address,member FROM records WHERE parent=? AND collection=? AND member>? ORDER BY member LIMIT 64",
        [.text(parent), .text(collection), .text(member)])
      guard let last = rows.last?[1].text else { return }
      for row in rows {
        try Task.checkCancellation()
        guard let fragment = try storedSourceFragment(row[0].text!) else { throw NotebookStorageError.corruptRecord(row[0].text!) }
        try body(fragment)
      }
      member = last
    }
  }

  func validateStoredPageSource(file: String) throws {
    let database = currentSQL!, root = file + "#", drawingRoot = root + "/drawingData"
    guard let header = try storedSourceFragment(root), let drawingHeader = try storedSourceFragment(drawingRoot),
      let id = header.value["id"]?.string.flatMap(UUID.init(uuidString:)), pageFile(id) == file else {
      throw NotebookStorageError.invalidTransaction("restored page identity")
    }
    let page = try pageSourceHeader(header, id: id)
    var covered = 1, fields = 0, computations = 0
    try visitStoredSourceMembers(parent: root, collection: "elements") { row in
      covered += try validateStoredSourceAtom(address: row.address) { raw in
        let element = try raw.decode(AgentElement.self)
        guard PageDocument.elementsAreValid([element], in: page.size), collaborationIdentity(element.id) == row.member,
          row.address == root + "/elements/@" + fieldKey([row.member]) else {
          throw NotebookStorageError.invalidTransaction("restored page element")
        }
        return try .encode(element)
      }
    }
    try visitStoredSourceMembers(parent: root, collection: "collaboration/fields") { row in
      let version = try row.value.decode(ContentFieldVersion.self)
      guard version.isValid, row.member.utf8.count <= 2048,
        row == NotebookStoredFragment(address: root + "/collaboration/fields/@" + fieldKey([row.member]), file: file,
          parent: root, collection: "collaboration/fields", member: row.member, position: 0,
          value: try .encode(version), collections: []) else { throw NotebookStorageError.invalidTransaction("restored page causal field") }
      fields += 1; covered += 1
    }
    guard fields <= CollaborativeContent.maximumFieldCount else { throw NotebookStorageError.limitExceeded("page_causal_fields") }
    var drawingValue = drawingHeader.value.setting("actions", .array([]))
    let baselineAddress = drawingRoot + "/baselinePNG"
    if let baseline = try storedSourceFragment(baselineAddress) {
      drawingValue = drawingValue.setting("baselinePNG", baseline.value)
      covered += 1
    }
    let drawing = try drawingValue.decode(PageInkDrawing.self)
    guard drawing.isValid else { throw PageInkDrawing.InkError.invalidDrawing }
    // Only header + optional baseline are materialized here, never all strokes.
    let drawingRows = try NotebookRecordCodec.encode(.encode(drawing), file: file, address: drawingRoot,
      parent: root, collection: "drawingData", member: "", position: 0)
    guard drawingRows.count == (try storedSourceFragment(baselineAddress) == nil ? 1 : 2) else {
      throw NotebookStorageError.invalidTransaction("restored ink header")
    }
    for row in drawingRows {
      guard try storedSourceFragment(row.address) == row else { throw NotebookStorageError.invalidTransaction("restored ink header") }
    }
    covered += 1
    try visitStoredSourceMembers(parent: drawingRoot, collection: "actions") { row in
      covered += try validateStoredSourceAtom(address: row.address) { raw in
        let action = try raw.decode(PageInkAction.self)
        guard action.isValid, action.sequence > 0, action.id.uuidString.lowercased() == row.member,
          row.address == drawingRoot + "/actions/@" + row.member else { throw PageInkDrawing.InkError.invalidDrawing }
        return try .encode(action)
      }
    }
    try visitStoredSourceMembers(parent: root, collection: "computations") { row in
      let computation = try row.value.decode(NotebookComputation.self)
      guard computation.isValid, computation.source.pageID == id, computation.source.region.isContained(in: page.size),
        try row.value == JSONValue.encode(computation), row.collections.isEmpty else {
        throw NotebookStorageError.invalidTransaction("restored page computation")
      }
      computations += 1; covered += 1
    }
    guard computations <= 256 else { throw NotebookStorageError.limitExceeded("page_computations") }
    guard computations == 0 || header.collections.contains(.init(path: ["computations"], kind: .array)) else {
      throw NotebookStorageError.invalidTransaction("missing restored computation collection")
    }
    let actual = try database.rows("SELECT count(*) FROM records WHERE file=?", [.text(file)]).first![0].integer!
    guard Int64(covered) == actual else { throw NotebookStorageError.invalidTransaction("unowned restored page record") }
  }
}

extension NotebookStore {
  func pageSourceHeader(_ row: NotebookStoredFragment, id: UUID) throws -> PageDocument {
    let file = pageFile(id), root = file + "#"
    let value = row.value.setting("elements", .array([])).setting("drawingData", try .encode(Data()))
      .setting("collaboration", .object(["fields": .object([:])]))
    let page = try value.decode(PageDocument.self)
    guard page.id == id, page.isValid, row.parent == nil, row.collection.isEmpty, row.member.isEmpty,
      row.position == 0, row.collections.contains(.init(path: ["drawingData"], kind: .pageInk)),
      row.collections.contains(.init(path: ["elements"], kind: .array)),
      row.collections.allSatisfy({ [.init(path: ["drawingData"], kind: .pageInk), .init(path: ["elements"], kind: .array),
        .init(path: ["collaboration", "fields"], kind: .dictionary), .init(path: ["computations"], kind: .array)].contains($0) }) else {
      throw NotebookStorageError.corruptRecord(root)
    }
    let canonical = try NotebookRecordCodec.encode(.encode(page), file: file).first { $0.address == root }
    guard canonical == row.replacing(value: row.value, collections: row.collections.filter { $0.path != ["computations"] }) else {
      throw NotebookStorageError.corruptRecord(root)
    }
    return page
  }
}

extension NotebookStore {
  /// The existing register owns conflict decisions. Equal/dominated roots do
  /// not enumerate any page IDs; incomparable retired cuts retain their union.
  func mergeRetiredNotebookOrder(_ incoming: NotebookPageOrderRegister,
    previous: NotebookPageOrderRegister?) throws -> NotebookPageOrderRegister {
    guard let previous else { return incoming }
    if previous == incoming { return previous }
    let heads = try NotebookPageOrderRegister.frontier(previous.heads + incoming.heads)
    if previous.visibleRoot == incoming.visibleRoot {
      let joined = NotebookPageOrderRegister(heads: heads, visibleRoot: incoming.visibleRoot)
      try joined.validate(); return joined
    }
    if incoming.heads != previous.heads {
      if heads == incoming.heads { return incoming }
      if heads == previous.heads { return previous }
    }
    let a = try NotebookPageOrderVector.materialize(previous.visibleRoot, read: { try readPageOrderNode($0) })
    let b = try NotebookPageOrderVector.materialize(incoming.visibleRoot, read: { try readPageOrderNode($0) })
    return try NotebookPageOrderRegister.normalize([previous, incoming], live: Set(a).union(b),
      read: { try readPageOrderNode($0) }, write: { try writePageOrderNode($0) }).register
  }
}

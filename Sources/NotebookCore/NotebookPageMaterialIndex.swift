import CoreGraphics
import Foundation

extension NotebookStore {
  // Local material admission changes only a disposable index. Shared content,
  // history, wire and manifest stay intact.
  static let pageMaterialDatabaseVersion: Int64 = 30

  static func createPageMaterialIndex(_ database: NotebookSQLConnection) throws {
    try database.run("""
      CREATE TABLE IF NOT EXISTS page_material_entries(
        address TEXT PRIMARY KEY REFERENCES records(address) ON DELETE CASCADE,
        page_id TEXT NOT NULL,element_id TEXT NOT NULL,parent_id TEXT,
        position INTEGER NOT NULL,member TEXT NOT NULL,is_group INTEGER NOT NULL,
        has_paint INTEGER NOT NULL,space_key INTEGER NOT NULL,
        min_x REAL NOT NULL,max_x REAL NOT NULL,min_y REAL NOT NULL,max_y REAL NOT NULL)
      """)
    try database.run("CREATE INDEX IF NOT EXISTS page_material_children ON page_material_entries(page_id,parent_id,element_id)")
    for (name, order) in [("min_x", "min_x"), ("max_x", "max_x"), ("min_y", "min_y"), ("max_y", "max_y")] {
      try database.run("CREATE INDEX IF NOT EXISTS page_material_\(name) ON page_material_entries(page_id,parent_id,\(order)) WHERE has_paint=1")
    }
    try database.run("CREATE VIRTUAL TABLE IF NOT EXISTS page_material_ranges USING rtree(entry,min_x,max_x,min_y,max_y,min_space,max_space)")
    let values = "new.rowid,new.min_x,new.max_x,new.min_y,new.max_y,new.space_key,new.space_key"
    try database.run("CREATE TRIGGER IF NOT EXISTS page_material_insert AFTER INSERT ON page_material_entries WHEN new.has_paint=1 BEGIN INSERT INTO page_material_ranges VALUES(" + values + "); END")
    try database.run("CREATE TRIGGER IF NOT EXISTS page_material_remove AFTER DELETE ON page_material_entries BEGIN DELETE FROM page_material_ranges WHERE entry=old.rowid; END")
    try database.run("CREATE TRIGGER IF NOT EXISTS page_material_update AFTER UPDATE ON page_material_entries BEGIN DELETE FROM page_material_ranges WHERE entry=old.rowid; INSERT INTO page_material_ranges SELECT " + values + " WHERE new.has_paint=1; END")
    database.pageMaterialIndexAdmitted = true
  }

  func pageMaterialIndexIsAdmitted(_ database: NotebookSQLConnection) throws -> Bool {
    if let value = database.pageMaterialIndexAdmitted { return value }
    let value = try !database.rows("SELECT 1 FROM sqlite_master WHERE name='page_material_entries' AND type='table'").isEmpty
    database.pageMaterialIndexAdmitted = value
    return value
  }

  func rebuildPageMaterialIndex(database: NotebookSQLConnection) throws {
    try Self.createPageMaterialIndex(database)
    try database.run("DELETE FROM page_material_entries")
    // Streaming addressed sources. Admission never assembles a PageDocument or
    // changes content hashes, history, membership, delivery or causal versions.
    var after = ""
    while let row = try database.rows("SELECT r.address,b.data FROM records r JOIN blobs b ON b.hash=r.hash WHERE r.file LIKE 'pages/%' AND r.collection='elements' AND r.address>? ORDER BY r.address LIMIT 1", [.text(after)]).first {
      after = row[0].text!
      try notePageMaterialChange(database.decodeFragmentEnvelope(row[1].blob!), database: database)
    }
    try refreshPageMaterialIndex(database: database)
    var inkAfter = ""
    while let row = try database.rows("SELECT r.address,b.data FROM records r JOIN blobs b ON b.hash=r.hash WHERE r.file LIKE 'pages/%' AND r.collection='actions' AND r.address>? ORDER BY r.address LIMIT 1", [.text(inkAfter)]).first {
      inkAfter = row[0].text!
      try indexPageInkWindow(database.decodeFragmentEnvelope(row[1].blob!), database: database)
    }
  }

  func notePageMaterialChange(_ fragment: NotebookStoredFragment, database: NotebookSQLConnection) throws {
    guard fragment.file.hasPrefix("pages/"), ["elements", "collaboration/fields"].contains(fragment.collection),
      try pageMaterialIndexIsAdmitted(database) else { return }
    let root = fragment.file + "#"
    if fragment.collection == "collaboration/fields" {
      let parts = fragment.member.components(separatedBy: "/")
      guard parts.count == 4, parts[0] == "elements", parts[2] == "graphic", parts[3] == "sourceInkIDs" else { return }
      try database.noteOwner(.pageMaterial, root + "/elements/@" + parts[1])
      return
    }
    guard let id = fragment.value["id"]?.string else { throw NotebookStorageError.corruptRecord(fragment.address) }
    let page = URL(fileURLWithPath: fragment.file).deletingPathExtension().lastPathComponent
    let old = try database.rows("SELECT parent_id,has_paint,is_group FROM page_material_entries WHERE address=?", [.text(fragment.address)]).first
    try database.noteOwner(.pageMaterial, fragment.address)
    for parent in [old?[0].text, fragment.value["parentID"]?.string].compactMap({ $0 }) {
      try database.noteOwner(.pageMaterialGroup, root + "/elements/@" + fieldKey([collaborationIdentity(parent)]))
    }
    for address in try dependentGraphicAddresses(owner: "page:" + page, id: id) {
      try database.noteOwner(.pageMaterial, address)
    }
    // Old neighbors are captured before deleting their immutable source index.
    for row in try database.rows("SELECT DISTINCT b.address FROM graphic_sources a JOIN graphic_sources b ON a.owner=b.owner AND a.stroke_id=b.stroke_id WHERE a.address=?", [.text(fragment.address)]) {
      try database.noteOwner(.pageMaterial, row[0].text!)
    }
    if fragment.value["kind"]?.string == "group", old == nil || old?[1].integer == 0 || old?[2].integer != 1 {
      // Resolving an orphan/cycle is the exceptional membership walk. Moving a
      // rooted whole touches its aggregate and cross-frame links, no children.
      try database.run("""
        WITH RECURSIVE members(address,element_id) AS (
          SELECT address,element_id FROM page_material_entries WHERE page_id=? AND parent_id=?
          UNION SELECT r.address,r.element_id FROM members m CROSS JOIN page_material_entries r
            ON r.parent_id=m.element_id WHERE r.page_id=?
        ) INSERT OR IGNORE INTO notebook_pending_owners(kind,key,value)
          SELECT ?,address,NULL FROM members
        """, [.text(page), .text(collaborationIdentity(id)), .text(page), .text(NotebookPendingOwner.pageMaterial.rawValue)])
    }
  }

  func refreshPageMaterialIndex(database: NotebookSQLConnection) throws {
    while let address = try database.takeOwner(.pageMaterial) {
      guard try !database.hasOwner(.pageMaterialProjected, address) else { continue }
      guard let row = try storedFragments(address: address, descendants: false).first,
        let pageID = UUID(uuidString: URL(fileURLWithPath: row.file).deletingPathExtension().lastPathComponent),
        let id = row.value["id"]?.string else { continue }
      guard let element = try readPageElement(pageID: pageID, elementID: id) else { continue }
      if element.kind == .group {
        try database.noteOwner(.pageMaterialGroup, address)
        continue
      }
      for dependent in try dependentGraphicAddresses(owner: "page:" + pageID.uuidString.lowercased(), id: id) {
        if try !database.hasOwner(.pageMaterialProjected, dependent) { try database.noteOwner(.pageMaterial, dependent) }
      }
      let bounds: CGRect?
      if let graphic = element.graphic {
        let sources = NotebookPageMaterialSources(store: self, pageID: pageID, capturesVersions: false)
        try sources.include(id)
        let graph = try sources.graph()
        bounds = graph.node(id).flatMap { NotebookGraphicVisibility.bounds($0, in: graph, parent: true) }
        // The shared claim component can reveal a previously hidden body.
        for claimant in sources.claimedElementIDs where collaborationIdentity(claimant) != collaborationIdentity(id) {
          // Refresh only unprojected addresses; this component's priority has
          // already settled in the enclosing accepted transaction.
          let candidate = pageFile(pageID) + "#/elements/@" + fieldKey([collaborationIdentity(claimant)])
          if try !database.hasOwner(.pageMaterial, candidate), try !database.hasOwner(.pageMaterialProjected, candidate) {
            try database.noteOwner(.pageMaterial, candidate)
          }
        }
        if graphic.connection != nil { try indexPageMaterialBindings(element, pageID: pageID, graph: graph, database: database) }
      } else {
        let placement = try NotebookElementPlacement(id: id, frame: element.frame).updating(frame: element.frame, basis: element.basis)
        bounds = NotebookGraphicVisibility.outward(NotebookElementPresentation(element, placement: placement).bounds, through: .identity)
      }
      try database.noteOwner(.pageMaterialProjected, address)
      try updatePageMaterialEntry(row, element: element, bounds: bounds, database: database)
    }
    if database.pendingOwnersPrepared {
      try database.run("DELETE FROM notebook_pending_owners WHERE kind=?", [.text(NotebookPendingOwner.pageMaterialProjected.rawValue)])
    }
    while let address = try database.takeOwner(.pageMaterialGroup) {
      guard let row = try storedFragments(address: address, descendants: false).first,
        let pageID = UUID(uuidString: URL(fileURLWithPath: row.file).deletingPathExtension().lastPathComponent),
        let id = row.value["id"]?.string,
        let element = try readPageElement(pageID: pageID, elementID: id), element.kind == .group else { continue }
      let resolver = NotebookElementPlacement.Resolver { try self.elementGroupingSource(target: .init(kind: .page, id: pageID), id: $0) }
      let placement = try resolver.resolve(id)
      let local = try pageMaterialGroupBounds(pageID: pageID, parentID: id, database: database)
      let bounds = placement.flatMap { placement in local.map { NotebookGraphicVisibility.outward($0, through: placement.localTransform) } }
      try updatePageMaterialEntry(row, element: element, bounds: bounds, database: database)
    }
  }

  private func indexPageMaterialBindings(_ element: AgentElement, pageID: UUID, graph: NotebookGraphicGraph,
    database: NotebookSQLConnection) throws {
    let address = pageFile(pageID) + "#/elements/@" + fieldKey([collaborationIdentity(element.id)])
    let own = Set(graph.placement(element.id)?.ancestors.map(collaborationIdentity) ?? [])
    var affected = Set<String>()
    for binding in element.graphic?.connection?.bindings ?? [] {
      affected.formUnion(own.symmetricDifference(Set(graph.placement(binding.elementID)?.ancestors.map(collaborationIdentity) ?? [])))
    }
    try database.run("DELETE FROM graphic_bindings WHERE address=? AND terminal LIKE 'basis:%'", [.text(address)])
    for id in affected {
      try database.run("INSERT INTO graphic_bindings(address,owner,target_id,terminal) VALUES(?,?,?,?)", [.text(address),
        .text("page:" + pageID.uuidString.lowercased()), .text(id), .text("basis:" + id)])
    }
  }

  private func updatePageMaterialEntry(_ fragment: NotebookStoredFragment, element: AgentElement, bounds: CGRect?,
    database: NotebookSQLConnection) throws {
    let page = URL(fileURLWithPath: fragment.file).deletingPathExtension().lastPathComponent
    let parent = element.parentID.map(collaborationIdentity)
    let box = bounds ?? .zero
    guard !box.isInfinite, [box.minX, box.maxX, box.minY, box.maxY].allSatisfy(\.isFinite) else {
      throw NotebookStorageError.limitExceeded("page_material_bounds")
    }
    let old = try database.rows("SELECT parent_id,has_paint,min_x,max_x,min_y,max_y,position,member,is_group FROM page_material_entries WHERE address=?", [.text(fragment.address)]).first
    if let old, old[0].text == parent, old[1].integer == (bounds == nil ? 0 : 1),
      old[2].spatialNumber == box.minX, old[3].spatialNumber == box.maxX,
      old[4].spatialNumber == box.minY, old[5].spatialNumber == box.maxY,
      old[6].integer == Int64(fragment.position), old[7].text == fragment.member,
      old[8].integer == (element.kind == .group ? 1 : 0) { return }
    try database.run("""
      INSERT INTO page_material_entries(address,page_id,element_id,parent_id,position,member,is_group,has_paint,space_key,min_x,max_x,min_y,max_y)
      VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(address) DO UPDATE SET
        element_id=excluded.element_id,parent_id=excluded.parent_id,position=excluded.position,member=excluded.member,
        is_group=excluded.is_group,has_paint=excluded.has_paint,space_key=excluded.space_key,
        min_x=excluded.min_x,max_x=excluded.max_x,min_y=excluded.min_y,max_y=excluded.max_y
      """, [.text(fragment.address), .text(page), .text(collaborationIdentity(element.id)), parent.map(NotebookSQLValue.text) ?? .null,
        .integer(Int64(fragment.position)), .text(fragment.member), .integer(element.kind == .group ? 1 : 0), .integer(bounds == nil ? 0 : 1),
        .integer(Self.spatialSpaceKey(board: page, parent: parent)), .real(box.minX), .real(box.maxX), .real(box.minY), .real(box.maxY)])
    for id in Set([old?[0].text, parent].compactMap({ $0 })) {
      try database.noteOwner(.pageMaterialGroup, fragment.file + "#/elements/@" + fieldKey([id]))
    }
  }

  func pageMaterialGroupBounds(pageID: UUID, parentID: String, database: NotebookSQLConnection) throws -> CGRect? {
    let predicate = " FROM page_material_entries WHERE page_id=? AND parent_id=? AND has_paint=1"
    let arguments: [NotebookSQLValue] = [.text(pageID.uuidString.lowercased()), .text(collaborationIdentity(parentID))]
    func extreme(_ field: String, descending: Bool = false) throws -> Double? {
      try database.rows("SELECT " + field + predicate + " ORDER BY " + field + (descending ? " DESC" : "") + " LIMIT 1", arguments).first?[0].spatialNumber
    }
    guard let x = try extreme("min_x"), let y = try extreme("min_y"),
      let right = try extreme("max_x", descending: true), let bottom = try extreme("max_y", descending: true) else { return nil }
    return .init(x: x, y: y, width: right - x, height: bottom - y)
  }
}

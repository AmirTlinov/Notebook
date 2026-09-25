import Foundation

/// Coverage describes geometry, not complete ownership. Every retained contact
/// keeps its whole immutable body. Erasers cover the whole retained pen extent,
/// not just the visible pixels, so selection and clipping have the same source.
public struct NotebookSpatialInkWindow: Sendable {
  public let journal: SpatialInkJournal
  public let records: NotebookSpatialInkWindowRecords
  public let coverage: [SurfaceID: WorkspaceSpatialBounds]
  public let cursor: UInt64
  public let pinnedActionIDs: Set<UUID>
  public let elementIDs: [SurfaceID: Set<String>]

  public func covers(_ requested: [SurfaceID: WorkspaceSpatialBounds], pins: Set<UUID> = [], elements: [SurfaceID: [String]] = [:]) -> Bool {
    elements.allSatisfy { Set($0.value).isSubset(of: elementIDs[$0.key] ?? []) }
      && pins.isSubset(of: Set(journal.actions.map(\.id))) && requested.allSatisfy { surface, bounds in
      coverage[surface]?.contains(bounds) == true
    }
  }
}

/// The candidate query and its exact immutable record identities. Repeating it
/// detects additions, removals and Undo without loading a single sample body.
public struct NotebookSpatialInkWindowRecords: Equatable, Sendable {
  public let coverage: [SurfaceID: WorkspaceSpatialBounds]
  public let pinnedActionIDs: Set<UUID>
  public let elementIDs: [SurfaceID: Set<String>]
  public let hashes: [String: String]

  public func isCurrent(_ store: NotebookStore) throws -> Bool {
    try store.readSpatialInkWindowRecords(coverage: coverage, pinnedActionIDs: pinnedActionIDs,
      elementIDs: elementIDs.mapValues { $0.sorted() }) == self
  }
}

extension NotebookStore {
  public func readSpatialInkActions(ids: Set<UUID>) throws -> [SpatialInkAction] {
    guard ids.count <= 8192 else { throw NotebookStorageError.limitExceeded("ink_action_pins") }
    return try readTransaction { _ in try ids.sorted().map { try readSpatialInkAction("spatial-ink.json#/actions/@" + $0.uuidString.lowercased()) } }
  }

  static func createInkWindowIndex(_ database: NotebookSQLConnection) throws {
    let columns = Set(try database.rows("PRAGMA table_info(ink_surfaces)").compactMap { $0[1].text })
    for (name, type) in [("min_tx", "INTEGER"), ("min_ty", "INTEGER"), ("min_x", "REAL"), ("min_y", "REAL"),
      ("max_tx", "INTEGER"), ("max_ty", "INTEGER"), ("max_x", "REAL"), ("max_y", "REAL"),
      ("space_key", "INTEGER"), ("active", "INTEGER NOT NULL DEFAULT 0"), ("tool", "TEXT"), ("has_ink", "INTEGER NOT NULL DEFAULT 0")] where !columns.contains(name) {
      try database.run("ALTER TABLE ink_surfaces ADD COLUMN \(name) \(type)")
    }
    try database.run("CREATE INDEX IF NOT EXISTS ink_surface_content ON ink_surfaces(kind,owner_id) WHERE active=1 AND tool='pen' AND has_ink=1")
    try database.run("CREATE VIRTUAL TABLE IF NOT EXISTS ink_ranges USING rtree(entry,min_tx,max_tx,min_ty,max_ty,min_x,max_x,min_y,max_y,min_space,max_space)")
    let values = "new.rowid,new.min_tx,new.max_tx,new.min_ty,new.max_ty,CASE WHEN new.min_tx=new.max_tx THEN new.min_x ELSE 0 END,CASE WHEN new.min_tx=new.max_tx THEN new.max_x ELSE \(WorldPoint.tileSize) END,CASE WHEN new.min_ty=new.max_ty THEN new.min_y ELSE 0 END,CASE WHEN new.min_ty=new.max_ty THEN new.max_y ELSE \(WorldPoint.tileSize) END,new.space_key,new.space_key"
    try database.run("CREATE TRIGGER IF NOT EXISTS ink_range_insert AFTER INSERT ON ink_surfaces WHEN new.active=1 BEGIN INSERT INTO ink_ranges VALUES(" + values + "); END")
    try database.run("CREATE TRIGGER IF NOT EXISTS ink_range_remove AFTER DELETE ON ink_surfaces BEGIN DELETE FROM ink_ranges WHERE entry=old.rowid; END")
    try database.run("CREATE TRIGGER IF NOT EXISTS ink_range_update AFTER UPDATE ON ink_surfaces BEGIN DELETE FROM ink_ranges WHERE entry=old.rowid; INSERT INTO ink_ranges SELECT " + values + " WHERE new.active=1; END")
  }

  func indexInkWindow(_ action: SpatialInkAction, address: String, database: NotebookSQLConnection) throws {
    var bounds: [SurfaceID: WorkspaceSpatialBounds] = [:], visible = Set<SurfaceID>()
    for span in action.spans {
      if span.samples.hasVisibleInk { visible.insert(span.surface) }
      let geometry = span.samples.storage.root.geometry
      let box = geometry.bounds.insetBy(dx: -1, dy: -1)
      let origin = geometry.origin ?? .zero
      let value: WorkspaceSpatialBounds
      if !box.isNull, !box.isInfinite, [box.minX, box.minY, box.maxX, box.maxY].allSatisfy(\.isFinite) {
        value = .init(origin: origin.offsetBy(x: box.minX, y: box.minY), maximum: origin.offsetBy(x: box.maxX, y: box.maxY))
      } else {
        value = .init(origin: .init(tileX: -WorldPoint.maximumTileIndex, tileY: -WorldPoint.maximumTileIndex, localX: 0, localY: 0),
          maximum: .init(tileX: WorldPoint.maximumTileIndex, tileY: WorldPoint.maximumTileIndex, localX: WorldPoint.tileSize.nextDown, localY: WorldPoint.tileSize.nextDown))
      }
      bounds[span.surface] = bounds[span.surface].map { $0.union(value) } ?? value
    }
    for (surface, box) in bounds {
      let owner = surface.ownerID!.uuidString.lowercased(), a = box.origin, b = box.maximum
      let args: [NotebookSQLValue] = [.text(address), .text(surface.kind.rawValue), .text(owner),
        .integer(a.tileX), .integer(a.tileY), .real(a.localX), .real(a.localY),
        .integer(b.tileX), .integer(b.tileY), .real(b.localX), .real(b.localY),
        .integer(Self.spatialSpaceKey(board: surface.kind.rawValue, parent: owner)),
        .integer(action.isActive ? 1 : 0), .text(action.tool.rawValue), .integer(visible.contains(surface) ? 1 : 0)]
      try database.run("INSERT INTO ink_surfaces(address,kind,owner_id,min_tx,min_ty,min_x,min_y,max_tx,max_ty,max_x,max_y,space_key,active,tool,has_ink) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(address,kind,owner_id) DO UPDATE SET min_tx=excluded.min_tx,min_ty=excluded.min_ty,min_x=excluded.min_x,min_y=excluded.min_y,max_tx=excluded.max_tx,max_ty=excluded.max_ty,max_x=excluded.max_x,max_y=excluded.max_y,space_key=excluded.space_key,active=excluded.active,tool=excluded.tool,has_ink=excluded.has_ink", args)
    }
  }

  public func readSpatialInkWindowRecords(coverage: [SurfaceID: WorkspaceSpatialBounds], pinnedActionIDs: Set<UUID> = [],
    elementIDs: [SurfaceID: [String]] = [:]) throws -> NotebookSpatialInkWindowRecords {
    guard coverage.count <= 15, pinnedActionIDs.count <= 8192, elementIDs.values.reduce(0, { $0 + $1.count }) <= 8192,
      coverage.keys.allSatisfy({ $0.isValid && $0.kind != .page }),
      elementIDs.keys.allSatisfy({ $0.isValid && $0.kind != .page }) else { throw NotebookStorageError.limitExceeded("ink_window_owners") }
    return try readTransaction { _ in
      let database = currentSQL!, maximum = 8192
      var addresses = Set(pinnedActionIDs.map { "spatial-ink.json#/actions/@" + $0.uuidString.lowercased() })
      var eraserCoverage: [SurfaceID: [WorkspaceSpatialBounds]] = [:]
      func bounds(_ row: [NotebookSQLValue]) -> WorkspaceSpatialBounds {
        .init(origin: .init(tileX: row[4].integer!, tileY: row[5].integer!, localX: row[6].spatialNumber, localY: row[7].spatialNumber),
          maximum: .init(tileX: row[8].integer!, tileY: row[9].integer!, localX: row[10].spatialNumber, localY: row[11].spatialNumber))
      }
      func retain(_ row: [NotebookSQLValue], expands: Bool) throws {
        let address = row[0].text!
        guard addresses.contains(address) || addresses.count < maximum else { throw NotebookStorageError.limitExceeded("ink_window_actions") }
        addresses.insert(address)
        if expands, row[1].text == "pen", let kind = row[2].text.flatMap(SurfaceKind.init(rawValue:)), let owner = row[3].text.flatMap(UUID.init(uuidString:)) {
          let surface = SurfaceID(kind: kind, ownerID: owner)
          guard coverage[surface] != nil else { return }
          let value = bounds(row)
          if coverage[surface]?.contains(value) != true { eraserCoverage[surface, default: []].append(value) }
        }
      }
      let fields = "s.address,s.tool,s.kind,s.owner_id,s.min_tx,s.min_ty,s.min_x,s.min_y,s.max_tx,s.max_ty,s.max_x,s.max_y"
      func query(_ surface: SurfaceID, _ bounds: WorkspaceSpatialBounds, erasersOnly: Bool,
        _ consume: ([NotebookSQLValue]) throws -> Void) throws {
        let a = bounds.origin, b = bounds.maximum, owner = surface.ownerID!.uuidString.lowercased()
        let space = NotebookSQLValue.integer(Self.spatialSpaceKey(board: surface.kind.rawValue, parent: owner))
        let sql = "SELECT " + fields + " FROM ink_ranges r CROSS JOIN ink_surfaces s ON s.rowid=r.entry WHERE r.min_space<=? AND r.max_space>=? AND r.min_tx<=? AND r.max_tx>=? AND r.min_ty<=? AND r.max_ty>=? AND r.min_x<=? AND r.max_x>=? AND r.min_y<=? AND r.max_y>=? AND s.kind=? AND s.owner_id=? AND s.active=1 " + (erasersOnly ? "AND s.tool='eraser' " : "") + "AND (s.min_tx<? OR (s.min_tx=? AND s.min_x<=?)) AND (s.max_tx>? OR (s.max_tx=? AND s.max_x>=?)) AND (s.min_ty<? OR (s.min_ty=? AND s.min_y<=?)) AND (s.max_ty>? OR (s.max_ty=? AND s.max_y>=?)) LIMIT ?"
        try database.forEachRow(sql, [space, space, .integer(b.tileX), .integer(a.tileX), .integer(b.tileY), .integer(a.tileY),
          .real(a.tileX == b.tileX ? b.localX : WorldPoint.tileSize), .real(a.tileX == b.tileX ? a.localX : 0),
          .real(a.tileY == b.tileY ? b.localY : WorldPoint.tileSize), .real(a.tileY == b.tileY ? a.localY : 0),
          .text(surface.kind.rawValue), .text(owner), .integer(b.tileX), .integer(b.tileX), .real(b.localX),
          .integer(a.tileX), .integer(a.tileX), .real(a.localX), .integer(b.tileY), .integer(b.tileY), .real(b.localY),
          .integer(a.tileY), .integer(a.tileY), .real(a.localY), .integer(erasersOnly ? -1 : Int64(maximum + 1))], consume)
      }
      for (surface, bounds) in coverage {
        if surface.kind == .board { try requireLiveBoard(surface.ownerID!) }
        try query(surface, bounds, erasersOnly: false) { try retain($0, expands: true) }
      }
      for id in pinnedActionIDs {
        try database.forEachRow("SELECT " + fields + " FROM ink_surfaces s WHERE s.address=?", [.text("spatial-ink.json#/actions/@" + id.uuidString.lowercased())]) {
          try retain($0, expands: true)
        }
      }
      for (surface, regions) in eraserCoverage {
        // One broad phase per owner, not one repeated query per retained pen.
        // The exact tiled index excludes gaps before the action admission limit;
        // neither false positives nor accepted rows retain a second body copy.
        let retained = WorkspaceSpatialIndex(entries: regions.enumerated().map {
          .init(id: .element(String($0.offset)), bounds: $0.element, zIndex: 0)
        })
        let envelope = regions.dropFirst().reduce(regions[0]) { $0.union($1) }
        try query(surface, envelope, erasersOnly: true) { row in
          guard !retained.intersections(in: bounds(row), limit: 1).entries.isEmpty else { return }
          try retain(row, expands: false)
        }
      }
      // Figure erasure follows its addressed source, even after that figure was
      // moved away from the old eraser's physical bounding rectangle.
      for (surface, ids) in elementIDs {
        for id in Set(ids) {
          let rows = try database.rows("SELECT e.address FROM ink_element_erasures e JOIN ink_surfaces s ON s.address=e.address AND s.kind=e.kind AND s.owner_id=e.owner_id WHERE e.kind=? AND e.owner_id=? AND e.element_id=? AND s.active=1 LIMIT ?",
            [.text(surface.kind.rawValue), .text(surface.ownerID!.uuidString.lowercased()), .text(collaborationIdentity(id)), .integer(Int64(maximum + 1))])
          for row in rows {
            guard addresses.contains(row[0].text!) || addresses.count < maximum else { throw NotebookStorageError.limitExceeded("ink_window_actions") }
            addresses.insert(row[0].text!)
          }
        }
      }
      var hashes: [String: String] = [:]
      for address in addresses.sorted() {
        for row in try database.rows("SELECT address,hash FROM records WHERE address=? OR address=? ORDER BY address",
          [.text(address), .text(address + "/spans")]) {
          hashes[row[0].text!] = row[1].text!
        }
      }
      return .init(coverage: coverage, pinnedActionIDs: pinnedActionIDs, elementIDs: elementIDs.mapValues(Set.init), hashes: hashes)
    }
  }

  public func readSpatialInkWindow(coverage: [SurfaceID: WorkspaceSpatialBounds], pinnedActionIDs: Set<UUID> = [],
    elementIDs: [SurfaceID: [String]] = [:]) throws -> NotebookSpatialInkWindow {
    try readTransaction { _ in
      let records = try readSpatialInkWindowRecords(coverage: coverage, pinnedActionIDs: pinnedActionIDs, elementIDs: elementIDs)
      var actions: [SpatialInkAction] = [], bytes = 0
      for address in records.hashes.keys.sorted() where !address.hasSuffix("/spans") {
        let action = try readSpatialInkAction(address)
        bytes += action.spans.reduce(0) { $0 + $1.samples.payloadBytes }
        guard bytes <= 64 * 1024 * 1024 else { throw NotebookStorageError.limitExceeded("ink_window_bytes") }
        actions.append(action)
      }
      let stamp = try readSpatialInk(surfaces: []).stamp
      return .init(journal: .init(actions: actions.sorted { $0.stamp < $1.stamp }, stamp: stamp), records: records, coverage: coverage,
        cursor: try currentChangeCursor(), pinnedActionIDs: pinnedActionIDs, elementIDs: elementIDs.mapValues(Set.init))
    }
  }
}

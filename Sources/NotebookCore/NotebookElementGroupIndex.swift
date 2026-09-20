import CoreGraphics
import Foundation

extension NotebookSQLValue {
  var spatialNumber: Double { if case .real(let value) = self { return value }; return Double(integer ?? 0) }
}

extension NotebookStore {
  static func createElementGroupSpatialIndex(_ database: NotebookSQLConnection) throws {
    let columns = Set(try database.rows("PRAGMA table_info(spatial_entries)").compactMap { $0[1].text })
    for (name,type) in [("parent_id","TEXT"),("is_group","INTEGER NOT NULL DEFAULT 0"),
      ("has_paint","INTEGER NOT NULL DEFAULT 1"),("non_graphic","INTEGER NOT NULL DEFAULT 0"),("space_key","INTEGER NOT NULL DEFAULT 0"),("max_z","REAL NOT NULL DEFAULT 0"),("lower_key","TEXT NOT NULL DEFAULT ''")] where !columns.contains(name) {
      try database.run("ALTER TABLE spatial_entries ADD COLUMN \(name) \(type)")
    }
    if !columns.contains("lower_key") {
      try database.run("UPDATE spatial_entries SET max_z=z_index,lower_key=paint_key")
    }
    try database.run("DROP INDEX IF EXISTS spatial_board_tiles")
    try database.run("CREATE INDEX IF NOT EXISTS spatial_item_tiles ON spatial_entries(board_id,min_tx,min_ty,layer,z_index,paint_key) WHERE kind='item'")
    let newRangeIndex = try database.rows("SELECT 1 FROM sqlite_master WHERE name='spatial_ranges'").isEmpty
    try database.run("CREATE VIRTUAL TABLE IF NOT EXISTS spatial_ranges USING rtree(entry,min_tx,max_tx,min_ty,max_ty,min_x,max_x,min_y,max_y,min_space,max_space)")
    let values = "new.rowid,new.min_tx,new.max_tx,new.min_ty,new.max_ty,CASE WHEN new.min_tx=new.max_tx THEN new.min_x ELSE 0 END,CASE WHEN new.min_tx=new.max_tx THEN new.max_x ELSE \(WorldPoint.tileSize) END,CASE WHEN new.min_ty=new.max_ty THEN new.min_y ELSE 0 END,CASE WHEN new.min_ty=new.max_ty THEN new.max_y ELSE \(WorldPoint.tileSize) END,new.space_key,new.space_key"
    try database.run("CREATE TRIGGER IF NOT EXISTS spatial_range_insert AFTER INSERT ON spatial_entries WHEN new.has_paint=1 BEGIN INSERT INTO spatial_ranges VALUES("+values+"); END")
    try database.run("CREATE TRIGGER IF NOT EXISTS spatial_range_remove AFTER DELETE ON spatial_entries BEGIN DELETE FROM spatial_ranges WHERE entry=old.rowid; END")
    try database.run("CREATE TRIGGER IF NOT EXISTS spatial_range_update AFTER UPDATE ON spatial_entries BEGIN DELETE FROM spatial_ranges WHERE entry=old.rowid; INSERT INTO spatial_ranges SELECT "+values+" WHERE new.has_paint=1; END")
    if newRangeIndex {
      var after: Int64 = 0
      while let row = try database.rows("SELECT rowid,board_id,parent_id FROM spatial_entries WHERE rowid>? ORDER BY rowid LIMIT 1",[.integer(after)]).first {
        after=row[0].integer!
        try database.run("UPDATE spatial_entries SET space_key=? WHERE rowid=?",[.integer(spatialSpaceKey(board:row[1].text!,parent:row[2].text)),.integer(after)])
      }
    }
    // Only grouped entries pay for extrema/ordering. A whole pose reads six
    // index endpoints rather than scanning or rewriting the member records.
    for (name,parts) in [("min_x","min_tx,min_x"),("min_y","min_ty,min_y"),
      ("max_x","max_tx,max_x"),("max_y","max_ty,max_y"),("order","layer,z_index,lower_key"),("last","max_z"),("non_graphic","non_graphic")] {
      try database.run("CREATE INDEX IF NOT EXISTS spatial_group_\(name) ON spatial_entries(board_id,parent_id,\(parts)) WHERE parent_id IS NOT NULL AND has_paint=1")
    }
  }

  /// This lossy key is only an R-tree broad-phase dimension. Every result is
  /// filtered by its exact board/parent strings; a collision never means identity.
  static func spatialSpaceKey(board: String,parent: String?) -> Int64 {
    var hash: UInt32 = 2166136261
    for byte in board.utf8 { hash=(hash ^ UInt32(byte)) &* 16777619 }
    hash=(hash ^ 0) &* 16777619
    for byte in (parent ?? "").utf8 { hash=(hash ^ UInt32(byte)) &* 16777619 }
    return Int64(hash & 0x00ff_ffff)
  }

  func noteElementGroupAncestors(_ fragment: NotebookStoredFragment,database: NotebookSQLConnection) throws {
    guard let boardAddress = fragment.parent else { return }
    func address(_ id: String) -> String { boardAddress+"/board/elements/@"+fieldKey([collaborationIdentity(id)]) }
    let old = try database.rows("SELECT parent_id,has_paint FROM spatial_entries WHERE address=?",[.text(fragment.address)]).first
    var parents = [old?[0].text,fragment.value["parentID"]?.string].compactMap { $0 }
    var seen = Set<String>()
    while let parent = parents.popLast(),seen.count < 128 {
      let key = collaborationIdentity(parent)
      guard seen.insert(key).inserted else { continue }
      let source = address(parent)
      try database.noteOwner(.elementGroup,source)
      if let next = try database.rows("SELECT parent_id FROM spatial_entries WHERE address=?",[.text(source)]).first?[0].text { parents.append(next) }
    }
    if fragment.value["kind"]?.string == "group",
      old == nil || (old?[1].integer == 0 && old?[0].text != fragment.value["parentID"]?.string.map(collaborationIdentity)),
      let id = fragment.value["id"]?.string,let surface = try fragment.value["surface"]?.decode(SurfaceID.self),let owner = surface.ownerID {
      // First arrival or breaking a delivered parent cycle can make orphan
      // members resolvable; canonical addresses preserve non-UUID case.
      // This cold membership walk is not performed for an existing whole pose.
      try database.noteOwner(.elementGroup,fragment.address)
      let ownerKey = surface.kind.rawValue+":"+owner.uuidString.lowercased()
      let members = """
        WITH RECURSIVE members(address,member) AS (
          SELECT address,replace(replace(substr(address,?),'~1','/'),'~0','~')
          FROM reference_element_order WHERE owner_key=? AND parent_id=?
          UNION SELECT r.address,replace(replace(substr(r.address,?),'~1','/'),'~0','~')
          FROM members m CROSS JOIN reference_element_order r ON r.parent_id=m.member WHERE r.owner_key=?
        )
        """
      for kind in [NotebookPendingOwner.graphic,.elementGroup] {
        try database.run(members+" INSERT OR IGNORE INTO notebook_pending_owners(kind,key,value) SELECT ?,address,NULL FROM members",
          [.integer(Int64((boardAddress+"/board/elements/@").count+1)),.text(ownerKey),.text(collaborationIdentity(id)),
            .integer(Int64((boardAddress+"/board/elements/@").count+1)),.text(ownerKey),.text(kind.rawValue)])
      }
    }
  }

  /// Only ancestors below the common frame affect a connector's local shape.
  /// They extend the existing reverse binding index; common outer frames do not
  /// turn an internal edge into a dependency on every whole-pose update.
  func indexGraphicBasisDependencies(_ fragment: NotebookStoredFragment,database: NotebookSQLConnection) throws {
    guard let element = try? fragment.value.decode(SpatialElement.self),let connection = element.graphic?.connection,
      let owner = element.surface.ownerID,let boardText = fragment.parent?.components(separatedBy:"@").last,
      let board = UUID(uuidString:boardText) else { return }
    let target = CollaborationTarget(kind:element.surface.kind == .cover ? .cover : .board,id:owner,
      boardID:element.surface.kind == .cover ? board : nil)
    func ancestors(_ id: String) throws -> Set<String> {
      var result = Set<String>(),next = try elementGroupingSource(target:target,id:id)?.parentID
      while let current = next,result.count < 64,result.insert(collaborationIdentity(current)).inserted {
        next = try elementGroupingSource(target:target,id:current)?.parentID
      }
      return result
    }
    let own = try ancestors(element.id)
    var affected = Set<String>()
    for binding in connection.bindings { affected.formUnion(own.symmetricDifference(try ancestors(binding.elementID))) }
    try database.run("DELETE FROM graphic_bindings WHERE address=? AND terminal LIKE 'basis:%'",[.text(fragment.address)])
    let key = element.surface.kind.rawValue+":"+owner.uuidString.lowercased()
    for id in affected {
      try database.run("INSERT INTO graphic_bindings(address,owner,target_id,terminal) VALUES(?,?,?,?)",
        [.text(fragment.address),.text(key),.text(id),.text("basis:"+id)])
    }
  }

  func refreshElementGroupIndex(database: NotebookSQLConnection) throws {
    while let address = try database.takeOwner(.elementGroup) {
      guard let fragment = try storedFragments(address:address,descendants:false).first,
        let element = try? fragment.value.decode(SpatialElement.self),element.kind == .group,
        let basis = element.basis,let boardText = fragment.parent?.components(separatedBy:"@").last,
        let boardID = UUID(uuidString:boardText) else { continue }
      let board = boardID.uuidString.lowercased(),key = collaborationIdentity(element.id)
      // A concurrently delivered parent cycle has no rooted geometry. Keep its
      // derived membership row, with no paint, so breaking the cycle recovers it.
      var seen: Set<String> = [key],parent = element.parentID,cyclic = false
      while let id = parent {
        let next = collaborationIdentity(id)
        if !seen.insert(next).inserted { cyclic = next == key; break }
        guard seen.count <= 64 else { cyclic=true;break }
        parent = try storedSpatialElement(boardID:boardID,elementID:id)?.parentID
      }
      let predicate = " FROM spatial_entries WHERE board_id=? AND parent_id=? AND parent_id IS NOT NULL AND has_paint=1"
      let arguments: [NotebookSQLValue] = [.text(board),.text(key)]
      func extreme(_ columns: String,_ order: String) throws -> [NotebookSQLValue]? {
        try database.rows("SELECT "+columns+predicate+" ORDER BY "+order+" LIMIT 1",arguments).first
      }
      let first = cyclic ? nil : try extreme("z_index,lower_key","layer,z_index,lower_key")
      let nonGraphic = try first != nil && extreme("non_graphic","non_graphic DESC")?[0].integer == 1
      var origin = (element.worldOrigin ?? .zero).offsetBy(x:element.frame.x,y:element.frame.y)
      var width=0.0,height=0.0,z=Double(fragment.position),last=z,lower=element.id
      if let first {
        let transform = try basis.placement(in:.init(x:element.frame.x,y:element.frame.y,width:element.frame.width,height:element.frame.height))
        let bounds = try storedGroupLocalBounds(boardID:boardID,id:key)!.applying(transform)
        guard [bounds.minX,bounds.minY,bounds.width,bounds.height].allSatisfy(\.isFinite) else { throw NotebookStorageError.limitExceeded("element_group_bounds") }
        let projected=try NotebookElementBasis.spatialBounds(bounds,origin:element.worldOrigin ?? .zero)
        origin=projected.origin;width=bounds.width;height=bounds.height
        z=first[0].spatialNumber;lower=first[1].text!;last=try extreme("max_z","max_z DESC")![0].spatialNumber
      }
      guard let maximum=origin.projectionOffset(x:width,y:height) else { throw NotebookStorageError.limitExceeded("element_group_bounds") }
      let old = try database.rows("SELECT parent_id,has_paint,z_index,max_z,lower_key,min_tx,min_ty,min_x,min_y,max_tx,max_ty,max_x,max_y,non_graphic FROM spatial_entries WHERE address=?",[.text(address)]).first
      let parentKey = element.parentID.map(collaborationIdentity)
      if let old,old[0].text == parentKey,old[1].integer == (first == nil ? 0 : 1),old[2].spatialNumber == z,
        old[3].spatialNumber == last,old[4].text == lower,old[5].integer == origin.tileX,old[6].integer == origin.tileY,
        old[7].spatialNumber == origin.localX,old[8].spatialNumber == origin.localY,old[9].integer == maximum.tileX,
        old[10].integer == maximum.tileY,old[11].spatialNumber == maximum.localX,old[12].spatialNumber == maximum.localY,old[13].integer == (nonGraphic ? 1 : 0) { continue }
      try database.run("DELETE FROM spatial_entries WHERE address=?",[.text(address)])
      try insertSpatialEntry(address:address,boardID:boardID,id:element.surface.kind == .cover ? element.surface.ownerID!.uuidString.lowercased() : element.id,
        kind:element.surface.kind == .cover ? "coverElement" : "element",key:element.id,origin:origin,width:width,height:height,z:z,
        parentID:element.parentID,isGroup:true,hasPaint:first != nil,nonGraphic:nonGraphic,maxZ:last,lowerKey:lower,database:database)
      if let parent = element.parentID,let owner = fragment.parent {
        try database.noteOwner(.elementGroup,owner+"/board/elements/@"+fieldKey([collaborationIdentity(parent)]))
      }
      if element.surface.kind == .cover { try database.noteOwner(.cover,address) }
    }
  }

  /// Four indexed extrema describe the whole in its own frame. Neither source
  /// bodies nor the descendant list are needed for publication or pose damage.
  func storedGroupLocalBounds(boardID:UUID,id:String) throws -> CGRect? {
    let predicate=" FROM spatial_entries WHERE board_id=? AND parent_id=? AND parent_id IS NOT NULL AND has_paint=1"
    let arguments:[NotebookSQLValue]=[.text(boardID.uuidString.lowercased()),.text(collaborationIdentity(id))]
    func extreme(_ columns:String,_ order:String) throws -> [NotebookSQLValue]? {
      try currentSQL!.rows("SELECT "+columns+predicate+" ORDER BY "+order+" LIMIT 1",arguments).first
    }
    guard let x=try extreme("min_tx,min_x","min_tx,min_x"),let y=try extreme("min_ty,min_y","min_ty,min_y"),
      let right=try extreme("max_tx,max_x","max_tx DESC,max_x DESC"),let bottom=try extreme("max_ty,max_y","max_ty DESC,max_y DESC") else { return nil }
    let minimum=WorldPoint(tileX:x[0].integer!,tileY:y[0].integer!,localX:x[1].spatialNumber,localY:y[1].spatialNumber)
    let maximum=WorldPoint(tileX:right[0].integer!,tileY:bottom[0].integer!,localX:right[1].spatialNumber,localY:bottom[1].spatialNumber)
    let start=WorldPoint.zero.delta(to:minimum),extent=minimum.delta(to:maximum)
    return .init(x:start.x,y:start.y,width:extent.x,height:extent.y)
  }
}

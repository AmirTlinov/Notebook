import CoreGraphics
import Foundation

/// A complete whole's indexed extent accompanies the bounded scene window.
/// It describes no child bodies and is never saved as authored geometry.
public struct NotebookElementGroupRead: Equatable, Sendable {
  public let source: NotebookElementPlacement.Source
  public let placement: NotebookElementPlacement
  public let localBounds: CGRect
  public let isSelfContained: Bool
}

/// One iterator per visited local frame. It keeps a bounded page of index rows,
/// never member bodies, and merges those pages in the original flat paint order.
private final class NotebookSpatialLevel {
  let parentID: String?
  let bounds: WorkspaceSpatialBounds
  let origin: WorldPoint
  let transform: CGAffineTransform?
  let depth: Int
  var rows: [[NotebookSQLValue]] = []
  var offset = 0
  var cursor: [NotebookSQLValue]?
  var ended = false
  var forced:[[NotebookSQLValue]] = []
  var forcedOffset=0
  init(parentID: String?,bounds: WorkspaceSpatialBounds,origin: WorldPoint = .zero,
    transform: CGAffineTransform? = nil,depth: Int = 0) {
    self.parentID=parentID;self.bounds=bounds;self.origin=origin;self.transform=transform;self.depth=depth
  }
}

extension NotebookStore {
  public func readElementGroup(target:CollaborationTarget,elementID:String) throws -> NotebookElementGroupRead? {
    try readTransaction { _ in
      guard target.kind == .board || target.kind == .cover else { throw NotebookStorageError.invalidTransaction("spatial group owner") }
      let boardID=target.boardID ?? target.id
      guard let source=try elementGroupingSource(target:target,id:elementID),source.isGroup,
        let placement=try readElementPlacement(target:target,elementID:elementID) else { return nil }
      let row=try currentSQL!.rows("SELECT 1 FROM spatial_entries WHERE address=? AND is_group=1",
        [.text("board.json#/boards/@"+boardID.uuidString.lowercased()+"/board/elements/@"+fieldKey([collaborationIdentity(elementID)]))]).first
      guard row != nil else { return nil }
      let owner=target.kind.rawValue+":"+target.id.uuidString.lowercased()
      return try .init(source:source,placement:placement,localBounds:storedGroupLocalBounds(boardID:boardID,id:elementID) ?? .null,
        isSelfContained:try dependentGraphicAddresses(owner:owner,id:elementID).isEmpty)
    }
  }

  func spatialRows(boardID: UUID,coverID: UUID? = nil,bounds: WorkspaceSpatialBounds,limit: Int,
    after: NotebookScenePaintCursor? = nil,elementsOnly: Bool = false,
    groupPoses:[String:NotebookElementPlacement.Source] = [:]) throws -> [[NotebookSQLValue]] {
    guard (1...257).contains(limit) else { throw NotebookStorageError.limitExceeded("scene_window") }
    let database = currentSQL!,pageSize = min(limit,32)
    let forced=try projectedGroupRows(boardID:boardID,coverID:coverID,poses:groupPoses)
    let forcedIDs=Set(forced.values.flatMap { $0.map { $0[16].text! } })
    func rowBefore(_ a:[NotebookSQLValue],_ b:[NotebookSQLValue]) -> Bool {
      if a[4].integer != b[4].integer { return a[4].integer!<b[4].integer! }
      if a[5].spatialNumber != b[5].spatialNumber { return a[5].spatialNumber<b[5].spatialNumber }
      if a[15].text != b[15].text { return a[15].text!<b[15].text! }
      return a[16].text!<b[16].text!
    }
    func prepare(_ level:NotebookSpatialLevel) -> NotebookSpatialLevel {
      level.forced=(forced[level.parentID] ?? []).filter { row in
        guard row[14].integer != 1,let after else { return true }
        let layer=Int(row[4].integer!),z=row[5].spatialNumber,key=row[0].text!
        return layer>after.layer || (layer == after.layer && (z>after.zIndex || (z == after.zIndex && key>after.address)))
      }.sorted(by:rowBefore)
      return level
    }
    func next(_ level: NotebookSpatialLevel) throws -> [NotebookSQLValue]? {
      while level.offset == level.rows.count && !level.ended {
        let start=level.bounds.origin,end=level.bounds.maximum,cover=coverID.map { NotebookSQLValue.text($0.uuidString.lowercased()) } ?? .null
        let seek = level.cursor == nil ? "" : " AND (layer,z_index,lower_key,entry_id)>(?,?,?,?)"
        let query = """
          SELECT paint_key,address,owner_id,kind,layer,z_index,s.min_tx,s.min_ty,s.min_x,s.min_y,s.max_tx,s.max_ty,s.max_x,s.max_y,is_group,lower_key,entry_id
          FROM spatial_ranges r JOIN spatial_entries s ON s.rowid=r.entry
          WHERE r.min_space<=? AND r.max_space>=? AND r.min_tx<=? AND r.max_tx>=? AND r.min_ty<=? AND r.max_ty>=?
          AND r.min_x<=? AND r.max_x>=? AND r.min_y<=? AND r.max_y>=?
          AND board_id=? AND parent_id IS ? AND has_paint=1
          AND (?=0 OR kind<>'item') AND ((? IS NULL AND kind<>'coverElement') OR (? IS NOT NULL AND kind='coverElement' AND owner_id=?))
          AND (s.min_tx<? OR (s.min_tx=? AND s.min_x<=?)) AND (s.max_tx>? OR (s.max_tx=? AND s.max_x>=?))
          AND (s.min_ty<? OR (s.min_ty=? AND s.min_y<=?)) AND (s.max_ty>? OR (s.max_ty=? AND s.max_y>=?))
          AND ((is_group=1 AND (layer>? OR (layer=? AND max_z>=?)))
            OR (is_group=0 AND (layer>? OR (layer=? AND (z_index>? OR (z_index=? AND paint_key>?))))))
          """ + seek + " ORDER BY layer,z_index,lower_key,entry_id LIMIT ?"
        let layer=NotebookSQLValue.integer(Int64(after?.layer ?? -1)),z=NotebookSQLValue.real(after?.zIndex ?? 0)
        let space = NotebookSQLValue.integer(Self.spatialSpaceKey(board:boardID.uuidString.lowercased(),parent:level.parentID))
        var args: [NotebookSQLValue] = [space,space,.integer(end.tileX),.integer(start.tileX),.integer(end.tileY),.integer(start.tileY),
          .real(start.tileX == end.tileX ? end.localX : WorldPoint.tileSize),.real(start.tileX == end.tileX ? start.localX : 0),
          .real(start.tileY == end.tileY ? end.localY : WorldPoint.tileSize),.real(start.tileY == end.tileY ? start.localY : 0),
          .text(boardID.uuidString.lowercased()),level.parentID.map { .text($0) } ?? .null,
          .integer(elementsOnly ? 1 : 0),cover,cover,cover,
          .integer(end.tileX),.integer(end.tileX),.real(end.localX),.integer(start.tileX),.integer(start.tileX),.real(start.localX),
          .integer(end.tileY),.integer(end.tileY),.real(end.localY),.integer(start.tileY),.integer(start.tileY),.real(start.localY),
          layer,layer,z,layer,layer,z,z,.text(after?.address ?? "")]
        if let cursor=level.cursor { args += [cursor[4],cursor[5],cursor[15],cursor[16]] }
        args.append(.integer(Int64(pageSize)))
        let rows=try database.rows(query,args)
        level.rows=rows.filter { !forcedIDs.contains($0[16].text!) };level.offset=0;level.ended=rows.count<pageSize
        level.cursor=rows.last
      }
      let indexed=level.offset<level.rows.count ? level.rows[level.offset] : nil
      if level.forcedOffset<level.forced.count,
        indexed.map({ rowBefore(level.forced[level.forcedOffset],$0) }) ?? true {
        let row=level.forced[level.forcedOffset];level.forcedOffset += 1;return row
      }
      guard let indexed else { return nil };level.offset += 1;return indexed
    }
    typealias Candidate = (row:[NotebookSQLValue],level:NotebookSpatialLevel)
    var heap: [Candidate] = []
    func ordered(_ a: Candidate,_ b: Candidate) -> Bool { rowBefore(a.row,b.row) }
    func push(_ value: Candidate) {
      heap.append(value);var index=heap.count-1
      while index>0 {
        let parent=(index-1)/2
        guard ordered(heap[index],heap[parent]) else { break }
        heap.swapAt(index,parent);index=parent
      }
    }
    func pop() -> Candidate {
      let result=heap[0],last=heap.removeLast()
      guard !heap.isEmpty else { return result }
      heap[0]=last;var index=0
      while index*2+1<heap.count {
        var child=index*2+1
        if child+1<heap.count,ordered(heap[child+1],heap[child]) { child += 1 }
        guard ordered(heap[child],heap[index]) else { break }
        heap.swapAt(child,index);index=child
      }
      return result
    }
    let root=prepare(NotebookSpatialLevel(parentID:nil,bounds:bounds))
    if let first=try next(root) { push((first,root)) }
    var result: [[NotebookSQLValue]] = []
    while !heap.isEmpty,result.count<limit {
      let candidate=pop(),level=candidate.level
      var row=candidate.row
      if let following=try next(level) { push((following,level)) }
      if row[14].integer == 1 {
        guard level.depth<64 else { throw NotebookStorageError.limitExceeded("element_group_depth") }
        guard let element=try storedSpatialElement(boardID:boardID,elementID:row[0].text!),element.kind == .group,
          let basis=element.basis else { throw NotebookStorageError.corruptRecord(row[1].text!) }
        let pose=groupPoses[collaborationIdentity(element.id)]
        let local=try (pose?.basis ?? basis).placement(in:pose?.frame ?? .init(x:element.frame.x,y:element.frame.y,width:element.frame.width,height:element.frame.height))
        let origin=pose?.origin ?? element.worldOrigin ?? .zero
        let determinant=local.a*local.d-local.b*local.c
        guard determinant.isFinite,determinant != 0 else { throw NotebookStorageError.limitExceeded("element_group_projection") }
        let delta=origin.delta(to:level.bounds.origin)
        let query=CGRect(x:delta.x,y:delta.y,width:level.bounds.width,height:level.bounds.height).applying(local.inverted())
        guard [query.minX,query.minY,query.width,query.height].allSatisfy(\.isFinite) else { throw NotebookStorageError.limitExceeded("element_group_projection") }
        let child=prepare(NotebookSpatialLevel(parentID:collaborationIdentity(element.id),
          bounds:try NotebookElementBasis.spatialBounds(query),
          origin:level.transform == nil ? origin : level.origin,
          transform:local.concatenating(level.transform ?? .identity),depth:level.depth+1))
        if let first=try next(child) { push((first,child)) }
        continue
      }
      if forcedIDs.contains(row[16].text!) {
        // An external bound connector can enter the window although its old
        // derived index row did not. Resolve only this dependency, not siblings.
        let target=coverID.map { CollaborationTarget(kind:.cover,id:$0,boardID:boardID) } ?? .init(kind:.board,id:boardID)
        guard let layout=try storedGraphicResolution(target:target,elementID:row[0].text!,groupPoses:groupPoses).layout else { continue }
        let projected=try NotebookElementBasis.spatialBounds(.init(x:layout.frame.x,y:layout.frame.y,width:layout.frame.width,height:layout.frame.height),origin:layout.origin)
        guard projected.intersects(bounds) else { continue }
        let a=projected.origin,b=projected.maximum
        row.replaceSubrange(6...13,with:[.integer(a.tileX),.integer(a.tileY),.real(a.localX),.real(a.localY),
          .integer(b.tileX),.integer(b.tileY),.real(b.localX),.real(b.localY)])
      } else if let transform=level.transform {
        let minimum=WorldPoint(tileX:row[6].integer!,tileY:row[7].integer!,localX:row[8].spatialNumber,localY:row[9].spatialNumber)
        let maximum=WorldPoint(tileX:row[10].integer!,tileY:row[11].integer!,localX:row[12].spatialNumber,localY:row[13].spatialNumber)
        let start=WorldPoint.zero.delta(to:minimum),extent=minimum.delta(to:maximum)
        let rect=CGRect(x:start.x,y:start.y,width:extent.x,height:extent.y).applying(transform)
        guard [rect.minX,rect.minY,rect.width,rect.height].allSatisfy(\.isFinite) else { throw NotebookStorageError.limitExceeded("element_group_projection") }
        let projected=try NotebookElementBasis.spatialBounds(rect,origin:level.origin)
        guard projected.intersects(bounds) else { continue }
        let a=projected.origin,b=projected.maximum
        row.replaceSubrange(6...13,with:[.integer(a.tileX),.integer(a.tileY),.real(a.localX),.real(a.localY),
          .integer(b.tileX),.integer(b.tileY),.real(b.localX),.real(b.localY)])
      }
      result.append(Array(row.prefix(14)))
    }
    return result
  }
}


extension NotebookStore {
  /// Conservative old AND new painted areas, not the group's nominal frame.
  /// Independently posed descendants contribute their own area; external bound
  /// connectors contribute their old/new resolved body. Unchanged siblings are
  /// represented by four existing index extrema, never enumerated.
  public func readGroupPoseDamage(boardID:UUID,coverID:UUID? = nil,
    groupPoses:[String:NotebookElementPlacement.Source]) throws -> [WorkspaceSpatialBounds] {
    try readTransaction { _ in
      try requireLiveBoard(boardID)
      if let coverID,try ownerBoardID(of:coverID) != boardID { throw CocoaError(.fileNoSuchFile) }
      let target=coverID.map { CollaborationTarget(kind:.cover,id:$0,boardID:boardID) } ?? .init(kind:.board,id:boardID)
      let poses=try checkedGroupPoses(groupPoses,target:target)
      let original=NotebookElementPlacement.Resolver { try self.elementGroupingSource(target:target,id:$0) }
      let projected=NotebookElementPlacement.Resolver { try poses[collaborationIdentity($0)] ?? self.elementGroupingSource(target:target,id:$0) }
      var result:[WorkspaceSpatialBounds]=[],dependencies=Set<String>()
      let owner=coverID.map { "cover:"+$0.uuidString.lowercased() } ?? "board:"+boardID.uuidString.lowercased()
      for id in poses.keys.sorted() {
        if let bounds=try storedGroupLocalBounds(boardID:boardID,id:id) {
          for resolver in [original,projected] {
            guard let placement=try resolver.resolve(id) else { throw NotebookStorageError.invalidTransaction("group pose ancestry") }
            result.append(try NotebookElementBasis.spatialBounds(bounds.applying(placement.transform),origin:placement.origin))
          }
        }
        dependencies.formUnion(try dependentGraphicAddresses(owner:owner,id:id))
        guard dependencies.count<=4096 else { throw NotebookStorageError.limitExceeded("group_pose_dependencies") }
      }
      for address in dependencies.sorted() {
        guard let row=try currentSQL!.rows("SELECT paint_key FROM spatial_entries WHERE address=?",[.text(address)]).first else { continue }
        for changes in [[String:NotebookElementPlacement.Source](),poses] {
          if let layout=try storedGraphicResolution(target:target,elementID:row[0].text!,groupPoses:changes).layout {
            result.append(try NotebookElementBasis.spatialBounds(.init(x:layout.frame.x,y:layout.frame.y,width:layout.frame.width,height:layout.frame.height),origin:layout.origin))
          }
        }
      }
      return result
    }
  }

  /// Read-only poses may change a whole's placement, never membership or bodies.
  /// They are a projection of this exact source cut, not a second transaction.
  func checkedGroupPoses(_ values:[String:NotebookElementPlacement.Source],target:CollaborationTarget) throws -> [String:NotebookElementPlacement.Source] {
    guard values.count<=32 else { throw NotebookStorageError.limitExceeded("group_pose_projection") }
    var result:[String:NotebookElementPlacement.Source]=[:]
    for (id,pose) in values {
      let key=collaborationIdentity(id)
      guard result[key] == nil,pose.isGroup,NotebookElementBasis.validLocalFrame(pose.frame),pose.basis?.isValid == true,
        let original=try elementGroupingSource(target:target,id:id),original.isGroup,
        original.parentID.map(collaborationIdentity) == pose.parentID.map(collaborationIdentity),
        pose.parentID == nil || pose.origin == .zero else { throw NotebookStorageError.invalidTransaction("group pose projection") }
      result[key]=pose
    }
    let resolver=NotebookElementPlacement.Resolver { try result[collaborationIdentity($0)] ?? self.elementGroupingSource(target:target,id:$0) }
    for id in result.keys {
      guard let placement=try resolver.resolve(id) else { throw NotebookStorageError.invalidTransaction("group pose ancestry") }
      let t=placement.transform,det=t.a*t.d-t.b*t.c
      guard det.isFinite,det != 0 else { throw NotebookStorageError.limitExceeded("element_group_projection") }
    }
    return result
  }

  private func projectedGroupRows(boardID:UUID,coverID:UUID?,poses:[String:NotebookElementPlacement.Source]) throws -> [String?:[[NotebookSQLValue]]] {
    guard !poses.isEmpty else { return [:] }
    let prefix="board.json#/boards/@"+boardID.uuidString.lowercased()+"/board/elements/@"
    let owner=coverID.map { "cover:"+$0.uuidString.lowercased() } ?? "board:"+boardID.uuidString.lowercased()
    var pending=Set(poses.keys.map { prefix+fieldKey([$0]) }),seen=Set<String>()
    for id in poses.keys { pending.formUnion(try dependentGraphicAddresses(owner:owner,id:id)) }
    var result:[String?:[[NotebookSQLValue]]]=[:]
    while let address=pending.popFirst() {
      guard seen.insert(address).inserted else { continue }
      guard seen.count<=4096 else { throw NotebookStorageError.limitExceeded("group_pose_dependencies") }
      guard let row=try currentSQL!.rows("""
        SELECT paint_key,address,owner_id,kind,layer,z_index,min_tx,min_ty,min_x,min_y,max_tx,max_ty,max_x,max_y,is_group,lower_key,entry_id,parent_id
        FROM spatial_entries WHERE address=? AND board_id=?
        """,[.text(address),.text(boardID.uuidString.lowercased())]).first else { continue }
      let parent=row[17].text
      result[parent,default:[]].append(Array(row.prefix(17)))
      if let parent { pending.insert(prefix+fieldKey([parent])) }
    }
    return result
  }
}

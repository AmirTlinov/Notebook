import CoreGraphics
import Foundation

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
  init(parentID: String?,bounds: WorkspaceSpatialBounds,origin: WorldPoint = .zero,
    transform: CGAffineTransform? = nil,depth: Int = 0) {
    self.parentID=parentID;self.bounds=bounds;self.origin=origin;self.transform=transform;self.depth=depth
  }
}

extension NotebookStore {
  func spatialRows(boardID: UUID,coverID: UUID? = nil,bounds: WorkspaceSpatialBounds,limit: Int,
    after: NotebookScenePaintCursor? = nil,elementsOnly: Bool = false) throws -> [[NotebookSQLValue]] {
    guard (1...257).contains(limit) else { throw NotebookStorageError.limitExceeded("scene_window") }
    let database = currentSQL!,pageSize = min(limit,32)
    func next(_ level: NotebookSpatialLevel) throws -> [NotebookSQLValue]? {
      if level.offset == level.rows.count {
        guard !level.ended else { return nil }
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
        level.rows=try database.rows(query,args);level.offset=0;level.ended=level.rows.count<pageSize
        level.cursor=level.rows.last
      }
      guard level.offset<level.rows.count else { return nil }
      let row=level.rows[level.offset];level.offset += 1;return row
    }
    typealias Candidate = (row:[NotebookSQLValue],level:NotebookSpatialLevel)
    var heap: [Candidate] = []
    func ordered(_ a: Candidate,_ b: Candidate) -> Bool {
      if a.row[4].integer != b.row[4].integer { return a.row[4].integer!<b.row[4].integer! }
      if a.row[5].spatialNumber != b.row[5].spatialNumber { return a.row[5].spatialNumber<b.row[5].spatialNumber }
      if a.row[15].text != b.row[15].text { return a.row[15].text!<b.row[15].text! }
      return a.row[16].text!<b.row[16].text!
    }
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
    let root=NotebookSpatialLevel(parentID:nil,bounds:bounds)
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
        let local=try basis.placement(in:.init(x:element.frame.x,y:element.frame.y,width:element.frame.width,height:element.frame.height))
        let determinant=local.a*local.d-local.b*local.c
        guard determinant.isFinite,determinant != 0 else { throw NotebookStorageError.limitExceeded("element_group_projection") }
        let delta=(element.worldOrigin ?? .zero).delta(to:level.bounds.origin)
        let query=CGRect(x:delta.x,y:delta.y,width:level.bounds.width,height:level.bounds.height).applying(local.inverted())
        guard [query.minX,query.minY,query.width,query.height].allSatisfy(\.isFinite) else { throw NotebookStorageError.limitExceeded("element_group_projection") }
        let child=NotebookSpatialLevel(parentID:collaborationIdentity(element.id),
          bounds:try NotebookElementBasis.spatialBounds(query),
          origin:level.transform == nil ? element.worldOrigin ?? .zero : level.origin,
          transform:local.concatenating(level.transform ?? .identity),depth:level.depth+1)
        if let first=try next(child) { push((first,child)) }
        continue
      }
      if let transform=level.transform {
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

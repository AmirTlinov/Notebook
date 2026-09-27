import Foundation

/// A raw selection depends on its contact and later intersecting cuts. A new
/// pen elsewhere, or another surface's journal clock, is not that dependency.
public struct NotebookInkContactWitness:Equatable,Sendable {
  public let id:UUID
  public let tool:SpatialInkTool
  public let color:SpatialInkColor
  public let sequence:UInt64
  public let actor:String
  public let stateStamp:VersionStamp?
  public let isActive:Bool
  public let measurements:[UUID]
  public init(_ action:PageInkAction) {
    id=action.id;tool=action.tool;color=action.color;sequence=action.sequence;actor=""
    stateStamp=action.stateStamp;isActive=action.isActive;measurements=[action.samples.revision]
  }
  public init(_ action:SpatialInkAction) {
    id=action.id;tool=action.tool;color=action.color;sequence=action.stamp.counter;actor=action.stamp.actor.uuidString
    stateStamp=action.stateStamp;isActive=action.isActive;measurements=action.spans.map{ $0.samples.revision }
  }
  init(id:UUID,tool:SpatialInkTool,color:SpatialInkColor,sequence:UInt64,actor:String,stateStamp:VersionStamp?,isActive:Bool,measurements:[UUID]) {
    self.id=id;self.tool=tool;self.color=color;self.sequence=sequence;self.actor=actor
    self.stateStamp=stateStamp;self.isActive=isActive;self.measurements=measurements
  }
  public func precedes(_ other:Self)->Bool {
    if sequence != other.sequence {return sequence<other.sequence}
    if actor != other.actor {return actor<other.actor}
    return id.uuidString<other.id.uuidString
  }
}

/// One immutable source proof per retained read set. Strong ownership avoids
/// ObjectIdentifier reuse; a new root replaces this slot after exact validation.
private final class NotebookInkReadValidation:@unchecked Sendable {
  private let lock=NSLock()
  private var owner:AnyObject
  private var value=true
  init(_ owner:AnyObject) {self.owner=owner}
  func cached(_ owner:AnyObject)->Bool? {lock.withLock {self.owner === owner ? value:nil}}
  func record(_ value:Bool,for owner:AnyObject)->Bool {lock.withLock {self.owner=owner;self.value=value};return value}
}

public struct NotebookInkReadSet:Equatable,Sendable {
  public let surface:SurfaceID
  public let bounds:WorkspaceSpatialBounds
  public let contact:NotebookInkContactWitness
  public let erasers:[NotebookInkContactWitness]
  private let validation:NotebookInkReadValidation
  public static func ==(lhs:Self,rhs:Self)->Bool {
    lhs.surface == rhs.surface && lhs.bounds == rhs.bounds && lhs.contact == rhs.contact && lhs.erasers == rhs.erasers
  }
  init(surface:SurfaceID,bounds:WorkspaceSpatialBounds,contact:NotebookInkContactWitness,erasers:[NotebookInkContactWitness],owner:AnyObject) {
    self.surface=surface;self.bounds=bounds;self.contact=contact;validation = .init(owner)
    self.erasers=erasers.filter{$0.isActive && $0.tool == .eraser && contact.precedes($0)}.sorted{$0.id<$1.id}
  }
  public static func bounds(of samples:InkMeasurements)->WorkspaceSpatialBounds {
    let geometry=samples.storage.root.geometry,box=geometry.bounds.insetBy(dx:-1,dy:-1),origin=geometry.origin ?? .zero
    guard !box.isNull,!box.isInfinite,[box.minX,box.minY,box.maxX,box.maxY].allSatisfy(\.isFinite),
      let minimum=origin.projectionOffset(x:box.minX,y:box.minY),let maximum=origin.projectionOffset(x:box.maxX,y:box.maxY) else {
      return .init(origin:.init(tileX:-WorldPoint.maximumTileIndex,tileY:-WorldPoint.maximumTileIndex,localX:0,localY:0),
        maximum:.init(tileX:WorldPoint.maximumTileIndex,tileY:WorldPoint.maximumTileIndex,localX:WorldPoint.tileSize.nextDown,localY:WorldPoint.tileSize.nextDown))
    }
    return .init(origin:minimum,maximum:maximum)
  }
  public func matches(_ source:PageInkSource,suppressed:Set<UUID> = [])->Bool {
    guard !suppressed.contains(contact.id) else {return false}
    if let cached=validation.cached(source.source) {return cached}
    guard let prepared=source.preparedProjection else {return false}
    guard prepared.drawing.action(id:contact.id).map(NotebookInkContactWitness.init) == contact else {return validation.record(false,for:source.source)}
    let cuts=prepared.eraserIndex.candidates(on:nil,in:bounds).compactMap {prepared.drawing.action(id:$0)}
      .map(NotebookInkContactWitness.init).filter{$0.isActive && contact.precedes($0)}.sorted{$0.id<$1.id}
    return validation.record(cuts == erasers,for:source.source)
  }
  public func matches(_ journal:SpatialInkJournal,suppressed:Set<UUID> = [])->Bool {
    guard !suppressed.contains(contact.id) else {return false}
    if let cached=validation.cached(journal.storage) {return cached}
    guard journal.action(id:contact.id).map(NotebookInkContactWitness.init) == contact else {return validation.record(false,for:journal.storage)}
    let cuts=journal.storage.eraserIndex.candidates(on:surface,in:bounds).compactMap{journal.action(id:$0)}
      .map(NotebookInkContactWitness.init).filter{$0.isActive && contact.precedes($0)}.sorted{$0.id<$1.id}
    return validation.record(cuts == erasers,for:journal.storage)
  }
}

/// Immutable blocks share the canonical measurement bounds. Appending an
/// eraser rebuilds at most 256 bounds; pen and visibility changes reuse them.
struct InkReadSetBoundsIndex:Sendable {
  private struct Block:Sendable {
    let entries:[WorkspaceSpatialEntry]
    let index:WorkspaceSpatialIndex
    init(_ entries:[WorkspaceSpatialEntry]) {self.entries=entries;index = .init(entries:entries)}
  }
  private var blocks:[SurfaceID?:[Block]] = [:]
  init() {}
  init(page actions:[PageInkAction]) {
    self.init(entries:[nil:actions.filter{$0.tool == .eraser}.map {
      .init(id:.element($0.id.uuidString),bounds:NotebookInkReadSet.bounds(of:$0.samples),zIndex:0)
    }])
  }
  init(spatial actions:[SpatialInkAction]) {
    var entries:[SurfaceID?:[WorkspaceSpatialEntry]]=[:]
    for action in actions where action.tool == .eraser {
      for (surface,bounds) in Self.regions(action) {
        entries[surface,default:[]].append(.init(id:.element(action.id.uuidString),bounds:bounds,zIndex:0))
      }
    }
    self.init(entries:entries)
  }
  private init(entries:[SurfaceID?:[WorkspaceSpatialEntry]]) {
    blocks=entries.mapValues { values in
      stride(from:0,to:values.count,by:256).map {.init(Array(values[$0..<min($0+256,values.count)]))}
    }
  }
  private static func regions(_ action:SpatialInkAction)->[SurfaceID:WorkspaceSpatialBounds] {
    var regions:[SurfaceID:WorkspaceSpatialBounds]=[:]
    for span in action.spans {
      let bounds=NotebookInkReadSet.bounds(of:span.samples)
      regions[span.surface]=regions[span.surface].map{$0.union(bounds)} ?? bounds
    }
    return regions
  }
  mutating func append(id:UUID,surface:SurfaceID?,bounds:WorkspaceSpatialBounds) {
    var group=blocks[surface] ?? [],tail:[WorkspaceSpatialEntry]=[]
    if let last=group.last,last.entries.count<256 {tail=group.removeLast().entries}
    tail.append(.init(id:.element(id.uuidString),bounds:bounds,zIndex:0));group.append(.init(tail));blocks[surface]=group
  }
  mutating func append(_ action:PageInkAction) {
    if action.tool == .eraser {append(id:action.id,surface:nil,bounds:NotebookInkReadSet.bounds(of:action.samples))}
  }
  mutating func append(_ action:SpatialInkAction) {
    guard action.tool == .eraser else {return}
    for (surface,bounds) in Self.regions(action) {append(id:action.id,surface:surface,bounds:bounds)}
  }
  func candidates(on surface:SurfaceID?,in bounds:WorkspaceSpatialBounds)->Set<UUID> {
    var ids=Set<UUID>()
    for block in blocks[surface] ?? [] {
      for entry in block.index.intersections(in:bounds,limit:256).entries {
        if case .element(let id)=entry.id,let uuid=UUID(uuidString:id) {ids.insert(uuid)}
      }
    }
    return ids
  }
}

extension NotebookStore {
  /// Read authenticated addressed envelopes, not the referenced measurement
  /// bodies. Their immutable UUIDs and causal header are the selected read set.
  func inkContactWitness(at address:String,page:Bool) throws -> NotebookInkContactWitness? {
    let database=currentSQL!
    guard let header=try database.rows("SELECT b.data FROM records r JOIN blobs b ON b.hash=r.hash WHERE r.address=?",[.text(address)]).first?[0].blob else {return nil}
    let child=address+(page ? "/samples":"/spans")
    guard let body=try database.rows("SELECT b.data FROM records r JOIN blobs b ON b.hash=r.hash WHERE r.address=?",[.text(child)]).first?[0].blob else {return nil}
    return try inkContactWitness(header:header,body:body,address:address,page:page)
  }
  private func inkContactWitness(header:Data,body:Data,address:String,page:Bool) throws -> NotebookInkContactWitness {
    let database=currentSQL!,value=try database.decodeFragmentEnvelope(header).value
    let material=try database.decodeFragmentEnvelope(body)
    let revisions:[UUID]
    if page {revisions=try material.inkMeasurementRevisions(at:[[]])}
    else {
      guard case .array(let spans)=material.value else {throw NotebookStorageError.corruptRecord(material.address)}
      revisions=try material.inkMeasurementRevisions(at:spans.indices.map {[String($0),"samples"]})
    }
    if page {
      let metadata=try value.decode(NotebookPageInkActionMetadata.self)
      return .init(id:metadata.id,tool:metadata.tool,color:metadata.color,sequence:metadata.sequence,actor:"",
        stateStamp:metadata.stateStamp,isActive:metadata.isActive,measurements:revisions)
    }
    let metadata=try value.decode(SpatialInkActionHeader.self)
    return .init(id:metadata.id,tool:metadata.tool,color:metadata.color,sequence:metadata.stamp.counter,actor:metadata.stamp.actor.uuidString,
      stateStamp:metadata.stateStamp,isActive:metadata.isActive,measurements:revisions)
  }
  static func inkSelectionReadAllowance(_ sets:[NotebookInkReadSet])->NotebookSQLReadAllowance {
    let base=NotebookSQLReadAllowance.agentCommand
    let witnesses=sets.reduce(0){$0+$1.erasers.count}
    let references=sets.reduce(0){$0+$1.erasers.reduce(0){$0+$1.measurements.count}}
    return .init(rows:base.rows+witnesses+sets.count*4,
      bytes:base.bytes+witnesses*2048+references*2048,valueBytes:base.valueBytes,reason:"native_ink_selection_read")
  }
  func validateInkReadSets(_ sets:[NotebookInkReadSet],target:CollaborationTarget) throws {
    guard sets.count<=32 else {throw NotebookStorageError.limitExceeded("selection_sources")}
    let surface:SurfaceID=target.kind == .page ? .page(target.id):target.kind == .cover ? .cover(target.id):.board(target.id)
    for set in sets {
      let page=surface.kind == .page
      let address=(page ? pageFile(target.id)+"#/drawingData/actions/@":"spatial-ink.json#/actions/@")+set.contact.id.uuidString.lowercased()
      guard set.surface == surface,try inkContactWitness(at:address,page:page) == set.contact else {
        throw CollaborationError("revision_conflict","Выбранный штрих изменился.")
      }
      let a=set.bounds.origin,b=set.bounds.maximum,owner=target.id.uuidString.lowercased()
      let space=NotebookSQLValue.integer(Self.spatialSpaceKey(board:surface.kind.rawValue,parent:owner))
      var next=0
      try currentSQL!.forEachRow("""
        SELECT s.address,hb.data,mb.data FROM ink_surfaces s JOIN ink_ranges r ON s.rowid=r.entry
        JOIN records h ON h.address=s.address JOIN blobs hb ON hb.hash=h.hash
        JOIN records m ON m.address=s.address||? JOIN blobs mb ON mb.hash=m.hash
        WHERE s.paint_counter>=?
          AND (s.paint_counter>? OR s.paint_actor>? OR (s.paint_actor=? AND s.address>?))
          AND r.min_space<=? AND r.max_space>=? AND r.min_tx<=? AND r.max_tx>=? AND r.min_ty<=? AND r.max_ty>=?
          AND r.min_x<=? AND r.max_x>=? AND r.min_y<=? AND r.max_y>=?
          AND s.kind=? AND s.owner_id=? AND s.active=1 AND s.tool='eraser'
          AND (s.min_tx<? OR (s.min_tx=? AND s.min_x<=?)) AND (s.max_tx>? OR (s.max_tx=? AND s.max_x>=?))
          AND (s.min_ty<? OR (s.min_ty=? AND s.min_y<=?)) AND (s.max_ty>? OR (s.max_ty=? AND s.max_y>=?))
        ORDER BY s.address
        """,[.text(page ? "/samples":"/spans"),.integer(Int64(set.contact.sequence)),.integer(Int64(set.contact.sequence)),
          .text(set.contact.actor),.text(set.contact.actor),.text(address),space,space,.integer(b.tileX),.integer(a.tileX),.integer(b.tileY),.integer(a.tileY),
          .real(a.tileX == b.tileX ? b.localX:WorldPoint.tileSize),.real(a.tileX == b.tileX ? a.localX:0),
          .real(a.tileY == b.tileY ? b.localY:WorldPoint.tileSize),.real(a.tileY == b.tileY ? a.localY:0),
          .text(surface.kind.rawValue),.text(owner),.integer(b.tileX),.integer(b.tileX),.real(b.localX),.integer(a.tileX),.integer(a.tileX),.real(a.localX),
          .integer(b.tileY),.integer(b.tileY),.real(b.localY),.integer(a.tileY),.integer(a.tileY),.real(a.localY)]) {row in
        guard next<set.erasers.count,
          try inkContactWitness(header:row[1].blob!,body:row[2].blob!,address:row[0].text!,page:page) == set.erasers[next] else {
          throw CollaborationError("revision_conflict","Стирание выбранного штриха изменилось.")
        }
        next += 1
      }
      guard next == set.erasers.count else {throw CollaborationError("revision_conflict","Стирание выбранного штриха изменилось.")}
    }
  }
}

extension PageInkSource {
  public func readSet(for id:UUID,on surface:SurfaceID)->NotebookInkReadSet? {
    guard surface.kind == .page,let prepared=preparedProjection,let action=prepared.drawing.action(id:id),action.isActive else {return nil}
    let bounds=NotebookInkReadSet.bounds(of:action.samples)
    let cuts=prepared.eraserIndex.candidates(on:nil,in:bounds).compactMap{prepared.drawing.action(id:$0)}.map(NotebookInkContactWitness.init)
    return .init(surface:surface,bounds:bounds,contact:.init(action),erasers:cuts,owner:source)
  }
}
extension SpatialInkJournal {
  public func readSet(for id:UUID,on surface:SurfaceID)->NotebookInkReadSet? {
    guard let action=action(id:id),action.isActive else {return nil}
    let regions=action.spans.filter{$0.surface == surface}.map{NotebookInkReadSet.bounds(of:$0.samples)}
    guard let first=regions.first else {return nil}
    let bounds=regions.dropFirst().reduce(first){$0.union($1)}
    let cuts=storage.eraserIndex.candidates(on:surface,in:bounds).compactMap{self.action(id:$0)}.map(NotebookInkContactWitness.init)
    return .init(surface:surface,bounds:bounds,contact:.init(action),erasers:cuts,owner:storage)
  }
}

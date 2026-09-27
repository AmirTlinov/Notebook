import CoreGraphics
import Foundation
import NotebookCore

/// Pins accepted vector content, never a screenshot or a visibility mask.
enum NotebookLassoInkSource: Sendable {
  case paper(PageInkSource, Set<UUID>)
  static func page(_ page:PageDocument) -> Self {
    .paper(page.inkSource,page.graphicPresentation.suppressedInkIDs)
  }
  /// A bounded spatial read can gain members without advancing the journal's
  /// maximum stamp. The scene revision identifies that immutable membership.
  case spatial(SpatialInkJournal, Set<UUID>, membershipRevision: UInt64)
  var revision: String {
    switch self {
    case .paper(let p, _): return p.stamp.revision
    case .spatial(let j,_,_): return j.stamp.revision
    }
  }
  var suppressed: Set<UUID> {
    switch self {
    case .paper(_,let ids): ids
    case .spatial(_,let ids,_): ids
    }
  }
  func cacheKey(surface: SurfaceID) -> String {
    if case .spatial(_,_,let membershipRevision) = self {
      return "\(surface)|\(revision)|\(membershipRevision)"
    }
    return "\(surface)|\(revision)"
  }
  struct Result: Equatable, Sendable {
    let frame: PageRect
    let selectionFrame: PageRect
    let polygon: [SpatialPoint]
    let graphic: NotebookGraphic
    /// Candidate traversal only; excludes exact semantic geometry preparation.
    let candidateSampleCount: Int
    let sourceSampleCount: Int
  }
  struct PaintOrder: Equatable, Comparable, Sendable {
    let counter:UInt64
    let actor:String
    let id:UUID
    static func < (lhs:Self,rhs:Self)->Bool {
      if lhs.counter != rhs.counter { return lhs.counter<rhs.counter }
      if lhs.actor != rhs.actor { return lhs.actor<rhs.actor }
      return lhs.id.uuidString<rhs.id.uuidString
    }
  }
  struct WholeContact: Equatable, Sendable {
    let actionID: UUID
    let painterOrder: PaintOrder
    let material: Result
  }
  func selection(polygon: [SpatialPoint], surface: SurfaceID, origin: WorldPoint?, bounds: CGRect?) throws -> Result? {
    try prepare(surface:surface,origin:origin).selection(polygon:polygon,surface:surface,origin:origin,bounds:bounds)
  }
  func prepare(surface: SurfaceID, origin: WorldPoint?, reusing previous: Prepared? = nil) throws -> Prepared {
    let suppressed = suppressed
    switch self {
    case .paper(let page, _):
      let drawing = try page.drawing()
      let cursor=drawing.actionCursor
      if let previous,let previousCursor=previous.pageCursor,
        let appended=drawing.appendedActions(after:previousCursor),
        let updated=try Prepared(revision:revision,appending:Self.pageEntries(appended),pageCursor:cursor,
          surface:surface,origin:origin,excluding:suppressed,reusing:previous) { return updated }
      let actions=drawing.actions
      return try Prepared(revision:revision,entries:Self.pageEntries(actions),pageCursor:cursor,
        preparationActionCount:actions.count,surface:surface,origin:origin,excluding:suppressed)
    case .spatial(let journal,_,_):
      let entries:[Prepared.Entry] = journal.actions.filter(\.isActive).compactMap { action in
          let spans=action.spans.enumerated().filter { $0.element.surface == surface }.map { index,span in
            InkSampleRelations(sourceID:action.id,span:index,measurements:span.samples,
              header:.init(tool:action.tool,color:action.color))
          }
          return spans.isEmpty ? nil : .init(id:action.id,tool:action.tool,color:action.color,sources:spans,
            allowsWholeContact:action.spans.allSatisfy { $0.surface == surface },
            painterOrder:.init(counter:action.stamp.counter,actor:action.stamp.actor.uuidString,id:action.id))
        }
      if let previous,let updated=try Prepared(revision:revision,entries:entries,surface:surface,
        origin:origin,excluding:suppressed,reusing:previous) { return updated }
      return try Prepared(revision:revision,entries:entries,preparationActionCount:journal.actions.count,
        surface:surface,origin:origin,excluding:suppressed)
    }
  }
  private static func pageEntries(_ actions:[PageInkAction])->[Prepared.Entry] {
    actions.filter(\.isActive).map {
        .init(id:$0.id,tool:$0.tool,color:$0.color,sources:[.init($0)],
          painterOrder:.init(counter:$0.sequence,actor:"",id:$0.id))
      }
  }

  /// One bounded snapshot is retained by the tool controller. Its top-level
  /// index addresses whole spans; their canonical range tree rejects hidden
  /// measurements, including on the first gesture after reopening a repeat.
  final class Prepared: Sendable {
    struct Entry: Sendable {
      let id: UUID
      let tool: SpatialInkTool
      let color: SpatialInkColor
      let sources: [InkSampleRelations]
      var allowsWholeContact = true
      var painterOrder:PaintOrder? = nil
    }
    struct Span: Sendable {
      let entry: Int
      let span: Int
      let bounds: CGRect
    }
    private struct IndexBlock: Sendable {
      let base:Int
      let count:Int
      let index:InkBoundsIndex
    }
    let revision: String
    let sourceSampleCount: Int
    let reusedSampleCount:Int
    /// Actions visited to refresh this snapshot. A live append should be one,
    /// not the complete page history.
    let preparationActionCount:Int
    private let indexBlocks:[IndexBlock]
    private let entries: [Entry]
    private let spans: [Span]
    var indexedSpanCount: Int { spans.count }
    let preparationSampleCount: Int
    private let entryBounds: [CGRect]
    private let surface: SurfaceID
    private let origin: WorldPoint?
    private let excluded: Set<UUID>
    fileprivate let pageCursor:PageInkDrawing.ActionCursor?
    // Changing presentation claims must not rebuild unchanged measured source.
    func excluding(_ ids: Set<UUID>) -> Prepared {
      ids == excluded ? self : Prepared(reusing:self,excluding:ids)
    }
    func excludingAdditional(_ ids:Set<UUID>) -> Prepared { excluding(excluded.union(ids)) }
    private init(reusing source: Prepared, excluding ids: Set<UUID>) {
      revision = source.revision; entries = source.entries; surface = source.surface; origin = source.origin
      sourceSampleCount = source.sourceSampleCount; indexBlocks = source.indexBlocks
      reusedSampleCount=source.reusedSampleCount
      spans = source.spans; entryBounds = source.entryBounds; excluded = ids
      preparationSampleCount = source.preparationSampleCount;preparationActionCount=source.preparationActionCount
      pageCursor=source.pageCursor
    }
    init(revision: String, entries: [Entry], pageCursor:PageInkDrawing.ActionCursor?=nil,
      preparationActionCount:Int?=nil,surface: SurfaceID, origin: WorldPoint?, excluding: Set<UUID>) throws {
      self.revision = revision; self.entries = entries; self.surface = surface; self.origin = origin; excluded = excluding
      self.pageCursor=pageCursor;self.preparationActionCount=preparationActionCount ?? entries.count
      var spans: [Span] = [], boxes: [CGRect] = [], count = 0, prepared = 0
      for (e, entry) in entries.enumerated() {
        try Task.checkCancellation()
        var box = CGRect.null
        for (s,source) in entry.sources.enumerated() {
          count += source.count
          let result=try source.bounds(in:0..<source.count)
          prepared += result.cost.decodedSamples
          let bounds=Self.projected(result.bounds,source:source,origin:origin)
          box = box.union(bounds)
          spans.append(.init(entry:e,span:s,bounds:bounds))
        }
        boxes.append(box)
      }
      self.spans = spans; entryBounds = boxes; sourceSampleCount = count;preparationSampleCount = prepared
      reusedSampleCount=0
      indexBlocks = Self.blocks(spans.map(\.bounds))
    }
    private static func sameSource(_ lhs:Entry,_ rhs:Entry)->Bool {
      lhs.id == rhs.id && lhs.tool == rhs.tool && lhs.color == rhs.color && lhs.allowsWholeContact == rhs.allowsWholeContact && lhs.painterOrder == rhs.painterOrder
        && lhs.sources.count == rhs.sources.count
        && zip(lhs.sources,rhs.sources).allSatisfy {
          $0.sourceID == $1.sourceID && $0.span == $1.span && $0.revision == $1.revision && $0.count == $1.count
        }
    }
    convenience init?(revision:String,entries:[Entry],surface:SurfaceID,origin:WorldPoint?,
      excluding:Set<UUID>,reusing source:Prepared) throws {
      guard source.surface == surface,source.origin == origin,entries.count >= source.entries.count,
        zip(source.entries,entries).allSatisfy({ Self.sameSource($0.0,$0.1) }) else { return nil }
      var spans=source.spans,boxes=source.entryBounds,count=source.sourceSampleCount
      var prepared=source.preparationSampleCount,newBounds:[CGRect]=[]
      for e in source.entries.count..<entries.count {
        try Task.checkCancellation()
        var box=CGRect.null
        for (s,relation) in entries[e].sources.enumerated() {
          count += relation.count
          let result=try relation.bounds(in:0..<relation.count)
          prepared += result.cost.decodedSamples
          let bounds=Self.projected(result.bounds,source:relation,origin:origin)
          box=box.union(bounds);spans.append(.init(entry:e,span:s,bounds:bounds));newBounds.append(bounds)
        }
        boxes.append(box)
      }
      let allBounds=spans.map(\.bounds)
      let blocks=Self.appending(newBounds,to:source.indexBlocks,allBounds:allBounds)
      self.init(revision:revision,sourceSampleCount:count,indexBlocks:blocks,entries:entries,spans:spans,
        reusedSampleCount:source.sourceSampleCount,preparationSampleCount:prepared,
        preparationActionCount:entries.count-source.entries.count,pageCursor:nil,entryBounds:boxes,
        surface:surface,origin:origin,excluded:excluding)
    }
    convenience init?(revision:String,appending added:[Entry],pageCursor:PageInkDrawing.ActionCursor,
      surface:SurfaceID,origin:WorldPoint?,excluding:Set<UUID>,reusing source:Prepared) throws {
      guard source.surface == surface,source.origin == origin,source.pageCursor != nil else { return nil }
      var entries=source.entries;entries.append(contentsOf:added)
      var spans=source.spans,boxes=source.entryBounds,count=source.sourceSampleCount
      var prepared=source.preparationSampleCount,newBounds:[CGRect]=[]
      for offset in added.indices {
        try Task.checkCancellation()
        let e=source.entries.count+offset,entry=added[offset]
        var box=CGRect.null
        for (s,relation) in entry.sources.enumerated() {
          count += relation.count
          let result=try relation.bounds(in:0..<relation.count)
          prepared += result.cost.decodedSamples
          let bounds=Self.projected(result.bounds,source:relation,origin:origin)
          box=box.union(bounds);spans.append(.init(entry:e,span:s,bounds:bounds));newBounds.append(bounds)
        }
        boxes.append(box)
      }
      let allBounds=spans.map(\.bounds)
      let blocks=Self.appending(newBounds,to:source.indexBlocks,allBounds:allBounds)
      self.init(revision:revision,sourceSampleCount:count,indexBlocks:blocks,entries:entries,spans:spans,
        reusedSampleCount:source.sourceSampleCount,preparationSampleCount:prepared,
        preparationActionCount:added.count,pageCursor:pageCursor,entryBounds:boxes,
        surface:surface,origin:origin,excluded:excluding)
    }
    private init(revision:String,sourceSampleCount:Int,indexBlocks:[IndexBlock],entries:[Entry],spans:[Span],
      reusedSampleCount:Int,preparationSampleCount:Int,preparationActionCount:Int,
      pageCursor:PageInkDrawing.ActionCursor?,entryBounds:[CGRect],surface:SurfaceID,origin:WorldPoint?,excluded:Set<UUID>) {
      self.revision=revision;self.sourceSampleCount=sourceSampleCount;self.indexBlocks=indexBlocks
      self.reusedSampleCount=reusedSampleCount
      self.entries=entries;self.spans=spans;self.preparationSampleCount=preparationSampleCount
      self.preparationActionCount=preparationActionCount;self.pageCursor=pageCursor
      self.entryBounds=entryBounds;self.surface=surface;self.origin=origin;self.excluded=excluded
    }
    private static func blocks(_ bounds:[CGRect])->[IndexBlock] {
      var result:[IndexBlock]=[],base=0,remaining=bounds.count
      while remaining > 0 {
        var count=1
        while count <= remaining/2 { count *= 2 }
        result.append(.init(base:base,count:count,index:.init(Array(bounds[base..<base+count]))))
        base += count;remaining -= count
      }
      return result
    }
    private static func appending(_ added:[CGRect],to existing:[IndexBlock],allBounds:[CGRect])->[IndexBlock] {
      var result=existing,base=allBounds.count-added.count
      for _ in added {
        var block=IndexBlock(base:base,count:1,index:.init([allBounds[base]]));base += 1
        while let last=result.last,last.count == block.count {
          result.removeLast();let count=last.count+block.count
          block = .init(base:last.base,count:count,index:.init(Array(allBounds[last.base..<last.base+count])))
        }
        result.append(block)
      }
      return result
    }
    private func indexedSpans(intersecting area:CGRect)->[Int] {
      indexBlocks.flatMap { block in block.index.query(area).indices.map { block.base+$0 } }.sorted()
    }
    private static func projected(_ box: CGRect,source: InkSampleRelations,origin: WorldPoint?) -> CGRect {
      guard let origin,let sourceOrigin=source.geometry.origin else { return box }
      let delta=origin.delta(to:sourceOrigin)
      return InkSampleRelations.Geometry.offset(box,x:delta.x,y:delta.y)
    }
    private func ranges(_ span: Span, intersecting box: CGRect,examined: inout Int) throws -> [Range<Int>] {
      let source=entries[span.entry].sources[span.span]
      let query=try source.querySegments(maximumSegments:64,intersecting: {
        let b=Self.projected($0,source:source,origin:origin)
        return !b.isNull && b.maxX >= box.minX && b.minX <= box.maxX && b.maxY >= box.minY && b.minY <= box.maxY
      })
      examined += query.cost.decodedSamples
      return query.segments.map { ($0.lowerBound*64)..<min(source.count,$0.upperBound*64+1) }
    }
    private static func point(_ sample: SpatialInkSample, origin: WorldPoint?) -> SpatialPoint {
      origin.flatMap { o in sample.worldPoint.map { o.delta(to:$0) } } ?? sample.point
    }
    /// Broad-phase action identities only. Count each immutable contact once,
    /// including erasers that the retained pen extent may need outside the
    /// contour. No sample ranges or exact polygon geometry are visited here.
    func candidateActionIDs(intersecting polygon:[SpatialPoint],surface:SurfaceID,origin queryOrigin:WorldPoint?) -> Set<UUID> {
      guard surface == self.surface,polygon.count >= 3 else { return [] }
      let delta=origin.flatMap { o in queryOrigin.map { o.delta(to:$0) } } ?? .zero
      let region=polygon.reduce(CGRect.null) { $0.union(.init(x:$1.x+delta.x,y:$1.y+delta.y,width:0,height:0)) }
      var ids=Set<UUID>(),penBounds=CGRect.null
      for index in indexedSpans(intersecting:region) {
        let span=spans[index],entry=entries[span.entry]
        guard entry.tool == .pen,!excluded.contains(entry.id) else { continue }
        ids.insert(entry.id);penBounds=penBounds.union(entryBounds[span.entry])
      }
      if !penBounds.isNull {
        for index in indexedSpans(intersecting:penBounds) {
          let entry=entries[spans[index].entry]
          if entry.tool == .eraser { ids.insert(entry.id) }
        }
      }
      return ids
    }

    private struct Query {
      let polygon: [SpatialPoint]
      let region: CGRect
      let delta: SpatialPoint
      let candidates: [Int]
    }

    private func query(_ polygon:[SpatialPoint],surface:SurfaceID,origin queryOrigin:WorldPoint?) -> Query? {
      guard surface == self.surface,polygon.count >= 3 else { return nil }
      let delta=origin.flatMap { o in queryOrigin.map { o.delta(to:$0) } } ?? .zero
      let polygon=polygon.map { SpatialPoint(x:$0.x+delta.x,y:$0.y+delta.y) }
      let region=polygon.reduce(CGRect.null) { $0.union(.init(x:$1.x,y:$1.y,width:0,height:0)) }
      return .init(polygon:polygon,region:region,delta:delta,candidates:indexedSpans(intersecting:region))
    }

    /// Shared exact contact test. The range tree, not the stored measurement
    /// count, determines how much source needs decoding for this contour.
    private func intersects(_ span:Span,query:Query,examined:inout Int) throws -> Bool {
      let entry=entries[span.entry]
      for candidate in try ranges(span,intersecting:query.region,examined:&examined) {
        try Task.checkCancellation()
        let samples=entry.sources[span.span].decoded(in:candidate),range=samples.indices
        examined += range.count
        func point(_ i:Int)->SpatialPoint { Self.point(samples[i],origin:origin) }
        if range.contains(where:{ i in
          let p=point(i),r=max(0.25,samples[i].width/2)*Double(InkStrokeGeometry.maximumCrossSectionScale)
          return NotebookToolGeometry.intersects(.init(x:p.x-r,y:p.y-r,width:max(0.01,2*r),height:max(0.01,2*r)),polygon:query.polygon)
        }) || range.dropLast().contains(where:{
          NotebookToolGeometry.intersects(from:point($0),to:point($0+1),polygon:query.polygon)
        }) { return true }
      }
      return false
    }

    /// Material retains complete immutable contacts and subsequent erasers.
    /// A selected pen never inherits an eraser which preceded that pen.
    private func material(_ chosen:Set<Int>,query:Query,bounds:CGRect?,whole:Bool,
      examined:inout Int) throws -> Result? {
      guard let first=chosen.min() else { return nil }
      var box=chosen.reduce(CGRect.null) { $0.union(entryBounds[$1]) }
      if let bounds { box=box.intersection(bounds.offsetBy(dx:query.delta.x,dy:query.delta.y)) }
      guard !box.isNull,box.width>0,box.height>0 else { return nil }
      let frame=PageRect(x:box.minX,y:box.minY,width:box.width,height:box.height)
      var cuts:[Int:Set<Int>]=[:]
      for id in indexedSpans(intersecting:box) {
        let span=spans[id]
        if span.entry>first,entries[span.entry].tool == .eraser,
          try !ranges(span,intersecting:box,examined:&examined).isEmpty {
          cuts[span.entry,default:[]].insert(span.span)
        }
      }
      var layers:[NotebookFreehand.Layer]=[]
      for e in chosen.union(cuts.keys).sorted() {
        try Task.checkCancellation()
        let entry=entries[e]
        for (span,source) in entry.sources.enumerated() where chosen.contains(e) || cuts[e]?.contains(span) == true {
          layers.append(.init(tool:entry.tool,color:entry.color,
            measured:.init(sourceID:source.sourceID,span:source.span,measurements:source.measurements,frame:frame,origin:origin)))
        }
      }
      let ink=NotebookFreehand(layers:layers)
      guard ink.isValid else { throw CollaborationError("selection_limit","Выделите меньшую часть рукописи.") }
      let clip=query.polygon.map { CGPoint(x:($0.x-frame.x)/frame.width,y:($0.y-frame.y)/frame.height) }
      guard ink.geometry.intersects(clip) else { return nil }
      let selectedBox=whole ? box : query.region.intersection(box)
      guard !selectedBox.isNull,selectedBox.width>0,selectedBox.height>0 else { return nil }
      let polygon=whole ? [
        SpatialPoint(x:box.minX,y:box.minY),.init(x:box.maxX,y:box.minY),
        .init(x:box.maxX,y:box.maxY),.init(x:box.minX,y:box.maxY)] : query.polygon
      let d=query.delta
      return .init(frame:.init(x:frame.x-d.x,y:frame.y-d.y,width:frame.width,height:frame.height),
        selectionFrame:.init(x:selectedBox.minX-d.x,y:selectedBox.minY-d.y,width:selectedBox.width,height:selectedBox.height),
        polygon:polygon.map { .init(x:$0.x-d.x,y:$0.y-d.y) },
        graphic:.init(shape:.freehand,sourceInkIDs:chosen.sorted().map { entries[$0].id },freehand:ink),
        candidateSampleCount:examined,sourceSampleCount:sourceSampleCount)
    }

    func selection(polygon:[SpatialPoint],surface:SurfaceID,origin queryOrigin:WorldPoint?,bounds:CGRect?) throws -> Result? {
      guard let query=query(polygon,surface:surface,origin:queryOrigin) else { return nil }
      var chosen=Set<Int>(),examined=0
      for id in query.candidates {
        let span=spans[id],entry=entries[span.entry]
        guard entry.tool == .pen,entry.allowsWholeContact,!excluded.contains(entry.id),!chosen.contains(span.entry) else { continue }
        if try intersects(span,query:query,examined:&examined) { chosen.insert(span.entry) }
      }
      guard chosen.count<=1024 else {
        throw CollaborationError("selection_limit","Выделите меньшую часть рукописи: это выделение слишком большое.")
      }
      return try material(chosen,query:query,bounds:bounds,whole:false,examined:&examined)
    }

    /// One result per accepted contact. Point picking visits reverse painter
    /// order and stops at the first surviving contact; a lasso keeps them all.
    /// Unsupported multi-surface contacts reject the choice, never disappear.
    func wholeContacts(polygon:[SpatialPoint],surface:SurfaceID,origin queryOrigin:WorldPoint?,
      bounds:CGRect?,topmostOnly:Bool = false,maximumCount:Int = 32,alreadySelected:Set<UUID> = []) throws -> [WholeContact] {
      guard let query=query(polygon,surface:surface,origin:queryOrigin) else { return [] }
      var byEntry:[Int:[Span]]=[:],examined=0
      for id in query.candidates {
        let span=spans[id],entry=entries[span.entry]
        if entry.tool == .pen,!excluded.contains(entry.id) { byEntry[span.entry,default:[]].append(span) }
      }
      let order=topmostOnly ? byEntry.keys.sorted(by:>) : byEntry.keys.sorted()
      var result:[WholeContact]=[],newCount=0
      for index in order {
        try Task.checkCancellation()
        var hit=false
        for span in byEntry[index]! where !hit { hit=try intersects(span,query:query,examined:&examined) }
        guard hit,let value=try material([index],query:query,bounds:bounds,whole:true,examined:&examined) else { continue }
        guard entries[index].allowsWholeContact else {
          throw CollaborationError("unsupported_selection","Этот штрих проходит по нескольким поверхностям. Выделение целого такого штриха пока не поддерживается.")
        }
        if !alreadySelected.contains(entries[index].id) {
          guard newCount<maximumCount else {
            throw CollaborationError("selection_limit","Выберите не более 32 объектов за один раз.")
          }
          newCount += 1
        }
        result.append(.init(actionID:entries[index].id,painterOrder:entries[index].painterOrder ?? .init(counter:UInt64(index),actor:"",id:entries[index].id),material:value))
        if topmostOnly { break }
      }
      return result
    }
  }
}

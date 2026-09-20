import CoreGraphics
import Foundation
import NotebookCore

/// Pins accepted vector content, never a screenshot or a visibility mask.
enum NotebookLassoInkSource: Sendable {
  case page(PageDocument)
  case spatial(SpatialInkJournal, Set<UUID>)
  var revision: String {
    switch self { case .page(let p): p.drawingStamp.revision; case .spatial(let j,_): j.stamp.revision }
  }
  var suppressed: Set<UUID> {
    switch self { case .page(let p): p.graphicPresentation.suppressedInkIDs; case .spatial(_,let ids): ids }
  }
  func cacheKey(surface: SurfaceID) -> String {
    var key = "\(surface)|\(revision)"
    if case .spatial(let journal,_) = self {
      // A spatial read window can gain members without changing the owner's
      // maximum stamp. Key its actual immutable membership, not only that stamp.
      key += "|" + journal.actions.map { "\($0.id):\($0.stamp.revision):\($0.stateStamp.revision)" }.joined(separator:",")
    }
    return key
  }
  struct Result: Sendable {
    let frame: PageRect
    let graphic: NotebookGraphic
    let examinedSampleCount: Int
    let sourceSampleCount: Int
  }
  func selection(polygon: [SpatialPoint], surface: SurfaceID, origin: WorldPoint?, bounds: CGRect?) throws -> Result? {
    try prepare(surface:surface,origin:origin).selection(polygon:polygon,surface:surface,origin:origin,bounds:bounds)
  }
  func prepare(surface: SurfaceID, origin: WorldPoint?) throws -> Prepared {
    let suppressed = suppressed
    let entries: [Prepared.Entry]
    switch self {
    case .page(let page):
      entries = try PageInkDrawing.decode(page.drawingData).actions.filter { $0.isActive }.map {
        .init(id:$0.id,tool:$0.tool,color:$0.color,sources:[.init($0,revision:$0.id)])
      }
    case .spatial(let journal,_):
      entries = journal.actions.filter { $0.isActive
        && ($0.tool == .eraser || $0.spans.allSatisfy { $0.surface == surface }) }.compactMap { action in
          let spans=action.spans.enumerated().filter { $0.element.surface == surface }.map { index,span in
            InkSampleRelations(sourceID:action.id,span:index,revision:action.id,samples:span.samples,
              header:.init(tool:action.tool,color:action.color))
          }
          return spans.isEmpty ? nil : .init(id:action.id,tool:action.tool,color:action.color,sources:spans)
        }
    }
    return try Prepared(revision:revision,entries:entries,surface:surface,origin:origin,excluding:suppressed)
  }

  /// One bounded snapshot is retained by the tool controller. Cold preparation
  /// reads all measurements once; repeated gestures visit only intersecting
  /// branches, even after the viewport's world origin has moved.
  final class Prepared: Sendable {
    struct Entry: Sendable {
      let id: UUID
      let tool: SpatialInkTool
      let color: SpatialInkColor
      let sources: [InkSampleRelations]
    }
    struct Fragment: Sendable {
      let entry: Int
      let span: Int
      let range: Range<Int>
      let bounds: CGRect
    }
    let revision: String
    let sourceSampleCount: Int
    let index: InkBoundsIndex
    private let entries: [Entry]
    private let fragments: [Fragment]
    private let entryBounds: [CGRect]
    private let surface: SurfaceID
    private let origin: WorldPoint?
    private let excluded: Set<UUID>
    // Changing presentation claims must not rebuild unchanged measured source.
    func excluding(_ ids: Set<UUID>) -> Prepared {
      ids == excluded ? self : Prepared(reusing:self,excluding:ids)
    }
    private init(reusing source: Prepared, excluding ids: Set<UUID>) {
      revision = source.revision; entries = source.entries; surface = source.surface; origin = source.origin
      sourceSampleCount = source.sourceSampleCount; index = source.index
      fragments = source.fragments; entryBounds = source.entryBounds; excluded = ids
    }
    init(revision: String, entries: [Entry], surface: SurfaceID, origin: WorldPoint?, excluding: Set<UUID>) throws {
      self.revision = revision; self.entries = entries; self.surface = surface; self.origin = origin; excluded = excluding
      var fragments: [Fragment] = [], boxes: [CGRect] = [], count = 0
      for (e, entry) in entries.enumerated() {
        try Task.checkCancellation()
        var box = CGRect.null
        for (s,source) in entry.sources.enumerated() {
          count += source.count
          for start in stride(from:0,to:max(1,source.count-1),by:64) where source.count > 0 {
            if fragments.count.isMultiple(of:256) { try Task.checkCancellation() }
            let range=start..<min(source.count,start+65)
            var bounds=CGRect.null
            if origin == nil {
              bounds=try source.bounds(in:range).bounds
            } else {
              source.forEachSample(in:range) { sample in
                let p=Self.point(sample,origin:origin),r=max(0.25,sample.width/2)*1.8
                bounds=bounds.union(.init(x:p.x-r,y:p.y-r,width:r*2,height:r*2))
              }
            }
            box = box.union(bounds)
            fragments.append(.init(entry:e,span:s,range:range,bounds:bounds))
          }
        }
        boxes.append(box)
      }
      self.fragments = fragments; entryBounds = boxes; sourceSampleCount = count
      index = .init(fragments.map(\.bounds))
    }
    private static func point(_ sample: SpatialInkSample, origin: WorldPoint?) -> SpatialPoint {
      origin.flatMap { o in sample.worldPoint.map { o.delta(to:$0) } } ?? sample.point
    }
    func selection(polygon: [SpatialPoint], surface: SurfaceID, origin queryOrigin: WorldPoint?, bounds: CGRect?) throws -> Result? {
      guard surface == self.surface, polygon.count >= 3 else { return nil }
      let delta = origin.flatMap { o in queryOrigin.map { o.delta(to:$0) } } ?? .zero
      let polygon = polygon.map { SpatialPoint(x:$0.x+delta.x,y:$0.y+delta.y) }
      let region = polygon.reduce(CGRect.null) { $0.union(.init(x:$1.x,y:$1.y,width:0,height:0)) }
      var chosen = Set<Int>(), examined = 0
      for id in index.query(region).indices {
        let f = fragments[id], entry = entries[f.entry]
        guard entry.tool == .pen, !excluded.contains(entry.id), !chosen.contains(f.entry) else { continue }
        try Task.checkCancellation()
        let samples=entry.sources[f.span].decoded(in:f.range),range=samples.indices
        examined += range.count
        func point(_ i: Int) -> SpatialPoint { Self.point(samples[i],origin:origin) }
        let intersects = range.contains { i in
          let p = point(i), r = max(0.25,samples[i].width/2)*1.8
          return NotebookToolGeometry.intersects(.init(x:p.x-r,y:p.y-r,width:max(0.01,2*r),height:max(0.01,2*r)),polygon:polygon)
        } || range.dropLast().contains { NotebookToolGeometry.intersects(from:point($0),to:point($0+1),polygon:polygon) }
        if intersects { chosen.insert(f.entry) }
      }
      guard let first = chosen.min() else { return nil }
      let selectedSamples = chosen.reduce(0) { n, e in n + entries[e].sources.reduce(0) { $0+$1.count } }
      guard chosen.count <= 1024, selectedSamples <= 10_000 else {
        throw CollaborationError("selection_limit","Выделите меньшую часть рукописи: это выделение слишком большое.")
      }
      var box = chosen.reduce(CGRect.null) { $0.union(entryBounds[$1]) }
      if let bounds { box = box.intersection(bounds.offsetBy(dx:delta.x,dy:delta.y)) }
      guard !box.isNull, box.width > 0, box.height > 0 else { return nil }
      let frame = PageRect(x:box.minX,y:box.minY,width:box.width,height:box.height)
      // Cuts outside the selected whole cannot affect it. Keep only candidate
      // sweep ranges, coalescing shared endpoints before creating vector layers.
      var cuts: [Int:[Int:[Range<Int>]]] = [:]
      for id in index.query(box).indices {
        let f = fragments[id]
        if f.entry > first, entries[f.entry].tool == .eraser { cuts[f.entry,default:[:]][f.span,default:[]].append(f.range) }
      }
      var layers: [NotebookFreehand.Layer] = [], vertices = 0
      for e in Set(chosen).union(cuts.keys).sorted() {
        try Task.checkCancellation()
        let entry = entries[e]
        if chosen.contains(e) {
          for source in entry.sources {
            // The chosen whole alone is materialized for the existing vector
            // representation. Invisible/unselected source events stay encoded.
            let mesh=NotebookFreehand.mesh(samples:source.decoded(),frame:frame,origin:origin)
            vertices += mesh.count
            guard vertices <= NotebookFreehand.maximumVertices else {
              throw CollaborationError("selection_limit","Слишком сложное выделение; выделите меньшую часть рукописи.")
            }
            if !mesh.isEmpty { layers.append(.init(color:entry.color,vertices:mesh)) }
          }
        } else if let spans = cuts[e] {
          for s in spans.keys.sorted() {
            var ranges: [Range<Int>] = []
            for r in spans[s]!.sorted(by:{ $0.lowerBound < $1.lowerBound }) {
              if let last = ranges.last, r.lowerBound <= last.upperBound {
                ranges[ranges.count-1] = last.lowerBound..<max(last.upperBound,r.upperBound)
              } else { ranges.append(r) }
            }
            for range in ranges {
              examined += range.count
              let local=entry.sources[s].decoded(in:range).map { sample in
                let p=Self.point(sample,origin:origin)
                return NotebookFreehand.Eraser.Sample(point:.init(x:p.x-frame.x,y:p.y-frame.y),width:sample.width)
              }
              layers.append(.init(eraser:.init(size:.init(x:frame.width,y:frame.height),samples:local)))
            }
          }
        }
      }
      let ink = NotebookFreehand(layers:layers)
      guard ink.isValid else { throw CollaborationError("selection_limit","Выделите меньшую часть рукописи.") }
      let clip = polygon.map { CGPoint(x:($0.x-frame.x)/frame.width,y:($0.y-frame.y)/frame.height) }
      guard ink.geometry.intersects(clip) else { return nil }
      return .init(frame:.init(x:frame.x-delta.x,y:frame.y-delta.y,width:frame.width,height:frame.height),
        graphic:.init(shape:.freehand,sourceInkIDs:chosen.sorted().map { entries[$0].id },freehand:ink),
        examinedSampleCount:examined,sourceSampleCount:sourceSampleCount)
    }
  }
}

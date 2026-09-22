import CoreGraphics
import Foundation

public struct NotebookGraphicVisibilityResult: Sendable {
  public let layouts:[String:NotebookGraphicLayout]
  public let placements:[String:NotebookElementPlacement]
  public let visitedIndexNodes:Int
  public let resolvedGraphics:Int
  public let overflow:Bool
  /// Only the bounding tree arrays, not a claim about total resident memory.
  public let boundsIndexBytes:Int
}

/// Broad-phase leaves inside one retained local frame. A moved whole maps the
/// contact into that frame and resolves only these IDs against its live graph.
public struct NotebookGraphicCandidateResult: Sendable {
  public let ids:Set<String>
  public let visitedIndexNodes:Int
  public let overflow:Bool
  public let boundsIndexBytes:Int
}

/// Elements use the same immutable bounds tree as measured ink, in each
/// existing local frame. A whole pose changes the query, not all leaf bounds.
/// Durable board windows remain SQL-owned; this tree is retained with a live
/// scene only so interaction does not expand a moved whole on Pencil-down.
final class NotebookGraphicVisibility: Sendable {
  private struct Level: Sendable {
    let ids:[String]
    let index:InkBoundsIndex
    init(_ entries:[(String,CGRect)]) { ids=entries.map(\.0);index = .init(entries.map(\.1)) }
  }
  private let levels:[String?:Level]
  private let groups:Set<String>
  private let parents:[String:String]
  private let dependents:[String:Set<String>]
  private let labelled:Set<String>
  private let elements:[String:NotebookGraphicGraph.ElementSource]
  private let surface:SurfaceID
  private let bytes:Int

  init(surface:SurfaceID,graph:NotebookGraphicGraph,nodes:[NotebookGraphicGraph.Node],
    groups:[String:NotebookGraphicGraph.ElementSource],
    elements:[String:NotebookGraphicGraph.ElementSource]) {
    self.surface=surface
    let includeRoot=surface.kind == .page
    // Board rendering already owns a world index. Its local-frame companion
    // retains only grouped leaves, not a second copy of every root element.
    self.elements=elements.filter { $0.value.surface == surface
      && (includeRoot || $0.value.source.parentID != nil) }
    let nodes=nodes.filter { $0.surface == surface }
    let placedGroups=groups.compactMap { id,group -> (String,NotebookElementPlacement)? in
      guard group.surface == surface,let value=graph.placement(id) else { return nil };return (id,value)
    }
    let groupIDs=Set(placedGroups.map(\.0));self.groups=groupIDs
    func parent(_ id:String?) -> String? { id.map(collaborationIdentity).flatMap { groupIDs.contains($0) ? $0 : nil } }
    var parents:[String:String]=[:],edges:[String:Set<String>]=[:],labelled=Set<String>()
    var entries:[String?:[(String,CGRect)]]=[:]
    for node in nodes {
      let id=collaborationIdentity(node.id),parent=parent(node.placement.parentID)
      parents[id]=parent
      for binding in node.graphic.connection?.bindings ?? [] {
        edges[collaborationIdentity(binding.elementID),default:[]].insert(id)
        let own=Set(node.placement.ancestors.map(collaborationIdentity))
        let target=Set((graph.node(binding.elementID)?.placement.ancestors ?? []).map(collaborationIdentity))
        for ancestor in own.symmetricDifference(target) { edges[ancestor,default:[]].insert(id) }
      }
      guard includeRoot || parent != nil else { continue }
      // Glyph extents belong to typography, not a guessed character width.
      // Until that owner supplies extents, labels remain conservative candidates.
      if !node.graphic.label.isEmpty { labelled.insert(id);continue }
      if let bounds=Self.bounds(node,in:graph,parent:parent != nil) { entries[parent,default:[]].append((id,bounds)) }
    }
    for (id,element) in self.elements {
      guard let placement=graph.placement(id) else { continue }
      let parent=parent(placement.parentID);parents[id]=parent
      let presentation=NotebookElementPresentation(placement:placement,
        text:element.text,style:element.textStyle)
      entries[parent,default:[]].append((id,Self.outward(presentation.localBounds,
        through:parent == nil ? placement.transform : placement.localTransform)))
    }
    var levels:[String?:Level]=[:]
    for (id,placement) in placedGroups.sorted(by:{ $0.1.ancestors.count>$1.1.ancestors.count }) {
      let parent=placement.parentID.map(collaborationIdentity);parents[id]=parent
      let level=Level(entries[id] ?? []);levels[id]=level
      if !level.index.bounds.isNull,includeRoot || parent != nil {
        entries[parent,default:[]].append((id,Self.outward(level.index.bounds,through:placement.localTransform)))
      }
    }
    if includeRoot { levels[nil]=Level(entries[nil] ?? []) }
    self.levels=levels;self.parents=parents;dependents=edges;self.labelled=labelled
    bytes=levels.values.reduce(0) { $0+$1.index.byteCount }
  }

  /// Traverse only the requested whole's indexed subtree. Leaves are coarse
  /// owners; exact current geometry is deliberately left to the caller.
  func candidates(in groupID:String,area:CGRect,graph:NotebookGraphicGraph,
    changed:Set<String>,limit:Int) -> NotebookGraphicCandidateResult {
    precondition(limit > 0)
    let root=collaborationIdentity(groupID)
    guard groups.contains(root),!area.isNull else { return .init(ids:[],visitedIndexNodes:0,
      overflow:false,boundsIndexBytes:bytes) }
    func parent(_ id:String) -> String? {
      graph.source(id)?.parentID.map(collaborationIdentity).flatMap { groups.contains($0) ? $0 : nil }
    }
    var affected=changed
    for id in changed { affected.formUnion(dependents[id] ?? []) }
    var forced:[String?:Set<String>]=[:]
    for id in affected {
      for current in [false,true] {
        var next:String?=id,seen=Set<String>()
        while let key=next,seen.count<65,seen.insert(key).inserted {
          let owner=current ? parent(key) : parents[key]
          forced[owner,default:[]].insert(key);next=owner
        }
      }
    }
    var ids=Set<String>(),visited=0,overflow=false
    func include(_ id:String) {
      guard !overflow,!groups.contains(id),ids.insert(id).inserted else { return }
      if ids.count>limit { overflow=true }
    }
    func visit(_ owner:String,area:CGRect,depth:Int) {
      guard depth<65,!overflow else { return }
      let level=levels[owner]
      let query=level?.index.query(area,limit:max(1,limit-ids.count))
      visited += query?.visitedNodes ?? 0
      if query?.overflow == true { overflow=true;return }
      var values=Set((query?.indices ?? []).map { level!.ids[$0] })
      values.formUnion(forced[owner] ?? [])
      for id in values {
        guard !overflow,parent(id) == owner else { continue }
        if groups.contains(id) {
          guard let placement=graph.placement(id) else { continue }
          let transform=placement.localTransform,det=transform.a*transform.d-transform.b*transform.c
          let inverse=transform.inverted()
          let query=det.isFinite && det != 0 && [inverse.a,inverse.b,inverse.c,inverse.d,inverse.tx,inverse.ty].allSatisfy(\.isFinite)
            ? Self.outward(area,through:inverse) : CGRect.infinite
          visit(id,area:query,depth:depth+1)
        } else { include(id) }
      }
    }
    visit(root,area:area,depth:0)
    // A connector crossing the whole boundary changes with the whole although
    // it is not a descendant. Resolve only those retained reverse bindings.
    for id in dependents[root] ?? [] where !overflow { include(id) }
    // Label extents do not yet have a typography-owned coarse box. Preserve
    // correctness, but constrain that conservative scan to this whole.
    for id in labelled where !overflow && graph.placement(id)?.descends(from:root) == true { include(id) }
    return .init(ids:ids,visitedIndexNodes:visited,overflow:overflow,boundsIndexBytes:bytes)
  }

  func query(_ area:CGRect,graph:NotebookGraphicGraph,changed:Set<String>,limit:Int) -> NotebookGraphicVisibilityResult {
    precondition(limit > 0)
    guard !area.isNull else { return .init(layouts:[:],placements:[:],visitedIndexNodes:0,
      resolvedGraphics:0,overflow:false,boundsIndexBytes:bytes) }
    func parent(_ id:String) -> String? {
      graph.source(id)?.parentID.map(collaborationIdentity).flatMap { groups.contains($0) ? $0 : nil }
    }
    var affected=changed
    for id in changed { affected.formUnion(dependents[id] ?? []) }
    var forced:[String?:Set<String>]=[:]
    // Old membership removes the old candidate; new membership brings its new
    // branch into the query. Neither operation walks that branch's descendants.
    for id in affected {
      for current in [false,true] {
        var next:String?=id,seen=Set<String>()
        while let key=next,seen.count<65,seen.insert(key).inserted {
          let parent=current ? parent(key) : parents[key]
          forced[parent,default:[]].insert(key);next=parent
        }
      }
    }
    var layouts:[String:NotebookGraphicLayout]=[:],placements:[String:NotebookElementPlacement]=[:]
    var visited=0,resolved=0,read=Set<String>(),overflow=false
    func include(_ id:String) {
      guard !overflow,read.insert(id).inserted else { return }
      if let node=graph.node(id),node.surface == surface {
        resolved += 1
        guard let layout=graph.resolve(id).layout else { return }
        if node.graphic.label.isEmpty {
          guard let bounds=Self.bounds(node,in:graph,parent:false),Self.intersects(bounds,area) else { return }
        }
        guard layouts.count+placements.count < limit else { overflow=true;return }
        layouts[node.id]=layout
      } else if let element=elements[collaborationIdentity(id)],
        element.surface == surface,let placement=graph.placement(id) {
        let presentation=NotebookElementPresentation(placement:placement,
          text:element.text,style:element.textStyle)
        guard Self.intersects(presentation.bounds,area) else { return }
        guard layouts.count+placements.count < limit else { overflow=true;return }
        placements[id]=placement
      }
    }
    func visit(_ parent:String?,area:CGRect,depth:Int) {
      guard depth<65,!overflow else { return }
      let level=levels[parent]
      let query=level?.index.query(area,limit:max(1,limit-layouts.count-placements.count))
      visited += query?.visitedNodes ?? 0
      if query?.overflow == true { overflow=true;return }
      var candidates=Set((query?.indices ?? []).map { level!.ids[$0] })
      candidates.formUnion(forced[parent] ?? [])
      for id in candidates {
        guard !overflow else { return }
        guard (graph.source(id)?.parentID.map(collaborationIdentity).flatMap { groups.contains($0) ? $0 : nil }) == parent else { continue }
        if groups.contains(id) {
          guard let placement=graph.placement(id) else { continue }
          let transform=placement.localTransform,det=transform.a*transform.d-transform.b*transform.c
          let inverse=transform.inverted()
          let query=det.isFinite && det != 0 && [inverse.a,inverse.b,inverse.c,inverse.d,inverse.tx,inverse.ty].allSatisfy(\.isFinite)
            ? Self.outward(area,through:inverse) : CGRect.infinite
          visit(id,area:query,depth:depth+1)
        } else { include(id) }
      }
    }
    visit(nil,area:area,depth:0)
    for id in labelled where !overflow { include(id) }
    return .init(layouts:layouts,placements:placements,visitedIndexNodes:visited,
      resolvedGraphics:resolved,overflow:overflow,boundsIndexBytes:bytes)
  }

  private static func bounds(_ node:NotebookGraphicGraph.Node,in graph:NotebookGraphicGraph,parent:Bool) -> CGRect? {
    guard node.shown else { return nil }
    let graphic=node.graphic,t=parent ? node.placement.localTransform : node.placement.transform
    if graphic.connection != nil {
      guard let layout=graph.resolve(node.id,space:parent ? .parent : .surface).layout else { return nil }
      return outward(.init(x:layout.frame.x,y:layout.frame.y,width:layout.frame.width,height:layout.frame.height),through:.identity)
    }
    let size=CGSize(width:node.placement.localSize.x,height:node.placement.localSize.y)
    let body:CGRect
    if graphic.freehand != nil {
      // Freehand pixels and semantic contact are clipped to this whole frame.
      // A coarse scene bound must never tessellate/Boolean-union every source
      // event merely to decide which whole can intersect the viewport.
      body=CGRect(origin:.zero,size:size)
    } else if graphic.transform != nil || graphic.shape == .path {
      body=NotebookGraphicGeometry.paintPath(graphic,layout:nil,size:size).boundingBoxOfPath
    } else {
      // Round strokes normally lie inside the frame; this also admits the
      // overflow of an unusually thick stroke on a very small object.
      body=CGRect(origin:.zero,size:size).insetBy(dx:-graphic.style.strokeWidth/2,dy:-graphic.style.strokeWidth/2)
    }
    return body.isNull ? nil : outward(body,through:t)
  }
  private static func intersects(_ a:CGRect,_ b:CGRect) -> Bool {
    a.maxX>=b.minX && a.minX<=b.maxX && a.maxY>=b.minY && a.minY<=b.maxY
  }
  /// Conservative arithmetic margin, including cancellation in the inverse
  /// map. A non-finite coarse query visits the branch rather than dropping it.
  private static func outward(_ rect:CGRect,through t:CGAffineTransform) -> CGRect {
    guard !rect.isNull else { return .null }
    guard !rect.isInfinite else { return .infinite }
    let value=rect.applying(t)
    let x=max(abs(rect.minX),abs(rect.maxX)),y=max(abs(rect.minY),abs(rect.maxY))
    let magnitude=max(abs(t.a)*x+abs(t.c)*y+abs(t.tx),abs(t.b)*x+abs(t.d)*y+abs(t.ty),1)
    let error=magnitude*Double.ulpOfOne*32
    guard [value.minX,value.minY,value.maxX,value.maxY,error].allSatisfy(\.isFinite) else { return .infinite }
    return value.insetBy(dx:-error,dy:-error)
  }
}

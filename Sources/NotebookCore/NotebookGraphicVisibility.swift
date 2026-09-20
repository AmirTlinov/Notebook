import CoreGraphics
import Foundation

public struct NotebookGraphicVisibilityResult: Sendable {
  public let layouts:[String:NotebookGraphicLayout]
  public let visitedIndexNodes:Int
  public let resolvedGraphics:Int
  /// Only the bounding tree arrays, not a claim about total resident memory.
  public let boundsIndexBytes:Int
}

/// Page graphics use the same immutable bounds tree as measured ink, in each
/// existing local frame. A whole pose changes the query, not all leaf bounds.
/// Boards keep their addressed SQL window; this is not another board index.
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
  private let pageID:UUID
  private let bytes:Int

  init(pageID:UUID,graph:NotebookGraphicGraph,nodes:[NotebookGraphicGraph.Node],groups:[String:NotebookGraphicGraph.ElementSource]) {
    self.pageID=pageID
    let nodes=nodes.filter { $0.surface == .page(pageID) }
    let placedGroups=groups.compactMap { id,group -> (String,NotebookElementPlacement)? in
      guard group.surface == .page(pageID),let value=graph.placement(id) else { return nil };return (id,value)
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
      // Glyph extents belong to typography, not a guessed character width.
      // Until that owner supplies extents, labels remain conservative candidates.
      if !node.graphic.label.isEmpty { labelled.insert(id);continue }
      if let bounds=Self.bounds(node,in:graph,parent:parent != nil) { entries[parent,default:[]].append((id,bounds)) }
    }
    var levels:[String?:Level]=[:]
    for (id,placement) in placedGroups.sorted(by:{ $0.1.ancestors.count>$1.1.ancestors.count }) {
      let parent=placement.parentID.map(collaborationIdentity);parents[id]=parent
      let level=Level(entries[id] ?? []);levels[id]=level
      if !level.index.bounds.isNull {
        entries[parent,default:[]].append((id,Self.outward(level.index.bounds,through:placement.localTransform)))
      }
    }
    levels[nil]=Level(entries[nil] ?? [])
    self.levels=levels;self.parents=parents;dependents=edges;self.labelled=labelled
    bytes=levels.values.reduce(0) { $0+$1.index.byteCount }
  }

  func query(_ area:CGRect,graph:NotebookGraphicGraph,changed:Set<String>) -> NotebookGraphicVisibilityResult {
    guard !area.isNull else { return .init(layouts:[:],visitedIndexNodes:0,resolvedGraphics:0,boundsIndexBytes:bytes) }
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
    var layouts:[String:NotebookGraphicLayout]=[:],visited=0,resolved=0,read=Set<String>()
    func include(_ id:String) {
      guard read.insert(id).inserted,let node=graph.node(id),node.surface == .page(pageID) else { return }
      resolved += 1
      guard let layout=graph.resolve(id).layout else { return }
      if node.graphic.label.isEmpty {
        guard let bounds=Self.bounds(node,in:graph,parent:false),Self.intersects(bounds,area) else { return }
      }
      layouts[node.id]=layout
    }
    func visit(_ parent:String?,area:CGRect,depth:Int) {
      guard depth<65 else { return }
      let level=levels[parent],query=level?.index.query(area)
      visited += query?.visitedNodes ?? 0
      var candidates=Set((query?.indices ?? []).map { level!.ids[$0] })
      candidates.formUnion(forced[parent] ?? [])
      for id in candidates {
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
    for id in labelled { include(id) }
    return .init(layouts:layouts,visitedIndexNodes:visited,resolvedGraphics:resolved,boundsIndexBytes:bytes)
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

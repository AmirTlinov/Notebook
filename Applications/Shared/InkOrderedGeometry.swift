import CoreGraphics
import Foundation
import Metal
import NotebookCore

/// Prepared body geometry belongs to the same physical ink plane as its raw
/// contacts. No drawable, timer, visibility claim or durable state lives here.
@MainActor final class InkOrderedGeometry {
  let plan:NotebookOrderedInkPlan
  private let bodies:[UUID:InkMaterialRenderer.OrderedBody]
  private let index:WorkspaceSpatialIndex
  private let overridden:Set<UUID>
  private static func bounds(_ body:NotebookOrderedInkPlan.Body)->WorkspaceSpatialBounds {
    .init(origin:body.layout.origin.offsetBy(x:body.layout.frame.x,y:body.layout.frame.y),
      width:body.layout.frame.width,height:body.layout.frame.height)
  }
  private static func makeIndex(_ bodies:[NotebookOrderedInkPlan.Body])->WorkspaceSpatialIndex {
    .init(entries:bodies.map{.init(id:.item($0.sourceID),bounds:bounds($0),zIndex:0)})
  }
  init(_ plan:NotebookOrderedInkPlan,reusing previous:InkOrderedGeometry?,device:any MTLDevice,
    resources:SceneRenderResources,owner:ScenePhysicalOwnerLease?) async throws {
    self.plan=plan;index=Self.makeIndex(plan.bodies);overridden=[]
    if !plan.isEmpty {try await InkRasterRenderer.shared.prepareOrdered()}
    var values:[UUID:InkMaterialRenderer.OrderedBody]=[:]
    for source in plan.bodies {
      try Task.checkCancellation()
      let body=InkMaterialRenderer.OrderedBody(source,reusing:previous?.bodies[source.sourceID])
      try await body.prepareClip(device:device,resources:resources,owner:owner)
      values[source.sourceID]=body
    }
    bodies=values
  }
  private init(plan:NotebookOrderedInkPlan,bodies:[UUID:InkMaterialRenderer.OrderedBody],
    indexSource:InkOrderedGeometry?,changed:Set<UUID> = []) {
    self.plan=plan;self.bodies=bodies
    index=indexSource?.index ?? Self.makeIndex(plan.bodies)
    overridden=indexSource.map{$0.overridden.union(changed)} ?? []
  }
  private func candidates(in rect:CGRect,camera:SpatialCamera?,viewport:SpatialPoint)->[NotebookOrderedInkPlan.Body] {
    guard !rect.isNull,!rect.isEmpty else {return []}
    let area=rect.insetBy(dx:-1,dy:-1)
    let origin=camera?.screenToWorld(.init(x:area.minX,y:area.minY),viewport:viewport) ?? WorldPoint(x:area.minX,y:area.minY)
    let bounds=WorkspaceSpatialBounds(origin:origin,width:area.width/(camera?.scale ?? 1),height:area.height/(camera?.scale ?? 1))
    let indexed=index.intersections(in:bounds,limit:max(1,bodies.count+overridden.count)).entries.compactMap {entry -> NotebookOrderedInkPlan.Body? in
      guard case .item(let id)=entry.id,!overridden.contains(id) else {return nil}
      return bodies[id]?.source
    }
    let edited=overridden.compactMap{bodies[$0]?.source}.filter{Self.bounds($0).intersects(bounds)}
    return (indexed+edited).sorted{$0.key<$1.key}
  }
  static func replacing(_ ids:Set<UUID>,with candidate:InkOrderedGeometry?,plan:NotebookOrderedInkPlan,
    in current:InkOrderedGeometry?,currentPlan:NotebookOrderedInkPlan)->InkOrderedGeometry? {
    let sources=currentPlan.bodies.filter{!ids.contains($0.sourceID)}+plan.bodies.filter{ids.contains($0.sourceID)}
    guard !sources.isEmpty else {return nil}
    var bodies=current?.bodies ?? [:]
    for id in ids {bodies[id]=candidate?.bodies[id]}
    return .init(plan:.init(bodies:sources,suppressedInkIDs:currentPlan.suppressedInkIDs.subtracting(ids).union(plan.suppressedInkIDs.intersection(ids))),bodies:bodies,indexSource:current,changed:ids)
  }
  static func restoring(_ original:InkOrderedGeometry?,originalPlan:NotebookOrderedInkPlan,in current:InkOrderedGeometry?,removing ids:Set<UUID>)->InkOrderedGeometry? {
    let retained=(current?.plan.bodies ?? []).filter{!ids.contains($0.sourceID)}
    let restored=(original?.plan.bodies ?? []).filter{ids.contains($0.sourceID)}
    let bodies=retained+restored
    guard !bodies.isEmpty else {return nil}
    let plan=NotebookOrderedInkPlan(bodies:bodies,suppressedInkIDs:(current?.plan.suppressedInkIDs ?? []).subtracting(ids).union(originalPlan.suppressedInkIDs.intersection(ids)))
    var geometry=current?.bodies ?? [:]
    for id in ids {geometry[id]=original?.bodies[id]}
    return .init(plan:plan,bodies:geometry,indexSource:current,changed:ids)
  }
  func replacingErasures(_ erasures:InkElementErasureMap)->InkOrderedGeometry {
    var sources=plan.bodies,prepared=bodies
    for index in sources.indices {
      let old=sources[index]
      guard let next=erasures[old.elementID],next != old.erasures else {continue}
      let value=NotebookOrderedInkPlan.Body(elementID:old.elementID,key:old.key,graphic:old.graphic,layout:old.layout,erasures:next)
      sources[index]=value;prepared[value.sourceID]=InkMaterialRenderer.OrderedBody(value,reusing:prepared[value.sourceID])
    }
    return .init(plan:.init(bodies:sources,suppressedInkIDs:plan.suppressedInkIDs),bodies:prepared,indexSource:self)
  }
  func events(raw:[(NotebookInkPaintKey,InkRasterRenderer.Draw)],camera:SpatialCamera?,viewport:SpatialPoint,
    region:CGRect,pixels:CGSize,device:any MTLDevice,resources:SceneRenderResources,owner:ScenePhysicalOwnerLease?,liveCuts:InkElementErasureMap = [:],damage:CGRect? = nil) throws
    -> (events:[InkRasterRenderer.OrderedEvent],reservations:[RasterReservation]) {
    var result:[InkRasterRenderer.OrderedEvent]=[],held:[RasterReservation]=[],index=0
    let visible=candidates(in:damage ?? region,camera:camera,viewport:viewport)
    func appendBody(_ source:NotebookOrderedInkPlan.Body) throws {
      let position=camera.map {$0.worldToScreen(source.layout.origin.offsetBy(x:source.layout.frame.x,y:source.layout.frame.y),viewport:viewport)}
        ?? .init(x:source.layout.frame.x,y:source.layout.frame.y)
      let scale=camera?.scale ?? 1
      let bounds=CGRect(x:position.x,y:position.y,width:source.layout.frame.width*scale,height:source.layout.frame.height*scale)
      guard bounds.intersects((damage ?? region).insetBy(dx:-1,dy:-1)) else {return}
      guard !source.erasures.contains(where:{$0.target.wholeElement}),
        !(liveCuts[source.elementID] ?? []).contains(where:{$0.target.wholeElement}) else {return}
      guard let body=bodies[source.sourceID] else {throw SceneRenderError.snapshotPending("ordered_ink_body")}
      let prepared=try body.prepare(camera:camera,viewport:viewport,region:region,pixels:pixels,
        device:device,resources:resources,owner:owner,extraCuts:liveCuts[source.elementID] ?? [])
      result.append(prepared.event);held += prepared.reservations
    }
    // Raw ranges come from the existing painter-ordered mesh index. Neither
    // source history nor a full buffer array is copied/sorted for a pose change.
    for (key,draw) in raw {
      while index<visible.count,visible[index].key<key {try appendBody(visible[index]);index += 1}
      if !plan.suppressedInkIDs.contains(key.actionID) {result.append(.raw(draw))}
    }
    while index<visible.count {try appendBody(visible[index]);index += 1}
    return (result,held)
  }
}

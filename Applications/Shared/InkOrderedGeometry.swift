import CoreGraphics
import Foundation
import Metal
import NotebookCore

/// Prepared body geometry belongs to the same physical ink plane as its raw
/// contacts. No drawable, timer, visibility claim or durable state lives here.
@MainActor final class InkOrderedGeometry {
  let plan:NotebookOrderedInkPlan
  private let bodies:InkActionMap<UUID,InkMaterialRenderer.OrderedBody>
  private let index:WorkspaceSpatialIndex
  private static func bounds(_ body:NotebookOrderedInkPlan.Body)->WorkspaceSpatialBounds {
    .init(origin:body.layout.origin.offsetBy(x:body.layout.frame.x,y:body.layout.frame.y),
      width:body.layout.frame.width,height:body.layout.frame.height)
  }
  private static func makeIndex(_ bodies:InkActionMap<NotebookInkPaintKey,NotebookOrderedInkPlan.Body>.Values)->WorkspaceSpatialIndex {
    .init(entries:bodies.map{.init(id:.item($0.sourceID),bounds:bounds($0),zIndex:0)})
  }
  init(_ plan:NotebookOrderedInkPlan,reusing previous:InkOrderedGeometry?,device:any MTLDevice,
    resources:SceneRenderResources,owner:ScenePhysicalOwnerLease?) async throws {
    self.plan=plan;index=Self.makeIndex(plan.bodies)
    if !plan.isEmpty {try await InkRasterRenderer.shared.prepareOrdered()}
    var values:[(UUID,InkMaterialRenderer.OrderedBody)]=[]
    values.reserveCapacity(plan.bodies.count)
    for source in plan.bodies {
      try Task.checkCancellation()
      let body=InkMaterialRenderer.OrderedBody(source,reusing:previous?.bodies[source.sourceID])
      try await body.prepareClip(device:device,resources:resources,owner:owner)
      values.append((source.sourceID,body))
    }
    bodies = .init(entries:values)
  }
  private init(plan:NotebookOrderedInkPlan,bodies:InkActionMap<UUID,InkMaterialRenderer.OrderedBody>,
    indexSource:InkOrderedGeometry?,changed:Set<UUID> = []) {
    self.plan=plan;self.bodies=bodies
    if let indexSource {
      index=indexSource.index.replacing(Set(changed.map{.item($0)}),with:changed.compactMap {id in
        bodies[id].map{.init(id:.item(id),bounds:Self.bounds($0.source),zIndex:0)}
      })
    } else {index=Self.makeIndex(plan.bodies)}
  }
  private func candidates(in rect:CGRect,camera:SpatialCamera?,viewport:SpatialPoint)->[NotebookOrderedInkPlan.Body] {
    guard !rect.isNull,!rect.isEmpty else {return []}
    let area=rect.insetBy(dx:-1,dy:-1)
    let origin=camera?.screenToWorld(.init(x:area.minX,y:area.minY),viewport:viewport) ?? WorldPoint(x:area.minX,y:area.minY)
    let bounds=WorkspaceSpatialBounds(origin:origin,width:area.width/(camera?.scale ?? 1),height:area.height/(camera?.scale ?? 1))
    let indexed=index.intersections(in:bounds,limit:max(1,bodies.count)).entries.compactMap {entry -> NotebookOrderedInkPlan.Body? in
      guard case .item(let id)=entry.id else {return nil}
      return bodies[id]?.source
    }
    return indexed.sorted{$0.key<$1.key}
  }
  static func replacing(_ ids:Set<UUID>,with candidate:InkOrderedGeometry?,plan:NotebookOrderedInkPlan,
    in current:InkOrderedGeometry?,currentPlan:NotebookOrderedInkPlan)->InkOrderedGeometry? {
    let merged=currentPlan.replacing(ids,from:plan)
    guard !merged.isEmpty else {return nil}
    var bodies=current?.bodies ?? .init()
    for id in ids {bodies[id]=candidate?.bodies[id]}
    return .init(plan:merged,bodies:bodies,indexSource:current,changed:ids)
  }
  static func restoring(_ original:InkOrderedGeometry?,originalPlan:NotebookOrderedInkPlan,in current:InkOrderedGeometry?,currentPlan:NotebookOrderedInkPlan,removing ids:Set<UUID>)->InkOrderedGeometry? {
    let plan=currentPlan.replacing(ids,from:originalPlan)
    guard !plan.isEmpty else {return nil}
    var geometry=current?.bodies ?? .init()
    for id in ids {geometry[id]=original?.bodies[id]}
    return .init(plan:plan,bodies:geometry,indexSource:current,changed:ids)
  }
  func replacingErasures(_ erasures:InkElementErasureMap)->InkOrderedGeometry {
    var updated=plan,prepared=bodies
    for (elementID,next) in erasures {
      guard let old=plan.body(elementID:elementID),next != old.erasures else {continue}
      let value=NotebookOrderedInkPlan.Body(elementID:old.elementID,key:old.key,graphic:old.graphic,layout:old.layout,erasures:next)
      updated=updated.replacingBody(value);prepared[value.sourceID]=InkMaterialRenderer.OrderedBody(value,reusing:prepared[value.sourceID])
    }
    return .init(plan:updated,bodies:prepared,indexSource:self)
  }
  /// Addressed lookup avoids walking the ordered plane on every Pencil sample.
  func erasureDamage(_ next:InkElementErasureMap,replacing previous:InkElementErasureMap)->CGRect {
    var damage=CGRect.null
    for id in Set(next.map(\.key)).union(previous.map(\.key)) {
      guard let source=plan.body(elementID:id) else {continue}
      let local=InkMaterialRenderer.erasureDamage(next[id] ?? [],replacing:previous[id] ?? [],
        transform:source.graphic.transform,layout:source.layout)
      damage=damage.union(local.offsetBy(dx:source.layout.frame.x,dy:source.layout.frame.y))
    }
    return damage
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
        device:device,resources:resources,owner:owner,extraCuts:liveCuts[source.elementID] ?? [],damage:damage)
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

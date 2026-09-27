import CoreGraphics
import Foundation
import Metal
import NotebookCore

/// Prepared body geometry belongs to the same physical ink plane as its raw
/// contacts. No drawable, timer, visibility claim or durable state lives here.
@MainActor final class InkOrderedGeometry {
  let plan:NotebookOrderedInkPlan
  private let bodies:[UUID:InkMaterialRenderer.OrderedBody]
  init(_ plan:NotebookOrderedInkPlan,reusing previous:InkOrderedGeometry?,device:any MTLDevice,
    resources:SceneRenderResources,owner:ScenePhysicalOwnerLease?) async throws {
    self.plan=plan
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
  private init(plan:NotebookOrderedInkPlan,bodies:[UUID:InkMaterialRenderer.OrderedBody]) {self.plan=plan;self.bodies=bodies}
  static func restoring(_ original:InkOrderedGeometry?,originalPlan:NotebookOrderedInkPlan,in current:InkOrderedGeometry?,removing ids:Set<UUID>)->InkOrderedGeometry? {
    let retained=(current?.plan.bodies ?? []).filter{!ids.contains($0.sourceID)}
    let restored=(original?.plan.bodies ?? []).filter{ids.contains($0.sourceID)}
    let bodies=retained+restored
    guard !bodies.isEmpty else {return nil}
    let plan=NotebookOrderedInkPlan(bodies:bodies,suppressedInkIDs:(current?.plan.suppressedInkIDs ?? []).subtracting(ids).union(originalPlan.suppressedInkIDs.intersection(ids)))
    var geometry=current?.bodies ?? [:]
    for id in ids {geometry[id]=original?.bodies[id]}
    return .init(plan:plan,bodies:geometry)
  }
  func replacingErasures(_ erasures:[String:[InkElementErasure]])->InkOrderedGeometry {
    var sources=plan.bodies,prepared=bodies
    for index in sources.indices {
      let old=sources[index]
      guard let next=erasures[old.elementID],next != old.erasures else {continue}
      let value=NotebookOrderedInkPlan.Body(elementID:old.elementID,key:old.key,graphic:old.graphic,layout:old.layout,erasures:next)
      sources[index]=value;prepared[value.sourceID]=InkMaterialRenderer.OrderedBody(value,reusing:prepared[value.sourceID])
    }
    return .init(plan:.init(bodies:sources,suppressedInkIDs:plan.suppressedInkIDs),bodies:prepared)
  }
  func events(raw:[(NotebookInkPaintKey,InkRasterRenderer.Draw)],camera:SpatialCamera?,viewport:SpatialPoint,
    region:CGRect,pixels:CGSize,device:any MTLDevice,resources:SceneRenderResources,owner:ScenePhysicalOwnerLease?,liveCuts:[String:[InkElementErasure]] = [:]) throws
    -> (events:[InkRasterRenderer.OrderedEvent],reservations:[RasterReservation]) {
    var result:[InkRasterRenderer.OrderedEvent]=[],held:[RasterReservation]=[],index=0
    func appendBody(_ source:NotebookOrderedInkPlan.Body) throws {
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
      while index<plan.bodies.count,plan.bodies[index].key<key {try appendBody(plan.bodies[index]);index += 1}
      if !plan.suppressedInkIDs.contains(key.actionID) {result.append(.raw(draw))}
    }
    while index<plan.bodies.count {try appendBody(plan.bodies[index]);index += 1}
    return (result,held)
  }
}

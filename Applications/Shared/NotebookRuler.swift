import Foundation
import NotebookCore

/// A physical straightedge, not authored geometry. Its pose is local UI state;
/// strokes projected onto the edge use the normal authored-element command.
struct NotebookRuler {
  let address: NotebookToolAddress
  var start: SpatialPoint
  var angle: Double
  var length: Double
  func project(_ point: SpatialPoint, from source: NotebookToolAddress, snap: Bool) -> SpatialPoint {
    let delta = (source.worldOrigin ?? .zero).delta(to:address.worldOrigin ?? .zero)
    let anchor = SpatialPoint(x:start.x+delta.x,y:start.y+delta.y)
    let radians = angle * .pi/180
    var distance = (point.x-anchor.x)*cos(radians)+(point.y-anchor.y)*sin(radians)
    if snap { distance = (distance/PhysicalPaper.gridSpacing).rounded()*PhysicalPaper.gridSpacing }
    distance = min(length,max(0,distance))
    return .init(x:anchor.x+distance*cos(radians),y:anchor.y+distance*sin(radians))
  }
}

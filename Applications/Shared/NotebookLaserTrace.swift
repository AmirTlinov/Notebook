import Foundation
import CoreGraphics
import NotebookCore

/// Pointing can address a printed page without inventing an ink surface for it.
enum NotebookLaserAddress: Equatable, Sendable {
  struct Document: Equatable, Sendable {
    let id: UUID
    let pageIndex: Int
    let token: String
    let hostID: UUID
    let generation: UInt64
    let size: WorkspaceItemGeometry
  }
  case material(NotebookToolAddress)
  case document(Document)

  var bounds: CGRect? {
    switch self {
    case .material(let address): return address.bounds
    case .document(let page): return .init(x:0,y:0,width:page.size.width,height:page.size.height)
    }
  }
}

/// Ephemeral owner-local measurements. The oldest portion expires first even
/// while the Pencil is still down; camera changes only reproject this trace.
struct NotebookLaserTrace: Identifiable {
  struct Sample { let point: SpatialPoint; let time: Double }
  let id: UUID
  let address: NotebookLaserAddress
  let color: PenColor
  let width: Double
  let lifetime: Double
  var samples: [Sample]
  var expiresAt: Double { (samples.last?.time ?? 0)+lifetime }
  mutating func append(_ point: SpatialPoint, time: Double) {
    let cutoff = time-lifetime
    while samples.count > 1 && samples[1].time < cutoff { samples.removeFirst() }
    samples.append(.init(point:point,time:time))
  }
  func points(at time: Double) -> [SpatialPoint] {
    let cutoff = time-lifetime
    guard let index = samples.firstIndex(where:{ $0.time >= cutoff }) else { return [] }
    var points = samples[index...].map(\.point)
    if index > 0 {
      let a = samples[index-1], b = samples[index], t = (cutoff-a.time)/max(0.000001,b.time-a.time)
      points.insert(.init(x:a.point.x+(b.point.x-a.point.x)*t,y:a.point.y+(b.point.y-a.point.y)*t),at:0)
    }
    return points
  }
}

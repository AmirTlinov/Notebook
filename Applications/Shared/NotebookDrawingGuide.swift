import CoreGraphics
import Foundation
import NotebookCore

enum NotebookGuideKind: String, CaseIterable, Sendable {
  case ruler, protractor, compass
  var title: String {
    switch self { case .ruler: "Линейка"; case .protractor: "Транспортир"; case .compass: "Циркуль" }
  }
  var symbol: String {
    switch self { case .ruler: "ruler"; case .protractor: "angle"; case .compass: "compass.drawing" }
  }
}

/// Transient, owner-local geometry. Preferences are not a second live pose.
struct NotebookDrawingGuide: Equatable, Sendable {
  let id: UUID
  let address: NotebookToolAddress
  var kind: NotebookGuideKind
  var start: SpatialPoint
  var angle: Double
  var length: Double
  var openingAngle = 45.0
  var snapToGrid = false

  init(address: NotebookToolAddress, kind: NotebookGuideKind = .ruler, start: SpatialPoint,
    angle: Double = 0, length: Double, id: UUID = UUID()) {
    self.id = id; self.address = address; self.kind = kind; self.start = start
    self.angle = angle; self.length = length
  }

  var isValid: Bool {
    [start.x,start.y,angle,length,openingAngle].allSatisfy(\.isFinite)
      && length > 0 && (0.1...360).contains(openingAngle)
  }

  func constraint(at point: SpatialPoint, from source: NotebookToolAddress,
    screenScale: Double) -> GuideConstraintSnapshot? {
    guard source.surface == address.surface, source.boardID == address.boardID,
      isValid, screenScale.isFinite, screenScale > 0 else { return nil }
    let delta = (source.worldOrigin ?? .zero).delta(to:address.worldOrigin ?? .zero)
    let center = SpatialPoint(x:start.x+delta.x,y:start.y+delta.y)
    let angle = angle * .pi/180
    func segment(_ direction: Double) -> GuideConstraintSnapshot {
      .init(surface:address.surface,primitive:.segment(start:center,
        end:.init(x:center.x+length*cos(direction),y:center.y+length*sin(direction)),
        grid:snapToGrid ? PhysicalPaper.gridSpacing : nil))
    }
    let candidates: [GuideConstraintSnapshot]
    switch kind {
    case .ruler: candidates = [segment(angle)]
    case .protractor:
      candidates = [segment(angle),segment(angle+openingAngle * .pi/180),
        .init(surface:address.surface,primitive:.arc(center:center,radius:length,
          start:angle,sweep:openingAngle * .pi/180))]
    case .compass:
      candidates = [.init(surface:address.surface,primitive:.arc(center:center,radius:length,start:0,sweep:2 * .pi))]
    }
    func distance(_ candidate: GuideConstraintSnapshot) -> Double {
      let projected = candidate.project(point)
      return hypot(projected.x-point.x,projected.y-point.y)
    }
    guard let nearest = candidates.min(by:{ distance($0) < distance($1) }), distance(nearest)*screenScale <= 12 else { return nil }
    return nearest
  }
}

/// Frozen at admission and used for measured, predicted and estimated points.
/// Adapters change only coordinates; pressure, ordering and history stay native.
struct GuideConstraintSnapshot: Equatable, Sendable {
  enum Primitive: Equatable, Sendable {
    case segment(start: SpatialPoint, end: SpatialPoint, grid: Double?)
    case arc(center: SpatialPoint, radius: Double, start: Double, sweep: Double)
  }
  let surface: SurfaceID
  let primitive: Primitive
  private var inputToOwner = CGAffineTransform.identity

  init(surface: SurfaceID, primitive: Primitive) { self.surface = surface; self.primitive = primitive }

  func project(_ point: SpatialPoint) -> SpatialPoint {
    let local = CGPoint(x:point.x,y:point.y).applying(inputToOwner)
    let result = projectOwner(.init(x:local.x,y:local.y))
    let output = CGPoint(x:result.x,y:result.y).applying(inputToOwner.inverted())
    return .init(x:output.x,y:output.y)
  }

  private func projectOwner(_ point: SpatialPoint) -> SpatialPoint {
    switch primitive {
    case .segment(let start,let end,let grid):
      let dx=end.x-start.x, dy=end.y-start.y, length=hypot(dx,dy)
      guard length > 0 else { return start }
      var distance=((point.x-start.x)*dx+(point.y-start.y)*dy)/length
      if let grid, grid > 0 { distance=(distance/grid).rounded()*grid }
      distance=min(length,max(0,distance))
      return .init(x:start.x+dx*distance/length,y:start.y+dy*distance/length)
    case .arc(let center,let radius,let start,let sweep):
      let tau=2 * Double.pi
      var angle=(atan2(point.y-center.y,point.x-center.x)-start).truncatingRemainder(dividingBy:tau)
      if angle < 0 { angle += tau }
      if angle > sweep { angle = angle-sweep < tau-angle ? sweep : 0 }
      return .init(x:center.x+radius*cos(start+angle),y:center.y+radius*sin(start+angle))
    }
  }

  func project(_ point: CGPoint) -> CGPoint {
    let p=project(SpatialPoint(x:point.x,y:point.y)); return .init(x:p.x,y:p.y)
  }

  /// A spatial contact samples in window coordinates. Freeze its projection,
  /// rather than consulting a moving camera again for every point.
  func projected(using ownerToInput: CGAffineTransform) -> Self {
    var result = self
    result.inputToOwner = ownerToInput.inverted()
    return result
  }
}

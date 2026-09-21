import CoreGraphics
import Foundation

/// Disposable hit selection for one measured eraser contact. The measurement
/// owner keeps the samples; this index keeps only the first hit per element.
/// A force/location correction retracts hits from the replaced suffix, not the
/// accepted prefix. Live paint and the final action use this same selection.
public struct InkElementContact {
  private let targets: [InkElementTarget]
  private let origin: WorldPoint?
  private let index: InkBoundsIndex
  private let homogeneous: Bool
  private var firstHits: [Int: Int] = [:]
  private(set) var testedSegments = 0
  private(set) var visitedNodes = 0
  public var selected: [InkElementTarget] { firstHits.keys.sorted().map { targets[$0] } }

  public init(_ targets: [InkElementTarget]) {
    self.targets = targets
    let origin = targets.first?.worldOrigin
    self.origin = origin
    homogeneous = targets.allSatisfy { ($0.worldOrigin == nil) == (origin == nil) }
    index = InkBoundsIndex(targets.map { target in
      let delta = origin.flatMap { base in target.worldOrigin.map { base.delta(to: $0) } } ?? .zero
      return CGRect(x: target.frame.x + delta.x, y: target.frame.y + delta.y,
        width: target.frame.width, height: target.frame.height)
    })
  }

  public mutating func update(_ source: InkSampleRelations.Contact, from changedIndex: Int) {
    precondition((0...source.count).contains(changedIndex))
    guard !targets.isEmpty else { return }
    firstHits = firstHits.filter { $0.value < changedIndex }
    var previous = changedIndex > 0 ? source.sample(at: changedIndex - 1) : nil
    var position = changedIndex
    source.forEach(in: changedIndex..<source.count) { sample in
      let first = previous ?? sample
      let compatible = homogeneous && (origin == nil || (first.worldPoint != nil && sample.worldPoint != nil))
      let candidates: [Int]
      if compatible {
        func point(_ s: SpatialInkSample) -> SpatialPoint {
          origin.flatMap { o in s.worldPoint.map { o.delta(to: $0) } } ?? s.point
        }
        let a = point(first), b = point(sample), radius = max(first.width, sample.width) / 2
        // Index coordinates can cross tile origins. Expand broad-phase bounds
        // by their floating-point uncertainty; exact tests still use localPoint.
        let guardBand = max(abs(a.x), abs(a.y), abs(b.x), abs(b.y), index.bounds.width, index.bounds.height).ulp * 8
        let box = CGRect(x: min(a.x,b.x)-radius-guardBand, y: min(a.y,b.y)-radius-guardBand,
          width: abs(a.x-b.x)+2*(radius+guardBand), height: abs(a.y-b.y)+2*(radius+guardBand))
        let query = index.query(box)
        visitedNodes += query.visitedNodes
        candidates = query.indices
      } else { candidates = Array(targets.indices) }
      for id in candidates where firstHits[id] == nil {
        testedSegments += 1
        if targets[id].intersects([first, sample]) { firstHits[id] = position }
      }
      previous = sample
      position += 1
    }
  }
}

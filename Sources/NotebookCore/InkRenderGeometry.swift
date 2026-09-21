import CoreGraphics
import Foundation
import simd

/// Display-only records. Measured samples remain the authoritative durable data.
/// One stroke color is supplied separately; topology is implicit in array order.
public enum InkRenderGeometry {
  public struct Node: Equatable, Sendable {
    public var position: SIMD2<Float>
    public var edge: SIMD2<Float>
    public var radius: Float
    public var alpha: Float
    public init(position: SIMD2<Float>, edge: SIMD2<Float>, radius: Float, alpha: Float) {
      self.position = position
      self.edge = edge
      self.radius = radius
      self.alpha = alpha
    }
  }
  public struct Level: Sendable {
    public let error: Float
    public let minimumRadius: Float
    public let indices: [UInt16]
  }
  public static let maximumSegments = 256
  public static let pixelError: Float = 0.20
  public static func node(at i: Int, in points: [InkStrokeGeometry.RenderPoint]) -> Node {
    let p = points[i]
    return .init(
      position: p.position, edge: InkStrokeGeometry.crossSectionOffset(at: i, in: points),
      radius: p.radius, alpha: p.premultipliedColor.w)
  }
  public static func vertexCount(nodes: Int, flags: UInt32) -> Int {
    guard nodes > 0 else { return 0 }
    if flags & 8 != 0 { return nodes }  // canonical, unstructured freehand triangles
    if nodes == 1 { return 72 }
    if flags & 4 != 0 { return (flags & 1 != 0 ? 72 : 0) + (nodes - 1) * 78 }
    return (nodes - 1) * 6 + (flags & 1 != 0 ? 36 : 0) + (flags & 2 != 0 ? 36 : 0)
  }
  /// Bounds enclose strip edges AND round disks/caps, not just sample centers.
  public static func bounds(_ nodes: ArraySlice<Node>) -> CGRect {
    var lo = SIMD2<Float>(repeating: .infinity)
    var hi = SIMD2<Float>(repeating: -.infinity)
    for n in nodes {
      let d = simd_max(simd_abs(n.edge), SIMD2(repeating: n.radius))
      lo = simd_min(lo, n.position - d)
      hi = simd_max(hi, n.position + d)
    }
    guard lo.x.isFinite else { return .null }
    return .init(
      x: Double(lo.x), y: Double(lo.y), width: Double(hi.x - lo.x), height: Double(hi.y - lo.y))
  }
  /// Simplify the two actual contour rails, not just the center line. Reversal,
  /// shape/orientation changes and non-linear alpha force retained samples.
  /// Keep the first/last neighbour for exact round-cap tangents.
  public static func levels(_ source: ArraySlice<Node>, flags: UInt32) -> [Level] {
    guard source.count > 6, flags & 12 == 0 else { return [] }
    let a = Array(source)
    let last = a.count - 1
    let minimumRadius = a.reduce(Float.infinity) { min($0,$1.radius) }
    var result: [Level] = []
    var previous = a.count
    for tolerance: Float in [0.125, 0.5, 2, 8, 32] {
      var keep = Set([0, 1, last - 1, last])
      var pending = [(1, last - 1)]
      while let (start, end) = pending.popLast() {
        guard end > start + 1 else { continue }
        let p = a[start]
        let q = a[end]
        let chord = q.position - p.position
        let length = simd_length_squared(chord)
        var needsSplit = false
        var previousT: Float = 0
        for i in (start + 1)..<end {
          let raw = length > 1e-10 ? simd_dot(a[i].position - p.position, chord) / length : 0
          let t = min(1, max(0, raw))
          // Alpha and winding can reject the interval without evaluating
          // its more expensive contour distances.
          let alpha = abs(a[i].alpha - (p.alpha + (q.alpha - p.alpha) * t)) * 4096
          if alpha > 1 || raw < previousT || raw < 0 || raw > 1 || length <= 1e-10 {
            needsSplit = true;break
          }
          previousT = raw
          let center = p.position + (q.position - p.position) * t
          let edge = p.edge + (q.edge - p.edge) * t
          let rail = max(
            simd_length(a[i].position + a[i].edge - center - edge),
            simd_length(a[i].position - a[i].edge - center + edge))
          if rail / tolerance > 1 { needsSplit = true;break }
        }
        if needsSplit {
          // Reject at the first counterexample, then bisect the interval.
          // Searching for the farthest violation can repeatedly peel off one
          // sample and rescan the same prefix: quadratic work on noisy ink.
          // Balanced children bound depth; every accepted interval still pays
          // the same complete contour/alpha/fold proof above.
          let split = start + (end - start) / 2
          keep.insert(split)
          pending.append((start, split))
          pending.append((split, end))
        }
      }
      let ids = keep.sorted().map(UInt16.init)
      if ids.count < previous {
        result.append(.init(error: tolerance, minimumRadius: minimumRadius, indices: ids))
        previous = ids.count
      }
    }
    return result
  }
  public static func level(_ levels: [Level], pixelsPerUnit: Float, minimumPixelsPerUnit: Float) -> Int {
    // A subpixel contour displacement can change coverage of an entire thin
    // stroke at MSAA sample positions. Geometric proximity alone is not an
    // alpha proof: retain the original rails below one physical pixel.
    // Use the least stretch, not the largest, under shear/anisotropic scale.
    guard minimumPixelsPerUnit.isFinite, minimumPixelsPerUnit > 0 else { return -1 }
    return levels.lastIndex {
      $0.error * abs(pixelsPerUnit) <= pixelError && 2 * $0.minimumRadius * minimumPixelsPerUnit >= 1
    } ?? -1
  }
}

import CoreGraphics
import Foundation
import simd

/// A whole changes 32 bytes, never its immutable sample or display-node arrays.
public struct InkAffine: Sendable {
  public var x: SIMD4<Float>
  public var y: SIMD4<Float>
  public init(_ scaleAndTranslation: SIMD4<Float> = .init(1, 1, 0, 0)) {
    x = .init(scaleAndTranslation.x, 0, scaleAndTranslation.z, 0)
    y = .init(0, scaleAndTranslation.y, scaleAndTranslation.w, 0)
  }
  public init(x: SIMD4<Float>, y: SIMD4<Float>) {
    self.x = x
    self.y = y
  }
  /// Largest singular value; column lengths alone understate shear magnification.
  public var maximumStretch: Float {
    let a = x.x * x.x + y.x * y.x
    let b = x.x * x.y + y.x * y.y
    let d = x.y * x.y + y.y * y.y
    return sqrt(max(0, (a + d + sqrt((a - d) * (a - d) + 4 * b * b)) / 2))
  }
  /// Least singular value, rounded down. Double products preserve the exact
  /// Float matrix's determinant without Float overflow or cancellation.
  public var minimumStretch: Float {
    let a=Double(x.x),b=Double(y.x),c=Double(x.y),d=Double(y.y)
    guard a.isFinite,b.isFinite,c.isFinite,d.isFinite else { return 0 }
    let maximum=(hypot(a+d,b-c)+hypot(a-d,b+c))/2
    return maximum > 0 ? max(0,Float(abs(a*d-b*c)/maximum).nextDown) : 0
  }
  public func bounds(_ rect: CGRect) -> CGRect {
    var lo = SIMD2<Float>(repeating: .infinity)
    var hi = SIMD2<Float>(repeating: -.infinity)
    for p in [
      SIMD2<Float>(Float(rect.minX), Float(rect.minY)), .init(Float(rect.maxX), Float(rect.minY)),
      .init(Float(rect.minX), Float(rect.maxY)), .init(Float(rect.maxX), Float(rect.maxY)),
    ] {
      let q = SIMD2<Float>(x.x * p.x + x.y * p.y + x.z, y.x * p.x + y.y * p.y + y.z)
      lo = simd_min(lo, q)
      hi = simd_max(hi, q)
    }
    return .init(
      x: Double(lo.x), y: Double(lo.y), width: Double(hi.x - lo.x), height: Double(hi.y - lo.y))
  }
}

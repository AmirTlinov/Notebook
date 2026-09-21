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
  /// Collinear source rails remain screen-axis rails. With mixed axes, Float
  /// projection and MSAA edge setup can distinguish different subdivisions.
  public var preservesAxisAlignment: Bool {
    (x.y == 0 && y.x == 0) || (x.x == 0 && y.y == 0)
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

/// Display-only admission against the actual raster sample lattice. Vector
/// editing never supplies this grid. Uncertain/near-edge bounds stay visible.
public struct InkRasterGrid: Sendable {
  private let positions: [SIMD2<Float>]
  private let pixelsPerPoint: SIMD2<Double>
  private let viewport: SIMD2<Double>
  public init?(positions: [SIMD2<Float>], viewport: CGSize, pixels: CGSize) {
    let w=Double(max(Float(viewport.width),1)),h=Double(max(Float(viewport.height),1))
    guard viewport.width > 0,viewport.height > 0,!positions.isEmpty,positions.allSatisfy({ $0.x >= 0 && $0.x < 1 && $0.y >= 0 && $0.y < 1 }),
      w.isFinite,h.isFinite,pixels.width.isFinite,pixels.height.isFinite,pixels.width > 0,pixels.height > 0 else { return nil }
    self.positions=positions;self.viewport = .init(w,h)
    pixelsPerPoint = .init(Double(pixels.width)/w,Double(pixels.height)/h)
  }
  public func mayCover(_ rect: CGRect, affine: InkAffine) -> Bool {
    if rect.isNull { return false }
    // The common large-footprint case contains a whole period of every sample
    // lattice. Avoid interval arithmetic for already resolved detail.
    let width=(abs(Double(affine.x.x))*rect.width+abs(Double(affine.x.y))*rect.height)*pixelsPerPoint.x
    let height=(abs(Double(affine.y.x))*rect.width+abs(Double(affine.y.y))*rect.height)*pixelsPerPoint.y
    if width >= 1 && height >= 1 { return true }
    guard rect.minX.isFinite,rect.minY.isFinite,rect.maxX.isFinite,rect.maxY.isFinite else { return true }
    // Outward Float conversion bounds the shader's local coordinates. The
    // arithmetic budget uses magnitudes BEFORE cancellation by translation.
    let lo=SIMD2<Double>(Double(Float(rect.minX).nextDown),Double(Float(rect.minY).nextDown))
    let hi=SIMD2<Double>(Double(Float(rect.maxX).nextUp),Double(Float(rect.maxY).nextUp))
    func interval(_ row: SIMD4<Float>,_ axis: Int) -> (Double,Double) {
      let a=Double(row.x),b=Double(row.y),t=Double(row.z)
      let left=min(a*lo.x,a*hi.x)+min(b*lo.y,b*hi.y)+t
      let right=max(a*lo.x,a*hi.x)+max(b*lo.y,b*hi.y)+t
      let magnitude=abs(a)*max(abs(lo.x),abs(hi.x))+abs(b)*max(abs(lo.y),abs(hi.y))+abs(t)
      // Includes local vertex/affine arithmetic and the shader's division and
      // clip-to-viewport conversion. A separate 1/16 pixel guard excludes ties
      // and nearby raster setup; it is not an alpha approximation allowance.
      let error=16*Double(Float.ulpOfOne)*(magnitude+viewport[axis])
      let padding=error*pixelsPerPoint[axis]+1.0/16
      return (left*pixelsPerPoint[axis]-padding,right*pixelsPerPoint[axis]+padding)
    }
    let x=interval(affine.x,0),y=interval(affine.y,1)
    guard x.0.isFinite,x.1.isFinite,y.0.isFinite,y.1.isFinite else { return true }
    if x.1-x.0 >= 1 && y.1-y.0 >= 1 { return true }
    return positions.contains { p in
      ceil(x.0-Double(p.x)) <= floor(x.1-Double(p.x)) &&
      ceil(y.0-Double(p.y)) <= floor(y.1-Double(p.y))
    }
  }
}

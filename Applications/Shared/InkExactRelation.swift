import Foundation

/// The exact numeric domain for ink relations, not an alternate Float evaluator.
/// A normalized signed coefficient has at most 53 bits; exponent is -1074...1023.
/// Unsupported composition leaves its operands intact. It never rounds content.
struct InkDyadic: Equatable, Sendable {
  let coefficient: Int64
  let exponent: Int
  static let zero = InkDyadic(coefficient: 0, exponent: 0)!
  static let one = InkDyadic(coefficient: 1, exponent: 0)!

  init?(coefficient: Int64, exponent: Int) {
    guard coefficient != .min else { return nil }
    if coefficient == 0 { self.coefficient = 0; self.exponent = 0; return }
    let shift = coefficient.magnitude.trailingZeroBitCount
    let c = coefficient / (Int64(1) << shift)
    let (e, overflow) = exponent.addingReportingOverflow(shift)
    guard !overflow, c.magnitude <= (1 << 53) - 1, (-1074...1023).contains(e) else { return nil }
    let value = Double(sign: c < 0 ? .minus : .plus, exponent: e, significand: Double(c.magnitude))
    guard value.isFinite, value != 0 else { return nil }
    self.coefficient = c; self.exponent = e
  }

  init?(_ value: Double) {
    guard value.isFinite, value.bitPattern != 0x8000_0000_0000_0000 else { return nil }
    let bits = value.bitPattern, e = Int((bits >> 52) & 0x7ff)
    let mantissa = (bits & 0x000f_ffff_ffff_ffff) | (e == 0 ? 0 : 1 << 52)
    self.init(coefficient: value.sign == .minus ? -Int64(mantissa) : Int64(mantissa),
      exponent: e == 0 ? -1074 : e - 1023 - 52)
  }
  var value: Double {
    Double(sign: coefficient < 0 ? .minus : .plus, exponent: exponent, significand: Double(coefficient.magnitude))
  }
  var negated: Self { Self(coefficient: -coefficient, exponent: exponent)! }

  func adding(_ other: Self) -> Self? {
    if coefficient == 0 { return other }; if other.coefficient == 0 { return self }
    let e = min(exponent, other.exponent)
    func shifted(_ x: Self) -> Int64? {
      let shift = x.exponent - e
      guard shift < 63 else { return nil }
      let (c, overflow) = x.coefficient.multipliedReportingOverflow(by: Int64(1) << shift)
      return overflow ? nil : c
    }
    guard let a = shifted(self), let b = shifted(other) else { return nil }
    let (c, overflow) = a.addingReportingOverflow(b)
    return overflow ? nil : Self(coefficient: c, exponent: e)
  }
  func multiplied(by other: Self) -> Self? {
    let (c, overflow) = coefficient.multipliedReportingOverflow(by: other.coefficient)
    return overflow ? nil : Self(coefficient: c, exponent: exponent + other.exponent)
  }
  func multiplied(by count: Int) -> Self? {
    guard let n = Int64(exactly: count) else { return nil }
    let (c, overflow) = coefficient.multipliedReportingOverflow(by: n)
    return overflow ? nil : Self(coefficient: c, exponent: exponent)
  }
}

enum InkRelationEquality: Equatable { case equal, different, notProven }

/// Typed affine relation in paper points. Composition is inner, then outer.
/// Observable samples remain outside this value; inverse transitions may only
/// cancel when adjacent, with no emitted sample/contact/paint barrier in between.
struct InkExactFrame: Equatable, Sendable {
  let a: InkDyadic, b: InkDyadic, c: InkDyadic, d: InkDyadic, x: InkDyadic, y: InkDyadic
  static let identity = InkExactFrame(a: .one, b: .zero, c: .zero, d: .one, x: .zero, y: .zero)
  func composed(after inner: Self) -> Self? {
    func sum(_ a: InkDyadic, _ b: InkDyadic, _ c: InkDyadic, _ d: InkDyadic,
      offset: InkDyadic = .zero) -> InkDyadic? {
      guard let p = a.multiplied(by: b), let q = c.multiplied(by: d), let s = p.adding(q) else { return nil }
      return s.adding(offset)
    }
    guard let aa = sum(a,inner.a,c,inner.b), let bb = sum(b,inner.a,d,inner.b),
      let cc = sum(a,inner.c,c,inner.d), let dd = sum(b,inner.c,d,inner.d),
      let xx = sum(a,inner.x,c,inner.y,offset:x), let yy = sum(b,inner.x,d,inner.y,offset:y) else { return nil }
    return .init(a:aa,b:bb,c:cc,d:dd,x:xx,y:yy)
  }
}

import Foundation

typealias Point = InkStrokeGeometry.RenderPoint
typealias Vertex = InkStrokeGeometry.Vertex

enum Encoding: String, CaseIterable {
  case current, float32, absolute4, relative4, absolute8, relative8, absolute12, relative12
  var bits: Int {
    switch self {
    case .absolute4, .relative4: 4
    case .absolute8, .relative8: 8
    case .absolute12, .relative12: 12
    default: 0
    }
  }
  var relative: Bool { self == .relative4 || self == .relative8 || self == .relative12 }
}

// Test-only hypothesis: at level k, 0 contracts by 2^(-2^-k),
// 1 expands by 2^(2^-k). Bit order is coarse-to-fine; this is not a
// claim that these operators follow from the user's relation model.
// Code 0 is an explicit absolute escape. A 64-point restart bounds replay.
struct PackedStroke {
  struct Restart { let radius: Float; let escapeOffset: UInt32 }
  static let blockSize = 64
  let encoding: Encoding
  var original: [Point] = []
  var positions: [SIMD2<Float>] = []
  var colors: [SIMD4<Float>] = []
  var radii: [Float] = []
  var codes: [UInt8] = []
  var restarts: [Restart] = []
  var escapes: [Float] = []
  var lower: Float = 0
  var upper: Float = 0

  // Shared per-encoding table, charged once in the report, not once per stroke.
  static let factors: [Int: [Float]] = Dictionary(uniqueKeysWithValues: [4, 8, 12].map { bits in
    let levels = 1 << bits
    return (bits, (0..<levels).map { exp2(Float(2 * $0 - (levels - 1)) / Float(levels / 2)) })
  })

  init(_ points: [Point], encoding: Encoding) {
    self.encoding = encoding
    if encoding == .current { original = points; return }
    positions = points.map(\.position)
    colors = points.map(\.premultipliedColor)
    if encoding == .float32 { radii = points.map(\.radius); return }
    let bits = encoding.bits, levels = 1 << bits
    codes = [UInt8](repeating: 0, count: (points.count * bits + 7) / 8)
    if encoding.relative {
      let factors = Self.factors[bits]!
      var previous: Float = 1
      for (index, point) in points.enumerated() {
        precondition(point.radius.isFinite && point.radius > 0)
        if index.isMultiple(of: Self.blockSize) {
          restarts.append(.init(radius: point.radius, escapeOffset: UInt32(escapes.count)))
          previous = point.radius
          continue
        }
        // Feed back the reconstructed value: no accumulation of quantization error.
        let value = log2(point.radius / previous) * Float(levels / 4) + Float(levels - 1) / 2
        if value < 0.5 || value >= Float(levels) - 0.5 {
          escapes.append(point.radius)
          previous = point.radius
        } else {
          let code = Int(value.rounded())
          write(code, at: index)
          previous *= factors[code]
        }
      }
    } else {
      lower = points.map(\.radius).min() ?? 0
      upper = points.map(\.radius).max() ?? 0
      let scale = upper > lower ? Float(levels - 1) / (upper - lower) : 0
      for (index, point) in points.enumerated() {
        write(min(levels - 1, max(0, Int(((point.radius - lower) * scale).rounded()))), at: index)
      }
    }
  }

  private mutating func write(_ code: Int, at index: Int) {
    let offset = index * encoding.bits, byte = offset >> 3, shift = offset & 7
    let word = code << shift
    codes[byte] |= UInt8(truncatingIfNeeded: word)
    if shift + encoding.bits > 8 { codes[byte + 1] |= UInt8(truncatingIfNeeded: word >> 8) }
  }

  func code(at index: Int) -> Int {
    let offset = index * encoding.bits, byte = offset >> 3, shift = offset & 7
    var word = Int(codes[byte])
    if shift + encoding.bits > 8 { word |= Int(codes[byte + 1]) << 8 }
    return (word >> shift) & ((1 << encoding.bits) - 1)
  }

  func decode() -> [Point] {
    if encoding == .current { return original }
    var result: [Point] = []
    result.reserveCapacity(positions.count)
    func append(_ index: Int, _ radius: Float) {
      result.append(.init(position: positions[index], radius: radius, premultipliedColor: colors[index]))
    }
    if encoding == .float32 {
      for i in positions.indices { append(i, radii[i]) }
    } else if encoding.relative {
      let factors = Self.factors[encoding.bits]!
      var previous: Float = 1, escape = 0
      for i in positions.indices {
        if i.isMultiple(of: Self.blockSize) {
          let restart = restarts[i / Self.blockSize]
          previous = restart.radius; escape = Int(restart.escapeOffset)
        } else {
          let c = code(at: i)
          if c == 0 { previous = escapes[escape]; escape += 1 }
          else { previous *= factors[c] }
        }
        append(i, previous)
      }
    } else {
      let step = (upper - lower) / Float((1 << encoding.bits) - 1)
      for i in positions.indices { append(i, lower + Float(code(at: i)) * step) }
    }
    return result
  }

  // Count used payload bytes, not Array capacity, allocator overhead, RSS, or archive size.
  var radiusBytes: Int {
    if encoding == .current { return original.count * MemoryLayout<Float>.stride }
    return radii.count * 4 + codes.count + restarts.count * MemoryLayout<Restart>.stride
      + escapes.count * 4 + (encoding.relative || encoding == .float32 ? 0 : 8)
  }
  var bytes: Int {
    if encoding == .current { return original.count * MemoryLayout<Point>.stride }
    return positions.count * MemoryLayout<SIMD2<Float>>.stride
      + colors.count * MemoryLayout<SIMD4<Float>>.stride + radiusBytes
  }
}

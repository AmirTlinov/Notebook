import CoreGraphics
import Foundation
import simd

struct InkPrimitive {
  var count: UInt32
  var flags: UInt32
  var reserved = SIMD2<UInt32>(repeating: 0)
  var color: SIMD4<Float>
}

import CoreGraphics
import Foundation
import Testing
@testable import NotebookCore

/// An eraser can revisit the same small area for several seconds. Addressed
/// reads and scene picking must not feed an unbounded duplicate triangle soup
/// into a synchronous boolean operation. This is synthetic, not a device trace.
@Suite(.serialized)
struct NotebookAppearanceComplexityTests {
  @Test(arguments: [256, 1024, 2048])
  func denseRepeatedErasureKeepsBothItsMeaningAndABoundedProjection(_ count: Int) {
    let frame = PageRect(x: 0, y: 0, width: 160, height: 100)
    let samples = (0..<count).map { i in
      let angle = Double(i % 32) * 2 * Double.pi / 32
      return SpatialInkSample(point: .init(x: 2 * cos(angle), y: 50 + 40 * sin(angle)),
        timeOffset: Double(i) / 240, width: 20, opacity: 1, force: 1, azimuth: 0, altitude: 1)
    }
    let cut = InkElementErasure(target: .init(elementID: "box", frame: frame), samples: samples)
    FileHandle.standardOutput.write(Data("APPEARANCE_COMPLEXITY_BEGIN samples=\(count)\n".utf8))
    let start = ContinuousClock.now
    let result = NotebookElementAppearance(graphic: .init(shape: .rectangle, style: .init(strokeWidth: 4)),
      layout: nil, size: .init(width: 160, height: 100), erasures: [cut])
    let elapsed = start.duration(to: .now)
    FileHandle.standardOutput.write(Data("APPEARANCE_COMPLEXITY_END samples=\(count) elapsed=\(elapsed)\n".utf8))
    #expect(result.state == .partial)
    #expect(!result.contains(.init(x: 0, y: 50), tolerance: 6))
    #expect(result.contains(.init(x: 160, y: 50), tolerance: 6))
    #expect(elapsed < .seconds(1), "One small addressed target must not approach the ten-second scene watchdog")
  }
}

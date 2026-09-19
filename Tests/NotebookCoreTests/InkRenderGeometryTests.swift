import Foundation
import Testing
import simd

@testable import NotebookCore

@Suite("Compact display geometry")
struct InkRenderGeometryTests {
  private func nodes(
    _ count: Int, _ edit: (Int, inout InkRenderGeometry.Node) -> Void = { _, _ in }
  ) -> [InkRenderGeometry.Node] {
    (0..<count).map { i in
      var n = InkRenderGeometry.Node(
        position: .init(Float(i), 0), edge: .init(0, 2), radius: 2, alpha: 0.4)
      edit(i, &n)
      return n
    }
  }
  @Test func storesTwentyFourBytesAndUsesImplicitTopology() {
    #expect(MemoryLayout<InkRenderGeometry.Node>.stride == 24)
    #expect(InkRenderGeometry.vertexCount(nodes: 1, flags: 3) == 72)
    #expect(InkRenderGeometry.vertexCount(nodes: 10, flags: 3) == 9 * 6 + 72)
    #expect(InkRenderGeometry.vertexCount(nodes: 10, flags: 7) == 9 * 78 + 72)
  }
  @Test func distantStraightInkSimplifiesWithoutDiscardingSource() {
    let source = nodes(257)
    let before = source
    let levels = InkRenderGeometry.levels(source[...], flags: 3)
    #expect(levels.first?.indices == [0, 1, 255, 256])
    #expect(InkRenderGeometry.level(levels, pixelsPerUnit: 1) == 0)
    #expect(InkRenderGeometry.level(levels, pixelsPerUnit: 100) == -1)
    #expect(source == before)
  }
  @Test func curvatureThicknessOrientationAlphaAndFoldCannotDisappear() {
    for feature in 0..<5 {
      let source = nodes(65) { i, n in
        guard i == 32 else { return }
        switch feature {
        case 0: n.position.y = 5
        case 1:
          n.edge.y = 7
          n.radius = 7
        case 2: n.edge = .init(2, 0)
        case 3: n.alpha = 0.9
        default: n.position.x = 5
        }
      }
      let levels = InkRenderGeometry.levels(source[...], flags: 3)
      #expect(levels.first?.indices.contains(32) == true)
    }
  }
  @Test func selectedRailsStayWithinScreenErrorAndEraserRemainsExact() {
    let source = nodes(257) { i, n in
      let t = Float(i) / 20
      n.position.y = sin(t) * 4
      n.edge = .init(sin(t) * 0.4, 2 + cos(t) * 0.3)
      n.alpha = 0.4 + Float(i) / 1024
    }
    for level in InkRenderGeometry.levels(source[...], flags: 3) {
      for (left, right) in zip(level.indices, level.indices.dropFirst()) {
        let a = source[Int(left)]
        let b = source[Int(right)]
        let chord = b.position - a.position
        let den = simd_length_squared(chord)
        for i in Int(left)...Int(right) {
          let t = simd_dot(source[i].position - a.position, chord) / den
          let center = a.position + (b.position - a.position) * t
          let edge = a.edge + (b.edge - a.edge) * t
          #expect(
            simd_length(source[i].position + source[i].edge - center - edge) <= level.error + 0.0001
          )
          #expect(
            simd_length(source[i].position - source[i].edge - center + edge) <= level.error + 0.0001
          )
          #expect(abs(source[i].alpha - (a.alpha + (b.alpha - a.alpha) * t)) <= 1 / 4096 + 0.000001)
        }
      }
    }
    #expect(InkRenderGeometry.levels(source[...], flags: 7).isEmpty)
  }
}

import Foundation
import Testing
import simd

@testable import NotebookCore

@Suite("Compact display geometry")
struct InkRenderGeometryTests {
  @Test func rasterAdmissionKeepsTiesNegativeCoordinatesAndUncertainProjection() throws {
    let grid=try #require(InkRasterGrid(positions:[.init(0.5,0.5)],viewport:.init(width:100,height:100),pixels:.init(width:100,height:100)))
    #expect(!grid.mayCover(.init(x:0,y:0,width:0.1,height:0.1),affine:.init()))
    #expect(grid.mayCover(.init(x:0.5,y:0.5,width:0,height:0),affine:.init()))
    #expect(grid.mayCover(.init(x:-0.5,y:-0.5,width:0,height:0),affine:.init()))
    #expect(!grid.mayCover(.init(x:-1,y:-1,width:0.1,height:0.1),affine:.init()))
    #expect(grid.mayCover(.init(x:0.44,y:0.44,width:0,height:0),affine:.init()),"Near-edge guard stays conservative")
    #expect(grid.mayCover(.infinite,affine:.init()))
    #expect(grid.mayCover(.init(x:1e8,y:1e8,width:0.1,height:0.1),affine:.init(.init(1,1,-1e8,-1e8))),"Error before cancellation must not vanish")
    #expect(grid.mayCover(.init(x:0,y:0,width:1,height:1),affine:.init(x:.init(.nan,0,0,0),y:.init(0,1,0,0))))
    #expect(InkRasterGrid(positions:[],viewport:.init(width:100,height:100),pixels:.init(width:100,height:100)) == nil)
  }
  @Test func rasterAdmissionUsesActualRoundedPixelDimensionsAndFloatViewport() throws {
    let size=CGSize(width:100.2,height:80.3),pixels=CGSize(width:126,height:101)
    let grid=try #require(InkRasterGrid(positions:[.init(0.5,0.5)],viewport:size,pixels:pixels))
    for i in [-10,0,30,90] {
      let point=CGRect(x:(Double(i)+0.5)*Double(Float(size.width))/pixels.width,
        y:20.5*Double(Float(size.height))/pixels.height,width:0,height:0)
      #expect(grid.mayCover(point,affine:.init()))
    }
    let reflected=InkAffine(x:.init(0,-1,0,0),y:.init(-1,0,0,0))
    #expect(grid.mayCover(.init(x:-20.5*Double(Float(size.height))/pixels.height,
      y:-30.5*Double(Float(size.width))/pixels.width,width:0,height:0),affine:reflected))
  }
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
    #expect(InkRenderGeometry.level(levels, pixelsPerUnit: 1, minimumPixelsPerUnit: 1) == 0)
    #expect(InkRenderGeometry.level(levels, pixelsPerUnit: 100, minimumPixelsPerUnit: 100) == -1)
    #expect(source == before)
  }
  @Test func subpixelCoverageUsesTheLeastProjectedWidth() {
    let source=nodes(257) { i,n in n.position.y=sin(Float(i)/40)*0.2 }
    let levels=InkRenderGeometry.levels(source[...],flags:3)
    #expect(!levels.isEmpty)
    #expect(levels.allSatisfy { $0.minimumRadius == 2 })
    #expect(InkRenderGeometry.level(levels,pixelsPerUnit:0.001,minimumPixelsPerUnit:0.001) == -1)
    #expect(InkRenderGeometry.level(levels,pixelsPerUnit:0.4,minimumPixelsPerUnit:0.001) == -1)
    #expect(InkRenderGeometry.level(levels,pixelsPerUnit:0.4,minimumPixelsPerUnit:0.4) >= 0)
    #expect(InkRenderGeometry.level(levels,pixelsPerUnit:0.4,minimumPixelsPerUnit:0) == -1)
    let stretch=InkAffine(.init(-4,0.125,0,0))
    #expect(abs(stretch.maximumStretch-4)<1e-6)
    #expect(abs(stretch.minimumStretch-0.125)<1e-6)
    let shear=InkAffine(x:.init(1,100,0,0),y:.init(0,1,0,0))
    #expect(abs(shear.minimumStretch*shear.maximumStretch-1)<1e-5)
    #expect(InkAffine(.init(0,1,0,0)).minimumStretch == 0)
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
  @Test(arguments:[false,true]) func selectedRailsStayWithinScreenErrorAndEraserRemainsExact(irregular: Bool) {
    let source = nodes(257) { i, n in
      let t = Float(i) / 20
      n.position.y = sin(t) * 4
      n.edge = .init(sin(t) * 0.4, 2 + cos(t) * 0.3)
      n.alpha = irregular ? 0.25 + Float(i % 7) / 16 : 0.4 + Float(i) / 1024
      if irregular { n.position.y=sin(Float(i)*0.37)*12;n.edge.y=2+Float(i%13)/8 }
    }
    let levels=InkRenderGeometry.levels(source[...], flags: 3)
    #expect(!levels.isEmpty)
    for level in levels {
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

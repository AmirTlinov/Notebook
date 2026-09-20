import CoreGraphics
import Foundation
import Testing
@testable import NotebookCore

@Suite("Indexed vector ink source")
struct VectorInkSourceTests {
  private func grid(_ count: Int = 20_000) -> NotebookFreehand {
    let vertices = (0..<count).flatMap { i -> [NotebookFreehand.Vertex] in
      let x = Double(i%200)/200, y = Double(i/200)/100
      return [.init(x:x,y:y,opacity:1),.init(x:x+0.004,y:y,opacity:1),.init(x:x,y:y+0.008,opacity:1)]
    }
    return .init(layers:[.init(color:.black,vertices:vertices)])
  }
  @Test func localizedQueriesSkipMostSourceAndWholeEditsShareIt() throws {
    let ink = grid(), geometry = ink.geometry
    let hits = geometry.index.query(.init(x:0.499,y:0.499,width:0.006,height:0.009))
    let touched = hits.indices.reduce(0) { $0+geometry.chunks[$1].range.count }
    #expect(touched < geometry.sourceNodeCount/20)
    #expect(hits.visitedNodes < geometry.chunks.count/4)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let original = try encoder.encode(ink)
    var graphic = NotebookGraphic(shape:.freehand,freehand:ink)
    for _ in 0..<100 {
      graphic = try graphic.applying(.object(["transform":try JSONValue.encode(NotebookGraphicTransform(a:0,b:1,c:-1,d:0,tx:1,ty:0))]))
      #expect(graphic.freehand!.geometry === geometry)
    }
    #expect(try encoder.encode(graphic.freehand!) == original)
    #expect(try JSONDecoder().decode(NotebookFreehand.self,from:original) == ink)
    #expect(!String(decoding:original,as:UTF8.self).contains("preparation"))
  }
  @Test func vectorSelectionDoesNotLoseSubpixelSliversOrSelectErasedPaint() {
    let size = CGSize(width:1,height:1)
    let pen = NotebookFreehand.Layer(color:.black,vertices:[.init(x:0.1,y:0.5,opacity:1),
      .init(x:0.9,y:0.5,opacity:1),.init(x:0.5,y:0.50001,opacity:1)])
    let polygon = [CGPoint(x:0,y:0),.init(x:1,y:0),.init(x:1,y:1),.init(x:0,y:1)]
    #expect(NotebookFreehand(layers:[pen]).geometry.intersects(polygon))
    let cut = NotebookFreehand.Layer(eraser:.init(size:.init(x:1,y:1),samples:[.init(point:.init(x:0.5,y:0.5),width:2)]))
    let erased = NotebookFreehand(layers:[pen,cut])
    #expect(!erased.geometry.intersects(polygon))
    #expect(!erased.contains(.init(x:0.5,y:0.500001),size:size,transform:nil))
    #expect(NotebookFreehand(layers:[pen,cut,pen]).geometry.intersects(polygon))
  }
  @Test func transparentPaintAndPartialEraserRemainVectorSemantics() {
    func layer(_ tool: SpatialInkTool, _ opacity: Double) -> NotebookFreehand.Layer {
      .init(tool:tool,color:.black,vertices:[.init(x:0,y:0,opacity:opacity),.init(x:1,y:0,opacity:opacity),.init(x:0,y:1,opacity:opacity)])
    }
    let polygon = [CGPoint(x:0.1,y:0.1),.init(x:0.2,y:0.1),.init(x:0.2,y:0.2),.init(x:0.1,y:0.2)]
    #expect(!NotebookFreehand(layers:[layer(.pen,0)]).geometry.intersects(polygon))
    let partial = NotebookFreehand(layers:[layer(.pen,1),layer(.eraser,0.5)])
    #expect(partial.geometry.intersects(polygon))
    #expect(partial.contains(.init(x:0.15,y:0.15),size:.init(width:1,height:1),transform:nil))
    let faint = NotebookFreehand(layers:[layer(.pen,1),layer(.eraser,0.99999999)])
    #expect(faint.contains(.init(x:0.15,y:0.15),size:.init(width:1,height:1),transform:nil))
  }
  @Test func inverseQueryHandlesRotationShearAndAnisotropicSize() {
    let ink = grid(), t = NotebookGraphicTransform(a:0.7,b:0.2,c:0.1,d:0.6,tx:0.1,ty:0.1)
    let size = CGSize(width:700,height:1100), local = SpatialPoint(x:0.501,y:0.502), p = t.applying(local)
    let world = CGPoint(x:p.x*size.width,y:p.y*size.height)
    #expect(ink.contains(world,size:size,transform:t))
    let bounds = NotebookFreehandGeometry.sourceBounds(.init(x:world.x-1,y:world.y-1,width:2,height:2),size:size,transform:t)
    #expect(bounds.contains(.init(x:local.x,y:local.y)))
    #expect(ink.geometry.index.query(bounds).indices.count < 20)
  }
}

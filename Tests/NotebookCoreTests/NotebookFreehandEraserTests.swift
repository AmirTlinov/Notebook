import CoreGraphics
import Foundation
import Testing
@testable import NotebookCore

@Suite("Compact retained eraser sweeps")
struct NotebookFreehandEraserTests {
  @Test func longEraserDoesNotSpendThePaintVertexBudgetAndKeepsExactGeometry() throws {
    let samples = (0..<1624).map { index in
      NotebookFreehand.Eraser.Sample(point:.init(x:Double(index)/4,y:40+sin(Double(index)/30)*20),width:8)
    }
    let eraser = NotebookFreehand.Eraser(size:.init(x:500,y:200),samples:samples)
    let layer = NotebookFreehand.Layer(eraser:eraser)
    let pen = NotebookFreehand.Layer(color:.black,vertices:[.init(x:0,y:0,opacity:0.2),.init(x:1,y:0,opacity:1),.init(x:1,y:1,opacity:1)])
    let ink = NotebookFreehand(layers:[pen,layer])
    #expect(ink.isValid)
    #expect(layer.renderVertices.count > NotebookFreehand.maximumVertices)
    let measured = samples.map { SpatialInkSample(point:$0.point,timeOffset:0,width:$0.width,opacity:1,force:1,azimuth:0,altitude:.pi/2) }
    #expect(layer.renderVertices == NotebookFreehand.mesh(samples:measured,frame:.init(x:0,y:0,width:500,height:200),origin:nil,tool:.eraser))
    let compact = try JSONEncoder().encode(ink)
    #expect(compact.count < 150_000)
    #expect(try JSONDecoder().decode(NotebookFreehand.self,from:compact) == ink)
    #expect(NotebookGraphic(shape:.freehand,freehand:ink).isValid)
  }
  @Test func hitTestingUsesChronologicalCutsAndTransformedGeometry() {
    func pen(_ y: Double) -> NotebookFreehand.Layer {
      let samples = [10.0,90.0].map { SpatialInkSample(point:.init(x:$0,y:y),timeOffset:0,width:8,opacity:1,force:1,azimuth:0,altitude:.pi/2) }
      return .init(color:.black,vertices:NotebookFreehand.mesh(samples:samples,frame:.init(x:0,y:0,width:100,height:100),origin:nil))
    }
    let cut = NotebookFreehand.Layer(eraser:.init(size:.init(x:100,y:100),samples:[.init(point:.init(x:50,y:10),width:20),.init(point:.init(x:50,y:90),width:20)]))
    let ink = NotebookFreehand(layers:[pen(30),cut,pen(70)])
    let size = CGSize(width:100,height:100)
    #expect(ink.contains(.init(x:20,y:30),size:size,transform:nil))
    #expect(!ink.contains(.init(x:50,y:30),size:size,transform:nil,tolerance:12))
    #expect(ink.contains(.init(x:50,y:70),size:size,transform:nil))
    let rotation = NotebookGraphicTransform(a:0,b:1,c:-1,d:0,tx:1,ty:0)
    #expect(!ink.contains(.init(x:70,y:50),size:size,transform:rotation))
    #expect(ink.contains(.init(x:30,y:50),size:size,transform:rotation))
    let path = ink.paintPath(size:size,transform:rotation)
    #expect(!path.contains(.init(x:70,y:50)))
    #expect(path.contains(.init(x:30,y:50)))
  }

  @Test func layerHasExactlyOneGeometryOwner() {
    let invalid = NotebookFreehand.Eraser(size:.init(x:0,y:1),samples:[.init(point:.zero,width:8)])
    let pen = NotebookFreehand.Layer(color:.black,vertices:[.init(x:0,y:0,opacity:1),.init(x:1,y:0,opacity:1),.init(x:1,y:1,opacity:1)])
    #expect(!NotebookFreehand(layers:[pen,.init(eraser:invalid)]).isValid)
    #expect(!NotebookFreehand(layers:[.init(eraser:.init(size:.init(x:1,y:1),samples:[.init(point:.zero,width:8)]))]).isValid)
  }
}

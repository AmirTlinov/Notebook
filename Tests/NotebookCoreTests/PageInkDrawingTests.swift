import Foundation
import Testing

@testable import NotebookCore

@Test func pageInkRoundTripKeepsExactSamplesAndOperationOrder() throws {
  let point = SpatialInkSample(
    point: .init(x: 10, y: 20), timeOffset: 0.2, width: 2.2, opacity: 0.344, force: 0.2,
    azimuth: 0.3, altitude: 1)
  let pen = PageInkAction(tool: .pen, samples: [point])
  let eraser = PageInkAction(tool: .eraser, samples: [point])
  let drawing = PageInkDrawing().appending(pen).appending(eraser)
  #expect(try PageInkDrawing.decode(drawing.dataRepresentation()) == drawing)
  #expect(drawing.actions.map(\.tool) == [.pen, .eraser])
  #expect(drawing.appending(pen) == drawing)
  #expect(try drawing.dataRepresentation().starts(with: Data("NotebookInk/2\n".utf8)))
}

@Test func pageInkAcceptsOnlyTheCurrentFormat() throws {
  #expect(try PageInkDrawing.decode(Data()).isEmpty)
  #expect(throws: PageInkDrawing.InkError.self) { try PageInkDrawing.decode(Data("NotebookInk/1\nold binary archive".utf8)) }
  #expect(throws: PageInkDrawing.InkError.self) { try PageInkDrawing.decode(Data([1, 2, 3])) }
}

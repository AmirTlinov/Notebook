import Foundation
import Testing
@testable import NotebookCore

@Test("Draw-and-hold принимает замкнутые эллипсы при неравномерной скорости, шуме и масштабе", arguments: [0.4, 1.0, 2.0, 4.0])
func quickShapeMeasuredEllipse(scale: Double) {
  let points = (0...180).map { index -> SpatialPoint in
    let a = Double(index) / 180 * 2 * Double.pi
    let jitter = 1 + 0.018 * sin(17 * a)
    return .init(x: 200 + 95 * cos(a) * jitter, y: 200 + 62 * sin(a) * jitter)
  }
  let fit = NotebookQuickShape.ellipse(points + Array(repeating: points.last!, count: 200), screenScale: scale)
  #expect(fit != nil)
  #expect(abs((fit?.frame.width ?? 0) - 190) < 8)
}

@Test("Открытая линия, волна, квадрат с долгой остановкой и соседняя запись не становятся эллипсом")
func quickShapeRejectsNonEllipses() {
  let line = (0...80).map { SpatialPoint(x: Double($0), y: 10) }
  let wave = (0...160).map { SpatialPoint(x: Double($0), y: 20 * sin(Double($0) / 14)) }
  let square = (0...160).map { i -> SpatialPoint in
    switch i {
    case 0..<40: return .init(x: Double(i) * 2, y: 0)
    case 40..<80: return .init(x: 80, y: Double(i - 40) * 2)
    case 80..<120: return .init(x: 80 - Double(i - 80) * 2, y: 80)
    default: return .init(x: 0, y: 80 - Double(i - 120) * 2)
    }
  }
  let circle = (0...80).map { i -> SpatialPoint in
    let a = Double(i) / 80 * 2 * Double.pi
    return .init(x: 60 + 40 * cos(a), y: 60 + 40 * sin(a))
  }
  for points in [line, wave, square + Array(repeating: .init(x: 0, y: 0), count: 2000), line + circle] {
    #expect(NotebookQuickShape.ellipse(points, screenScale: 1) == nil)
  }
}

@Test("Пустая середина контура не заслоняет узлы; подпись остаётся доступной")
func graphicContourHitTesting() {
  let empty = NotebookGraphic()
  #expect(!NotebookGraphicGeometry.hitTest(empty, width: 200, height: 100, x: 100, y: 50, tolerance: 4))
  #expect(NotebookGraphicGeometry.hitTest(empty, width: 200, height: 100, x: 0, y: 50, tolerance: 4))
  var labelled = empty; labelled.label = "+"
  #expect(NotebookGraphicGeometry.hitTest(labelled, width: 200, height: 100, x: 100, y: 50, tolerance: 4))
  labelled.visible = false
  #expect(!NotebookGraphicGeometry.hitTest(labelled, width: 200, height: 100, x: 100, y: 50, tolerance: 4))
}

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

@Test("Измеренная линия и одноштриховая стрелка распознаются в разных масштабах", arguments:[0.4,1.0,2.5])
func quickShapeConnectors(scale: Double) throws {
  for arrow in [false,true] {
    for angle in [0.0,0.7,2.6] {
      let vertices: [SpatialPoint] = arrow
        ? [.init(x:0,y:0),.init(x:200,y:0),.init(x:164,y:-26),.init(x:200,y:0),.init(x:164,y:26)]
        : [.init(x:0,y:0),.init(x:200,y:0)]
      let measured = zip(vertices,vertices.dropFirst()).flatMap { a,b in
        (0..<30).map { i -> SpatialPoint in
          let t = Double(i)/29, x = a.x+(b.x-a.x)*t, y = a.y+(b.y-a.y)*t+sin(Double(i))*0.5
          return .init(x:400+(x*cos(angle)-y*sin(angle))/scale,y:400+(x*sin(angle)+y*cos(angle))/scale)
        }
      }
      let fit = try #require(NotebookQuickShape.recognize(measured,screenScale:scale))
      #expect(fit.shape == .connector)
      #expect(fit.connection?.endArrowhead == (arrow ? NotebookGraphicConnection.Arrowhead.arrow : NotebookGraphicConnection.Arrowhead.none))
      #expect(fit.sampleCount == measured.count)
      #expect(fit.layout?.curves.isEmpty == false)
    }
  }
}

@Test("Удержание волны, буквы V и составной заметки не угадывает стрелку")
func quickShapeConnectorNegatives() {
  let wave = (0...180).map { SpatialPoint(x:Double($0),y:25*sin(Double($0)/12)) }
  let v = (0...180).map { SpatialPoint(x:Double($0),y:abs(Double($0)-90)) }
  let scribble = (0...180).map { SpatialPoint(x:Double($0)+20*sin(Double($0)),y:20*cos(Double($0))) }
  for points in [wave,v,scribble,Array(wave.prefix(5))] {
    #expect(NotebookQuickShape.connector(points,screenScale:1) == nil)
  }
}

// Unevenly sampled sketches exercise geometry rather than an exact vertex order.
private func sketch(_ vertices: [SpatialPoint], scale: Double = 1, angle: Double = 0) -> [SpatialPoint] {
  zip(vertices, vertices.dropFirst()).enumerated().flatMap { index, pair in
    (0...37).map { i in
      let t = pow(Double(i)/37, 1.6), (a,b) = pair
      let x = a.x+(b.x-a.x)*t+0.9*sin(Double(i+index)), y = a.y+(b.y-a.y)*t+0.9*cos(Double(i+index))
      return SpatialPoint(x:300+(x*cos(angle)-y*sin(angle))/scale, y:300+(x*sin(angle)+y*cos(angle))/scale)
    }
  }
}

@Test("Стрелка допускает отрывы, обратное направление и наконечник до стержня", arguments: [0.4, 1.0, 3.0])
func quickShapeArrowsWithoutPrescribedStrokeOrder(scale: Double) throws {
  let tail = SpatialPoint(x:0,y:0), tip = SpatialPoint(x:180,y:0)
  let upper = SpatialPoint(x:141,y:-29), lower = SpatialPoint(x:139,y:31)
  let sketches = [
    [[tail, tip, upper, tip, lower]], [[upper, tip, lower, tip, tail]],
    [[tip, tail, tip, lower, tip, upper]], [[tail, tip], [upper, tip, lower]],
    [[lower, tip, upper], [tip, tail]], [[tail, tip], [tip, upper], [lower, tip]],
    [[upper, tip], [tip, tail], [lower, tip]]
  ]
  for vertices in sketches {
    for angle in [0.0, 0.72, 2.4, 4.8] {
      let strokes = vertices.map { sketch($0, scale:scale, angle:angle) }
      let fit = try #require(NotebookQuickShape.recognize(strokes:strokes,screenScale:scale), "\(vertices.count) strokes, angle \(angle)")
      #expect(fit.shape == .connector)
      #expect(fit.connection?.endArrowhead == .arrow)
      #expect(fit.sampleCount == strokes.last!.count, "Only current-contact measurements are frozen at the hold")
      let start = try #require(fit.connection?.start.point), end = try #require(fit.connection?.end.point)
      #expect(hypot(end.x-start.x,end.y-start.y)*scale > 175)
    }
  }
}

@Test("Неровный почти замкнутый круг не требует идеального совпадения концов", arguments: [-0.42, 0.0, 0.4])
func quickShapeRoughOpenAndOvershotCircles(overlap: Double) throws {
  let points = (0...160).map { i -> SpatialPoint in
    let a = pow(Double(i)/160, 1.8)*(2*Double.pi+overlap)
    let radius = 60*(1+0.085*sin(3*a)+0.04*cos(7*a))
    return .init(x:200+radius*cos(a), y:180+radius*sin(a))
  }
  let fit = try #require(NotebookQuickShape.recognize(points,screenScale:1))
  #expect(fit.shape == .ellipse)
}

@Test("Квадрат и плюс распознаются как собственная геометрия из одного и нескольких штрихов")
func quickShapeRectanglesAndPluses() throws {
  let a = SpatialPoint(x:0,y:0), b = SpatialPoint(x:100,y:0), c = SpatialPoint(x:100,y:100), d = SpatialPoint(x:0,y:100)
  let center = SpatialPoint(x:50,y:50), left = SpatialPoint(x:0,y:50), right = SpatialPoint(x:100,y:50)
  let top = SpatialPoint(x:50,y:0), bottom = SpatialPoint(x:50,y:100)
  let examples: [(NotebookGraphic.Shape, [[SpatialPoint]])] = [
    (.rectangle,[[a,b,c,d,a]]), (.rectangle,[[a,b],[d,c],[a,d],[b,c]]),
    (.plus,[[left,right],[top,bottom]]), (.plus,[[bottom,top],[right,left]]),
    (.plus,[[left,center,top,bottom,center,right]])
  ]
  for (shape, vertices) in examples {
    for angle in [-0.055,0,0.055] {
      let fit = try #require(NotebookQuickShape.recognize(strokes:vertices.map { sketch($0,angle:angle) },screenScale:1))
      #expect(fit.shape == shape)
      #expect(fit.connection == nil)
    }
  }
}

@Test("Неполные фигуры, буквы и соседние штрихи не поглощаются общим распознавателем")
func quickShapeCompoundNegatives() {
  let examples: [[[SpatialPoint]]] = [
    [[.init(x:0,y:0),.init(x:0,y:100),.init(x:100,y:100)]], // L
    [[.init(x:0,y:0),.init(x:100,y:0)],[.init(x:50,y:0),.init(x:50,y:100)]], // T
    [[.init(x:0,y:0),.init(x:100,y:100),.init(x:200,y:0)]], // V
    [[.init(x:0,y:0),.init(x:100,y:100),.init(x:200,y:0),.init(x:0,y:0)]],
    [[.init(x:0,y:0),.init(x:100,y:0)],[.init(x:300,y:0),.init(x:300,y:100)]],
    [[.init(x:0,y:0),.init(x:10,y:0),.init(x:10,y:10),.init(x:0,y:10),.init(x:0,y:0)]]
  ]
  for vertices in examples {
    #expect(NotebookQuickShape.recognize(strokes:vertices.map { sketch($0) },screenScale:1) == nil)
  }
  #expect(NotebookQuickShape.recognize(strokes:[],screenScale:1) == nil)
  #expect(NotebookQuickShape.recognize([.zero,.init(x:100,y:10)],screenScale:0) == nil)
}

@Test("Контуры квадрата и плюса совпадают с их областями выбора")
func graphicRectangleAndPlusContourHitTesting() {
  let rectangle = NotebookGraphic(shape:.rectangle), plus = NotebookGraphic(shape:.plus)
  #expect(NotebookGraphicGeometry.hitTest(rectangle,width:100,height:80,x:2,y:2,tolerance:3))
  #expect(!NotebookGraphicGeometry.hitTest(rectangle,width:100,height:80,x:50,y:40,tolerance:3))
  #expect(NotebookGraphicGeometry.hitTest(plus,width:100,height:80,x:50,y:40,tolerance:3))
  #expect(NotebookGraphicGeometry.hitTest(plus,width:100,height:80,x:0,y:40,tolerance:3))
  #expect(!NotebookGraphicGeometry.hitTest(plus,width:100,height:80,x:0,y:0,tolerance:3))
}

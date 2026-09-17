import AppKit
import NotebookCore
import XCTest
@testable import Notebook

@MainActor final class NotebookGraphicRenderingTests: XCTestCase {
  func testPartialEraserUnionsOverlapsAndMovesWithEveryNativeFigure() async throws {
    let actor = UUID(), frame = PageRect(x: 40, y: 40, width: 160, height: 160)
    for shape in [NotebookGraphic.Shape.ellipse, .rectangle, .plus] {
      let graphic = NotebookGraphic(shape: shape, style: .init(strokeWidth: 6))
      let element = AgentElement(id: "shape", kind: .graphic, frame: frame, source: "", html: "", graphic: graphic)
      let target = InkElementTarget(elementID: element.id, frame: frame)
      let samples = [110.0, 130.0].map { y in
        SpatialInkSample(point: .init(x: 43, y: y), timeOffset: y, width: 24,
          opacity: 1, force: 1, azimuth: 0, altitude: 1)
      }
      let eraser = PageInkAction(tool: .eraser, samples: samples).erasingElements([target])
      let second = PageInkAction(tool: .eraser, samples: samples).erasingElements([target])
      let drawing = try PageInkDrawing().appending(eraser).appending(second)
      let page = PageDocument(size: .init(width: 350, height: 250), actor: actor,
        drawingData: try drawing.dataRepresentation(), elements: [element])
      func image(_ page: PageDocument) async throws -> NSBitmapImageRep {
        let result = try await PageCompositionRenderer.render(page, scale: 1) { _ in
          XCTFail("Native erasure must not start WebKit"); throw CocoaError(.featureUnsupported)
        }
        let proof = XCTAttachment(data: result.png, uniformTypeIdentifier: "public.png")
        proof.name = "partially-erased-\(shape.rawValue)"; proof.lifetime = .keepAlways; add(proof)
        return try XCTUnwrap(NSBitmapImageRep(data: result.png))
      }
      func dark(_ image: NSBitmapImageRep, _ x: Int, _ y: Int) -> Bool {
        guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
        return max(color.redComponent, color.greenComponent, color.blueComponent) < 0.3
      }
      let erased = try await image(page)
      XCTAssertFalse(dark(erased, 43, 120), "The traversed contour is cut, including overlapping erasers")
      XCTAssertTrue(dark(erased, 196, 120), "The opposite side survives as the same native figure")
      var moved = page
      moved.replaceElements([.init(id: element.id, kind: .graphic,
        frame: .init(x: 140, y: 40, width: 160, height: 160), source: "", html: "", graphic: graphic)], actor: actor)
      let shifted = try await image(moved)
      XCTAssertFalse(dark(shifted, 143, 120), "A cutout travels with the object, not the old screen position")
      XCTAssertTrue(dark(shifted, 296, 120))
      let restored = PageDocument(size: page.size, actor: actor,
        drawingData: try drawing.removing([eraser.id, second.id]).dataRepresentation(), elements: [element])
      let uncut = try await image(restored)
      XCTAssertTrue(dark(uncut, 43, 120), "Undo restores original native geometry, not a traced bitmap")
    }
  }


  func testRectangleAndPlusPaintTheirOwnContoursRatherThanEllipses() async throws {
    let elements = [NotebookGraphic.Shape.rectangle,.plus].enumerated().map { index, shape in
      AgentElement(id:shape.rawValue,kind:.graphic,frame:.init(x:20+Double(index)*140,y:20,width:100,height:100),
        source:"",html:"",graphic:.init(shape:shape,style:.init(strokeWidth:4)))
    }
    let page = PageDocument(size:.init(width:280,height:150),actor:UUID(),elements:elements)
    let result = try await PageCompositionRenderer.render(page,scale:1) { _ in
      XCTFail("Native contours do not request WebKit"); throw CocoaError(.featureUnsupported)
    }
    let image = try XCTUnwrap(NSBitmapImageRep(data:result.png))
    func dark(_ x: Int, _ y: Int) -> Bool {
      guard let color = image.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB) else { return false }
      return max(color.redComponent,color.greenComponent,color.blueComponent) < 0.3
    }
    XCTAssertTrue(dark(22,22),"Rectangle corner, not ellipse")
    XCTAssertFalse(dark(70,70),"Rectangle interior remains empty")
    XCTAssertTrue(dark(210,70),"Plus intersection is painted")
    XCTAssertTrue(dark(210,24)); XCTAssertTrue(dark(164,70))
    XCTAssertFalse(dark(164,24),"Plus has no box or ellipse around it")
    let proof = XCTAttachment(data:result.png,uniformTypeIdentifier:"public.png")
    proof.name = "native-rectangle-plus"; proof.lifetime = .keepAlways; add(proof)
  }

  func testBoundArcsAndNineArrowheadsRenderAsNativeGeometryWithoutWebKit() async throws {
    let actor = UUID()
    var elements: [AgentElement] = []
    for (index,head) in NotebookGraphicConnection.Arrowhead.allCases.enumerated() {
      let y = Double(index)*108+20
      for (id,x) in [("a-\(index)",40.0),("b-\(index)",580.0)] {
        elements.append(.init(id:id,kind:.graphic,frame:.init(x:x,y:y,width:76,height:76),source:"",html:"",graphic:.init(label:id.hasPrefix("a") ? "+" : "−")))
      }
      elements.append(.init(id:"link-\(index)",kind:.graphic,frame:.init(x:180,y:y+38,width:100,height:1),source:"",html:"",
        graphic:.init(shape:.connector,style:.init(strokeWidth:2,dash:index == 1 ? .dashed : index == 2 ? .dotted : .solid),label:head.rawValue,
          connection:.init(start:.init(point:.zero,binding:.init(elementID:"a-\(index)")),
            end:.init(point:.init(x:100,y:0),binding:.init(elementID:"b-\(index)")),
            bend:Double(index%3-1)*30,startArrowhead:head,endArrowhead:head))))
    }
    let page = PageDocument(size:.init(width:720,height:1024),actor:actor,elements:elements)
    let result = try await PageCompositionRenderer.render(page) { _ in
      XCTFail("Native nodes, labels and connections have no WebKit preparation")
      throw CocoaError(.featureUnsupported)
    }
    let image = try XCTUnwrap(NSBitmapImageRep(data:result.png))
    XCTAssertEqual(image.pixelsWide,1440); XCTAssertEqual(image.pixelsHigh,2048)
    for index in 0..<9 {
      let layout = try XCTUnwrap(page.graphicGraph().resolve("link-\(index)").layout)
      let point = try XCTUnwrap(layout.curves.first).point(at:0.25)
      let x = Int((layout.frame.x+point.x)*2), y = Int((layout.frame.y+point.y)*2)
      var dark = false
      for dx in -6...6 { for dy in -6...6 {
        if let color = image.colorAt(x:x+dx,y:y+dy)?.usingColorSpace(.deviceRGB),max(color.redComponent,color.greenComponent,color.blueComponent) < 0.3 { dark = true }
      } }
      XCTAssertTrue(dark,"Row \(index) must paint its actual derived curve rather than its authored frame")
    }
    let proof = XCTAttachment(data:result.png,uniformTypeIdentifier:"public.png")
    proof.name = "native-nine-arrowheads"; proof.lifetime = .keepAlways; add(proof)
  }

  func testNativeCompositeAndInkMapShareReversiblePresentationWithoutWebKit() async throws {
    let actor = UUID()
    let stroke = PageInkAction(tool: .pen, samples: [20.0, 110.0].map {
      .init(point: .init(x: $0, y: 30), timeOffset: 0, width: 5, opacity: 1, force: 1, azimuth: 0, altitude: 1)
    })
    let drawing = try PageInkDrawing(actions: [stroke]).dataRepresentation()
    func page(_ representation: NotebookGraphic.Representation, visible: Bool = true) -> PageDocument {
      .init(size: .init(width: 260, height: 260), actor: actor, drawingData: drawing, elements: [
        .init(id: "circle", kind: .graphic, frame: .init(x: 100, y: 100, width: 120, height: 120),
          source: "", html: "", graphic: .init(label: "+", representation: representation,
            visible: visible, sourceInkIDs: [stroke.id]))
      ])
    }
    func pixels(_ page: PageDocument) async throws -> Data {
      try await PageCompositionRenderer.render(page) { _ in
        XCTFail("A native shape must not request a web source")
        throw CocoaError(.featureUnsupported)
      }.png
    }
    let raw = page(.ink), geometry = page(.geometry), hidden = page(.geometry, visible: false)
    let original = try await pixels(raw), converted = try await pixels(geometry), deleted = try await pixels(hidden)
    XCTAssertNotEqual(original, converted); XCTAssertNotEqual(converted, deleted)
    let restoredGeometry = try await pixels(page(.geometry)), restoredInk = try await pixels(page(.ink))
    XCTAssertEqual(restoredGeometry, converted); XCTAssertEqual(restoredInk, original)
    XCTAssertFalse(try PageVisionRenderer.render(raw).regions.isEmpty)
    XCTAssertTrue(try PageVisionRenderer.render(geometry).regions.isEmpty)
    XCTAssertTrue(try PageVisionRenderer.render(hidden).regions.isEmpty)
    XCTAssertEqual(raw.drawingData, geometry.drawingData); XCTAssertEqual(hidden.drawingData, drawing)
  }

  func testInkRasterIdentityIncludesPresentationWithoutChangingTheMeasurementVersion() async throws {
    let actor = UUID(), id = UUID()
    let stroke = PageInkAction(tool: .pen, samples: [20.0, 100.0].map {
      .init(point: .init(x: $0, y: 30), timeOffset: 0, width: 5, opacity: 1, force: 1, azimuth: 0, altitude: 1)
    })
    let raw = PageDocument(id: id, size: .init(width: 180, height: 180), actor: actor,
      drawingData: try PageInkDrawing(actions: [stroke]).dataRepresentation())
    var converted = raw
    converted.replaceElements([.init(id: "circle", kind: .graphic,
      frame: .init(x: 20, y: 20, width: 100, height: 100), source: "", html: "",
      graphic: .init(sourceInkIDs: [stroke.id]))], actor: actor)
    let cache = PageInkRasterCache()
    await cache.prepare(raw)
    let original = try XCTUnwrap(cache.image(for: raw))
    XCTAssertNil(cache.image(for: converted))
    await cache.prepare(converted)
    XCTAssertFalse(try XCTUnwrap(cache.image(for: converted)) === original)
    XCTAssertTrue(cache.image(for: raw) === original)
    XCTAssertEqual(raw.drawingStamp, converted.drawingStamp)
  }
}

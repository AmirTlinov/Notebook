import AppKit
import NotebookCore
import XCTest
@testable import Notebook

@MainActor final class NotebookGraphicRenderingTests: XCTestCase {
  func testDetachedLassoConnectorKeepsTheActuallyRenderedContour() async throws {
    for routing in [NotebookGraphicConnection.Routing.curved,.elbow] {
      let actor=UUID(),size=PageSize(width:640,height:600)
      let targets:[AgentElement]=[
        .init(id:"a",kind:.graphic,frame:.init(x:50,y:50,width:200,height:200),source:"",html:"",graphic:.init(shape:.rectangle)),
        .init(id:"b",kind:.graphic,frame:.init(x:350,y:340,width:100,height:20),source:"",html:"",graphic:.init(shape:.rectangle))]
      let arrow=AgentElement(id:"link",kind:.graphic,frame:.init(x:20,y:30,width:500,height:500),source:"",html:"",
        graphic:.init(shape:.connector,style:.init(stroke:.init(red:0.8,green:0.1,blue:0.2),strokeWidth:10),connection:.init(
          start:.init(point:.zero,binding:.init(elementID:"a")),end:.init(point:.zero,binding:.init(elementID:"b")),
          bend:routing == .curved ? 70 : 0,bendPosition:routing == .curved ? 1 : 0.5,routing:routing)))
      let page=PageDocument(size:size,actor:actor,elements:targets+[arrow]),graph=page.graphicGraph()
      let body=try XCTUnwrap(graph.resolve(arrow.id).layout),f=body.frame
      let address=NotebookToolAddress(surface:.page(page.id),boardID:nil,worldOrigin:nil,bounds:nil)
      let region=NotebookRegionSelection(id:UUID(),address:address,
        polygon:[.init(x:f.x,y:f.y),.init(x:f.x+f.width*0.9,y:f.y),
          .init(x:f.x+f.width*0.9,y:f.y+f.height),.init(x:f.x,y:f.y+f.height)],
        frame:.init(x:f.x,y:f.y,width:f.width*0.9,height:f.height),rawInk:nil,expectedInkRevision:nil,
        graphics:[address.reference(arrow.id)])
      let prepared=try XCTUnwrap(NotebookRegionMaterialization.prepare(region,graph:graph,snapshot:.init(page:page,board:nil)))
      let fragment=try XCTUnwrap(prepared.working.first)
      XCTAssertTrue(fragment.graphic.connection?.bindings.isEmpty == true)
      var masked=try XCTUnwrap(arrow.graphic);masked.mask=fragment.graphic.mask
      let source=AgentElement(id:arrow.id,kind:.graphic,frame:arrow.frame,source:"",html:"",graphic:masked)
      let expected=PageDocument(size:size,actor:actor,elements:targets+[source])
      let actual=PageDocument(size:size,actor:actor,elements:targets+[fragment.pageElement])
      func render(_ page:PageDocument,_ name:String) async throws -> NSBitmapImageRep {
        let image=try await PageCompositionRenderer.render(page,scale:1) { _ in throw CocoaError(.featureUnsupported) }
        let attachment=XCTAttachment(data:image.png,uniformTypeIdentifier:"public.png")
        attachment.name=name;attachment.lifetime = .keepAlways;add(attachment)
        return try XCTUnwrap(NSBitmapImageRep(data:image.png))
      }
      let before=try await render(expected,"bound-\(routing)"),after=try await render(actual,"detached-\(routing)")
      var largest=0.0,redPixels=0
      for y in 0..<before.pixelsHigh { for x in 0..<before.pixelsWide {
        let a=try XCTUnwrap(before.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB))
        let b=try XCTUnwrap(after.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB))
        largest=max(largest,abs(a.redComponent-b.redComponent),abs(a.greenComponent-b.greenComponent),abs(a.blueComponent-b.blueComponent))
        if a.redComponent>0.6 && a.greenComponent<0.3 { redPixels += 1 }
      } }
      XCTAssertGreaterThan(redPixels,500,"An empty render cannot establish preservation")
      XCTAssertLessThan(largest,0.02,"The rendered curve, head and cut remain in the same local basis")
    }
  }

  func testRetainedPressureInkAndNativePageTextUseTheNativeExportPlane() async throws {
    let actor = UUID(), size = PageSize(width:300,height:200)
    let samples = (0...30).map { i in SpatialInkSample(point:.init(x:30+Double(i)*7,y:60+sin(Double(i)/5)*25),
      timeOffset:Double(i)/100,width:14,opacity:0.2+Double(i)/50,force:Double(i)/30,azimuth:0,altitude:1) }
    let stroke = PageInkAction(tool:.pen,color:.init(red:0.1,green:0.3,blue:0.8),samples:samples)
    let cut = PageInkAction(tool:.eraser,samples:[45.0,105].map { y in
      .init(point:.init(x:160,y:y),timeOffset:0,width:12,opacity:1,force:1,azimuth:0,altitude:1) })
    let later = PageInkAction(tool:.pen,color:.init(red:0.8,green:0.2,blue:0.1),samples:[140.0,190,140,190].enumerated().map { i,x in
      .init(point:.init(x:x,y:65+Double(i)*10),timeOffset:Double(i),width:10,opacity:0.4,force:0.4,azimuth:0,altitude:1) })
    let actions = [stroke,cut,later]
    let drawing = try PageInkDrawing(actions:actions).dataRepresentation()
    let raw = PageDocument(size:size,actor:actor,drawingData:drawing)
    let frame = PageRect(x:0,y:0,width:300,height:200)
    let graphic = NotebookGraphic(shape:.freehand,sourceInkIDs:[stroke.id,later.id],freehand:.init(layers:actions.map {
      .init(tool:$0.tool,color:$0.color,measured:.init(sourceID:$0.id,measurements:$0.samples,frame:frame)) }))
    let converted = PageDocument(size:size,actor:actor,drawingData:drawing,elements:[
      .init(id:"retained",kind:.graphic,frame:frame,source:"",html:"",graphic:graphic)])
    func render(_ page:PageDocument,_ name:String) async throws -> NSBitmapImageRep {
      let result = try await PageCompositionRenderer.render(page,scale:2) { _ in
        XCTFail("Native ink/text must never start WebKit"); throw CocoaError(.featureUnsupported)
      }
      let proof = XCTAttachment(data:result.png,uniformTypeIdentifier:"public.png"); proof.name = name; proof.lifetime = .keepAlways; add(proof)
      return try XCTUnwrap(NSBitmapImageRep(data:result.png))
    }
    let before = try await render(raw,"measured-pressure-ink"), after = try await render(converted,"retained-pressure-ink")
    var error = 0.0, count = 0, interiorError = 0.0
    for x in stride(from:40,to:510,by:2) { for y in stride(from:50,to:180,by:2) {
      let a = try XCTUnwrap(before.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB))
      let b = try XCTUnwrap(after.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB))
      error += abs(a.redComponent-b.redComponent)+abs(a.greenComponent-b.greenComponent)+abs(a.blueComponent-b.blueComponent); count += 3
      let inside = [(0,0),(-4,0),(4,0),(0,-4),(0,4)].allSatisfy { dx,dy in
        (before.colorAt(x:x+dx,y:y+dy)?.usingColorSpace(.deviceRGB)?.redComponent ?? 1) < 0.88
      }
      if inside { interiorError = max(interiorError,abs(a.redComponent-b.redComponent),abs(a.greenComponent-b.greenComponent),abs(a.blueComponent-b.blueComponent)) }
    } }
    XCTAssertLessThan(error/Double(count),0.015,"A lasso preserves measured paint; only raster-edge antialiasing can differ")
    XCTAssertLessThan(interiorError,0.025,"Average error can hide triangle seams; stroke interiors must preserve coverage too")
    let text = AgentElement(id:"text",kind:.nativeText,frame:.init(x:30,y:120,width:240,height:60),source:"Native page text",html:"",textStyle:.init(fontSize:24))
    let withText = PageDocument(size:size,actor:actor,elements:[text])
    let textImage = try await render(withText,"native-page-text")
    var dark = 0
    for x in 60..<530 { for y in 240..<330 {
      if let c = textImage.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB),max(c.redComponent,c.greenComponent,c.blueComponent) < 0.4 { dark += 1 }
    } }
    XCTAssertGreaterThan(dark,1000)
  }

  func testDenseRoundEraserExportPreparesItsMaskWithoutBlockingTheMainActor() async throws {
    let frame = PageRect(x:20,y:20,width:160,height:160)
    let graphic = NotebookGraphic(shape:.rectangle,style:.init(strokeWidth:2,fill:.black))
    let element = AgentElement(id:"dense-cut",kind:.graphic,frame:frame,source:"",html:"",graphic:graphic)
    let samples = (0..<2048).map { index in
      let angle = Double(index)*0.31
      return SpatialInkSample(point:.init(x:80+cos(angle)*3,y:80+sin(angle)*3),timeOffset:Double(index)/240,
        width:36,opacity:1,force:1,azimuth:0,altitude:1)
    }
    let erase = PageInkAction(tool:.eraser,samples:samples).erasingElements([.init(elementID:element.id,frame:frame)])
    let page = PageDocument(size:.init(width:200,height:200),actor:UUID(),drawingData:try PageInkDrawing(actions:[erase]).dataRepresentation(),elements:[element])
    var ticks = 0
    let heartbeat = Task { @MainActor in
      while !Task.isCancelled { try? await Task.sleep(for:.milliseconds(10)); ticks += 1 }
    }
    defer { heartbeat.cancel() }
    let started = ContinuousClock.now
    let result = try await PageCompositionRenderer.render(page,scale:1) { _ in
      XCTFail("Native erasure never starts WebKit"); throw CocoaError(.featureUnsupported)
    }
    XCTAssertLessThan(started.duration(to:.now),.seconds(8),"Dense cutouts cannot monopolize CPU mask rasterization")
    XCTAssertGreaterThan(ticks,2,"The main actor remains available during canonical mask preparation")
    let image = try XCTUnwrap(NSBitmapImageRep(data:result.png))
    XCTAssertGreaterThan(try XCTUnwrap(image.colorAt(x:80,y:80)?.usingColorSpace(.deviceRGB)).redComponent,0.8)
    XCTAssertLessThan(try XCTUnwrap(image.colorAt(x:140,y:140)?.usingColorSpace(.deviceRGB)).redComponent,0.2)
  }

  func testDenseBoardPreviewAndCompositionTilesKeepMainActorResponsive() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let workspace = try store.loadIndex(), before = try store.loadBoard(items: workspace.items)
    var tree = before
    _ = tree.moveItem(workspace.selectedItemID, in: header.rootBoardID, to: .init(x: 10000, y: 10000), actor: actor)
    let frame = PageRect(x: 20, y: 20, width: 160, height: 160)
    let element = SpatialElement(id: "dense-board-cut", surface: .board(header.rootBoardID), kind: .graphic,
      frame: .init(x: frame.x, y: frame.y, width: frame.width, height: frame.height), worldOrigin: .zero,
      source: "", graphic: .init(shape: .rectangle, style: .init(strokeWidth: 2, fill: .black)), stamp: workspace.stamp)
    XCTAssertTrue(tree.upsertElement(element, in: header.rootBoardID, expected: nil, actor: actor))
    _ = try store.saveBoardEdits(before: before, after: tree)
    let samples = (0..<3603).map { index in
      let angle = Double(index) * 0.31
      let point = SpatialPoint(x: 80 + cos(angle) * 3, y: 80 + sin(angle) * 3)
      return SpatialInkSample(point: point, worldPoint: .init(x: point.x, y: point.y), timeOffset: Double(index) / 240,
        width: 36, opacity: 1, force: 1, azimuth: 0, altitude: 1)
    }
    var ink = try store.loadSpatialInk()
    _ = ink.append(tool: .eraser, spans: [.init(surface: .board(header.rootBoardID), samples: samples,
      elementTargets: [.init(elementID: element.id, frame: frame, worldOrigin: .zero)])], actor: actor)
    try store.saveSpatialInk(ink)
    let current = try store.workspaceHeader()
    let source = SceneCompositionSource(store: store, revision: current.cursor, workspaceID: current.workspaceID)
    let presence = SessionPresence(boardID: header.rootBoardID, mode: .board,
      camera: .init(center: .init(x: 100, y: 100), scale: 1), viewport: .init(x: 200, y: 200))
    let resources = SceneRenderResources()
    var maximumGap = Duration.zero, ticks = 0
    let heartbeat = Task { @MainActor in
      var previous = ContinuousClock.now
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(10))
        let now = ContinuousClock.now
        maximumGap = max(maximumGap, previous.duration(to: now)); previous = now; ticks += 1
      }
    }
    defer { heartbeat.cancel() }
    let start = ContinuousClock.now
    let result = try await SceneCompositionRenderer(source: source, resources: resources).render(presence: presence, scale: 1)
    let tile = try XCTUnwrap(CompositionTile(containing: .init(x: 80, y: 80), level: 0))
    let key = SceneCompositionTileKey(workspaceID: current.workspaceID, revision: current.cursor, plane: .board(header.rootBoardID),
      tile: tile, range: .whole(.elements), presentationScale: 1, viewportWidth: 200, viewportHeight: 200, focusedItemID: nil, mode: "board")
    let raster = try await SceneCompositionRenderer(source: source, resources: resources).renderTile(key: key, presentation: presence)
    raster.release()
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertGreaterThan(ticks, 2)
    XCTAssertLessThan(maximumGap, .seconds(1), "Dense masks must not enter CPU softmask rendering on MainActor")
    XCTAssertLessThan(start.duration(to: .now), .seconds(10))
    let image = try XCTUnwrap(NSBitmapImageRep(data: result.png))
    XCTAssertGreaterThan(try XCTUnwrap(image.colorAt(x: 80, y: 80)?.usingColorSpace(.deviceRGB)).redComponent, 0.8)
    XCTAssertLessThan(try XCTUnwrap(image.colorAt(x: 140, y: 140)?.usingColorSpace(.deviceRGB)).redComponent, 0.2)
    let proof = XCTAttachment(string: "samples=3603; elapsed=\(start.duration(to: .now)); maximumMainActorGap=\(maximumGap); ticks=\(ticks)")
    proof.name = "dense-board-preview-main-actor"; proof.lifetime = .keepAlways; add(proof)
  }

  func testRoundEraserTurnLeavesNoPenMiterInSavedPixels() async throws {
    func sample(_ x: Double, _ y: Double, _ width: Double) -> SpatialInkSample {
      .init(point:.init(x:x,y:y),timeOffset:0,width:width,opacity:1,force:1,azimuth:0,altitude:1)
    }
    let drawing = try PageInkDrawing(actions:[
      .init(tool:.pen,samples:[sample(110,110,200)]),
      .init(tool:.eraser,samples:[sample(40,80,40),sample(120,80,40),sample(120,160,40)])
    ]).dataRepresentation()
    let page = PageDocument(size:.init(width:230,height:230),actor:UUID(),drawingData:drawing)
    let result = try await PageCompositionRenderer.render(page,scale:2) { _ in
      XCTFail("Measured erasure stays native"); throw CocoaError(.featureUnsupported)
    }
    let image = try XCTUnwrap(NSBitmapImageRep(data:result.png))
    func red(_ x: Int, _ y: Int) throws -> CGFloat {
      try XCTUnwrap(image.colorAt(x:x*2,y:y*2)?.usingColorSpace(.deviceRGB)).redComponent
    }
    XCTAssertLessThan(try red(138,62),0.2,"Outside the round turn remains ink, not the pen's square/miter cut")
    XCTAssertGreaterThan(try red(132,68),0.8,"The interior of the round turn is erased")
    XCTAssertGreaterThan(try red(120,80),0.8)
    let proof = XCTAttachment(data:result.png,uniformTypeIdentifier:"public.png")
    proof.name = "round-eraser-saved-turn"; proof.lifetime = .keepAlways; add(proof)
  }

  func testRoundedPolygonPaintUsesTheSharedContour() async throws {
    let graphic = NotebookGraphic(shape:.rectangle,style:.init(strokeWidth:3,fill:.black),cornerRadius:30)
    let page = PageDocument(size:.init(width:200,height:180),actor:UUID(),elements:[
      .init(id:"round",kind:.graphic,frame:.init(x:30,y:30,width:120,height:100),source:"",html:"",graphic:graphic)])
    let render = try await PageCompositionRenderer.render(page,scale:1) { _ in
      XCTFail("A native contour never starts WebKit"); throw CocoaError(.featureUnsupported)
    }
    let image = try XCTUnwrap(NSBitmapImageRep(data:render.png))
    XCTAssertGreaterThan(try XCTUnwrap(image.colorAt(x:32,y:32)?.usingColorSpace(.deviceRGB)).redComponent,0.8)
    XCTAssertLessThan(try XCTUnwrap(image.colorAt(x:47,y:47)?.usingColorSpace(.deviceRGB)).redComponent,0.2)
    let proof = XCTAttachment(data:render.png,uniformTypeIdentifier:"public.png"); proof.name = "rounded-polygon-mac"; proof.lifetime = .keepAlways; add(proof)
  }

  func testPartialEraserUnionsOverlapsAndMovesWithEveryNativeFigure() async throws {
    let actor = UUID(), frame = PageRect(x: 40, y: 40, width: 160, height: 160)
    for shape in [NotebookGraphic.Shape.ellipse, .rectangle, .triangle, .diamond, .plus] {
      let left = shape == .triangle ? 81 : 43, right = shape == .triangle ? 158 : 196
      let graphic = NotebookGraphic(shape: shape, style: .init(strokeWidth: 6))
      let element = AgentElement(id: "shape", kind: .graphic, frame: frame, source: "", html: "", graphic: graphic)
      let target = InkElementTarget(elementID: element.id, frame: frame)
      let samples = [110.0, 130.0].map { y in
        SpatialInkSample(point: .init(x: Double(left), y: y), timeOffset: y, width: 24,
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
      XCTAssertFalse(dark(erased, left, 120), "The traversed contour is cut, including overlapping erasers")
      XCTAssertTrue(dark(erased, right, 120), "The opposite side survives as the same native figure")
      var moved = page
      moved.replaceElements([.init(id: element.id, kind: .graphic,
        frame: .init(x: 140, y: 40, width: 160, height: 160), source: "", html: "", graphic: graphic)], actor: actor)
      let shifted = try await image(moved)
      XCTAssertFalse(dark(shifted, left+100, 120), "A cutout travels with the object, not the old screen position")
      XCTAssertTrue(dark(shifted, right+100, 120))
      let restored = PageDocument(size: page.size, actor: actor,
        drawingData: try drawing.settingActive(false,for:[eraser.id,second.id],stamp:.init(counter:1,actor:UUID())).dataRepresentation(), elements: [element])
      let uncut = try await image(restored)
      XCTAssertTrue(dark(uncut, left, 120), "Undo restores original native geometry, not a traced bitmap")
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

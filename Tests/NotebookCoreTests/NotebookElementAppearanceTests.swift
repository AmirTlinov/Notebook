import CoreGraphics
import Foundation
import Testing
@testable import NotebookCore

@Suite struct NotebookElementAppearanceTests {
  let frame = PageRect(x:100,y:200,width:160,height:100)
  func cut(_ points: [SpatialPoint], width: Double = 20) -> InkElementErasure {
    .init(target:.init(elementID:"box",frame:frame),samples:points.map {
      .init(point:.init(x:$0.x+frame.x,y:$0.y+frame.y),timeOffset:0,width:width,opacity:1,force:1,azimuth:0,altitude:1)
    })
  }
  func appearance(_ cuts: [InkElementErasure], size: CGSize = .init(width:160,height:100), graphic: NotebookGraphic? = .init(shape:.rectangle,style:.init(strokeWidth:4))) -> NotebookElementAppearance {
    .init(graphic:graphic,layout:nil,size:size,erasures:cuts)
  }
  @Test func denseRepeatedEraseRemovesEveryLabeledOutline() {
    let samples = (0..<4096).map { i in
      let t = Double(i % 64) * 2 * Double.pi / 64
      return SpatialInkSample(point: .init(x:465+80*cos(t),y:745+70*sin(t)),
        timeOffset:Double(i)/240,width:260,opacity:1,force:1,azimuth:0,altitude:1)
    }
    for i in 0..<16 {
      let frame = PageRect(x:350+Double(i%4)*65,y:650+Double(i/4)*55,width:40,height:35)
      let cut = InkElementErasure(target:.init(elementID:"erased-\(i)",frame:frame),samples:samples)
      let result = NotebookElementAppearance(graphic:.init(shape:.rectangle,label:"Erased \(i)"),
        layout:nil,size:.init(width:40,height:35),erasures:[cut])
      #expect(result.state == .erased, "Fully covered labeled shape \(i) cannot remain selectable")
      #expect(!result.contains(.init(x:20,y:17.5),tolerance:6))
    }
  }
  @Test(arguments: [4096, 100_000])
  func densePartialEraseReadUsesSurvivingOutlineWithoutExpandingEveryCut(_ count: Int) {
    let samples = (0..<count).map { index in
      let angle = Double(index % 64) * 2 * Double.pi / 64
      return SpatialInkSample(point: .init(x: frame.x + 20 + 10*cos(angle), y: frame.y + 50 + 10*sin(angle)),
        timeOffset: Double(index)/240, width: 30, opacity: 1, force: 1, azimuth: 0, altitude: 1)
    }
    let erased = InkElementErasure(target: .init(elementID: "outline", frame: frame), samples: samples)
    let start = ContinuousClock.now
    let value = NotebookElementAppearance.readProjection(graphic: .init(shape: .rectangle, style: .init(strokeWidth: 4)),
      layout: nil, size: .init(width: frame.width, height: frame.height), erasures: [erased])
    let elapsed = start.duration(to: .now)
    print("Partial outline, \(count) measured eraser samples: \(elapsed)")
    #expect(value["state"] == .string("partial"))
    #expect(value["sourceIsCompleteAppearance"] == .bool(false))
    #expect(elapsed < .milliseconds(500), "Reading a partial outline must not subtract every repeated cut to find its untouched side")
  }
  @Test func fullyErasedHollowContourHasNoGhostInterior() {
    let rim = cut([.init(x:0,y:0),.init(x:160,y:0),.init(x:160,y:100),.init(x:0,y:100),.init(x:0,y:0)])
    let result = appearance([rim])
    #expect(result.state == .erased)
    #expect(!result.contains(.init(x:80,y:50),tolerance:12))
    #expect(!result.contains(.init(x:0,y:50),tolerance:12))
    #expect(NotebookElementAppearance.readProjection(graphic:.init(shape:.rectangle,style:.init(strokeWidth:4)),
      layout:nil,size:.init(width:160,height:100),erasures:[rim])["sourceIsCompleteAppearance"] == .bool(false))
    #expect(appearance([]).state == .intact)
  }
  @Test(arguments: [31, 40, 64, 127]) func sampledFullRimDoesNotLeaveBooleanSeams(_ steps: Int) {
    let corners = [SpatialPoint(x:0,y:0),.init(x:160,y:0),.init(x:160,y:100),.init(x:0,y:100),.init(x:0,y:0)]
    var points: [SpatialPoint] = []
    for (a,b) in zip(corners,corners.dropFirst()) {
      for i in 0...steps {
        let t = Double(i)/Double(steps)
        points.append(.init(x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t))
      }
    }
    for size in [CGSize(width:160,height:100),CGSize(width:220,height:180)] {
      let result = appearance([cut(points,width:24)],size:size)
      #expect(result.state == .erased, "No artificial batch seam: \(result.remaining.boundingBoxOfPath)")
    }
  }
  @Test func partialEraseKeepsOnlySurvivingPaintAcrossResizeAndOverlap() {
    let erased = cut([.init(x:-10,y:50),.init(x:30,y:50)])
    let result = appearance([erased,erased])
    #expect(result.state == .partial)
    #expect(!result.contains(.init(x:0,y:50),tolerance:12))
    #expect(result.contains(.init(x:160,y:50),tolerance:12))
    #expect(!result.contains(.init(x:80,y:50),tolerance:12))
    let scaled = appearance([erased],size:.init(width:320,height:200))
    #expect(!scaled.contains(.init(x:0,y:100),tolerance:12))
    #expect(scaled.contains(.init(x:320,y:100),tolerance:12))
  }
  @Test func erasedWebEnvelopeCannotBePickedButPartialSourceIsExplicit() {
    let whole = appearance([cut([.init(x:80,y:50)],width:400)],graphic:nil)
    #expect(whole.state == .erased)
    #expect(!whole.contains(.init(x:80,y:50),tolerance:12))
    let part = appearance([cut([.init(x:80,y:50)])],graphic:nil)
    #expect(part.state == .partial)
    #expect(!part.contains(.init(x:80,y:50),tolerance:12))
    #expect(part.contains(.init(x:10,y:10),tolerance:0))
  }
  @Test func normalizedMaskPreservesMeasuredTriangleCoverageAcrossBatchesAndResize() {
    // Independent coverage oracle: the original Metal triangles, not another
    // boolean operation or a resampled/simplified eraser centreline.
    let samples = (0..<192).map { i in
      let t = Double(i) * 0.19
      return SpatialInkSample(point:.init(x:frame.x + 80 + 65*sin(t),y:frame.y + 50 + 38*sin(t*1.7)),
        timeOffset:Double(i)/240,width:3+Double(i%19),opacity:1,force:1,azimuth:0,altitude:1)
    }
    let erasure = InkElementErasure(target:.init(elementID:"box",frame:frame),samples:samples)
    let points = samples.map { sample in
      let p = erasure.target.localPoint(sample)
      return InkStrokeGeometry.RenderPoint(position:.init(Float(p.x),Float(p.y)),
        radius:Float(sample.width/2),premultipliedColor:.init(repeating:1))
    }
    var vertices: [InkStrokeGeometry.Vertex] = []
    InkStrokeGeometry.appendEraserVertices(renderPoints:points,to:&vertices)
    for size in [CGSize(width:160,height:100),CGSize(width:240,height:75)] {
      let mask = NotebookElementAppearance.erasurePath([erasure,erasure],size:size)
      let measured = NotebookElementAppearance.measuredErasurePath([erasure,erasure],size:size)
      let triangles = stride(from:0,to:vertices.count,by:3).map { index in
        let triangle = CGMutablePath()
        for i in 0..<3 {
          let p = vertices[index+i].position
          let point = CGPoint(x:Double(p.x)*size.width/160,y:Double(p.y)*size.height/100)
          if i == 0 { triangle.move(to:point) } else { triangle.addLine(to:point) }
        }
        triangle.closeSubpath(); return triangle
      }
      for x in stride(from:0.317,to:size.width,by:3) {
        for y in stride(from:0.193,to:size.height,by:3) {
          let point = CGPoint(x:x,y:y)
          let expected = triangles.contains { $0.contains(point) }
          #expect(mask.contains(point) == expected)
          #expect(measured.contains(point) == expected)
        }
      }
    }
  }
  @Test func reflectedCapturedCutsCannotCancelOpaqueCoverage() {
    let frame=PageRect(x:0,y:0,width:100,height:100)
    let samples=[10.0,90.0].map { y in SpatialInkSample(point:.init(x:50,y:y),timeOffset:y/100,
      width:20,opacity:1,force:1,azimuth:0,altitude:1) }
    let plain=InkElementErasure(target:.init(elementID:"body",frame:frame),samples:samples)
    let reflected=InkElementErasure(target:.init(elementID:"body",frame:frame,
      elementTransform:.init(a:-1,b:0,c:0,d:1,tx:1,ty:0)),samples:samples)
    let size=CGSize(width:200,height:60)
    let mask=NotebookElementAppearance.measuredErasurePath([plain,reflected],size:size)
    #expect(mask.contains(.init(x:100,y:30)),"Opposite capture orientation still erases the overlap")
    #expect(!mask.contains(.init(x:150,y:30)))
    let visible=NotebookGraphicMask().capturing([plain,reflected],transform:nil)
    #expect(!visible.contains(.init(x:0.5,y:0.5)))
    #expect(visible.contains(.init(x:0.75,y:0.5)))
  }

  @Test func addressedIndexSurvivesMigrationAndUndo() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let store = NotebookStore(root:root), actor = UUID()
    let header = try store.initializeWorkspace(actor:actor,pageSize:.init(width:834,height:1194))
    let pageID = try #require(store.loadIndex().selectedPageID), surface = SurfaceID.board(header.rootBoardID)
    let erase = cut([.init(x:80,y:50)],width:400)
    var page = try store.loadPage(pageID)
    let action = PageInkAction(tool:.eraser,measurements:erase.samples).erasingElements([erase.target])
    let change = try page.prepareInkChange(.append(action),stamp:.init(counter:10,actor:actor))
    let changed = page.publishInkChange(change); #expect(changed); try store.savePage(page)
    let spatial = SpatialInkAction(tool:.eraser,spans:[SpatialInkSpan(surface:surface,samples:erase.samples.map { .init(point:$0.point,worldPoint:WorldPoint(x:$0.point.x,y:$0.point.y),timeOffset:$0.timeOffset,width:$0.width,opacity:1,force:1,azimuth:0,altitude:1) }).erasingElements([.init(elementID:erase.target.elementID,frame:erase.target.frame,worldOrigin:.zero)])],stamp:.init(counter:11,actor:actor))
    try store.commitSpatialInk(.append(spatial,journalStamp:spatial.stamp))
    #expect(try store.readElementErasures(on:.page(pageID),elementID:"box").count == 1)
    #expect(try store.readElementErasures(on:surface,elementID:"box").count == 1)
    #expect(try store.readElementErasures(on:surface,elementID:"absent").isEmpty)
    // Exact v6 store admission rebuilds only a disposable index, not content.
    let cursor = try store.currentReadCursor()
    try store.commandTransaction(advancesReadRevision:false) {
      try store.currentSQL!.run("DROP TABLE ink_element_erasures")
      try store.currentSQL!.run("PRAGMA user_version=6")
    }
    let reopened = NotebookStore(root:root)
    #expect(try reopened.readElementErasures(on:.page(pageID),elementID:"box").count == 1)
    #expect(try reopened.readElementErasures(on:surface,elementID:"box").count == 1)
    #expect(try reopened.currentReadCursor() == cursor)
    let undo = try page.prepareInkChange(.setActive([action.id],false),stamp:.init(counter:12,actor:actor))
    let undone = page.publishInkChange(undo); #expect(undone); try reopened.savePage(page)
    try reopened.commitSpatialInk(.state(actionID:spatial.id,creationStamp:spatial.stamp,expectedStateStamp: spatial.stateStamp, isActive:false,
      stateStamp:.init(counter:13,actor:actor),journalStamp:.init(counter:13,actor:actor)))
    #expect(try reopened.readElementErasures(on:.page(pageID),elementID:"box").isEmpty)
    #expect(try reopened.readElementErasures(on:surface,elementID:"box").isEmpty)
  }
}

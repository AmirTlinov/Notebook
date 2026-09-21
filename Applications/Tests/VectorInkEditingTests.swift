import NotebookCore
import XCTest
@testable import Notebook

@MainActor final class VectorInkEditingTests: XCTestCase {
  func testPreparedLassoSkipsMostMeasurementsAndDoesNotDependOnPixels() async throws {
    var actions: [PageInkAction] = []
    for stroke in 0..<400 {
      var samples: [SpatialInkSample] = []
      let x = Double(stroke%20)*400, y = Double(stroke/20)*100+20
      for i in 0..<250 {
        samples.append(.init(point:.init(x:x+Double(i),y:y),timeOffset:Double(i)/240,
          width:2,opacity:1,force:1,azimuth:0,altitude:1))
      }
      actions.append(.init(tool:.pen,samples:samples))
    }
    let drawing = PageInkDrawing(actions:actions)
    let page = PageDocument(size:.init(width:834,height:1194),actor:UUID(),drawingData:try drawing.dataRepresentation())
    let source = NotebookLassoInkSource.page(page)
    let cold = ContinuousClock.now
    let prepared = try source.prepare(surface:.page(page.id),origin:nil)
    let preparation = cold.duration(to:.now)
    let polygon = [SpatialPoint(x:90,y:15),.init(x:110,y:15),.init(x:110,y:25),.init(x:90,y:25)]
    var durations: [Double] = [], result: NotebookLassoInkSource.Result?
    for _ in 0..<15 {
      let start = ContinuousClock.now
      result = try prepared.selection(polygon:polygon,surface:.page(page.id),origin:nil,bounds:nil)
      let elapsed = start.duration(to:.now).components
      durations.append(Double(elapsed.seconds)*1000+Double(elapsed.attoseconds)/1e15)
    }
    let selected = try XCTUnwrap(result)
    XCTAssertEqual(selected.graphic.sourceInkIDs,[actions[0].id])
    XCTAssertEqual(selected.sourceSampleCount,100_000)
    XCTAssertLessThan(selected.candidateSampleCount,1000)
    XCTAssertTrue(selected.graphic.freehand?.layers.filter { $0.tool == .pen }.allSatisfy { $0.measured != nil } == true)
    let reused = try XCTUnwrap(prepared.selection(polygon:polygon,surface:.page(page.id),origin:nil,bounds:nil))
    XCTAssertEqual(reused.graphic,selected.graphic)
    XCTAssertEqual(try drawing.dataRepresentation(),page.drawingData)
    let appended=PageInkAction(tool:.pen,samples:(0..<250).map { i in
      .init(point:.init(x:10_000+Double(i),y:10_000),timeOffset:Double(i)/240,
        width:2,opacity:1,force:1,azimuth:0,altitude:1)
    })
    let nextDrawing=try drawing.appending(appended)
    let nextPage=PageDocument(id:page.id,size:page.size,actor:UUID(),drawingData:try nextDrawing.dataRepresentation())
    let incrementallyPrepared=try NotebookLassoInkSource.page(nextPage).prepare(
      surface:.page(nextPage.id),origin:nil,reusing:prepared)
    XCTAssertEqual(incrementallyPrepared.sourceSampleCount,100_250)
    XCTAssertEqual(incrementallyPrepared.reusedSampleCount,100_000,
      "Appending one stroke must retain the existing range forest instead of rebuilding it")
    let receipt: [String:Any] = ["sourceSamples":selected.sourceSampleCount,"candidateSamplesRead":selected.candidateSampleCount,
      "retainedSelectedSamples":actions[0].samples.count,"selectionMilliseconds":durations,
      "coldPrepareMilliseconds":Double(preparation.components.seconds)*1000+Double(preparation.components.attoseconds)/1e15]
    let attachment = XCTAttachment(data:try JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
    attachment.name = "vector-lasso-100k"; attachment.lifetime = .keepAlways; add(attachment)
  }

  func testMaskedMaterialNarrowsTheMetalSourceQueryBeforePreparingNodes() throws {
    let mask=NotebookGraphicMask().appending(.intersect,polygon:[
      .init(x:0.1,y:0.2),.init(x:0.2,y:0.2),.init(x:0.2,y:0.4),.init(x:0.1,y:0.4)])
    let content=NotebookInkMaterialView.Content(freehand:nil,erasures:[],transform:nil,layout:nil,mask:mask)
    let region=InkMaterialRenderer.queryRegion(content,region:.init(x:0,y:0,width:1000,height:500),
      sourceSize:.init(width:1000,height:500),density:2)
    XCTAssertEqual(region.minX,99.5,accuracy:1e-9);XCTAssertEqual(region.maxX,200.5,accuracy:1e-9)
    XCTAssertEqual(region.minY,99.5,accuracy:1e-9);XCTAssertEqual(region.maxY,200.5,accuracy:1e-9)

    let actor=UUID()
    var page=PageDocument(size:.init(width:1200,height:1200),actor:actor)
    let element=AgentElement(id:"masked",kind:.graphic,frame:.init(x:0,y:0,width:500,height:1000),source:"",html:"",
      graphic:.init(shape:.rectangle),basis:.init(size:.init(x:1000,y:500),
        transform:.init(a:0,b:1,c:-1,d:0,tx:1,ty:0)))
    XCTAssertTrue(page.replaceElements([element],actor:actor))
    let layout=try XCTUnwrap(page.graphicGraph().resolve(element.id).layout)
    let placed=NotebookInkMaterialView.Content(freehand:nil,erasures:[],transform:nil,layout:layout,mask:mask)
    let transformed=InkMaterialRenderer.queryRegion(placed,region:.init(x:0,y:0,width:500,height:1000),
      sourceSize:.init(width:500,height:1000),density:2)
    XCTAssertEqual(transformed.minX,299.5,accuracy:1e-9);XCTAssertEqual(transformed.maxX,400.5,accuracy:1e-9)
    XCTAssertEqual(transformed.minY,99.5,accuracy:1e-9);XCTAssertEqual(transformed.maxY,200.5,accuracy:1e-9)
  }

  func testVectorLassoReturnsAReadOnlyCompactRegion() throws {
    func sample(_ x: Double,_ y: Double,_ width: Double) -> SpatialInkSample {
      .init(point:.init(x:x,y:y),timeOffset:0,width:width,opacity:1,force:1,azimuth:0,altitude:1)
    }
    let pen = PageInkAction(tool:.pen,samples:[sample(20,50,4),sample(180,50,4)])
    let cut = PageInkAction(tool:.eraser,samples:[sample(100,20,20),sample(100,80,20)])
    let page = PageDocument(size:.init(width:200,height:100),actor:UUID(),drawingData:try PageInkDrawing(actions:[pen,cut]).dataRepresentation())
    let source = try NotebookLassoInkSource.page(page).prepare(surface:.page(page.id),origin:nil)
    func polygon(_ x: Double) -> [SpatialPoint] { [.init(x:x-2,y:45),.init(x:x+2,y:45),.init(x:x+2,y:55),.init(x:x-2,y:55)] }
    XCTAssertNil(try source.selection(polygon:polygon(100),surface:.page(page.id),origin:nil,bounds:nil))
    let selection = try XCTUnwrap(source.selection(polygon:polygon(40),surface:.page(page.id),origin:nil,bounds:nil))
    let ink = try XCTUnwrap(selection.graphic.freehand)
    XCTAssertEqual(selection.graphic.sourceInkIDs,[pen.id])
    XCTAssertTrue(ink.layers.filter { $0.tool == .pen }.allSatisfy { $0.measured != nil })
    XCTAssertTrue(ink.layers.contains { $0.tool == .eraser && $0.measured != nil })
    XCTAssertLessThan(selection.selectionFrame.x+selection.selectionFrame.width,50)
    XCTAssertLessThan(selection.frame.x,25)
    XCTAssertGreaterThan(selection.frame.x+selection.frame.width,175)
    let inside=NotebookGraphicMask().appending(.intersect,polygon:selection.polygon.map {
      .init(x:($0.x-selection.selectionFrame.x)/selection.selectionFrame.width,
        y:($0.y-selection.selectionFrame.y)/selection.selectionFrame.height)
    })
    XCTAssertFalse(inside.path(in:.init(x:0,y:0,width:1,height:1)).isEmpty)
  }
  func testSpatialWindowMembershipAndOriginAreNotConfusedWithOwnerRevision() throws {
    let board = UUID(), actor = UUID(), surface = SurfaceID.board(board)
    let stamp = VersionStamp(counter:1,actor:actor)
    let base = WorldPoint.zero.offsetBy(x:100_000,y:-300_000)
    func stroke(_ x: Double) -> SpatialInkAction {
      let samples: [SpatialInkSample] = [x,x+80].map {
        .init(point:.init(x:$0,y:40),worldPoint:base.offsetBy(x:$0,y:40),timeOffset:0,width:4,
          opacity:1,force:1,azimuth:0,altitude:1)
      }
      return .init(tool:.pen,spans:[.init(surface:surface,samples:samples)],stamp:stamp)
    }
    let a = stroke(20), b = stroke(400)
    let old = NotebookLassoInkSource.spatial(.init(actions:[a],stamp:stamp),[],membershipRevision:1)
    let new = NotebookLassoInkSource.spatial(.init(actions:[a,b],stamp:stamp),[],membershipRevision:2)
    XCTAssertNotEqual(old.cacheKey(surface:surface),new.cacheKey(surface:surface))
    let prepared = try new.prepare(surface:surface,origin:base)
    let origin = base.offsetBy(x:300,y:20)
    let polygon = [SpatialPoint(x:90,y:15),.init(x:190,y:15),.init(x:190,y:25),.init(x:90,y:25)]
    let result = try XCTUnwrap(prepared.selection(polygon:polygon,surface:surface,origin:origin,bounds:nil))
    XCTAssertEqual(result.graphic.sourceInkIDs,[b.id])
    XCTAssertEqual(result.frame.x,96.4,accuracy:0.001)
    XCTAssertEqual(result.frame.y,16.4,accuracy:0.001)
    let hidden = NotebookLassoInkSource.spatial(.init(actions:[a,b],stamp:stamp),[b.id],membershipRevision:2)
    XCTAssertEqual(hidden.cacheKey(surface:surface),new.cacheKey(surface:surface),"Presentation claims do not rebuild measured source")
    let projection = prepared.excluding([b.id])
    XCTAssertNil(try projection.selection(polygon:polygon,surface:surface,origin:origin,bounds:nil))
    XCTAssertNotNil(try prepared.selection(polygon:polygon,surface:surface,origin:origin,bounds:nil),"The frozen source remains immutable")
  }

}

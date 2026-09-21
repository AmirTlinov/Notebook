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
    let reused = try XCTUnwrap(prepared.selection(polygon:polygon,surface:.page(page.id),origin:nil,bounds:nil))
    XCTAssertEqual(reused.graphic,selected.graphic)
    XCTAssertEqual(try drawing.dataRepresentation(),page.drawingData)
    let receipt: [String:Any] = ["sourceSamples":selected.sourceSampleCount,"candidateSamplesRead":selected.candidateSampleCount,
      "retainedSelectedSamples":actions[0].samples.count,"selectionMilliseconds":durations,
      "coldPrepareMilliseconds":Double(preparation.components.seconds)*1000+Double(preparation.components.attoseconds)/1e15]
    let attachment = XCTAttachment(data:try JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
    attachment.name = "vector-lasso-100k"; attachment.lifetime = .keepAlways; add(attachment)
  }

  func testVectorLassoSeesOnlyRemainingPaintAndSharesWholeSource() throws {
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
    let geometry = ink.geometry
    let edited = try selection.graphic.applying(.object(["transform":try JSONValue.encode(NotebookGraphicTransform(a:0,b:1,c:-1,d:0,tx:1,ty:0))]))
    XCTAssertTrue(edited.freehand?.geometry === geometry)
    XCTAssertEqual(edited.freehand,ink)
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

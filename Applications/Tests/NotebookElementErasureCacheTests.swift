import CoreGraphics
import NotebookCore
import XCTest
@testable import Notebook

@MainActor final class NotebookElementErasureCacheTests: XCTestCase {
  private let surface = SurfaceID.page(UUID())
  private let frame = PageRect(x:100,y:200,width:160,height:100)
  private let graphic = NotebookGraphic(shape:.rectangle,style:.init(strokeWidth:4))

  private func cuts(full: Bool, count: Int = 2048) -> [InkElementErasure] {
    let samples = (0..<count).map { i in
      let angle = Double(i % 32)*2*Double.pi/32
      return SpatialInkSample(point:.init(x:100+2*cos(angle),y:250+40*sin(angle)),
        timeOffset:Double(i)/240,width:full ? 500 : 20,opacity:1,force:1,azimuth:0,altitude:1)
    }
    return [.init(target:.init(elementID:"shape",frame:frame),samples:samples)]
  }
  private func request(_ cache: NotebookElementErasureCache, _ cuts: [InkElementErasure],
    size: CGSize = .init(width:160,height:100), graphic: NotebookGraphic? = nil,
    layout: NotebookGraphicLayout? = nil) -> NotebookElementAppearance? {
    cache.appearance(surface:surface,id:"shape",graphic:graphic ?? self.graphic,layout:layout,size:size,erasures:cuts)
  }
  private func ready(_ cache: NotebookElementErasureCache, _ cuts: [InkElementErasure],
    size: CGSize = .init(width:160,height:100), graphic: NotebookGraphic? = nil,
    layout: NotebookGraphicLayout? = nil) async throws -> NotebookElementAppearance {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
      if let result = request(cache,cuts,size:size,graphic:graphic,layout:layout) { return result }
      try await Task.sleep(for:.milliseconds(5))
    }
    throw NSError(domain:"appearance_timeout",code:1)
  }

  func testDensePreparationYieldsMainAndReusesOneValueForPaintPickAndCamera() async throws {
    let cache = NotebookElementErasureCache(), cuts = cuts(full:false,count:8192)
    let start = ContinuousClock.now
    for _ in 0..<30 { XCTAssertNil(request(cache,cuts)) }
    XCTAssertLessThan(start.duration(to:.now),.milliseconds(100),"No boolean geometry in a synchronous UI request")
    XCTAssertEqual(cache.preparationCount,1)
    let prepared = try await ready(cache,cuts)
    XCTAssertEqual(prepared.state,.partial)
    XCTAssertFalse(prepared.contains(.init(x:0,y:50),tolerance:6))
    XCTAssertTrue(prepared.contains(.init(x:160,y:50),tolerance:6))
    for offset in [0.0,1000,-1000] {
      let graph = NotebookGraphicGraph([.init(id:"shape",graphic:graphic,
        frame:.init(x:offset,y:offset,width:160,height:100),surface:surface,shown:true)])
      let reused = try XCTUnwrap(request(cache,cuts,layout:graph.resolve("shape").layout))
      XCTAssertTrue(reused.mask === prepared.mask)
      XCTAssertTrue(reused.remaining === prepared.remaining)
    }
    XCTAssertEqual(cache.preparationCount,1,"Translation is not a content revision")
    await cache.stop()
  }

  func testNewEraseResizeStyleAndUndoNeverReturnAnOldProjection() async throws {
    let cache = NotebookElementErasureCache(), full = cuts(full:true), partial = cuts(full:false)
    XCTAssertNil(request(cache,full))
    XCTAssertNil(request(cache,partial),"Supersede pending full erase")
    let result = try await ready(cache,partial)
    XCTAssertEqual(result.state,.partial)
    XCTAssertEqual(cache.preparationCount,2)
    let resized = CGSize(width:320,height:200)
    XCTAssertNil(request(cache,partial,size:resized))
    let big = try await ready(cache,partial,size:resized)
    XCTAssertFalse(big.contains(.init(x:0,y:100),tolerance:6))
    XCTAssertTrue(big.contains(.init(x:320,y:100),tolerance:6))
    var filled = graphic; filled.style.fill = .black
    XCTAssertNil(request(cache,partial,size:resized,graphic:filled))
    let fill = try await ready(cache,partial,size:resized,graphic:filled)
    XCTAssertTrue(fill.contains(.init(x:160,y:100),tolerance:0))
    XCTAssertNil(request(cache,[]),"Undo to intact uses the ordinary unmasked source")
    XCTAssertNil(request(cache,full))
    let erased = try await ready(cache,full)
    XCTAssertEqual(erased.state,.erased)
    XCTAssertFalse(erased.contains(.init(x:80,y:50),tolerance:12))
    await cache.stop()
    XCTAssertNil(request(cache,partial),"Stopped model cannot restart derived work")
  }

  func testMountedSiblingsNeverEvictEachOtherAndUnloadedOwnersReleaseWork() async throws {
    let cache = NotebookElementErasureCache(), cuts = cuts(full:false,count:32)
    func value(_ i: Int) -> NotebookElementAppearance? {
      cache.appearance(surface:surface,id:"shape-\(i)",graphic:graphic,layout:nil,
        size:.init(width:160,height:100),erasures:cuts)
    }
    for i in 0..<160 { XCTAssertNil(value(i)) }
    let deadline = ContinuousClock.now + .seconds(10)
    while (0..<160).contains(where: { value($0) == nil }), ContinuousClock.now < deadline {
      try await Task.sleep(for:.milliseconds(10))
    }
    for i in 0..<160 { XCTAssertNotNil(value(i)) }
    XCTAssertEqual(cache.preparationCount,160,"A mounted workset must not churn at a cache-count threshold")
    cache.retain(pages:[:])
    XCTAssertNil(value(0),"Unloading an owner releases its derived paths")
    XCTAssertEqual(cache.preparationCount,161)
    await cache.stop()
  }

  func testQuickShapeBindingUsesTheSamePreparedCutout() async throws {
    let cache = NotebookElementErasureCache(), partial = cuts(full:false), full = cuts(full:true)
    let graph = NotebookGraphicGraph([.init(id:"shape",graphic:graphic,frame:frame,surface:surface,shown:true)])
    let fit = NotebookQuickShapeFit(frame:.init(x:260,y:250,width:50,height:1),sampleCount:2,
      connection:.init(start:.init(point:.zero),end:.init(point:.init(x:50,y:0))))
    func bind(_ cuts: [InkElementErasure]) -> NotebookQuickShapeFit {
      fit.binding(in:graph,surface:surface,tolerance:6,erasures:["shape":cuts],appearance: { id,graphic,size,cuts in
        cache.appearance(surface:surface,id:id,graphic:graphic,layout:nil,size:size,erasures:cuts)
      })
    }
    XCTAssertNil(bind(partial).connection?.start.binding,"Pending is not permission to bind to erased geometry")
    _ = try await ready(cache,partial)
    XCTAssertEqual(bind(partial).connection?.start.binding?.elementID,"shape")
    XCTAssertEqual(cache.preparationCount,1)
    XCTAssertNil(bind(full).connection?.start.binding)
    _ = try await ready(cache,full)
    XCTAssertNil(bind(full).connection?.start.binding)
    XCTAssertEqual(cache.preparationCount,2)
    await cache.stop()
  }

  func testConnectorLocalGeometryInvalidatesButOwnerTranslationDoesNot() async throws {
    let cache = NotebookElementErasureCache()
    var line = NotebookGraphic(shape:.connector,connection:.init(start:.init(point:.init(x:0,y:0)),end:.init(point:.init(x:140,y:80))))
    func layout(_ graphic: NotebookGraphic, offset: Double = 0) throws -> NotebookGraphicLayout {
      let graph = NotebookGraphicGraph([.init(id:"shape",graphic:graphic,
        frame:.init(x:offset,y:offset,width:160,height:100),surface:surface,shown:true)])
      return try XCTUnwrap(graph.resolve("shape").layout)
    }
    let first = try layout(line), cuts = cuts(full:false)
    let size = CGSize(width:first.frame.width,height:first.frame.height)
    _ = try await ready(cache,cuts,size:size,graphic:line,layout:first)
    let moved = try layout(line,offset:500)
    XCTAssertNotNil(request(cache,cuts,size:size,graphic:line,layout:moved))
    XCTAssertEqual(cache.preparationCount,1)
    line.connection?.bend = 30
    let changed = try layout(line)
    XCTAssertNil(request(cache,cuts,size:size,graphic:line,layout:changed))
    _ = try await ready(cache,cuts,size:size,graphic:line,layout:changed)
    XCTAssertEqual(cache.preparationCount,2)
    await cache.stop()
  }
}

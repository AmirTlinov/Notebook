import Foundation
import Testing
@testable import NotebookCore

@Suite struct InkDisplayNormalizationTests {
  private func sample(_ i:Int,x:Double,y:Double = 0) -> SpatialInkSample {
    .init(point:.init(x:x,y:y),timeOffset:Double(i)/1000,width:2+Double(i%7),
      opacity:0.2+Double(i%5)/10,force:Double(i%11)/10,azimuth:0,altitude:1)
  }
  private func source(_ points:[SpatialInkSample],tool:SpatialInkTool = .pen) -> InkSampleRelations {
    .init(sourceID:UUID(),revision:UUID(),samples:points,header:.init(tool:tool,color:.black))
  }
  private func nodes(_ display:SpatialInkGeometry.RelativeSource) -> [SpatialInkGeometry.Node] {
    (0..<display.chunkCount).flatMap { i in
      let value=display.prepare(i..<(i+1)).chunk.nodes
      return i == 0 ? Array(value) : Array(value.dropFirst())
    }
  }

  @Test func distantNearPairPreparesOnlyItsBranchAndKeepsCameraQueryLocal() throws {
    var points=(0..<100_000).map { sample($0,x:Double($0)/4,y:sin(Double($0)/30)*12) }
    let control=try #require(SpatialInkGeometry.RelativeSource(source(points),projection:.init()))
    let index=99_001
    points[index]=sample(index,x:points[index-1].point.x+0.001,y:points[index-1].point.y)
    let raw=source(points),original=try raw.encodedRelations()
    let display=try #require(SpatialInkGeometry.RelativeSource(raw,projection:.init()))
    #expect(display.source.measurements == raw.measurements)
    #expect(display.normalizationCost.decodedSamples < 600)
    #expect(display.normalizationCost.visitedNodes < 100)
    let view=SpatialInkGeometry.Source(source:raw,projection:.init())
    #expect(view.preparedNodeCount == 0)
    #expect(view.auxiliaryBytes < 64_000)
    let query=display.query(viewport:.init(x:1000,y:-20,width:50,height:40),allowRangeCoalescing:false)
    let read=query.chunks.reduce(0) { $0+display.prepare($1).decodedPoints }
    let controlQuery=control.query(viewport:.init(x:1000,y:-20,width:50,height:40),allowRangeCoalescing:false)
    let controlRead=controlQuery.chunks.reduce(0) { $0+control.prepare($1).decodedPoints }
    #expect(query.cost.visitedNodes <= controlQuery.cost.visitedNodes+64)
    #expect(read <= controlRead+2)
    #expect(nodes(display) == SpatialInkGeometry.compact(source:raw))
    #expect(try raw.encodedRelations() == original,"Display normalization must not rewrite accepted measurements")
    print("LOCAL_NORMALIZATION count=100000 visited=\(display.normalizationCost.visitedNodes) decoded=\(display.normalizationCost.decodedSamples) auxiliaryBytes=\(view.auxiliaryBytes) cameraDecoded=\(read) controlCameraDecoded=\(controlRead) visits=\(query.cost.visitedNodes)/\(controlQuery.cost.visitedNodes)")
  }

  @Test(arguments:[SpatialInkTool.pen,.eraser])
  func collapsingRunsAndReturningContoursKeepCanonicalTangentsAndOpacity(tool:SpatialInkTool) throws {
    // Retained endpoints are identical even though distinct raw groups survive.
    // A second normalization or a stationary-source shortcut would erase one.
    let returning=source([sample(0,x:0),sample(1,x:0.011),sample(2,x:0.002),sample(3,x:0)],tool:tool)
    let tiny=try #require(SpatialInkGeometry.RelativeSource(returning,projection:.init()))
    #expect(nodes(tiny) == SpatialInkGeometry.compact(source:returning))
    #expect(nodes(tiny).count == 2)

    var points=(0..<2050).map { sample($0,x:Double($0)/2,y:cos(Double($0)/9)) }
    // A collapsed run crosses leaves and virtual GPU chunk boundaries.
    for i in 250..<1300 { points[i]=sample(i,x:125+Double(i-250)/4096,y:points[249].point.y) }
    let raw=source(points,tool:tool)
    for projection in [InkSampleProjection(),.init(offset:.init(x:100,y:40),scale:0.1),.init(scale:16)] {
      let display=try #require(SpatialInkGeometry.RelativeSource(raw,projection:projection))
      #expect(nodes(display) == SpatialInkGeometry.compact(source:raw,offset:projection.offset,scale:projection.scale))
      #expect(display.source.count == points.count)
    }
  }

  @Test func worldFloatCoalescingUsesExactTiledProjectionWithoutMutatingTheSource() throws {
    let origin=WorldPoint(tileX:WorldPoint.maximumTileIndex-100,tileY:-WorldPoint.maximumTileIndex+100,localX:20,localY:40)
    let points=(0..<1025).map { i in
      let p=sample(i,x:Double(i)/10,y:sin(Double(i)))
      return SpatialInkSample(point:p.point,worldPoint:origin.offsetBy(x:Double(i),y:sin(Double(i))),
        timeOffset:p.timeOffset,width:p.width,opacity:p.opacity,force:p.force,azimuth:p.azimuth,altitude:p.altitude)
    }
    let raw=source(points)
    for camera in [origin,origin.offsetBy(x:-1_000_000_000,y:-1_000_000_000)] {
      let display=try #require(SpatialInkGeometry.RelativeSource(raw,projection:.init(origin:camera)))
      #expect(nodes(display) == SpatialInkGeometry.compact(source:raw,origin:camera))
    }
    let reopened=try InkSampleRelations(encodedRelations:raw.encodedRelations())
    for i in points.indices { #expect(InkSampleRelations.sameBits(points[i],reopened.sample(at:i))) }
  }

  @Test(arguments:[SpatialInkTool.pen,.eraser])
  func repeatedCoincidentSeamsKeepTheirSharedBodyAndExactPaint(tool:SpatialInkTool) throws {
    let body=source((0..<100).map { i in
      let p=sample(i,x:Double(i),y:Double(i%9))
      return SpatialInkSample(point:p.point,timeOffset:Double(i)/128,width:p.width,opacity:p.opacity,
        force:p.force,azimuth:p.azimuth,altitude:p.altitude)
    },tool:tool)
      .settingExit(.init(x:InkDyadic(99)!,y:.zero,time:.one),revision:UUID())
    let small=try #require(body.repeated(10,revision:UUID()))
    let display=try #require(SpatialInkGeometry.RelativeSource(small,projection:.init()))
    #expect(nodes(display) == SpatialInkGeometry.compact(source:small))
    let million=try #require(body.repeated(10_000,revision:UUID()))
    let large=try #require(SpatialInkGeometry.RelativeSource(million,projection:.init()))
    #expect(large.normalizationCost.visitedNodes < 10)
    #expect(large.normalizationCost.decodedSamples < 10)
    #expect(SpatialInkGeometry.Source(source:million,projection:.init()).auxiliaryBytes < 64_000)
    #expect(large.source.measurements == million.measurements)
    let query=large.query(viewport:.init(x:1000,y:-10,width:50,height:30),allowRangeCoalescing:false)
    let decoded=query.chunks.reduce(0) { $0+large.prepare($1).decodedPoints }
    #expect(decoded < 1000)
    print("REPEAT_SEAM_NORMALIZATION tool=\(tool) events=\(million.count) visited=\(large.normalizationCost.visitedNodes) decoded=\(large.normalizationCost.decodedSamples) cameraDecoded=\(decoded)")
  }
}

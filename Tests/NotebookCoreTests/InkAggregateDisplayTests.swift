import Foundation
import Testing
@testable import NotebookCore

@Suite struct InkAggregateDisplayTests {
  private func sample(_ i: Int,x: Double? = nil,y: Double = 10,width: Double = 4,opacity: Double = 0.5) -> SpatialInkSample {
    .init(point:.init(x:x ?? Double(i),y:y),timeOffset:Double(i)/128,width:width,opacity:opacity,
      force:Double(i%5)/4,azimuth:Double(i%9)/4,altitude:1)
  }
  private func source(_ samples: [SpatialInkSample],tool: SpatialInkTool = .pen) -> InkSampleRelations {
    .init(sourceID:UUID(),revision:UUID(),samples:samples,header:.init(tool:tool,color:.black))
  }
  @Test(arguments:[10_000,100_000,1_000_000])
  func entireRepeatStopsAtItsAggregateAndRetainsEveryExactEvent(count: Int) throws {
    let body=source((0..<100).map { sample($0) })
      .settingExit(.init(x:InkDyadic(100)!,y:.zero,time:.one),revision:UUID())
    let original=try #require(body.repeated(count/100,revision:UUID()))
    for value in [original,try InkSampleRelations(encodedRelations:original.encodedRelations())] {
      let display=SpatialInkGeometry.Source(source:value,projection:.init())
      #expect(display.preparedNodeCount == 0)
      #expect(display.chunkCount == 1)
      let query=display.query(viewport:.init(x:-10,y:0,width:Double(count)+20,height:20),affine:.init())
      #expect(query.chunks == [0]);#expect(query.cost.visitedNodes == 1);#expect(query.cost.decodedSamples == 0)
      let prepared=display.prepare(0)
      #expect(prepared.decodedPoints == 4);#expect(prepared.chunk.nodes.count == 4)
      #expect(prepared.chunk.nodes.map(\.position.x) == [0,1,Float(count-2),Float(count-1)])
      #expect(prepared.chunk.nodes.allSatisfy { $0.edge == .init(0,2) && $0.alpha == 0.5 })
      #expect(value.allocationSummary.nodes == 2)
      for i in [0,1,count/2,count-1] {
        let expected=InkRepeatStep(x:InkDyadic(Double(i/100*100))!,y:.zero,time:InkDyadic(Double(i/100))!).apply(body.sample(at:i%100))
        #expect(InkSampleRelations.sameBits(value.sample(at:i),expected))
      }
    }
  }
  @Test(arguments:[0,1,2,3,4])
  func localShapeOpacityAndFoldInvalidateOnlyTheNewSource(feature: Int) throws {
    let original=source((0..<4097).map { sample($0) })
    #expect(original.geometry.isUniformAxisStrip)
    let index=2048
    let changed: SpatialInkSample
    switch feature {
    case 0: changed=sample(index,y:14)
    case 1: changed=sample(index,width:12)
    case 2: changed=sample(index,opacity:0.9)
    case 3: changed=sample(index,x:Double(index-10))
    default: changed=sample(index,x:Double(index-1))
    }
    let edited=try original.editing(original.address(at:index),to:changed,revision:UUID())
    #expect(!edited.geometry.isUniformAxisStrip)
    #expect(original.geometry.isUniformAxisStrip)
    #expect(InkSampleRelations.sameBits(edited.sample(at:index),changed))
    let nodes=SpatialInkGeometry.compact(source:edited)
    let control=SpatialInkGeometry.renderPoint(from:changed,color:.init(repeating:1))
    #expect(nodes.contains { $0.position == control.position && $0.radius == control.radius && $0.alpha == control.premultipliedColor.w })
    #expect(SpatialInkGeometry.compact(source:original).count == 4)
    let restored=try edited.editing(edited.address(at:index),to:original.sample(at:index),revision:UUID())
    #expect(restored.geometry.isUniformAxisStrip)
    #expect(SpatialInkGeometry.compact(source:restored).count == 4)
  }
  @Test(arguments:[false,true],[false,true])
  func bothAxisDirectionsComposeAcrossUnevenLeaves(vertical: Bool,reverse: Bool) {
    let samples=(0..<1025).map { i in
      let t=Double(i)*(reverse ? -2 : 2)
      return sample(i,x:vertical ? 10 : t,y:vertical ? t : 10)
    }
    let value=source(samples),display=SpatialInkGeometry.Source(source:value,projection:.init())
    #expect(value.geometry.isUniformAxisStrip);#expect(display.chunkCount == 1)
    #expect(display.prepare(0).decodedPoints == 4)
    #expect(SpatialInkGeometry.compact(source:source(samples,tool:.eraser)).count == samples.count)
  }
  @Test func repeatSeamsAndNumericalCoalescingRemainUnreduced() throws {
    let body=source((0..<100).map { sample($0) })
    for step in [0.0,99,50] {
      let repeated=try #require(body.settingExit(.init(x:InkDyadic(step)!,y:.zero,time:.one),revision:UUID()).repeated(100,revision:UUID()))
      #expect(!repeated.geometry.isUniformAxisStrip)
      #expect(SpatialInkGeometry.Source(source:repeated,projection:.init()).chunkCount > 1)
    }
    let close=source((0..<1000).map { sample($0,x:Double($0)/8192) })
    #expect(SpatialInkGeometry.RelativeSource(close,projection:.init()) == nil)
    var indices:[Int]=[]
    close.forEachIndexedDisplayPoint { i,_,_,_ in indices.append(i) }
    #expect(indices.count == close.count)
    #expect(!body.geometry.canReduceAxisStrip(minimumSpacing:0,maximumSpan:1))
  }
  @Test func axisRailsStayExactUnderLargeStretch() throws {
    let body=source((0..<100).map { sample($0,y:0) })
      .settingExit(.init(x:InkDyadic(100)!,y:.zero,time:.one),revision:UUID())
    let repeated=try #require(body.repeated(1000,revision:UUID()))
    let edited=try repeated.editing(repeated.address(at:50_000),to:sample(50_000,y:0,opacity:0.75),revision:UUID())
    for value in [repeated,edited] {
      let display=SpatialInkGeometry.Source(source:value,projection:.init())
      for nodes in [Array(display.prepare(0).chunk.nodes),SpatialInkGeometry.compact(source:value)] {
        #expect(nodes.count >= 2)
        for node in nodes { #expect((node.position.y+node.edge.y)*1_000_000-2_000_000+64 == 64) }
      }
    }
    // The proof also admits irregular literal spacings: their unreduced rails
    // must have the same exact normal, not length-dependent reciprocal error.
    for sign: Float in [-1,1] {
      for vertical in [false,true] {
        let points:[SpatialInkGeometry.RenderPoint]=[Float(0),0.125,3.14,99997,100000,100001].map { d in
          .init(position:vertical ? .init(0,d*sign) : .init(d*sign,0),radius:2,premultipliedColor:.init(repeating:0.5))
        }
        for i in points.indices {
          let n=InkRenderGeometry.node(at:i,in:points)
          #expect(n.edge == (vertical ? .init(-2*sign,0) : .init(0,2*sign)))
        }
      }
    }
  }
  @Test(arguments:[false,true],[false,true])
  func worldStripsKeepTiledCoordinatesAndExactEdits(vertical: Bool,reverse: Bool) throws {
    let origin=WorldPoint(tileX:WorldPoint.maximumTileIndex-1000,tileY:-WorldPoint.maximumTileIndex+1000,localX:20,localY:40)
    let samples=(0..<4097).map { i in
      let d=Double(i)*(reverse ? -2 : 2)
      return SpatialInkSample(point:.init(x:Double(i)/4,y:sin(Double(i))),
        worldPoint:origin.offsetBy(x:vertical ? 0 : d,y:vertical ? d : 0),timeOffset:Double(i)/128,
        width:4,opacity:0.5,force:Double(i%5)/4,azimuth:Double(i%9)/4,altitude:1)
    }
    let original=source(samples)
    for value in [original,try InkSampleRelations(encodedRelations:original.encodedRelations())] {
      #expect(value.geometry.isUniformAxisStrip)
      let display=SpatialInkGeometry.Source(source:value,projection:.init(origin:origin))
      #expect(display.chunkCount == 1)
      let prepared=display.prepare(0)
      #expect(prepared.decodedPoints == 4)
      let retained=[0,1,4095,4096]
      for (node,index) in zip(prepared.chunk.nodes,retained) {
        let p=origin.delta(to:samples[index].worldPoint!)
        #expect(node.position == .init(Float(p.x),Float(p.y)))
        #expect(InkSampleRelations.sameBits(value.sample(at:index),samples[index]))
      }
      // Without a world projection the existing API displays sample.point;
      // that unrelated, curved coordinate must not inherit the world proof.
      var unprojected=0
      value.forEachDisplayPoint { _,_,_ in unprojected += 1 }
      #expect(unprojected == samples.count)
      let remote=origin.offsetBy(x:-1_000_000_000,y:-1_000_000_000)
      var far=0
      value.forEachDisplayPoint(origin:remote) { _,_,_ in far += 1 }
      #expect(far == samples.count,"Float coalescing must use the requested projection, not the first event's origin")
      #expect(SpatialInkGeometry.RelativeSource(value,projection:.init(origin:remote)) == nil)
    }
    let i=2048,p=samples[i]
    let bend=SpatialInkSample(point:p.point,worldPoint:p.worldPoint!.offsetBy(x:vertical ? 8 : 0,y:vertical ? 0 : 8),
      timeOffset:p.timeOffset,width:p.width,opacity:p.opacity,force:p.force,azimuth:p.azimuth,altitude:p.altitude)
    let edited=try original.editing(original.address(at:i),to:bend,revision:UUID())
    #expect(!edited.geometry.isUniformAxisStrip)
    let restored=try edited.editing(edited.address(at:i),to:p,revision:UUID())
    #expect(restored.geometry.isUniformAxisStrip)
    #expect(InkSampleRelations.sameBits(restored.sample(at:i),p))
  }

}

import Foundation
import simd
import Testing
@testable import NotebookCore

@Suite struct InkCurveSummaryTests {
  private func sample(_ i: Int,width: Double = 256,opacity: Double = 1) -> SpatialInkSample {
    .init(point:.init(x:Double(i)/32,y:sin(Double(i)*Double.pi/32)/1024),timeOffset:Double(i)/128,
      width:width,opacity:opacity,force:Double(i%5)/4,azimuth:Double(i%9)/4,altitude:1)
  }
  private func source(_ samples: [SpatialInkSample],tool: SpatialInkTool = .pen) -> InkSampleRelations {
    .init(sourceID:UUID(),revision:UUID(),samples:samples,header:.init(tool:tool,color:.black))
  }
  @Test(arguments:[10_000,100_000,1_000_000])
  func visibleCurveRepeatChoosesItsDetailBeforeReadingEvents(count: Int) throws {
    let body=source((0..<100).map { sample($0) }).settingExit(.init(x:InkDyadic(100.0/32)!,y:.zero,time:.one),revision:UUID())
    let value=try #require(body.repeated(count/100,revision:UUID()))
    for source in [value,try InkSampleRelations(encodedRelations:value.encodedRelations())] {
      let display=SpatialInkGeometry.Source(source:source,projection:.init())
      let query=display.query(viewport:.infinite,affine:.init(),detail:.init(pixelsPerUnit:0.01,minimumPixelsPerUnit:0.01))
      #expect(query.chunks == [0..<display.chunkCount])
      #expect(query.cost.decodedSamples == 2)
      let p=display.prepare(try #require(query.chunks.first))
      #expect(p.chunk.nodes.count == 4);#expect(p.decodedPoints <= 8)
      #expect(display.preparedNodeCount == 0)
      let exact=display.query(viewport:.infinite,affine:.init())
      #expect(exact.chunks.count == display.chunkCount)
      #expect(source.allocationSummary.nodes == 2)
      #expect(source.sample(at:count-1) == value.sample(at:count-1))
    }
  }
  @Test func curvedRangesKeepOriginalRailsAndRespectTheScreenBudget() throws {
    let samples=(0..<10_000).map { i -> SpatialInkSample in
      let p=sample(i,width:128+Double(i%17)/64)
      return .init(point:.init(x:p.point.x,y:8*sin(Double(i)/10000*Double.pi)),timeOffset:p.timeOffset,
        width:p.width,opacity:1,force:p.force,azimuth:p.azimuth,altitude:p.altitude)
    }
    let value=source(samples),display=SpatialInkGeometry.Source(source:value,projection:.init())
    let query=display.query(viewport:.infinite,affine:.init(),detail:.init(pixelsPerUnit:0.02,minimumPixelsPerUnit:0.02))
    #expect(query.chunks.contains { $0.count > 1 })
    let points=samples.map { SpatialInkGeometry.renderPoint(from:$0,color:.init(repeating:1)) }
    let full=points.indices.map { InkRenderGeometry.node(at:$0,in:points) }
    guard case .relative(let r)=display.storage else { Issue.record("Expected lazy source");return }
    for selection in query.chunks where selection.count > 1 {
      let range=r.range(at:selection),kept=[range.lowerBound,range.lowerBound+1,range.upperBound-2,range.upperBound-1]
      let prepared=Array(display.prepare(selection).chunk.nodes)
      #expect(prepared == kept.map { full[$0] })
      let a=prepared[1],b=prepared[2],chord=b.position-a.position
      for i in (kept[1]+1)..<kept[2] {
        let t=simd_dot(full[i].position-a.position,chord)/simd_length_squared(chord)
        #expect(t >= 0 && t <= 1)
        let center=a.position+(b.position-a.position)*t,edge=a.edge+(b.edge-a.edge)*t
        let error=max(simd_length(full[i].position+full[i].edge-center-edge),simd_length(full[i].position-full[i].edge-center+edge))
        #expect(error*0.02 <= InkRenderGeometry.pixelError)
      }
    }
  }
  @Test func aTinyOpaqueBodyBuildsTheCertificateOnlyForItsAggregate() throws {
    let samples=(0..<2).map { i in SpatialInkSample(point:.init(x:Double(i)*8,y:Double(i)*2),timeOffset:Double(i)/8,
      width:256,opacity:1,force:1,azimuth:0,altitude:1) }
    let body=source(samples).settingExit(.init(x:InkDyadic(16)!,y:InkDyadic(4)!,time:.one),revision:UUID())
    #expect(body.geometry.curve == nil)
    let repeated=try #require(body.repeated(5000,revision:UUID()))
    #expect(repeated.geometry.curve != nil)
    let display=SpatialInkGeometry.Source(source:repeated,projection:.init())
    let q=display.query(viewport:.infinite,affine:.init(),detail:.init(pixelsPerUnit:0.01,minimumPixelsPerUnit:0.01))
    #expect(q.chunks == [0..<display.chunkCount])
    #expect(display.prepare(try #require(q.chunks.first)).chunk.nodes.count == 4)
  }
  @Test func localEditUpdatesTheCertificateWithoutExpandingItsNeighbours() throws {
    let body=source((0..<100).map { sample($0) }).settingExit(.init(x:InkDyadic(100.0/32)!,y:.zero,time:.one),revision:UUID())
    let original=try #require(body.repeated(10_000,revision:UUID())),index=500_000
    let old=original.sample(at:index)
    let changed=SpatialInkSample(point:.init(x:old.point.x,y:20),timeOffset:old.timeOffset,width:old.width,opacity:0.5,
      force:old.force,azimuth:old.azimuth,altitude:old.altitude)
    let edited=try original.editing(original.address(at:index),to:changed,revision:UUID())
    let display=SpatialInkGeometry.Source(source:edited,projection:.init())
    let q=display.query(viewport:.infinite,affine:.init(),detail:.init(pixelsPerUnit:0.01,minimumPixelsPerUnit:0.01))
    #expect(q.chunks.contains { $0.count > 1 });#expect(q.chunks.count < 100)
    let prepared=q.chunks.map { display.prepare($0) }
    #expect(prepared.reduce(q.cost.decodedSamples) { $0+$1.decodedPoints } < 10_000)
    #expect(prepared.contains { $0.chunk.nodes.contains { $0.position == .init(Float(old.point.x),20) && $0.alpha == 0.5 } })
    #expect(original.sample(at:index) == old);#expect(edited.sample(at:index) == changed)
  }
  @Test(arguments:[0,1,2,3])
  func uncertainCompositionThinInkFoldsAndZoomStayDetailed(feature: Int) {
    var samples=(0..<2049).map { sample($0,width:feature == 1 ? 4 : 256,opacity:feature == 0 ? 0.5 : 1) }
    if feature == 2 {
      samples=(0..<2049).map { i in
        let p=sample(i)
        return .init(point:.init(x:Double(i%2),y:p.point.y),timeOffset:p.timeOffset,width:p.width,opacity:1,
          force:p.force,azimuth:p.azimuth,altitude:p.altitude)
      }
    }
    let display=SpatialInkGeometry.Source(source:source(samples),projection:.init())
    let scale:Float=feature == 3 ? 1000 : 0.01
    let q=display.query(viewport:.infinite,affine:.init(),detail:.init(pixelsPerUnit:scale,minimumPixelsPerUnit:scale))
    #expect(q.chunks.allSatisfy { $0.count == 1 })
  }
}

import Foundation
import Testing
@testable import NotebookCore

@Suite struct InkShortBodyTests {
  @Test(arguments:[0,1,2,3,4],[false,true])
  func primitiveFactsAndCodecDoNotRequireAStoredSummary(count: Int,world: Bool) throws {
    let origin=WorldPoint(tileX:1_000_000,tileY:-1_000_000,localX:20,localY:30)
    let samples=(0..<count).map { i in SpatialInkSample(
      point:.init(x:i == 0 ? -0.0 : Double(i)*8,y:Double(i)*2),
      worldPoint:world ? origin.offsetBy(x:Double(i)*8,y:Double(i)*2) : nil,
      timeOffset:Double(i)/8,width:4,opacity:i == 0 ? 0 : 0.5,force:0.75,azimuth:-0.0,altitude:1) }
    let source=InkSampleRelations(sourceID:UUID(),revision:UUID(),samples:samples,header:.init(tool:.pen,color:.black))
    let bytes=try source.encodedRelations(),restored=try InkSampleRelations(encodedRelations:bytes)
    for body in [source,restored] {
      #expect(body.storage.root.hasStoredSummary == (count >= 4))
      #expect(body.measurements.isPaper == (!world || count == 0))
      #expect(body.measurements.isWorld == (world || count == 0))
      #expect(body.measurements.hasVisibleInk == (count > 1))
      #expect(body.geometry.stationary == (count < 2))
      if count > 1 { #expect(abs(body.geometry.minimumSpacing-hypot(8,2)) < 1e-12) }
      for i in samples.indices { #expect(InkSampleRelations.sameBits(body.sample(at:i),samples[i])) }
      #expect(try body.encodedRelations() == bytes)
      if count > 0 {
        let replacement=SpatialInkSample(point:.init(x:4,y:6),worldPoint:world ? origin : nil,
          timeOffset:0,width:8,opacity:1,force:0.5,azimuth:0,altitude:1)
        let edited=try body.editing(body.address(at:0),to:replacement,revision:UUID())
        #expect(InkSampleRelations.sameBits(edited.sample(at:0),replacement))
        #expect(InkSampleRelations.sameBits(body.sample(at:0),samples[0]))
      }
    }
  }

  @Test func shortPrimitiveStillProvesExactRepeatAndRejectsUnrepresentableShift() throws {
    let samples=(0..<2).map { i in SpatialInkSample(point:.init(x:Double(i),y:0),timeOffset:Double(i)/8,
      width:4,opacity:0.5,force:0.75,azimuth:0,altitude:1) }
    let body=InkSampleRelations(sourceID:UUID(),revision:UUID(),samples:samples,header:.init(tool:.pen,color:.black))
    let repeated=try #require(body.settingExit(.init(x:InkDyadic(2)!,y:.zero,time:.one),revision:UUID()).repeated(500_000,revision:UUID()))
    #expect(repeated.count == 1_000_000)
    #expect(repeated.allocationSummary.nodes == 2)
    #expect(repeated.storage.root.hasStoredSummary)
    let last=try repeated.access(repeated.address(at:999_999))
    #expect(last.sample.point.x == 999_999 && last.sample.timeOffset == 499_999.125)
    #expect(last.cost.decodedSamples == 1)
    let edge=SpatialInkSample(point:.init(x:.leastNonzeroMagnitude,y:0),timeOffset:0,
      width:1,opacity:1,force:1,azimuth:0,altitude:1)
    let unproved=InkSampleRelations(sourceID:UUID(),revision:UUID(),samples:[edge],header:.init(tool:.pen,color:.black))
      .settingExit(.init(x:.one,y:.zero,time:.zero),revision:UUID())
    #expect(unproved.repeated(2,revision:UUID()) == nil)
  }

  @Test(arguments:[1025,1028,511],[false,true])
  func residualLeavesDoNotRetainTheWholePreCompressionArray(count: Int,world: Bool) throws {
    var rng: UInt64=0x56abb541
    func random()->Double { rng ^= rng<<13;rng ^= rng>>7;rng ^= rng<<17;return Double(rng & 0xffff_ffff)/Double(UInt32.max) }
    let samples=(0..<count).map { i in SpatialInkSample(point:.init(x:random()*500,y:random()*500),
      worldPoint:world ? WorldPoint.zero.offsetBy(x:Double(i),y:0) : nil,
      timeOffset:Double(i)/128,width:4,opacity:random(),force:1,azimuth:0,altitude:1) }
    let source=InkSampleRelations(sourceID:UUID(),revision:UUID(),samples:samples,header:.init(tool:.pen,color:.black))
    #expect(source.payloadBytes < samples.capacity*MemoryLayout<SpatialInkSample>.stride*11/10)
    let restored=try InkSampleRelations(encodedRelations:source.encodedRelations())
    for i in samples.indices {
      #expect(InkSampleRelations.sameBits(source.sample(at:i),samples[i]))
      #expect(InkSampleRelations.sameBits(restored.sample(at:i),samples[i]))
    }
  }
}

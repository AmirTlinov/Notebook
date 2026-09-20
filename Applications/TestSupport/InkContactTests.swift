import Foundation
@testable import NotebookCore
import PencilKit
import XCTest
@testable import Notebook

final class InkContactTests: XCTestCase {
  private func sample(_ i: Int) -> SpatialInkSample {
    .init(point:.init(x:Double(i%4096)/8,y:Double(i/4096)),timeOffset:Double(i)/128,
      width:4,opacity:Double(i%7)/8,force:Double(i%9)/16,azimuth:Double(i%5)/4,altitude:1)
  }
  func testContactSealsOnlyBoundedBlocksAndRetainsExactSnapshotAfterTailReplacement() throws {
    var contact=InkSampleRelations.Contact(header:.init(tool:.pen,color:.black))
    var latencies:[Double]=[],prepared=0
    for i in 0..<100_000 {
      let start=ContinuousClock.now
      contact.replaceTail(from:contact.count,with:[sample(i)])
      let t=start.duration(to:.now).components
      if i >= 99_000 { latencies.append(Double(t.seconds)*1000+Double(t.attoseconds)/1e15) }
      XCTAssertLessThanOrEqual(contact.preparedEventCount,256);prepared += contact.preparedEventCount
    }
    XCTAssertEqual(prepared,99_840)
    let frozen=contact.frozen(),revision=frozen.revision
    contact.replaceTail(from:257,with:[sample(7),sample(8)])
    XCTAssertEqual(contact.count,259)
    XCTAssertNotEqual(contact.revision,revision)
    let changed=contact.frozen()
    for i in 0..<257 { XCTAssertTrue(InkSampleRelations.sameBits(changed.sample(at:i),sample(i))) }
    XCTAssertTrue(InkSampleRelations.sameBits(changed.sample(at:257),sample(7)))
    XCTAssertThrowsError(try changed.sample(at:frozen.address(at:0)))
    let decoded=frozen.decoded()
    for i in decoded.indices { XCTAssertTrue(InkSampleRelations.sameBits(decoded[i],sample(i))) }
    let row:[String:Any]=["events":100_000,"preparedEvents":prepared,"tailAppendMilliseconds":latencies,
      "retainedLayoutBytes":frozen.payloadBytes,"scope":"native Debug accepted buffer; not input-to-present or process peak"]
    let attachment=XCTAttachment(data:try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]),uniformTypeIdentifier:"public.json")
    attachment.name="relation-contact-100k";attachment.lifetime = .keepAlways;add(attachment)
  }
  func testSpanAddressesRemainDistinctAndPredictionsCannotEnterAcceptedSource() throws {
    let id=UUID(),revision=UUID(),samples=(0..<8).map(sample)
    let first=InkSampleRelations(sourceID:id,span:0,revision:revision,samples:samples,header:.init(tool:.pen,color:.black))
    let second=InkSampleRelations(sourceID:id,span:1,revision:revision,samples:samples,header:first.header)
    XCTAssertEqual(first.equality(to:second,eventBudget:8),.different)
    XCTAssertThrowsError(try second.sample(at:first.address(at:0)))
    var contact=InkSampleRelations.Contact(sourceID:id,header:first.header)
    contact.replaceTail(from:0,with:samples)
    var mesh=IncrementalInkMesh()
    mesh.update(measured:contact,predicted:[sample(800),sample(801)],changedFrom:0,color:.init(0,0,0,1))
    XCTAssertEqual(contact.count,8)
    let accepted=contact.frozen()
    mesh.update(measured:contact,changedFrom:contact.count,color:.init(0,0,0,1))
    let expected=SpatialInkGeometry.compact(source:accepted)
    XCTAssertEqual(mesh.nodes,expected)
    for i in samples.indices { XCTAssertTrue(InkSampleRelations.sameBits(accepted.sample(at:i),samples[i])) }
  }
  func testRangeBoundsUseVerifiedFieldsWithoutLosingInteriorWidthOrBends() throws {
    for literal in [false,true] {
      let samples: [SpatialInkSample]=(0..<256).map { i in
        let x=Double(i)/4,y:Double=literal && i == 100 ? 80 : Double(i)/8
        let width:Double=literal && i == 101 ? 50 : Double(i+1)/128
        return .init(point:.init(x:x,y:y),timeOffset:Double(i)/128,width:width,opacity:1,force:1,azimuth:0,altitude:1)
      }
      let source=InkSampleRelations(sourceID:UUID(),revision:UUID(),samples:samples,header:.init(tool:.pen,color:.black))
      let range=31..<211,result=try source.bounds(in:range)
      for i in range {
        let p=samples[i],r=max(p.width/2,0.25)*Double(InkStrokeGeometry.maximumCrossSectionScale)
        XCTAssertTrue(result.bounds.contains(CGRect(x:p.point.x-r,y:p.point.y-r,width:2*r,height:2*r)))
      }
      XCTAssertEqual(result.cost.decodedSamples,literal ? range.count : 2)
    }
  }
  func testStreamedWorldContactUsesTheSameProjectionAsSettledSource() {
    let origin=WorldPoint(tileX:999_999,tileY:-999_999,localX:20,localY:40)
    var contact=InkSampleRelations.Contact(header:.init(tool:.pen,color:.black))
    let samples=(0..<1024).map { i in SpatialInkSample(point:.zero,worldPoint:origin.offsetBy(x:Double(i)/4,y:sin(Double(i)/10)),
      timeOffset:Double(i)/128,width:4,opacity:0.5,force:1,azimuth:0,altitude:1) }
    contact.replaceTail(from:0,with:samples)
    let projection=InkSampleProjection(origin:origin,offset:.init(x:30,y:40),scale:0.5)
    var mesh=IncrementalInkMesh()
    mesh.update(measured:contact,changedFrom:0,color:.init(0,0,0,1),projection:projection)
    XCTAssertEqual(mesh.nodes,SpatialInkGeometry.compact(source:contact.frozen(),origin:origin,offset:projection.offset,scale:projection.scale))
  }
}

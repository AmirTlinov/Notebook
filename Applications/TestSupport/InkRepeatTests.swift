import Foundation
import CoreGraphics
import ImageIO
@testable import NotebookCore
import XCTest
@testable import Notebook

final class InkRepeatTests: XCTestCase {
  private func sample(_ i: Int) -> SpatialInkSample {
    .init(point:.init(x:20+Double(i)/4,y:40+Double(i%13)/2),timeOffset:Double(i)/128,
      width:4,opacity:0.5,force:Double(i%7)/8,azimuth:Double(i%9)/8,altitude:0.5)
  }
  private func source(_ count: Int = 100) -> InkSampleRelations {
    .init(sourceID:UUID(),revision:UUID(),samples:(0..<count).map(sample),
      header:.init(tool:.pen,color:.init(red:0.1,green:0.3,blue:0.7)))
  }
  private var step: InkRepeatStep { .init(x:InkDyadic(32)!,y:.zero,time:.one) }
  private func ms(_ start: ContinuousClock.Instant) -> Double {
    let d=start.duration(to:.now).components;return Double(d.seconds)*1000+Double(d.attoseconds)/1e15
  }
  private func assertBits(_ a:SpatialInkSample,_ b:SpatialInkSample,file:StaticString=#filePath,line:UInt=#line) {
    XCTAssertTrue(InkSampleRelations.sameBits(a,b),file:file,line:line)
  }
  func testRepeatJumpRangeEditAndGPUAt100kAndMillion() throws {
    var reports:[[String:Any]]=[]
    for n in [1_000,10_000] {
      let bodyStart=ContinuousClock.now,body=source().settingExit(step,revision:UUID())
      let bodyMS=ms(bodyStart),start=ContinuousClock.now
      let repeated=try XCTUnwrap(body.repeated(n,revision:UUID()))
      let setup=ms(start)
      XCTAssertEqual(repeated.count,n*body.count)
      XCTAssertEqual(repeated.storage.exit,step.multiplied(by:n))
      var accessTimes:[Double]=[]
      for i in [0,repeated.count/2,repeated.count-1] {
        let start=ContinuousClock.now,read=try repeated.access(repeated.address(at:i))
        accessTimes.append(ms(start))
        assertBits(read.sample,step.multiplied(by:i/body.count)!.apply(sample(i%body.count)))
        XCTAssertEqual(read.cost.decodedSamples,1);XCTAssertEqual(read.cost.jumps,1)
        XCTAssertLessThanOrEqual(read.cost.visitedNodes,3)
      }
      for i in 0..<100 {
        let index=(i*7919)%repeated.count,start=ContinuousClock.now
        _=try repeated.access(repeated.address(at:index));accessTimes.append(ms(start))
      }
      let sequentialStart=ContinuousClock.now
      var sequential=sample(0)
      for _ in 1..<n { sequential=step.apply(sequential) }
      let sequentialMS=ms(sequentialStart)
      assertBits(sequential,repeated.sample(at:(n-1)*body.count))
      let middle=repeated.count/2+27,original=repeated.sample(at:middle)
      let replacement=SpatialInkSample(point:.init(x:original.point.x+3,y:original.point.y-2),
        timeOffset:original.timeOffset,width:5,opacity:0.25,force:0.5,azimuth:0,altitude:0.5)
      let editStart=ContinuousClock.now
      let edited=try repeated.editing(repeated.address(at:middle),to:replacement,revision:UUID())
      let editMS=ms(editStart)
      assertBits(edited.sample(at:middle),replacement)
      for i in [0,middle-1,middle+1,repeated.count-1] { assertBits(edited.sample(at:i),repeated.sample(at:i)) }
      assertBits(repeated.sample(at:middle),original)
      XCTAssertThrowsError(try edited.sample(at:repeated.address(at:middle)))
      XCTAssertLessThan(edited.allocationSummary.nodes,40)
      XCTAssertLessThan(edited.payloadBytes,body.payloadBytes+20_000)
      let bounds=try repeated.bounds(in:23..<(repeated.count-19))
      XCTAssertLessThanOrEqual(bounds.cost.decodedSamples,body.count*2)
      XCTAssertLessThan(bounds.cost.visitedNodes,10)
      XCTAssertTrue(bounds.bounds.contains(CGPoint(x:repeated.sample(at:middle).point.x,y:repeated.sample(at:middle).point.y)))
      let selected=(middle-15)..<(middle+26)
      let reopened=try InkSampleRelations(encodedRelations:edited.encodedRelations())
      try compareRangeGPU(reopened,range:selected,name:"repeat-\(repeated.count)-restored-selected")
      reports.append(["events":repeated.count,"bodyEvents":body.count,"bodyGenerationAndEncodingMilliseconds":bodyMS,"setupMilliseconds":setup,
        "accessMilliseconds":accessTimes,"editMilliseconds":editMS,
        "sequentialControlTransitions":n-1,"sequentialControlMilliseconds":sequentialMS,
        "sourcePayloadBytes":repeated.payloadBytes,"editedPayloadBytes":edited.payloadBytes,
        "physicalNodes":repeated.allocationSummary.nodes,"editedPhysicalNodes":edited.allocationSummary.nodes,
        "boundsVisitedNodes":bounds.cost.visitedNodes,"boundsDecodedSamples":bounds.cost.decodedSamples,
        "selectedEvents":selected.count,"scope":"typed translation repeat; native Debug; not installed UI latency"])
    }
    let a=XCTAttachment(data:try JSONSerialization.data(withJSONObject:reports,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
    a.name="relation-repeat-access";a.lifetime = .keepAlways;add(a)
  }
  private func compareRangeGPU(_ source: InkSampleRelations,range: Range<Int>,name: String) throws {
    let samples=source.decoded(in:range),color=source.header.color
    let old=SpatialInkMesh.referencePage(.init(actions:[
      .init(tool:.pen,color:color,samples:samples)]))
    let nodes=SpatialInkGeometry.compact(source:source,range:range)
    let new=SpatialInkMesh(batches:[.init(tool:.pen,nodes:nodes,
      color:.init(Float(color.red),Float(color.green),Float(color.blue),1),projection:.local)])
    let affine=InkAffine(x:.init(1,0,Float(50-samples[0].point.x),0),y:.init(0,1,0,0))
    let a=try XCTUnwrap(InkRasterRenderer.shared.render(mesh:old,size:.init(width:256,height:128),scale:1,affine:affine))
    let b=try XCTUnwrap(InkRasterRenderer.shared.render(mesh:new,size:.init(width:256,height:128),scale:1,affine:affine))
    let left=Array(try XCTUnwrap(a.dataProvider?.data) as Data),right=Array(try XCTUnwrap(b.dataProvider?.data) as Data)
    XCTAssertTrue(right.contains { $0 > 0 })
    XCTAssertLessThanOrEqual(zip(left,right).map { abs(Int($0)-Int($1)) }.max()!,2)
    let png=NSMutableData(),destination=try XCTUnwrap(CGImageDestinationCreateWithData(png,"public.png" as CFString,1,nil))
    CGImageDestinationAddImage(destination,b,nil);XCTAssertTrue(CGImageDestinationFinalize(destination))
    let reread=try XCTUnwrap(CGImageSourceCreateWithData(png,nil));XCTAssertEqual(CGImageSourceGetCount(reread),1)
    let attachment=XCTAttachment(data:png as Data,uniformTypeIdentifier:"public.png")
    attachment.name=name;attachment.lifetime = .keepAlways;add(attachment)
  }
  func testRepeatNestedEmptyOverflowAndExactDomainAdmission() throws {
    let body=source(16).settingExit(step,revision:UUID())
    let inner=try XCTUnwrap(body.repeated(10,revision:UUID()))
    let nested=try XCTUnwrap(inner.repeated(100,revision:UUID()))
    let flat=try XCTUnwrap(body.repeated(1000,revision:UUID()))
    for i in [0,15,16,159,160,8_011,15_999] { assertBits(nested.sample(at:i),flat.sample(at:i)) }
    XCTAssertEqual(try nested.access(nested.address(at:8011)).cost.jumps,1)
    let empty=try XCTUnwrap(body.repeated(0,revision:UUID()))
    XCTAssertEqual(empty.count,0);XCTAssertEqual(empty.storage.exit,.zero)
    XCTAssertThrowsError(try empty.sample(at:empty.address(at:0)))
    let transitionOnly=try XCTUnwrap(source(0).settingExit(step,revision:UUID()).repeated(7,revision:UUID()))
    XCTAssertEqual(transitionOnly.count,0);XCTAssertEqual(transitionOnly.storage.exit,step.multiplied(by:7))
    XCTAssertTrue(try transitionOnly.bounds(in:0..<0).bounds.isNull)
    let once=try XCTUnwrap(body.repeated(1,revision:UUID()))
    XCTAssertTrue(once.storage.root === body.storage.root);XCTAssertEqual(once.storage.exit,step)
    XCTAssertNil(body.repeated(-1,revision:UUID()))
    XCTAssertNil(body.settingExit(.zero,revision:UUID()).repeated(Int.max,revision:UUID()))
    // A translation too fine for the 53-bit common lattice is not rounded.
    XCTAssertNil(body.settingExit(.init(x:InkDyadic(.leastNonzeroMagnitude)!,y:.zero,time:.zero),revision:UUID()).repeated(20,revision:UUID()))
    XCTAssertNil(body.settingExit(.init(x:.zero,y:.zero,time:InkDyadic(-1)!),revision:UUID()).repeated(20,revision:UUID()))
    XCTAssertThrowsError(try flat.bounds(in:0..<(flat.count+1)))
    // Bounds of arbitrary nested intervals enclose every source footprint.
    for range in [31..<319,1..<15_999,8_000..<8_001] {
      let b=try nested.bounds(in:range).bounds
      for i in range {
        let p=nested.sample(at:i),r=p.width/2
        XCTAssertTrue(b.contains(CGPoint(x:p.point.x-r,y:p.point.y-r)))
        XCTAssertTrue(b.contains(CGPoint(x:p.point.x+r,y:p.point.y+r)))
      }
    }
  }
  func testRangeBoundsEncloseActualMiterAndFloatProjection() throws {
    let points=[(0.0,0.0),(20.0,0.0),(1.0,1.0),(40.0,0.0)]
    let samples=points.enumerated().map { i,p in
      SpatialInkSample(point:.init(x:p.0,y:p.1),timeOffset:Double(i)/8,width:10,
        opacity:0.5,force:0.5,azimuth:0,altitude:0.5)
    }
    let body=InkSampleRelations(sourceID:UUID(),revision:UUID(),samples:samples,
      header:.init(tool:.pen,color:.init(red:0,green:0,blue:0)))
      .settingExit(.init(x:InkDyadic(64)!,y:.zero,time:.one),revision:UUID())
    let repeated=try XCTUnwrap(body.repeated(10_000,revision:UUID()))
    for range in [0..<4,3..<11,39_000..<39_007] {
      let geometry=SpatialInkGeometry.compact(source:repeated,range:range)
      let actual=InkRenderGeometry.bounds(geometry[...]),summary=try repeated.bounds(in:range).bounds
      XCTAssertTrue(summary.contains(actual),"\(summary) does not enclose \(actual)")
    }
  }
  func testChangedExitPropagatesAndRepeatedLocalEditsStayIndexed() throws {
    let body=source(32).settingExit(step,revision:UUID()),original=try XCTUnwrap(body.repeated(10_000,revision:UUID()))
    let changedStep=InkRepeatStep(x:InkDyadic(36)!,y:InkDyadic(2)!,time:InkDyadic(2)!)
    let delta=try XCTUnwrap(changedStep.adding(step.negated))
    let changed=try original.propagatingExitDelta(delta,from:original.address(at:160_000),revision:UUID())
    for i in [0,159_999] { assertBits(changed.sample(at:i),original.sample(at:i)) }
    for i in [160_000,160_003,319_999] { assertBits(changed.sample(at:i),delta.apply(original.sample(at:i))) }
    XCTAssertEqual(changed.storage.exit,original.storage.exit.adding(delta))
    // Includes the single shared basis owner as well as sequence/index nodes.
    XCTAssertLessThanOrEqual(changed.allocationSummary.nodes,20)
    var edited=original,expected:[Int:SpatialInkSample]=[:]
    for i in 0..<250 {
      let index=(i*7919)%original.count,replacement=sample(i%32)
      edited=try edited.editing(edited.address(at:index),to:replacement,revision:UUID())
      expected[index]=replacement
    }
    for (i,p) in expected { assertBits(edited.sample(at:i),p) }
    for i in stride(from:17,to:original.count,by:1013) where expected[i] == nil {
      let result=try edited.access(edited.address(at:i))
      assertBits(result.sample,original.sample(at:i));XCTAssertLessThan(result.cost.visitedNodes,30)
    }
    XCTAssertLessThan(edited.storage.root.height,25)
    // Full overlap is a legitimate expensive output, not skipped events.
    let overlap=try XCTUnwrap(body.settingExit(.zero,revision:UUID()).repeated(3125,revision:UUID()))
    let start=ContinuousClock.now,expanded=overlap.decoded(),decodeMS=ms(start)
    XCTAssertEqual(expanded.count,100_000)
    for i in stride(from:0,to:expanded.count,by:97) { assertBits(expanded[i],sample(i%32)) }
    XCTAssertTrue(try overlap.bounds(in:0..<100_000).bounds.contains(body.storage.root.bounds))
    let report:[String:Any] = ["case":"fully overlapping repeat, explicit full export",
      "events":overlap.count,"emittedEvents":expanded.count,"decodeMilliseconds":decodeMS,
      "expandedPayloadBytes":expanded.count*MemoryLayout<SpatialInkSample>.stride,
      "sourcePayloadBytes":overlap.payloadBytes,"scope":"negative control; full output is not sublinear"]
    let a=XCTAttachment(data:try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
    a.name="relation-repeat-full-output";a.lifetime = .keepAlways;add(a)
  }
}

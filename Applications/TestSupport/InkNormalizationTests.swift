import Foundation
@testable import NotebookCore
import XCTest
@testable import Notebook

final class InkNormalizationTests: XCTestCase {
  typealias Source=InkSampleRelations
  typealias Node=InkSampleRelations.Sequence
  private let step=InkRepeatStep(x:InkDyadic(32)!,y:.zero,time:.one)
  private func sample(_ i: Int,x: Double? = nil,y: Double = 20) -> SpatialInkSample {
    .init(point:.init(x:x ?? 10+Double(i)/4,y:y),timeOffset:Double(i)/128,
      width:4,opacity:0.5,force:Double(i%3)/8,azimuth:0,altitude:0.5)
  }
  private func source(_ samples: [SpatialInkSample]) -> Source {
    .init(sourceID:UUID(),revision:UUID(),samples:samples,header:.init(tool:.pen,color:.init(red:0.1,green:0.4,blue:0.8)))
  }
  private func events(_ node: Node) -> [SpatialInkSample] {
    var result:[SpatialInkSample]=[];node.forEachSample(in:0..<node.count) { result.append($0) };return result
  }
  private func assertBits(_ a:[SpatialInkSample],_ b:[SpatialInkSample],file:StaticString=#filePath,line:UInt=#line) {
    XCTAssertEqual(a.count,b.count,file:file,line:line)
    for i in 0..<min(a.count,b.count) { XCTAssertTrue(Source.sameBits(a[i],b[i]),"event \(i)",file:file,line:line) }
  }
  private func nodeCount(_ node:Node)->Int { var seen=Set<ObjectIdentifier>();return node.allocationSummary(seen:&seen).nodes }
  func testLocalRulesPreserveEventsPhaseAndStrictlyReduceRepresentation() throws {
    let body=source((0..<16).map { sample($0) }).storage.root
    let a=try XCTUnwrap(Node.repeated(body,count:4,step:step))
    let b=try XCTUnwrap(Node.repeated(body,count:6,step:step)?.shifted(step.multiplied(by:4)!))
    var work=Source.RewriteWork()
    let merged=Node.join(a,b,work:&work)
    XCTAssertNotEqual(work.rules & (1<<2),0) // R3
    XCTAssertLessThan(nodeCount(merged),nodeCount(Node.balance(a,b)))
    assertBits(events(merged),events(a)+events(b))
    let wrongPhase=try XCTUnwrap(Node.repeated(body,count:6,step:step)?.shifted(step.multiplied(by:5)!))
    var negative=Source.RewriteWork()
    let separate=Node.join(a,wrongPhase,work:&negative)
    XCTAssertEqual(negative.rules & (1<<2),0)
    assertBits(events(separate),events(a)+events(wrongPhase))
    let nested=try XCTUnwrap(Node.repeated(a,count:10,step:step.multiplied(by:4)!))
    let flat=try XCTUnwrap(Node.repeated(body,count:40,step:step))
    XCTAssertEqual(nodeCount(nested),nodeCount(flat));assertBits(events(nested),events(flat)) // R4
    let reset=try XCTUnwrap(Node.repeated(a,count:10,step:step))
    XCTAssertGreaterThan(nodeCount(reset),nodeCount(flat))
    XCTAssertFalse(Source.sameBits(events(reset)[64],events(flat)[64]))
    let displacement=InkRepeatStep(x:InkDyadic(64)!,y:InkDyadic(8)!,time:.one)
    let x=try XCTUnwrap(body.shifted(displacement))
    let different=source((0..<16).map { sample($0,x:80+Double($0)/2) }).storage.root
    let y=try XCTUnwrap(different.shifted(displacement))
    var factoring=Source.RewriteWork()
    let grouped=Node.join(x,y,work:&factoring)
    XCTAssertNotEqual(factoring.rules & (1<<4),0) // R5; same scoped coordinate frame only
    XCTAssertLessThan(nodeCount(grouped),nodeCount(Node.balance(x,y)))
    assertBits(events(grouped),events(x)+events(y))
    XCTAssertTrue(grouped.pending)
    var finished=grouped,passes=0
    while finished.pending && passes < 8 {
      var work=Source.RewriteWork()
      let next=finished.normalized(work:&work)
      XCTAssertLessThanOrEqual(nodeCount(next),nodeCount(finished))
      assertBits(events(next),events(grouped));finished=next;passes += 1
    }
    XCTAssertFalse(finished.pending)
    var unknown=Source.RewriteWork(0)
    let copy=source((0..<16).map { sample($0) }).storage.root
    XCTAssertEqual(Node.sameEvents(body,copy,work:&unknown),.notProven)
    var r2=Source.RewriteWork(0)
    XCTAssertTrue(Node.join(.empty,body,work:&r2) === body)
    XCTAssertNotEqual(r2.rules & (1<<1),0)
    let empty=source([]).settingExit(step,revision:UUID())
    let noEvents=try XCTUnwrap(empty.repeated(5,revision:UUID()))
    XCTAssertEqual(noEvents.count,0);XCTAssertEqual(noEvents.storage.exit,step.multiplied(by:5))
    // Same output with a different emitted middle must NOT pass R3 equality.
    var altered=(0..<16).map { sample($0) };altered[8]=sample(8,x:99)
    var compare=Source.RewriteWork()
    XCTAssertEqual(Node.sameEvents(body,source(altered).storage.root,work:&compare),.different)
  }
  func testPendingNormalizationTerminatesAcrossUncomposableFrameScopes() throws {
    let large=InkRepeatStep(x:InkDyadic(Double(1<<52))!,y:.zero,time:.zero)
    let fine=InkRepeatStep(x:InkDyadic(0.25)!,y:.zero,time:.zero)
    let body=source((0..<4096).map { sample($0,x:-Double(1<<52),y:Double($0)/4) }).storage.root
    let a=try XCTUnwrap(body.shifted(large)?.shifted(fine))
    let b=try XCTUnwrap(source((0..<16).map { sample($0) }).storage.root.shifted(fine))
    let reference=events(a)+events(b)
    var work=Source.RewriteWork(0),node=Node.join(a,b,work:&work),passes=0
    func shape(_ node: Node) -> String {
      let pending=node.pending ? "?" : "!"
      switch node.content {
      case .block(let block): return "\(pending)L\(block.count):\(block.payloadBytes)"
      case .pair(let a,let b): return "\(pending)P(\(shape(a)),\(shape(b)))"
      case .shifted(let body,let basis): return "\(pending)F\(basis.step.x.value)(\(shape(body)))"
      case .repeated(let body,let n,_): return "\(pending)R\(n)(\(shape(body)))"
      }
    }
    var seen=Set<String>()
    while node.pending && passes < 32 {
      XCTAssertTrue(seen.insert(shape(node)).inserted,"Normalization revisited the same pending expression")
      var next=Source.RewriteWork();node=node.normalized(work:&next);passes += 1
    }
    XCTAssertFalse(node.pending)
    assertBits(events(node),reference)
  }
  func testDeferredLocalPreparationRetainsInputAndRevision() throws {
    let original=source((0..<16_384).map { sample($0) })
    let edited=try original.editing(original.address(at:8000),to:sample(8000,x:2300),revision:UUID(),normalizationBudget:0)
    XCTAssertTrue(edited.storage.root.pending)
    XCTAssertTrue(edited.lastEdit!.work.deferred)
    XCTAssertTrue(Source.sameBits(edited.sample(at:8000),sample(8000,x:2300)))
    let stillPending=edited.normalizingPending(budget:0)
    XCTAssertTrue(stillPending.storage.root === edited.storage.root)
    let complete=edited.normalizingPending(budget:8192)
    XCTAssertFalse(complete.storage.root.pending)
    XCTAssertEqual(complete.revision,edited.revision)
    XCTAssertLessThanOrEqual(complete.lastEdit!.work.scannedEvents,768)
    XCTAssertLessThan(complete.lastEdit!.work.visitedNodes,60)
    assertBits(complete.decoded(),edited.decoded())
    XCTAssertEqual(complete.equality(to:edited,eventBudget:complete.count),.equal)
    let stable=complete.normalizingPending(budget:8192)
    XCTAssertTrue(stable.storage.root === complete.storage.root)
    XCTAssertEqual(stable.equality(to:complete,eventBudget:0),.equal)
  }
  func testChangedMiddleInvalidatesGeometryWhenExitDoesNotChange() throws {
    let original=source([sample(0,x:10,y:10),sample(1,x:30,y:10),sample(2,x:30,y:30),sample(3,x:10,y:10)])
      .settingExit(step,revision:UUID())
    let edited=try original.editing(original.address(at:2),to:sample(2,x:50,y:50),revision:UUID())
    let report=try XCTUnwrap(edited.lastEdit)
    XCTAssertFalse(report.exitChanged);XCTAssertTrue(report.geometryChanged)
    XCTAssertNotEqual(report.oldBounds,report.newBounds)
    XCTAssertTrue(report.newBounds.contains(CGPoint(x:50,y:50)))
    XCTAssertEqual(report.affectedEvents,1..<4)
    func image(_ source: Source) throws -> Data {
      let mesh=SpatialInkMesh(batches:[.init(tool:.pen,nodes:SpatialInkGeometry.compact(source:source),
        color:.init(0.1,0.4,0.8,1),projection:.local)])
      let image=try XCTUnwrap(InkRasterRenderer.shared.render(mesh:mesh,size:.init(width:64,height:64),scale:1))
      return try XCTUnwrap(image.dataProvider?.data) as Data
    }
    XCTAssertNotEqual(try image(original),try image(edited))
    XCTAssertEqual(try image(original),try image(original)) // retained undo source
    let timed=try original.propagatingExitDelta(.init(x:.zero,y:.zero,time:.one),from:original.address(at:2),revision:UUID())
    XCTAssertFalse(timed.lastEdit!.geometryChanged);XCTAssertTrue(timed.lastEdit!.exitChanged)
    XCTAssertEqual(try image(original),try image(timed))
  }
  func testIncrementalEditsAndSuffixChangesMatchFullOrderedExecutionAndUndo() throws {
    var expected=(0..<512).map { sample($0) },current=source(expected)
    var undo:[(Source,[SpatialInkSample])]=[]
    for i in 0..<32 {
      undo.append((current,expected))
      let index=(i*97)%expected.count
      if i%2 == 0 {
        let value=sample(index,x:Double(i)+0.25,y:Double(i)+20)
        current=try current.editing(current.address(at:index),to:value,revision:UUID())
        expected[index]=value
      } else {
        let delta=InkRepeatStep(x:InkDyadic(0.25)!,y:InkDyadic(-0.5)!,time:InkDyadic(0.125)!)
        current=try current.propagatingExitDelta(delta,from:current.address(at:index),revision:UUID())
        for j in index..<expected.count { expected[j]=try XCTUnwrap(delta.applyingIfExact(expected[j])) }
      }
      assertBits(current.decoded(),expected)
    }
    for (old,reference) in undo.reversed() { assertBits(old.decoded(),reference) }
  }
  func testLocalRewriteCostOnMillionEventRepeat() throws {
    let body=source((0..<100).map { sample($0) }).settingExit(step,revision:UUID())
    let original=try XCTUnwrap(body.repeated(10_000,revision:UUID()))
    var rows:[[String:Any]]=[]
    for iteration in 0..<105 {
      let index=400_000+iteration*103,old=original.sample(at:index)
      let value=SpatialInkSample(point:.init(x:old.point.x+0.25,y:old.point.y+0.5),timeOffset:old.timeOffset,
        width:old.width,opacity:old.opacity,force:old.force,azimuth:old.azimuth,altitude:old.altitude)
      let start=ContinuousClock.now
      let edited=try original.editing(original.address(at:index),to:value,revision:UUID())
      let elapsed=start.duration(to:.now).components
      XCTAssertTrue(Source.sameBits(edited.sample(at:index),value))
      let w=edited.lastEdit!.work
      XCTAssertLessThanOrEqual(w.scannedEvents,768)
      if iteration >= 5 {
        rows.append(["milliseconds":Double(elapsed.seconds)*1000+Double(elapsed.attoseconds)/1e15,
          "reductions":w.reductions,"rules":w.rules,"visitedNodes":w.visitedNodes,
          "scannedEvents":w.scannedEvents,"comparedEvents":w.comparedEvents,
          "propagatedEvents":w.propagatedEvents,"normalizationDeferred":edited.storage.root.pending,
          "indexHeight":edited.storage.root.height,"affectedEvents":edited.lastEdit!.affectedEvents.count])
      }
    }
    let a=XCTAttachment(data:try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
    a.name="relation-local-normalization-cost";a.lifetime = .keepAlways;add(a)
  }
  func testExpensiveCascadeIsExplicitAndUnsupportedEditDoesNotPublishPartialData() throws {
    let samples=(0..<100_000).map { sample($0,x:$0%2 == 0 ? 0.25 : Double(1<<52)) }
    let original=source(samples),delta=InkRepeatStep(x:.one,y:.zero,time:.zero)
    let start=ContinuousClock.now
    let changed=try original.propagatingExitDelta(delta,from:original.address(at:0),revision:UUID())
    let elapsed=start.duration(to:.now).components
    XCTAssertEqual(changed.lastEdit!.work.propagatedEvents,samples.count)
    XCTAssertTrue(changed.storage.root.pending)
    for i in samples.indices { XCTAssertTrue(Source.sameBits(changed.sample(at:i),delta.applyingIfExact(samples[i])!)) }
    XCTAssertEqual(original.sample(at:0).point.x,0.25)
    XCTAssertThrowsError(try original.propagatingExitDelta(.init(x:.zero,y:.zero,time:InkDyadic(-1)!),
      from:original.address(at:0),revision:UUID()))
    XCTAssertEqual(original.sample(at:0).timeOffset,0)
    let world=SpatialInkSample(point:.init(x:0,y:0),worldPoint:.init(tileX:1_000_000,tileY:-1_000_000,localX:0.25,localY:0.5),
      timeOffset:0,width:4,opacity:0.5,force:0.5,azimuth:0,altitude:0.5)
    let worldSource=source([world])
    let timed=try worldSource.propagatingExitDelta(.init(x:.zero,y:.zero,time:.one),from:worldSource.address(at:0),revision:UUID())
    XCTAssertEqual(timed.sample(at:0).worldPoint,world.worldPoint)
    XCTAssertEqual(timed.sample(at:0).timeOffset,1)
    XCTAssertThrowsError(try worldSource.propagatingExitDelta(delta,from:worldSource.address(at:0),revision:UUID()))
    let w=changed.lastEdit!.work
    let report:[String:Any]=["case":"mixed binary scales, no shared range proof","events":samples.count,
      "propagatedEvents":w.propagatedEvents,"visitedNodes":w.visitedNodes,"scannedEvents":w.scannedEvents,
      "normalizationDeferred":changed.storage.root.pending,"normalizationWork":w.spent,
      "milliseconds":Double(elapsed.seconds)*1000+Double(elapsed.attoseconds)/1e15]
    let attachment=XCTAttachment(data:try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
    attachment.name="relation-expensive-cascade";attachment.lifetime = .keepAlways;add(attachment)
  }
}

import Foundation
import Darwin
import CoreGraphics
import ImageIO
@testable import NotebookCore
import PencilKit
import XCTest
@testable import Notebook

final class InkRelationTests: XCTestCase {
  private func processFootprint() -> UInt64? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to:&info) { pointer in
      pointer.withMemoryRebound(to:integer_t.self,capacity:Int(count)) {
        task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count)
      }
    }
    return status == KERN_SUCCESS ? info.phys_footprint : nil
  }
  
  private let sourceID = UUID(uuidString:"ACAAABBB-0000-4000-8000-000000000001")!
  private let revision = UUID(uuidString:"ACAAABBB-0000-4000-8000-000000000002")!
  private func sample(_ x: Double, _ y: Double, _ i: Int, opacity: Double = 0.5) -> SpatialInkSample {
    .init(point:.init(x:x,y:y),timeOffset:Double(i)/128,width:4,opacity:opacity,
      force:i%17 == 0 ? 0 : 0.75,azimuth:Double(i%9)/4,altitude:0.5)
  }
  private func source(_ a: [SpatialInkSample], tool: SpatialInkTool = .pen) -> InkSampleRelations {
    .init(sourceID:sourceID,revision:revision,samples:a,header:.init(tool:tool,color:.init(red:0.1,green:0.3,blue:0.7)))
  }
  private func assertBits(_ a: [SpatialInkSample], _ b: [SpatialInkSample], file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.count,b.count,file:file,line:line)
    for i in 0..<min(a.count,b.count) { XCTAssertTrue(InkSampleRelations.sameBits(a[i],b[i]),"event \(i)",file:file,line:line) }
  }
  func testExactDomainOrderedFramesAndUnprovenEquality() throws {
    for value in [0.0,1,-1,.leastNonzeroMagnitude,.greatestFiniteMagnitude,Double.pi,Double(1<<52)+1] {
      let d = try XCTUnwrap(InkDyadic(value)); XCTAssertEqual(d.value.bitPattern,value.bitPattern)
    }
    XCTAssertNil(InkDyadic(-0.0)); XCTAssertNil(InkDyadic(.infinity))
    XCTAssertNil(InkDyadic(1)!.adding(InkDyadic(.leastNonzeroMagnitude)!))
    XCTAssertNil(InkDyadic(.greatestFiniteMagnitude)!.multiplied(by:2))
    let zero = InkDyadic.zero, one = InkDyadic.one, two = InkDyadic(2)!
    let rotate = InkExactFrame(a:zero,b:one,c:one.negated,d:zero,x:zero,y:zero)
    let scale = InkExactFrame(a:two,b:zero,c:zero,d:one,x:zero,y:zero)
    XCTAssertNotEqual(rotate.composed(after:scale),scale.composed(after:rotate))
    let back = InkExactFrame(a:zero,b:one.negated,c:one,d:zero,x:zero,y:zero)
    XCTAssertEqual(back.composed(after:rotate),.identity)
    // Inverse relation only cancels adjacent state transitions. An emitted
    // square/path is never represented by its final transition alone.
    let square = [sample(0,0,0),sample(20,0,1),sample(20,20,2),sample(0,20,3),sample(0,0,4)]
    let a = source(square), b = source(square)
    XCTAssertEqual(a.equality(to:b,eventBudget:0),.notProven)
    XCTAssertEqual(a.equality(to:a,eventBudget:0),.equal)
    XCTAssertEqual(a.equality(to:b,eventBudget:5),.equal)
    XCTAssertEqual(a.equality(to:source([]),eventBudget:0),.different)
    var loop = square; loop[2] = sample(40,20,2)
    XCTAssertEqual(a.equality(to:source(loop),eventBudget:5),.different)
  }
  func testBitExactRoundTripAddressedEditAndUndo() throws {
    var rng: UInt64 = 0x56abb541
    func random() -> Double { rng ^= rng<<13; rng ^= rng>>7; rng ^= rng<<17; return Double(rng & 0xffff_ffff)/Double(UInt32.max) }
    var samples = (0..<1025).map { i in sample(random()*500,random()*500,i,opacity:random()) }
    samples[0] = sample(-0.0,.leastNonzeroMagnitude,0)
    let original = source(samples)
    assertBits(samples,original.decoded())
    let edited = try original.editing(original.address(at:513),to:sample(200,30,513),revision:UUID())
    XCTAssertThrowsError(try edited.sample(at:original.address(at:513)))
    XCTAssertThrowsError(try original.sample(at:original.address(at:original.count)))
    for i in samples.indices where i != 513 { XCTAssertTrue(InkSampleRelations.sameBits(samples[i],edited.sample(at:i))) }
    assertBits(samples,original.decoded()) // immutable source is the undo value
    var expected = samples; expected[513] = sample(200,30,513)
    try verifyRender(expected,name:"relative-edited",encoded:edited)
    try verifyRender(samples,name:"relative-undo",encoded:original)
    let action = PageInkAction(id:sourceID,tool:.pen,samples:original.decoded(),sequence:9)
    let reopened = try JSONDecoder().decode(PageInkAction.self,from:JSONEncoder().encode(action))
    XCTAssertEqual(reopened.id,sourceID); XCTAssertEqual(reopened.sequence,9)
    assertBits(samples,reopened.samples.materialized())
    XCTAssertLessThan(original.payloadBytes,samples.capacity*MemoryLayout<SpatialInkSample>.stride*11/10)
  }
  private func mesh(_ samples: [SpatialInkSample], relations: Bool, eraser: Bool = false) -> SpatialInkMesh {
    if relations {
      return mesh(source(samples,tool:eraser ? .eraser : .pen))
    }
    let action = PageInkAction(id:sourceID,tool:eraser ? .eraser : .pen,
      color:.init(red:0.1,green:0.3,blue:0.7),samples:samples)
    return SpatialInkMesh.referencePage(.init(actions:[action]))
  }
  private func mesh(_ source: InkSampleRelations) -> SpatialInkMesh {
    .init(batches:[.init(source:source,projection:.local)])
  }
  private func image(_ mesh: SpatialInkMesh, affine: InkAffine = .init()) throws -> CGImage {
    try XCTUnwrap(InkRasterRenderer.shared.render(mesh:mesh,size:.init(width:640,height:640),scale:1,affine:affine))
  }
  private func verifyRender(_ samples: [SpatialInkSample], name: String, encoded: InkSampleRelations? = nil) throws {
    let input = encoded ?? source(samples)
    let action = PageInkAction(id:input.sourceID,tool:input.header.tool,color:input.header.color,samples:samples)
    let original = SpatialInkMesh.referencePage(.init(actions:[action]))
    let derived = mesh(input)
    let a = try image(original), b = try image(derived)
    let left = Array(try XCTUnwrap(a.dataProvider?.data) as Data),right = Array(try XCTUnwrap(b.dataProvider?.data) as Data)
    XCTAssertEqual(left.count,right.count)
    XCTAssertLessThanOrEqual(zip(left,right).map { abs(Int($0)-Int($1)) }.max()!,2)
    XCTAssertTrue(right.contains { $0 > 0 })
    let png = NSMutableData(), destination = try XCTUnwrap(CGImageDestinationCreateWithData(png,"public.png" as CFString,1,nil))
    CGImageDestinationAddImage(destination,b,nil);XCTAssertTrue(CGImageDestinationFinalize(destination))
    let reread = try XCTUnwrap(CGImageSourceCreateWithData(png,nil));XCTAssertEqual(CGImageSourceGetCount(reread),1)
    let attachment = XCTAttachment(data:png as Data,uniformTypeIdentifier:"public.png");attachment.name=name;attachment.lifetime = .keepAlways;add(attachment)
  }
  func testRegularAndMeasuredGeometryUseActualGPUAndExport() throws {
    let regular = (0..<4096).map { sample(30+Double($0)/8,100,$0) }
    let nodes = SpatialInkGeometry.compact(source:source(regular))
    XCTAssertLessThan(nodes.count,regular.count/10)
    assertBits(regular,source(regular).decoded())
    try verifyRender(regular,name:"relative-regular")
    let url = try XCTUnwrap(Bundle(for:Self.self).url(forResource:"QuickShapeMeasured",withExtension:"json"))
    let measured = try JSONDecoder().decode([String:[[[[Double]]]]].self,from:Data(contentsOf:url))
    let xy = try XCTUnwrap(measured["rectangles"]?.first?.first)
    let samples = xy.enumerated().map { sample($0.element[0]+80,$0.element[1]+80,$0.offset) }
    // Only the positions of this committed fixture are real measurements.
    // Private full Pencil attributes are checked by the explicit corpus test.
    assertBits(samples,source(samples).decoded())
    try verifyRender(samples,name:"relative-measured-positions")
    let eraser = (0..<128).map { sample(200,70+Double($0)/2,$0,opacity:0.3) }
    var outputs: [[UInt8]] = []
    for relations in [false,true] {
      let pen=mesh(regular,relations:relations), cut=mesh(eraser,relations:relations,eraser:true)
      let after=mesh(samples,relations:relations)
      let composed=try image(.init(batches:pen.batches+cut.batches+after.batches))
      outputs.append(Array(try XCTUnwrap(composed.dataProvider?.data) as Data))
    }
    XCTAssertLessThanOrEqual(zip(outputs[0],outputs[1]).map { abs(Int($0)-Int($1)) }.max()!,2)
  }
  func testWholeFrameUsesSameSourceAndPreservesOrderThroughGPU() throws {
    let samples = (0..<4096).map { sample(30+Double($0)/8,100,$0) }, original = source(samples)
    let zero=InkDyadic.zero,one=InkDyadic.one
    let transform=InkExactFrame(a:zero,b:one,c:one.negated,d:zero,x:InkDyadic(580)!,y:InkDyadic(20)!)
    let undo=InkExactFrame(a:zero,b:one.negated,c:one,d:zero,x:InkDyadic(-20)!,y:InkDyadic(580)!)
    let placed=original.transformed(by:transform)
    XCTAssertTrue(placed.storage === original.storage)
    assertBits(samples,placed.decoded())
    let back=placed.transformed(by:undo)
    XCTAssertEqual(back.equality(to:original,eventBudget:0),.equal)
    let reopened=try InkSampleRelations(encodedRelations:placed.encodedRelations())
    let actual=try image(mesh(reopened),affine:reopened.displayAffine)
    let expected=try image(mesh(samples,relations:false),affine:.init(x:.init(0,-1,580,0),y:.init(1,0,20,0)))
    let a=Array(try XCTUnwrap(actual.dataProvider?.data) as Data),b=Array(try XCTUnwrap(expected.dataProvider?.data) as Data)
    XCTAssertLessThanOrEqual(zip(a,b).map { abs(Int($0)-Int($1)) }.max()!,2)
    // The same endpoint cannot cancel a separately emitted/painted middle path.
    let first=source([sample(0,0,0),sample(20,20,1)]).transformed(by:transform)
    let second=source([sample(20,20,2),sample(0,0,3)]).transformed(by:undo)
    XCTAssertEqual(first.count+second.count,4)
    XCTAssertFalse(first.frames.isEmpty);XCTAssertFalse(second.frames.isEmpty)
  }
  func testMeasureFullPreparationAndRasterBudget() throws {
    var rng: UInt64 = 0xacadd
    func random() -> Double { rng ^= rng<<13; rng ^= rng>>7; rng ^= rng<<17; return Double(rng & 0xffff_ffff)/Double(UInt32.max) }
    let regular = (0..<4096).map { sample(30+Double($0)/8,100,$0) }
    let noise = (0..<4096).map { sample(30+random()*500,30+random()*500,$0,opacity:random()) }
    let url = try XCTUnwrap(Bundle(for:Self.self).url(forResource:"QuickShapeMeasured",withExtension:"json"))
    let fixture = try JSONDecoder().decode([String:[[[[Double]]]]].self,from:Data(contentsOf:url))
    let xy = try XCTUnwrap(fixture["rectangles"]?.first?.first)
    let measured = xy.enumerated().map { sample($0.element[0]+80,$0.element[1]+80,$0.offset) }
    var rows: [[String:Any]] = []
    for (name,samples) in [("regular",regular),("noise",noise),("measured-positions",measured)] {
      var preparation = [[Double]](repeating:[],count:2), total = preparation
      var footprint = [[UInt64]](repeating:[],count:2)
      var nodes = [0,0], meshBytes = [0,0], auxiliaryBytes = [0,0], visibleCPUBytes = [0,0], selectedGPUBytes = [0,0], firstPrepareMS = [0.0,0.0], firstTotalMS = [0.0,0.0]
      func ms(_ since: ContinuousClock.Instant) -> Double {
        let t=since.duration(to:.now).components;return Double(t.seconds)*1000+Double(t.attoseconds)/1e15
      }
      for round in 0..<105 {
        for mode in (round%2 == 0 ? [0,1] : [1,0]) {
          try autoreleasepool {
            let start=ContinuousClock.now
            let retained = mode == 1 ? source(samples) : nil
            let output = retained.map { mesh($0) } ?? mesh(samples,relations:false), ready=ms(start)
            _ = try image(output);let end=ms(start)
            if round == 0 {
              firstPrepareMS[mode]=ready;firstTotalMS[mode]=end
              nodes[mode]=output.batches.reduce(0) { $0+$1.preparedNodeCount }
              meshBytes[mode]=output.batches.reduce(0) { $0+$1.byteCount }
              auxiliaryBytes[mode]=output.batches.reduce(0) { $0+$1.auxiliaryBytes }
              visibleCPUBytes[mode]=output.batches.reduce(0) { total,batch in
                total+batch.query(viewport:.init(x:0,y:0,width:640,height:640),affine:.init()).chunks.reduce(0) { bytes,id in
                  let chunk=batch.prepareChunk(id).chunk
                  let level=InkRenderGeometry.level(chunk.descriptor.levels,pixelsPerUnit:1)
                  selectedGPUBytes[mode] += chunk.selected(level:level).count*MemoryLayout<SpatialInkGeometry.Node>.stride
                  return bytes+chunk.byteCount
                }
              }
            }
            if round >= 5 { preparation[mode].append(ready);total[mode].append(end)
              withExtendedLifetime(retained) {
                if let bytes=processFootprint() { footprint[mode].append(bytes) }
              }
            }
          }
        }
      }
      let encoding=ContinuousClock.now, encoded=source(samples), encodeMS=ms(encoding)
      let decode=ContinuousClock.now, decoded=encoded.decoded(), decodeMS=ms(decode)
      assertBits(samples,decoded)
      let comparison=ContinuousClock.now
      XCTAssertEqual(encoded.equality(to:source(samples),eventBudget:samples.count),.equal)
      let compareMS=ms(comparison), editStart=ContinuousClock.now
      let edited=try encoded.editing(encoded.address(at:samples.count/2),to:samples[0],revision:UUID())
      let editMS=ms(editStart);XCTAssertEqual(edited.count,samples.count)
      func percentile(_ a:[Double],_ p:Double)->Double { a.sorted()[min(a.count-1,Int(ceil(Double(a.count)*p))-1)] }
      let report:[String:Any] = ["case":name,"samples":samples.count,"sourceBytes":samples.count*MemoryLayout<SpatialInkSample>.stride,
        "canonicalAllocatedBytes":samples.capacity*MemoryLayout<SpatialInkSample>.stride,
        "relationPayloadBytes":encoded.payloadBytes,"meshBytes":meshBytes,"initialPreparedNodes":nodes,
        "meshAuxiliaryBytesBesideCanonical":auxiliaryBytes,"visibleCPUViewBytes":visibleCPUBytes,"selectedGPUNodeBytes":selectedGPUBytes,
        "processFootprintBytesAfterRaster":footprint,
        "footprintScope":"process snapshots with source descriptor retained after complete raster; not peak transient allocations",
        "firstSourcePreparationMilliseconds":firstPrepareMS,"firstSourcePrepareRasterMilliseconds":firstTotalMS,
        "mode":"fresh source+mesh+raster each repeat; warm code/device, not warm retained geometry",
        "prepareMilliseconds":preparation,"prepareRasterMilliseconds":total,
        "p50Milliseconds":total.map { percentile($0,0.5) },"p95Milliseconds":total.map { percentile($0,0.95) },
        "p99Milliseconds":total.map { percentile($0,0.99) },"coldEncodeMilliseconds":encodeMS,
        "decodeMilliseconds":decodeMS,"comparisonIncludingEncodeMilliseconds":compareMS,"editMilliseconds":editMS]
      rows.append(report)
      // Gate is decided from the report, not adapted to whatever passes this run.
      print("INK_RELATION_COST \(name) p50 \(total.map { percentile($0,0.5) })")
    }
    let attachment=XCTAttachment(data:try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
    attachment.name="relation-s1-costs";attachment.lifetime = .keepAlways;add(attachment)
  }
  func testPrivateMeasuredSourceRoundTripAndGPU() throws {
    #if os(macOS)
    let url = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent(".build/gui286-baseline/measured-private.json")
    #else
    let url = try XCTUnwrap(FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first)
      .appendingPathComponent("gui286-measured.json")
    #endif
    guard FileManager.default.fileExists(atPath:url.path) else {
      throw XCTSkip("Optional private measured corpus must be supplied separately; it is never committed.")
    }
    let data = try Data(contentsOf:url)
    let action = try JSONDecoder().decode(PageInkAction.self,from:data)
    let original = InkSampleRelations(action)
    let restored = original.restoredAction()
    XCTAssertEqual(restored,action);assertBits(action.samples.materialized(),restored.samples.materialized())
    XCTAssertEqual(original.header.tool,action.tool);XCTAssertEqual(original.header.sequence,action.sequence)
    let changedHeader=InkSampleRelations.Header(tool:.eraser,color:action.color,sequence:action.sequence)
    let other=InkSampleRelations(sourceID:action.id,measurements:action.samples,header:changedHeader)
    XCTAssertEqual(original.equality(to:other,eventBudget:0),.different)
    try verifyRender(action.samples.materialized(),name:"relative-private-measured",encoded:original)
  }
}

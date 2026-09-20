import CoreGraphics
import Foundation
import ImageIO
import NotebookCore
import XCTest
@testable import Notebook

final class InkVisibleRangeTests: XCTestCase {
  private func source(_ samples: [SpatialInkSample],tool: SpatialInkTool = .pen) -> InkSampleRelations {
    .init(sourceID:UUID(),revision:UUID(),samples:samples,header:.init(tool:tool,color:.init(red:0.2,green:0.4,blue:0.8)))
  }
  private func sample(_ x: Double,_ y: Double,_ i: Int) -> SpatialInkSample {
    .init(point:.init(x:x,y:y),timeOffset:Double(i)/128,width:3+Double(i%7)/4,
      opacity:0.25+Double(i%4)/8,force:Double(i%5)/4,azimuth:Double(i%9)/4,altitude:1)
  }
  func testIncompressibleCanonicalLiteralsShareOneImmutableBuffer() throws {
    var samples=(0..<4096).map { i in sample(Double(i)/2+sin(Double(i))/8,sin(Double(i)*1.7)*40,i) }
    let original=samples[0],measured=source(samples)
    var buffers:[InkSampleRelations.SampleBuffer]=[]
    func visit(_ node: InkSampleRelations.Sequence) {
      switch node.content {
      case .block(.literal(let values)): buffers.append(values.buffer)
      case .pair(let a,let b): visit(a);visit(b)
      default: XCTFail("The incompressible fixture must remain literal")
      }
    }
    visit(measured.storage.root)
    XCTAssertEqual(buffers.count,16)
    let buffer=try XCTUnwrap(buffers.first)
    XCTAssertTrue(buffers.allSatisfy { $0 === buffer })
    let canonical=samples.withUnsafeBufferPointer { UInt(bitPattern:$0.baseAddress!) }
    XCTAssertEqual(buffer.samples.withUnsafeBufferPointer { UInt(bitPattern:$0.baseAddress!) },canonical)
    XCTAssertEqual(measured.payloadBytes-measured.auxiliaryBytes,samples.capacity*MemoryLayout<SpatialInkSample>.stride)
    XCTAssertLessThan(measured.auxiliaryBytes,samples.count*MemoryLayout<SpatialInkGeometry.Node>.stride/4)
    samples[0]=sample(900,900,0)
    XCTAssertTrue(InkSampleRelations.sameBits(measured.sample(at:0),original),"A caller mutation must COW, never alter accepted events")
    // A small view may retain a large buffer: the standalone accounting must
    // count the whole allocation, once, not just its logical slice length.
    let tiny=InkSampleRelations.Sequence(block:.literal(.init(buffer:buffer,range:0..<1)))
    var seen=Set<ObjectIdentifier>()
    XCTAssertGreaterThan(tiny.allocationSummary(seen:&seen).bytes,4096*MemoryLayout<SpatialInkSample>.stride)
    let batch=SpatialInkMesh.Batch(source:measured,projection:.local)
    XCTAssertEqual(batch.preparedNodeCount,0)
    let visibleCPU=(0..<batch.chunkCount).reduce(0) { $0+batch.prepareChunk($1).chunk.byteCount }
    let reference=SpatialInkMesh.referencePage(.init(actions:[measured.restoredAction()])).batches[0]
    let canonicalBytes=buffer.samples.capacity*MemoryLayout<SpatialInkSample>.stride
    XCTAssertLessThanOrEqual(Double(canonicalBytes+batch.auxiliaryBytes+visibleCPU),Double(canonicalBytes+reference.byteCount)*1.1)
  }
  func testHundredThousandSmallStrokesPackIntoTheExistingChunkIndex() throws {
    let actor=UUID(),surface=SurfaceID.cover(UUID())
    let actions=(0..<100_000).map { i in SpatialInkAction(tool:.pen,
      spans:[.init(surface:surface,samples:[sample(Double(i)*20,10,0),sample(Double(i)*20+8,12,1)])],
      stamp:.init(counter:UInt64(i+1),actor:actor)) }
    let journal=SpatialInkJournal(actions:actions,stamp:actions.last!.stamp)
    let start=ContinuousClock.now,mesh=try SpatialInkMesh.prepare(surface:surface,journal:journal)
    let elapsed=start.duration(to:.now).components
    let batch=try XCTUnwrap(mesh.batches.first)
    XCTAssertEqual(mesh.batches.count,1);XCTAssertEqual(batch.parts.count,1)
    XCTAssertEqual(batch.chunkCount,100_000);XCTAssertEqual(batch.preparedNodeCount,200_000)
    let q=batch.query(viewport:.init(x:1_000_000,y:0,width:10,height:20),affine:.init())
    XCTAssertEqual(q.chunks,[50_000]);XCTAssertLessThan(q.cost.visitedNodes,100)
    let chunk=batch.prepareChunk(50_000).chunk
    XCTAssertEqual(chunk.nodes.first?.position.x,1_000_000)
    XCTAssertLessThan(chunk.byteCount,256,"A visible view shares prepared nodes/LOD, not another copy")
    let record:[String:Any]=["strokes":actions.count,"parts":batch.parts.count,"chunks":batch.chunkCount,
      "meshBytes":batch.byteCount,"queryVisits":q.cost.visitedNodes,
      "prepareMilliseconds":Double(elapsed.seconds)*1000+Double(elapsed.attoseconds)/1e15]
    let a=XCTAttachment(data:try JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
    a.name="relation-small-strokes-costs";a.lifetime = .keepAlways;add(a)
  }
  func testMillionEventRepeatBuildsOnlyVisibleNeighbourhoodBeforeGPU() throws {
    let body=source((0..<100).map { sample(Double($0),sin(Double($0)/4)*4,$0) })
      .settingExit(.init(x:InkDyadic(100)!,y:.zero,time:InkDyadic(1)!),revision:UUID())
    var records:[[String:Any]]=[]
    for count in [10_000,100_000,1_000_000] {
      let start=ContinuousClock.now
      let repeated=try XCTUnwrap(body.repeated(count/100,revision:UUID()))
      let mesh=SpatialInkMesh.Batch(source:repeated,projection:.local)
      let elapsed=start.duration(to:.now).components
      XCTAssertEqual(mesh.preparedNodeCount,0)
      XCTAssertLessThan(mesh.byteCount,40_000)
      let area=CGRect(x:Double(count/2),y:-8,width:48,height:16)
      let q=mesh.query(viewport:area,affine:.init())
      XCTAssertFalse(q.chunks.isEmpty)
      var decoded=0,nodes=0
      for id in q.chunks { let p=mesh.prepareChunk(id);decoded += p.decodedPoints;nodes += p.chunk.nodes.count }
      XCTAssertLessThan(decoded+q.cost.decodedSamples,count/3)
      XCTAssertLessThan(q.cost.visitedNodes,1000)
      XCTAssertLessThan(nodes,800)
      records.append(["logicalEvents":count,"initialDisplayNodes":mesh.preparedNodeCount,"retainedBytes":mesh.byteCount,
        "sourcePrepareMilliseconds":Double(elapsed.seconds)*1000+Double(elapsed.attoseconds)/1e15,
        "visibleChunks":q.chunks.count,"indexVisits":q.cost.visitedNodes,"boundsEvents":q.cost.decodedSamples,
        "geometryEvents":decoded,"visibleNodes":nodes])
      // Whole pose changes only the query/projection; it does not allocate the hidden source.
      let translated=mesh.query(viewport:area.offsetBy(dx:100,dy:20),affine:.init(.init(1,1,100,20)))
      XCTAssertEqual(translated.chunks,q.chunks)
    }
    let a=XCTAttachment(data:try JSONSerialization.data(withJSONObject:records,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
    a.name="relation-visible-range-costs";a.lifetime = .keepAlways;add(a)
  }
  func testWorldRangeBoundsStayRelativeAcrossTiles() throws {
    let origin=WorldPoint(tileX:900_000,tileY:-800_000,localX:20,localY:40)
    let samples=(0..<10_000).map { i in SpatialInkSample(point:.zero,worldPoint:origin.offsetBy(x:Double(i)/2,y:sin(Double(i)/10)),
      timeOffset:Double(i)/128,width:4,opacity:0.5,force:1,azimuth:0,altitude:1) }
    let measured=source(samples)
    let mesh=SpatialInkMesh.Batch(source:measured,projection:.world(origin),sampleProjection:.init(origin:origin))
    XCTAssertEqual(mesh.preparedNodeCount,0)
    let q=mesh.query(viewport:.init(x:2500,y:-10,width:30,height:20),affine:.init())
    XCTAssertFalse(q.chunks.isEmpty)
    let points=q.chunks.reduce(0) { $0+mesh.prepareChunk($1).decodedPoints }
    XCTAssertLessThan(points+q.cost.decodedSamples,2500)
    for i in [0,255,256,4999,9999] { XCTAssertTrue(InkSampleRelations.sameBits(measured.sample(at:i),samples[i])) }
    let bounds=try measured.bounds(in:4999..<5100).bounds
    XCTAssertTrue(bounds.contains(CGPoint(x:Double(5000)/2,y:sin(500))))
  }
  func testLazyVisiblePenEraserAndAffineRastersMatchUnreducedSource() throws {
    let pen=(0..<4096).map { sample(20+Double($0)/8,100+sin(Double($0)/40)*30,$0) }
    let eraser=(0..<256).map { sample(220,60+Double($0)/3,$0) }
    let sources=[source(pen),source(eraser,tool:.eraser),source(Array(pen[1500..<2100]))]
    let lazy=SpatialInkMesh(batches:sources.map { .init(source:$0,projection:.local) })
    let drawing=PageInkDrawing(actions:sources.map { $0.restoredAction() })
    let reference=SpatialInkMesh.referencePage(drawing)
    let transforms=[InkAffine(.init(1,1,-190,-70)),
      InkAffine(x:.init(-0.8,0.6,320,0),y:.init(0.1,1.2,-80,0)),
      InkAffine(x:.init(0.04,0.1,20,0),y:.init(0.8,2.5,-260,0)),
      InkAffine(.init(0,1,64,-70))]
    for affine in transforms {
      let a=try XCTUnwrap(InkRasterRenderer.shared.render(mesh:lazy,size:.init(width:128,height:128),scale:2,affine:affine))
      let b=try XCTUnwrap(InkRasterRenderer.shared.render(mesh:reference,size:.init(width:128,height:128),scale:2,affine:affine))
      let left=Array(try XCTUnwrap(a.dataProvider?.data) as Data),right=Array(try XCTUnwrap(b.dataProvider?.data) as Data)
      XCTAssertEqual(left.count,right.count)
      XCTAssertLessThanOrEqual(zip(left,right).map { abs(Int($0)-Int($1)) }.max()!,2)
    }
  }
  func testStationaryRepeatUsesTheLastMeasurementWithoutUnboundedNormalization() throws {
    let body=source([sample(30,40,0),sample(30,40,1)])
    let repeated=try XCTUnwrap(body.repeated(500_000,revision:UUID()))
    let mesh=SpatialInkMesh.Batch(source:repeated,projection:.local)
    XCTAssertEqual(mesh.preparedNodeCount,0);XCTAssertEqual(mesh.chunkCount,1)
    let p=mesh.prepareChunk(0)
    XCTAssertEqual(p.decodedPoints,1)
    XCTAssertEqual(Array(p.chunk.nodes),SpatialInkGeometry.compact(source:source([sample(30,40,1)])))
    XCTAssertEqual(mesh.query(viewport:.init(x:25,y:35,width:10,height:10),affine:.init()).chunks,[0])
  }
  func testCoalescingAmbiguityPaysForTheExistingNormalizerInsteadOfChangingItsState() {
    let samples=(0..<4096).map { sample(Double($0)/8192,20,$0) }
    let measured=source(samples),batch=SpatialInkMesh.Batch(source:measured,projection:.local)
    XCTAssertGreaterThan(batch.preparedNodeCount,0)
    XCTAssertEqual(batch.expandedForTesting().nodes,SpatialInkGeometry.compact(source:measured))
    let literal=source([sample(0,0,0),sample(20,20,1),sample(0,0,2)])
    XCTAssertNotNil(SpatialInkGeometry.RelativeSource(literal,projection:.init()))
    XCTAssertNotEqual(literal.storage.root.geometry.minimumSpacing,0,"A closed endpoint does not erase the painted middle")
  }
}

import CoreGraphics
import Foundation
import ImageIO
@testable import NotebookCore
import XCTest
@testable import Notebook

final class InkVisibleRangeTests: XCTestCase {
  func testSampleFreeSubpixelBoundsAgainstFullRaster() throws {
    let count=100_000,renderer=InkRasterRenderer.shared
    let samples=(0..<count).map { i in SpatialInkSample(point:.init(x:Double(i),y:64+sin(Double(i)*0.37)*12),
      timeOffset:Double(i)/128,width:4+Double(i%13)/4,opacity:0.25+Double(i%7)/16,force:0.75,azimuth:0,altitude:1) }
    let value=source(samples),batch=SpatialInkMesh.Batch(source:value,projection:.local)
    XCTAssertEqual(batch.preparedNodeCount,0)
    let color=SIMD4<Float>(0.2,0.4,0.8,1)
    let points=samples.map { SpatialInkGeometry.renderPoint(from:$0,color:color) }
    let nodes=points.indices.map { InkRenderGeometry.node(at:$0,in:points) }
    // Deliberately broad oracle bounds defeat sample rejection. Every original
    // node is drawn with no LOD, independently of the candidate's admission.
    let chunks=SpatialInkGeometry.chunks(for:nodes,color:color,eraser:false,buildLOD:false).map {
      SpatialInkGeometry.Chunk(nodes:$0.nodes,bounds:.init(x:-count,y:-count,width:count*2,height:count*2),color:$0.color,flags:$0.flags)
    }
    let reference=SpatialInkMesh(batches:[.init(tool:.pen,nodes:nodes,chunks:chunks,projection:.local)])
    func milliseconds(_ start: ContinuousClock.Instant) -> Double {
      let d=start.duration(to:.now).components;return Double(d.seconds)*1000+Double(d.attoseconds)/1e15
    }
    var records:[[String:Any]]=[]
    for (size,scale):(CGSize,Double) in [(.init(width:512,height:128),2),(.init(width:512.2,height:128.3),1.25)] {
      let grid=try XCTUnwrap(renderer.sampleGrid(viewport:size,pixels:.init(width:ceil(size.width*scale),height:ceil(size.height*scale))))
      for phase in 0..<32 {
        let affine=InkAffine(.init(500/Float(count),0.0005,6,64+Float(phase)/64))
        let start=ContinuousClock.now
        let q=batch.query(viewport:.init(origin:.zero,size:size),affine:affine,admitting:{ grid.mayCover($0,affine:affine) })
        let queryMS=milliseconds(start)
        let possible = !q.chunks.isEmpty
        if !possible { XCTAssertEqual(q.cost.decodedSamples,0);XCTAssertLessThan(q.cost.visitedNodes,4) }
        let renderStart=ContinuousClock.now
        let actual=try XCTUnwrap(renderer.render(mesh:.init(batches:[batch]),size:size,scale:scale,affine:affine))
        let renderMS=milliseconds(renderStart),fullStart=ContinuousClock.now
        let image=try XCTUnwrap(renderer.render(mesh:reference,size:size,scale:scale,affine:affine))
        let fullMS=milliseconds(fullStart)
        let data=try XCTUnwrap(image.dataProvider?.data) as Data
        let visible=data.contains { $0 != 0 }
        XCTAssertEqual(try XCTUnwrap(actual.dataProvider?.data) as Data,data,"Coverage phase \(phase), density \(scale)")
        if !possible { XCTAssertFalse(visible,"A rejected source must cover no sample") }
        records.append(["phase":phase,"scale":scale,"possible":possible,"visible":visible,"selectedRanges":q.chunks.count,
          "queryReads":q.cost.decodedSamples,"queryVisits":q.cost.visitedNodes,"queryMilliseconds":queryMS,
          "rasterMilliseconds":renderMS,"fullRasterMilliseconds":fullMS])
      }
    }
    XCTAssertTrue(records.contains { $0["possible"] as? Bool == false })
    XCTAssertTrue(records.contains { $0["visible"] as? Bool == true })
    // Exact vector access remains independent of current raster sample phase.
    XCTAssertFalse(batch.query(viewport:.init(x:0,y:0,width:count,height:128),affine:.init()).chunks.isEmpty)
    let proof=XCTAttachment(data:try JSONSerialization.data(withJSONObject:records,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
    proof.name="sample-free-subpixel-phases";proof.lifetime = .keepAlways;add(proof)
  }
  func testSampleFreeRepeatKeepsSourceCompactThroughFreehandRaster() throws {
    let renderer=InkRasterRenderer.shared,size=CGSize(width:512,height:128)
    let grid=try XCTUnwrap(renderer.sampleGrid(viewport:size,pixels:.init(width:1024,height:256)))
    var records:[[String:Any]]=[]
    func milliseconds(_ start: ContinuousClock.Instant) -> Double {
      let d=start.duration(to:.now).components;return Double(d.seconds)*1000+Double(d.attoseconds)/1e15
    }
    for count in [10_000,100_000,1_000_000] {
      let start=ContinuousClock.now
      let samples: [SpatialInkSample]=(0..<100).map { i in
        let point=SpatialPoint(x:Double(i),y:64+sin(Double(i)*0.37)*12)
        return SpatialInkSample(point:point,timeOffset:Double(i)/128,width:4+Double(i%13)/4,
          opacity:0.25+Double(i%7)/16,force:0.75,azimuth:0,altitude:1)
      }
      let body=source(samples).settingExit(.init(x:InkDyadic(100)!,y:.zero,time:.one),revision:UUID())
      let value=try XCTUnwrap(body.repeated(count/100,revision:UUID()))
      let batch=SpatialInkMesh.Batch(source:value,projection:.local),sourceMS=milliseconds(start)
      let affine=InkAffine(.init(500/Float(count),0.0005,6,64+5.0/64))
      let q=batch.query(viewport:.init(origin:.zero,size:size),affine:affine,admitting:{ grid.mayCover($0,affine:affine) })
      XCTAssertTrue(q.chunks.isEmpty);XCTAssertEqual(q.cost.decodedSamples,0);XCTAssertLessThan(q.cost.visitedNodes,4)
      let raster=try XCTUnwrap(renderer.render(mesh:.init(batches:[batch]),size:size,scale:2,affine:affine))
      let sourceToRasterMS=milliseconds(start)
      XCTAssertFalse((try XCTUnwrap(raster.dataProvider?.data) as Data).contains { $0 != 0 })
      let ink=NotebookFreehand(layers:[.init(tool:.pen,color:value.header.color,
        measured:.init(sourceID:value.sourceID,measurements:value.measurements,frame:.init(x:0,y:0,width:Double(count),height:128)))])
      let whole=NotebookGraphicTransform(a:Double(affine.x.x),b:0,c:0,d:Double(affine.y.y),tx:6/Double(count),ty:Double(affine.y.z)/128)
      let freehandStart=ContinuousClock.now
      let image=try XCTUnwrap(renderer.freehand(ink,transform:whole,size:.init(width:count,height:128),region:.init(origin:.zero,size:size),scale:2,mask:false))
      let freehandMS=milliseconds(freehandStart)
      XCTAssertEqual(try XCTUnwrap(image.dataProvider?.data) as Data,try XCTUnwrap(raster.dataProvider?.data) as Data)
      XCTAssertEqual(ink.geometry.preparedNodeCount,0);XCTAssertEqual(ink.geometry.sourceNodeCount,count)
      let controlStart=ContinuousClock.now
      let control=batch.query(viewport:.init(origin:.zero,size:size),affine:affine)
      var reads=control.cost.decodedSamples,nodes=0
      for id in control.chunks { let p=batch.prepareChunk(id);reads += p.decodedPoints;nodes += p.chunk.nodes.count }
      let controlMS=milliseconds(controlStart)
      XCTAssertGreaterThan(nodes,count);XCTAssertGreaterThan(reads,count)
      records.append(["events":count,"sourceBytes":value.payloadBytes,"sourceBuildMilliseconds":sourceMS,
        "sourceToRasterMilliseconds":sourceToRasterMS,"freehandToRasterMilliseconds":freehandMS,
        "visitedNodes":q.cost.visitedNodes,"decodedEvents":q.cost.decodedSamples,"preparedNodes":0,
        "unfilteredQueryPrepareMilliseconds":controlMS,"unfilteredReads":reads,"unfilteredNodes":nodes])
    }
    let proof=XCTAttachment(data:try JSONSerialization.data(withJSONObject:records,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
    proof.name="sample-free-repeat-costs";proof.lifetime = .keepAlways;add(proof)
  }
  private func source(_ samples: [SpatialInkSample],tool: SpatialInkTool = .pen) -> InkSampleRelations {
    .init(sourceID:UUID(),revision:UUID(),samples:samples,header:.init(tool:tool,color:.init(red:0.2,green:0.4,blue:0.8)))
  }
  private func sample(_ x: Double,_ y: Double,_ i: Int) -> SpatialInkSample {
    .init(point:.init(x:x,y:y),timeOffset:Double(i)/128,width:3+Double(i%7)/4,
      opacity:0.25+Double(i%4)/8,force:Double(i%5)/4,azimuth:Double(i%9)/4,altitude:1)
  }
  func testIncompressibleCanonicalLiteralsShareOneImmutableBuffer() throws {
    let paper=(0..<4096).map { i in sample(Double(i)/2+sin(Double(i))/8,sin(Double(i)*1.7)*40,i) }
    var samples=paper.map { s in SpatialInkSample(point:s.point,worldPoint:.init(x:s.point.x,y:s.point.y),
      timeOffset:s.timeOffset,width:s.width,opacity:s.opacity,force:s.force,azimuth:s.azimuth,altitude:s.altitude) }
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
    let sourceBytes=samples.capacity*MemoryLayout<SpatialInkSample>.stride
    XCTAssertGreaterThanOrEqual(measured.payloadBytes,sourceBytes)
    XCTAssertLessThan(measured.payloadBytes-sourceBytes,25_000)
    XCTAssertLessThan(measured.auxiliaryBytes,samples.count*MemoryLayout<SpatialInkGeometry.Node>.stride/4)
    samples[0]=sample(900,900,0)
    XCTAssertTrue(InkSampleRelations.sameBits(measured.sample(at:0),original),"A caller mutation must COW, never alter accepted events")
    // A small view may retain a large buffer: the standalone accounting must
    // count the whole allocation, once, not just its logical slice length.
    let tiny=InkSampleRelations.Sequence(block:.literal(.init(buffer:buffer,range:0..<1)))
    var seen=Set<ObjectIdentifier>()
    XCTAssertGreaterThan(tiny.allocationSummary(seen:&seen).bytes,4096*MemoryLayout<SpatialInkSample>.stride)
    let batch=SpatialInkMesh.Batch(source:measured,projection:.world(.zero),sampleProjection:.init(origin:.zero))
    XCTAssertEqual(batch.preparedNodeCount,0)
    let visibleCPU=(0..<batch.chunkCount).reduce(0) { $0+batch.prepareChunk($1..<($1+1)).chunk.byteCount }
    let reference=SpatialInkMesh.referencePage(.init(actions:[PageInkAction(tool:.pen,color:measured.header.color,samples:paper)])).batches[0]
    let canonicalBytes=buffer.samples.capacity*MemoryLayout<SpatialInkSample>.stride
    XCTAssertLessThanOrEqual(Double(canonicalBytes+batch.auxiliaryBytes+visibleCPU),Double(canonicalBytes+reference.byteCount)*1.1)
  }
  func testHundredThousandSmallStrokesPackIntoTheExistingChunkIndex() throws {
    let actor=UUID(),surface=SurfaceID.cover(UUID())
    let sourceStart=ContinuousClock.now
    let actions=(0..<100_000).map { i in SpatialInkAction(tool:.pen,
      spans:[.init(surface:surface,samples:[sample(Double(i)*20,10,0),sample(Double(i)*20+8,12,1)])],
      stamp:.init(counter:UInt64(i+1),actor:actor)) }
    let sourceElapsed=sourceStart.duration(to:.now).components
    XCTAssertTrue(actions.allSatisfy { !$0.spans[0].samples.storage.root.hasStoredSummary })
    let sourceBytes=actions.reduce(0) { $0+$1.spans[0].samples.payloadBytes }
    let journal=SpatialInkJournal(actions:actions,stamp:actions.last!.stamp)
    let start=ContinuousClock.now,mesh=try SpatialInkMesh.prepare(surface:surface,journal:journal)
    let elapsed=start.duration(to:.now).components
    let batch=try XCTUnwrap(mesh.batches.first)
    XCTAssertEqual(mesh.batches.count,1);XCTAssertEqual(batch.parts.count,1)
    XCTAssertEqual(batch.chunkCount,100_000);XCTAssertEqual(batch.preparedNodeCount,200_000)
    let q=batch.query(viewport:.init(x:1_000_000,y:0,width:10,height:20),affine:.init())
    XCTAssertEqual(q.chunks,[50_000..<50_001]);XCTAssertLessThan(q.cost.visitedNodes,100)
    let chunk=batch.prepareChunk(50_000..<50_001).chunk
    XCTAssertEqual(chunk.nodes.first?.position.x,1_000_000)
    XCTAssertLessThan(chunk.byteCount,256,"A visible view shares prepared nodes/LOD, not another copy")
    let record:[String:Any]=["strokes":actions.count,"parts":batch.parts.count,"chunks":batch.chunkCount,
      "meshBytes":batch.byteCount,"queryVisits":q.cost.visitedNodes,
      "sourceLayoutBytes":sourceBytes,
      "sourcePrepareMilliseconds":Double(sourceElapsed.seconds)*1000+Double(sourceElapsed.attoseconds)/1e15,
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
    let p=mesh.prepareChunk(0..<1)
    XCTAssertEqual(p.decodedPoints,1)
    XCTAssertEqual(Array(p.chunk.nodes),SpatialInkGeometry.compact(source:source([sample(30,40,1)])))
    XCTAssertEqual(mesh.query(viewport:.init(x:25,y:35,width:10,height:10),affine:.init()).chunks,[0..<1])
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
  func testWholeStraightRepeatRasterCostIncludesQueryAndPreparation() throws {
    let body=source((0..<100).map { i in SpatialInkSample(point:.init(x:Double(i),y:10),
      timeOffset:Double(i)/128,width:4,opacity:0.5,force:0.75,azimuth:0,altitude:1) })
      .settingExit(.init(x:InkDyadic(100)!,y:.zero,time:.one),revision:UUID())
    func milliseconds(_ start: ContinuousClock.Instant) -> Double {
      let c=start.duration(to:.now).components;return Double(c.seconds)*1000+Double(c.attoseconds)/1e15
    }
    var records:[[String:Any]]=[]
    for count in [10_000,100_000,1_000_000] {
      let start=ContinuousClock.now
      let repeated=try XCTUnwrap(body.repeated(count/100,revision:UUID()))
      let batch=SpatialInkMesh.Batch(source:repeated,projection:.local)
      let affine=InkAffine(.init(500/Float(count),4,6,10))
      let image=try XCTUnwrap(InkRasterRenderer.shared.render(mesh:.init(batches:[batch]),
        size:.init(width:512,height:128),scale:2,affine:affine))
      let elapsed=milliseconds(start)
      let query=batch.query(viewport:.init(x:0,y:0,width:512,height:128),affine:affine)
      var decoded=0,nodes=0
      for id in query.chunks { let p=batch.prepareChunk(id);decoded += p.decodedPoints;nodes += p.chunk.nodes.count }
      XCTAssertEqual(query.chunks.count,1);XCTAssertEqual(decoded,4);XCTAssertEqual(nodes,4)
      let reference=SpatialInkMesh.referencePage(.init(actions:[repeated.restoredAction()]))
      let control=try XCTUnwrap(InkRasterRenderer.shared.render(mesh:reference,
        size:.init(width:512,height:128),scale:2,affine:affine))
      let a=Array(try XCTUnwrap(image.dataProvider?.data) as Data),b=Array(try XCTUnwrap(control.dataProvider?.data) as Data)
      XCTAssertLessThanOrEqual(zip(a,b).map { abs(Int($0)-Int($1)) }.max()!,2)
      XCTAssertTrue(a.contains { $0 > 0 })
      records.append(["events":count,"sourceToRasterMilliseconds":elapsed,"chunks":query.chunks.count,
        "indexVisits":query.cost.visitedNodes,"boundsEvents":query.cost.decodedSamples,
        "displayEvents":decoded,"nodes":nodes,"sourceBytes":repeated.payloadBytes])
      if count == 1_000_000 {
        let png=NSMutableData(),destination=try XCTUnwrap(CGImageDestinationCreateWithData(png,"public.png" as CFString,1,nil))
        CGImageDestinationAddImage(destination,image,nil);XCTAssertTrue(CGImageDestinationFinalize(destination))
        let a=XCTAttachment(data:png as Data,uniformTypeIdentifier:"public.png")
        a.name="whole-million-straight-repeat";a.lifetime = .keepAlways;add(a)
      }
    }
    let a=XCTAttachment(data:try JSONSerialization.data(withJSONObject:records,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
    a.name="whole-straight-repeat-costs";a.lifetime = .keepAlways;add(a)
  }
  func testUnreducibleCurvePreparationKeepsTheFullRaster() throws {
    let count=100_000
    let samples=(0..<count).map { i in SpatialInkSample(point:.init(x:Double(i),y:64+sin(Double(i)*0.37)*12),
      timeOffset:Double(i)/128,width:4+Double(i%13)/4,opacity:0.25+Double(i%7)/16,force:0.75,azimuth:0,altitude:1) }
    func milliseconds(_ start: ContinuousClock.Instant) -> Double {
      let d=start.duration(to:.now).components;return Double(d.seconds)*1000+Double(d.attoseconds)/1e15
    }
    let start=ContinuousClock.now,value=source(samples)
    let mesh=SpatialInkMesh(batches:[.init(source:value,projection:.local)])
    let sourceMS=milliseconds(start),renderStart=ContinuousClock.now
    let affine=InkAffine(.init(500/Float(count),1,6,0))
    let actual=try XCTUnwrap(InkRasterRenderer.shared.render(mesh:mesh,size:.init(width:512,height:128),scale:2,affine:affine))
    let renderMS=milliseconds(renderStart)
    let color=SIMD4<Float>(0.2,0.4,0.8,1)
    let points=samples.map { SpatialInkGeometry.renderPoint(from:$0,color:color) }
    let nodes=points.indices.map { InkRenderGeometry.node(at:$0,in:points) }
    let reference=SpatialInkMesh(batches:[.init(tool:.pen,nodes:nodes,
      chunks:SpatialInkGeometry.chunks(for:nodes,color:color,eraser:false,buildLOD:false),projection:.local)])
    let control=try XCTUnwrap(InkRasterRenderer.shared.render(mesh:reference,size:.init(width:512,height:128),scale:2,affine:affine))
    let a=Array(try XCTUnwrap(actual.dataProvider?.data) as Data),b=Array(try XCTUnwrap(control.dataProvider?.data) as Data)
    XCTAssertEqual(a,b);XCTAssertTrue(a.contains { $0 > 0 })
    let query=mesh.batches[0].query(viewport:.init(x:0,y:0,width:512,height:128),affine:affine)
    XCTAssertTrue(query.chunks.allSatisfy { $0.count == 1 })
    let record:[String:Any]=["events":count,"sourceMilliseconds":sourceMS,"queryToRasterMilliseconds":renderMS,
      "sourceToRasterMilliseconds":sourceMS+renderMS,"queryVisits":query.cost.visitedNodes,
      "chunks":query.chunks.count,"sourceBytes":value.payloadBytes,"maxChannelError":0]
    let proof=XCTAttachment(data:try JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
    proof.name="unreducible-detail-search-costs";proof.lifetime = .keepAlways;add(proof)
  }
  func testLocalBendKeepsExactRasterWithoutExpandingStraightNeighbours() throws {
    let samples=(0..<10_000).map { i in SpatialInkSample(point:.init(x:Double(i),y:10),
      timeOffset:Double(i)/128,width:4,opacity:0.5,force:0.75,azimuth:0,altitude:1) }
    let body=source(samples)
    let changed=SpatialInkSample(point:.init(x:5000,y:22),timeOffset:5000.0/128,width:9,opacity:0.75,force:0.75,azimuth:0,altitude:1)
    let value=try body.editing(body.address(at:5000),to:changed,revision:UUID())
    let actual=SpatialInkMesh(batches:[.init(source:value,projection:.local)])
    var original=samples;original[5000]=changed
    let color=SIMD4<Float>(0.2,0.4,0.8,1)
    let points=original.map { SpatialInkGeometry.renderPoint(from:$0,color:color) }
    let nodes=points.indices.map { InkRenderGeometry.node(at:$0,in:points) }
    let reference=SpatialInkMesh(batches:[.init(tool:.pen,nodes:nodes,
      chunks:SpatialInkGeometry.chunks(for:nodes,color:color,eraser:false,buildLOD:false),projection:.local)])
    let transforms=[InkAffine(.init(0.05,4,6,10)),InkAffine(.init(0.05,0.05,6,64.0625)),
      InkAffine(.init(1,1,-4900,30)),InkAffine(x:.init(-0.04,0.7,440,0),y:.init(0.004,2,10,0)),
      InkAffine(.init(0.05,1_000_000,6,-10_000_000+64))]
    var records:[[String:Any]]=[]
    for (i,affine) in transforms.enumerated() {
      let start=ContinuousClock.now
      let a=try XCTUnwrap(InkRasterRenderer.shared.render(mesh:actual,size:.init(width:512,height:128),scale:2,affine:affine))
      let elapsed=start.duration(to:.now).components
      let b=try XCTUnwrap(InkRasterRenderer.shared.render(mesh:reference,size:.init(width:512,height:128),scale:2,affine:affine))
      let left=Array(try XCTUnwrap(a.dataProvider?.data) as Data),right=Array(try XCTUnwrap(b.dataProvider?.data) as Data)
      let maxError=zip(left,right).map { abs(Int($0)-Int($1)) }.max()!
      let q=actual.batches[0].query(viewport:.init(x:0,y:0,width:512,height:128),affine:affine)
      let prepared=q.chunks.map { actual.batches[0].prepareChunk($0) }
      let reads=prepared.reduce(q.cost.decodedSamples) { $0+$1.decodedPoints }
      if affine.preservesAxisAlignment { XCTAssertLessThan(reads,2000) }
      else { XCTAssertTrue(q.chunks.allSatisfy { $0.count == 1 }) }
      XCTAssertLessThanOrEqual(maxError,2)
      if i != 4 { XCTAssertTrue(right.contains { $0 > 0 }) }
      records.append(["case":i,"chunks":q.chunks.count,"reads":reads,"nodes":prepared.reduce(0) { $0+$1.chunk.nodes.count },
        "maxChannelError":maxError,"rasterMilliseconds":Double(elapsed.seconds)*1000+Double(elapsed.attoseconds)/1e15])
      if i == 0 {
        let png=NSMutableData(),destination=try XCTUnwrap(CGImageDestinationCreateWithData(png,"public.png" as CFString,1,nil))
        CGImageDestinationAddImage(destination,a,nil);XCTAssertTrue(CGImageDestinationFinalize(destination))
        let proof=XCTAttachment(data:png as Data,uniformTypeIdentifier:"public.png")
        proof.name="local-bend-coarse-neighbours";proof.lifetime = .keepAlways;add(proof)
      }
    }
    let proof=XCTAttachment(data:try JSONSerialization.data(withJSONObject:records,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
    proof.name="local-bend-range-costs";proof.lifetime = .keepAlways;add(proof)
  }
  func testDistantCurveKeepsCoverageAcrossSubpixelRasterPhase() throws {
    let body=source((0..<100).map { i in SpatialInkSample(point:.init(x:Double(i),y:sin(Double(i)*0.07)*4),
      timeOffset:Double(i)/128,width:4,opacity:1,force:1,azimuth:0,altitude:1) })
      .settingExit(.init(x:InkDyadic(100)!,y:.zero,time:.one),revision:UUID())
    let value=try XCTUnwrap(body.repeated(10_000,revision:UUID()))
    let actual=SpatialInkMesh(batches:[.init(source:value,projection:.local)])
    let full=SpatialInkMesh.referencePage(.init(actions:[value.restoredAction()]))
    // The oracle must not run the same LOD selection as the path under test.
    let reference=SpatialInkMesh(batches:full.batches.map { batch in
      .init(tool:batch.tool,projection:batch.projection,parts:batch.parts.map { part in
        guard case .prepared(let nodes,let chunks,_)=part.storage else { fatalError("Expected explicit oracle") }
        return .init(nodes:nodes,chunks:chunks.map { .init(nodes:$0.nodes,bounds:$0.bounds,color:$0.color,flags:$0.flags) })
      })
    })
    var records:[[String:Any]]=[]
    for (scale,offset):(Float,Float) in [(0.0005,64),(0.0005,64.0625),(0.1,64.0625)] {
      let affine=InkAffine(.init(scale,scale,6,offset))
      let a=try XCTUnwrap(InkRasterRenderer.shared.render(mesh:actual,size:.init(width:512,height:128),scale:2,affine:affine))
      let b=try XCTUnwrap(InkRasterRenderer.shared.render(mesh:reference,size:.init(width:512,height:128),scale:2,affine:affine))
      let left=Array(try XCTUnwrap(a.dataProvider?.data) as Data),right=Array(try XCTUnwrap(b.dataProvider?.data) as Data)
      var sum=0,difference=0,shown=0,changed=0
      for i in stride(from:3,to:left.count,by:4) {
        sum += Int(right[i]);shown += Int(left[i]);difference += abs(Int(left[i])-Int(right[i]))
        if abs(Int(left[i])-Int(right[i])) > 2 { changed += 1 }
      }
      records.append(["scale":scale,"offset":offset,"referenceAlpha":sum,"actualAlpha":shown,"alphaL1":difference,"changedPixels":changed])
      if offset == 64.0625 {
        for (label,img) in [("actual",a),("reference",b)] {
          let png=NSMutableData(),destination=try XCTUnwrap(CGImageDestinationCreateWithData(png,"public.png" as CFString,1,nil))
          CGImageDestinationAddImage(destination,img,nil);XCTAssertTrue(CGImageDestinationFinalize(destination))
          let proof=XCTAttachment(data:png as Data,uniformTypeIdentifier:"public.png")
          proof.name="subpixel-curve-\(label)-\(scale)";proof.lifetime = .keepAlways;add(proof)
        }
      }
    }
    let a=XCTAttachment(data:try JSONSerialization.data(withJSONObject:records,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
    a.name="subpixel-curve-coverage";a.lifetime = .keepAlways;add(a)
    XCTAssertTrue(records.contains { ($0["referenceAlpha"] as! Int) > 0 },"Also test actual visible paint, not only blank phases")
    for record in records {
      let expected=record["referenceAlpha"] as! Int,error=record["alphaL1"] as! Int
      XCTAssertLessThanOrEqual(Double(error),max(2,Double(expected)*0.02),"Geometry tolerance is not a coverage guarantee: \(record)")
    }
  }
  func testWholeWorldStripUsesFourNodesAndKeepsAffinePixels() throws {
    let origin=WorldPoint(tileX:WorldPoint.maximumTileIndex-1000,tileY:-WorldPoint.maximumTileIndex+1000,localX:20,localY:40)
    let count=100_000
    let samples=(0..<count).map { i in SpatialInkSample(point:.zero,worldPoint:origin.offsetBy(x:Double(i),y:0),
      timeOffset:Double(i)/128,width:4,opacity:0.5,force:Double(i%5)/4,azimuth:0,altitude:1) }
    func milliseconds(_ start: ContinuousClock.Instant) -> Double {
      let c=start.duration(to:.now).components;return Double(c.seconds)*1000+Double(c.attoseconds)/1e15
    }
    let cold=ContinuousClock.now,measured=source(samples),sourceMS=milliseconds(cold)
    let start=ContinuousClock.now
    let batch=SpatialInkMesh.Batch(source:measured,projection:.world(origin),sampleProjection:.init(origin:origin))
    let affine=InkAffine(.init(500/Float(count),4,6,64))
    let image=try XCTUnwrap(InkRasterRenderer.shared.render(mesh:.init(batches:[batch]),
      size:.init(width:512,height:128),scale:2,affine:affine))
    let rasterMS=milliseconds(start)
    let query=batch.query(viewport:.init(x:0,y:0,width:512,height:128),affine:affine)
    XCTAssertEqual(query.chunks,[0..<1]);XCTAssertEqual(query.cost.decodedSamples,0)
    XCTAssertEqual(batch.prepareChunk(0..<1).decodedPoints,4)
    XCTAssertEqual(batch.prepareChunk(0..<1).chunk.nodes.count,4)
    let transforms=[affine,InkAffine(.init(1,1,-Float(count)/2,64)),
      InkAffine(x:.init(-0.004,0.2,450,0),y:.init(0.0001,4,50,0))]
    for edited in [false,true] {
      var events=samples
      let value:InkSampleRelations
      if edited {
        let i=count/2,p=events[i]
        events[i]=SpatialInkSample(point:p.point,worldPoint:p.worldPoint!.offsetBy(x:0,y:12),
          timeOffset:p.timeOffset,width:12,opacity:0.9,force:p.force,azimuth:p.azimuth,altitude:p.altitude)
        value=try measured.editing(measured.address(at:i),to:events[i],revision:UUID())
      } else { value=measured }
      let actual=SpatialInkMesh(batches:[.init(source:value,projection:.world(origin),sampleProjection:.init(origin:origin))])
      let paper=events.map { p in SpatialInkSample(point:origin.delta(to:p.worldPoint!),timeOffset:p.timeOffset,
        width:p.width,opacity:p.opacity,force:p.force,azimuth:p.azimuth,altitude:p.altitude) }
      let reference=SpatialInkMesh.referencePage(.init(actions:[.init(tool:.pen,color:value.header.color,samples:paper)]))
      for transform in transforms {
        let a=try XCTUnwrap(InkRasterRenderer.shared.render(mesh:actual,size:.init(width:512,height:128),scale:2,affine:transform))
        let b=try XCTUnwrap(InkRasterRenderer.shared.render(mesh:reference,size:.init(width:512,height:128),scale:2,affine:transform))
        let left=Array(try XCTUnwrap(a.dataProvider?.data) as Data),right=Array(try XCTUnwrap(b.dataProvider?.data) as Data)
        XCTAssertLessThanOrEqual(zip(left,right).map { abs(Int($0)-Int($1)) }.max()!,2,"edited \(edited)")
        XCTAssertTrue(left.contains { $0 > 0 })
      }
    }
    let record:[String:Any]=["events":count,"coldSourceMilliseconds":sourceMS,"sourceToRasterMilliseconds":sourceMS+rasterMS,
      "preparedSourceToRasterMilliseconds":rasterMS,"chunks":query.chunks.count,"indexVisits":query.cost.visitedNodes,
      "boundsEvents":query.cost.decodedSamples,"displayEvents":4,"sourceBytes":measured.payloadBytes]
    let attachment=XCTAttachment(data:try JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
    attachment.name="world-whole-strip-costs";attachment.lifetime = .keepAlways;add(attachment)
    let png=NSMutableData(),destination=try XCTUnwrap(CGImageDestinationCreateWithData(png,"public.png" as CFString,1,nil))
    CGImageDestinationAddImage(destination,image,nil);XCTAssertTrue(CGImageDestinationFinalize(destination))
    let proof=XCTAttachment(data:png as Data,uniformTypeIdentifier:"public.png")
    proof.name="world-whole-strip";proof.lifetime = .keepAlways;add(proof)
  }
  func testAggregateStripAndItsEditedMiddleKeepAffinePaintAndEraserOrder() throws {
    let samples=(0..<8193).map { i in SpatialInkSample(point:.init(x:20+Double(i)/16,y:70),
      timeOffset:Double(i)/128,width:6,opacity:0.4,force:0.75,azimuth:0,altitude:1) }
    let original=source(samples)
    let eraser=source((0..<128).map { i in SpatialInkSample(point:.init(x:200,y:40+Double(i)/2),
      timeOffset:Double(i)/128,width:8,opacity:0.3,force:1,azimuth:0,altitude:1) },tool:.eraser)
    let transforms=[InkAffine(),InkAffine(x:.init(-0.8,0.3,480,0),y:.init(0.05,0.6,20,0)),
      InkAffine(x:.init(0.2,0.1,20,0),y:.init(0.1,2,20,0)),InkAffine(.init(0,1,128,0))]
    for feature in 0..<5 {
      let value: InkSampleRelations
      if feature == 0 { value=original }
      else {
        let p=samples[4096]
        let changed=SpatialInkSample(point:.init(x:feature == 4 ? p.point.x-4 : p.point.x,y:feature == 1 ? p.point.y+12 : p.point.y),
          timeOffset:p.timeOffset,width:feature == 2 ? 18 : p.width,opacity:feature == 3 ? 0.9 : p.opacity,
          force:p.force,azimuth:p.azimuth,altitude:p.altitude)
        value=try original.editing(original.address(at:4096),to:changed,revision:UUID())
      }
      let sources=[value,eraser,source(Array(samples[3000..<4000]))]
      let actual=SpatialInkMesh(batches:sources.map { .init(source:$0,projection:.local) })
      let reference=SpatialInkMesh.referencePage(.init(actions:sources.map { $0.restoredAction() }))
      let full=SpatialInkMesh(batches:reference.batches.map { batch in
        .init(tool:batch.tool,projection:batch.projection,parts:batch.parts.map { part in
          guard case .prepared(let nodes,let chunks,_)=part.storage else { fatalError("Expected explicit oracle") }
          return .init(nodes:nodes,chunks:chunks.map { .init(nodes:$0.nodes,bounds:$0.bounds,color:$0.color,flags:$0.flags) })
        })
      })
      for transform in transforms {
        let a=try XCTUnwrap(InkRasterRenderer.shared.render(mesh:actual,size:.init(width:560,height:256),scale:2,affine:transform))
        let b=try XCTUnwrap(InkRasterRenderer.shared.render(mesh:full,size:.init(width:560,height:256),scale:2,affine:transform))
        let left=Array(try XCTUnwrap(a.dataProvider?.data) as Data),right=Array(try XCTUnwrap(b.dataProvider?.data) as Data)
        XCTAssertLessThanOrEqual(zip(left,right).map { abs(Int($0)-Int($1)) }.max()!,2,"feature \(feature)")
      }
    }
  }
  func testAggregateRailKeepsSubpixelBoundaryUnderExtremeAnisotropy() throws {
    let body=source((0..<100).map { i in SpatialInkSample(point:.init(x:Double(i),y:0),
      timeOffset:Double(i)/128,width:4,opacity:0.5,force:1,azimuth:0,altitude:1) })
      .settingExit(.init(x:InkDyadic(100)!,y:.zero,time:.one),revision:UUID())
    let repeated=try XCTUnwrap(body.repeated(1000,revision:UUID()))
    let actual=SpatialInkMesh(batches:[.init(source:repeated,projection:.local)])
    let reference=SpatialInkMesh.referencePage(.init(actions:[repeated.restoredAction()]))
    let affine=InkAffine(.init(0.005,1_000_000,6,-2_000_000+64))
    let a=try XCTUnwrap(InkRasterRenderer.shared.render(mesh:actual,size:.init(width:512,height:128),scale:2,affine:affine))
    let b=try XCTUnwrap(InkRasterRenderer.shared.render(mesh:reference,size:.init(width:512,height:128),scale:2,affine:affine))
    let left=Array(try XCTUnwrap(a.dataProvider?.data) as Data),right=Array(try XCTUnwrap(b.dataProvider?.data) as Data)
    XCTAssertLessThanOrEqual(zip(left,right).map { abs(Int($0)-Int($1)) }.max()!,2)
    XCTAssertTrue(left.contains { $0 > 0 })
  }
}

import Foundation
import ImageIO
@testable import NotebookCore
import PencilKit
import XCTest
@testable import Notebook

final class InkSourceIntegrationTests: XCTestCase {
  private func sample(_ i: Int, world: WorldPoint? = nil) -> SpatialInkSample {
    .init(point:.init(x:30+Double(i)/8,y:100),worldPoint:world,timeOffset:Double(i)/128,
      width:4,opacity:0.5,force:Double(i%7)/8,azimuth:Double(i%9)/4,altitude:0.5)
  }
  func testPageReloadAndExportUseTheRelationPathWithoutChangingAcceptedEvents() throws {
    let action=PageInkAction(tool:.pen,samples:(0..<4096).map { sample($0) })
    let drawing=PageInkDrawing(actions:[action]), bytes=try drawing.dataRepresentation()
    let prepared=try PageInkMesh.prepare(drawing,reusing:[])
    XCTAssertLessThan(prepared.entries[0].mesh.expandedForTesting().nodes.count,action.samples.count/10)
    let replay=try PageInkMesh.prepare(PageInkDrawing.decode(bytes),reusing:prepared.entries)
    XCTAssertEqual(replay.builtActionCount,0)
    XCTAssertEqual(replay.entries[0].reusedIndex,0)
    let layers=SpatialInkComposer.pageLayers(drawing)
    for i in action.samples.indices { XCTAssertTrue(InkSampleRelations.sameBits(layers[0].source.sample(at:i),action.samples[i])) }
    let mesh=SpatialInkMesh.local(layers)
    XCTAssertEqual(prepared.entries[0].mesh.expandedForTesting().nodes,mesh.batches[0].expandedForTesting().nodes)
    let renderer=InkRasterRenderer.shared, size=CGSize(width:640,height:160)
    let actual=try XCTUnwrap(renderer.page(drawing,size:size,scale:1))
    let old=try XCTUnwrap(renderer.render(mesh:.referencePage(drawing),size:size,scale:1))
    let a=Array(try XCTUnwrap(actual.dataProvider?.data) as Data)
    let b=Array(try XCTUnwrap(old.dataProvider?.data) as Data)
    XCTAssertLessThanOrEqual(zip(a,b).map { abs(Int($0)-Int($1)) }.max()!,2)
    XCTAssertEqual(try drawing.dataRepresentation(),bytes)
  }
  func testProjectionNeverSkipsCoincidentMeasuredSamples() throws {
    for (step,scale,offset) in [(1.0/8192,1.0,0.0),(1.0/8,0.02,0),(1.0/8,1,1_000_000)] {
      let samples=(0..<512).map { i in SpatialInkSample(point:.init(x:Double(i)*step,y:20),
        timeOffset:Double(i)/128,width:4,opacity:1,force:1,azimuth:0,altitude:1) }
      let source=InkSampleRelations(sourceID:UUID(),revision:UUID(),samples:samples,header:.init(tool:.pen,color:.black))
      let nodes=SpatialInkGeometry.compact(source:source,offset:.init(x:offset,y:0),scale:scale)
      let points=samples.map { PKStrokePoint(location:.init(x:$0.point.x*scale+offset,y:$0.point.y*scale),
        timeOffset:$0.timeOffset,size:.init(width:$0.width*scale,height:$0.width*scale),opacity:1,force:1,azimuth:0,altitude:1) }
      let expected=SpatialInkGeometry.compact(points:points,color:.init(0,0,0,1))
      XCTAssertEqual(nodes.count,expected.count)
      for (a,b) in zip(nodes,expected) {
        XCTAssertEqual(a.position,b.position);XCTAssertEqual(a.edge,b.edge);XCTAssertEqual(a.radius,b.radius)
        XCTAssertEqual(a.alpha,1);XCTAssertEqual(a.alpha,b.alpha,accuracy:1/4096)
      }
    }
  }
  func testWorldAndRegionalProjectionKeepSourceBitsAndMatchUnreducedGeometry() throws {
    let origin=WorldPoint(tileX:1_000_000,tileY:-1_000_000,localX:10,localY:20)
    let samples=(0..<100).map { sample($0,world:origin.offsetBy(x:Double($0)/8,y:sin(Double($0)))) }
    let actor=UUID(),surface=SurfaceID.board(UUID())
    var journal=SpatialInkJournal(stamp:.init(counter:0,actor:actor))
    _ = try XCTUnwrap(journal.append(tool:.pen,spans:[.init(surface:surface,samples:samples)],actor:actor))
    let installed=try SpatialInkMesh.prepare(surface:surface,journal:journal)
    XCTAssertEqual(installed.batches.count,1)
    for scale in [0.02,0.5,1,4] {
      let camera=SpatialCamera(center:origin.offsetBy(x:3.125,y:-5.25),scale:scale)
      let viewport=SpatialPoint(x:300.5,y:170.25)
      let layers=SpatialInkComposer.boardLayers(board:surface,journal:journal,camera:camera,viewport:viewport)
      for i in samples.indices { XCTAssertTrue(InkSampleRelations.sameBits(layers[0].source.sample(at:i),samples[i])) }
      let points=samples.map { s in
        let p=camera.worldToScreen(s.worldPoint!,viewport:viewport)
        return PKStrokePoint(location:.init(x:p.x,y:p.y),timeOffset:s.timeOffset,
          size:.init(width:s.width*scale,height:s.width*scale),opacity:s.opacity,
          force:s.force,azimuth:s.azimuth,altitude:s.altitude)
      }
      let expected=SpatialInkGeometry.compact(points:points,color:.init(0,0,0,1))
      let actual=SpatialInkMesh.local(layers).batches[0].expandedForTesting().nodes
      XCTAssertEqual(actual.count,expected.count)
      for (a,b) in zip(actual,expected) {
        XCTAssertEqual(a.position,b.position);XCTAssertEqual(a.edge,b.edge);XCTAssertEqual(a.radius,b.radius)
        // PencilKit quantizes opacity (0.5 -> 0.4999771); content now keeps the
        // accepted value. This is the existing 1/4096 display alpha budget.
        XCTAssertEqual(a.alpha,0.5);XCTAssertEqual(a.alpha,b.alpha,accuracy:1/4096)
      }
    }
    let cover=SurfaceID.cover(UUID())
    var local=SpatialInkJournal(stamp:.init(counter:0,actor:actor))
    _=local.append(tool:.pen,spans:[.init(surface:cover,samples:(0..<4).map { sample($0) })],actor:actor)
    let crop=SpatialInkComposer.localLayers(for:cover,journal:local,origin:.init(x:20,y:80))
    XCTAssertEqual(SpatialInkMesh.local(crop).batches[0].expandedForTesting().nodes[0].position,.init(10,20))
    XCTAssertEqual(crop[0].source.sample(at:0).point,.init(x:30,y:100))
  }
  func testStoredMillionEventBodyReopensIntoTheNativeVisibleRangeAndGPU() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("native-relations-\(UUID())")
    defer { try? FileManager.default.removeItem(at:root) }
    let store=NotebookStore(root:root),actor=UUID()
    _=try store.initializeWorkspace(actor:actor,pageSize:.init(width:834,height:1194))
    let index=try store.loadIndex(),pageID=try XCTUnwrap(index.selectedPageID)
    let samples: [SpatialInkSample]=(0..<100).map { i in
      .init(point:.init(x:Double(i),y:64+sin(Double(i)/8)*20),timeOffset:Double(i)/128,
        width:4,opacity:0.5,force:0.75,azimuth:0,altitude:1)
    }
    let body=InkSampleRelations(sourceID:UUID(),revision:UUID(),samples:samples,
      header:.init(tool:.pen,color:.init(red:0.2,green:0.4,blue:0.8)))
      .settingExit(.init(x:InkDyadic(128)!,y:.zero,time:.one),revision:UUID())
    let source=try XCTUnwrap(body.repeated(10_000,revision:UUID()))
    let drawing=PageInkDrawing(actions:[source.restoredAction()])
    _=try store.savePage(.init(id:pageID,size:.init(width:834,height:1194),actor:actor,drawingData:drawing.dataRepresentation()))
    let reloaded=try PageInkDrawing.decode(NotebookStore(root:root).loadPage(pageID).drawingData)
    XCTAssertLessThan(try reloaded.dataRepresentation().count,10_000)
    let mesh=try PageInkMesh.prepare(reloaded,reusing:[]).entries[0].mesh
    XCTAssertEqual(mesh.preparedNodeCount,0);XCTAssertEqual(mesh.sourceNodeCount,1_000_000)
    guard case .relative(let relative)=mesh.parts[0].storage else { return XCTFail("Stored source was expanded") }
    XCTAssertTrue(relative.source.storage === reloaded.actions[0].samples.storage)
    XCTAssertEqual(relative.source.allocationSummary.nodes,2)
    let center=500_000,x=Double(center/100*128),affine=InkAffine(.init(1,1,Float(32-x),0))
    let query=mesh.query(viewport:.init(x:0,y:0,width:160,height:128),affine:affine)
    let decoded=query.chunks.reduce(0) { $0+mesh.prepareChunk($1).decodedPoints }
    XCTAssertLessThan(decoded+query.cost.decodedSamples,source.count/100,
      "The visible crop must visit less than one percent of original events")
    let image=try XCTUnwrap(InkRasterRenderer.shared.render(mesh:.init(batches:[mesh]),size:.init(width:160,height:128),scale:2,affine:affine))
    // A bounded unreduced neighbourhood supplies an independent old geometry
    // control. Hidden repetitions are absent from this display-only reference.
    let reference=PageInkDrawing(actions:[.init(tool:.pen,color:source.header.color,samples:source.decoded(in:(center-200)..<(center+400)))])
    let control=try XCTUnwrap(InkRasterRenderer.shared.render(mesh:.referencePage(reference),size:.init(width:160,height:128),scale:2,affine:affine))
    let pixels=Array(try XCTUnwrap(image.dataProvider?.data) as Data),expected=Array(try XCTUnwrap(control.dataProvider?.data) as Data)
    XCTAssertEqual(pixels.count,expected.count)
    XCTAssertTrue(pixels.contains { $0 > 0 })
    XCTAssertLessThanOrEqual(zip(pixels,expected).map { abs(Int($0)-Int($1)) }.max()!,2)
    let png=NSMutableData(),destination=try XCTUnwrap(CGImageDestinationCreateWithData(png,"public.png" as CFString,1,nil))
    CGImageDestinationAddImage(destination,image,nil);XCTAssertTrue(CGImageDestinationFinalize(destination))
    let proof=XCTAttachment(data:png as Data,uniformTypeIdentifier:"public.png")
    proof.name="sqlite-repeat-visible-source";proof.lifetime = .keepAlways;add(proof)
    let cost: [String:Int] = ["logicalEvents":source.count,"graphNodes":relative.source.allocationSummary.nodes,
      "queryVisits":query.cost.visitedNodes,"boundsEvents":query.cost.decodedSamples,"geometryEvents":decoded,
      "visibleChunks":query.chunks.count,"storedDrawingBytes":try reloaded.dataRepresentation().count]
    let work=XCTAttachment(data:try JSONSerialization.data(withJSONObject:cost,options:[.sortedKeys,.prettyPrinted]),uniformTypeIdentifier:"public.json")
    work.name="sqlite-repeat-visible-work";work.lifetime = .keepAlways;add(work)
  }

  @MainActor
  func testPageExportBudgetsVisibleRelationsAndStillRefusesOverlappingWork() async throws {
    let samples: [SpatialInkSample]=(0..<100).map { i in
      .init(point:.init(x:Double(i),y:64+sin(Double(i)/8)*20),timeOffset:Double(i)/128,
        width:4,opacity:0.5,force:0.75,azimuth:0,altitude:1)
    }
    let body=InkSampleRelations(sourceID:UUID(),revision:UUID(),samples:samples,
      header:.init(tool:.pen,color:.init(red:0.2,green:0.4,blue:0.8)))
    let spread=try XCTUnwrap(body.settingExit(.init(x:InkDyadic(128)!,y:.zero,time:.one),revision:UUID())
      .repeated(10_000,revision:UUID()))
    let resources=SceneRenderResources(byteLimit:24*1024*1024)
    let id=UUID(),actor=UUID(),size=PageSize(width:320,height:128)
    func page(_ action: PageInkAction) throws -> PageDocument {
      .init(id:id,size:size,actor:actor,drawingData:try PageInkDrawing(actions:[action]).dataRepresentation())
    }
    let actual=try await PageCompositionRenderer.render(page(spread.restoredAction()),scale:2,resources:resources) { _ in
      throw CocoaError(.featureUnsupported)
    }
    let control=try await PageCompositionRenderer.render(page(.init(tool:.pen,color:body.header.color,
      samples:spread.decoded(in:0..<600))),scale:2,resources:resources) { _ in throw CocoaError(.featureUnsupported) }
    func pixels(_ png: Data) throws -> [UInt8] {
      let source=try XCTUnwrap(CGImageSourceCreateWithData(png as CFData,nil))
      let image=try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
      return Array(try XCTUnwrap(image.dataProvider?.data) as Data)
    }
    let a=try pixels(actual.png),b=try pixels(control.png)
    XCTAssertEqual(a.count,b.count)
    XCTAssertLessThanOrEqual(zip(a,b).map { abs(Int($0)-Int($1)) }.max()!,2)
    XCTAssertLessThan(resources.peakAccountedBytes,resources.byteLimit)
    let proof=XCTAttachment(data:actual.png,uniformTypeIdentifier:"public.png")
    proof.name="bounded-million-event-page-export";proof.lifetime = .keepAlways;add(proof)
    let overlap=try XCTUnwrap(body.repeated(10_000,revision:UUID()))
    do {
      _=try await PageCompositionRenderer.render(page(overlap.restoredAction()),scale:2,resources:resources) { _ in
        throw CocoaError(.featureUnsupported)
      }
      XCTFail("A compact source cannot authorize a million overlapping draws outside the budget")
    } catch SceneRenderError.resourceLimit { }
    XCTAssertEqual(resources.reservedBytes,0)
  }
  func testColdLassoQueriesMillionEventSourceWithoutPreparingAllFragments() throws {
    func point(_ x:Double,_ y:Double) -> SpatialInkSample {
      .init(point:.init(x:x,y:y),timeOffset:0,width:2,opacity:1,force:1,azimuth:0,altitude:1)
    }
    let body=InkSampleRelations(sourceID:UUID(),revision:UUID(),samples:[point(0,0),point(1,1)],
      header:.init(tool:.pen,color:.black))
      .settingExit(.init(x:InkDyadic(4)!,y:InkDyadic(4)!,time:.one),revision:UUID())
    let huge=try XCTUnwrap(body.repeated(500_000,revision:UUID()))
    let small=PageInkAction(tool:.pen,samples:[point(500_000,30),point(500_008,30)])
    let drawing=PageInkDrawing(actions:[huge.restoredAction(),small])
    let bytes=try drawing.dataRepresentation()
    let page=PageDocument(size:.init(width:834,height:1194),actor:UUID(),drawingData:bytes)
    let start=ContinuousClock.now
    let prepared=try NotebookLassoInkSource.page(page).prepare(surface:.page(page.id),origin:nil)
    let cold=start.duration(to:.now).components
    XCTAssertEqual(prepared.sourceSampleCount,1_000_002)
    XCTAssertEqual(prepared.indexedSpanCount,2)
    XCTAssertEqual(prepared.preparationSampleCount,0,"Reopening a source must not build one lasso fragment per 64 events")
    // This region is inside the large diagonal's whole box, but outside its
    // actual measured path. Reject it through the canonical range tree.
    let polygon: [SpatialPoint]=[.init(x:499_998,y:26),.init(x:500_010,y:26),.init(x:500_010,y:34),.init(x:499_998,y:34)]
    let selected=try XCTUnwrap(prepared.selection(polygon:polygon,surface:.page(page.id),origin:nil,bounds:nil))
    XCTAssertEqual(selected.graphic.sourceInkIDs,[small.id])
    XCTAssertLessThan(selected.candidateSampleCount,huge.count/100)
    XCTAssertEqual(try drawing.dataRepresentation(),bytes)
    let row: [String:Any]=["logicalEvents":prepared.sourceSampleCount,"indexedSpans":prepared.indexedSpanCount,
      "coldPreparedEvents":prepared.preparationSampleCount,"candidateEventsRead":selected.candidateSampleCount,
      "coldPrepareMilliseconds":Double(cold.seconds)*1000+Double(cold.attoseconds)/1e15]
    let proof=XCTAttachment(data:try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys,.prettyPrinted]),uniformTypeIdentifier:"public.json")
    proof.name="cold-lasso-million-source";proof.lifetime = .keepAlways;add(proof)
  }
  func testLassoRetainsMillionEventWholeAndRasterizesOnlyItsVisibleCrop() throws {
    let samples: [SpatialInkSample]=(0..<100).map { i in
      .init(point:.init(x:Double(i)/2,y:64+sin(Double(i)/8)*20),timeOffset:Double(i)/128,
        width:4,opacity:0.5,force:Double(i)/128,azimuth:0,altitude:1)
    }
    let body=InkSampleRelations(sourceID:UUID(),revision:UUID(),samples:samples,
      header:.init(tool:.pen,color:.init(red:0.2,green:0.4,blue:0.8)))
    let source=try XCTUnwrap(body.settingExit(.init(x:InkDyadic(64)!,y:.zero,time:.one),revision:UUID())
      .repeated(10_000,revision:UUID()))
    let drawing=PageInkDrawing(actions:[source.restoredAction()])
    let page=PageDocument(size:.init(width:834,height:1194),actor:UUID(),drawingData:try drawing.dataRepresentation())
    let prepared=try NotebookLassoInkSource.page(page).prepare(surface:.page(page.id),origin:nil)
    let x=320_000.0,start=ContinuousClock.now
    let polygon: [SpatialPoint]=[.init(x:x-2,y:60),.init(x:x+4,y:60),.init(x:x+4,y:68),.init(x:x-2,y:68)]
    let selection=try XCTUnwrap(prepared.selection(polygon:polygon,surface:.page(page.id),origin:nil,bounds:nil))
    let elapsed=start.duration(to:.now).components
    XCTAssertEqual(selection.graphic.sourceInkIDs,[source.sourceID])
    let ink=try XCTUnwrap(selection.graphic.freehand),measured=try XCTUnwrap(ink.layers.first?.measured)
    XCTAssertTrue(ink.layers[0].vertices.isEmpty)
    XCTAssertEqual(try measured.measurements.encodedRelations(),try source.measurements.encodedRelations())
    XCTAssertEqual(ink.geometry.preparedNodeCount,0)
    XCTAssertEqual(ink.geometry.sourceNodeCount,1_000_000)
    let encoded=try JSONEncoder().encode(selection.graphic)
    XCTAssertLessThan(encoded.count,20_000)
    let restored=try JSONDecoder().decode(NotebookGraphic.self,from:encoded)
    XCTAssertEqual(restored,selection.graphic)
    let frame=selection.frame,size=CGSize(width:frame.width,height:frame.height)
    let region=CGRect(x:x-frame.x,y:-frame.y,width:160,height:128)
    let query=ink.geometry.query(NotebookFreehandGeometry.sourceBounds(region,size:size,transform:nil))
    let preparedNodes=query.indices.reduce(0) { $0+ink.geometry.prepared(at:$1).geometry.nodes.count }
    XCTAssertLessThan(preparedNodes,1_000)
    let renderer=InkRasterRenderer.shared
    let actual=try XCTUnwrap(renderer.freehand(ink,transform:nil,size:size,region:region,scale:2,mask:false))
    let reference=PageInkDrawing(actions:[.init(tool:.pen,color:source.header.color,
      samples:source.decoded(in:499_800..<500_500))])
    let control=try XCTUnwrap(renderer.render(mesh:.referencePage(reference),size:region.size,scale:2,
      affine:InkAffine(.init(1,1,Float(-x),0))))
    func difference(_ a:CGImage,_ b:CGImage) throws -> Int {
      let p=Array(try XCTUnwrap(a.dataProvider?.data) as Data),q=Array(try XCTUnwrap(b.dataProvider?.data) as Data)
      XCTAssertEqual(p.count,q.count);XCTAssertTrue(p.contains { $0 > 0 })
      return zip(p,q).map { abs(Int($0)-Int($1)) }.max()!
    }
    XCTAssertLessThanOrEqual(try difference(actual,control),2)
    // A quarter turn changes only the whole basis. Compare the same measured
    // neighbourhood through the independent unreduced canvas control.
    let turn=NotebookGraphicTransform(a:0,b:1,c:-1,d:0,tx:1,ty:0)
    let edited=try selection.graphic.applying(.object(["transform":try .encode(turn)]))
    XCTAssertTrue(edited.freehand?.geometry === ink.geometry)
    let rotatedRegion=CGRect(x:frame.y+frame.height-128,y:x-frame.x,width:128,height:160)
    let rotated=try XCTUnwrap(renderer.freehand(ink,transform:turn,size:.init(width:frame.height,height:frame.width),
      region:rotatedRegion,scale:2,mask:false))
    let rotatedControl=try XCTUnwrap(renderer.render(mesh:.referencePage(reference),size:rotatedRegion.size,scale:2,
      affine:InkAffine(x:.init(0,-1,128,0),y:.init(1,0,Float(-x),0))))
    XCTAssertLessThanOrEqual(try difference(rotated,rotatedControl),2)
    let png=NSMutableData(),destination=try XCTUnwrap(CGImageDestinationCreateWithData(png,"public.png" as CFString,1,nil))
    CGImageDestinationAddImage(destination,actual,nil);XCTAssertTrue(CGImageDestinationFinalize(destination))
    let image=XCTAttachment(data:png as Data,uniformTypeIdentifier:"public.png")
    image.name="million-event-selected-whole";image.lifetime = .keepAlways;add(image)
    let row: [String:Any]=["selectedLogicalEvents":source.count,"eagerPreparedNodes":ink.geometry.preparedNodeCount,
      "cropPreparedNodes":preparedNodes,"cropIndexVisits":query.visitedNodes,"candidateEventsRead":selection.candidateSampleCount,
      "storedGraphicBytes":encoded.count,"selectionMilliseconds":Double(elapsed.seconds)*1000+Double(elapsed.attoseconds)/1e15]
    let proof=XCTAttachment(data:try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys,.prettyPrinted]),uniformTypeIdentifier:"public.json")
    proof.name="million-event-selected-work";proof.lifetime = .keepAlways;add(proof)
  }

}

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

}

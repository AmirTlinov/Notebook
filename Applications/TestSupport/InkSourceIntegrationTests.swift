import Foundation
import NotebookCore
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
    XCTAssertLessThan(prepared.entries[0].mesh.nodes.count,action.samples.count/10)
    let replay=try PageInkMesh.prepare(PageInkDrawing.decode(bytes),reusing:prepared.entries)
    XCTAssertEqual(replay.builtActionCount,0)
    XCTAssertEqual(replay.entries[0].reusedIndex,0)
    let layers=SpatialInkComposer.pageLayers(drawing)
    for i in action.samples.indices { XCTAssertTrue(InkSampleRelations.sameBits(layers[0].source.sample(at:i),action.samples[i])) }
    let mesh=SpatialInkMesh.local(layers)
    XCTAssertEqual(prepared.entries[0].mesh.nodes,mesh.batches[0].nodes)
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
      let actual=SpatialInkMesh.local(layers).batches[0].nodes
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
    XCTAssertEqual(SpatialInkMesh.local(crop).batches[0].nodes[0].position,.init(10,20))
    XCTAssertEqual(crop[0].source.sample(at:0).point,.init(x:30,y:100))
  }
}

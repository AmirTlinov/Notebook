import Foundation
import ImageIO
@testable import NotebookCore
import PencilKit
import XCTest
@testable import Notebook

final class InkSourceIntegrationTests: XCTestCase {
  func testReopenedCopiesShareOneBodyThroughEditAndRaster() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("native-shared-ink-\(UUID())")
    defer { try? FileManager.default.removeItem(at:root) }
    let store=NotebookStore(root:root),actor=UUID(),size=CGSize(width:160,height:128)
    _=try store.initializeWorkspace(actor:actor,pageSize:.init(width:834,height:1194))
    let page=try XCTUnwrap(store.loadIndex().selectedPageID),values=(0..<512).map { sample($0) }
    let drawing=PageInkDrawing(actions:(0..<32).map { _ in
      .init(tool:.pen,measurements:InkMeasurements(values,revision:UUID()))
    })
    let bytes=try drawing.dataRepresentation()
    let before=try XCTUnwrap(InkRasterRenderer.shared.page(drawing,size:size,scale:2))
    _=try store.savePage(.init(id:page,size:.init(width:834,height:1194),actor:actor,drawingData:bytes))
    let bodyCount=try store.sqlRead { try $0.rows("SELECT count(*) FROM blobs WHERE substr(data,1,4) IN (?,?)",[.blob(Data("NIB1".utf8)),.blob(Data("NIB2".utf8))]).first?[0].integer }
    XCTAssertEqual(bodyCount,1)
    let reopened=try PageInkDrawing.decode(NotebookStore(root:root).loadPage(page).drawingData)
    let shared=try XCTUnwrap(reopened.actions.first).samples.storage
    XCTAssertTrue(reopened.actions.allSatisfy { $0.samples.storage === shared })
    XCTAssertEqual(reopened.actions.map(\.id),drawing.actions.map(\.id))
    XCTAssertEqual(reopened.actions.map(\.samples.revision),drawing.actions.map(\.samples.revision))
    XCTAssertEqual(try reopened.dataRepresentation(),bytes)
    let mesh=try PageInkMesh.prepare(reopened,reusing:[])
    XCTAssertEqual(mesh.entries.count,32)
    for entry in mesh.entries {
      guard case .relative(let relative)=entry.mesh.parts[0].storage else { return XCTFail("Source expanded") }
      XCTAssertTrue(relative.source.storage === shared)
    }
    let after=try XCTUnwrap(InkRasterRenderer.shared.page(reopened,size:size,scale:2))
    XCTAssertEqual(try XCTUnwrap(before.dataProvider?.data) as Data,try XCTUnwrap(after.dataProvider?.data) as Data)
    let last=try XCTUnwrap(reopened.actions.last)
    let source=InkSampleRelations(sourceID:last.id,measurements:last.samples,header:.init(tool:.pen,color:last.color))
    let replacement=SpatialInkSample(point:.init(x:80,y:80),timeOffset:values[31].timeOffset,
      width:4,opacity:0.5,force:0.75,azimuth:0,altitude:1)
    let edited=try source.editing(source.address(at:31),to:replacement,revision:UUID())
    let changed=PageInkDrawing(actions:Array(reopened.actions.dropLast())+[
      .init(id:last.id,tool:last.tool,color:last.color,measurements:edited.measurements,sequence:last.sequence)])
    let changedImage=try XCTUnwrap(InkRasterRenderer.shared.page(changed,size:size,scale:2))
    XCTAssertNotEqual(try XCTUnwrap(after.dataProvider?.data) as Data,try XCTUnwrap(changedImage.dataProvider?.data) as Data)
    XCTAssertTrue(InkSampleRelations.sameBits(reopened.actions[0].samples[31],values[31]))
    XCTAssertTrue(reopened.actions[0].samples.storage === shared)
    XCTAssertTrue(changed.removing([last.id]).actions.last?.isActive == false)
    XCTAssertTrue(changed.actions[0].samples.storage === shared)
  }

  func testLocalMeasuredEditReopensWithSharedPartsAndExactRaster() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("native-graph-edit-\(UUID())")
    defer { try? FileManager.default.removeItem(at:root) }
    let store=NotebookStore(root:root),actor=UUID(),size=CGSize(width:160,height:128)
    _=try store.initializeWorkspace(actor:actor,pageSize:.init(width:834,height:1194))
    let page=try XCTUnwrap(store.loadIndex().selectedPageID),target=CollaborationTarget(kind:.page,id:page)
    let values:[SpatialInkSample]=(0..<2048).map { i in
      let point=SpatialPoint(x:16+Double(i)/16,y:64+sin(Double(i)/32)*20)
      return .init(point:point,timeOffset:Double(i)/128,width:4,opacity:0.75,force:0.5,azimuth:0,altitude:1)
    }
    let source=InkSampleRelations(sourceID:UUID(),revision:UUID(),samples:values,header:.init(tool:.pen,color:.black))
    let frame=PageRect(x:0,y:0,width:160,height:128)
    func ink(_ source:InkSampleRelations) -> NotebookFreehand {
      .init(layers:[.init(tool:.pen,color:.black,measured:.init(sourceID:source.sourceID,measurements:source.measurements,frame:frame))])
    }
    func pixels(_ ink:NotebookFreehand) throws -> Data {
      let image=try XCTUnwrap(InkRasterRenderer.shared.freehand(ink,transform:nil,size:size,region:.init(origin:.zero,size:size),scale:2,mask:false))
      return try XCTUnwrap(image.dataProvider?.data) as Data
    }
    func parts() throws -> Set<String> {
      try store.sqlRead { Set(try $0.rows("SELECT hash FROM blobs WHERE substr(data,1,4)=?",[.blob(Data("NIN1".utf8))]).compactMap { $0[0].text }) }
    }
    let original=ink(source),beforePixels=try pixels(original)
    _=try store.applyNativeElementEdits([.init(kind:.insertElement,target:target,id:"editable",values:[
      "kind":.string("graphic"),"source":.string(""),"frame":try .encode(frame),
      "graphic":try .encode(NotebookGraphic(shape:.freehand,freehand:original))])],summary:"Исходные чернила",
      sources:[.init(target:target,id:"editable")],actor:actor)
    let oldParts=try parts(),before=try XCTUnwrap(store.readPageElement(pageID:page,elementID:"editable"))
    let replacement=SpatialInkSample(point:values[1007].point,timeOffset:values[1007].timeOffset,width:20,opacity:1,force:0.5,azimuth:0,altitude:1)
    let changed=try source.editing(source.address(at:1007),to:replacement,revision:UUID()),next=ink(changed)
    let receipt=try store.applyNativeElementEdits([.init(kind:.updateElement,target:target,id:"editable",values:[
      "graphic":.object(["freehand":try .encode(next)])])],summary:"Локальная правка",
      sources:[.init(target:target,id:"editable",page:before)],actor:actor).receipt
    XCTAssertLessThanOrEqual(try parts().subtracting(oldParts).count,6)
    let reopened=NotebookStore(root:root),loaded=try XCTUnwrap(reopened.readPageElement(pageID:page,elementID:"editable")?.graphic?.freehand)
    XCTAssertEqual(try loaded.layers[0].measured?.measurements.encodedRelations(),try changed.measurements.encodedRelations())
    let afterPixels=try pixels(loaded)
    XCTAssertEqual(afterPixels,try pixels(next));XCTAssertNotEqual(afterPixels,beforePixels)
    XCTAssertTrue(InkSampleRelations.sameBits(source.sample(at:1007),values[1007]))
    _=try reopened.undoCollaborationAction(receipt.id,actor:actor)
    let restored=try XCTUnwrap(reopened.readPageElement(pageID:page,elementID:"editable")?.graphic?.freehand)
    XCTAssertEqual(try pixels(restored),beforePixels)
  }

  func testColdDecodeSharingCostFor100000ShortBodiesAndUniqueControl() throws {
    func milliseconds(_ duration: Duration) -> Double {
      Double(duration.components.seconds)*1000+Double(duration.components.attoseconds)/1e15
    }
    func retained(_ values: [InkMeasurements]) -> (bodies:Int,bytes:Int) {
      var storage=Set<ObjectIdentifier>(),nodes=Set<ObjectIdentifier>()
      var bytes=values.capacity*MemoryLayout<InkMeasurements>.stride
      for value in values where storage.insert(ObjectIdentifier(value.storage)).inserted {
        bytes += value.storage.byteCount+value.storage.root.allocationSummary(seen:&nodes).bytes
      }
      return (storage.count,bytes)
    }
    var measurements:[[String:Any]]=[]
    for unique in [false,true] {
      let count=100_000,start=ContinuousClock.now
      let seed=try InkMeasurements([sample(0),sample(1)]).encodedRelations().base64EncodedString()
      let strings=try (0..<count).map { i in
        unique ? try InkMeasurements([sample(i),sample(i+1)]).encodedRelations().base64EncodedString() : seed
      }
      let bytes=try JSONEncoder().encode(strings),prepareMS=milliseconds(start.duration(to:.now))
      let controlStart=ContinuousClock.now
      let control=try JSONDecoder().decode([InkMeasurements].self,from:bytes)
      let controlMS=milliseconds(controlStart.duration(to:.now)),controlMemory=retained(control)
      let scope=InkRelationDecoding(),actualStart=ContinuousClock.now
      let actual=try InkRelationDecoding.decoder(sharing:scope).decode([InkMeasurements].self,from:bytes)
      let actualMS=milliseconds(actualStart.duration(to:.now)),actualMemory=retained(actual)
      XCTAssertEqual(actual.count,count)
      XCTAssertEqual(actualMemory.bodies,unique ? count : 1)
      XCTAssertEqual(controlMemory.bodies,count)
      XCTAssertLessThanOrEqual(scope.entryCount,256);XCTAssertLessThanOrEqual(scope.retainedBytes,4*1024*1024)
      for i in [0,49_999,99_999] { XCTAssertEqual(try actual[i].encodedRelations(),try control[i].encodedRelations()) }
      measurements.append(["case":unique ? "unique-short-100k" : "identical-short-100k",
        "inputBytes":bytes.count,"prepareInputMS":prepareMS,"decodeSharedMS":actualMS,"decodeIndependentMS":controlMS,
        "uniqueBodies":actualMemory.bodies,"retainedSourceBytes":actualMemory.bytes,
        "controlSourceBytes":controlMemory.bytes,"scopeEntries":scope.entryCount,
        "scopePayloadBytesIncludingSharedSources":scope.retainedBytes])
    }
    let report=try JSONSerialization.data(withJSONObject:measurements,options:[.sortedKeys,.prettyPrinted])
    print("INK_SHARED_DECODE_COST "+String(decoding:report,as:UTF8.self))
    let attachment=XCTAttachment(data:report,uniformTypeIdentifier:"public.json")
    attachment.name="shared-ink-cold-decode-cost";attachment.lifetime = .keepAlways;add(attachment)
  }

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
  func testAcknowledgedDeviceWithANewIncomingJournalMigratesAndKeepsItsInkRaster() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("native-ink-migration-\(UUID())")
    defer { try? FileManager.default.removeItem(at:root) }
    let store=NotebookStore(root:root),actor=UUID(),peer=UUID(),size=CGSize(width:256,height:128)
    _=try store.initializeWorkspace(actor:actor,pageSize:.init(width:834,height:1194))
    let page=try XCTUnwrap(try store.loadIndex().selectedPageID),samples=(0..<64).map { sample($0) }
    let action=PageInkAction(tool:.pen,samples:samples),drawing=PageInkDrawing(actions:[action])
    _=try store.savePage(.init(id:page,size:.init(width:834,height:1194),actor:actor,drawingData:drawing.dataRepresentation()))
    let incoming=NotebookReplicationSource(deviceID:peer,generation:UUID())
    _=try store.admitReplicationSource(incoming)
    let cursor=try store.currentChangeCursor()
    try store.acknowledgePeer(peerID:peer,through:cursor)
    let before=try XCTUnwrap(InkRasterRenderer.shared.page(drawing,size:size,scale:2))
    // Manufacture only the prior serialization in this disposable native
    // store. No installed content, trust state or journal receipt is touched.
    let db=try NotebookSQLConnection(url:store.databaseURL,writable:true)
    try db.run("BEGIN IMMEDIATE")
    do {
      let rows=try db.rows("SELECT b.data FROM records r JOIN blobs b ON b.hash=r.hash WHERE r.file LIKE 'pages/%' AND r.collection='samples'")
      XCTAssertEqual(rows.count,1)
      let row=try JSONDecoder().decode(NotebookStoredFragment.self,from:XCTUnwrap(rows.first?[0].blob))
      let old=try row.replacing(value:.encode(samples)),hash=try db.putBlob(NotebookStore.storageEncoder.encode(old))
      try db.run("UPDATE records SET hash=? WHERE address=?",[.text(hash),.text(row.address)])
      try db.run("INSERT INTO peer_cursors(peer_id,direction,sequence) VALUES(?,'incoming',7)",[.text(incoming.cursorKey)])
      try db.run("PRAGMA user_version=16");try db.run("COMMIT")
    } catch { try? db.run("ROLLBACK");throw error }
    let opened=NotebookStore(root:root),reloaded=try PageInkDrawing.decode(opened.loadPage(page).drawingData)
    XCTAssertEqual(reloaded.actions.map(\.id),[action.id])
    let restored=try XCTUnwrap(reloaded.actions.first).samples.materialized()
    XCTAssertEqual(restored.count,samples.count)
    XCTAssertTrue(zip(restored,samples).allSatisfy { InkSampleRelations.sameBits($0,$1) })
    XCTAssertEqual(try opened.peerCursor(peerID:peer,direction:.outgoing),cursor)
    XCTAssertEqual(try opened.incomingCursor(source:incoming),7)
    XCTAssertEqual(try opened.currentChangeCursor(),cursor+1)
    let after=try XCTUnwrap(InkRasterRenderer.shared.page(reloaded,size:size,scale:2))
    let pixels=try XCTUnwrap(after.dataProvider?.data) as Data
    XCTAssertTrue(pixels.contains { $0 != 0 })
    XCTAssertEqual(pixels,try XCTUnwrap(before.dataProvider?.data) as Data)
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
    // A whole straight repeat is four display nodes even though its logical
    // range spans one million measurements. Admission must charge that work.
    let straight=InkSampleRelations(sourceID:UUID(),revision:UUID(),samples:(0..<100).map { i in
      SpatialInkSample(point:.init(x:Double(i),y:64),timeOffset:Double(i)/128,width:4,opacity:0.5,force:1,azimuth:0,altitude:1)
    },header:body.header).settingExit(.init(x:InkDyadic(100)!,y:.zero,time:.one),revision:UUID())
    let long=try XCTUnwrap(straight.repeated(10_000,revision:UUID()))
    let simple=try await PageCompositionRenderer.render(page(long.restoredAction()),scale:2,resources:resources) { _ in
      throw CocoaError(.featureUnsupported)
    }
    let simpleControl=try await PageCompositionRenderer.render(page(.init(tool:.pen,color:body.header.color,
      samples:long.decoded(in:0..<600))),scale:2,resources:resources) { _ in throw CocoaError(.featureUnsupported) }
    XCTAssertEqual(try pixels(simple.png),try pixels(simpleControl.png))
    XCTAssertLessThan(resources.peakAccountedBytes,resources.byteLimit)
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
    let selectedPage=PageDocument(size:page.size,actor:UUID(),drawingData:page.drawingData,elements:[
      .init(id:"whole",kind:.graphic,frame:.init(x:0,y:0,width:600,height:128),source:"",html:"",graphic:restored)])
    let readStart=ContinuousClock.now
    let projection=try selectedPage.graphicReadProjection(),readDuration=readStart.duration(to:.now)
    XCTAssertLessThan(readDuration,.seconds(1),"Reading appearance is not a request for the full contour")
    XCTAssertEqual(projection["elements"]?.array.first?["appearance"]?["state"],.string("intact"))
    let readTime=readDuration.components
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
      "storedGraphicBytes":encoded.count,"selectionMilliseconds":Double(elapsed.seconds)*1000+Double(elapsed.attoseconds)/1e15,
      "appearanceReadMilliseconds":Double(readTime.seconds)*1000+Double(readTime.attoseconds)/1e15]
    let proof=XCTAttachment(data:try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys,.prettyPrinted]),uniformTypeIdentifier:"public.json")
    proof.name="million-event-selected-work";proof.lifetime = .keepAlways;add(proof)
  }

}

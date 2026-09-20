import CoreGraphics
import Foundation
import ImageIO
import NotebookCore
import SwiftUI
import XCTest
#if os(iOS)
import UIKit
#else
import AppKit
#endif
@testable import Notebook

@MainActor final class GroupGraphicRenderingTests: XCTestCase {
  func testBoardIndexAndBothCompositorsUseTheWholeTiledOrigin() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("group-board-\(UUID())")
    defer { try? FileManager.default.removeItem(at:root) }
    let store=NotebookStore(root:root),actor=UUID()
    let header=try store.initializeWorkspace(actor:actor,pageSize:.init(width:834,height:1194))
    let target=CollaborationTarget(kind:.board,id:header.rootBoardID)
    let origin=WorldPoint(tileX:1_000_000_000_000,tileY:-1_000_000_000_000,localX:3,localY:7)
    let basis=NotebookElementBasis(size:.init(x:200,y:120),transform:.init(a:0,b:1,c:-1,d:0,tx:1,ty:0))
    let operations: [CollaborationOperation] = [
      .init(kind:.insertElement,target:target,id:"whole",values:["kind":.string("group"),"source":.string(""),
        "frame":try .encode(PageRect(x:40,y:30,width:240,height:600)),"worldOrigin":try .encode(origin),"basis":try .encode(basis)]),
      .init(kind:.insertElement,target:target,id:"shape",values:["kind":.string("graphic"),"source":.string(""),
        "frame":try .encode(PageRect(x:10,y:20,width:100,height:60)),"worldOrigin":try .encode(WorldPoint.zero),
        "parentID":.string("whole"),"graphic":try .encode(NotebookGraphic(shape:.rectangle,style:.init(strokeWidth:8,fill:.black)))])]
    _ = try store.applyNativeElementEdits(operations,summary:"Вложенная фигура",sources:operations.map { .init(target:target,id:$0.id!) },actor:actor)
    let workspace=try store.loadIndex(),hierarchy=try store.loadBoard(items:workspace.items)
    let index=WorkspaceSceneIndex(workspace:workspace,hierarchy:hierarchy,paperSizes:[:])
    XCTAssertNil(index.paintEntry(id:.element("whole"),boardID:target.id))
    let entry=try XCTUnwrap(index.paintEntry(id:.element("shape"),boardID:target.id))
    XCTAssertEqual(entry.bounds.origin,origin.offsetBy(x:120,y:60))
    XCTAssertEqual(entry.bounds.width,120);XCTAssertEqual(entry.bounds.height,300)
    let current=try store.workspaceHeader()
    let sources=[SceneCompositionSource(store:store,revision:current.cursor,workspaceID:current.workspaceID),
      SceneCompositionSource(index:index,hierarchy:hierarchy,journal:.init(stamp:workspace.stamp))]
    let presence=SessionPresence(boardID:target.id,mode:.board,
      camera:.init(center:origin.offsetBy(x:200,y:400),scale:1),viewport:.init(x:400,y:800))
    for (offset,source) in sources.enumerated() {
      let result=try await SceneCompositionRenderer(source:source,resources:SceneRenderResources()).render(presence:presence,scale:1)
      let body=try pixels(result.png)
      XCTAssertTrue(dark(body,180,150));XCTAssertTrue(dark(body,180,285))
      XCTAssertFalse(dark(body,60,70),"The unplaced local frame is not another painted copy")
      let proof=XCTAttachment(data:result.png,uniformTypeIdentifier:"public.png")
      proof.name="group-board-\(offset == 0 ? "sql" : "memory")";proof.lifetime = .keepAlways;add(proof)
    }
  }

  func testMaskCacheKeepsWholeTranslationButNotANewLocalBasis() throws {
    let graphic = NotebookGraphic(shape:.rectangle,style:.init(strokeWidth:8))
    func input(_ transform: NotebookGraphicTransform,x: Double) throws -> NotebookElementErasureCache.Input {
      let page = PageDocument(size:.init(width:600,height:600),actor:UUID(),elements:[
        .init(id:"shape",kind:.graphic,frame:.init(x:x,y:40,width:200,height:200),source:"",html:"",graphic:graphic,
          basis:.init(size:.init(x:100,y:100),transform:transform))])
      let layout = try XCTUnwrap(page.graphicGraph().resolve("shape").layout)
      return .init(graphic:graphic,layout:layout,size:.init(width:200,height:200),erasures:[])
    }
    let rotation = NotebookGraphicTransform(a:0,b:1,c:-1,d:0,tx:1,ty:0)
    let first = try input(rotation,x:40), translated = try input(rotation,x:200)
    XCTAssertEqual(first,translated)
    XCTAssertNotNil(first.layout?.projection)
    let reflection = try input(.init(a:-1,b:0,c:0,d:1,tx:1,ty:0),x:40)
    XCTAssertNotEqual(first,reflection,"Same size is not the same rotated mask")
  }

  func testMeasuredEraserCapturesTheModelsWholeBasisNotTheLocalFrame() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("group-eraser-\(UUID())")
    let store = NotebookStore(root:root),actor = UUID(),size = PageSize(width:400,height:800)
    let (workspace,_) = try store.loadOrCreate(actor:actor,pageSize:size)
    let pageID = try XCTUnwrap(workspace.selectedPageID)
    let turn = NotebookGraphicTransform(a:0,b:1,c:-1,d:0,tx:1,ty:0)
    let page = PageDocument(id:pageID,size:size,actor:actor,elements:[
      .init(id:"whole",kind:.group,frame:.init(x:40,y:30,width:240,height:600),source:"",html:"",
        basis:.init(size:.init(x:200,y:120),transform:turn)),
      .init(id:"shape",kind:.graphic,frame:.init(x:10,y:20,width:100,height:60),source:"",html:"",
        graphic:.init(shape:.rectangle,style:.init(strokeWidth:8,fill:.black)),parentID:"whole")])
    var admitted = try store.loadPage(pageID)
    admitted.replaceElements(page.elements,actor:actor)
    try store.savePage(admitted)
    let model = NotebookAppModel(store:store,startsNearbySync:false)
    retainNotebookUntilTeardown(model,removing:root)
    await model.start(pageSize:size)
    let targets = model.eraserTargets(pageID:pageID)
    XCTAssertEqual(targets.count,1,"The group descriptor is not a painted eraser target")
    let target = try XCTUnwrap(targets.first)
    XCTAssertEqual(target.frame,.init(x:120,y:60,width:120,height:300))
    XCTAssertEqual(target.elementTransform,turn)
    let action = PageInkAction(tool:.eraser,samples:[140.0,220].map {
      .init(point:.init(x:$0,y:150),timeOffset:0,width:16,opacity:1,force:1,azimuth:0,altitude:1)
    }).erasingElements(targets)
    let drawing = try PageInkDrawing.decode(PageInkDrawing(actions:[action]).dataRepresentation())
    let cuts = try XCTUnwrap(drawing.elementErasures["shape"])
    let layout = try XCTUnwrap(model.graphicGraph(page:page).resolve("shape").layout)
    let appearance = NotebookElementAppearance(graphic:page.elements[1].graphic,layout:layout,
      size:.init(width:120,height:300),erasures:cuts)
    let pendingMask=NotebookElementAppearance.measuredErasurePath(cuts,size:.init(width:120,height:300),layout:layout)
    XCTAssertTrue(pendingMask.contains(.init(x:60,y:90)))
    XCTAssertFalse(pendingMask.contains(.init(x:60,y:110)))
    XCTAssertFalse(appearance.contains(.init(x:60,y:90),tolerance:0))
    XCTAssertTrue(appearance.contains(.init(x:60,y:110),tolerance:0))
    let graph=model.graphicGraph(page:page),surface=SurfaceID.page(pageID)
    func binding(_ point: SpatialPoint) -> NotebookGraphicConnection.Binding? {
      graph.binding(at:point,surface:surface,tolerance:0,erasures:drawing.elementErasures) { id,graphic,layout,size,cuts in
        model.elementErasureCache.appearance(surface:surface,id:id,graphic:graphic,layout:layout,size:size,erasures:cuts)
      }
    }
    XCTAssertNil(binding(.init(x:180,y:250)),"An unprepared cut cannot create an old-coordinate attraction")
    let deadline=ContinuousClock.now + .seconds(5)
    while binding(.init(x:180,y:250)) == nil,ContinuousClock.now<deadline { try await Task.sleep(for:.milliseconds(5)) }
    XCTAssertEqual(binding(.init(x:180,y:250))?.elementID,"shape")
    XCTAssertNil(binding(.init(x:180,y:150)),"Binding shares the displayed cut, not the old local mask")
    let result = try await PageCompositionRenderer.render(PageDocument(id:pageID,size:size,actor:actor,
      drawingData:drawing.dataRepresentation(),elements:page.elements),scale:1) { _ in
      XCTFail("A group is not a WebKit document"); throw CocoaError(.featureUnsupported)
    }
    let proof = XCTAttachment(data:result.png,uniformTypeIdentifier:"public.png")
    proof.name="group-new-measured-cut"; proof.lifetime = .keepAlways; add(proof)
  }

  func testWholeBasisTransformsStrokeAndSavedCutInTheNativeExport() async throws {
    let graphic = NotebookGraphic(shape:.rectangle,style:.init(strokeWidth:8,fill:.black))
    let local = PageRect(x:10,y:20,width:100,height:60)
    let elements: [AgentElement] = [
      .init(id:"whole",kind:.group,frame:.init(x:40,y:30,width:240,height:600),source:"",html:"",
        basis:.init(size:.init(x:200,y:120),transform:.init(a:0,b:1,c:-1,d:0,tx:1,ty:0))),
      .init(id:"shape",kind:.graphic,frame:local,source:"",html:"",graphic:graphic,parentID:"whole")]
    let erase = PageInkAction(tool:.eraser,samples:[30.0,70].map {
      .init(point:.init(x:40,y:$0),timeOffset:0,width:12,opacity:1,force:1,azimuth:0,altitude:1)
    }).erasingElements([.init(elementID:"shape",frame:local)])
    let drawing = try PageInkDrawing(actions:[erase]).dataRepresentation()
    func render(_ drawing: Data) async throws -> [UInt8] {
      let page = PageDocument(size:.init(width:400,height:800),actor:UUID(),drawingData:drawing,elements:elements)
      // Roundtrip the complete source; groups never become flattened paths or pixels.
      let restored = try JSONDecoder().decode(PageDocument.self,from:JSONEncoder().encode(page))
      let result = try await PageCompositionRenderer.render(restored,scale:1) { _ in
        XCTFail("A nonpainting group must not request WebKit"); throw CocoaError(.featureUnsupported)
      }
      let proof = XCTAttachment(data:result.png,uniformTypeIdentifier:"public.png")
      proof.name = drawing.isEmpty ? "group-basis-uncut" : "group-basis-cut"; proof.lifetime = .keepAlways; add(proof)
      return try pixels(result.png)
    }
    let cut = try await render(drawing), uncut = try await render(Data())
    // Local (30,30) -> whole (180,150); (75,30) -> (180,285).
    XCTAssertFalse(dark(cut,180,150)); XCTAssertTrue(dark(uncut,180,150))
    XCTAssertTrue(dark(cut,180,285)); XCTAssertTrue(dark(uncut,180,285))
    XCTAssertFalse(dark(cut,60,70),"The local source frame is not an extra painted copy")
  }

  func testLassoUsesDisplayedContoursAndDoesNotSelectTheGroupDescriptor() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("group-lasso-\(UUID())")
    let store=NotebookStore(root:root),actor=UUID(),size=PageSize(width:600,height:400)
    let (workspace,_)=try store.loadOrCreate(actor:actor,pageSize:size)
    let pageID=try XCTUnwrap(workspace.selectedPageID)
    let turn=NotebookGraphicTransform(a:0,b:1,c:-1,d:0,tx:1,ty:0)
    let ink=NotebookFreehand(layers:[.init(color:.black,vertices:[
      .init(x:0.1,y:0.1,opacity:1),.init(x:0.6,y:0.1,opacity:1),.init(x:0.1,y:0.6,opacity:1)])])
    var page=try store.loadPage(pageID)
    page.replaceElements([
      .init(id:"whole",kind:.group,frame:.init(x:100,y:50,width:400,height:200),source:"",html:"",basis:.init(size:.init(x:100,y:100),transform:turn)),
      .init(id:"ellipse",kind:.graphic,frame:.init(x:0,y:0,width:100,height:100),source:"",html:"",graphic:.init(shape:.ellipse,style:.init(fill:.black)),parentID:"whole"),
      .init(id:"ink",kind:.graphic,frame:.init(x:0,y:0,width:100,height:100),source:"",html:"",graphic:.init(shape:.freehand,freehand:ink),parentID:"whole")],actor:actor)
    try store.savePage(page)
    let model=NotebookAppModel(store:store,startsNearbySync:false)
    retainNotebookUntilTeardown(model,removing:root);await model.start(pageSize:size)
    let address=NotebookToolAddress(surface:.page(pageID),boardID:nil,worldOrigin:nil,bounds:nil)
    model.selectDrawingTool(.lasso)
    func lasso(_ min: Double,_ max: Double,ink: Bool,passes: Int = 1) {
      model.drawingToolSettings.lassoSelectsInk=ink;model.drawingToolSettings.lassoSelectsObjects = !ink
      let local:[SpatialPoint]=[.init(x:min,y:min),.init(x:max,y:min),.init(x:max,y:max),.init(x:min,y:max)]
      let repeated:[SpatialPoint]=Array(repeating:local,count:passes).flatMap { $0 }
      let points:[SpatialPoint]=repeated.map { point in SpatialPoint(x:500.0-4.0*point.y,y:50.0+2.0*point.x) }
      XCTAssertTrue(model.drawingTools.begin(at:points[0],address:address,screenScale:1))
      for point in points.dropFirst() { model.drawingTools.move(to:point) };model.drawingTools.finish()
    }
    lasso(2,5,ink:false)
    XCTAssertTrue(model.selectionSession.elements.isEmpty,"Neither the empty ellipse corner nor its nonpainting group is selected")
    lasso(40,60,ink:false);XCTAssertEqual(model.selectionSession.elements,[address.reference("ellipse")])
    lasso(40,60,ink:false,passes:2);XCTAssertTrue(model.selectionSession.elements.isEmpty,"Repeated lasso loops keep the existing even-odd rule")
    lasso(18,22,ink:true);XCTAssertEqual(model.selectionSession.elements,[address.reference("ink")])
    lasso(78,82,ink:true);XCTAssertTrue(model.selectionSession.elements.isEmpty,"The freehand's empty bounding-box corner stays empty")
  }

  func testHeldMemberEditsItsOwnBasisAndKeepsItsOriginalBodyThroughSaveAndUndo() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("group-pose-\(UUID())")
    let store=NotebookStore(root:root),size=PageSize(width:800,height:1000)
    let model=NotebookAppModel(store:store,startsNearbySync:false)
    retainNotebookUntilTeardown(model,removing:root);await model.start(pageSize:size)
    let initialized=await model.finishPendingPersistence();XCTAssertTrue(initialized)
    var page=try XCTUnwrap(model.activePage)
    let pageID=page.id,actor=model.actorID
    let graphic=NotebookGraphic(shape:.rectangle,style:.init(strokeWidth:8,fill:.black),cornerRadius:6)
    page.replaceElements([
      .init(id:"whole",kind:.group,frame:.init(x:40,y:30,width:240,height:600),source:"",html:"",
        basis:.init(size:.init(x:200,y:120),transform:.init(a:0,b:1,c:-1,d:0,tx:1,ty:0))),
      .init(id:"shape",kind:.graphic,frame:.init(x:10,y:20,width:100,height:60),source:"",html:"",graphic:graphic,parentID:"whole")],actor:actor)
    try store.savePage(page);await model.reloadExternalChanges()?.value
    let reference=EditableElementReference.page(pageID:pageID,elementID:"shape")
    func shown() throws -> NotebookGraphicLayout { try XCTUnwrap(model.graphicLayout(reference)) }
    func check(_ f: PageRect,_ expected: PageRect) {
      XCTAssertEqual(f.x,expected.x,accuracy:1e-9);XCTAssertEqual(f.y,expected.y,accuracy:1e-9)
      XCTAssertEqual(f.width,expected.width,accuracy:1e-9);XCTAssertEqual(f.height,expected.height,accuracy:1e-9)
    }
    model.selectElement(reference)
    let before=try shown(),move=try XCTUnwrap(model.beginElementManipulation(reference,kind:.move))
    model.updateElementManipulation(move,translation:.init(x:20,y:40))
    check(try shown().frame,.init(x:140,y:100,width:120,height:300))
    XCTAssertEqual(try store.loadPage(pageID),page,"Movement samples do not write or flatten the source")
    model.cancelElementManipulation(move);XCTAssertEqual(try shown(),before)
    let movedContact=try XCTUnwrap(model.beginElementManipulation(reference,kind:.move))
    XCTAssertTrue(model.finishElementManipulation(movedContact,translation:.init(x:20,y:40)))
    let movedSaved=await model.finishPendingPersistence();XCTAssertTrue(movedSaved);await model.reloadExternalChanges()?.value
    let moved=try store.loadPage(pageID)
    XCTAssertNotEqual(moved.elements[1].frame,page.elements[1].frame,model.actionCue ?? "The accepted movement was not stored")
    XCTAssertEqual(moved.elements[0],page.elements[0]);XCTAssertEqual(moved.elements[1].graphic,graphic)
    XCTAssertNil(moved.elements[1].basis);XCTAssertEqual(moved.elements[1].parentID,"whole")
    check(try shown().frame,.init(x:140,y:100,width:120,height:300))
    let resize=try XCTUnwrap(model.beginElementManipulation(reference,kind:.resize(.bottomTrailing)))
    model.updateElementManipulation(resize,translation:.init(x:60,y:-60))
    let preview=try shown();check(preview.frame,.init(x:140,y:100,width:180,height:240))
    XCTAssertEqual(try store.loadPage(pageID),moved)
    XCTAssertTrue(model.finishElementManipulation(resize,translation:.init(x:60,y:-60)))
    XCTAssertEqual(try shown(),preview,"Accepted preview remains at the measured position")
    let resizedSaved=await model.finishPendingPersistence();XCTAssertTrue(resizedSaved);await model.reloadExternalChanges()?.value
    let resized=try NotebookStore(root:root).loadPage(pageID)
    XCTAssertEqual(resized.elements[0],page.elements[0]);XCTAssertEqual(resized.elements[1].graphic,graphic)
    XCTAssertEqual(resized.elements[1].basis?.size,.init(x:100,y:60));XCTAssertEqual(resized.elements[1].parentID,"whole")
    XCTAssertEqual(try shown(),preview,"Saving never re-solves the pointer against a different basis")
    let action=try XCTUnwrap(store.collaborationActions(afterID:nil).first { $0.action.operations.contains { $0.id == "shape" && $0.values["basis"] != nil } })
    model.undoCollaboration(action.id)
    let undone=await model.finishPendingPersistence();XCTAssertTrue(undone);await model.reloadExternalChanges()?.value
    XCTAssertEqual(try store.loadPage(pageID).elements,moved.elements)
    let stale=try XCTUnwrap(model.beginElementManipulation(reference,kind:.move))
    let source=try store.readPageElement(pageID:pageID,elementID:"whole"),target=CollaborationTarget(kind:.page,id:pageID)
    _ = try store.applyNativeElementEdits([.init(kind:.updateElement,target:target,id:"whole",values:["frame":try .encode(PageRect(x:80,y:30,width:240,height:600))])],
      summary:"Другой участник переместил основание",sources:[.init(target:target,id:"whole",page:source)],actor:UUID())
    await model.reloadExternalChanges()?.value
    let queued=model.finishElementManipulation(stale,translation:.init(x:20,y:40))
    let staleFinished=await model.finishPendingPersistence();XCTAssertTrue(staleFinished);await model.reloadExternalChanges()?.value
    if queued { XCTAssertNotNil(model.actionCue,"Queued admission is not a durable receipt; the changed parent must reject it") }
    XCTAssertNil(model.retainedGraphicGraph { .page(pageID:pageID,elementID:$0) })
    XCTAssertEqual(try store.loadPage(pageID).elements[1],moved.elements[1],"A late lift cannot adopt another whole's placement")
  }

  func testConnectorEndpointAndBodyDragUseTheSameNestedBasis() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("group-connector-drag-\(UUID())")
    let model=NotebookAppModel(store:.init(root:root),startsNearbySync:false)
    retainNotebookUntilTeardown(model,removing:root);await model.start(pageSize:.init(width:800,height:1000))
    let initialized=await model.finishPendingPersistence();XCTAssertTrue(initialized)
    var page=try XCTUnwrap(model.activePage)
    let graphic=NotebookGraphic(shape:.connector,connection:.init(start:.init(point:.zero,binding:.init(elementID:"shape")),
      end:.init(point:.init(x:170,y:60)),bend:20))
    page.replaceElements([
      .init(id:"whole",kind:.group,frame:.init(x:40,y:30,width:240,height:600),source:"",html:"",
        basis:.init(size:.init(x:200,y:120),transform:.init(a:0,b:1,c:-1,d:0,tx:1,ty:0))),
      .init(id:"shape",kind:.graphic,frame:.init(x:10,y:20,width:60,height:60),source:"",html:"",graphic:.init(shape:.ellipse),parentID:"whole"),
      .init(id:"arrow",kind:.graphic,frame:.init(x:0,y:0,width:200,height:120),source:"",html:"",graphic:graphic,parentID:"whole")],actor:model.actorID)
    try model.store.savePage(page);await model.reloadExternalChanges()?.value
    let reference=EditableElementReference.page(pageID:page.id,elementID:"arrow")
    func shown() throws -> NotebookGraphicLayout { try XCTUnwrap(model.graphicLayout(reference)) }
    func point(_ p: SpatialPoint,_ layout: NotebookGraphicLayout) -> CGPoint {
      let p=layout.displayedPoint(p);return .init(x:layout.frame.x+p.x,y:layout.frame.y+p.y)
    }
    model.selectElement(reference)
    let before=try shown(),end=point(before.end,before),contact=try XCTUnwrap(model.beginElementManipulation(reference,kind:.endpoint(.end)))
    model.updateElementManipulation(contact,translation:.init(x:20,y:30))
    let preview=try shown(),nextEnd=point(preview.end,preview)
    XCTAssertEqual(nextEnd.x,end.x+20,accuracy:1e-8);XCTAssertEqual(nextEnd.y,end.y+30,accuracy:1e-8)
    XCTAssertTrue(model.finishElementManipulation(contact,translation:.init(x:20,y:30)))
    let endpointSaved=await model.finishPendingPersistence();XCTAssertTrue(endpointSaved);await model.reloadExternalChanges()?.value
    XCTAssertEqual(try shown(),preview)
    let move=try XCTUnwrap(model.beginElementManipulation(reference,kind:.move))
    model.updateElementManipulation(move,translation:.init(x:20,y:30))
    let moved=try shown()
    XCTAssertEqual(moved.curves.count,preview.curves.count)
    for (a,b) in zip(preview.curves,moved.curves) {
      for t in [0.0,0.25,0.5,0.75,1.0] {
        let old=point(a.point(at:t),preview),new=point(b.point(at:t),moved)
        XCTAssertEqual(new.x,old.x+20,accuracy:1e-8);XCTAssertEqual(new.y,old.y+30,accuracy:1e-8)
      }
    }
    XCTAssertTrue(model.finishElementManipulation(move,translation:.init(x:20,y:30)))
    let movedSaved=await model.finishPendingPersistence();XCTAssertTrue(movedSaved);await model.reloadExternalChanges()?.value
    let saved=try model.store.loadPage(page.id)
    XCTAssertEqual(saved.elements[0],page.elements[0]);XCTAssertEqual(saved.elements[1],page.elements[1])
    XCTAssertEqual(saved.elements[2].graphic?.connection?.bindings,[])
    XCTAssertEqual(try shown(),moved)
  }

  func testSelectionCreatesAndManipulatesOneWholeWithoutRewritingItsMembers() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("group-controls-\(UUID())")
    let model=NotebookAppModel(store:.init(root:root),startsNearbySync:false)
    retainNotebookUntilTeardown(model,removing:root);await model.start(pageSize:.init(width:800,height:1000))
    let initialized=await model.finishPendingPersistence();XCTAssertTrue(initialized)
    var page=try XCTUnwrap(model.activePage)
    page.replaceElements([
      .init(id:"a",kind:.graphic,frame:.init(x:150,y:150,width:100,height:80),source:"",html:"",graphic:.init(shape:.rectangle,style:.init(strokeWidth:6,fill:.black))),
      .init(id:"between",kind:.graphic,frame:.init(x:200,y:170,width:30,height:30),source:"",html:"",graphic:.init(shape:.ellipse)),
      .init(id:"b",kind:.graphic,frame:.init(x:300,y:200,width:80,height:100),source:"",html:"",graphic:.init(shape:.ellipse,style:.init(strokeWidth:4,fill:.black)))],actor:model.actorID)
    try model.store.savePage(page);await model.reloadExternalChanges()?.value
    func ref(_ id:String) -> EditableElementReference { .page(pageID:page.id,elementID:id) }
    func graph() throws -> NotebookGraphicGraph { model.graphicGraph(page:try XCTUnwrap(model.pages[page.id])) }
    let before=try graph(),original=try ["a","b"].map { try XCTUnwrap(before.resolve($0).layout) }
    model.selectElements([ref("a"),ref("b")]);XCTAssertTrue(model.canGroupSelectedElements)
    model.groupSelectedElements()
    let deadline=ContinuousClock.now + .seconds(10)
    while model.selectionSession.element.map({ model.isElementGroup($0) }) != true,ContinuousClock.now<deadline { try await Task.sleep(for:.milliseconds(10)) }
    let whole=try XCTUnwrap(model.selectionSession.element),grouped=try model.store.loadPage(page.id)
    XCTAssertTrue(model.isElementGroup(whole));XCTAssertEqual(model.parentGroup(ref("a")),whole)
    XCTAssertEqual(grouped.elements.filter { $0.kind != .group }.map(\.id),page.elements.map(\.id))
    XCTAssertEqual(try ["a","b"].map { try XCTUnwrap(graph().resolve($0).layout) },original)
    let children=grouped.elements.filter { $0.kind != .group }
    let held=try XCTUnwrap(model.beginElementManipulation(whole,kind:.move))
    let capture=try XCTUnwrap(model.selectionSession.manipulation?.graphicCapture)
    XCTAssertTrue(capture.closedGroup)
    let initialBounds=try XCTUnwrap(capture.graph.groupBounds(whole.elementID))
    // Real model update and both display queries, after contact admission.
    // No leaf is resolved merely to update the whole's controls.
    let clock=ContinuousClock(),start=clock.now
    for step in 0..<100 {
      let delta=SpatialPoint(x:Double(step%31),y:Double(step%41))
      model.updateElementManipulation(held,translation:delta)
      let projection=try graph(),geometry=try XCTUnwrap(model.groupManipulationGeometry(whole))
      XCTAssertTrue(projection.sharesSource(with:capture.graph))
      XCTAssertEqual(projection.projectedPlacementReadCount,0)
      XCTAssertEqual(geometry.bounds,initialBounds.offsetBy(dx:delta.x,dy:delta.y))
    }
    let timing=XCTAttachment(string:"GUI291 model 100 held whole updates + graph + controls: \(start.duration(to:clock.now)); 2 grouped members and 1 unchanged outsider; excludes cold admission and painting")
    timing.name="gui291-held-whole-model-cost";timing.lifetime = .keepAlways;add(timing)
    model.updateElementManipulation(held,translation:.init(x:30,y:40))
    for (id,old) in zip(["a","b"],original) {
      let next=try XCTUnwrap(graph().resolve(id).layout)
      XCTAssertEqual(next.frame.x,old.frame.x+30,accuracy:1e-9);XCTAssertEqual(next.frame.y,old.frame.y+40,accuracy:1e-9)
    }
    XCTAssertEqual(try model.store.loadPage(page.id),grouped,"A held whole does not write any child")
    model.cancelElementManipulation(held)
    XCTAssertNil(model.retainedGraphicGraph(reference:ref))
    XCTAssertEqual(try ["a","b"].map { try XCTUnwrap(graph().resolve($0).layout) },original)
    let move=try XCTUnwrap(model.beginElementManipulation(whole,kind:.move))
    let moveCapture=try XCTUnwrap(model.selectionSession.manipulation?.graphicCapture)
    XCTAssertTrue(model.finishElementManipulation(move,translation:.init(x:30,y:40)))
    let accepted=try graph()
    XCTAssertTrue(accepted.sharesSource(with:moveCapture.graph))
    XCTAssertEqual(accepted.projectedPlacementReadCount,0)
    XCTAssertEqual(model.groupManipulationGeometry(whole)?.bounds,initialBounds.offsetBy(dx:30,dy:40))
    // A following member draft invalidates the closed whole's retained bounds.
    // This is projection-only; removing it before yielding cannot write a child.
    var member=try XCTUnwrap(accepted.source("a"))
    member.frame = .init(x:member.frame.x+300,y:member.frame.y,width:member.frame.width,height:member.frame.height)
    model.elementCommandDrafts[ref("a")] = .init(source:member,graphic:accepted.node("a")?.graphic)
    let expanded=try XCTUnwrap(graph().groupBounds(whole.elementID))
    XCTAssertGreaterThan(expanded.maxX,initialBounds.maxX+30)
    XCTAssertEqual(model.groupManipulationGeometry(whole)?.bounds,expanded)
    model.elementCommandDrafts[ref("a")] = nil
    let moved=await model.finishPendingPersistence();XCTAssertTrue(moved);await model.reloadExternalChanges()?.value
    XCTAssertNil(model.retainedGraphicGraph(reference:ref))
    XCTAssertEqual(try model.store.loadPage(page.id).elements.filter { $0.kind != .group },children)
    for id in ["a","b"] { XCTAssertEqual(try graph().resolve(id).layout,accepted.resolve(id).layout) }
    let resize=try XCTUnwrap(model.beginElementManipulation(whole,kind:.resize(.bottomTrailing)))
    model.updateElementManipulation(resize,translation:.init(x:40,y:30));let resized=try graph()
    XCTAssertTrue(model.finishElementManipulation(resize,translation:.init(x:40,y:30)))
    let saved=await model.finishPendingPersistence();XCTAssertTrue(saved);await model.reloadExternalChanges()?.value
    XCTAssertEqual(try model.store.loadPage(page.id).elements.filter { $0.kind != .group },children)
    for id in ["a","b"] { XCTAssertEqual(try graph().resolve(id).layout,resized.resolve(id).layout) }
    model.transformGraphicSelection(radians:.pi/2)
    let rotated=try graph()
    let rotationSaved=await model.finishPendingPersistence();XCTAssertTrue(rotationSaved);await model.reloadExternalChanges()?.value
    let reopened=try NotebookStore(root:root).loadPage(page.id)
    XCTAssertEqual(reopened.elements.filter { $0.kind != .group },children)
    for id in ["a","b"] { XCTAssertEqual(reopened.graphicGraph().resolve(id).layout,rotated.resolve(id).layout) }
    let actions=try model.store.collaborationActions(afterID:nil)
    let rotation=try XCTUnwrap(actions.first { $0.action.summary == "Повернуть группу" })
    XCTAssertEqual(rotation.action.operations.count,1)
    model.undoCollaboration(rotation.id)
    let undone=await model.finishPendingPersistence();XCTAssertTrue(undone);await model.reloadExternalChanges()?.value
    for id in ["a","b"] { XCTAssertEqual(try graph().resolve(id).layout,resized.resolve(id).layout) }
    let export=try await PageCompositionRenderer.render(reopened,scale:1) { _ in
      XCTFail("The group has no document surface");throw CocoaError(.featureUnsupported)
    }
    let proof=XCTAttachment(data:export.png,uniformTypeIdentifier:"public.png");proof.name="group-controls-saved-export";proof.lifetime = .keepAlways;add(proof)
  }

  func testBoardBasisWaitsForPassiveMembersAndDoesNotMixMembershipCuts() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("group-cohort-\(UUID())")
    let model=NotebookAppModel(store:.init(root:root),startsNearbySync:false)
    retainNotebookUntilTeardown(model,removing:root);await model.start(pageSize:.init(width:800,height:1000))
    let initialized=await model.finishPendingPersistence();XCTAssertTrue(initialized)
    let boardID=try XCTUnwrap(model.workspace?.rootBoardID),target=CollaborationTarget(kind:.board,id:boardID),group=UUID().uuidString
    let operations:[CollaborationOperation]=[
      .init(kind:.insertElement,target:target,id:group,values:["kind":.string("group"),"source":.string(""),"worldOrigin":try .encode(WorldPoint.zero),
        "frame":try .encode(PageRect(x:40,y:50,width:200,height:100)),"basis":try .encode(NotebookElementBasis(size:.init(x:200,y:100)))]),
      .init(kind:.insertElement,target:target,id:"a",values:["kind":.string("graphic"),"source":.string(""),"worldOrigin":try .encode(WorldPoint.zero),
        "frame":try .encode(PageRect(x:10,y:10,width:60,height:50)),"parentID":.string(group.lowercased()),"graphic":try .encode(NotebookGraphic(shape:.rectangle))]),
      .init(kind:.insertElement,target:target,id:"b",values:["kind":.string("graphic"),"source":.string(""),"worldOrigin":try .encode(WorldPoint.zero),
        "frame":try .encode(PageRect(x:100,y:20,width:70,height:50)),"parentID":.string(group),"graphic":try .encode(NotebookGraphic(shape:.ellipse))])]
    _ = try model.store.applyNativeElementEdits(operations,summary:"Группа на доске",sources:operations.map { .init(target:target,id:$0.id!) },actor:model.actorID)
    await model.reloadExternalChanges()?.value
    let workspace=try XCTUnwrap(model.workspace),hierarchy=try XCTUnwrap(model.boardHierarchy),captured=try XCTUnwrap(hierarchy.board(boardID))
    let index=WorkspaceSceneIndex(workspace:workspace,hierarchy:hierarchy,paperSizes:[:])
    let presence=SessionPresence(boardID:boardID,mode:.board,camera:.init(),viewport:.init(x:800,y:600))
    let frame=WorkspaceSceneFrame(index:index,presence:presence,portalCamera:{ _ in nil })
    func cohort(_ live:[String]) -> SceneCompositionCohort {
      let owners=live.enumerated().map { i,id in SceneCompositionLiveOwner(plane:.board(boardID),id:.element(id),position:.init(layer:.elements,zIndex:Double(i),key:id)) }
      let plan=SceneCompositionPlan(revision:1,workspaceID:index.generationID,rootBoardID:boardID,inkBoardIDs:[],liveOwners:owners,protectedOwners:[],
        bands:[],coverage:[:],presentations:[.board(boardID):presence],tiles:[])
      let data=SceneCompositionLiveData(documents:[:],states:[:],pages:[:],ink:.init(stamp:workspace.stamp))
      #if os(iOS)
      return .init(plan:plan,frame:frame,requestedSources:frame.sourceIdentity,liveData:data,rasters:[:],liveRasters:[:],
        nativeInk:.init(registry:.init(),rootBoardID:boardID,focusedCoverID:nil,owners:[:],updates:[]))
      #else
      return .init(plan:plan,frame:frame,liveData:data,rasters:[:],liveRasters:[:])
      #endif
    }
    let source=try model.store.readSpatialElement(boardID:boardID,elementID:group)
    _ = try model.store.applyNativeElementEdits([.init(kind:.updateElement,target:target,id:group,values:["frame":try .encode(PageRect(x:130,y:70,width:200,height:100))])],
      summary:"Переместить общее основание",sources:[.init(target:target,id:group,spatial:source)],actor:model.actorID)
    await model.reloadExternalChanges()?.value
    let old=captured.graphicGraph(),all=cohort(["a","b"]),partial=cohort(["a"])
    for id in ["a","b"] {
      let before=try XCTUnwrap(old.resolve(id).layout)
      let moved=try XCTUnwrap(model.presentedGraphicGraph(boardID:boardID,cohort:all).resolve(id).layout)
      XCTAssertEqual(moved.frame.x,before.frame.x+90,accuracy:1e-9);XCTAssertEqual(moved.frame.y,before.frame.y+20,accuracy:1e-9)
      XCTAssertEqual(model.presentedGraphicGraph(boardID:boardID,cohort:partial).resolve(id).layout,before,
        "One live member must not move ahead of the same whole's retained passive pixels")
    }
    let beforeRegroup=model.presentedGraphicGraph(boardID:boardID,cohort:all)
    _ = try model.store.groupNativeElements(["a","b"].map { try .init(target:target,id:$0,spatial:model.store.readSpatialElement(boardID:boardID,elementID:$0)) },id:"nested",actor:model.actorID)
    await model.reloadExternalChanges()?.value
    let retained=model.presentedBoard(captured,boardID:boardID,cohort:all)
    XCTAssertEqual(retained.elements.first { $0.id == "a" }?.parentID,group.lowercased())
    for id in ["a","b"] { XCTAssertEqual(model.presentedGraphicGraph(boardID:boardID,cohort:all).resolve(id).layout,beforeRegroup.resolve(id).layout) }
  }

  func testPageViewportSkipsHiddenMembersAndKeepsTheSameVisiblePixelsDuringAWholeDrag() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("group-visible-\(UUID())")
    let model=NotebookAppModel(store:.init(root:root),startsNearbySync:false)
    retainNotebookUntilTeardown(model,removing:root);await model.start(pageSize:.init(width:1000,height:1000))
    let initialized=await model.finishPendingPersistence();XCTAssertTrue(initialized)
    var page=try XCTUnwrap(model.activePage)
    let whole=AgentElement(id:"whole",kind:.group,frame:.init(x:20,y:20,width:900,height:900),source:"",html:"",basis:.init(size:.init(x:900,y:900)))
    var children=(0..<1000).map { i in AgentElement(id:"part-\(i)",kind:.graphic,
      frame:.init(x:Double(i%32)*28,y:Double(i/32)*28,width:16,height:16),source:"",html:"",
      graphic:.init(shape:i.isMultiple(of:2) ? .rectangle : .ellipse,style:.init(strokeWidth:1,fill:.black)),parentID:"whole") }
    children.insert(.init(id:"between",kind:.graphic,frame:.init(x:350,y:390,width:30,height:30),source:"",html:"",
      graphic:.init(shape:.ellipse,style:.init(strokeWidth:3,fill:.init(red:1,green:1,blue:1)))),at:501)
    XCTAssertTrue(page.replaceElements([whole]+children,actor:model.actorID))
    try model.store.savePage(page);await model.reloadExternalChanges()?.value
    page=try XCTUnwrap(model.pages[page.id])
    let reference=EditableElementReference.page(pageID:page.id,elementID:"whole")
    model.selectElement(reference)
    let held=try XCTUnwrap(model.beginElementManipulation(reference,kind:.move))
    model.updateElementManipulation(held,translation:.init(x:40,y:50))
    let area=CGRect(x:340,y:370,width:48,height:48)
    let visible=model.pageGraphicDisplay(page,in:area)
    XCTAssertEqual(visible.elements.count,5)
    XCTAssertLessThan(visible.resolvedGraphics,8);XCTAssertLessThan(visible.visitedIndexNodes,150)
    XCTAssertEqual(visible.elements.map(\.id),page.elements.filter { visible.layouts[$0.id] != nil }.map(\.id))
    func render(_ region:CGRect?) throws -> CGImage {
      let painter=ImageRenderer(content:AgentOverlayView(page:page,renderingScale:1,allowsInteraction:false,inputEnabled:false,
        onRenderReady:{ _ in },onState:{ _,_ in false },visibleRegion:region).environment(model)
        .frame(width:1000,height:1000).background(Color.white))
      painter.scale=1
      return try XCTUnwrap(painter.cgImage)
    }
    func rgba(_ image:CGImage) throws -> Data {
      let clipped=try XCTUnwrap(image.cropping(to:area))
      let context=try XCTUnwrap(CGContext(data:nil,width:clipped.width,height:clipped.height,bitsPerComponent:8,bytesPerRow:clipped.width*4,
        space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(clipped,in:.init(x:0,y:0,width:clipped.width,height:clipped.height))
      return Data(bytes:try XCTUnwrap(context.data),count:clipped.width*clipped.height*4)
    }
    let all=try render(nil),small=try render(area),pixels=try rgba(small)
    XCTAssertEqual(pixels,try rgba(all),"Culling must retain the interleaved painter order and exactly the same crop")
    XCTAssertTrue(stride(from:0,to:pixels.count,by:4).contains { pixels[$0]<80 && pixels[$0+1]<80 && pixels[$0+2]<80 },"An empty image is not a valid comparison")
    let clock=ContinuousClock()
    func ms(_ d:Duration) -> Double { let c=d.components;return Double(c.seconds)*1000+Double(c.attoseconds)/1e15 }
    var full:[Double]=[],bounded:[Double]=[]
    for i in 0..<10 {
      for limited in (i.isMultiple(of:2) ? [false,true] : [true,false]) {
        let start=clock.now,image=try render(limited ? area : nil),elapsed=ms(start.duration(to:clock.now))
        XCTAssertEqual(image.width,1000)
        if limited { bounded.append(elapsed) } else { full.append(elapsed) }
      }
    }
    let record:[String:Any]=["scope":"Debug ImageRenderer, same live AgentOverlayView, warm source/index, 1001 graphics, 48x48 crop; not on-screen FPS or input-to-present",
      "fullPageMs":full,"visibleOnlyMs":bounded,"displayedGraphics":visible.elements.count,
      "resolvedGraphics":visible.resolvedGraphics,"visitedIndexNodes":visible.visitedIndexNodes]
    let timing=XCTAttachment(data:try JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
    timing.name="gui291-page-visible-render-cost";timing.lifetime = .keepAlways;add(timing)
    let data=NSMutableData(),destination=try XCTUnwrap(CGImageDestinationCreateWithData(data,"public.png" as CFString,1,nil))
    CGImageDestinationAddImage(destination,small,nil);XCTAssertTrue(CGImageDestinationFinalize(destination))
    let proof=XCTAttachment(data:data as Data,uniformTypeIdentifier:"public.png");proof.name="group-visible-page-crop";proof.lifetime = .keepAlways;add(proof)
    model.cancelElementManipulation(held)
    XCTAssertEqual(try model.store.loadPage(page.id).elements,page.elements)
  }

  func testNativeCameraChangesTheGraphicCandidatesWithoutRepublishingTheirSource() async throws {
    #if os(iOS)
    let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous=scene.windows.first { $0.isKeyWindow },window=UIWindow(windowScene:scene),controller=UIViewController()
    window.rootViewController=controller;window.makeKeyAndVisible()
    defer { window.isHidden=true;window.rootViewController=nil;previous?.makeKey() }
    let clip=UIView(frame:.init(x:30,y:30,width:96,height:96));clip.clipsToBounds=true
    controller.view.addSubview(clip)
    let host=PagePresentationNativeView()
    #else
    let window=NSWindow(contentRect:.init(x:0,y:0,width:96,height:96),styleMask:[.titled],backing:.buffered,defer:false)
    let clip=PagePresentationNativeView(frame:.init(x:0,y:0,width:96,height:96))
    window.contentView=clip;window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil);window.contentView=nil }
    let host=PagePresentationNativeView(frame:.zero)
    #endif
    host.frame = .init(x:-160,y:0,width:400,height:400);clip.addSubview(host)
    let viewport=host.viewport;defer { viewport.stop() }
    let page=PageDocument(size:.init(width:400,height:400),actor:UUID(),elements:[
      .init(id:"a",kind:.graphic,frame:.init(x:180,y:20,width:20,height:20),source:"",html:"",graphic:.init(shape:.rectangle)),
      .init(id:"b",kind:.graphic,frame:.init(x:20,y:20,width:20,height:20),source:"",html:"",graphic:.init(shape:.ellipse))])
    let graph=page.graphicGraph(),projection=ScenePlaneProjection(.init(mode:.page,camera:.init(),viewport:.init(x:96,y:96)))
    viewport.isVisible=true
    func move(_ x:CGFloat,expecting id:String) async {
      let ready=expectation(description:"Native viewport shows \(id)")
      viewport.onRegion={ area in
        XCTAssertTrue(page.graphicGraph().sharesSource(with:graph))
        let candidates=graph.visiblePageGraphics(page.id,in:area)
        if Set(candidates.layouts.keys) == [id] { ready.fulfill() }
      }
      host.frame.origin.x=x;viewport.observe(projection);projection.didProject()
      await fulfillment(of:[ready],timeout:3)
    }
    await move(-160,expecting:"a");await move(0,expecting:"b");await move(-160,expecting:"a")
  }

  private func pixels(_ png: Data) throws -> [UInt8] {
    let source=try XCTUnwrap(CGImageSourceCreateWithData(png as CFData,nil))
    let image=try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
    let context=try XCTUnwrap(CGContext(data:nil,width:400,height:800,bitsPerComponent:8,bytesPerRow:1600,
      space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image,in:.init(x:0,y:0,width:400,height:800))
    return Array(UnsafeBufferPointer(start:try XCTUnwrap(context.data).assumingMemoryBound(to:UInt8.self),count:400*800*4))
  }
  private func dark(_ pixels: [UInt8],_ x: Int,_ y: Int) -> Bool {
    let p=(y*400+x)*4
    return max(pixels[p],pixels[p+1],pixels[p+2])<80
  }
}

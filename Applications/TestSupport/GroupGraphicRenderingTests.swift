import CoreGraphics
import Foundation
import ImageIO
import NotebookCore
import XCTest
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
      let points=Array(repeating:local,count:passes).flatMap { $0 }.map { SpatialPoint(x:500-4*$0.y,y:50+2*$0.x) }
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

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

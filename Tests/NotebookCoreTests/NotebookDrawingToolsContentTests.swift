import CoreGraphics
import Foundation
import Testing
@testable import NotebookCore

@Suite("Drawing tools content ownership")
struct NotebookDrawingToolsContentTests {
  @Test func freehandConversionUsesItsOwnSourceBudgetBeyondSixteenStrokes() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("lasso-many-\(UUID())")
    defer { try? FileManager.default.removeItem(at:root) }
    let actor = UUID(), store = NotebookStore(root:root)
    let (_,pages) = try store.loadOrCreate(actor:actor,pageSize:.init(width:600,height:800))
    _ = try store.loadOrCreateSpatialInk(actor:actor)
    var page = try #require(pages.values.first)
    let strokes = (0..<27).map { i in PageInkAction(tool:.pen,samples:[
      .init(point:.init(x:100,y:100+Double(i)),timeOffset:0,width:2,opacity:1,force:1,azimuth:0,altitude:1),
      .init(point:.init(x:200,y:100+Double(i)),timeOffset:1,width:2,opacity:1,force:1,azimuth:0,altitude:1)]) }
    let original = try PageInkDrawing(actions:strokes).dataRepresentation()
    let changed = page.replaceDrawing(original,actor:actor)
    #expect(changed); try store.savePage(page)
    let frame = PageRect(x:98,y:98,width:104,height:32)
    let graphic = NotebookGraphic(shape:.freehand,sourceInkIDs:strokes.map(\.id),freehand:.init(layers:strokes.map {
      .init(color:$0.color,vertices:NotebookFreehand.mesh(samples:$0.samples,frame:frame,origin:nil))
    }))
    let target = CollaborationTarget(kind:.page,id:page.id)
    let operation = CollaborationOperation(kind:.convertInkToElement,target:target,id:"handwriting",values:[
      "kind":.string("graphic"),"source":.string(""),"frame":try .encode(frame),"graphic":try .encode(graphic)])
    let result = try store.applyNativeElementEdits([operation],summary:"Lasso 27 strokes",sources:[.init(target:target,id:"handwriting")],
      expectedInkRevision:page.drawingStamp.revision,actor:actor)
    let saved = try NotebookStore(root:root).loadPage(page.id)
    #expect(saved.elements.first?.graphic == graphic)
    #expect(saved.graphicPresentation.suppressedInkIDs == Set(strokes.map(\.id)))
    #expect(saved.drawingData == original)
    _ = try store.undoCollaborationAction(result.receipt.id,actor:actor)
    #expect(try store.loadPage(page.id).graphicPresentation.suppressedInkIDs.isEmpty)
  }

  @Test func rotationKeepsPhysicalCornerRadiusRatherThanRoundingTheBoundingBox() throws {
    let graphic = NotebookGraphic(shape:.rectangle,cornerRadius:20)
    let frame = PageRect(x:0,y:0,width:200,height:80), surface = SurfaceID.page(UUID())
    let graph = NotebookGraphicGraph([.init(id:"a",graphic:graphic,frame:frame,surface:surface,shown:true)])
    let member = NotebookGraphicSelection.Member(id:"a",frame:frame,graphic:graphic,layout:try #require(graph.resolve("a").layout))
    let edit = try #require(NotebookGraphicSelection.transformed([member],radians:.pi/2).first)
    let path = NotebookGraphicGeometry.outlinePath(edit.graphic,in:.init(x:0,y:0,width:80,height:200))
    #expect(!path.contains(.init(x:2,y:2)))
    #expect(!path.contains(.init(x:7,y:4)))
    #expect(!NotebookGraphicGeometry.containsInterior(edit.graphic,width:80,height:200,x:7,y:4))
    #expect(path.contains(.init(x:7,y:7)))
    #expect(path.contains(.init(x:20,y:2)))
    let size = try #require(edit.graphic.transform).contentSize(in:.init(width:80,height:200))
    #expect(abs(size.width-200) < 0.000001 && abs(size.height-80) < 0.000001)
  }
  @Test func rotatedCutsUseTheBasisAtEraserAdmission() throws {
    let surface = SurfaceID.page(UUID())
    let original = NotebookGraphic(shape:.rectangle,style:.init(fill:.black))
    let frame = PageRect(x:100,y:100,width:200,height:80)
    let graph = NotebookGraphicGraph([.init(id:"a",graphic:original,frame:frame,surface:surface,shown:true)])
    let member = NotebookGraphicSelection.Member(id:"a",frame:frame,graphic:original,layout:try #require(graph.resolve("a").layout))
    let turned = try #require(NotebookGraphicSelection.transformed([member],radians:.pi/2).first)
    #expect(abs(turned.frame.width-80) < 0.000001)
    #expect(abs(turned.frame.height-200) < 0.000001)
    func sample(_ x:Double,_ y:Double) -> SpatialInkSample {
      .init(point:.init(x:x,y:y),timeOffset:0,width:10,opacity:1,force:1,azimuth:0,altitude:1)
    }
    // Vertical cut at original x=150 becomes a horizontal cut at new y=50.
    let cut = InkElementErasure(target:.init(elementID:"a",frame:frame),samples:[sample(150,100),sample(150,180)])
    let transformed = NotebookElementAppearance(graphic:turned.graphic,layout:nil,size:.init(width:80,height:200),erasures:[cut])
    #expect(!transformed.contains(.init(x:40,y:50),tolerance:0))
    #expect(transformed.contains(.init(x:40,y:140),tolerance:0))
    let second = InkElementErasure(target:.init(elementID:"a",frame:turned.frame,graphicTransform:turned.graphic.transform),
      samples:[sample(turned.frame.x,turned.frame.y+140),sample(turned.frame.x+80,turned.frame.y+140)])
    let atAdmission = NotebookElementAppearance(graphic:turned.graphic,layout:nil,size:.init(width:80,height:200),erasures:[second])
    #expect(!atAdmission.contains(.init(x:40,y:140),tolerance:0))
    #expect(atAdmission.contains(.init(x:40,y:50),tolerance:0))
  }

  @Test func nativePageTextAndFreehandHaveDurableFieldsAndAtomicUndo() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("drawing-content-\(UUID())")
    defer { try? FileManager.default.removeItem(at:root) }
    let actor = UUID(), store = NotebookStore(root:root)
    let (_,pages) = try store.loadOrCreate(actor:actor,pageSize:.init(width:600,height:800))
    let page = try #require(pages.values.first)
    _ = try store.loadOrCreateSpatialInk(actor:actor)
    let target = CollaborationTarget(kind:.page,id:page.id), textID = "text"
    let style = NativeTextStyle(fontSize:22,red:0.2,green:0.3,blue:0.6)
    let insert = CollaborationOperation(kind:.insertElement,target:target,id:textID,values:["kind":.string("nativeText"),
      "source":.string("Изменяемая подпись"),"textStyle":try .encode(style),"frame":try .encode(PageRect(x:20,y:30,width:200,height:80))])
    let receipt = try store.applyNativeElementEdits([insert],summary:"Text",sources:[.init(target:target,id:textID)],actor:actor).receipt
    let saved = try #require(try store.readPageElement(pageID:page.id,elementID:textID))
    #expect(saved.kind == .nativeText && saved.textStyle == style)
    _ = try store.applyNativeElementEdits([.init(kind:.updateElement,target:target,id:textID,values:["source":.string("После изменения")])],
      summary:"Edit",sources:[.init(target:target,id:textID,page:saved)],actor:actor)
    #expect(try NotebookStore(root:root).readPageElement(pageID:page.id,elementID:textID)?.source == "После изменения")
    // A stale page/source is not silently rebased.
    #expect(throws:CollaborationError.self) {
      try store.applyNativeElementEdits([.init(kind:.removeElement,target:target,id:textID)],summary:"Stale",sources:[.init(target:target,id:textID,page:saved)],actor:actor)
    }
    #expect(receipt.author == .human)
    let stroke = NotebookFreehand.Layer(color:.black,vertices:[.init(x:0,y:0,opacity:0.2),.init(x:1,y:0,opacity:0.8),.init(x:1,y:1,opacity:0.8)])
    let graphic = NotebookGraphic(shape:.freehand,freehand:.init(layers:[stroke]))
    let operation = CollaborationOperation(kind:.insertElement,target:target,id:"ink",values:["kind":.string("graphic"),"source":.string(""),
      "frame":try .encode(PageRect(x:100,y:200,width:100,height:100)),"graphic":try .encode(graphic)])
    let accepted = try store.applyNativeElementEdits([operation],summary:"Ink copy",sources:[.init(target:target,id:"ink")],actor:actor)
    #expect(try NotebookStore(root:root).readPageElement(pageID:page.id,elementID:"ink")?.graphic == graphic)
    _ = try store.undoCollaborationAction(accepted.receipt.id,actor:actor)
    #expect(try store.readPageElement(pageID:page.id,elementID:"ink") == nil)
  }

  @Test func roundTripTransformAndCopyRetainPressureWithoutClaimingSourceInk() throws {
    let frame = PageRect(x:100,y:100,width:120,height:40), surface = SurfaceID.page(UUID())
    let samples = [SpatialInkSample(point:.init(x:100,y:120),timeOffset:0,width:8,opacity:0.2,force:0.2,azimuth:0,altitude:1),
      .init(point:.init(x:220,y:120),timeOffset:1,width:8,opacity:0.9,force:0.9,azimuth:0,altitude:1)]
    let mesh = NotebookFreehand.mesh(samples:samples,frame:frame,origin:nil)
    let ink = NotebookFreehand(layers:[.init(color:.black,vertices:mesh)])
    let graphic = NotebookGraphic(shape:.freehand,sourceInkIDs:[UUID()],freehand:ink)
    let graph = NotebookGraphicGraph([.init(id:"ink",graphic:graphic,frame:frame,surface:surface,shown:true)])
    let member = NotebookGraphicSelection.Member(id:"ink",frame:frame,graphic:graphic,layout:try #require(graph.resolve("ink").layout))
    let turned = try #require(NotebookGraphicSelection.transformed([member],radians:.pi/6).first)
    let roundTrip = try JSONValue.encode(turned.graphic).decode(NotebookGraphic.self)
    #expect(roundTrip == turned.graphic && roundTrip.isValid)
    let copy = try #require(NotebookGraphicSelection.duplicated([member],namespace:UUID(),offset:.zero).first)
    #expect(copy.graphic.sourceInkIDs.isEmpty && copy.graphic.freehand == ink)
    #expect(mesh.map(\.opacity).min()! < 0.3 && mesh.map(\.opacity).max()! > 0.8)
    #expect(!ink.paintPath(size:.init(width:120,height:40),transform:nil).isEmpty)
    #expect(throws:CollaborationError.self) { try graphic.applying(.object(["transform":.object(["a":.number(0),"b":.number(0),"c":.number(0),"d":.number(0),"tx":.number(0),"ty":.number(0)])])) }
  }
}

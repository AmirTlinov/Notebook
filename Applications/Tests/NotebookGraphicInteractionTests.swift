import NotebookCore
import ImageIO
import SwiftUI
import UIKit
import XCTest
@testable import Notebook

@MainActor final class NotebookGraphicInteractionTests: XCTestCase {
  func testAgentPearlAppearanceAndExpiredRemount() async throws {
    let window = UIWindow(windowScene:try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let host = UIHostingController(rootView:AnyView(EmptyView()))
    window.overrideUserInterfaceStyle = .light
    window.rootViewController = host; window.makeKeyAndVisible()
    defer { host.rootView = AnyView(EmptyView()); window.isHidden = true; window.rootViewController = nil }
    let frame = CGRect(x:100,y:220,width:240,height:160), start = Date()
    func content(_ started: Date) -> AnyView {
      AnyView(ZStack(alignment:.topLeading) {
        Color(red:0.993,green:0.987,blue:0.965)
        NotebookGraphicView(graphic:.init(shape:.rectangle,label:"Действие агента"))
          .frame(width:frame.width,height:frame.height).position(x:frame.midX,y:frame.midY)
        NotebookAgentPearl(surface:.init(rect:frame,graphic:.init(shape:.rectangle)),startedAt:started)
      }.ignoresSafeArea())
    }
    func capture(_ name: String? = nil) -> UIImage {
      host.view.layoutIfNeeded()
      let image = UIGraphicsImageRenderer(bounds:frame.insetBy(dx:-16,dy:-16)).image { _ in
        host.view.drawHierarchy(in:host.view.bounds,afterScreenUpdates:true)
      }
      if let name {
        let attachment = XCTAttachment(image:image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
      }
      return image
    }
    host.rootView = content(start)
    var frames: [(image:CGImage,time:Date)] = []
    while Date().timeIntervalSince(start) < NotebookAppModel.agentHighlightDuration+0.2 {
      try await Task.sleep(for:.milliseconds(80))
      frames.append((capture().cgImage!,Date()))
    }
    let data = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data,"com.compuserve.gif" as CFString,frames.count,nil))
    for (index,frame) in frames.enumerated() {
      let delay = index+1 < frames.count ? frames[index+1].time.timeIntervalSince(frame.time) : 0.5
      CGImageDestinationAddImage(destination,frame.image,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:delay]] as CFDictionary)
    }
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    let motion = XCTAttachment(data:data as Data,uniformTypeIdentifier:"com.compuserve.gif")
    motion.name = "agent-pearl-physical-pass"; motion.lifetime = .keepAlways; add(motion)
    let expired = capture("agent-pearl-expired").pngData()
    host.rootView = content(start)
    try await Task.sleep(for:.milliseconds(100))
    XCTAssertEqual(capture("agent-pearl-remounted-expired").pngData(),expired,"A remounted expired accent cannot flash again")
  }

  func testAgentPearlSweepsWholeSilhouettesWithoutPaintingTheirBoundingBoxes() async throws {
    let window = UIWindow(windowScene:try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let host = UIHostingController(rootView:AnyView(EmptyView()))
    window.overrideUserInterfaceStyle = .light
    window.rootViewController = host; window.makeKeyAndVisible()
    defer { host.rootView = AnyView(EmptyView()); window.isHidden = true; window.rootViewController = nil }
    let shapes: [NotebookGraphic] = [
      .init(shape:.rectangle,label:"Действие агента"),
      .init(shape:.ellipse,label:"Идея"),
      .init(shape:.triangle),
      .init(shape:.diamond,vertices:[.init(x:0.18,y:0),.init(x:1,y:0.30),.init(x:0.82,y:1),.init(x:0,y:0.70)]),
      .init(shape:.plus,style:.init(strokeWidth:4)),
      .init(shape:.connector,style:.init(strokeWidth:4),label:"Связь",connection:.init(
        start:.init(point:.init(x:12,y:100)),end:.init(point:.init(x:245,y:18)),bend:30))
    ]
    let surfaces = shapes.enumerated().map { index, graphic in
      let scale = index == 3 ? 1.75 : 1.0
      let frame = PageRect(x:0,y:0,width:280/scale,height:180/scale)
      let layout = NotebookGraphicGraph([.init(id:"shape",graphic:graphic,frame:frame,surface:.page(UUID()),shown:true)])
        .resolve("shape").layout!
      return NotebookAgentPearlSurface(rect:.init(x:Double(28+(index%2)*330),y:Double(24+(index/2)*240),
        width:layout.frame.width*scale,height:layout.frame.height*scale),scale:scale,graphic:graphic,layout:layout)
    }
    let bounds = CGRect(x:0,y:0,width:680,height:700)
    func render(_ age: Double, _ name: String, reduceMotion: Bool = false) async throws -> UIImage {
      host.rootView = AnyView(ZStack(alignment:.topLeading) {
        Color(red:0.993,green:0.987,blue:0.965)
        Canvas { context, _ in
          for surface in surfaces {
            var ink = context
            ink.translateBy(x:surface.rect.minX,y:surface.rect.minY)
            ink.scaleBy(x:surface.scale,y:surface.scale)
            NotebookGraphicView.paint(surface.graphic!,layout:surface.layout,in:ink,
              size:.init(width:surface.rect.width/surface.scale,height:surface.rect.height/surface.scale))
            var light = context
            light.translateBy(x:surface.rect.minX,y:surface.rect.minY)
            NotebookAgentPearl.paint(surface,age:age,reduceMotion:reduceMotion,in:light,size:surface.rect.size)
          }
        }
      }.ignoresSafeArea())
      try await Task.sleep(for:.milliseconds(100))
      host.view.layoutIfNeeded()
      let image = UIGraphicsImageRenderer(bounds:bounds).image { _ in
        host.view.drawHierarchy(in:host.view.bounds,afterScreenUpdates:true)
      }
      let attachment = XCTAttachment(image:image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
      return image
    }
    let plain = try await render(-1,"pearl-silhouettes-before")
    let early = try await render(0.35,"pearl-silhouettes-entering")
    let middle = try await render(0.9,"pearl-silhouettes-middle")
    let late = try await render(1.45,"pearl-silhouettes-leaving")
    let expired = try await render(NotebookAppModel.agentHighlightDuration,"pearl-silhouettes-expired")
    XCTAssertEqual(plain.pngData(),expired.pngData(),"The single pass leaves no persistent decoration")
    for (index,surface) in surfaces.enumerated() {
      let rect = surface.rect
      let outside = CGPoint(x:rect.minX+8,y:rect.minY+8)
      if index != 0 {
        XCTAssertEqual(pixel(middle,at:outside),pixel(plain,at:outside),"No bounding-box fill for \(shapes[index].shape)")
      }
      XCTAssertEqual(pixel(middle,at:.init(x:rect.minX-4,y:rect.midY)),pixel(plain,at:.init(x:rect.minX-4,y:rect.midY)))
      if index < 4 {
        let inside = CGPoint(x:rect.midX,y:rect.minY+rect.height*0.72)
        let pass = [early,middle,late].map { difference($0,plain,at:inside) }.max()!
        XCTAssertGreaterThan(pass,0.05,"The ribbon crosses the interior of \(shapes[index].shape), even if its white crest matches the paper in one frame")
      }
    }
    let rectangle = surfaces[0].rect
    let left = CGPoint(x:rectangle.minX+30,y:rectangle.minY+40)
    let right = CGPoint(x:rectangle.maxX-30,y:rectangle.minY+40)
    XCTAssertGreaterThan(difference(early,plain,at:left),difference(early,plain,at:right)+0.015)
    XCTAssertGreaterThan(difference(late,plain,at:right),difference(late,plain,at:left)+0.015)
    let reduced = try await render(0.2,"pearl-reduced-motion",reduceMotion:true)
    let reducedLater = try await render(1.2,"pearl-reduced-motion-still",reduceMotion:true)
    XCTAssertEqual(reduced.pngData(),reducedLater.pngData(),"Reduce Motion has one static wash, not a moving beam")
  }

  func testAgentPearlRespectsPartialErasureAndPaperClipAtCameraScale() async throws {
    let window = UIWindow(windowScene:try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let host = UIHostingController(rootView:AnyView(EmptyView()))
    window.overrideUserInterfaceStyle = .light
    window.rootViewController = host; window.makeKeyAndVisible()
    defer { host.rootView = AnyView(EmptyView()); window.isHidden = true; window.rootViewController = nil }
    let frame = PageRect(x:0,y:0,width:160,height:100), scale = 2.0
    let erasure = InkElementErasure(target:.init(elementID:"shape",frame:frame),samples:[20.0,80.0].map {
      .init(point:.init(x:80,y:$0),timeOffset:$0,width:24,opacity:1,force:1,azimuth:0,altitude:1)
    })
    let surface = NotebookAgentPearlSurface(rect:.init(x:40,y:60,width:320,height:200),scale:scale,
      graphic:.init(shape:.ellipse),erasures:[erasure],clipRect:.init(x:40,y:60,width:280,height:200))
    host.rootView = AnyView(ZStack(alignment:.topLeading) {
      Color.white
      Canvas { context, _ in
        var local = context; local.translateBy(x:surface.rect.minX,y:surface.rect.minY)
        NotebookAgentPearl.paint(surface,age:0.9,in:local,size:surface.rect.size)
      }
    }.ignoresSafeArea())
    try await Task.sleep(for:.milliseconds(100))
    let image = UIGraphicsImageRenderer(bounds:.init(x:0,y:0,width:400,height:300)).image { _ in
      host.view.drawHierarchy(in:host.view.bounds,afterScreenUpdates:true)
    }
    let attachment = XCTAttachment(image:image); attachment.name = "pearl-erasure-and-paper-clip"; attachment.lifetime = .keepAlways; add(attachment)
    let white = pixel(image,at:.init(x:10,y:10))
    XCTAssertEqual(pixel(image,at:.init(x:200,y:160)),white,"The light cannot restore erased pixels")
    XCTAssertEqual(pixel(image,at:.init(x:335,y:160)),white,"The paper edge clips the light too")
    XCTAssertEqual(pixel(image,at:.init(x:45,y:65)),white,"The ellipse is not its bounding rectangle")
    XCTAssertNotEqual(pixel(image,at:.init(x:135,y:170)),white,"A visible part of the surface is lit at camera scale 2")
  }

  private func pixel(_ image: UIImage, at point: CGPoint) -> [UInt8] {
    let sample = image.cgImage!.cropping(to:.init(x:point.x*image.scale,y:point.y*image.scale,width:1,height:1))!
    var bytes = [UInt8](repeating:0,count:4)
    bytes.withUnsafeMutableBytes { buffer in
      let context = CGContext(data:buffer.baseAddress,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,
        space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
      context.draw(sample,in:.init(x:0,y:0,width:1,height:1))
    }
    return bytes
  }
  private func difference(_ a: UIImage, _ b: UIImage, at point: CGPoint) -> Double {
    zip(pixel(a,at:point),pixel(b,at:point)).prefix(3).map { abs(Double($0)-Double($1))/255 }.max()!
  }

  func testAgentPearlUsesTheInstalledPageAndBoardGeometry() async throws {
    for onBoard in [false,true] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent("pearl-scene-\(UUID())")
      let model = NotebookAppModel(store:.init(root:root),startsNearbySync:false)
      retainNotebookUntilTeardown(model,removing:root)
      await model.start(pageSize:NotebookAppModel.defaultPageSize)
      let workspace = try XCTUnwrap(model.workspace), pageID = try XCTUnwrap(workspace.selectedPageID)
      let target = CollaborationTarget(kind:onBoard ? .board : .page,id:onBoard ? workspace.rootBoardID : pageID)
      let origin = WorldPoint(tileX:90_000_000,tileY:-120_000_000,localX:1,localY:2)
      let viewport = SpatialPoint(x:834,y:1194)
      if onBoard { model.moveItem(workspace.selectedItemID,to:.init(x:100_000,y:100_000)) }
      let center = onBoard ? origin.offsetBy(x:417,y:597)
        : try XCTUnwrap(model.boardHierarchy?.focusedCenter(of:workspace.selectedItemID,in:workspace.rootBoardID))
      model.updatePresence(.init(boardID:workspace.rootBoardID,mode:onBoard ? .board : .page,
        camera:.init(center:center,scale:0.8),viewport:viewport,
        focusedItemID:onBoard ? nil : workspace.selectedItemID,openProgress:onBoard ? 0 : 1),settled:true)
      let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
      let window = try await mountNotebookScene(model)
      let graphic = NotebookGraphic(shape:.triangle,vertices:[.init(x:0,y:0.12),.init(x:1,y:0),.init(x:0.7,y:1)])
      var values: [String: JSONValue] = ["kind":.string("graphic"),"source":.string(""),
        "frame":try .encode(PageRect(x:260,y:420,width:220,height:180)),"graphic":try .encode(graphic)]
      if onBoard { values["worldOrigin"] = try .encode(origin) }
      _ = try model.store.applyCollaborationAction(.init(summary:"Pearl scene",
        expected:[.init(target:target,revision:model.store.targetContentRevision(target:target))],
        operations:[.init(kind:.insertElement,target:target,id:"pearl",values:values)]),actor:UUID())
      await model.reloadExternalChanges()?.value
      let deadline = ContinuousClock.now + .seconds(5)
      while (onBoard ? model.compositionTiles.published?.frame.index.element(id:"pearl",boardID:target.id) == nil
        : model.activePage.map { !model.pagePresentations.isPresented($0) } == true), ContinuousClock.now < deadline {
        try await Task.sleep(for:.milliseconds(10))
      }
      let presence = try XCTUnwrap(model.presence)
      let reference = CollaborationReference(target:target,elementID:"pearl",revision:"fixture")
      let projected = try XCTUnwrap(NotebookAttentionProjection.agentPearl(reference,model:model,presence:presence))
      let editable: EditableElementReference = onBoard ? .spatial(boardID:target.id,elementID:"pearl") : .page(pageID:pageID,elementID:"pearl")
      XCTAssertEqual(projected.rect,NotebookAttentionProjection.editingFrame(editable,model:model,presence:presence))
      XCTAssertEqual(projected.graphic,graphic)
      XCTAssertEqual(projected.layout,model.graphicLayout(editable))
      XCTAssertEqual(projected.rect.width/projected.scale,220,accuracy:0.01)
      XCTAssertEqual(projected.rect.height/projected.scale,180,accuracy:0.01)
      XCTAssertEqual(projected.clipRect != nil,!onBoard)
      let attachment = XCTAttachment(image:UIGraphicsImageRenderer(bounds:window.bounds).image { _ in
        window.drawHierarchy(in:window.bounds,afterScreenUpdates:true)
      })
      attachment.name = "pearl-installed-\(onBoard ? "board" : "page")"; attachment.lifetime = .keepAlways; add(attachment)
      await model.shutdown()
    }
  }

  func testErasedGeometryCannotSelectItsOldContourOrEmptyInterior() {
    let surface = SurfaceID.page(UUID()), frame = PageRect(x:100,y:200,width:160,height:100)
    let graphic = NotebookGraphic(shape:.rectangle,style:.init(strokeWidth:4))
    let element = AgentElement(id:"ghost",kind:.graphic,frame:frame,source:"",html:"",graphic:graphic)
    let graph = NotebookGraphicGraph([.init(id:"ghost",graphic:graphic,frame:frame,surface:surface,shown:true)])
    func cut(_ points: [SpatialPoint]) -> InkElementErasure {
      .init(target:.init(elementID:"ghost",frame:frame),samples:points.map {
        .init(point:$0,timeOffset:0,width:20,opacity:1,force:1,azimuth:0,altitude:1)
      })
    }
    let rim = cut([.init(x:100,y:200),.init(x:260,y:200),.init(x:260,y:300),.init(x:100,y:300),.init(x:100,y:200)])
    func pick(_ point: SpatialPoint, cuts: [InkElementErasure]) -> String? {
      NotebookAttentionProjection.pickElement(in:[element],graph:graph,erasures:["ghost":cuts],
        appearance: { _,graphic,layout,size,cuts in .init(graphic:graphic,layout:layout,size:size,erasures:cuts) }, scale:1,
        viewport:.init(x:834,y:1194),project:{ ($0.id,$0.frame,$0.graphic,point) })?.id
    }
    XCTAssertNil(pick(.init(x:180,y:250),cuts:[rim]))
    XCTAssertNil(pick(.init(x:100,y:250),cuts:[rim]))
    XCTAssertEqual(pick(.init(x:180,y:250),cuts:[]),"ghost","Undo restores ordinary interior picking")
    let partial = cut([.init(x:80,y:250),.init(x:130,y:250)])
    XCTAssertNil(pick(.init(x:100,y:250),cuts:[partial]))
    XCTAssertEqual(pick(.init(x:260,y:250),cuts:[partial]),"ghost")
  }

  func testHollowSelectionUsesActualPolygonAndKeepsItsChildrenReachable() throws {
    let pageID = UUID(), surface = SurfaceID.page(pageID)
    func element(_ id: String, _ shape: NotebookGraphic.Shape, _ frame: PageRect) -> AgentElement {
      .init(id:id,kind:.graphic,frame:frame,source:"",html:"",graphic:.init(shape:shape))
    }
    let outer = element("outer",.rectangle,.init(x:0,y:0,width:600,height:700))
    let triangle = element("triangle",.triangle,.init(x:100,y:100,width:240,height:240))
    let diamond = element("diamond",.diamond,.init(x:150,y:210,width:80,height:80))
    let child = AgentElement(id:"child",kind:.web,frame:.init(x:175,y:250,width:24,height:20),source:"",html:"<p>x</p>")
    func pick(_ point: SpatialPoint, _ elements: [AgentElement]) -> String? {
      let graph = NotebookGraphicGraph(elements.compactMap { e in e.graphic.map {
        .init(id:e.id,graphic:$0,frame:e.frame,surface:surface,shown:$0.showsGeometry)
      } })
      return NotebookAttentionProjection.pickElement(in:elements,graph:graph,scale:1,viewport:.init(x:834,y:1194),
        project:{ ($0.id,$0.frame,$0.graphic,point) })?.id
    }
    XCTAssertEqual(pick(.init(x:220,y:200),[triangle]),"triangle")
    XCTAssertNil(pick(.init(x:100,y:100),[triangle]),"A polygon is not its bounding rectangle")
    XCTAssertEqual(pick(.init(x:190,y:250),[diamond,triangle,outer]),"diamond","Small inner shape wins even under a later enclosing outline")
    XCTAssertEqual(pick(.init(x:185,y:260),[child,diamond,triangle,outer]),"child")
    let oversized = element("canvas",.rectangle,.init(x:-1000,y:-1000,width:3000,height:3000))
    XCTAssertNil(pick(.init(x:400,y:500),[oversized]),"An enclosing canvas cannot steal empty-paper navigation")
  }

  func testOnlyNewAgentActionsGetAnExpiringPearl() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-pearl-\(UUID())")
    let model = NotebookAppModel(store:.init(root:root),startsNearbySync:false)
    retainNotebookUntilTeardown(model,removing:root)
    await model.start(pageSize:NotebookAppModel.defaultPageSize)
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    let target = CollaborationTarget(kind:.page,id:try XCTUnwrap(model.activePage?.id))
    let store = model.store
    func action(_ id: String) throws -> CollaborationAction {
      .init(summary:id,expected:[.init(target:target,revision:try store.targetContentRevision(target:target))],
        operations:[.init(kind:.insertElement,target:target,id:id,values:["kind":.string("graphic"),"source":.string(""),
          "frame":try .encode(PageRect(x:100,y:100,width:180,height:140)),"graphic":try .encode(NotebookGraphic(shape:.triangle))])])
    }
    _ = try store.applyNativeGraphicAction(action("human"),actor:model.actorID)
    await model.reloadExternalChanges()?.value
    XCTAssertTrue(model.agentHighlightStarts.isEmpty,"A human shape is never an agent highlight")
    let agent = try store.applyCollaborationAction(action("agent"),actor:UUID())
    await model.reloadExternalChanges()?.value
    let started = try XCTUnwrap(model.agentHighlightStarts[agent.id])
    await model.reloadExternalChanges()?.value
    XCTAssertEqual(model.agentHighlightStarts[agent.id],started,"A metadata refresh must not restart the pulse")
    try await Task.sleep(for:.seconds(NotebookAppModel.agentHighlightDuration+0.2))
    XCTAssertTrue(model.agentHighlightStarts.isEmpty,"Expiry does not need a mounted or visible view")
    await model.reloadExternalChanges()?.value
    XCTAssertTrue(model.agentHighlightStarts.isEmpty)
  }
}

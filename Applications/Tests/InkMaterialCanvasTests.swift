import NotebookCore
import UIKit
import SwiftUI
import XCTest
@testable import Notebook

@MainActor final class InkMaterialCanvasTests: XCTestCase {
  func testUnpaintedMaterialMaskIsNeutralAndChangingItsRoleDoesNotBorrowWhiteInk() async {
    let canvas=InkCanvasView(frame:.zero)
    let mask=NotebookInkMaterialView.Content(freehand:nil,erasures:[],transform:nil,layout:nil)
    let ink=NotebookFreehand(layers:[.init(color:.black,vertices:[
      .init(x:0,y:0,opacity:1),.init(x:1,y:0,opacity:1),.init(x:0,y:1,opacity:1)])])
    let body=NotebookInkMaterialView.Content(freehand:ink,erasures:[],transform:nil,layout:nil)
    canvas.updateMaterial(mask)
    XCTAssertEqual(canvas.layer.opacity,1,"An unpainted erasure mask cannot hide the entire element")
    XCTAssertEqual(canvas.backgroundColor,.white)
    XCTAssertFalse(canvas.isStableFramePresented,"Neutral coverage is not the accepted cut's readiness")
    XCTAssertEqual(canvas.drawableRequestCount,0)
    canvas.updateMaterial(body)
    XCTAssertEqual(canvas.layer.opacity,0,"A reusable owner must not paint the mask's neutral white as freehand")
    XCTAssertEqual(canvas.backgroundColor,.clear)
    canvas.updateMaterial(mask)
    XCTAssertEqual(canvas.layer.opacity,1)
    XCTAssertEqual(canvas.backgroundColor,.white)
    XCTAssertEqual(canvas.drawableRequestCount,0)
    await canvas.finishSpatialHandoffFrames()
  }

  func testPartialEraseUndoRedoRetainsHandwritingBodyAndUntouchedPixels() async throws {
    let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window=UIWindow(windowScene:scene),controller=UIViewController()
    window.rootViewController=controller;controller.view.backgroundColor = .red;window.makeKeyAndVisible()
    defer { window.isHidden=true;window.rootViewController=nil }
    let frame=PageRect(x:0,y:0,width:300,height:300)
    let samples=[30.0,270].map { x in SpatialInkSample(point:.init(x:x,y:150),timeOffset:x/300,
      width:20,opacity:1,force:1,azimuth:0,altitude:.pi/2) }
    let ink=NotebookFreehand(layers:[.init(tool:.pen,color:.black,measured:.init(sourceID:UUID(),
      measurements:.init(samples),frame:frame))])
    let graphic=NotebookGraphic(shape:.freehand,freehand:ink)
    let cut=InkElementErasure(target:.init(elementID:"handwriting",frame:frame),samples:[
      .init(point:.init(x:90,y:150),timeOffset:0,width:30,opacity:1,force:1,azimuth:0,altitude:.pi/2)])
    var readiness=NotebookInkMaterialReadiness()
    let receiver=NotebookInkMaterialReceiver(id:UUID(),report:{ id,content,ready in
      _=readiness.record(id,content:content,ready:ready)
    })
    func presented(_ cuts:[InkElementErasure]) -> some View {
      NotebookGraphicView(graphic:graphic,erasures:cuts).environment(\.inkMaterialReadiness,receiver)
    }
    let hosted=UIHostingController(rootView:presented([]))
    controller.addChild(hosted);controller.view.addSubview(hosted.view);hosted.didMove(toParent:controller)
    hosted.view.frame = .init(x:40,y:40,width:300,height:300);hosted.view.backgroundColor = .clear
    controller.view.layoutIfNeeded()
    func materials(_ view:UIView)->[InkMaterialHost] {
      (view as? InkMaterialHost).map { [$0] } ?? view.subviews.flatMap(materials)
    }
    let initial=ContinuousClock.now + .seconds(5)
    while (materials(hosted.view).count != 1 || materials(hosted.view).first?.canvas.isStableFramePresented != true),
      ContinuousClock.now < initial { try await Task.sleep(for:.milliseconds(5)) }
    let body=try XCTUnwrap(materials(hosted.view).first)
    XCTAssertTrue(body.canvas.isStableFramePresented)
    let bodyID=ObjectIdentifier(body)
    for (name,cuts) in [("partial-erase",[cut]),("undo",[]),("redo",[cut])] {
      let began=ContinuousClock.now
      let required=NotebookInkMaterialView.Content.required(graphic:graphic,layout:nil,erasures:cuts,appearance:nil)
      hosted.rootView=presented(cuts)
      try await assertUX("retained-handwriting-\(name)",since:began,window:window) {
        // SwiftUI's mask is not required to be a subview of the body host.
        // The composition owner reports the exact body and mask contents.
        guard materials(hosted.view).contains(where:{ ObjectIdentifier($0) == bodyID }),
          readiness.isReady(for:required) else { return false }
        return try NotebookUXObservation.Pixels(window:window).matches([
          (hosted.view.convert(.init(x:230,y:150),to:window),.black),
          (hosted.view.convert(.init(x:90,y:150),to:window),cuts.isEmpty ? .black : .red)])
      }
      XCTAssertTrue(materials(hosted.view).contains(where:{ $0 === body }),
        "Only the mask's ownership changes; the handwriting source must not remount")
    }
  }

  func testLiveFreehandAndIncrementalEraserReachPhysicalPixelsWithoutReadback() async throws {
    let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window=UIWindow(windowScene:scene),controller=UIViewController()
    window.rootViewController=controller;controller.view.backgroundColor = .red
    let canvas=InkCanvasView(frame:.zero)
    controller.view.addSubview(canvas);window.makeKeyAndVisible()
    defer { Task { await canvas.finishSpatialHandoffFrames() };window.isHidden=true;window.rootViewController=nil }
    let frame=PageRect(x:0,y:0,width:300,height:300)
    canvas.projectPage(region:.init(x:0,y:0,width:300,height:300),sourceSize:.init(width:300,height:300),pixelDensity:2)
    func point(_ x:Double,_ y:Double) -> SpatialInkSample {
      .init(point:.init(x:x,y:y),timeOffset:0,width:20,opacity:1,force:1,azimuth:0,altitude:1)
    }
    let ink=NotebookFreehand(layers:[.init(tool:.pen,color:.black,measured:.init(sourceID:UUID(),
      measurements:.init([point(30,150),point(270,150)]),frame:frame))])
    canvas.updateMaterial(.init(freehand:ink,erasures:[],transform:nil,layout:nil))
    try await ready(canvas,after:0)
    XCTAssertFalse(canvas.hasPageRetainedTexture,
      "An element material must not allocate the page-history backing texture")
    XCTAssertLessThan(try pixel(canvas,window:window,x:150,y:150)[0],30)
    let uploaded=canvas.materialUploadedNodeCount,completed=canvas.drawableRequestCount
    canvas.projectPage(region:.init(x:10,y:10,width:280,height:280),sourceSize:.init(width:300,height:300),pixelDensity:2)
    try await ready(canvas,after:completed)
    XCTAssertEqual(canvas.materialUploadedNodeCount,uploaded,"Panning changes projection, not vector buffers")

    var contact=InkSampleRelations.Contact(header:.init(tool:.eraser,color:.black))
    contact.replaceTail(from:0,with:(0..<2400).map { i in point(100+cos(Double(i)*0.2)*4,100+sin(Double(i)*0.2)*4) })
    let target=InkElementTarget(elementID:"box",frame:frame)
    func mask() -> NotebookInkMaterialView.Content {
      .init(freehand:nil,erasures:[.init(target:target,measurements:contact.frozen().measurements)],transform:nil,layout:nil)
    }
    let before=canvas.drawableRequestCount
    canvas.updateMaterial(mask());try await ready(canvas,after:before)
    XCTAssertEqual(canvas.backgroundColor,.clear,"The first actual mask replaces neutral coverage in its presentation transaction")
    let hole=try pixel(canvas,window:window,x:100,y:100),body=try pixel(canvas,window:window,x:200,y:200)
    XCTAssertGreaterThan(hole[0],220);XCTAssertLessThan(hole[1],30,"The transparent erase reveals the red surface")
    XCTAssertGreaterThan(body[1],220,"The rest of the mask remains opaque white")
    let nodes=canvas.materialUploadedNodeCount,frames=canvas.drawableRequestCount
    contact.replaceTail(from:contact.count,with:[point(102,101)])
    canvas.updateMaterial(mask())
    XCTAssertEqual(canvas.layer.opacity,1,"Updating a shown mask retains its installed pixels")
    XCTAssertEqual(canvas.backgroundColor,.clear,"An update cannot fill the previously shown erasure holes")
    try await ready(canvas,after:frames)
    XCTAssertLessThan(canvas.materialUploadedNodeCount-nodes,256,"A new sample does not upload the erased prefix again")
    let proof=XCTAttachment(image:capture(window));proof.name="direct-metal-element-mask";proof.lifetime = .keepAlways;add(proof)
    canvas.removeFromSuperview();canvas.updateMaterial(.init(freehand:ink,erasures:[],transform:nil,layout:nil))
    XCTAssertTrue(canvas.isPaused)
  }
  func testMaterialCoalescesPendingDrawsAndPresentsOnlyTheLatestDirtySource() async throws {
    let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window=UIWindow(windowScene:scene),controller=UIViewController(),canvas=InkCanvasView(frame:.zero)
    window.rootViewController=controller;controller.view.backgroundColor = .red
    controller.view.addSubview(canvas);window.makeKeyAndVisible()
    defer { Task { await canvas.finishSpatialHandoffFrames() };window.isHidden=true;window.rootViewController=nil }
    let frame=PageRect(x:0,y:0,width:300,height:300)
    canvas.projectPage(region:.init(x:0,y:0,width:300,height:300),sourceSize:.init(width:300,height:300),pixelDensity:2)
    func source(_ x:Double) -> NotebookInkMaterialView.Content {
      .init(freehand:nil,erasures:[.init(target:.init(elementID:"mask",frame:frame),samples:[
        .init(point:.init(x:x,y:150),timeOffset:0,width:30,opacity:1,force:1,azimuth:0,altitude:1)])],
        transform:nil,layout:nil)
    }
    canvas.updateMaterial(source(70));canvas.draw()
    let first=canvas.drawableRequestCount
    XCTAssertEqual(first,1)
    // No actor suspension: the existing completion cannot drain the first
    // submission while these duplicate and changed requests are admitted.
    canvas.draw()
    canvas.updateMaterial(source(130));canvas.draw()
    canvas.updateMaterial(source(210));canvas.draw()
    XCTAssertEqual(canvas.drawableRequestCount,first,"Only one material command may be in flight")
    XCTAssertFalse(canvas.isStableFramePresented)
    let frameBefore=canvas.frame,boundsBefore=canvas.bounds,cropBefore=canvas.pageRenderRegion
    let sourceSizeBefore=canvas.pageSourceSize,pixelsBefore=canvas.drawableSize
    var retryInvalidations=0,observingRetries=false
    canvas.onRenderReadinessChange = { ready in
      // Ignore the setter's current false state. No source/crop mutation is
      // allowed below; another false event is a revoked failed attempt.
      if observingRetries,!ready { retryInvalidations += 1 }
    }
    observingRetries=true
    try await ready(canvas,after:first)
    XCTAssertTrue(canvas.isStableFramePresented)
    XCTAssertEqual(canvas.frame,frameBefore);XCTAssertEqual(canvas.bounds,boundsBefore)
    XCTAssertEqual(canvas.pageRenderRegion,cropBefore);XCTAssertEqual(canvas.pageSourceSize,sourceSizeBefore)
    XCTAssertEqual(canvas.drawableSize,pixelsBefore)
    XCTAssertEqual(canvas.drawableRequestCount,first+1+retryInvalidations,
      "One latest revision plus only failed-attempt retries, never a duplicate or the superseded middle source")
    let pixels=try NotebookUXObservation.Pixels(window:window)
    XCTAssertTrue(try pixels.matches([(canvas.convert(.init(x:70,y:150),to:window),.paper),
      (canvas.convert(.init(x:130,y:150),to:window),.paper),
      (canvas.convert(.init(x:210,y:150),to:window),.red)]))
    let readyFrames=canvas.drawableRequestCount
    canvas.draw()
    XCTAssertEqual(canvas.drawableRequestCount,readyFrames,"A ready unchanged material needs no repeated GPU pass")
    observingRetries=false;canvas.onRenderReadinessChange=nil
    let report=XCTAttachment(string:"Material submissions=\(readyFrames); failed-attempt invalidations=\(retryInvalidations); unchanged crop=\(String(describing:cropBefore)); pixels=\(pixelsBefore)")
    report.name="material-admission-revisions";report.lifetime = .keepAlways;add(report)
  }

  func testPendingMaterialRemountRevokesTheOldReceiptEvenForIdenticalContent() async throws {
    let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window=UIWindow(windowScene:scene),controller=UIViewController(),canvas=InkCanvasView(frame:.zero)
    window.rootViewController=controller;controller.view.backgroundColor = .red
    controller.view.addSubview(canvas);window.makeKeyAndVisible()
    defer { Task { await canvas.finishSpatialHandoffFrames() };window.isHidden=true;window.rootViewController=nil }
    let frame=PageRect(x:0,y:0,width:300,height:300)
    let source=NotebookInkMaterialView.Content(freehand:nil,erasures:[.init(target:.init(elementID:"mask",frame:frame),samples:[
      .init(point:.init(x:100,y:150),timeOffset:0,width:30,opacity:1,force:1,azimuth:0,altitude:1)])],
      transform:nil,layout:nil)
    canvas.projectPage(region:.init(x:0,y:0,width:300,height:300),sourceSize:.init(width:300,height:300),pixelDensity:2)
    canvas.updateMaterial(source);canvas.draw()
    let first=canvas.drawableRequestCount
    XCTAssertEqual(first,1)
    canvas.removeFromSuperview()
    XCTAssertFalse(canvas.isStableFramePresented)
    controller.view.addSubview(canvas)
    canvas.projectPage(region:.init(x:0,y:0,width:300,height:300),sourceSize:.init(width:300,height:300),pixelDensity:2)
    canvas.updateMaterial(source);canvas.draw()
    XCTAssertEqual(canvas.drawableRequestCount,first,"Remount waits for the retired command, not an extra in-flight copy")
    try await ready(canvas,after:first)
    XCTAssertEqual(canvas.drawableRequestCount,first+1,"The identical source still needs the new mounted drawable")
    let pixels=try NotebookUXObservation.Pixels(window:window)
    XCTAssertTrue(try pixels.matches([(canvas.convert(.init(x:100,y:150),to:window),.red),
      (canvas.convert(.init(x:200,y:150),to:window),.paper)]))
  }

  func testSwiftUIMaskPreservesTransformedHolesOnThePhysicalLayer() async throws {
    let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window=UIWindow(windowScene:scene),controller=UIViewController()
    window.rootViewController=controller;controller.view.backgroundColor = .red;window.makeKeyAndVisible()
    defer { window.isHidden=true;window.rootViewController=nil }
    let sample=SpatialInkSample(point:.init(x:90,y:150),timeOffset:0,width:30,opacity:1,force:1,azimuth:0,altitude:1)
    let cut=InkElementErasure(target:.init(elementID:"box",frame:.init(x:0,y:0,width:300,height:300)),measurements:.init([sample]))
    var presented=false
    let transform=NotebookGraphicTransform(a:0,b:1,c:-1,d:0,tx:1,ty:0)
    let prepared=NotebookElementAppearance(graphic:.init(shape:.rectangle,transform:transform),layout:nil,
      size:.init(width:300,height:300),erasures:[cut])
    let view=Color.black.erased(by:[cut],appearance:prepared,transform:transform)
      .environment(\.inkMaterialReadiness,.init(id:UUID(),report:{ _,_,ready in presented=ready }))
    let hosted=UIHostingController(rootView:view)
    controller.addChild(hosted);controller.view.addSubview(hosted.view);hosted.didMove(toParent:controller)
    hosted.view.frame = .init(x:40,y:40,width:300,height:300);hosted.view.backgroundColor = .clear
    controller.view.layoutIfNeeded()
    let until=ContinuousClock.now + .seconds(5)
    while !presented,ContinuousClock.now < until { try await Task.sleep(for:.milliseconds(20)) }
    XCTAssertTrue(presented,"The native mask must report its first visible frame")
    try await Task.sleep(for:.milliseconds(60))
    let hole=try pixel(hosted.view,window:window,x:150,y:90),old=try pixel(hosted.view,window:window,x:90,y:150)
    XCTAssertGreaterThan(hole[0],220);XCTAssertLessThan(hole[1],30)
    XCTAssertLessThan(old[0],30,"The saved cut follows the whole transform, not its old body position")
    let proof=XCTAttachment(image:capture(window));proof.name="swiftui-transformed-native-mask";proof.lifetime = .keepAlways;add(proof)
  }

  func testVectorRegionMaskClipsTheLiveMetalMaterial() async throws {
    let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window=UIWindow(windowScene:scene),controller=UIViewController()
    window.rootViewController=controller;controller.view.backgroundColor = .red;window.makeKeyAndVisible()
    defer { window.isHidden=true;window.rootViewController=nil }
    let frame=PageRect(x:0,y:0,width:300,height:100)
    let samples=[30.0,270].map { x in SpatialInkSample(point:.init(x:x,y:50),timeOffset:x/300,
      width:20,opacity:1,force:1,azimuth:0,altitude:1) }
    let ink=NotebookFreehand(layers:[.init(tool:.pen,color:.black,measured:.init(sourceID:UUID(),
      measurements:.init(samples),frame:frame))])
    let mask=NotebookGraphicMask().appending(.intersect,polygon:[.init(x:0,y:0),.init(x:0.5,y:0),
      .init(x:0.5,y:1),.init(x:0,y:1)])
    let graphic=NotebookGraphic(shape:.freehand,freehand:ink,mask:mask)
    var presented=false
    let hosted=UIHostingController(rootView:NotebookGraphicView(graphic:graphic)
      .environment(\.inkMaterialReadiness,.init(id:UUID(),report:{ _,_,ready in presented=ready })))
    controller.addChild(hosted);controller.view.addSubview(hosted.view);hosted.didMove(toParent:controller)
    hosted.view.frame = .init(x:40,y:40,width:300,height:100);hosted.view.backgroundColor = .clear
    controller.view.layoutIfNeeded()
    let until=ContinuousClock.now + .seconds(5)
    while !presented,ContinuousClock.now < until { try await Task.sleep(for:.milliseconds(20)) }
    XCTAssertTrue(presented);try await Task.sleep(for:.milliseconds(60))
    let inside=try pixel(hosted.view,window:window,x:80,y:50)
    let outside=try pixel(hosted.view,window:window,x:220,y:50)
    XCTAssertLessThan(inside[0],30);XCTAssertLessThan(inside[1],30)
    XCTAssertGreaterThan(outside[0],220);XCTAssertLessThan(outside[1],30)
    let proof=XCTAttachment(image:capture(window));proof.name="live-vector-region-mask";proof.lifetime = .keepAlways;add(proof)
  }

  func testColdCapturedMaskShowsOneHundredThousandMeasurementsWithoutBooleanPreparation() async throws {
    let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous=scene.windows.first(where:\.isKeyWindow),window=UIWindow(windowScene:scene),controller=UIViewController()
    window.rootViewController=controller;controller.view.backgroundColor = .red;window.makeKeyAndVisible()
    defer { window.isHidden=true;window.rootViewController=nil;previous?.makeKey() }
    let frame=PageRect(x:0,y:0,width:300,height:300)
    let measurements=InkMeasurements((0..<100_000).map { i in
      SpatialInkSample(point:.init(x:90,y:Double(i%2)*200+50),timeOffset:Double(i)/240,
        width:24,opacity:1,force:1,azimuth:0,altitude:1)
    })
    let cut=InkElementErasure(target:.init(elementID:"source",frame:frame),measurements:measurements)
    let turn=NotebookGraphicTransform(a:0,b:1,c:-1,d:0,tx:1,ty:0)
    let mask=NotebookGraphicMask().capturing([cut],transform:turn)
      .appending(.intersect,polygon:[.zero,.init(x:0.8,y:0),.init(x:0.8,y:1),.init(x:0,y:1)])
    let graphic=NotebookGraphic(shape:.rectangle,style:.init(fill:.black),mask:mask)
    let external=InkElementErasure(target:.init(elementID:"source",frame:frame),samples:[
      .init(point:.init(x:100,y:220),timeOffset:0,width:24,opacity:1,force:1,azimuth:0,altitude:1)])
    let required=NotebookInkMaterialView.Content.required(graphic:graphic,layout:nil,erasures:[external],appearance:nil)
    XCTAssertEqual(required.count,1,"Captured and current cuts share one mask renderer")
    var readiness=NotebookInkMaterialReadiness()
    let start=ContinuousClock.now
    let hosted=UIHostingController(rootView:NotebookGraphicView(graphic:graphic,erasures:[external])
      .environment(\.inkMaterialReadiness,.init(id:UUID(),report:{ id,content,ready in
        _=readiness.record(id,content:content,ready:ready)
      })))
    controller.addChild(hosted);controller.view.addSubview(hosted.view);hosted.didMove(toParent:controller)
    hosted.view.frame = .init(x:40,y:40,width:300,height:300);hosted.view.backgroundColor = .clear
    controller.view.layoutIfNeeded()
    while !readiness.isReady(for:required),start.duration(to:.now) < .seconds(2) { try await Task.sleep(for:.milliseconds(5)) }
    let readyTime=start.duration(to:.now)
    XCTAssertTrue(readiness.isReady(for:required))
    XCTAssertLessThan(readyTime,.milliseconds(500),"First local paint cannot wait for the full 100k Boolean contour")
    // Observe the mounted window too: readiness alone cannot prove coverage.
    let hole=try pixel(hosted.view,window:window,x:150,y:90)
    let currentHole=try pixel(hosted.view,window:window,x:100,y:220)
    let body=try pixel(hosted.view,window:window,x:100,y:160)
    let outside=try pixel(hosted.view,window:window,x:270,y:160)
    for value in [hole,currentHole,outside] {
      XCTAssertGreaterThan(value[0],220);XCTAssertLessThan(value[1],30,"Exact absence reveals the red surface")
    }
    XCTAssertLessThan(body[0],30);XCTAssertLessThan(body[1],30)
    let report=XCTAttachment(string:"100000 captured erase measurements: first stable mounted layer=\(readyTime); all four window probes verified after \(start.duration(to:.now)), including capture cost; not physical Pencil or FPS.")
    report.name="cold-captured-mask-100000";report.lifetime = .keepAlways;add(report)
    let proof=XCTAttachment(image:capture(window));proof.name="cold-captured-mask-shown";proof.lifetime = .keepAlways;add(proof)
  }

  func testColdMeasuredAppearanceAndPickingOnOneHundredThousandPoints() throws {
    let frame=PageRect(x:0,y:0,width:100_000,height:100)
    func point(_ x:Double,_ y:Double,_ width:Double) -> SpatialInkSample {
      .init(point:.init(x:x,y:y),timeOffset:(x+y)/240,width:width,opacity:1,force:1,azimuth:0,altitude:1)
    }
    let ink=NotebookFreehand(layers:[.init(tool:.pen,color:.black,measured:.init(sourceID:UUID(),
      measurements:.init((0..<100_000).map { point(Double($0),50,2) }),frame:frame))])
    let cut=InkElementErasure(target:.init(elementID:"ink",frame:frame),samples:[point(30_000,0,6),point(30_000,100,6)])
    let start=ContinuousClock.now
    let value=NotebookElementAppearance(graphic:.init(shape:.freehand,freehand:ink),layout:nil,
      size:.init(width:100_000,height:100),erasures:[cut])
    XCTAssertEqual(value.state,.partial)
    XCTAssertTrue(value.contains(.init(x:80_000,y:50),tolerance:2))
    XCTAssertFalse(value.contains(.init(x:30_000,y:50),tolerance:2))
    let elapsed=start.duration(to:.now)
    print("IPAD_COLD_APPEARANCE nodes=100000 elapsed=\(elapsed)")
    XCTAssertLessThan(elapsed,.milliseconds(300),"A local pick must not prepare the full retained contour")
    let fullStart=ContinuousClock.now
    let wholeCut=InkElementErasure(target:.init(elementID:"ink",frame:frame),samples:[point(0,50,8),point(100_000,50,8)])
    let erased=NotebookElementAppearance(graphic:.init(shape:.freehand,freehand:ink),layout:nil,
      size:.init(width:100_000,height:100),erasures:[wholeCut])
    XCTAssertEqual(erased.state,.erased)
    print("IPAD_COLD_FULL_ERASE nodes=100000 elapsed=\(fullStart.duration(to:.now))")
    XCTAssertLessThan(fullStart.duration(to:.now),.milliseconds(300))
  }

  private func ready(_ canvas:InkCanvasView,after frames:Int) async throws {
    let deadline=ContinuousClock.now + .seconds(5)
    while !canvas.isStableFramePresented,ContinuousClock.now < deadline { try await Task.sleep(for:.milliseconds(10)) }
    XCTAssertTrue(canvas.isStableFramePresented)
    try await Task.sleep(for:.milliseconds(60))
  }
  private func capture(_ window:UIWindow) -> UIImage {
    let format=UIGraphicsImageRendererFormat();format.scale=window.screen.scale;format.opaque=true
    return UIGraphicsImageRenderer(bounds:window.bounds,format:format).image { _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true) }
  }
  private func pixel(_ canvas:UIView,window:UIWindow,x:Double,y:Double) throws -> [UInt8] {
    let cg=try XCTUnwrap(capture(window).cgImage),scale=window.screen.scale
    var bytes=[UInt8](repeating:0,count:cg.width*cg.height*4)
    let context=try XCTUnwrap(CGContext(data:&bytes,width:cg.width,height:cg.height,bitsPerComponent:8,bytesPerRow:cg.width*4,
      space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(cg,in:.init(x:0,y:0,width:cg.width,height:cg.height))
    let p=canvas.convert(.init(x:x-(canvas is InkCanvasView ? canvas.frame.minX : 0),y:y-(canvas is InkCanvasView ? canvas.frame.minY : 0)),to:window)
    let offset=(Int(p.y*scale)*cg.width+Int(p.x*scale))*4
    return Array(bytes[offset..<offset+4])
  }
}

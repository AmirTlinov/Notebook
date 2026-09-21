import NotebookCore
import UIKit
import SwiftUI
import XCTest
@testable import Notebook

@MainActor final class InkMaterialCanvasTests: XCTestCase {
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
    let hole=try pixel(canvas,window:window,x:100,y:100),body=try pixel(canvas,window:window,x:200,y:200)
    XCTAssertGreaterThan(hole[0],220);XCTAssertLessThan(hole[1],30,"The transparent erase reveals the red surface")
    XCTAssertGreaterThan(body[1],220,"The rest of the mask remains opaque white")
    let nodes=canvas.materialUploadedNodeCount,frames=canvas.drawableRequestCount
    contact.replaceTail(from:contact.count,with:[point(102,101)])
    canvas.updateMaterial(mask());try await ready(canvas,after:frames)
    XCTAssertLessThan(canvas.materialUploadedNodeCount-nodes,256,"A new sample does not upload the erased prefix again")
    let proof=XCTAttachment(image:capture(window));proof.name="direct-metal-element-mask";proof.lifetime = .keepAlways;add(proof)
    canvas.removeFromSuperview();canvas.updateMaterial(.init(freehand:ink,erasures:[],transform:nil,layout:nil))
    XCTAssertTrue(canvas.isPaused)
  }
  func testSwiftUIMaskPreservesTransformedHolesOnThePhysicalLayer() async throws {
    let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window=UIWindow(windowScene:scene),controller=UIViewController()
    window.rootViewController=controller;controller.view.backgroundColor = .red;window.makeKeyAndVisible()
    defer { window.isHidden=true;window.rootViewController=nil }
    let sample=SpatialInkSample(point:.init(x:90,y:150),timeOffset:0,width:30,opacity:1,force:1,azimuth:0,altitude:1)
    let cut=InkElementErasure(target:.init(elementID:"box",frame:.init(x:0,y:0,width:300,height:300)),measurements:.init([sample]))
    var presented=false
    let view=Color.black.erased(by:[cut],transform:.init(a:0,b:1,c:-1,d:0,tx:1,ty:0))
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

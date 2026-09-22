import NotebookCore
import UIKit
import XCTest
@testable import Notebook

@MainActor final class InkRelativeDisplayTests: XCTestCase {
  private func sample(_ i:Int,x:Double,y:Double,origin:WorldPoint? = nil) -> SpatialInkSample {
    .init(point:.init(x:x,y:y),worldPoint:origin?.offsetBy(x:x,y:y),timeOffset:Double(i)/128,
      width:2+Double(i%7)/4,opacity:0.25+Double(i%5)/10,force:0.5,azimuth:0,altitude:1)
  }
  private func source(_ points:[SpatialInkSample],tool:SpatialInkTool = .pen) -> InkSampleRelations {
    .init(sourceID:UUID(),revision:UUID(),samples:points,
      header:.init(tool:tool,color:.init(red:0.23,green:0.68,blue:0.93)))
  }
  /// The former cold path is retained only as a test control, never a second
  /// production owner. Both paths use the accepted renderer and blending.
  private func fullGeometry(_ value:InkSampleRelations,origin:WorldPoint? = nil) -> SpatialInkGeometry.Source {
    let nodes=SpatialInkGeometry.compact(source:value,origin:origin),c=value.header.color
    return .init(nodes:nodes,chunks:SpatialInkGeometry.chunks(for:nodes,
      color:.init(Float(c.red),Float(c.green),Float(c.blue),1),eraser:value.header.tool == .eraser))
  }

  func testLocalNormalizationCostAgainstWholePreparationAndOrdinaryStroke() throws {
    func ms(_ start:ContinuousClock.Instant) -> Double {
      let t=start.duration(to:.now).components;return Double(t.seconds)*1000+Double(t.attoseconds)/1e15
    }
    for count in [64,100_000] {
      var points=(0..<count).map { sample($0,x:Double($0)/4,y:sin(Double($0)/30)*12) }
      let index=count-15
      points[index]=sample(index,x:points[index-1].point.x+0.001,y:points[index-1].point.y)
      let value=source(points),area=CGRect(x:5,y:-20,width:20,height:40)
      var local:[Double]=[],full:[Double]=[],camera:[Double]=[],controlCamera:[Double]=[]
      var localBytes=0,fullBytes=0,decoded=0
      for _ in 0..<7 {
        var start=ContinuousClock.now
        let next=SpatialInkGeometry.Source(source:value,projection:.init());localBytes=next.auxiliaryBytes
        local.append(ms(start))
        start = .now
        let before=fullGeometry(value);fullBytes=before.auxiliaryBytes;full.append(ms(start))
        start = .now
        let selected=next.query(viewport:area,affine:.init())
        decoded=selected.chunks.reduce(0) { $0+next.prepare($1).decodedPoints }
        camera.append(ms(start))
        start = .now
        for chunk in before.query(viewport:area,affine:.init()).chunks { XCTAssertFalse(before.prepare(chunk).chunk.nodes.isEmpty) }
        controlCamera.append(ms(start))
      }
      func stats(_ a:[Double]) -> [String:Double] { let s=a.sorted();return ["p50":s[s.count/2],"max":s.last!] }
      let report:[String:Any]=["events":count,"coldMS":stats(local),"wholeControlMS":stats(full),
        "cameraMS":stats(camera),"preparedCameraControlMS":stats(controlCamera),
        "auxiliaryBytes":localBytes,"wholeAuxiliaryBytes":fullBytes,"cameraDecoded":decoded]
      print("IPAD_LOCAL_NORMALIZATION "+String(decoding:try JSONSerialization.data(withJSONObject:report,options:.sortedKeys),as:UTF8.self))
      if count == 100_000 {
        XCTAssertLessThan(local.sorted()[3],full.sorted()[3]/5)
        XCTAssertLessThan(localBytes,fullBytes/5);XCTAssertLessThan(decoded,600)
        XCTAssertLessThan(camera.max()!,8,"A local visible range must fit an ordinary frame's CPU budget")
      } else {
        XCTAssertEqual(localBytes,fullBytes)
        XCTAssertLessThan(local.max()!,8,"The ordinary stroke retains its direct path")
      }
    }
  }

  func testNormalizedWorldMaterialMatchesShownColorAlphaAndCutsThroughZoomAndReopen() async throws {
    let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window=UIWindow(windowScene:scene),controller=UIViewController()
    window.rootViewController=controller;controller.view.backgroundColor = .white;window.makeKeyAndVisible()
    let host=UIView(frame:.init(x:40,y:40,width:300,height:300));host.clipsToBounds=true
    controller.view.addSubview(host)
    let canvas=InkCanvasView(frame:.zero);host.addSubview(canvas)
    defer { Task { await canvas.finishSpatialHandoffFrames() };window.isHidden=true;window.rootViewController=nil }
    let origin=WorldPoint(tileX:WorldPoint.maximumTileIndex-10,tileY:-WorldPoint.maximumTileIndex+10,localX:20,localY:40)
    var points=(0..<2048).map { i in sample(i,x:25+Double(i)/8,y:150+sin(Double(i)/50)*35,origin:origin) }
    points[2027]=sample(2027,x:points[2026].point.x+0.001,y:points[2026].point.y,origin:origin)
    let original=source(points),encoded=try original.encodedRelations()
    let reopened=try InkSampleRelations(encodedRelations:encoded)
    let cut=InkSampleRelations(sourceID:UUID(),revision:UUID(),samples:[100.0,200].map {
      .init(point:.init(x:150,y:$0),timeOffset:0,width:18,opacity:1,force:1,azimuth:0,altitude:1)
    },header:.init(tool:.eraser,color:.black))
    let frame=PageRect(x:0,y:0,width:300,height:300)
    let ink=NotebookFreehand(layers:[.init(tool:.pen,color:reopened.header.color,measured:.init(sourceID:reopened.sourceID,
      measurements:reopened.measurements,frame:frame,origin:origin)),
      .init(tool:.eraser,color:.black,measured:.init(sourceID:cut.sourceID,measurements:cut.measurements,frame:frame))])
    let reference=SpatialInkMesh(batches:[.init(tool:.pen,projection:.local,parts:[fullGeometry(original,origin:origin)]),
      .init(tool:.eraser,projection:.local,parts:[fullGeometry(cut)])])
    let referenceView=UIImageView(frame:host.bounds);referenceView.backgroundColor = .clear
    for scale:CGFloat in [1,3,1] {
      let region=scale == 1 ? CGRect(x:0,y:0,width:300,height:300) : CGRect(x:100,y:100,width:100,height:100)
      referenceView.removeFromSuperview();canvas.isHidden=false;canvas.transform = .identity
      canvas.projectPage(region:region,sourceSize:.init(width:300,height:300),pixelDensity:window.screen.scale*scale)
      canvas.transform = .init(scaleX:scale,y:scale);canvas.frame.origin = .zero
      canvas.updateMaterial(.init(freehand:ink,erasures:[],transform:nil,layout:nil))
      let until=ContinuousClock.now + .seconds(5)
      while !canvas.isStableFramePresented,ContinuousClock.now < until { try await Task.sleep(for:.milliseconds(10)) }
      XCTAssertTrue(canvas.isStableFramePresented);try await Task.sleep(for:.milliseconds(60))
      let actual=try capture(host,window:window),shown=try rgba(actual)
      // Keep the same shader viewport and sample phase as the live crop. A
      // different algebraically equivalent Float basis can move an MSAA edge.
      let affine=InkAffine(x:.init(1,0,Float(-region.minX),0),y:.init(0,1,Float(-region.minY),0))
      let expected=try XCTUnwrap(InkRasterRenderer.shared.render(mesh:reference,size:region.size,
        scale:window.screen.scale*scale,affine:affine))
      canvas.isHidden=true;referenceView.image=UIImage(cgImage:expected);host.addSubview(referenceView)
      try await Task.sleep(for:.milliseconds(60))
      let control=try rgba(capture(host,window:window))
      XCTAssertEqual(shown.count,control.count)
      let differences=zip(shown,control).map { abs(Int($0)-Int($1)) }
      let mean=Double(differences.reduce(0,+))/Double(differences.count)
      print("IPAD_SHOWN_NORMALIZATION scale=\(scale) meanChannelError=\(mean) maxChannelError=\(differences.max()!)")
      XCTAssertLessThanOrEqual(differences.max()!,2);XCTAssertLessThan(mean,0.05)
      XCTAssertGreaterThan(shown.filter { $0 < 230 }.count,1000,"An empty image must not pass equivalence")
      let center=(actual.height/2*actual.width+actual.width/2)*4
      XCTAssertTrue(shown[center..<(center+3)].allSatisfy { $0 > 250 },"The erased center stays transparent after reopening and zoom")
      let proof=XCTAttachment(image:UIImage(cgImage:actual));proof.name="normalized-world-color-cuts-\(scale)x";proof.lifetime = .keepAlways;add(proof)
    }
    XCTAssertEqual(try reopened.encodedRelations(),encoded,"Camera preparation cannot rewrite the material")
  }
  private func capture(_ view:UIView,window:UIWindow) throws -> CGImage {
    let format=UIGraphicsImageRendererFormat();format.scale=window.screen.scale;format.opaque=true
    let image=UIGraphicsImageRenderer(bounds:window.bounds,format:format).image { _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true) }
    let rect=view.convert(view.bounds,to:window).applying(.init(scaleX:format.scale,y:format.scale))
    return try XCTUnwrap(image.cgImage?.cropping(to:rect))
  }
  private func rgba(_ image:CGImage) throws -> [UInt8] {
    var bytes=[UInt8](repeating:0,count:image.width*image.height*4)
    let context=try XCTUnwrap(CGContext(data:&bytes,width:image.width,height:image.height,bitsPerComponent:8,
      bytesPerRow:image.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image,in:.init(x:0,y:0,width:image.width,height:image.height));return bytes
  }
}

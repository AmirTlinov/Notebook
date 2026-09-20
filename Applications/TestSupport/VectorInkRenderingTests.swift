import CoreGraphics
import ImageIO
import Foundation
import NotebookCore
import XCTest
@testable import Notebook

final class VectorInkRenderingTests: XCTestCase {
  private func source() -> NotebookFreehand {
    let vertices = (0..<20_000).flatMap { i -> [NotebookFreehand.Vertex] in
      let x = Double(i%200)/200, y = Double(i/200)/100
      return [.init(x:x,y:y,opacity:0.4),.init(x:x+0.004,y:y,opacity:0.7),.init(x:x,y:y+0.008,opacity:1)]
    }
    let cuts = (0..<800).map { i in
      NotebookFreehand.Eraser.Sample(point:.init(x:128+sin(Double(i)/30)*3,y:Double(i)/3),width:6)
    }
    return .init(layers:[.init(color:.init(red:0.2,green:0.4,blue:0.8),vertices:vertices),
      .init(eraser:.init(size:.init(x:256,y:256),samples:cuts))])
  }
  func testIndexedCroppedRasterMatchesWholeVectorSourceAfterShear() throws {
    let ink = source(), size = CGSize(width:256,height:256)
    let t = NotebookGraphicTransform(a:0.8,b:0.1,c:0.1,d:0.8,tx:0.05,ty:0.05)
    let region = CGRect(x:100,y:100,width:48,height:48)
    let query = ink.geometry.query(NotebookFreehandGeometry.sourceBounds(region,size:size,transform:t))
    let touched = query.indices.reduce(0) { $0+ink.geometry.prepared(at:$1).descriptor.range.count }
    XCTAssertLessThan(touched,ink.geometry.sourceNodeCount/4)
    let full = try XCTUnwrap(InkRasterRenderer.shared.freehand(ink,transform:t,size:size,region:.init(origin:.zero,size:size),scale:1,mask:false))
    let crop = try XCTUnwrap(InkRasterRenderer.shared.freehand(ink,transform:t,size:size,region:region,scale:1,mask:false))
    let a = Array(try XCTUnwrap(full.dataProvider?.data) as Data), b = Array(try XCTUnwrap(crop.dataProvider?.data) as Data)
    var worst = 0, nonempty = 0
    for y in 0..<48 { for x in 0..<48 { for c in 0..<4 {
      let av = a[((y+100)*256+x+100)*4+c], bv = b[(y*48+x)*4+c]
      worst = max(worst,abs(Int(av)-Int(bv))); if bv > 0 { nonempty += 1 }
    } } }
    XCTAssertLessThanOrEqual(worst,2)
    XCTAssertGreaterThan(nonempty,100)
    let png = NSMutableData()
    if let destination = CGImageDestinationCreateWithData(png,"public.png" as CFString,1,nil) {
      CGImageDestinationAddImage(destination,crop,nil); CGImageDestinationFinalize(destination)
      let attachment = XCTAttachment(data:png as Data,uniformTypeIdentifier:"public.png")
      attachment.name = "vector-source-crop"; attachment.lifetime = .keepAlways; add(attachment)
    }
  }
  func testMeasureWholePoseEditWithoutReadingRetainedVertices() throws {
    let ink = source(), graphic = NotebookGraphic(shape:.freehand,freehand:ink)
    let geometry = ink.geometry
    let patch = JSONValue.object(["transform":try JSONValue.encode(NotebookGraphicTransform(a:0,b:1,c:-1,d:0,tx:1,ty:0))])
    // Previous implementation, retained only as a measurement control in tests.
    func fullSourceControl() throws -> NotebookGraphic {
      guard case .object(var fields) = try JSONValue.encode(graphic) else { throw CocoaError(.coderInvalidValue) }
      fields["transform"] = patch["transform"]
      return try JSONValue.object(fields).decode(NotebookGraphic.self)
    }
    var direct: [Double] = [], control: [Double] = []
    func measure(_ run: () throws -> NotebookGraphic) throws -> (NotebookGraphic,Double) {
      let start = ContinuousClock.now, value = try run(), elapsed = start.duration(to:.now).components
      return (value,Double(elapsed.seconds)*1000+Double(elapsed.attoseconds)/1e15)
    }
    for round in 0..<10 {
      for mode in (round%2 == 0 ? [0,1] : [1,0]) {
        let (value,time) = try measure { try mode == 0 ? graphic.applying(patch) : fullSourceControl() }
        XCTAssertEqual(value.transform?.b,1)
        if mode == 0 { XCTAssertTrue(value.freehand?.geometry === geometry) }
        if round >= 3 { if mode == 0 { direct.append(time) } else { control.append(time) } }
      }
    }
    let area = CGRect(x:0.499,y:0.499,width:0.006,height:0.009), q = geometry.query(area)
    let record: [String:Any] = ["retainedSourceNodes":geometry.sourceNodeCount,
      "querySourceNodes":q.indices.reduce(0) { $0+geometry.prepared(at:$1).descriptor.range.count },"indexNodesVisited":q.visitedNodes,
      "directPoseMilliseconds":direct,"fullSourceControlMilliseconds":control,"directPoseSourceNodesRead":0]
    let attachment = XCTAttachment(data:try JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
    attachment.name = "vector-source-edit"; attachment.lifetime = .keepAlways; add(attachment)
  }
}

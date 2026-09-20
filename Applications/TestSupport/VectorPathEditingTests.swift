import CoreGraphics
import Foundation
import NotebookCore
import XCTest

final class VectorPathEditingTests: XCTestCase {
  private func contour(_ curves: Int) -> NotebookVectorPath {
    var commands: [NotebookVectorPath.Command] = [.init(kind:.move,points:[.init(x:0.9,y:0.5)])]
    for i in 1...curves {
      let angle = Double(i) * 2 * .pi / Double(curves)
      let p = SpatialPoint(x:0.5+0.4*cos(angle),y:0.5+0.4*sin(angle))
      commands.append(.init(kind:.curve,points:[p,p,p]))
    }
    commands.append(.init(kind:.close,points:[]))
    return .init(commands:commands)
  }

  func testCopiedBodyLocalReplacementAndDecodeKeepIndependentValidity() throws {
    let original = contour(8190)
    XCTAssertTrue(original.isValid)
    let graphic = NotebookGraphic(shape:.path,path:original)
    let basis = NotebookGraphicTransform(a:0,b:1,c:-1,d:0,tx:1,ty:0)
    let changed = try graphic.applying(.object(["transform":try .encode(basis)]))
    XCTAssertEqual(changed.path,original)
    let bytes = try JSONEncoder().encode(original)
    XCTAssertEqual(try JSONSerialization.jsonObject(with:bytes) as? NSDictionary,
      try JSONSerialization.jsonObject(with:JSONEncoder().encode(changed.path!)) as? NSDictionary)
    let restored = try JSONDecoder().decode(NotebookVectorPath.self,from:bytes)
    XCTAssertEqual(restored,original)
    XCTAssertTrue(restored.isValid)
    let rect = CGRect(x:13,y:19,width:210,height:135)
    XCTAssertEqual(restored.path(in:rect),original.path(in:rect))
    XCTAssertEqual(try changed.applying(.object(["transform":.null])),graphic)
    var commands = original.commands
    commands[1] = .init(kind:.curve,points:[.zero])
    let invalid = NotebookVectorPath(commands:commands)
    XCTAssertFalse(invalid.isValid); XCTAssertFalse(invalid.isValid)
    XCTAssertTrue(original.isValid)
    XCTAssertNotEqual(invalid,original)
    XCTAssertThrowsError(try graphic.applying(.object(["path":try .encode(invalid)])))
  }

  func testValidationRetainsContourAndNumericBoundaries() throws {
    let move = NotebookVectorPath.Command(kind:.move,points:[.zero])
    let close = NotebookVectorPath.Command(kind:.close,points:[])
    for commands in [[],[move],[close],[move,move,close],
      [move,.init(kind:.line,points:[]),close],
      [move,.init(kind:.quad,points:[.zero]),close],
      [move,.init(kind:.line,points:[.init(x:1_000_001,y:0)]),close]] {
      let value = NotebookVectorPath(commands:commands)
      XCTAssertFalse(value.isValid); XCTAssertFalse(value.isValid)
    }
    XCTAssertFalse(contour(8191).isValid)
    let limits = NotebookVectorPath(commands:[move,.init(kind:.line,points:[.init(x:-1_000_000,y:1_000_000)]),close])
    XCTAssertTrue(limits.isValid); XCTAssertTrue(limits.isValid)
    // The public point initializer forbids nonfinite values. Exercise the
    // validating boundary with explicitly permissive decoding instead.
    let decoder = JSONDecoder()
    decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity:"Inf",negativeInfinity:"-Inf",nan:"NaN")
    for numeric in ["Inf","-Inf","NaN"] {
      let point = try decoder.decode(SpatialPoint.self,from:Data("{\"x\":\"\(numeric)\",\"y\":0}".utf8))
      let invalid = NotebookVectorPath(commands:[move,.init(kind:.line,points:[point]),close])
      XCTAssertFalse(invalid.isValid); XCTAssertFalse(invalid.isValid)
    }
  }

  func testMeasureColdAdmissionAndWarmPoseWithoutChangingTheContour() throws {
    let patch = JSONValue.object(["transform":try .encode(NotebookGraphicTransform(a:0,b:1,c:-1,d:0,tx:1,ty:0))])
    var rows: [[String:Any]] = []
    for count in [4,512,8190] {
      let source = contour(count), graphic = NotebookGraphic(shape:.path,path:source)
      XCTAssertTrue(source.isValid)
      var cold: [Double] = [], warm: [Double] = []
      for trial in 0..<105 {
        let start = ContinuousClock.now
        let admitted = NotebookVectorPath(commands:source.commands)
        let valid = admitted.isValid
        let elapsed = start.duration(to:.now).components
        XCTAssertTrue(valid)
        let editing = ContinuousClock.now
        var same = true
        for _ in 0..<20 {
          let result = try graphic.applying(patch)
          same = same && result.path == source && result.transform?.b == 1
        }
        let edited = editing.duration(to:.now).components
        XCTAssertTrue(same)
        if trial >= 5 {
          cold.append(Double(elapsed.seconds)*1000+Double(elapsed.attoseconds)/1e15)
          warm.append((Double(edited.seconds)*1000+Double(edited.attoseconds)/1e15)/20)
        }
      }
      rows.append(["commands":source.commands.count,"coldValidationMilliseconds":cold,
        "warmPoseAndEqualityMilliseconds":warm,"encodedSourceBytes":try JSONEncoder().encode(source).count])
    }
    let attachment = XCTAttachment(data:try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
    attachment.name = "vector-path-pose"; attachment.lifetime = .keepAlways; add(attachment)
  }
}

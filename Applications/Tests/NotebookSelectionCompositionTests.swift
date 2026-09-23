import UIKit
import XCTest
@testable import Notebook

/// A single window image must contain ALL expected planes at the SAME pose.
/// Neither a model pose, a UIKit callback, nor an unrelated Metal receipt is an
/// acknowledgement. This is a conservative window-observation upper bound,
/// including readback/oracle cost; it is not compositor or input-to-photon timing.
@MainActor
enum NotebookSelectionComposition {
  struct Probe {
    let name: String
    let points: [CGPoint]
    let color: NotebookUXObservation.Color
    var minimum: Int? = nil
    var maximum: Int? = nil
  }

  struct Frame {
    let image: UIImage
    private let width: Int
    private let height: Int
    private let rgba: [UInt8]

    init(_ image: UIImage) throws {
      self.image = image
      let cg = try XCTUnwrap(image.cgImage)
      let width = cg.width, height = cg.height
      self.width = width; self.height = height
      var bytes = [UInt8](repeating: 0, count: width * height * 4)
      try bytes.withUnsafeMutableBytes { buffer in
        let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height,
          bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
      }
      rgba = bytes
    }

    func failures(_ probes: [Probe]) -> [String] {
      guard !probes.isEmpty else { return ["missing composition"] }
      return probes.compactMap { probe in
        guard !probe.points.isEmpty else { return probe.name + ": missing probes" }
        var count = 0
        for point in probe.points {
          guard point.x.isFinite, point.y.isFinite,
            point.x >= 0, point.y >= 0, point.x.rounded() < CGFloat(width),
            point.y.rounded() < CGFloat(height) else { return probe.name + ": off-screen" }
          let offset = (Int(point.y.rounded()) * width + Int(point.x.rounded())) * 4
          if probe.color.matches(Array(rgba[offset..<(offset + 4)])) { count += 1 }
        }
        let lower = probe.minimum ?? probe.points.count, upper = probe.maximum ?? probe.points.count
        guard lower >= 0, upper <= probe.points.count, lower <= upper,
          (lower...upper).contains(count) else { return "\(probe.name): \(count)/\(probe.points.count)" }
        return nil
      }
    }
  }

  struct Sample {
    let elapsedMS: Double
    let captureMS: Double
    let failures: [String]
    var incoherentFrames = 0
    var correct: Bool { failures.isEmpty }
    var passed: Bool {
      correct && incoherentFrames == 0 && elapsedMS.isFinite && elapsedMS >= 0 && elapsedMS <= 100
        && captureMS.isFinite && captureMS >= 0 && captureMS <= elapsedMS
    }
    // Diagnostic upper bound, NOT the gate or an OS presentation timestamp.
    // A snapshot taking 24 ms cannot certify 20 ms display latency. Keep that
    // evidence gap explicit instead of subtracting capture cost or blaming UI.
    var observedWithinTwentyMS: Bool { passed && elapsedMS <= 20 }
  }

  static func isIncoherentMotionFrame(_ probes: [Probe], failures: [String]) -> Bool {
    let failed = Set(failures.map { String($0.prefix(while: { $0 != ":" })) })
    let names = Set(probes.map(\.name))
    let controls = names.filter { $0.hasPrefix("handle-") && $0.hasSuffix("-present") }
    let body = names.intersection(["moved-material", "blue-material"])
    let hasNewControls = !controls.isEmpty && controls.isDisjoint(with: failed)
    let hasNewBody = !body.isEmpty && body.isDisjoint(with: failed)
    let unchanged = names.filter { $0.hasPrefix("untouched-") || $0.hasPrefix("outside-")
      || $0 == "original-eraser-hole" || $0 == "unchanged-eraser-hole" }
    // A wholly old pose may precede the new frame. Once any changing plane is
    // new, the remaining planes cannot lag or restore erased material. Never
    // forgive a mixed frame just because a later snapshot becomes correct.
    return ((hasNewControls || hasNewBody) && !failures.isEmpty) || !unchanged.isDisjoint(with: failed)
  }

  /// Points are authored before input, in frozen window coordinates. Do not
  /// derive expected positions from the model or controls being tested.
  static func controls(_ rect: CGRect, transform: CGAffineTransform, visible: Bool) -> [Probe] {
    [CGPoint(x: rect.minX, y: rect.minY), .init(x: rect.maxX, y: rect.minY),
     .init(x: rect.maxX, y: rect.maxY), .init(x: rect.minX, y: rect.maxY)].enumerated().map { index, point in
      let p = point.applying(transform)
      let points = (-2...2).flatMap { y in (-2...2).map { x in CGPoint(x: p.x + CGFloat(x), y: p.y + CGFloat(y)) } }
      return .init(name: "handle-\(index)-\(visible ? "present" : "absent")", points: points,
        color: .blue, minimum: visible ? 9 : 0, maximum: visible ? nil : 0)
    }
  }

  static func outline(_ rect: CGRect, transform: CGAffineTransform) -> [Probe] {
    // Sample a strip, not one pixel on a dashed/antialiased line. Every side
    // must exist; a single surviving handle cannot masquerade as a contour.
    (0..<4).map { edge in
      let points = (10...30).flatMap { step -> [CGPoint] in
        let local: CGPoint = switch edge {
        case 0: .init(x: rect.minX + CGFloat(step), y: rect.minY)
        case 1: .init(x: rect.maxX, y: rect.minY + CGFloat(step))
        case 2: .init(x: rect.maxX - CGFloat(step), y: rect.maxY)
        default: .init(x: rect.minX, y: rect.maxY - CGFloat(step))
        }
        let p = local.applying(transform)
        return (-2...2).map { offset in
          edge % 2 == 0 ? CGPoint(x: p.x, y: p.y + CGFloat(offset)) : CGPoint(x: p.x + CGFloat(offset), y: p.y)
        }
      }
      return .init(name: "outline-side-\(edge)", points: points, color: .blue, minimum: 8)
    }
  }
}

extension NotebookInteractionUXTests {
  func testLassoRequiresOneCorrectCompositionDuringOutlineCutMoveLiftAndDeselect() async throws {
    let scene = try await fixture(erasedShape: true, tool: .lasso)
    scene.model.drawingToolSettings.lassoMode = .region
    let cut = CGRect(x: 340, y: 280, width: 100, height: 120)
    try await scene.readyPencil(self)
    var results: [NotebookSelectionComposition.Sample] = []
    let outlineStart = CACurrentMediaTime()
    scene.beginPencil(cut.origin)
    scene.movePencil(.init(x: cut.maxX, y: cut.minY))
    scene.movePencil(.init(x: cut.maxX, y: cut.maxY))
    scene.movePencil(.init(x: cut.minX, y: cut.maxY))
    scene.movePencil(cut.origin)
    results.append(try await composition("lasso-outline", scene, since: outlineStart,
      probes: cutComposition(scene, cut: cut, pose: nil, history: [])
        + NotebookSelectionComposition.outline(cut, transform: scene.pageToWindow)))

    // No selection/materialization/save wait between closing and first drag.
    // The first composition deadline includes the cold cut itself.
    let cold = CACurrentMediaTime()
    scene.endPencil()
    _ = try XCTUnwrap(scene.model.selectionSession.region)
    scene.beginFinger(.init(x: 365, y: 330))
    var history: [CGRect] = []
    var final = cut
    for index in 0..<10 {
      let dx = index % 2 == 0 ? 0.0 : 60.0, dy = 160.0 + Double(index) * 5
      let start = index == 0 ? cold : CACurrentMediaTime()
      final = cut.offsetBy(dx: dx, dy: dy)
      scene.moveFinger(.init(x: 365 + dx, y: 330 + dy))
      results.append(try await composition("lasso-move-\(index)", scene, since: start, moving: true,
        probes: cutComposition(scene, cut: cut, pose: final, history: history)
          + NotebookSelectionComposition.controls(final, transform: scene.pageToWindow, visible: true)
          + retiredControls([cut] + history, except: final, scene)))
      history.append(final)
    }
    var start = CACurrentMediaTime(); scene.endFinger()
    let material = cutComposition(scene, cut: cut, pose: final, history: history)
    results.append(try await composition("lasso-lift", scene, since: start, immediate: true,
      probes: material + NotebookSelectionComposition.controls(final, transform: scene.pageToWindow, visible: true)))
    try await scene.readyFinger(self)
    start = CACurrentMediaTime()
    scene.beginFinger(.init(x: 700, y: 850)); scene.endFinger()
    results.append(try await composition("lasso-tap-away", scene, since: start,
      probes: material + NotebookSelectionComposition.controls(final, transform: scene.pageToWindow, visible: false)))
    XCTAssertNil(scene.model.selectionSession.target, "No confirmation or retained selection after tapping away")
    XCTAssertEqual(results.count, 13)
    XCTAssertTrue(results.allSatisfy(\.passed), "No mixed composition, and correct within the 100 ms visual ceiling; see stage attachments. This does not certify 20 ms display latency")
  }

  func testWholeSelectionRequiresMaterialControlsAndUntouchedNeighborsInTheSameFrame() async throws {
    let scene = try await fixture(erasedShape: true, tool: .lasso)
    scene.model.drawingToolSettings.lassoMode = .elements
    try await scene.readyFinger(self)
    let original = CGRect(x: 540, y: 540, width: 100, height: 100)
    var results: [NotebookSelectionComposition.Sample] = []
    var start = CACurrentMediaTime()
    scene.beginFinger(.init(x: 590, y: 590)); scene.endFinger()
    results.append(try await composition("whole-select", scene, since: start,
      probes: wholeComposition(scene, pose: original, history: [])
        + NotebookSelectionComposition.controls(original, transform: scene.pageToWindow, visible: true)))
    try await scene.readyFinger(self)
    scene.beginFinger(.init(x: 590, y: 590))
    var history = [original], final = original
    for index in 0..<10 {
      let dy = 140.0 + Double(index) * 10
      start = CACurrentMediaTime(); final = original.offsetBy(dx: 0, dy: dy)
      scene.moveFinger(.init(x: 590, y: 590 + dy))
      results.append(try await composition("whole-move-\(index)", scene, since: start, moving: true,
        probes: wholeComposition(scene, pose: final, history: history)
          + NotebookSelectionComposition.controls(final, transform: scene.pageToWindow, visible: true)
          + retiredControls(history, except: final, scene)))
      history.append(final)
    }
    start = CACurrentMediaTime(); scene.endFinger()
    results.append(try await composition("whole-lift", scene, since: start, immediate: true,
      probes: wholeComposition(scene, pose: final, history: history)
        + NotebookSelectionComposition.controls(final, transform: scene.pageToWindow, visible: true)))
    try await scene.readyFinger(self)
    start = CACurrentMediaTime(); scene.beginFinger(.init(x: 700, y: 950)); scene.endFinger()
    results.append(try await composition("whole-tap-away", scene, since: start,
      probes: wholeComposition(scene, pose: final, history: history)
        + NotebookSelectionComposition.controls(final, transform: scene.pageToWindow, visible: false)))
    XCTAssertEqual(results.count, 13)
    XCTAssertTrue(results.allSatisfy(\.passed), "A fast frame/pose without the whole composition is not a passing selection")
  }

  private func composition(_ name: String, _ scene: Scene, since start: TimeInterval,
    immediate: Bool = false, moving: Bool = false,
    probes: [NotebookSelectionComposition.Probe]) async throws -> NotebookSelectionComposition.Sample {
    // This sparse correctness observation is separate from fixed-120-Hz input
    // replay: readback must not slow that replay into a false performance pass.
    // Give UIKit one opportunity, without forcing layout, CA flush or rendering.
    if !immediate { try await Task.sleep(for: .milliseconds(8)) }
    var rows = ["elapsed_ms,capture_and_decode_ms,incoherent,failed_components"]
    var sample: NotebookSelectionComposition.Sample
    var incomplete: [(failures: [String], image: UIImage)] = []
    var incoherentFrames = 0
    var last: UIImage?
    repeat {
      let capture = CACurrentMediaTime()
      let frame = try NotebookSelectionComposition.Frame(NotebookUXObservation.Pixels(window: scene.window).image)
      let captured = CACurrentMediaTime()
      let failures = frame.failures(probes)
      let incoherent = moving && NotebookSelectionComposition.isIncoherentMotionFrame(probes, failures: failures)
      if incoherent { incoherentFrames += 1 }
      sample = .init(elapsedMS: (CACurrentMediaTime() - start) * 1_000,
        captureMS: (captured - capture) * 1_000, failures: failures, incoherentFrames: incoherentFrames)
      rows.append("\(sample.elapsedMS),\(sample.captureMS),\(incoherent),\(failures.joined(separator: ";"))")
      last = frame.image
      if !sample.correct, incomplete.count < 3, !incomplete.contains(where: { $0.failures == failures }) {
        incomplete.append((failures, frame.image))
      }
      // A later correct frame cannot forgive a mixed composition or restart
      // its clock. Lift's first frame has no eventual-correctness grace period.
      if sample.correct || immediate || sample.elapsedMS >= 100 { break }
      try await Task.sleep(for: .milliseconds(16))
    } while true
    let text = "\(name): whole-window correct=\(sample.correct), mixed-frames=\(incoherentFrames), observed=\(sample.elapsedMS) ms, capture+decode=\(sample.captureMS) ms, correctness-ceiling=100 ms, observed-within-20ms=\(sample.observedWithinTwentyMS). Not an OS presentation/photon receipt.\n" + rows.joined(separator: "\n")
    print(text)
    let detail = XCTAttachment(string: text); detail.name = name; detail.lifetime = .keepAlways; add(detail)
    let images: [(String, UIImage?)] = incomplete.enumerated().map { ("incomplete-\($0.offset)", $0.element.image) } + [("observed", last)]
    for (suffix, image) in images {
      if let image {
        let shot = XCTAttachment(image: image); shot.name = name + "-" + suffix; shot.lifetime = .keepAlways; add(shot)
      }
    }
    return sample
  }

  private func probe(_ name: String, _ points: [CGPoint], _ color: NotebookUXObservation.Color,
    _ scene: Scene) -> NotebookSelectionComposition.Probe {
    .init(name: name, points: points.map { $0.applying(scene.pageToWindow) }, color: color)
  }
  private func grid(_ rect: CGRect) -> [CGPoint] {
    stride(from: rect.minY + 10, to: rect.maxY, by: 20).flatMap { y in
      stride(from: rect.minX + 10, to: rect.maxX, by: 20).map { x in CGPoint(x: x, y: y) }
    }
  }
  private func unchangedInk(_ scene: Scene) -> NotebookSelectionComposition.Probe {
    probe("untouched-ink", stride(from: 200.0, through: 460, by: 20).map { .init(x: $0, y: 650) }, .black, scene)
  }
  private func retiredControls(_ history: [CGRect], except current: CGRect, _ scene: Scene) -> [NotebookSelectionComposition.Probe] {
    let occupied = current.applying(scene.pageToWindow).insetBy(dx: -8, dy: -8)
    return history.enumerated().flatMap { index, rect in
      NotebookSelectionComposition.controls(rect, transform: scene.pageToWindow, visible: false)
        .filter { $0.points.allSatisfy { !occupied.contains($0) } }
        .map { .init(name: "retired-\(index)-" + $0.name, points: $0.points, color: .blue, minimum: 0, maximum: 0) }
    }
  }
  private func cutComposition(_ scene: Scene, cut: CGRect, pose: CGRect?, history: [CGRect]) -> [NotebookSelectionComposition.Probe] {
    let source = grid(.init(x: 160, y: 260, width: 320, height: 180))
    var groups = [unchangedInk(scene),
      probe("untouched-blue", grid(.init(x: 560, y: 560, width: 60, height: 60)), .blue, scene),
      probe("outside-material", source.filter { !cut.contains($0) }, .red, scene),
      probe("source-inside-cut", grid(cut), pose == nil ? .red : .paper, scene),
      probe("original-eraser-hole", [300.0, 320, 340, 360, 380].map { .init(x: 400, y: $0) }, .paper, scene)]
    if let pose {
      groups.append(probe("moved-material", grid(pose), .red, scene))
      groups.append(probe("moved-eraser-hole", [300.0, 320, 340, 360, 380].map {
        .init(x: 400 + pose.minX - cut.minX, y: $0 + pose.minY - cut.minY)
      }, .paper, scene))
      let ghosts = history.flatMap(grid).filter { !pose.insetBy(dx: -8, dy: -8).contains($0) }
      if !ghosts.isEmpty { groups.append(probe("no-old-fragment", ghosts, .paper, scene)) }
    }
    return groups
  }
  private func wholeComposition(_ scene: Scene, pose: CGRect, history: [CGRect]) -> [NotebookSelectionComposition.Probe] {
    func body(_ rect: CGRect) -> [CGPoint] {
      // Interior-only probes alias nearby poses of a solid object. The four
      // rim witnesses distinguish a real 10-point move from the old image.
      grid(rect.insetBy(dx: 20, dy: 20)) + [
        .init(x: rect.midX, y: rect.minY + 5), .init(x: rect.midX, y: rect.maxY - 5),
        .init(x: rect.minX + 5, y: rect.midY), .init(x: rect.maxX - 5, y: rect.midY)]
    }
    let ghostPoints = history.flatMap(body)
      .filter { !pose.insetBy(dx: -4, dy: -4).contains($0) }
    var groups = [unchangedInk(scene),
      probe("untouched-red", grid(.init(x: 160, y: 260, width: 220, height: 180)), .red, scene),
      probe("unchanged-eraser-hole", [300.0, 330, 360].map { .init(x: 400, y: $0) }, .paper, scene),
      probe("blue-material", body(pose), .blue, scene),
      probe("ellipse-not-a-bounding-box", [CGPoint(x: pose.minX + 8, y: pose.minY + 8),
        .init(x: pose.maxX - 8, y: pose.maxY - 8)], .paper, scene)]
    if !ghostPoints.isEmpty { groups.append(probe("no-old-object", ghostPoints, .paper, scene)) }
    return groups
  }
}

@MainActor
final class NotebookSelectionCompositionTests: XCTestCase {
  func testDifferentFramesCannotSupplyDifferentPartsOfOneComposition() throws {
    let format = UIGraphicsImageRendererFormat(); format.scale = 1
    format.preferredRange = .standard
    func frame(_ colors: [UIColor]) throws -> NotebookSelectionComposition.Frame {
      try .init(UIGraphicsImageRenderer(size: .init(width: 40, height: 10), format: format).image { context in
        for (index, color) in colors.enumerated() {
          color.setFill(); context.fill(.init(x: index * 10, y: 0, width: 10, height: 10))
        }
      })
    }
    let expected: [NotebookSelectionComposition.Probe] = [
      .init(name: "source-hole", points: [.init(x: 5, y: 5)], color: .paper),
      .init(name: "moved-material", points: [.init(x: 15, y: 5)], color: .red),
      .init(name: "selection-controls", points: [.init(x: 25, y: 5)], color: .blue),
      .init(name: "untouched-ink", points: [.init(x: 35, y: 5)], color: .black)]
    let correct: [UIColor] = [.white, .red, .blue, .black]
    XCTAssertTrue(try frame(correct).failures(expected).isEmpty)
    for missing in correct.indices {
      var wrong = correct; wrong[missing] = missing == 0 ? .red : .white
      XCTAssertEqual(try frame(wrong).failures(expected).count, 1,
        "Fast material, hole or controls from another frame cannot fill the missing part")
    }
    XCTAssertFalse(try frame(correct).failures([]).isEmpty)
    XCTAssertFalse(try frame(correct).failures([.init(name: "empty", points: [], color: .red)]).isEmpty)
    XCTAssertFalse(try frame(correct).failures([.init(name: "offscreen", points: [.init(x: 40, y: 5)], color: .red)]).isEmpty)
  }

  func testReadbackAndLaterCorrectFramesCannotForgeLatencyOrHideMixedFrames() {
    typealias Sample = NotebookSelectionComposition.Sample
    XCTAssertTrue(Sample(elapsedMS: 19, captureMS: 4, failures: []).passed)
    let readback = Sample(elapsedMS: 34, captureMS: 24, failures: [])
    XCTAssertTrue(readback.passed)
    XCTAssertFalse(readback.observedWithinTwentyMS, "Correct pixels do not certify 20 ms display latency")
    XCTAssertFalse(Sample(elapsedMS: 101, captureMS: 24, failures: []).passed)
    XCTAssertFalse(Sample(elapsedMS: 19, captureMS: 4, failures: [], incoherentFrames: 1).passed,
      "An eventual good frame cannot forgive a briefly uncut or detached fragment")
    XCTAssertFalse(Sample(elapsedMS: 2, captureMS: 1, failures: ["stale-source"]).passed)
    XCTAssertFalse(Sample(elapsedMS: .nan, captureMS: 1, failures: []).passed)
    XCTAssertFalse(Sample(elapsedMS: -1, captureMS: 1, failures: []).passed)
    XCTAssertFalse(Sample(elapsedMS: 5, captureMS: 6, failures: []).passed)
  }

  func testOldWholeFrameIsDifferentFromFastHandlesWithOldOrUnmaskedMaterial() {
    let names = ["moved-material", "moved-eraser-hole", "source-inside-cut", "untouched-ink"]
      + (0..<4).map { "handle-\($0)-present" }
    let probes = names.map { NotebookSelectionComposition.Probe(name: $0, points: [.zero], color: .blue) }
    XCTAssertFalse(NotebookSelectionComposition.isIncoherentMotionFrame(probes, failures: []))
    XCTAssertFalse(NotebookSelectionComposition.isIncoherentMotionFrame(probes,
      failures: ["moved-material", "source-inside-cut"] + (0..<4).map { "handle-\($0)-present" }))
    for incomplete in [["moved-material"], ["moved-eraser-hole"], ["source-inside-cut"],
      ["handle-0-present"], ["untouched-ink"]] {
      XCTAssertTrue(NotebookSelectionComposition.isIncoherentMotionFrame(probes, failures: incomplete))
    }
  }
}

import UIKit
import XCTest

/// Regression ceilings, not a claim of 100 ms Pencil quality. This observes the
/// mounted window (including capture cost), NOT the physical input-to-photon path.
/// Keep the clock outside the action: blocking input handlers count as latency.
@MainActor
enum NotebookUXObservation {
  static let correctnessTimeout: Duration = .milliseconds(100)
  static let selection: Duration = .milliseconds(250)
  static let opening: Duration = .seconds(1)
  // Product ceilings, not XCTest/AX transport timeouts. Both cold milestones
  // share the clock started BEFORE mounting/loading; refinement never resets it.
  static let firstUsefulFrame: Duration = .milliseconds(150)
  static let coldOpening: Duration = .milliseconds(1_000)
  static let zoomRefinement: Duration = .milliseconds(250)
  static let pageFirstResponse: Duration = .seconds(1.0 / 60)
  static let pageLanding: Duration = .milliseconds(450)
  static let cameraSampleMS = 1_000.0 / 60 // Queue + handler, NOT handler execution or FPS.
  static let cameraHandlerMS = 5.0

  static func acceptsCameraSample(due: TimeInterval, entered: TimeInterval?, handled: TimeInterval) -> Bool {
    guard let entered, [due, entered, handled].allSatisfy({ $0.isFinite && $0 > 0 }),
      entered >= due, handled >= entered else { return false }
    return handled <= due + cameraSampleMS / 1_000 && handled <= entered + cameraHandlerMS / 1_000
  }

  /// Zero holes is an invariant, not a grace period after material enters view.
  /// A commit observation proves installed native coverage, not physical FPS;
  /// window-pixel observations independently check the authored appearance.
  struct Coverage {
    private(set) var checked = 0
    private(set) var missing = 0
    mutating func record(_ covered: Bool?) {
      guard let covered else { return } // Nothing expected in this viewport.
      checked += 1
      if !covered { missing += 1 }
    }
    var passed: Bool { checked > 0 && missing == 0 }
  }

  struct Result {
    let matched: Bool
    let elapsed: Duration
    let budget: Duration
    var passed: Bool { matched && elapsed <= budget }
    var milliseconds: Double {
      Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
    }
  }

  static func observe(since start: ContinuousClock.Instant, budget: Duration,
    probe: () throws -> Bool) async throws -> Result {
    while true {
      let matched: Bool
      do { matched = try probe() }
      catch CaptureError.unavailable { matched = false }
      // Check AFTER the probe too. A synchronous 6-second render returning true
      // must not pass merely because the loop began before the deadline.
      let elapsed = start.duration(to: .now)
      if matched || elapsed >= budget { return .init(matched: matched, elapsed: elapsed, budget: budget) }
      // A window snapshot consumes main-thread time itself. Return a full
      // display opportunity before taking another one; 2 ms polling can starve
      // SwiftUI/CA and repeatedly observe the frame the probe kept stale.
      // The original deadline includes every wait and capture, unchanged.
      try await Task.sleep(for: .milliseconds(16))
    }
  }

  enum Color {
    case paper, black, red, blue
    func matches(_ rgb: [UInt8]) -> Bool {
      switch self {
      case .paper: rgb.prefix(3).allSatisfy { $0 > 220 }
      case .black: rgb.prefix(3).allSatisfy { $0 < 80 }
      case .red: rgb[0] > 180 && rgb[1] < 110 && rgb[2] < 110
      case .blue: rgb[0] < 100 && rgb[1] < 180 && rgb[2] > 180
      }
    }
  }

  enum CaptureError: Error { case unavailable }

  @MainActor struct Pixels {
    let image: UIImage
    init(window: UIWindow) throws {
      let format = UIGraphicsImageRendererFormat(); format.scale = 1
      var captured = false
      image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
        // Observe the current frame; do not force a synchronous render/Metal
        // readback and mislabel snapshot-induced waiting as input latency.
        captured = window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
      }
      // A not-yet-committed root is expected during a cold-open observation.
      // It counts as missing pixels until the SAME deadline, never as success.
      // A direct/final capture still throws rather than returning blank proof.
      guard captured else { throw CaptureError.unavailable }
      _ = try XCTUnwrap(image.cgImage)
    }

    func matches(_ probes: [(CGPoint, Color)]) throws -> Bool {
      guard !probes.isEmpty else { return false }
      return try probes.allSatisfy { point, color in
        let crop = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(x: point.x.rounded(),
          y: point.y.rounded(), width: 1, height: 1)), "Probe must be on the visible window")
        var rgba = [UInt8](repeating: 0, count: 4)
        try rgba.withUnsafeMutableBytes { bytes in
          let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
          context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return color.matches(rgba)
      }
    }
  }
}

extension XCTestCase {
  @MainActor @discardableResult
  func assertUX(_ name: String, since start: ContinuousClock.Instant,
    budget: Duration = NotebookUXObservation.correctnessTimeout, window: UIWindow? = nil,
    file: StaticString = #filePath, line: UInt = #line,
    probe: () throws -> Bool) async throws -> NotebookUXObservation.Result {
    let result = try await NotebookUXObservation.observe(since: start, budget: budget, probe: probe)
    let text = "UX \(name): correct=\(result.matched), observed=\(result.milliseconds) ms, ceiling=\(budget); window observation, not photon timing"
    print(text)
    let evidence = XCTAttachment(string: text); evidence.name = name; evidence.lifetime = .keepAlways; add(evidence)
    if !result.passed, let window {
      let shot = XCTAttachment(image: try NotebookUXObservation.Pixels(window: window).image)
      shot.name = name + "-failure"; shot.lifetime = .keepAlways; add(shot)
    }
    XCTAssertTrue(result.passed, text, file: file, line: line)
    return result
  }
}

@MainActor
final class NotebookUXObservationTests: XCTestCase {
  func testFastWrongAndMissingOutputCannotPass() async throws {
    let result = try await NotebookUXObservation.observe(since: .now, budget: .milliseconds(5)) { false }
    XCTAssertFalse(result.passed); XCTAssertFalse(result.matched)
    XCTAssertFalse(NotebookUXObservation.Color.red.matches([255, 255, 255, 255]))
    XCTAssertFalse(NotebookUXObservation.Color.paper.matches([240, 40, 20, 255]))
  }

  func testCorrectButLateSynchronousOutputCannotPass() async throws {
    let start = ContinuousClock.now
    let result = try await NotebookUXObservation.observe(since: start, budget: .milliseconds(5)) {
      // Negative control: even an input/render handler blocking the main actor
      // and eventually producing correct pixels has to turn this gate red.
      let until = ContinuousClock.now + .milliseconds(10)
      while ContinuousClock.now < until {}
      return true
    }
    XCTAssertTrue(result.matched); XCTAssertFalse(result.passed)
  }

  func testTimeBeforeTheFirstProbeIsNotDiscarded() async throws {
    let result = try await NotebookUXObservation.observe(since: .now - .seconds(1),
      budget: .milliseconds(100)) { true }
    XCTAssertFalse(result.passed)
  }

  func testUnavailableCaptureCannotPassButAnInBudgetCommittedFrameCan() async throws {
    let missing = try await NotebookUXObservation.observe(since: .now, budget: .milliseconds(5)) {
      throw NotebookUXObservation.CaptureError.unavailable
    }
    XCTAssertFalse(missing.matched); XCTAssertFalse(missing.passed)
    var attempts = 0
    let committed = try await NotebookUXObservation.observe(since: .now, budget: .milliseconds(100)) {
      attempts += 1
      if attempts == 1 { throw NotebookUXObservation.CaptureError.unavailable }
      return true
    }
    XCTAssertEqual(attempts, 2); XCTAssertTrue(committed.passed)
    let late = try await NotebookUXObservation.observe(since: .now - .seconds(1), budget: .milliseconds(100)) {
      throw NotebookUXObservation.CaptureError.unavailable
    }
    XCTAssertFalse(late.passed)
  }

  func testEveryNavigationCeilingRejectsEvenOneLateResult() {
    for budget in [NotebookUXObservation.firstUsefulFrame, NotebookUXObservation.coldOpening,
      NotebookUXObservation.zoomRefinement,
      NotebookUXObservation.pageFirstResponse, NotebookUXObservation.pageLanding] {
      XCTAssertTrue(NotebookUXObservation.Result(matched: true, elapsed: budget, budget: budget).passed)
      XCTAssertFalse(NotebookUXObservation.Result(matched: true,
        elapsed: budget + .nanoseconds(1), budget: budget).passed)
      XCTAssertFalse(NotebookUXObservation.Result(matched: false, elapsed: .zero, budget: budget).passed)
    }
  }

  func testCameraExecutionBudgetCannotHideQueueDelayOrMissingTimestamps() {
    let due = 100.0, entered = due + 0.002
    XCTAssertTrue(NotebookUXObservation.acceptsCameraSample(due: due, entered: entered, handled: entered + 0.005))
    XCTAssertFalse(NotebookUXObservation.acceptsCameraSample(due: due, entered: entered, handled: entered + 0.005_001))
    XCTAssertFalse(NotebookUXObservation.acceptsCameraSample(due: due, entered: due + 0.020, handled: due + 0.021))
    XCTAssertFalse(NotebookUXObservation.acceptsCameraSample(due: due, entered: nil, handled: due + 0.001))
    XCTAssertFalse(NotebookUXObservation.acceptsCameraSample(due: due, entered: entered, handled: due))
    XCTAssertFalse(NotebookUXObservation.acceptsCameraSample(due: due, entered: entered, handled: .nan))
  }

  func testFirstBlankOrLaterDisappearanceCannotBeAveragedAway() {
    var coverage = NotebookUXObservation.Coverage()
    coverage.record(nil)
    XCTAssertFalse(coverage.passed, "No applicable observations is missing evidence")
    coverage.record(false) // Even ONE initially blank committed frame must fail.
    for _ in 0..<100 { coverage.record(true) }
    XCTAssertEqual(coverage.checked, 101)
    XCTAssertFalse(coverage.passed)
    var stable = NotebookUXObservation.Coverage()
    stable.record(true)
    XCTAssertTrue(stable.passed)
    stable.record(false)
    XCTAssertFalse(stable.passed, "Already shown material must not disappear either")
  }
}

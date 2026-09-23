import UIKit
import XCTest
import NotebookCore
@testable import Notebook

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

  /// UIKit can combine pending .changed actions. A newer absolute camera pose
  /// covers earlier measurements of the SAME held pair, but keeps every input's
  /// original due time. Neither equal scale nor a fast ingestion call is an ACK.
  @MainActor struct CameraDelivery {
    struct Input {
      let id: TwoFingerPaperGestureRecognizer.CameraInput
      let due: TimeInterval
      let scale: Double
      let center: WorldPoint
      let requiresAction: Bool
    }
    struct Receipt {
      let id: TwoFingerPaperGestureRecognizer.CameraInput
      let scale: Double
      let center: WorldPoint
      let entered: TimeInterval
      let handled: TimeInterval
    }
    var inputs: [Input] = []
    var receipts: [Receipt] = []

    func receipt(for input: Input) -> Receipt? {
      receipts.filter { receipt in
        guard receipt.id.contactID == input.id.contactID, receipt.id.revision >= input.id.revision,
          let measured = inputs.first(where: { $0.id == receipt.id }),
          abs(receipt.scale - measured.scale) < 0.000_01 else { return false }
        let delta = receipt.center.delta(to: measured.center)
        return abs(delta.x) < 0.001 && abs(delta.y) < 0.001
      }.min { $0.handled < $1.handled }
    }

    var passed: Bool {
      let required = inputs.filter(\.requiresAction)
      return !required.isEmpty && required.allSatisfy { input in
        guard let receipt = receipt(for: input) else { return false }
        return NotebookUXObservation.acceptsCameraSample(due: input.due, entered: receipt.entered, handled: receipt.handled)
      }
    }

    var report: String {
      inputs.enumerated().map { index, sample in
        let receipt = receipt(for: sample)
        return "\(index): revision=\(sample.id.revision); required=\(sample.requiresAction); ack=\(receipt.map { String($0.id.revision) } ?? "missing"); entered=\(receipt.map { ($0.entered-sample.due)*1000 } ?? -1)ms; handled=\(receipt.map { ($0.handled-sample.due)*1000 } ?? -1)ms"
      }.joined(separator: "\n")
    }
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

  func testCoalescedCameraPoseAcknowledgesEveryIncludedInputWithoutResettingItsClock() {
    let contact = UUID()
    var delivery = NotebookUXObservation.CameraDelivery()
    delivery.inputs = [
      .init(id: .init(contactID: contact, revision: 1), due: 100, scale: 1, center: .zero, requiresAction: true),
      .init(id: .init(contactID: contact, revision: 2), due: 100.008, scale: 0.8, center: .zero, requiresAction: true)
    ]
    delivery.receipts = [.init(id: delivery.inputs[1].id, scale: 0.8, center: .zero,
      entered: 100.012, handled: 100.014)]
    XCTAssertTrue(delivery.passed, "Latest absolute pose covers both measurements before their own deadlines")
    XCTAssertEqual(delivery.receipt(for: delivery.inputs[0])?.id.revision, 2)
    delivery.receipts = [.init(id: delivery.inputs[1].id, scale: 0.8, center: .zero,
      entered: 100.017, handled: 100.019)]
    XCTAssertTrue(NotebookUXObservation.acceptsCameraSample(due: delivery.inputs[1].due,
      entered: 100.017, handled: 100.019))
    XCTAssertFalse(delivery.passed, "A newer timely pose cannot forgive the earlier input's 19-ms queue delay")
    delivery.receipts = [.init(id: delivery.inputs[1].id, scale: 0.8, center: .zero,
      entered: 100.008, handled: 100.014)]
    XCTAssertFalse(delivery.passed, "A coalesced action also keeps the independent 5-ms execution ceiling")
  }

  func testCameraReceiptMustBelongToThisContactAndAnActuallyMeasuredRevision() {
    let contact = UUID()
    var delivery = NotebookUXObservation.CameraDelivery()
    delivery.inputs = [
      .init(id: .init(contactID: contact, revision: 1), due: 100, scale: 1, center: .zero, requiresAction: true),
      .init(id: .init(contactID: contact, revision: 2), due: 100.008, scale: 1, center: .zero, requiresAction: true)
    ]
    XCTAssertFalse(delivery.passed, "Missing action is not a fast sample")
    for id in [TwoFingerPaperGestureRecognizer.CameraInput(contactID: UUID(), revision: 2),
      .init(contactID: contact, revision: 1), .init(contactID: contact, revision: 3)] {
      delivery.receipts = [.init(id: id, scale: 1, center: .zero, entered: 100.010, handled: 100.012)]
      XCTAssertFalse(delivery.passed,
        "Equal scale cannot authorize a foreign contact, stale pose, or invented future revision")
    }
  }

  func testCameraAckRequiresTheAppliedPoseAndValidHandlerTimes() {
    let input = NotebookUXObservation.CameraDelivery.Input(id: .init(contactID: UUID(), revision: 1),
      due: 100, scale: 0.8, center: .init(x: 10, y: 20), requiresAction: true)
    var delivery = NotebookUXObservation.CameraDelivery(inputs: [input])
    delivery.receipts = [.init(id: input.id, scale: 0.8, center: input.center, entered: 100.001, handled: 100.002)]
    XCTAssertTrue(delivery.passed)
    for receipt in [
      NotebookUXObservation.CameraDelivery.Receipt(id: input.id, scale: 1, center: input.center,
        entered: 100.001, handled: 100.002),
      .init(id: input.id, scale: 0.8, center: .zero, entered: 100.001, handled: 100.002),
      .init(id: input.id, scale: 0.8, center: input.center, entered: .nan, handled: 100.002),
      .init(id: input.id, scale: 0.8, center: input.center, entered: 100.001, handled: .nan),
      .init(id: input.id, scale: 0.8, center: input.center, entered: 99.999, handled: 100.002)
    ] {
      delivery.receipts = [receipt]
      XCTAssertFalse(delivery.passed, "Invoking the action is not proof that it applied the measured camera pose")
    }
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

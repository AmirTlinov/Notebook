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
  static let coldOpening: Duration = .seconds(2)

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
      let matched = try probe()
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
      XCTAssertTrue(captured, "A failed window capture is missing evidence, never a green frame")
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
}

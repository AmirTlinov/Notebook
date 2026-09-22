import UIKit
import XCTest
@testable import Notebook

/// No snapshots, forced layout, CA flush, display-rate override, or renderer
/// prewarming. UIKit submission and OS Metal presentation remain separate lanes.
@MainActor
final class NotebookGestureLatency {
  nonisolated static let budgetMS = 20.0
  struct Sample {
    let due: TimeInterval
    let handled: TimeInterval
    let needsPresentation: Bool
    let contact: InkCanvasView.ContactFrame?
    var uiSubmitted: TimeInterval?
    var presented: TimeInterval?
    var complete: Bool { uiSubmitted != nil && (!needsPresentation || presented != nil) }
    func accepts(_ time: TimeInterval?) -> Bool {
      guard let time, time.isFinite, due.isFinite, time > 0 else { return false }
      return time >= due && (time - due) * 1_000 <= NotebookGestureLatency.budgetMS
    }
    var passed: Bool {
      accepts(handled) && accepts(uiSubmitted)
        && (!needsPresentation || (contact != nil && accepts(presented)))
    }
  }
  private struct Frame {
    let contact: InkCanvasView.ContactFrame
    let tileCount: Int
    var times: [Int: TimeInterval] = [:]
  }
  private var frames: [UUID: Frame] = [:]
  private(set) var samples: [Sample] = []
  private var link: UIUpdateLink?
  private weak var canvas: InkCanvasView?

  init(window: UIWindow? = nil, canvas: InkCanvasView? = nil) {
    self.canvas = canvas
    if let window {
      let link = UIUpdateLink(view: window)
      link.addAction(to: .afterUpdateComplete) { [weak self] _, _ in
        // Actual callback time, NOT estimatedPresentationTime. This proves only
        // that UIKit finished its update, not that SwiftUI's pixels were shown.
        self?.submitted(at: CACurrentMediaTime())
      }
      link.isEnabled = true
      self.link = link
    }
    if let canvas {
      precondition(canvas.onContactFramePresented == nil, "Do not replace another observer")
      canvas.onContactFramePresented = { [weak self] in self?.receive($0) }
    }
  }
  func stop() { link?.isEnabled = false; link = nil; canvas?.onContactFramePresented = nil }
  isolated deinit { stop() }

  func input(due: TimeInterval, needsPresentation: Bool = true, action: () -> Void) {
    action()
    samples.append(.init(due: due, handled: CACurrentMediaTime(), needsPresentation: needsPresentation && canvas != nil,
      contact: canvas?.activeContactFrame))
  }
  func submitted(at time: TimeInterval) {
    for i in samples.indices where samples[i].uiSubmitted == nil { samples[i].uiSubmitted = time }
  }
  func receive(_ receipt: InkCanvasView.PresentedContactFrame) {
    guard receipt.tileCount > 0, (0..<receipt.tileCount).contains(receipt.tile),
      receipt.presentedAt.isFinite, receipt.presentedAt > 0 else { return }
    var frame = frames[receipt.frameID] ?? .init(contact: receipt.contact, tileCount: receipt.tileCount)
    guard frame.contact == receipt.contact, frame.tileCount == receipt.tileCount else { return }
    frame.times[receipt.tile] = receipt.presentedAt
    frames[receipt.frameID] = frame
    // Every changed drawable must be presented: the fastest tile cannot hide
    // a late/missing tile. A newer revision can include older measured samples.
    guard frame.times.count == frame.tileCount, let shown = frame.times.values.max() else { return }
    for i in samples.indices {
      guard let contact = samples[i].contact, contact.sourceID == frame.contact.sourceID,
        contact.revision <= frame.contact.revision else { continue }
      samples[i].presented = min(samples[i].presented ?? .infinity, shown)
    }
  }
  func drain() async throws {
    // A diagnostic wait is not the acceptance budget. Missing receipts and any
    // sample over 20 ms still fail; waiting never rebases the sample's clock.
    let until = ContinuousClock.now + .seconds(1)
    while !samples.allSatisfy(\.complete), ContinuousClock.now < until {
      try await Task.sleep(for: .milliseconds(2))
    }
  }
  var passed: Bool { !samples.isEmpty && samples.allSatisfy(\.passed) }
  func assertResult(_ test: XCTestCase, name: String, count: Int,
    file: StaticString = #filePath, line: UInt = #line) {
    func statistics(_ time: (Sample) -> TimeInterval?) -> String {
      let values = samples.compactMap { sample in time(sample).map { ($0 - sample.due) * 1_000 } }.sorted()
      guard !values.isEmpty else { return "missing" }
      func percentile(_ p: Double) -> Double { values[max(0, Int(ceil(Double(values.count) * p)) - 1)] }
      return "n=\(values.count) p50=\(percentile(0.5)) p95=\(percentile(0.95)) p99=\(percentile(0.99)) max=\(values.last!) ms"
    }
    let bad = samples.indices.filter { !samples[$0].passed }
    let text = "\(name), fixed 120 Hz input, EVERY sample <= \(Self.budgetMS) ms; "
      + "input to handler return: \(statistics { $0.handled }); "
      + "UIKit update completion: \(statistics { $0.uiSubmitted }); "
      + "OS Metal presentation: \(statistics { $0.presented }); failed samples=\(bad). "
      + "UIKit is not a presentation ACK. Neither lane measures physical Pencil sensing/photons."
    print(text)
    let attachment = XCTAttachment(string: text); attachment.name = name; attachment.lifetime = .keepAlways
    test.add(attachment)
    let rows = samples.enumerated().map { i, sample in
      func ms(_ time: Double?) -> String { time.map { String(($0 - sample.due) * 1_000) } ?? "missing" }
      return "\(i),\(ms(sample.handled)),\(ms(sample.uiSubmitted)),\(ms(sample.presented)),\(sample.passed)"
    }
    let detail = XCTAttachment(string: "sample,handler_ms,ui_update_ms,metal_present_ms,passed\n" + rows.joined(separator: "\n"))
    detail.name = name + "-samples.csv"; detail.lifetime = .keepAlways; test.add(detail)
    XCTAssertEqual(samples.count, count, "Missing input cannot produce green evidence", file: file, line: line)
    XCTAssertTrue(passed, text, file: file, line: line)
  }
}

@MainActor
final class NotebookGestureLatencyTests: XCTestCase {
  func testEmptyMissingAndSingleLateSampleCannotHideBehindGoodPercentiles() {
    let empty = NotebookGestureLatency(); XCTAssertFalse(empty.passed)
    var samples = (0..<120).map { _ in
      NotebookGestureLatency.Sample(due: 10, handled: 10.001, needsPresentation: false,
        contact: nil, uiSubmitted: 10.010)
    }
    XCTAssertTrue(samples.allSatisfy(\.passed))
    samples[119].uiSubmitted = 10.021
    XCTAssertFalse(samples.allSatisfy(\.passed), "One stall fails even when p95 is excellent")
    samples[119].uiSubmitted = nil; XCTAssertFalse(samples[119].passed)
    samples[119].uiSubmitted = .nan; XCTAssertFalse(samples[119].passed)
    samples[119].uiSubmitted = 9.999; XCTAssertFalse(samples[119].passed)
    let lateHandler = NotebookGestureLatency.Sample(due: 10, handled: 10.030,
      needsPresentation: false, contact: nil, uiSubmitted: 10.010)
    XCTAssertFalse(lateHandler.passed, "Time spent blocking before the observer cannot disappear")
  }

  func testWrongStaleDroppedOrPartialDrawableCannotAcknowledgeTheInput() {
    let canvas = InkCanvasView(frame: .zero)
    let stroke = ActiveInkStroke(style: .standard)
    stroke.replacePredictions(with: [])
    canvas.displayActiveStroke(stroke)
    let monitor = NotebookGestureLatency(canvas: canvas)
    let due = CACurrentMediaTime()
    monitor.input(due: due) {}
    monitor.submitted(at: due + 0.001)
    let expected = canvas.activeContactFrame!
    func receipt(_ contact: InkCanvasView.ContactFrame, _ time: Double,
      frame: UUID = UUID(), tile: Int = 0, count: Int = 1) -> InkCanvasView.PresentedContactFrame {
      .init(frameID: frame, contact: contact, tile: tile, tileCount: count, presentedAt: time)
    }
    monitor.receive(receipt(.init(sourceID: UUID(), revision: expected.revision), due + 0.002))
    monitor.receive(receipt(.init(sourceID: expected.sourceID, revision: expected.revision - 1), due + 0.002))
    monitor.receive(receipt(expected, 0))
    XCTAssertFalse(monitor.passed)
    let frame = UUID()
    monitor.receive(receipt(expected, due + 0.010, frame: frame, tile: 0, count: 2))
    XCTAssertFalse(monitor.passed, "A missing tile is not an acknowledged frame")
    monitor.receive(receipt(expected, due + 0.021, frame: frame, tile: 1, count: 2))
    XCTAssertFalse(monitor.passed, "All affected tiles count, including the slowest")
    monitor.receive(receipt(expected, due + 0.011))
    XCTAssertTrue(monitor.passed)
    monitor.stop()
  }
}

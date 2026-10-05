import NotebookCore
import UIKit
import XCTest
@testable import Notebook

@MainActor
final class InputFrameMonitorTests: XCTestCase {
  func testFreshSQLWorkspaceRecordsShortContactsWithoutAnExistingRuntimeDirectory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try await Task.detached {
      try NotebookStore(root: root).initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    }.value
    let runtime = root.appendingPathComponent("runtime")
    XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.path))
    let monitor = InputFrameMonitor(root: root), source = UUID()
    monitor.begin(mode: "page")
    var input = monitor.beginInput(on: .init(id: UUID(), pageID: UUID()), phase: .began)
    input.accept(.init(timestamp: input.entered, index: 0, kind: .actual, replacesSample: false),
      sourceID: source, tool: .pen)
    input.returned = input.entered
    monitor.record(input)
    monitor.contactEnded(source, reason: .lift)
    monitor.end()
    // Finishing with a write already scheduled must save the terminal boundary
    // even when no further input or receipt arrives to wake the writer.
    await monitor.finish()
    XCTAssertNil(monitor.writeFailure)
    let report = try report(at: root)
    XCTAssertNotNil(report.stoppedAt)
    XCTAssertEqual(report.outcomes.count, 1)
    XCTAssertNil(report.outcomes[0].osPresented)
    XCTAssertEqual(report.outcomes[0].unresolved, .noProjectedFrame,
      "A contact without a submitted drawable remains explicit evidence")
  }

  func testFailedDiagnosticWriteIsReportedAndALaterContactCanRecover() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let runtime = root.appendingPathComponent("runtime")
    let obstruction = Data("preserve this file".utf8)
    try obstruction.write(to: runtime)
    let monitor = InputFrameMonitor(root: root)
    monitor.begin(mode: "blocked"); monitor.end()
    try await waitUntil { monitor.writeFailure != nil }
    XCTAssertEqual(try Data(contentsOf: runtime), obstruction)
    try FileManager.default.removeItem(at: runtime)
    monitor.begin(mode: "recovered"); monitor.end()
    await monitor.checkpoint()
    XCTAssertNil(monitor.writeFailure)
    let report = try report(at: root)
    let modes = report.events.compactMap { event -> String? in
      if case .activity(let activity) = event { return activity.mode }; return nil
    }
    XCTAssertEqual(modes, ["blocked", "recovered"], "A bounded failed capture remains available to the same writer")
    XCTAssertEqual(report.writeFailures, 1)
  }

  func testLateOSReceiptResolvesOnlyItsCompletePageRevisionAndKeepsTheLiftTail() throws {
    let surface = InputFrameMonitor.Surface(id: UUID(), pageID: UUID()), source = UUID(), frame = UUID()
    func input(_ id: UInt64, revision: UInt64, phase: InputFrameMonitor.Phase,
      kind: InputFrameMonitor.SampleKind, time: Double, entered: Double) -> InputFrameMonitor.Event {
      var value = InputFrameMonitor.Input(id: id, surface: surface, phase: phase, entered: entered)
      value.accept(.init(timestamp: time, index: Int(id), kind: kind, replacesSample: kind == .estimatedCorrection),
        sourceID: source, tool: .pen)
      value.returned = entered + 0.001
      value.contact = .init(sourceID: source, revision: revision)
      return .input(value)
    }
    func receipt(_ id: UUID, revision: UInt64, tile: Int = 0, count: Int = 1,
      time: Double? = 10.02, surface owner: InputFrameMonitor.Surface? = nil,
      source contactSource: UUID? = nil) -> InputFrameMonitor.Event {
      .frame(.init(surface: owner ?? surface, id: id,
        contact: .init(sourceID: contactSource ?? source, revision: revision), tile: tile, tileCount: count,
        osPresented: time, simulatorCompletion: time == nil ? true : nil, delivered: 10.2, timing: nil))
    }
    var events: [InputFrameMonitor.Event] = [
      input(1, revision: 1, phase: .moved, kind: .coalesced, time: 10, entered: 10.005),
      input(2, revision: 3, phase: .ended, kind: .actual, time: 10.01, entered: 10.012),
      input(3, revision: 4, phase: .estimated, kind: .estimatedCorrection, time: 10.01, entered: 10.125),
      .contactEnded(source, .lift, 10.13),
      receipt(UUID(), revision: 9, surface: .init(id: UUID(), pageID: surface.pageID)),
      receipt(UUID(), revision: 9, source: UUID()),
      receipt(UUID(), revision: 0), receipt(UUID(), revision: 9, time: 0),
      receipt(UUID(), revision: 9, time: nil), receipt(frame, revision: 2, tile: 0, count: 2)
    ]
    var outcomes = InputFrameMonitor.resolve(events)
    XCTAssertTrue(outcomes.allSatisfy { $0.osPresented == nil && $0.unresolved == .contactEnded })
    events.append(receipt(frame, revision: 2, tile: 1, count: 2, time: 10.022))
    events.append(.surfaceDetached(surface, 10.14))
    outcomes = InputFrameMonitor.resolve(events)
    XCTAssertEqual(outcomes[0].osPresented, 10.022, "Every tile participates; the earliest tile is insufficient")
    XCTAssertNil(outcomes[1].osPresented, "A lifted tail needs its own revision in an OS receipt")
    XCTAssertEqual(outcomes[1].unresolved, .surfaceDetached)
    events.append(receipt(UUID(), revision: 3, time: 10.027))
    outcomes = InputFrameMonitor.resolve(events)
    XCTAssertEqual(outcomes[0].osPresented, 10.022)
    XCTAssertEqual(outcomes[1].osPresented, 10.027, "A late receipt can resolve the original contact after lift")
    XCTAssertNil(outcomes[2].osPresented, "An older drawable cannot acknowledge a late correction")
    guard case .input(let correction) = events[2] else { return XCTFail("Missing correction") }
    XCTAssertEqual(correction.samples[0].kind, .estimatedCorrection)
    XCTAssertEqual(correction.samples[0].timestamp, 10.01)
    XCTAssertEqual(correction.entered, 10.125, "Correction arrival and the original hardware timestamp remain distinct")
  }

  func testPaperBindingRecordsAcceptedFrontiersAndRetainsOldReceiptsAcrossRebinding() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let monitor = InputFrameMonitor(root: root), gate = NotebookInputGate(), actor = UUID()
    var page = PageDocument(size: .init(width: 400, height: 400), actor: actor)
    gate.onActivityChange = { active in if active { monitor.begin(mode: "page") } else { monitor.end() } }
    let coordinator = PencilCanvasView.Coordinator(inputGate: gate, publication: .init(),
      reserveAction: { _ in page.drawingStamp.advanced(by: actor) }, releaseAction: { _, _ in },
      acceptAction: { action, _, stamp, _ in try? page.prepareInkChange(.append(action), stamp: stamp) })
    let paper = PaperCanvasContainerView(frame: .init(x: 0, y: 0, width: 400, height: 400))
    coordinator.attach(to: paper); coordinator.setPageFinisherCurrent(true)
    coordinator.apply(page.inkSource, pageID: page.id, to: paper)
    coordinator.bindInputFrameMonitor(monitor, pageID: page.id, on: paper)
    let firstSurface = try XCTUnwrap(paper.touchView.inputFrameSurface)
    let oldReceipt = try XCTUnwrap(paper.inkView.onContactFrameResolved)
    var stroke: ActiveInkStroke?
    let present = paper.touchView.presentActivePen
    paper.touchView.presentActivePen = { value in stroke = value; present?(value) }
    let touch = MonitorPencilTouch()
    paper.touchView.touchesBegan([touch], with: nil)
    let source = try XCTUnwrap(stroke?.measured.sourceID)
    let coalesced = MonitorPencilTouch(), predicted = MonitorPencilTouch()
    coalesced.sampleTime = 1.005; coalesced.point.x = 40
    touch.sampleTime = 1.010; touch.point.x = 80
    predicted.sampleTime = 1.016; predicted.point.x = 110
    paper.touchView.touchesMoved([touch], with: MonitorPencilEvent(actual: [coalesced, touch], predicted: [predicted]))
    let moved = try XCTUnwrap(paper.inkView.activeContactFrame)
    XCTAssertEqual(moved.sourceID, source)
    XCTAssertEqual(moved.revision, stroke?.revision)
    touch.sampleTime = 1.020; touch.point.x = 120
    paper.touchView.touchesEnded([touch], with: nil)
    XCTAssertNil(paper.inkView.activeContactFrame)

    page = PageDocument(size: .init(width: 400, height: 400), actor: actor)
    coordinator.apply(page.inkSource, pageID: page.id, to: paper)
    coordinator.bindInputFrameMonitor(monitor, pageID: page.id, on: paper)
    let secondSurface = try XCTUnwrap(paper.touchView.inputFrameSurface)
    XCTAssertNotEqual(firstSurface, secondSurface)
    touch.sampleTime = 2; paper.touchView.touchesBegan([touch], with: nil)
    let nextSource = try XCTUnwrap(paper.inkView.activeContactFrame?.sourceID)
    XCTAssertNotEqual(source, nextSource)
    await Task.yield()
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("runtime/pencil-input.json").path),
      "A scheduled old-contact write must wait for the replacement contact to finish")
    oldReceipt(.init(frameID: UUID(), contact: .init(sourceID: source, revision: .max),
      tile: 0, tileCount: 1, completion: .osPresentation(1.5), isFirstFrame: false))
    touch.sampleTime = 2.01; paper.touchView.touchesEnded([touch], with: nil)
    coordinator.detach(from: paper)
    await monitor.finish()
    let report = try report(at: root)
    let inputs = report.events.compactMap { event -> InputFrameMonitor.Input? in
      if case .input(let input) = event { return input }; return nil
    }
    XCTAssertEqual(inputs.count, 5)
    let movedInput = try XCTUnwrap(inputs.first { $0.phase == .moved })
    XCTAssertEqual(movedInput.contact, moved)
    XCTAssertEqual(movedInput.samples.map(\.kind), [.coalesced, .actual])
    XCTAssertEqual(movedInput.samples.map(\.timestamp), [1.005, 1.010], "Predictions are never admitted measurements")
    let tail = try XCTUnwrap(inputs.first { $0.phase == .ended })
    XCTAssertEqual(tail.sourceID, source)
    XCTAssertEqual(tail.contact?.sourceID, source, "Lift keeps the last projected frontier after active ink is cleared")
    XCTAssertEqual(tail.samples.last?.timestamp, 1.020)
    XCTAssertTrue(report.outcomes.filter { $0.inputID <= tail.id }.allSatisfy { $0.osPresented == 1.5 })
    XCTAssertTrue(report.outcomes.filter { $0.inputID > tail.id }.allSatisfy { $0.osPresented == nil },
      "An old callback remains bound to its original surface and contact")
  }

  private func report(at root: URL) throws -> InputFrameMonitor.Report {
    try JSONDecoder().decode(InputFrameMonitor.Report.self,
      from: Data(contentsOf: root.appendingPathComponent("runtime/pencil-input.json")))
  }
  private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(predicate(), "The diagnostic writer did not finish within its bounded wait")
  }
}

@MainActor
private final class MonitorPencilTouch: UITouch {
  var point = CGPoint(x: 20, y: 100)
  var sampleTime: TimeInterval = 1
  override var type: UITouch.TouchType { .pencil }
  override var timestamp: TimeInterval { sampleTime }
  override var force: CGFloat { 1 }
  override var maximumPossibleForce: CGFloat { 1 }
  override var altitudeAngle: CGFloat { .pi / 2 }
  override func location(in view: UIView?) -> CGPoint { point }
  override func preciseLocation(in view: UIView?) -> CGPoint { point }
  override func azimuthAngle(in view: UIView?) -> CGFloat { 0 }
}

@MainActor
private final class MonitorPencilEvent: UIEvent {
  let actual: [UITouch], predicted: [UITouch]
  init(actual: [UITouch], predicted: [UITouch]) { self.actual = actual; self.predicted = predicted; super.init() }
  override func coalescedTouches(for touch: UITouch) -> [UITouch]? { actual }
  override func predictedTouches(for touch: UITouch) -> [UITouch]? { predicted }
}

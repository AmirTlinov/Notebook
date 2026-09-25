import UIKit
import XCTest
@testable import Notebook

/// Shares the actual mounted scene/input fixture with pixel correctness tests.
/// Latency replay never captures a window or waits for each sample to render.
extension NotebookInteractionUXTests {
  func testPencilReplayCannotHideBacklogBySlowingItsInputSchedule() async throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("Simulator has no OS Metal presentation receipts; GPU readiness cannot certify the 20 ms display budget")
    #endif
    let scene = try await fixture()
    try await scene.readyPencil(self)
    try await replay("pen-20ms", scene, points: line(from: .init(x: 150, y: 800),
      to: .init(x: 450, y: 800)), metal: true)
    try await correct("pen-replay-pixels", scene, [(.init(x: 430, y: 800), .black)])
  }

  func testInkEraserMeetsTwentyMillisecondPresentationBudget() async throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("Simulator has no OS Metal presentation receipts; GPU readiness cannot certify the 20 ms display budget")
    #endif
    let scene = try await fixture(tool: .eraser)
    scene.model.selectEraserWidth(28)
    try await scene.readyPencil(self)
    try await replay("ink-eraser-20ms", scene, points: line(from: .init(x: 230, y: 650),
      to: .init(x: 330, y: 650)), metal: true)
    try await correct("ink-eraser-replay-pixels", scene,
      [(.init(x: 280, y: 650), .paper), (.init(x: 430, y: 650), .black)])
  }

  func testShapeEraserMeetsTwentyMillisecondUIUpdateBudget() async throws {
    let scene = try await fixture(tool: .eraser)
    scene.model.selectEraserWidth(28)
    try await scene.readyPencil(self)
    // The page ink drawable alone cannot acknowledge a SwiftUI shape mask.
    // Gate submission here, check the actual result separately, never substitute
    // a fast unrelated Metal frame for proof that the shape was erased.
    try await replay("shape-eraser-ui-20ms", scene, points: line(from: .init(x: 230, y: 280),
      to: .init(x: 230, y: 400)))
    try await correct("shape-eraser-replay-pixels", scene,
      [(.init(x: 230, y: 330), .paper), (.init(x: 350, y: 330), .red)])
  }

  func testWholeObjectDragMeetsTwentyMillisecondUIUpdateBudget() async throws {
    let scene = try await fixture(tool: .lasso)
    scene.model.drawingToolSettings.lassoMode = .elements
    try await scene.readyFinger(self)
    // Unselected material needs a quiet hold; this measures the immediate drag
    // of an already selected object, using the same ordinary tap as the UX test.
    scene.beginFinger(.init(x: 590, y: 590)); scene.endFinger()
    XCTAssertEqual(scene.model.selectionSession.element?.elementID, "ux-blue")
    try await scene.readyFinger(self)
    try await replay("whole-object-ui-20ms", scene, points: line(from: .init(x: 590, y: 590),
      to: .init(x: 590, y: 790)), finger: true)
    try await correct("whole-object-replay-pixels", scene,
      [(.init(x: 590, y: 590), .paper), (.init(x: 590, y: 790), .blue), (.init(x: 350, y: 330), .red)])
  }

  func testLassoOutlineAndCutDragMeetTwentyMillisecondUIUpdateBudget() async throws {
    let scene = try await fixture(erasedShape: true, tool: .lasso)
    scene.model.drawingToolSettings.lassoMode = .region
    try await scene.readyPencil(self)
    let contour = (0..<120).map { i -> CGPoint in
      let angle = Double(i) / 119 * .pi * 2
      return .init(x: 230 + 50 * cos(angle), y: 330 + 60 * sin(angle))
    }
    try await replay("lasso-outline-ui-20ms", scene, points: contour)
    _ = try XCTUnwrap(scene.model.selectionSession.region, "No contour is not fast selection")
    try await scene.readyFinger(self)
    try await replay("cold-lasso-drag-ui-20ms", scene,
      points: line(from: .init(x: 230, y: 330), to: .init(x: 230, y: 550)), finger: true)
    try await correct("lasso-replay-pixels", scene,
      [(.init(x: 230, y: 330), .paper), (.init(x: 230, y: 550), .red),
       (.init(x: 350, y: 330), .red), (.init(x: 400, y: 330), .paper)])
  }

  private func line(from a: CGPoint, to b: CGPoint) -> [CGPoint] {
    (0..<120).map { i in
      let t = Double(i) / 119
      return .init(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
  }
  private func replay(_ name: String, _ scene: Scene, points: [CGPoint],
    finger: Bool = false, metal: Bool = false) async throws {
    let canvas = metal ? try XCTUnwrap(scene.paper.superview as? PaperCanvasContainerView).inkView : nil
    let monitor = NotebookGestureLatency(window: scene.window, canvas: canvas)
    defer { monitor.stop() }
    let began = CACurrentMediaTime()
    for (index, point) in points.enumerated() {
      // Fixed absolute deadlines include event backlog. Never slow the input
      // schedule to accommodate the renderer or reset the clock after a stall.
      let due = began + Double(index) / 120
      let remaining = due - CACurrentMediaTime()
      if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
      monitor.input(due: due) {
        if finger {
          if index == 0 { scene.beginFinger(point) }
          else {
            let first = points[0].applying(scene.pageToWindow), current = point.applying(scene.pageToWindow)
            scene.moveFinger(point, expectsManipulation: hypot(current.x - first.x, current.y - first.y) >= 4)
          }
        } else {
          if index == 0 { scene.beginPencil(point) }
          else { scene.movePencil(point, timestamp: due) }
        }
      }
    }
    // Keep the contact alive until its last measured revision is acknowledged.
    // This does not forgive late samples. Lift/publication continuity and the
    // immediate next gesture have their own screenshot-based scenarios.
    try await monitor.drain()
    monitor.input(due: CACurrentMediaTime(), needsPresentation: false) {
      if finger { scene.endFinger() } else { scene.endPencil() }
    }
    try await monitor.drain()
    monitor.assertResult(self, name: name, count: points.count + 1)
  }
  private func correct(_ name: String, _ scene: Scene,
    _ probes: [(CGPoint, NotebookUXObservation.Color)]) async throws {
    // Timing is already captured without readback. This first snapshot must be
    // correct; its own capture cost is not another input latency measurement.
    let snapshot = try NotebookUXObservation.Pixels(window: scene.window)
    let matches = try snapshot.matches(probes.map { ($0.0.applying(scene.pageToWindow), $0.1) })
    XCTAssertTrue(matches, "\(name): a fast callback without the expected pixels cannot pass")
    if !matches {
      let attachment = XCTAttachment(image: snapshot.image)
      attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
  }
}

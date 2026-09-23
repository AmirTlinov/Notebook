import UIKit
import XCTest

/// Ordinary entry and real finger/keyboard routing. Native companion tests
/// own subsecond pixel/latency gates; XCTest automation duration is not FPS.
@MainActor final class NotebookNavigationLoadUITests: XCTestCase {
  private var app: XCUIApplication!
  private var surface: XCUIElement { app.otherElements["page-turn-surface"] }

  func testDenseSVGPagesTurnForwardReverseAndRepeatedArrowsWithoutBlankLanding() throws {
    launch(programs: false)
    try leaf(0, since: open())
    for index in 1...3 { try turn(to: index) { surface.swipeLeft() } }
    for index in (0..<3).reversed() { try turn(to: index) { surface.swipeRight() } }
    try turn(to: 3) { app.buttons["next-page"].tap(withNumberOfTaps: 3, numberOfTouches: 1) }
    try turn(to: 0) { app.buttons["previous-page"].tap(withNumberOfTaps: 3, numberOfTouches: 1) }
  }

  func testTwentyFourPageProgramsAcceptFirstTapAfterZoomAndKeepStateAcrossTurns() throws {
    launch(programs: true); try controls(leaf: 0, since: open())
    surface.pinch(withScale: 1.4, velocity: 1); surface.pinch(withScale: 1 / 1.4, velocity: -1)
    let rectangles = try visibleControlRects()
    for (index, rectangle) in rectangles.enumerated() {
      tapControl(rectangle)
      try changedControl(rectangle, index: index)
    }
    let next = ContinuousClock.now
    app.buttons["next-page"].tap(); try controls(leaf: 1, since: next)
    let previous = ContinuousClock.now
    app.buttons["previous-page"].tap(); try controls(leaf: 0, since: previous)
    XCTAssertEqual(try visibleControlRects(red: true).count, 24,
      "Every program must retain its visibly changed state after returning")
  }

  func testTwentyFourBoardProgramsStayInteractiveAfterZoomOutAndBack() throws {
    try controls(leaf: 0, since: launch(programs: true, board: true))
    app.pinch(withScale: 0.55, velocity: -1); app.pinch(withScale: 1.25, velocity: 1)
    // Real pinches need not have identical centroids. Locate actual submitted
    // pixels, not untransformed WebKit accessibility frames or an assumed pose.
    let rectangles = try visibleControlRects()
    for (index, rectangle) in rectangles.enumerated() {
      tapControl(rectangle)
      try changedControl(rectangle, index: index)
    }
  }

  func testContinuousZoomWithProgramsMeetsSystemHitchBudget() throws {
    try controls(leaf: 0, since: launch(programs: true, board: true))
    let options = XCTMeasureOptions(); options.iterationCount = 10
    measure(metrics: [XCTHitchMetric(application: app)], options: options) {
      app.pinch(withScale: 0.8, velocity: -1)
      app.pinch(withScale: 1.25, velocity: 1)
    }
  }

  func testDensePageTurnsMeetSystemHitchBudget() throws {
    launch(programs: false); try leaf(0, since: open())
    let options = XCTMeasureOptions(); options.iterationCount = 10
    measure(metrics: [XCTHitchMetric(application: app)], options: options) {
      do {
        try turn(to: 1) { surface.swipeLeft() }
        try turn(to: 0) { surface.swipeRight() }
      } catch { XCTFail("Cannot inspect the landed page: \(error)") }
    }
  }

  private func control(leaf: Int, index: Int) -> XCUIElement {
    app.buttons["Load \(leaf) control \(index)"]
  }

  private struct Pixels {
    let width: Int, height: Int
    var rgba: [UInt8]
    init(image: CGImage, size: CGSize) throws {
      width = Int(size.width); height = Int(size.height)
      rgba = [UInt8](repeating: 0, count: width * height * 4)
      try rgba.withUnsafeMutableBytes { bytes in
        let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: width, height: height,
          bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: .init(origin: .zero, size: size))
      }
    }
    func matches(_ offset: Int, red: Bool) -> Bool {
      red ? rgba[offset * 4] > 180 && rgba[offset * 4 + 1] < 100 && rgba[offset * 4 + 2] < 100
        : rgba[offset * 4] < 70 && rgba[offset * 4 + 1] < 160 && rgba[offset * 4 + 2] > 180
    }
  }

  private func visibleControlRects(red: Bool = false) throws -> [CGRect] {
    let pixels = try Pixels(image: XCTUnwrap(app.screenshot().image.cgImage), size: app.frame.size)
    var visited = [Bool](repeating: false, count: pixels.width * pixels.height), rectangles: [CGRect] = []
    // Connected colour regions survive CSS pulses and text. Only the controls
    // use this colour; no DOM or production-only inspection hook supplies pose.
    for start in visited.indices where !visited[start] && pixels.matches(start, red: red) {
      var queue = [start], head = 0, minX = start % pixels.width, maxX = minX
      var minY = start / pixels.width, maxY = minY
      visited[start] = true
      while head < queue.count {
        let offset = queue[head], x = offset % pixels.width, y = offset / pixels.width
        head += 1; minX = min(minX,x); maxX = max(maxX,x); minY = min(minY,y); maxY = max(maxY,y)
        for next in [x > 0 ? offset-1 : -1, x+1 < pixels.width ? offset+1 : -1,
          y > 0 ? offset-pixels.width : -1, y+1 < pixels.height ? offset+pixels.width : -1]
          where next >= 0 && !visited[next] && pixels.matches(next, red: red) {
          visited[next] = true; queue.append(next)
        }
      }
      if maxX-minX > 35 && maxY-minY > 25 {
        rectangles.append(.init(x:minX,y:minY,width:maxX-minX+1,height:maxY-minY+1))
      }
    }
    XCTAssertEqual(rectangles.count, 24, "All 24 controls must be visibly present after real zoom")
    return rectangles.sorted { abs($0.midY-$1.midY) > 10 ? $0.midY < $1.midY : $0.midX < $1.midX }
  }

  private func tapControl(_ rect: CGRect) {
    app.coordinate(withNormalizedOffset: .zero).withOffset(.init(dx:rect.midX,dy:rect.midY)).tap()
  }

  private func changedControl(_ rect: CGRect, index: Int) throws {
    let image = app.screenshot().image
    let pixels = try Pixels(image: XCTUnwrap(image.cgImage), size: app.frame.size)
    let red = (Int(rect.minY)..<Int(rect.maxY)).reduce(0) { sum,y in
      sum + (Int(rect.minX)..<Int(rect.maxX)).filter { pixels.matches(y*pixels.width+$0,red:true) }.count
    }
    // A floating toolbar may occlude a corner of a partially visible program.
    // Compare its painted area, not a probe that might fall on that toolbar.
    XCTAssertGreaterThan(Double(red), rect.width*rect.height*0.45,
      "The FIRST real tap must visibly change program \(index), without a second activation tap")
    if index == 23 {
      let shot = XCTAttachment(image:image); shot.name = "24 controls responded to their first tap"
      shot.lifetime = .keepAlways; add(shot)
    }
  }

  @discardableResult private func launch(programs: Bool, board: Bool = false) -> ContinuousClock.Instant {
    continueAfterFailure = false; executionTimeAllowance = 240
    app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-navigation-load-fixture", "--notebook-simulator-finger-gestures"]
    if programs { app.launchArguments.append("--notebook-load-programs") }
    if board { app.launchArguments.append("--notebook-load-board") }
    let start = ContinuousClock.now
    app.launch(); XCUIDevice.shared.orientation = .portrait
    return start
  }
  private func open() -> ContinuousClock.Instant {
    let cover = app.descendants(matching: .any).matching(identifier: "workspace-item-7e7a2000-0000-4000-8000-000000000002").firstMatch
    XCTAssertTrue(cover.waitForExistence(timeout: 8))
    let start = ContinuousClock.now
    cover.doubleTap()
    XCTAssertTrue(surface.waitForExistence(timeout: 2))
    return start
  }
  private func controls(leaf: Int, since start: ContinuousClock.Instant) throws {
    // This bounds the ENTIRE AX journey (24 remote queries + screenshots), not
    // application latency. Native tests separately enforce all 24 within 1 s.
    let deadline = start + .seconds(30)
    let controls = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Load \(leaf) control "))
    var count = controls.count
    while count != 24, ContinuousClock.now < deadline { count = controls.count }
    XCTAssertEqual(count, 24, "Every control must exist in the real accessibility tree")
    // One remote snapshot names all 24. Asking existence and hittability
    // separately 48 times serialized AX traffic (~35 s) and measured XCTest,
    // not the app. The following real first taps prove each control's input.
    let image = XCTAttachment(screenshot: app.screenshot()); image.name = "24 live controls, leaf \(leaf)"; image.lifetime = .keepAlways; add(image)
    XCTAssertLessThanOrEqual(start.duration(to: .now), .seconds(30),
      "UI automation watchdog, including the action, every AX query and capture; NOT the 1 s product budget")
  }
  private func turn(to index: Int, action: () -> Void) throws {
    let start = ContinuousClock.now
    action()
    try leaf(index, since: start)
  }
  private func leaf(_ index: Int, since start: ContinuousClock.Instant) throws {
    // XCTest swipe/tap waits for remote event delivery and idleness. Keep that
    // overhead explicit; do not restart a fake 'latency' clock after it returns.
    // Native presentation tests enforce 16.67/450 ms without AX or capture loops.
    var image = app.screenshot().image
    while !(try leafIsVisible(index, image: image)), start.duration(to: .now) < .seconds(5) {
      image = app.screenshot().image
    }
    let attachment = XCTAttachment(image: image); attachment.name = "Dense leaf \(index)"; attachment.lifetime = .keepAlways; add(attachment)
    XCTAssertTrue(try leafIsVisible(index,image:image), "Wrong source or missing SVG on the landed image")
    XCTAssertLessThanOrEqual(start.duration(to:.now),.seconds(5), "UI automation watchdog from BEFORE the gesture, not the 450 ms app-presentation budget")
  }

  private func leafIsVisible(_ index: Int, image: UIImage) throws -> Bool {
    let cg = try XCTUnwrap(image.cgImage), scale = CGFloat(cg.width) / app.frame.width
    let fit = min(app.frame.width / 834, app.frame.height / 1194)
    let origin = CGPoint(x: (app.frame.width - 834*fit)/2, y: (app.frame.height - 1194*fit)/2)
    var probes: [(CGPoint, Bool)] = []
    for i in 0..<13 { probes.append((CGPoint(x: 200 + (i%4)*190, y: 335 + (i/4)*190), true)) }
    for leaf in 0..<4 { probes.append((CGPoint(x: 100 + leaf*90, y: 1045), leaf == index)) }
    for probe in probes {
      let point = CGPoint(x: origin.x + probe.0.x*fit, y: origin.y + probe.0.y*fit)
      let pixel = try XCTUnwrap(cg.cropping(to: .init(x: point.x*scale, y: point.y*scale, width: 1, height: 1)))
      var rgba = [UInt8](repeating: 0, count: 4)
      try rgba.withUnsafeMutableBytes { bytes in
        let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
          bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(pixel, in: .init(x: 0, y: 0, width: 1, height: 1))
      }
      let blue = rgba[0] < 100 && rgba[2] > 180
      if blue != probe.1 { return false }
    }
    return true
  }
}


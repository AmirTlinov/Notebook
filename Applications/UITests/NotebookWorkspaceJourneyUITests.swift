import UIKit
import XCTest

/// System-routed taps, swipes, keyboard, lifecycle and screenshots. Never calls
/// model.selectPage, UIPageViewController delegates, or a ready(true) callback.
/// XCTest cannot synthesize hardware Pencil on this physical device: these
/// checks complement, not replace, the native 20-ms Pencil/render gates.
@MainActor final class NotebookWorkspaceJourneyUITests: XCTestCase {
  private var app: XCUIApplication!
  private var paperFrame = CGRect.zero
  private var surface: XCUIElement { app.otherElements["page-turn-surface"] }
  private var cover: XCUIElement { app.descendants(matching: .any)
    .matching(identifier: "workspace-item-7e7a1000-0000-4000-8000-000000000002").firstMatch }

  func testColdBoardEntryAndRealSwipesShowEveryLeafAfterEvictionAndReturn() throws {
    try launch()
    try open()
    for number in 1...5 { try turn("swipe-to-\(number + 1)", to: number) { surface.swipeLeft() } }
    for number in (0..<5).reversed() { try turn("reverse-to-\(number + 1)", to: number) { surface.swipeRight() } }
    try leave()
    try open()
    // A successful counter change or shell mount alone cannot satisfy a turn.
    try turn("button-next", to: 1) { app.buttons["next-page"].tap() }
    try turn("button-previous", to: 0) { app.buttons["previous-page"].tap() }
  }

  func testFirstSelectionMoveDeleteAndColdReopenPreserveTheWholeComposition() throws {
    try launch(); try open()
    let node = app.images["Journey movable 1"]
    try step("first-body-selection", { node.tap() }) {
      XCTAssertTrue(self.app.buttons["delete-agent-element"].isHittable)
      XCTAssertFalse(self.app.buttons["finish-graphic-selection"].exists)
      try self.leaf(0)
    }
    let from = coordinate(300, 300), to = coordinate(300, 500)
    try step("move-whole-body", {
      from.press(forDuration: 0.01, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0)
    }) { try self.leaf(0, moved: true) }
    try step("tap-away-auto-applies", { coordinate(700, 900).tap() }) {
      XCTAssertFalse(self.app.buttons["delete-agent-element"].exists)
      try self.leaf(0, moved: true)
    }
    try step("take-moved-material-again", { coordinate(300, 500).tap() }) {
      XCTAssertTrue(self.app.buttons["delete-agent-element"].isHittable)
    }
    try step("delete-without-confirmation", { app.buttons["delete-agent-element"].tap() }) { try self.leaf(0, deleted: true) }
    try step("deleted-page-away", { surface.swipeLeft() }) { try self.leaf(1) }
    try step("deleted-page-back", { surface.swipeRight() }) { try self.leaf(0, deleted: true) }
    try leave()
    app.terminate(); app.launchArguments.append("--notebook-reopen-fixture"); app.launch()
    XCTAssertTrue(cover.waitForExistence(timeout: 8))
    try open(deleted: true)
  }

  func testNewPageAcceptsFirstTextContactAndKeepsItOnThatPage() throws {
    try launch(); try open()
    for number in 1...5 { try step("prepare-page-\(number + 1)", { surface.swipeLeft() }) { try self.leaf(number) } }
    try step("create-page-by-real-curl", { surface.swipeLeft() }) {
      XCTAssertTrue((self.surface.value as? String)?.hasPrefix("Страница 7 из ") == true)
      try self.pixels([(300, 300, .paper), (590, 590, .paper), (630, 830, .paper)])
    }
    app.buttons["drawing-tools-more"].tap(); app.buttons["drawing-tool-text"].tap()
    try step("first-contact-on-new-page", { coordinate(240, 350).tap() }) {
      XCTAssertTrue(self.app.textViews["native-text-editor"].isHittable)
    }
    let text = "NEW LEAF ONLY"
    app.textViews["native-text-editor"].typeText(text)
    // The keyboard covers the lower sheet. Dismiss on exposed paper, not on a key.
    try step("text-auto-apply", { coordinate(700, 200).tap() }) {
      XCTAssertFalse(self.app.textViews["native-text-editor"].exists)
      XCTAssertTrue(self.app.staticTexts[text].exists)
    }
    app.buttons["pen-controls-toggle"].tap()
    try step("new-text-not-on-previous-leaf", { surface.swipeRight() }) {
      try self.leaf(5); XCTAssertFalse(self.app.staticTexts[text].exists)
    }
    try step("return-to-new-text", { surface.swipeLeft() }) {
      XCTAssertTrue(self.app.staticTexts[text].exists)
      XCTAssertTrue((self.surface.value as? String)?.hasPrefix("Страница 7 из ") == true)
    }
  }

  func testMenusBackgroundAndRotationKeepFirstContactAndPageNavigation() throws {
    defer { XCUIDevice.shared.orientation = .portrait }
    try launch(); try open()
    for id in ["drawing-tool-eraser", "drawing-tool-lasso", "pen-controls-toggle"] {
      app.buttons[id].tap(); app.buttons[id].tap()
      // Dismiss by a real outside tap, never by closing an injected sheet.
      coordinate(720, 900).tap()
      try step("first-selection-after-\(id)", { app.images["Journey movable 1"].tap() }) {
        XCTAssertTrue(self.app.buttons["delete-agent-element"].isHittable); try self.leaf(0)
      }
      coordinate(720, 900).tap()
    }
    XCUIDevice.shared.press(.home); app.activate()
    try step("first-turn-after-background", { surface.swipeLeft() }) { try self.leaf(1) }
    XCUIDevice.shared.orientation = .landscapeLeft
    paperFrame = fittedPaper(in: app.frame)
    try leaf(1)
    try step("first-turn-after-rotation", { surface.swipeRight() }) { try self.leaf(0) }
    XCUIDevice.shared.orientation = .portrait
    paperFrame = fittedPaper(in: app.frame)
    try step("first-selection-after-rotation", { app.images["Journey movable 1"].tap() }) {
      XCTAssertTrue(self.app.buttons["delete-agent-element"].isHittable); try self.leaf(0)
    }
  }

  private func launch() throws {
    continueAfterFailure = false; executionTimeAllowance = 180
    app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-workspace-journey-fixture"]
    app.launch(); XCUIDevice.shared.orientation = .portrait
    XCTAssertTrue(cover.waitForExistence(timeout: 10), app.debugDescription)
    XCTAssertTrue(app.buttons["create-workspace-item"].isHittable)
    XCTAssertFalse(surface.exists, "The scenario must start on the board, not on a pre-opened sheet")
    paperFrame = fittedPaper(in: app.frame) // Freeze before input, not from a possibly displaced result.
  }
  private func fittedPaper(in viewport: CGRect) -> CGRect {
    let scale = min(viewport.width / 834, viewport.height / 1194)
    return CGRect(x: viewport.midX - 417 * scale, y: viewport.midY - 597 * scale, width: 834 * scale, height: 1194 * scale)
  }
  private func coordinate(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
    app.coordinate(withNormalizedOffset: .zero).withOffset(.init(dx: paperFrame.minX + x * paperFrame.width / 834 - app.frame.minX,
      dy: paperFrame.minY + y * paperFrame.height / 1194 - app.frame.minY))
  }
  private func open(deleted: Bool = false) throws {
    try step("ordinary-cover-double-tap", { cover.doubleTap() }) {
      XCTAssertTrue(self.surface.exists)
      XCTAssertTrue(self.app.buttons["pen-controls-toggle"].isHittable)
      XCTAssertTrue(self.app.buttons["next-page"].isHittable)
      try self.leaf(0, deleted: deleted)
    }
  }
  private func turn(_ name: String, to index: Int, action: () -> Void) throws {
    try step(name, {
      action()
      // XCTest's swipe returns while UIKit's curl is still in flight. Await
      // that native landing, then inspect its FIRST composition without retry.
      let landed = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "value BEGINSWITH %@", "Страница \(index + 1) из "), object: surface)
      XCTAssertEqual(XCTWaiter.wait(for: [landed], timeout: 2), .completed, "The native curl did not land")
    }) { try self.leaf(index) }
  }
  private func leave() throws {
    try step("back-to-board", { app.buttons["leave-nested-board"].tap() }) {
      XCTAssertFalse(self.surface.exists); XCTAssertTrue(self.cover.isHittable)
      XCTAssertTrue(self.app.buttons["create-workspace-item"].isHittable)
    }
  }
  private enum Color {
    case red, blue, black, paper
    func matches(_ p: [UInt8]) -> Bool {
      switch self {
      case .red: p[0] > 180 && p[1] < 110 && p[2] < 110
      case .blue: p[0] < 100 && p[1] < 180 && p[2] > 180
      case .black: p.prefix(3).allSatisfy { $0 < 80 }
      case .paper: p.prefix(3).allSatisfy { $0 > 220 }
      }
    }
  }
  private var currentScreenshot: XCUIScreenshot?
  private func leaf(_ index: Int, moved: Bool = false, deleted: Bool = false) throws {
    let folio = surface.value as? String
    XCTAssertTrue(folio?.hasPrefix("Страница \(index + 1) из ") == true,
      "Expected leaf \(index + 1), displayed folio: \(folio ?? "missing")")
    let dy: CGFloat = moved ? 200 : 0
    var probes: [(CGFloat, CGFloat, Color)] = []
    for x: CGFloat in [180, 220, 440, 460] {
      for y: CGFloat in [280, 310, 390, 420] { probes.append((x, y + dy, deleted ? .paper : .red)) }
    }
    if moved || deleted { probes += [(200, 300, .paper), (450, 400, .paper)] }
    if deleted { probes += [(200, 500, .paper), (450, 610, .paper)] }
    probes += [(560, 560, .blue), (620, 620, .blue)]
    for slot in 0..<6 {
      probes.append((130 + CGFloat(slot) * 100, 820, slot == index ? .blue : .paper))
      probes.append((220, 660 + CGFloat(slot) * 16, slot == index ? .black : .paper))
    }
    try pixels(probes)
  }
  private func pixels(_ probes: [(CGFloat, CGFloat, Color)]) throws {
    let shot = currentScreenshot ?? app.screenshot()
    let image = try XCTUnwrap(shot.image.cgImage), screen = app.frame
    let sx = CGFloat(image.width) / screen.width, sy = CGFloat(image.height) / screen.height
    for (x, y, color) in probes {
      let point = CGPoint(x: (paperFrame.minX + x * paperFrame.width / 834 - screen.minX) * sx,
        y: (paperFrame.minY + y * paperFrame.height / 1194 - screen.minY) * sy)
      let crop = try XCTUnwrap(image.cropping(to: .init(x: point.x.rounded(), y: point.y.rounded(), width: 1, height: 1)))
      var rgba = [UInt8](repeating: 0, count: 4)
      try rgba.withUnsafeMutableBytes { b in
        let context = try XCTUnwrap(CGContext(data: b.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
          bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(crop, in: .init(x: 0, y: 0, width: 1, height: 1))
      }
      XCTAssertTrue(color.matches(rgba), "Wrong displayed material at page (\(x), \(y)): \(rgba)")
    }
  }
  private func step(_ name: String, _ action: () -> Void, verify: () throws -> Void) throws {
    let start = ContinuousClock.now
    action()
    let shot = app.screenshot(); currentScreenshot = shot
    let image = XCTAttachment(screenshot: shot); image.name = name; image.lifetime = .keepAlways; add(image)
    defer { currentScreenshot = nil }
    let elapsed = start.duration(to: .now)
    let evidence = XCTAttachment(string: "\(name): XCTest action + screenshot = \(elapsed). This includes automation idling, NOT input-to-photon latency.")
    evidence.name = name + "-automation-duration"; evidence.lifetime = .keepAlways; add(evidence)
    // A coarse automation watchdog only. The strict 20-ms/100-ms native gates
    // remain separate; no fake millisecond verdict derived from AX roundtrips.
    XCTAssertLessThan(elapsed, .seconds(10), "Stalled user sequence: \(name)")
    XCTAssertEqual(app.state, .runningForeground)
    XCTAssertFalse(app.otherElements["persistence-failure"].exists)
    try verify() // First post-action composition: no eventual-correct retry loop.
  }
}

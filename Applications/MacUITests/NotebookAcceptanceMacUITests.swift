import AppKit
import XCTest

/// Drives the exact installed private application, not another run with the same bundle ID.
@MainActor final class NotebookAcceptanceMacUITests: XCTestCase {
  private var application: XCUIApplication!
  private var applicationURL: URL!

  override func setUp() async throws {
    let path = try XCTUnwrap(ProcessInfo.processInfo.environment["NOTEBOOK_ACCEPTANCE_MAC_APPLICATION"])
    // The test belongs to its attested application path and checkout-specific
    // bundle, never an arbitrary running helper.
    applicationURL = URL(fileURLWithPath: path).standardizedFileURL
    application = XCUIApplication(url: applicationURL)
  }

  private func activatePrivateApplication() throws {
    application.launchEnvironment["NOTEBOOK_ACCEPTANCE_MANIFEST"] = try XCTUnwrap(
      ProcessInfo.processInfo.environment["NOTEBOOK_ACCEPTANCE_MANIFEST"])
    if application.state == .notRunning { application.launch() }
    let instances = NSWorkspace.shared.runningApplications.filter {
      $0.bundleURL?.standardizedFileURL == applicationURL
    }
    XCTAssertEqual(instances.count, 1, "Only the attested application may receive input")
    let instance = try XCTUnwrap(instances.first)
    // XCTest owns activation of its exact attested application. A background
    // runner's NSRunningApplication.activate request may not be honored.
    application.activate()
    let active = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in instance.isActive }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [active], timeout: 5), .completed)
  }

  private func devicesWindow() throws -> XCUIElement {
    continueAfterFailure = false
    try activatePrivateApplication()
    let window = application.windows["notebook.devices.window"]
    if !window.exists {
      let item = application.menuBars.statusItems.firstMatch
      XCTAssertTrue(item.waitForExistence(timeout: 15), application.debugDescription)
      item.click()
      let devices = application.menuItems["notebook.devices.open"]
      XCTAssertTrue(devices.waitForExistence(timeout: 5), application.debugDescription)
      devices.click()
    }
    XCTAssertTrue(window.waitForExistence(timeout: 5), application.debugDescription)
    return window
  }

  func testDevicesStatusDoesNotRequireSetupOrChangeTheClipboard() throws {
    let previous = NSPasteboard.general.changeCount
    let window = try devicesWindow()
    XCTAssertTrue(window.descendants(matching: .any).matching(identifier: "notebook.devices.status").firstMatch.waitForExistence(timeout: 5))
    XCTAssertFalse(window.textFields.firstMatch.exists)
    XCTAssertFalse(window.buttons["Скопировать приглашение для iPad"].exists)
    XCTAssertEqual(NSPasteboard.general.changeCount, previous)
    let proof = XCTAttachment(screenshot: application.screenshot())
    proof.name = "automatic-devices-status"; proof.lifetime = .keepAlways; add(proof)
  }

  func testInteractiveSourceIsVisibleInLaTeXAndProgramsWithoutChangingPaper() throws {
    continueAfterFailure = false
    let id = try XCTUnwrap(ProcessInfo.processInfo.environment["NOTEBOOK_ACCEPTANCE_DOCUMENT_ID"].flatMap(UUID.init(uuidString:)))
    let title = try XCTUnwrap(ProcessInfo.processInfo.environment["NOTEBOOK_ACCEPTANCE_DOCUMENT_TITLE"])
    try activatePrivateApplication()
    let back = application.buttons["mac-workspace-back"]
    if back.exists && back.isEnabled { back.click() }
    let cover = application.buttons["workspace-item-" + id.uuidString.lowercased()]
    XCTAssertTrue(cover.waitForExistence(timeout: 15)); cover.doubleClick()
    let window = application.windows[title]
    XCTAssertTrue(window.waitForExistence(timeout: 15))
    XCTAssertTrue(window.buttons["mac-workspace-back"].isEnabled, "The exact public document, not its board, must be open")
    window.menuButtons["mac-reading-zoom"].click()
    application.menuItems["По ширине"].click()
    let paper = window.webViews.firstMatch
    XCTAssertTrue(paper.waitForExistence(timeout: 30))
    let originalPaper = paper.frame.size
    XCTAssertGreaterThan(originalPaper.width, window.frame.width * 0.8)
    let originalPixels = window.screenshot()
    let originalPaperWidth = try visiblePaperWidth(originalPixels, windowWidth: window.frame.width)
    XCTAssertGreaterThan(originalPaperWidth, window.frame.width * 0.8)
    let original = XCTAttachment(screenshot: originalPixels)
    original.name = "paper-before-source-mode-round-trip"; original.lifetime = .keepAlways; add(original)
    for mode in ["Рядом", "Код"] {
      window.radioButtons[mode].click()
      let source = window.menuButtons["Документ LaTeX"]
      XCTAssertTrue(source.waitForExistence(timeout: 5))
      XCTAssertLessThan(source.frame.minY, window.frame.minY + 130,
        "The source toolbar belongs at the top, not in a short vertically centered strip")
      let text = window.textViews.firstMatch
      let generated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
        (text.value as? String)?.contains("Notebook interactive block: \"sound\"") == true
          && (text.value as? String)?.contains("notebook.ready") == true
      }, object: nil)
      XCTAssertEqual(XCTWaiter.wait(for: [generated], timeout: 15), .completed,
        "The actual compiled LaTeX must expose the interactive source, not hide it behind an empty state")
      XCTAssertTrue(window.buttons["Найти в исходнике"].exists)
      let screenshot = XCTAttachment(screenshot: window.screenshot())
      screenshot.name = "interactive-latex-source-" + mode; screenshot.lifetime = .keepAlways; add(screenshot)
    }
    window.menuButtons["Документ LaTeX"].click(); application.menuItems["Программа · sound"].click()
    let actualProgram = window.textViews.firstMatch
    let executable = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      (actualProgram.value as? String)?.contains("notebook.ready") == true
        && (actualProgram.value as? String)?.contains("% Notebook interactive block:") == false
    }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [executable], timeout: 5), .completed)
    let program = XCTAttachment(screenshot: window.screenshot())
    program.name = "actual-program-javascript"; program.lifetime = .keepAlways; add(program)
    window.radioButtons["Лист"].click()
    XCTAssertTrue(paper.waitForExistence(timeout: 5))
    XCTAssertEqual(paper.frame.width, originalPaper.width, accuracy: 1,
      "Returning to paper must restore its width without a hidden horizontal scale")
    XCTAssertEqual(paper.frame.height, originalPaper.height, accuracy: 1)
    let restoredPixels = window.screenshot()
    XCTAssertEqual(try visiblePaperWidth(restoredPixels, windowWidth: window.frame.width), originalPaperWidth, accuracy: 2,
      "Actual paper pixels, not only WebKit accessibility bounds, must retain their width")
    let restored = XCTAttachment(screenshot: restoredPixels)
    restored.name = "paper-after-source-mode-round-trip"; restored.lifetime = .keepAlways; add(restored)
  }

  func testReadingScrollMovesLiveContentWithThePaper() throws {
    continueAfterFailure = false
    let id = try XCTUnwrap(ProcessInfo.processInfo.environment["NOTEBOOK_ACCEPTANCE_DOCUMENT_ID"].flatMap(UUID.init(uuidString:)))
    let title = try XCTUnwrap(ProcessInfo.processInfo.environment["NOTEBOOK_ACCEPTANCE_DOCUMENT_TITLE"])
    try activatePrivateApplication()
    let back = application.buttons["mac-workspace-back"]
    if back.exists && back.isEnabled { back.click() }
    let cover = application.buttons["workspace-item-" + id.uuidString.lowercased()]
    XCTAssertTrue(cover.waitForExistence(timeout: 15)); cover.doubleClick()
    let window = application.windows[title]
    XCTAssertTrue(window.waitForExistence(timeout: 15))
    window.menuButtons["mac-reading-zoom"].click()
    application.menuItems["По ширине"].click()
    let heading = window.webViews.staticTexts["Звук — движение без переноса"].firstMatch
    XCTAssertTrue(heading.waitForExistence(timeout: 30)); XCTAssertTrue(heading.isHittable)
    let top = heading.frame
    func capture(_ name: String) {
      let attachment = XCTAttachment(screenshot: window.screenshot())
      attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    capture("sound-scroll-top")
    let margin = window.coordinate(withNormalizedOffset: .init(dx: 0.95, dy: 0.65))
    margin.scroll(byDeltaX: 0, deltaY: -120)
    let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      heading.frame.minY < top.minY - 60
    }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 5), .completed,
      "Live content must leave its old screen position with the paper, not stick below the titlebar")
    capture("sound-scroll-bottom")
    margin.scroll(byDeltaX: 0, deltaY: 120)
    let returned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      abs(heading.frame.minY - top.minY) < 2 && heading.isHittable
    }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 5), .completed)
    XCTAssertEqual(heading.frame.width, top.width, accuracy: 1)
    capture("sound-scroll-returned")
  }

  func testReadingFitsAndScrollsToTheBottomWithoutAnOutsideFooter() throws {
    continueAfterFailure = false
    let id = try XCTUnwrap(ProcessInfo.processInfo.environment["NOTEBOOK_ACCEPTANCE_DOCUMENT_ID"].flatMap(UUID.init(uuidString:)))
    let title = try XCTUnwrap(ProcessInfo.processInfo.environment["NOTEBOOK_ACCEPTANCE_DOCUMENT_TITLE"])
    try activatePrivateApplication()
    let back = application.buttons["mac-workspace-back"]
    if back.exists && back.isEnabled { back.click() }
    let cover = application.buttons["workspace-item-" + id.uuidString.lowercased()]
    XCTAssertTrue(cover.waitForExistence(timeout: 15)); cover.doubleClick()
    let window = application.windows[title], paper = window.webViews.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 15)); XCTAssertTrue(paper.waitForExistence(timeout: 30))
    for fit in ["Вся страница", "По ширине"] {
      window.menuButtons["mac-reading-zoom"].click(); application.menuItems[fit].click()
      if fit == "По ширине" {
        window.coordinate(withNormalizedOffset: .init(dx: 0.99, dy: 0.65)).scroll(byDeltaX: 0, deltaY: -10_000)
      }
      let aligned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
        abs(paper.frame.maxY-window.frame.maxY) <= 1
      }, object: nil)
      XCTAssertEqual(XCTWaiter.wait(for: [aligned], timeout: 5), .completed,
        "The physical bottom of the paper must meet the reader edge, not reserve a gray footer")
      let attachment = XCTAttachment(screenshot: window.screenshot())
      attachment.name = "paper-bottom-" + fit; attachment.lifetime = .keepAlways; add(attachment)
    }
  }

  /// The public Sound document has white paper on the gray reader canvas.
  /// WebKit's remote AX frame alone can miss an ancestor's bounds transform.
  private func visiblePaperWidth(_ screenshot: XCUIScreenshot, windowWidth: CGFloat) throws -> CGFloat {
    let image = try XCTUnwrap(screenshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    return try pixels.withUnsafeMutableBytes { bytes in
      let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      let scale = CGFloat(width) / windowWidth
      let inset = Int(100 * scale) // Exclude the white toolbar and window edges.
      var widest = 0
      for y in stride(from: inset, to: height - inset, by: 4) {
        var run = 0
        for x in 0..<width {
          let offset = (y * width + x) * 4
          if bytes[offset] > 248 && bytes[offset + 1] > 248 && bytes[offset + 2] > 248 {
            run += 1; widest = max(widest, run)
          } else { run = 0 }
        }
      }
      return CGFloat(widest) / scale
    }
  }

  /// This document is authored through the installed public MCP before the
  /// scenario. No fixture injection or synthetic DOM events stand in for UI.
  func testPublicScientificDocumentRetainsARealControlEditAfterReopening() throws {
    continueAfterFailure = false
    let environment = ProcessInfo.processInfo.environment
    let id = try XCTUnwrap(environment["NOTEBOOK_ACCEPTANCE_DOCUMENT_ID"].flatMap(UUID.init(uuidString:)))
    let title = try XCTUnwrap(environment["NOTEBOOK_ACCEPTANCE_DOCUMENT_TITLE"])
    try activatePrivateApplication()
    let back = application.buttons["mac-workspace-back"]
    if back.exists && back.isEnabled { back.click() }
    let cover = application.buttons["workspace-item-" + id.uuidString.lowercased()]
    XCTAssertTrue(cover.waitForExistence(timeout: 15), application.debugDescription)
    XCTAssertTrue(cover.label.contains(title), "The exact private document identifies this application instance")
    XCTAssertTrue(cover.isHittable, application.debugDescription); cover.doubleClick()
    let zoom = application.menuButtons["mac-reading-zoom"]
    XCTAssertTrue(zoom.waitForExistence(timeout: 15)); zoom.click()
    application.menuItems["Вся страница"].click()
    let control = application.webViews.sliders["Разность частот"]
    XCTAssertTrue(control.waitForExistence(timeout: 30), application.debugDescription)
    XCTAssertTrue(control.isEnabled)
    XCTAssertTrue(control.isHittable)
    let before = try XCTUnwrap(control.value as? NSNumber).doubleValue
    XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.bundleURL?.standardizedFileURL, applicationURL,
      "The shared desktop must still belong to this UI attempt")
    control.click(); control.typeKey(.rightArrow, modifierFlags: [])
    XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.bundleURL?.standardizedFileURL, applicationURL,
      "An external focus change invalidates this input attempt")
    // Clicking focuses the range and may select its middle. A repeat must
    // still produce a different accepted value, not just reopen the old one.
    if (control.value as? NSNumber)?.doubleValue == before { control.typeKey(.rightArrow, modifierFlags: []) }
    let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      (control.value as? NSNumber).map { $0.doubleValue != before } ?? false
    }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
    let accepted = try XCTUnwrap(control.value as? NSNumber).doubleValue
    let proof = XCTAttachment(screenshot: application.screenshot())
    proof.name = "public-scientific-control-real-mac-input"; proof.lifetime = .keepAlways; add(proof)
    back.click()
    XCTAssertTrue(cover.waitForExistence(timeout: 15)); XCTAssertTrue(cover.isHittable); cover.doubleClick()
    XCTAssertTrue(control.waitForExistence(timeout: 30))
    XCTAssertEqual(try XCTUnwrap(control.value as? NSNumber).doubleValue, accepted, accuracy: 0.000001)
    let restored = XCTAttachment(screenshot: application.screenshot())
    restored.name = "public-scientific-control-reopened"; restored.lifetime = .keepAlways; add(restored)
  }
}

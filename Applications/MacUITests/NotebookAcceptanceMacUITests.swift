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

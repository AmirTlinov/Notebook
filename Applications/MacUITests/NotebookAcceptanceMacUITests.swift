import AppKit
import XCTest

/// Devices is informational; opening it never starts a setup procedure.
@MainActor final class NotebookAcceptanceMacUITests: XCTestCase {
  private var application: XCUIApplication!

  override func setUpWithError() throws {
    let path = try XCTUnwrap(ProcessInfo.processInfo.environment["NOTEBOOK_ACCEPTANCE_MAC_APPLICATION"])
    // Several isolated runs may share a bundle identifier. The test belongs
    // to its attested application path, never an arbitrary running helper.
    application = XCUIApplication(url: URL(fileURLWithPath: path))
  }

  private func devicesWindow() throws -> XCUIElement {
    continueAfterFailure = false
    let manifest = try XCTUnwrap(ProcessInfo.processInfo.environment["NOTEBOOK_ACCEPTANCE_MANIFEST"])
    if application.state == .notRunning {
      application.launchEnvironment["NOTEBOOK_ACCEPTANCE_MANIFEST"] = manifest
      application.launch()
    } else { application.activate() }
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
}

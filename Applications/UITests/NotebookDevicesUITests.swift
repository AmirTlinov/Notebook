import XCTest

@MainActor final class NotebookDevicesUITests: XCTestCase {
  func testDevicesIsAnOptionalStatusSheetWithoutAnInvitationForm() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-compact-chat-fixture"]
    app.launch()
    let menu = app.buttons["notebook-chat-menu"]
    if !menu.waitForExistence(timeout: 3) {
      let compose = app.buttons["notebook-companion-compose"]
      XCTAssertTrue(compose.waitForExistence(timeout: 10)); compose.tap()
    }
    XCTAssertTrue(menu.waitForExistence(timeout: 5)); menu.tap()
    let devices = app.buttons["Устройства"]
    XCTAssertTrue(devices.waitForExistence(timeout: 5)); devices.tap()
    let status = app.descendants(matching: .any).matching(identifier: "notebook.devices.status").firstMatch
    XCTAssertTrue(status.waitForExistence(timeout: 5))
    XCTAssertFalse(app.textFields["Приглашение Notebook"].exists)
    XCTAssertFalse(app.buttons["Подключиться"].exists)
    XCTAssertFalse(app.buttons["Обменяться сейчас"].exists)
    let proof = XCTAttachment(screenshot: app.screenshot())
    proof.name = "devices-without-setup"; proof.lifetime = .keepAlways; add(proof)
    app.buttons["Готово"].tap()
    XCTAssertTrue(status.waitForNonExistence(timeout: 5))
    XCTAssertTrue(menu.exists, "Closing status returns to the same working surface")
  }
}

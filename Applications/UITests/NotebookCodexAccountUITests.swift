import XCTest

@MainActor final class NotebookCodexAccountUITests: XCTestCase {
  func testDeviceCodeAndCancellationStayInsideTheSameSelectedComputer() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-stacked-board-fixture", "--notebook-chat-sync-fixture"]
    app.launch(); XCUIDevice.shared.orientation = .portrait
    let menu = app.buttons["notebook-chat-menu"]
    XCTAssertTrue(menu.waitForExistence(timeout: 15)); menu.tap()
    let account = app.buttons["codex-account-open"]
    XCTAssertTrue(account.waitForExistence(timeout: 5)); account.tap()
    let login = app.buttons["codex-account-sign-in"]
    XCTAssertTrue(login.waitForExistence(timeout: 5)); XCTAssertTrue(login.isEnabled); login.tap()
    let code = app.staticTexts["codex-account-device-code"]
    XCTAssertTrue(code.waitForExistence(timeout: 5)); XCTAssertEqual(code.label, "TEST-183")
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "codex-device-code-simulator"; attachment.lifetime = .keepAlways; add(attachment)
    app.buttons["Отменить вход"].tap()
    XCTAssertTrue(code.waitForNonExistence(timeout: 5))
    XCTAssertTrue(login.isEnabled)
    app.buttons["Готово"].tap()
    XCTAssertTrue(menu.waitForExistence(timeout: 5))
  }
}

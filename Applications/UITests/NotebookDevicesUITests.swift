import XCTest

@MainActor final class NotebookDevicesUITests: XCTestCase {
  func testDevicesLivesInSpacesWithSearchAndWithoutAnInvitationForm() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-compact-chat-fixture"]
    app.launch()
    let spaces = app.buttons["workspaces-open"]
    XCTAssertTrue(spaces.waitForExistence(timeout:10)); spaces.tap()
    let tabs = app.segmentedControls["workspace-tabs"]
    XCTAssertTrue(tabs.waitForExistence(timeout:5)); tabs.buttons["Устройства"].tap()
    XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout:3))
    let status = app.descendants(matching: .any).matching(identifier: "notebook.devices.status").firstMatch
    XCTAssertTrue(status.waitForExistence(timeout: 5))
    XCTAssertFalse(app.textFields["Приглашение Notebook"].exists)
    XCTAssertFalse(app.buttons["Подключиться"].exists)
    XCTAssertFalse(app.buttons["Обменяться сейчас"].exists)
    let proof = XCTAttachment(screenshot: app.screenshot())
    proof.name = "devices-without-setup"; proof.lifetime = .keepAlways; add(proof)
    app.buttons["Готово"].tap()
    XCTAssertTrue(status.waitForNonExistence(timeout: 5))
    XCTAssertTrue(spaces.exists, "Closing spaces returns to the same working surface")
  }
}

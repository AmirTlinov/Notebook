import XCTest

@MainActor final class NotebookWorkspaceLibraryUITests: XCTestCase {
  func testCreateRenameSwitchAndDeleteSpacesThroughTheInterface() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--workspace-library-fixture", "--reset-workspace-library-fixture"]
    app.launch()
    func tap(_ button: XCUIElement) {
      let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true AND enabled == true"), object: button)
      XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
      button.tap()
    }
    func openLibrary() {
      let button = app.buttons["workspaces-open"]
      XCTAssertTrue(button.waitForExistence(timeout: 10)); tap(button)
      XCTAssertTrue(app.buttons["workspace-create"].waitForExistence(timeout: 10))
    }
    func name(_ value: String) {
      let field = app.textFields["workspace-name"]
      XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap()
      if let old = field.value as? String, !old.isEmpty, old != field.placeholderValue {
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
      }
      field.typeText(value)
      tap(app.buttons["workspace-name-save"])
      XCTAssertTrue(field.waitForNonExistence(timeout: 10), app.debugDescription)
    }
    func row(_ value: String) -> XCUIElement {
      app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "workspace-open-", value)).firstMatch
    }
    func remove(_ value: String) {
      let actions = app.buttons["Действия: " + value]
      XCTAssertTrue(actions.waitForExistence(timeout: 5)); actions.tap()
      app.buttons["Удалить с этого устройства…"].tap()
      let confirmation = app.alerts.buttons["Удалить"]
      XCTAssertTrue(confirmation.waitForExistence(timeout: 5)); confirmation.tap()
    }
    openLibrary()
    app.buttons["workspace-create"].tap(); name("Work")
    openLibrary()
    XCTAssertTrue(row("Work").exists)
    app.buttons["Действия: Work"].tap(); app.buttons["Переименовать"].tap(); name("Ideas")
    XCTAssertTrue(row("Ideas").waitForExistence(timeout: 5))
    row("Моё пространство").tap()
    openLibrary()
    remove("Ideas")
    XCTAssertFalse(row("Ideas").waitForExistence(timeout: 1))
    remove("Моё пространство")
    XCTAssertTrue(app.buttons["workspace-create"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["workspaces-open"].exists)
    let screen = XCTAttachment(screenshot: app.screenshot()); screen.name = "Empty vault library after explicit deletion"; screen.lifetime = .keepAlways; add(screen)
    app.terminate(); app.launchArguments = ["--workspace-library-fixture"]; app.launch()
    XCTAssertTrue(app.buttons["workspace-create"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["workspaces-open"].exists)
    app.buttons["workspace-create"].tap(); name("Again")
    XCTAssertTrue(app.buttons["workspaces-open"].waitForExistence(timeout: 10))
  }
}

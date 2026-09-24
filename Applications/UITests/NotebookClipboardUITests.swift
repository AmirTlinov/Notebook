import XCTest

@MainActor final class NotebookClipboardUITests: XCTestCase {
  func testTextPastesImmediatelyAndRemainsEditableAfterReopen() {
    paste(environment: ["NOTEBOOK_CLIPBOARD_TEXT": "Clipboard text"], label: "Clipboard text", name: "text")
  }
  func testStyledWebTextUsesPlainRepresentation() {
    paste(environment: ["NOTEBOOK_CLIPBOARD_HTML": "<b>Styled text</b>", "NOTEBOOK_CLIPBOARD_TEXT": "Styled text"], label: "Styled text", name: "styled-text")
  }
  func testImagePastesImmediatelyAsIndependentElement() {
    paste(environment: ["NOTEBOOK_CLIPBOARD_IMAGE": "1"], label: "Изображение", name: "image")
  }
  func testURLPastesWithoutStructuralImportScreen() {
    paste(environment: ["NOTEBOOK_CLIPBOARD_URL": "https://example.com/"], label: "<https://example.com/>", name: "url")
  }
  private func paste(environment: [String: String], label: String, name: String) {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-native-graphics-fixture", "--notebook-native-graphic-page"]
    app.launchEnvironment = environment
    app.launch()
    openNotebookCanvasMenu(in:app)
    let paste = app.buttons["clipboard-paste"]
    XCTAssertTrue(paste.waitForExistence(timeout: 3))
    XCTAssertFalse(app.staticTexts["Из tldraw"].exists)
    let menu = XCTAttachment(screenshot: app.screenshot()); menu.name = "compact-paste-\(name)"; menu.lifetime = .keepAlways; add(menu)
    paste.tap()
    XCTAssertTrue(paste.waitForNonExistence(timeout: 8))
    XCTAssertFalse(app.buttons["paste-insert"].exists, "Ordinary paste must not require a second import action")
    let element = app.images.matching(NSPredicate(format: "label == %@", label)).firstMatch
    XCTAssertTrue(element.waitForExistence(timeout: 10), app.debugDescription)
    let proof = XCTAttachment(screenshot: app.screenshot()); proof.name = "ordinary-paste-\(name)"; proof.lifetime = .keepAlways; add(proof)
    element.tap()
    XCTAssertTrue(app.otherElements["resize-agent-element-topLeading"].waitForExistence(timeout:3))
    app.terminate()
    app.launchArguments.append("--notebook-reopen-fixture")
    app.launch()
    XCTAssertTrue(element.waitForExistence(timeout: 10))
    element.tap()
    XCTAssertTrue(app.otherElements["resize-agent-element-topLeading"].waitForExistence(timeout:3))
    notebookContextAction("Удалить элемент",on:element,in:app)
    XCTAssertTrue(element.waitForNonExistence(timeout: 6))
  }
}

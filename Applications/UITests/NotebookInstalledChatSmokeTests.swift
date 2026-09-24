import XCTest

/// Explicit post-install readback against the retained production container.
/// Never sends a message, clears a draft, grants permissions or creates a chat.
@MainActor final class NotebookInstalledChatSmokeTests: XCTestCase {
  func testInstalledChatLoadsExistingCatalogueWithoutStorageError() {
    continueAfterFailure = false
    guard ProcessInfo.processInfo.environment["NOTEBOOK_INSTALLED_CHAT_SMOKE"] == "1" else {
      XCTFail("This production readback requires explicit opt-in after installation")
      return
    }
    let app = XCUIApplication(bundleIdentifier: "com.amirtlinov.notebook.preview")
    app.activate()
    let header = app.buttons["notebook-chat-tasks"]
    if !header.exists {
      let open = app.buttons["notebook-companion-compose"]
      XCTAssertTrue(open.waitForExistence(timeout: 15)); open.tap()
    }
    let browser = app.descendants(matching: .any).matching(identifier: "notebook-chat-recents").firstMatch
    if !browser.exists { XCTAssertTrue(header.waitForExistence(timeout: 5)); header.tap() }
    let chats = app.segmentedControls["notebook-chat-browser-mode"].buttons["Чаты"]
    XCTAssertTrue(chats.waitForExistence(timeout: 5))
    if !chats.isSelected { chats.tap() }
    let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "notebook-chat-task-"))
      return rows.count > 0 || app.descendants(matching: .any).matching(identifier: "notebook-project-empty-chats").firstMatch.exists
    }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 45), .completed)
    let notice = app.staticTexts["notebook-chat-notice"]
    if notice.exists {
      XCTAssertFalse(notice.label.contains("first_message") || notice.label.contains("invalid_transaction"))
    }
    XCTAssertFalse(app.staticTexts["Загружаются чаты…"].exists)
    let proof = XCTAttachment(screenshot: app.screenshot())
    proof.name = "installed-chat-existing-catalogue"; proof.lifetime = .keepAlways; add(proof)
  }
}

import XCTest

/// System-routed gestures shared by UX scenarios, without model shortcuts.
@MainActor extension XCTestCase {
  func selectNotebookTool(_ tool:String,in app:XCUIApplication,settings:Bool = false) {
    let groupID = ["pen","marker"].contains(tool) ? "drawing-group"
      : ["shape","connector"].contains(tool) ? "figure-group" : nil
    if let groupID {
      let group=app.buttons[groupID]
      XCTAssertTrue(group.waitForExistence(timeout:5))
      if !group.isSelected { group.tap() }
      let choice=app.buttons["drawing-tool-"+tool]
      if !choice.exists { group.tap() }
      XCTAssertTrue(choice.waitForExistence(timeout:3));choice.tap()
      if !settings { dismissNotebookToolPanel(in:app) }
    } else {
      let button=app.buttons["drawing-tool-"+tool]
      XCTAssertTrue(button.waitForExistence(timeout:5))
      if !button.isSelected { button.tap() }
      if settings { button.tap() }
    }
  }
  func dismissNotebookToolPanel(in app:XCUIApplication) {
    app.coordinate(withNormalizedOffset:.zero).withOffset(.init(dx:30,dy:100)).tap()
    XCTAssertTrue(app.descendants(matching:.any).matching(identifier:"drawing-tool-options").firstMatch.waitForNonExistence(timeout:3))
  }
  func openNotebookCanvasMenu(in app:XCUIApplication) {
    XCTAssertTrue(app.wait(for:.runningForeground,timeout:12))
    // Fixture margins are blank; a real hold-up uses the production recognizer.
    app.coordinate(withNormalizedOffset:.init(dx:0.94,dy:0.8)).press(forDuration:0.5)
    XCTAssertTrue(app.otherElements["canvas-context-menu"].waitForExistence(timeout:3))
  }
  func notebookOffersCreation(in app:XCUIApplication) -> Bool {
    openNotebookCanvasMenu(in:app)
    let available=app.buttons["context-create-notebook"].exists
    app.coordinate(withNormalizedOffset:.init(dx:0.04,dy:0.2)).tap()
    XCTAssertTrue(app.otherElements["canvas-context-menu"].waitForNonExistence(timeout:3))
    return available
  }
  func notebookBack(in app:XCUIApplication) {
    openNotebookCanvasMenu(in:app)
    let back=app.buttons["leave-nested-board"]
    XCTAssertTrue(back.waitForExistence(timeout:3));back.tap()
  }
  func selectNotebookDocumentMode(_ mode: String, in app: XCUIApplication) {
    let picker = app.segmentedControls["document-view-mode"]
    XCTAssertTrue(picker.waitForExistence(timeout: 8), app.debugDescription)
    let button = picker.buttons[mode]
    XCTAssertTrue(button.waitForExistence(timeout: 3), app.debugDescription)
    XCTAssertTrue(button.isHittable)
    button.tap()
    XCTAssertTrue(app.otherElements["canvas-context-menu"].waitForNonExistence(timeout: 3))
  }
  func selectNotebookDocumentFile(_ path: String, in app: XCUIApplication) {
    let menu = app.buttons["document-source-menu"]
    XCTAssertTrue(menu.waitForExistence(timeout: 5)); menu.tap()
    // The header also displays the current path. Only the presented menu's
    // collection owns a file-selection action.
    let file = app.collectionViews.buttons[path]
    XCTAssertTrue(file.waitForExistence(timeout: 5)); XCTAssertTrue(file.isHittable)
    file.tap()
  }
  func rotateNotebook(to orientation: UIDeviceOrientation, in app: XCUIApplication) {
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 12))
    XCUIDevice.shared.orientation = orientation
    let landscape = orientation == .landscapeLeft || orientation == .landscapeRight
    let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      let window = app.windows.firstMatch.frame
      return window.width > 0 && window.height > 0 && (window.width > window.height) == landscape
    }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 8), .completed,
      "The physical application window must complete the requested rotation before the next contact")
  }
  func notebookMenuItem(_ title:String,in app:XCUIApplication) -> XCUIElement {
    // UIKit presents the compact edit menu as MenuItem and its expanded native
    // list as Button. Both are the same system menu, not app fallback controls.
    app.descendants(matching:.any).matching(NSPredicate(format:"(elementType == %d OR elementType == %d) AND label == %@",
      XCUIElement.ElementType.menuItem.rawValue,XCUIElement.ElementType.button.rawValue,title)).firstMatch
  }
  func notebookMenuAction(_ title:String,in app:XCUIApplication) {
    let action=notebookMenuItem(title,in:app)
    for _ in 0..<12 {
      if action.exists && action.isHittable { action.tap();return }
      let next=app.buttons["Next Page"]
      guard next.exists && next.isHittable else { break }
      next.tap()
    }
    XCTFail("Context action unavailable: \(title)\n\(app.debugDescription)")
  }
  func notebookContextAction(_ title:String,on element:XCUIElement,in app:XCUIApplication) {
    openNotebookSelectionMenu(on:element,in:app)
    notebookMenuAction(title,in:app)
  }
  func openNotebookSelectionMenu(on element:XCUIElement,in app:XCUIApplication) {
    openNotebookSelectionMenu(at:element.coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.5)),in:app)
  }
  func openNotebookSelectionMenu(at coordinate:XCUICoordinate,in app:XCUIApplication) {
    coordinate.press(forDuration:0.5)
    XCTAssertTrue(notebookMenuItem("Копировать",in:app).waitForExistence(timeout:3))
  }
}

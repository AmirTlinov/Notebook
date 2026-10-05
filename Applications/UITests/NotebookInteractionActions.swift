import XCTest

/// System-routed gestures shared by UX scenarios, without model shortcuts.
@MainActor extension XCTestCase {
  func assertNotebookFullScreenPortrait(in app: XCUIApplication) {
    let application = app.frame, window = app.windows.firstMatch.frame
    let screen = XCUIScreen.main.screenshot()
    let image = screen.image
    let hierarchy = XCTAttachment(string:
      "application=\(application), window=\(window), screenImage=\(image.size), imageScale=\(image.scale)\n\(app.debugDescription)")
    hierarchy.name = "Before first contact: window and accessibility tree"
    hierarchy.lifetime = .keepAlways; add(hierarchy)
    let picture = XCTAttachment(screenshot: screen)
    picture.name = "Before first contact: physical screen"
    picture.lifetime = .keepAlways; add(picture)
    XCTAssertGreaterThan(window.width, 0)
    XCTAssertGreaterThan(window.height, window.width,
      "This gesture journey requires a full-screen portrait window before its first contact")
    XCTAssertEqual(window, application,
      "The app and its main window must share the gesture coordinate space")
    XCTAssertEqual(window.width / max(window.height, 1),
      image.size.width / max(image.size.height, 1), accuracy: 0.001,
      "The physical screen and app window differ: restore full-screen portrait before this journey")
  }

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
    // UIKit exposes native menu commands as MenuItem or Button.
    app.descendants(matching:.any).matching(NSPredicate(format:"(elementType == %d OR elementType == %d) AND label == %@",
      XCUIElement.ElementType.menuItem.rawValue,XCUIElement.ElementType.button.rawValue,title)).firstMatch
  }
  func notebookMenuAction(_ title:String,in app:XCUIApplication) {
    let panel=app.otherElements["notebook-context-menu"]
    let direct=panel.buttons.matching(NSPredicate(format:"label == %@",title)).firstMatch
    if direct.exists && direct.isHittable { direct.tap();return }
    let action=notebookMenuItem(title,in:app)
    if action.exists && action.isHittable { action.tap();return }
    // Secondary actions belong to the visible More button. Do not spend a
    // timeout looking for a command which has not been presented yet.
    let more=panel.buttons["selection-more-actions"]
    if more.exists && more.isHittable { more.tap() }
    if action.waitForExistence(timeout:3) && action.isHittable { action.tap();return }
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
    XCTAssertTrue(app.otherElements["notebook-context-menu"].waitForExistence(timeout:3),app.debugDescription)
  }
}

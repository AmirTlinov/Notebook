import XCTest

@MainActor final class NotebookPrintSourceUITests: XCTestCase {
  func testUnifiedTopBarOffersTwoPortraitModesAndThreeLandscapeModesWithoutOverlap() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-document-runtime-fixture"]
    app.launch()
    for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
      XCUIDevice.shared.orientation = orientation
      let code = app.buttons["Код"]
      XCTAssertTrue(code.waitForExistence(timeout: 30))
      let landscape = orientation == .landscapeLeft
      let modes = app.segmentedControls["document-view-mode"]
      let adapted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
        modes.buttons.count == (landscape ? 3 : 2)
      }, object: nil)
      XCTAssertEqual(XCTWaiter.wait(for: [adapted], timeout: 8), .completed)
      XCTAssertEqual(app.buttons["Рядом"].exists, landscape)
      let modeButtons = landscape ? [app.buttons["Лист"], app.buttons["Рядом"], code] : [app.buttons["Лист"], code]
      let controls = [app.buttons["leave-nested-board"]] + modeButtons +
        [app.buttons["pen-controls-toggle"], app.buttons["drawing-tool-eraser"], app.buttons["pen-settings"]]
      for (index, control) in controls.enumerated() {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: control)
        if XCTWaiter.wait(for: [ready], timeout: 8) != .completed {
          let tree = XCTAttachment(string: app.debugDescription); tree.name = "Toolbar accessibility"; tree.lifetime = .keepAlways; add(tree)
          let screen = XCTAttachment(screenshot: app.screenshot()); screen.name = "Toolbar failure"; screen.lifetime = .keepAlways; add(screen)
          XCTFail(control.description)
        }
        for other in controls.dropFirst(index+1) {
          XCTAssertFalse(control.frame.intersects(other.frame), "Overlapping controls: \(control.label), \(other.label)")
        }
      }
      (landscape ? app.buttons["Рядом"] : code).tap()
      let editor = app.textViews["document-source-editor"].firstMatch
      XCTAssertTrue(editor.waitForExistence(timeout: 10))
      XCTAssertGreaterThan(editor.frame.minY, controls.map { $0.frame.maxY }.max() ?? 0)
      let image = XCTAttachment(screenshot: app.screenshot()); image.name = "Unified toolbar \(orientation.rawValue)"; image.lifetime = .keepAlways; add(image)
      app.buttons["Лист"].tap()
    }
    XCUIDevice.shared.orientation = .portrait
  }

  func testRotatingBesideToPortraitKeepsCodeTextAndInsertionPoint() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-document-runtime-fixture"]
    XCUIDevice.shared.orientation = .landscapeLeft
    defer { XCUIDevice.shared.orientation = .portrait }
    app.launch()
    let beside = app.buttons["Рядом"]
    XCTAssertTrue(beside.waitForExistence(timeout: 30))
    beside.tap()
    let editor = app.textViews["document-source-editor"].firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 10))
    editor.tap()
    editor.typeText("RotationBefore")
    let before = editor.value as? String
    XCTAssertTrue(before?.contains("RotationBefore") == true)
    XCUIDevice.shared.orientation = .portrait
    let adapted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      !beside.exists && app.buttons["Код"].isSelected
    }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [adapted], timeout: 8), .completed)
    XCTAssertEqual(editor.value as? String, before)
    editor.typeText("After")
    XCTAssertEqual(editor.value as? String, before?.replacingOccurrences(of: "RotationBefore", with: "RotationBeforeAfter"))
    XCUIDevice.shared.orientation = .landscapeLeft
    XCTAssertTrue(beside.waitForExistence(timeout: 8))
    XCTAssertTrue(app.buttons["Код"].isSelected)
    XCTAssertTrue((editor.value as? String)?.contains("RotationBeforeAfter") == true)
  }

  func testNativeSourceAutosaveUndoAndReturnToTheSamePrintedDocument() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-document-runtime-fixture"]
    app.launch()
    let code = app.buttons["Код"]
    XCTAssertTrue(code.waitForExistence(timeout: 30), app.debugDescription)
    code.tap()
    let editor = app.textViews["document-source-editor"].firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 10), app.debugDescription)
    let original = editor.value as? String
    XCTAssertTrue(original?.contains("Живая математика") == true)
    editor.tap()
    editor.typeText("Canonical source edit\n\n")
    XCTAssertTrue((editor.value as? String)?.contains("Canonical source edit") == true)
    XCTAssertTrue(app.staticTexts["Сохранено"].waitForExistence(timeout: 15), app.debugDescription)
    app.buttons["Отменить действие"].tap()
    let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in editor.value as? String == original }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 15), .completed)
    app.buttons["Лист"].tap()
    XCTAssertFalse(editor.exists)
    let slider = app.webViews.sliders.firstMatch
    XCTAssertTrue(slider.waitForExistence(timeout: 15), app.debugDescription)
    let before = slider.value as? String
    XCTAssertTrue(slider.isHittable)
    slider.coordinate(withNormalizedOffset: .init(dx: 0.3, dy: 0.5)).press(forDuration: 0.05,
      thenDragTo: slider.coordinate(withNormalizedOffset: .init(dx: 0.7, dy: 0.5)),
      withVelocity: .slow, thenHoldForDuration: 0)
    let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in slider.value as? String != before }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
    let programValue = slider.value as? String
    let image = XCTAttachment(screenshot: app.screenshot())
    image.name = "Canonical paper after native source save and causal undo"
    image.lifetime = .keepAlways; add(image)
    app.buttons["Код"].tap()
    XCTAssertEqual(editor.value as? String, original)
    app.buttons["Лист"].tap()
    XCTAssertTrue(slider.waitForExistence(timeout: 15))
    XCTAssertEqual(slider.value as? String, programValue, "Code mode must retain the same live program and control state")
  }
}

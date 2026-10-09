import XCTest

@MainActor final class NotebookPrintSourceUITests: XCTestCase {
  func testDocumentModesStayReachableAcrossPaperEditorAndRotationWithoutOverlap() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-document-runtime-fixture"]
    defer { XCUIDevice.shared.orientation = .portrait }
    app.launch()
    let paper = app.otherElements["page-turn-surface"]
    XCTAssertTrue(paper.waitForExistence(timeout: 30))
    for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
      rotateNotebook(to: orientation, in: app)
      let landscape = orientation == .landscapeLeft
      XCTAssertEqual(app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height, landscape,
        "The compact header follows the completed native rotation")
      let modes = app.segmentedControls["document-view-mode"]
      XCTAssertTrue(modes.waitForExistence(timeout: 3))
      let adapted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
        modes.buttons.count == (landscape ? 3 : 2)
      }, object: nil)
      XCTAssertEqual(XCTWaiter.wait(for: [adapted], timeout: 8), .completed)
      XCTAssertEqual(app.buttons["Рядом"].exists, landscape)
      let fileMenu = app.buttons["document-source-menu"]
      let header = app.otherElements["document-source-header"]
      XCTAssertEqual(fileMenu.label, "Файлы документа")
      XCTAssertEqual(fileMenu.frame.width, 44, accuracy: 2)
      XCTAssertEqual(fileMenu.frame.height, 44, accuracy: 2)
      XCTAssertFalse(header.staticTexts["main.tex"].exists)
      let settledPaper = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
        guard paper.exists else { return false }
        let frame = paper.frame, window = app.windows.firstMatch.frame
        return frame.width > 0 && frame.height > 0
          && abs(frame.width / frame.height - 210.0 / 297.0) <= 0.005
          && abs(frame.midX - window.midX) <= 2 && abs(frame.midY - window.midY) <= 2
          && frame.minX >= window.minX - 2 && frame.maxX <= window.maxX + 2
          && frame.minY >= window.minY - 2 && frame.maxY <= window.maxY + 2
      }, object: nil)
      XCTAssertEqual(XCTWaiter.wait(for: [settledPaper], timeout: 8), .completed)
      XCTAssertEqual(paper.frame.width / paper.frame.height, 210.0 / 297.0, accuracy: 0.005,
        "A4 remains portrait paper in either device orientation")
      let paperGeometry = XCTAttachment(string: "paper=\(paper.frame), window=\(app.windows.firstMatch.frame), header=\(header.frame), orientation=\(orientation.rawValue)")
      paperGeometry.name = "A4 paper geometry \(orientation.rawValue)"; paperGeometry.lifetime = .keepAlways; add(paperGeometry)
      let paperImage = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
      paperImage.name = "A4 paper and compact header \(orientation.rawValue)"; paperImage.lifetime = .keepAlways; add(paperImage)
      let code = modes.buttons["Код"]
      let modeButtons = landscape ? [modes.buttons["Лист"], modes.buttons["Рядом"], code] : [modes.buttons["Лист"], code]
      let controls = [app.buttons["document-source-menu"]] + modeButtons
      for (index, control) in controls.enumerated() {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: control)
        if XCTWaiter.wait(for: [ready], timeout: 8) != .completed {
          let tree = XCTAttachment(string: app.debugDescription); tree.name = "Document mode accessibility"; tree.lifetime = .keepAlways; add(tree)
          let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); screen.name = "Document mode failure"; screen.lifetime = .keepAlways; add(screen)
          XCTFail(control.description)
        }
        for other in controls.dropFirst(index+1) {
          XCTAssertFalse(control.frame.intersects(other.frame), "Overlapping controls: \(control.label), \(other.label)")
        }
      }
      selectNotebookDocumentMode(landscape ? "Рядом" : "Код", in: app)
      let editor = app.textViews["document-source-editor"].firstMatch
      XCTAssertTrue(editor.waitForExistence(timeout: 10))
      XCTAssertEqual(modes.buttons.count, landscape ? 3 : 2)
      XCTAssertTrue(modes.buttons["Лист"].isHittable, "The editor must keep a direct route back when paper gestures are hidden")
      XCTAssertGreaterThanOrEqual(editor.frame.minY, modes.frame.maxY)
      XCTAssertFalse(modes.frame.intersects(app.buttons["document-source-menu"].frame))
      let drawingBar = app.otherElements["notebook-top-bar"]
      XCTAssertEqual(drawingBar.exists, landscape, "Drawing tools stay on the paper, never above full-screen code")
      if drawingBar.exists { XCTAssertFalse(app.otherElements["document-source-header"].frame.intersects(drawingBar.frame)) }
      for action in ["Отменить действие", "Обсудить выделенный исходник", "Найти в исходнике", "Показать на листе"] {
        XCTAssertFalse(app.buttons[action].exists, "The compact header must not retain replaced actions")
      }
      let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); image.name = "Document modes \(orientation.rawValue)"; image.lifetime = .keepAlways; add(image)
      selectNotebookDocumentMode("Лист", in: app)
      XCTAssertFalse(editor.exists)
    }
  }

  func testDocumentZoomOutReturnsToBoardAndReopensTheSamePaper() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-document-runtime-fixture"]
    app.launch()
    rotateNotebook(to:.portrait,in:app)
    let surface = app.otherElements["page-turn-surface"]
    XCTAssertTrue(surface.waitForExistence(timeout:30))
    let slider = app.webViews.sliders.firstMatch
    XCTAssertTrue(slider.waitForExistence(timeout:15))
    let value = slider.value as? String
    // Start both contacts in the typeset body, not in the native file header.
    app.buttons["Исходник: main.tex"].firstMatch.pinch(withScale:0.5,velocity:-1)
    XCTAssertTrue(surface.waitForNonExistence(timeout:5),"Zooming out must close the document")
    let closed = XCTAttachment(screenshot:app.screenshot()); closed.name="Document closed by pinch"; closed.lifetime = .keepAlways; add(closed)
    // Closing preserves the zoom-out below the cover boundary. Reopen from
    // that actual board scale rather than depending on the old snap back.
    app.pinch(withScale:3,velocity:1)
    XCTAssertTrue(surface.waitForExistence(timeout:15))
    XCTAssertTrue(slider.waitForExistence(timeout:15))
    XCTAssertEqual(slider.value as? String,value)
    let reopened = XCTAttachment(screenshot:app.screenshot()); reopened.name="Document reopened by pinch"; reopened.lifetime = .keepAlways; add(reopened)
  }

  func testRotatingBesideToPortraitKeepsCodeTextAndInsertionPoint() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-document-runtime-fixture"]
    defer { XCUIDevice.shared.orientation = .portrait }
    app.launch()
    XCTAssertTrue(app.otherElements["page-turn-surface"].waitForExistence(timeout: 30))
    rotateNotebook(to: .landscapeLeft, in: app)
    let beside = app.buttons["Рядом"]
    selectNotebookDocumentMode("Рядом", in: app)
    selectNotebookDocumentFile("main.tex", in: app)
    let editor = app.textViews["document-source-editor"].firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 10))
    editor.tap()
    editor.typeText("%RotationBefore")
    let before = editor.value as? String
    XCTAssertTrue(before?.contains("RotationBefore") == true)
    rotateNotebook(to: .portrait, in: app)
    let adapted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      !beside.exists && app.buttons["Код"].isSelected
    }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [adapted], timeout: 8), .completed)
    XCTAssertEqual(editor.value as? String, before)
    editor.typeText("After")
    XCTAssertEqual(editor.value as? String, before?.replacingOccurrences(of: "RotationBefore", with: "RotationBeforeAfter"))
    rotateNotebook(to: .landscapeLeft, in: app)
    XCTAssertTrue(beside.waitForExistence(timeout: 8))
    XCTAssertTrue(app.buttons["Код"].isSelected)
    XCTAssertTrue((editor.value as? String)?.contains("RotationBeforeAfter") == true)
  }

  func testNativeSourceAutosaveUndoAndReturnToTheSamePrintedDocument() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-document-runtime-fixture"]
    app.launch()
    XCTAssertTrue(app.otherElements["page-turn-surface"].waitForExistence(timeout: 30))
    selectNotebookDocumentMode("Код", in: app)
    selectNotebookDocumentFile("main.tex", in: app)
    let editor = app.textViews["document-source-editor"].firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 10), app.debugDescription)
    let original = editor.value as? String
    XCTAssertTrue(original?.contains("Живая математика") == true)
    // The native editor is the measured hit target, but its default AX point
    // can be {-1, -1} after the file menu. Touch the visible body directly.
    editor.coordinate(withNormalizedOffset: .init(dx: 0.35, dy: 0.25)).tap()
    editor.typeText("%Canonical source edit\n\n")
    XCTAssertTrue((editor.value as? String)?.contains("Canonical source edit") == true)
    XCTAssertTrue(app.staticTexts["Сохранено"].waitForExistence(timeout: 15), app.debugDescription)
    editor.twoFingerTap()
    let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in editor.value as? String == original }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 15), .completed)
    editor.tap(withNumberOfTaps: 1, numberOfTouches: 3)
    let repeated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      (editor.value as? String)?.contains("Canonical source edit") == true
    }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [repeated], timeout: 15), .completed)
    editor.twoFingerTap()
    let restoredAgain = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in editor.value as? String == original }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [restoredAgain], timeout: 15), .completed)
    XCTAssertTrue(app.staticTexts["document-print-status"].waitForNonExistence(timeout: 15))
    editor.doubleTap()
    // UIKit can place the source action on a later page of its native edit menu.
    XCTAssertTrue(app.menuItems.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
    notebookMenuAction("Показать на листе", in: app)
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
    let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    image.name = "Canonical paper after native source save and causal undo"
    image.lifetime = .keepAlways; add(image)
    selectNotebookDocumentMode("Код", in: app)
    XCTAssertEqual(editor.value as? String, original)
    selectNotebookDocumentMode("Лист", in: app)
    XCTAssertTrue(slider.waitForExistence(timeout: 15))
    XCTAssertEqual(slider.value as? String, programValue, "Code mode must retain the same live program and control state")
  }
}

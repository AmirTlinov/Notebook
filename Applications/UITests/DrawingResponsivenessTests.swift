import XCTest

@MainActor
final class DrawingResponsivenessTests: XCTestCase {
  func testPageFitSurvivesPortraitLandscapePortrait() async throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    try await Task.sleep(for: .milliseconds(450))
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture"]
    app.launch()

    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout: 5))
    let original = paper.frame

    XCUIDevice.shared.orientation = .landscapeLeft
    try await Task.sleep(for: .milliseconds(700))
    XCUIDevice.shared.orientation = .portrait
    try await Task.sleep(for: .milliseconds(900))

    let restored = paper.frame
    XCTAssertEqual(restored.midX, original.midX, accuracy: 2)
    XCTAssertEqual(restored.midY, original.midY, accuracy: 2)
    XCTAssertEqual(restored.width, original.width, accuracy: 2)
    XCTAssertEqual(restored.height, original.height, accuracy: 2)
  }

  func testPinchClosesThePageOntoTheBoard() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-simulator-finger-gestures",
    ]
    app.launch()

    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout: 5))
    let originalPaperFrame = paper.frame
    paper.pinch(withScale: 0.28, velocity: -2)

    XCTAssertTrue(
      app.buttons["create-notebook"].waitForExistence(timeout: 5),
      "После закрытия листа должна появиться бесконечная доска"
    )
    let boardProof = XCTAttachment(screenshot: app.screenshot())
    boardProof.name = "infinite-board"
    boardProof.lifetime = .keepAlways
    add(boardProof)

    let notebook = app.descendants(matching: .any)
      .matching(
        identifier: "notebook-7e7a1000-0000-4000-8000-000000000002"
      )
      .firstMatch
    XCTAssertTrue(notebook.waitForExistence(timeout: 3))
    notebook.pinch(withScale: 1.2, velocity: 0.4)
    XCTAssertTrue(
      app.buttons["create-notebook"].exists,
      "Небольшой щипок должен только приблизить доску"
    )
    notebook.pinch(withScale: 4, velocity: 2)
    XCTAssertTrue(
      paper.waitForExistence(timeout: 5),
      "Щипок над тетрадью должен снова открыть её лист"
    )
    XCTAssertEqual(paper.frame.midX, originalPaperFrame.midX, accuracy: 2)
    XCTAssertEqual(paper.frame.midY, originalPaperFrame.midY, accuracy: 2)
    XCTAssertEqual(paper.frame.width, originalPaperFrame.width, accuracy: 2)
    XCTAssertEqual(paper.frame.height, originalPaperFrame.height, accuracy: 2)
  }

  func testDoubleTapOpensAWholePageImmediately() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-simulator-finger-gestures",
    ]
    app.launch()

    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout: 5))
    let originalPaperFrame = paper.frame
    paper.pinch(withScale: 0.28, velocity: -2)
    XCTAssertTrue(app.buttons["create-notebook"].waitForExistence(timeout: 5))

    let notebook = app.descendants(matching: .any)
      .matching(
        identifier: "notebook-7e7a1000-0000-4000-8000-000000000002"
      )
      .firstMatch
    XCTAssertTrue(notebook.waitForExistence(timeout: 3))
    notebook.doubleTap()

    XCTAssertTrue(paper.waitForExistence(timeout: 3))
    XCTAssertEqual(paper.frame.midX, originalPaperFrame.midX, accuracy: 2)
    XCTAssertEqual(paper.frame.midY, originalPaperFrame.midY, accuracy: 2)
    XCTAssertEqual(paper.frame.width, originalPaperFrame.width, accuracy: 2)
    XCTAssertEqual(paper.frame.height, originalPaperFrame.height, accuracy: 2)
  }

  func testPenCommitsOneStrokeAndKeepsThePaperResponsive() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture"]
    app.launch()

    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout: 5))
    XCTAssertEqual(paper.value as? String, "80 штрихов")

    let start = paper.coordinate(
      withNormalizedOffset: CGVector(dx: 0.18, dy: 0.22)
    )
    let end = paper.coordinate(
      withNormalizedOffset: CGVector(dx: 0.82, dy: 0.34)
    )
    let dragStarted = ContinuousClock.now
    start.press(
      forDuration: 0.05,
      thenDragTo: end,
      withVelocity: .slow,
      thenHoldForDuration: 0
    )
    XCTAssertLessThan(
      ContinuousClock.now - dragStarted,
      .seconds(4),
      "Живой штрих не должен ждать PencilKit, файл или сеть"
    )

    let drawingChanged = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "81 штрихов"),
      object: paper
    )
    wait(for: [drawingChanged], timeout: 2)

    let controls = app.buttons["pen-controls-toggle"]
    XCTAssertTrue(controls.waitForExistence(timeout: 2))
    controls.tap()
    XCTAssertTrue(
      app.buttons["drawing-tool-eraser"].waitForExistence(timeout: 2)
    )
  }

  func testEraserKeepsDensePaperResponsive() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture"]
    app.launch()

    let controls = app.buttons["pen-controls-toggle"]
    XCTAssertTrue(controls.waitForExistence(timeout: 5))
    controls.tap()

    let eraser = app.buttons["drawing-tool-eraser"]
    XCTAssertTrue(eraser.waitForExistence(timeout: 2))
    eraser.tap()

    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout: 2))
    guard let initialValue = paper.value as? String else {
      XCTFail("Лист должен сообщать число штрихов")
      return
    }
    XCTAssertEqual(initialValue, "80 штрихов")
    let start = paper.coordinate(
      withNormalizedOffset: CGVector(dx: 0.12, dy: 0.48)
    )
    let end = paper.coordinate(
      withNormalizedOffset: CGVector(dx: 0.88, dy: 0.56)
    )
    let dragStarted = ContinuousClock.now
    start.press(
      forDuration: 0.05,
      thenDragTo: end,
      withVelocity: .slow,
      thenHoldForDuration: 0
    )
    XCTAssertLessThan(
      ContinuousClock.now - dragStarted,
      .seconds(6),
      "Ластик не должен ставить вычисление всего рисунка в очередь UI"
    )

    let responseStarted = ContinuousClock.now
    controls.tap()
    let controlsClosed = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@", "Настроить ручку"),
      object: controls
    )
    wait(for: [controlsClosed], timeout: 2)
    XCTAssertLessThan(ContinuousClock.now - responseStarted, .seconds(2))

    let drawingChanged = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value != %@", initialValue),
      object: paper
    )
    wait(for: [drawingChanged], timeout: 2)
  }
}

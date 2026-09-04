import CoreGraphics
import UIKit
import XCTest

@MainActor
final class DrawingResponsivenessTests: XCTestCase {
  func testPersonMovesAndDeletesAnAgentElement() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-agent-element-fixture",
    ]
    app.launch()

    let sharedElement = app.otherElements["agent-element-shared-element"]
    XCTAssertTrue(sharedElement.waitForExistence(timeout: 8))
    let initialFrame = sharedElement.frame

    let controls = app.buttons["pen-controls-toggle"]
    XCTAssertTrue(controls.waitForExistence(timeout: 3))
    controls.tap()
    let elementTool = app.buttons["element-editing-tool"]
    XCTAssertTrue(elementTool.waitForExistence(timeout: 3))
    elementTool.tap()

    sharedElement.tap()
    let delete = app.buttons["delete-agent-element"]
    XCTAssertTrue(
      delete.waitForExistence(timeout: 3),
      "Выбранный общий элемент должен показать действие удаления"
    )

    sharedElement.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      .press(
        forDuration: 0.05,
        thenDragTo: sharedElement.coordinate(
          withNormalizedOffset: CGVector(dx: 0.72, dy: 0.68)
        ),
        withVelocity: .slow,
        thenHoldForDuration: 0
      )
    XCTAssertGreaterThan(
      sharedElement.frame.midX,
      initialFrame.midX + 20,
      "Палец должен перемещать элемент в том же листе"
    )

    app.buttons["delete-agent-element"].tap()
    XCTAssertFalse(
      sharedElement.waitForExistence(timeout: 2),
      "Удаление должно убрать общий элемент с листа"
    )
  }

  func testDocumentTextOpensMarkdownEditorOnDoubleTap() async throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    try await Task.sleep(for: .milliseconds(350))
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-document-runtime-fixture",
    ]
    app.launch()

    let heading = app.staticTexts["Живая математика"].firstMatch
    XCTAssertTrue(
      heading.waitForExistence(timeout: 8),
      "Markdown должен стать читаемым текстом WebKit"
    )
    let firstPage = app.otherElements.matching(
      NSPredicate(format: "label BEGINSWITH 'Страница 1 из '")
    ).firstMatch
    XCTAssertTrue(firstPage.waitForExistence(timeout: 8))
    firstPage.coordinate(
      withNormalizedOffset: CGVector(dx: 0.32, dy: 0.16)
    ).doubleTap()

    let editor = app.textViews["Исходный Markdown или LaTeX"].firstMatch
    XCTAssertTrue(
      editor.waitForExistence(timeout: 5),
      "Двойное касание должно заменить блок одним редактором исходника"
    )
    // WKWebView honours the person's double tap, while XCUITest does not pass
    // that activation token to a textarea created during the same event. A
    // direct automation tap gives the synthesized keyboard the same focus a
    // real touch already has.
    editor.tap()
    editor.typeText("\n\nНовая строка\n\n")

    XCTAssertTrue(
      (editor.value as? String)?.contains("Новая строка") == true,
      "Редактор должен принимать Markdown с экранной клавиатуры"
    )
  }

  func testDocumentRuntimeRendersMarkdownLatexAndInteractiveContent() async throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    try await Task.sleep(for: .milliseconds(350))
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-document-runtime-fixture",
    ]
    app.launch()

    let runtime = app.descendants(matching: .any)
      .matching(identifier: "document-runtime")
      .firstMatch
    XCTAssertTrue(
      runtime.waitForExistence(timeout: 8),
      "Открытый документ должен создать один живой WebKit runtime"
    )
    try await Task.sleep(for: .seconds(2))
    XCTAssertEqual(
      app.state,
      .runningForeground,
      "Markdown, LaTeX и интерактивный блок должны жить без падения приложения"
    )

    let proof = XCTAttachment(screenshot: app.screenshot())
    proof.name = "document-markdown-latex-interactive"
    proof.lifetime = .keepAlways
    add(proof)
  }

  func testDocumentContentFlowsAcrossFiniteA4Pages() async throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    try await Task.sleep(for: .milliseconds(350))
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-document-runtime-fixture",
    ]
    app.launch()

    let firstPage = app.otherElements.matching(
      NSPredicate(format: "label BEGINSWITH 'Страница 1 из '")
    ).firstMatch
    XCTAssertTrue(
      firstPage.waitForExistence(timeout: 8),
      "WebKit должен разбить содержание на конечные листы"
    )
    let secondPage = app.otherElements.matching(
      NSPredicate(format: "label BEGINSWITH 'Страница 2 из '")
    ).firstMatch
    XCTAssertTrue(
      secondPage.waitForExistence(timeout: 3),
      "Длинный текст должен перейти на второй лист"
    )
    XCTAssertGreaterThan(
      secondPage.frame.minX,
      firstPage.frame.maxX,
      "Страницы должны быть отдельными листами, а не одной вертикальной лентой"
    )
    XCTAssertEqual(
      firstPage.frame.height / firstPage.frame.width,
      841.88976378 / 595.275590551,
      accuracy: 0.03,
      "Экранный лист должен сохранять физическую пропорцию A4"
    )
  }

  func testStoredDocumentPageBecomesTheVisiblePhysicalSheet() async throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    try await Task.sleep(for: .milliseconds(350))
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-document-runtime-fixture",
      "--notebook-document-page-three-fixture",
    ]
    app.launch()

    let thirdPage = app.otherElements.matching(
      NSPredicate(format: "label BEGINSWITH 'Страница 3 из '")
    ).firstMatch
    XCTAssertTrue(thirdPage.waitForExistence(timeout: 8))
    XCTAssertEqual(
      thirdPage.frame.midX,
      app.frame.midX,
      accuracy: 4,
      "SessionPresence должен поставить выбранный физический лист в центр"
    )

    let thirdPageMarker = app.staticTexts["Раздел 12"].firstMatch
    XCTAssertTrue(thirdPageMarker.waitForExistence(timeout: 3))
    XCTAssertTrue(
      app.frame.intersects(thirdPageMarker.frame),
      "На выбранном листе должен быть виден его собственный раздел"
    )
  }

  func testNotebookPageTurnCommitsBothDirections() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture"]
    app.launch()

    let surface = app.otherElements["page-turn-surface"]
    XCTAssertTrue(surface.waitForExistence(timeout: 5))
    surface.swipeLeft()

    let landed = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value BEGINSWITH 'Страница 2 из '"),
      object: surface
    )
    wait(for: [landed], timeout: 3)

    surface.swipeRight()
    let returned = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value BEGINSWITH 'Страница 1 из '"),
      object: surface
    )
    wait(for: [returned], timeout: 3)
    XCTAssertEqual(app.state, .runningForeground)
  }

  func testNotebookAcceptsTheNextTurnAsSoonAsThePreviousSheetLands() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture"]
    app.launch()

    let surface = app.otherElements["page-turn-surface"]
    XCTAssertTrue(surface.waitForExistence(timeout: 5))
    surface.swipeLeft()
    Thread.sleep(forTimeInterval: 0.25)
    surface.swipeLeft()
    Thread.sleep(forTimeInterval: 0.25)
    surface.swipeLeft()

    let landed = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value BEGINSWITH 'Страница 4 из '"),
      object: surface
    )
    wait(for: [landed], timeout: 3)
    XCTAssertEqual(app.state, .runningForeground)
  }

  func testDocumentPageTurnShowsTheCommittedPhysicalPage() async throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-document-runtime-fixture",
    ]
    app.launch()

    let surface = app.otherElements["page-turn-surface"]
    XCTAssertTrue(surface.waitForExistence(timeout: 8))
    let paginationReady = XCTNSPredicateExpectation(
      predicate: NSPredicate(
        format: "value BEGINSWITH 'Страница 1 из ' AND value != 'Страница 1 из 1'"
      ),
      object: surface
    )
    await fulfillment(of: [paginationReady], timeout: 3)
    try await Task.sleep(for: .seconds(2.5))
    surface.swipeLeft()

    let landed = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value BEGINSWITH 'Страница 2 из '"),
      object: surface
    )
    await fulfillment(of: [landed], timeout: 3)

    let secondPageMarker = app.staticTexts["Раздел 5"].firstMatch
    XCTAssertTrue(secondPageMarker.waitForExistence(timeout: 3))
    XCTAssertTrue(
      app.frame.intersects(secondPageMarker.frame),
      "После перелистывания на экране должен появиться раздел второго листа"
    )
  }

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
      app.buttons["create-workspace-item"].waitForExistence(timeout: 5),
      "После закрытия листа должна появиться бесконечная доска"
    )
    let boardProof = XCTAttachment(screenshot: app.screenshot())
    boardProof.name = "infinite-board"
    boardProof.lifetime = .keepAlways
    add(boardProof)

    let notebook = app.descendants(matching: .any)
      .matching(
        identifier: "workspace-item-7e7a1000-0000-4000-8000-000000000002"
      )
      .firstMatch
    XCTAssertTrue(notebook.waitForExistence(timeout: 3))
    let distantNotebookWidth = notebook.frame.width
    notebook.pinch(withScale: 1.2, velocity: 0.4)
    XCTAssertTrue(
      app.buttons["create-workspace-item"].exists,
      "Небольшой щипок должен только приблизить доску"
    )
    XCTAssertGreaterThan(notebook.frame.width, distantNotebookWidth)
    notebook.pinch(withScale: 1.4, velocity: 0.5)
    XCTAssertTrue(
      app.buttons["create-workspace-item"].exists,
      "Тетрадь вдали должна приближаться вместе с доской"
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
    XCTAssertTrue(app.buttons["create-workspace-item"].waitForExistence(timeout: 5))

    let notebook = app.descendants(matching: .any)
      .matching(
        identifier: "workspace-item-7e7a1000-0000-4000-8000-000000000002"
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

  func testDoubleTapCreatesAndReopensTextOnAFocusedCover() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-simulator-finger-gestures",
      "--notebook-nearby-cover-fixture",
    ]
    app.launch()

    let notebook = app.descendants(matching: .any)
      .matching(
        identifier: "workspace-item-7e7a1000-0000-4000-8000-000000000002"
      )
      .firstMatch
    XCTAssertTrue(notebook.waitForExistence(timeout: 5))
    notebook.doubleTap()

    let editor = app.descendants(matching: .any)
      .matching(identifier: "native-text-editor")
      .firstMatch
    XCTAssertTrue(
      editor.waitForExistence(timeout: 3),
      "Двойное касание близкой обложки должно сразу передать фокус тексту"
    )
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 2))
    editor.typeText("Первая мысль")

    notebook.coordinate(
      withNormalizedOffset: CGVector(dx: 0.12, dy: 0.2)
    ).tap()
    XCTAssertTrue(
      app.keyboards.firstMatch.waitForNonExistence(timeout: 2),
      "Касание обложки вне текста должно закончить редактирование"
    )

    let textPoint = notebook.coordinate(
      withNormalizedOffset: CGVector(dx: 0.55, dy: 0.53)
    )
    textPoint.tap()
    XCTAssertFalse(
      app.keyboards.firstMatch.exists,
      "Одно касание готового текста должно оставить обложку спокойной"
    )
    textPoint.doubleTap()
    XCTAssertTrue(
      app.keyboards.firstMatch.waitForExistence(timeout: 3),
      "Повторное двойное касание текста должно вернуть редактор"
    )
    editor.typeText("!")
    XCTAssertTrue(
      (editor.value as? String)?.contains("!") == true,
      "Открытый повторно текст должен принимать продолжение"
    )
  }

  func testSingleTapOffersDeletionAndRepairsAStack() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-simulator-finger-gestures",
      "--notebook-stacked-board-fixture",
    ]
    app.launch()
    XCTAssertTrue(app.buttons["create-workspace-item"].waitForExistence(timeout: 5))

    let removed = app.descendants(matching: .any)
      .matching(
        identifier: "workspace-item-7e7a1000-0000-4000-8000-000000000004"
      )
      .firstMatch
    let remaining = app.descendants(matching: .any)
      .matching(
        identifier: "workspace-item-7e7a1000-0000-4000-8000-000000000002"
      )
      .firstMatch
    XCTAssertTrue(removed.waitForExistence(timeout: 3))
    XCTAssertTrue(remaining.exists)

    removed.tap()
    let delete = app.buttons["delete-workspace-item"]
    XCTAssertTrue(delete.waitForExistence(timeout: 2))

    app.windows.firstMatch.coordinate(
      withNormalizedOffset: CGVector(dx: 0.04, dy: 0.08)
    ).tap()
    XCTAssertFalse(
      delete.waitForExistence(timeout: 0.6),
      "Касание свободной доски должно снять выбор"
    )

    removed.tap()
    XCTAssertTrue(delete.waitForExistence(timeout: 2))
    delete.tap()

    XCTAssertTrue(remaining.waitForExistence(timeout: 2))
    XCTAssertFalse(removed.exists)
  }

  func testLongPressPicksUpAndMovesTheNotebook() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-simulator-finger-gestures",
      "--notebook-cover-eraser-fixture",
    ]
    app.launch()

    let notebook = app.descendants(matching: .any)
      .matching(
        identifier: "workspace-item-7e7a1000-0000-4000-8000-000000000002"
      )
      .firstMatch
    XCTAssertTrue(notebook.waitForExistence(timeout: 5))
    let initialFrame = notebook.frame
    let start = notebook.coordinate(
      withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
    )
    let end = start.withOffset(CGVector(dx: 120, dy: 80))

    start.press(
      forDuration: 0.28,
      thenDragTo: end,
      withVelocity: .slow,
      thenHoldForDuration: 0
    )

    let moved = XCTNSPredicateExpectation(
      predicate: NSPredicate(
        block: { object, _ in
          guard let element = object as? XCUIElement else { return false }
          return element.frame.midX > initialFrame.midX + 70
            && element.frame.midY > initialFrame.midY + 40
        }
      ),
      object: notebook
    )
    wait(for: [moved], timeout: 2)

    let proof = XCTAttachment(screenshot: app.screenshot())
    proof.name = "cover-ink-after-notebook-move"
    proof.lifetime = .keepAlways
    add(proof)
  }

  func testCoverAndBoardAcceptConsecutivePencilActions() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-nearby-cover-fixture",
    ]
    app.launch()

    let notebook = app.descendants(matching: .any)
      .matching(
        identifier: "workspace-item-7e7a1000-0000-4000-8000-000000000002"
      )
      .firstMatch
    let ink = app.otherElements["spatial-ink"]
    XCTAssertTrue(notebook.waitForExistence(timeout: 5))
    XCTAssertTrue(ink.waitForExistence(timeout: 2))
    XCTAssertEqual(ink.value as? String, "0 действий")

    notebook.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3))
      .press(
        forDuration: 0.04,
        thenDragTo: notebook.coordinate(
          withNormalizedOffset: CGVector(dx: 0.72, dy: 0.42)
        ),
        withVelocity: .slow,
        thenHoldForDuration: 0
      )
    let firstCommitted = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "1 действий"),
      object: ink
    )
    wait(for: [firstCommitted], timeout: 2)

    let window = app.windows.firstMatch
    XCTAssertTrue(window.exists)
    window.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.18))
      .press(
        forDuration: 0.04,
        thenDragTo: window.coordinate(
          withNormalizedOffset: CGVector(dx: 0.08, dy: 0.52)
        ),
        withVelocity: .slow,
        thenHoldForDuration: 0
      )
    let secondCommitted = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "2 действий"),
      object: ink
    )
    wait(for: [secondCommitted], timeout: 2)
  }

  func testCoverEraserCommitsIntoTheVisibleSpatialScene() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-cover-eraser-fixture",
    ]
    app.launch()

    let notebook = app.descendants(matching: .any)
      .matching(
        identifier: "workspace-item-7e7a1000-0000-4000-8000-000000000002"
      )
      .firstMatch
    let ink = app.otherElements["spatial-ink"]
    XCTAssertTrue(notebook.waitForExistence(timeout: 5))
    XCTAssertTrue(ink.waitForExistence(timeout: 2))
    XCTAssertEqual(ink.value as? String, "1 действий")

    notebook.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.42))
      .press(
        forDuration: 0.04,
        thenDragTo: notebook.coordinate(
          withNormalizedOffset: CGVector(dx: 0.82, dy: 0.42)
        ),
        withVelocity: .slow,
        thenHoldForDuration: 0
      )

    let erased = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "2 действий"),
      object: ink
    )
    wait(for: [erased], timeout: 2)
    let proof = XCTAttachment(screenshot: app.screenshot())
    proof.name = "cover-eraser"
    proof.lifetime = .keepAlways
    add(proof)
  }

  func testUnrevealedCoverKeepsTheReleasedBoardCamera() async throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-simulator-finger-gestures",
      "--notebook-off-center-cover-fixture",
    ]
    app.launch()

    let notebook = app.descendants(matching: .any)
      .matching(
        identifier: "workspace-item-7e7a1000-0000-4000-8000-000000000002"
      )
      .firstMatch
    XCTAssertTrue(notebook.waitForExistence(timeout: 3))
    let coverFrame = notebook.frame
    let window = app.windows.firstMatch
    XCTAssertTrue(window.exists)
    let coverOffset = abs(coverFrame.midX - window.frame.midX)
    XCTAssertGreaterThan(coverOffset, 80)

    notebook.pinch(withScale: 1.005, velocity: 0.05)
    try await Task.sleep(for: .milliseconds(300))
    let releasedFrame = notebook.frame

    XCTAssertEqual(releasedFrame.width, coverFrame.width, accuracy: 3)
    XCTAssertEqual(releasedFrame.height, coverFrame.height, accuracy: 3)
    XCTAssertFalse(app.otherElements["paper-input"].exists)

    let proof = XCTAttachment(screenshot: app.screenshot())
    proof.name = "unrevealed-cover-keeps-board-camera"
    proof.lifetime = .keepAlways
    add(proof)
  }

  func testFirstVisibleOpeningReleaseFinishesTheDock() async throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-simulator-finger-gestures",
      "--notebook-off-center-cover-fixture",
    ]
    app.launch()

    let notebook = app.descendants(matching: .any)
      .matching(
        identifier: "workspace-item-7e7a1000-0000-4000-8000-000000000002"
      )
      .firstMatch
    let window = app.windows.firstMatch
    XCTAssertTrue(notebook.waitForExistence(timeout: 3))
    XCTAssertTrue(window.exists)
    notebook.pinch(withScale: 1.04, velocity: 0.15)

    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(
      paper.waitForExistence(timeout: 3),
      "Первое видимое раскрытие должно само завершить путь после отпускания"
    )
    try await Task.sleep(for: .milliseconds(320))
    assertFittedAndCentered(paper.frame, in: window.frame)

    let proof = XCTAttachment(screenshot: app.screenshot())
    proof.name = "first-visible-opening-completes-dock"
    proof.lifetime = .keepAlways
    add(proof)
  }

  func testCoverInkTravelsWithThePhysicalCurl() async throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-simulator-finger-gestures",
      "--notebook-cover-eraser-fixture",
      "--notebook-partial-cover-fixture",
    ]
    app.launch()

    let notebook = app.descendants(matching: .any)
      .matching(
        identifier: "workspace-item-7e7a1000-0000-4000-8000-000000000002"
      )
      .firstMatch
    XCTAssertTrue(notebook.waitForExistence(timeout: 3))
    try await Task.sleep(for: .milliseconds(300))

    let curl = app.otherElements["cover-opening-surface"]
    XCTAssertTrue(curl.exists)
    XCTAssertNotEqual(
      curl.value as? String,
      "Обложка 0%",
      "Проверка должна видеть именно частично изгибающуюся обложку"
    )
    XCTAssertFalse(app.otherElements["paper-input"].exists)
    XCTAssertEqual(app.state, .runningForeground)
    let screenshot = app.screenshot()
    XCTAssertGreaterThan(
      visibleInkPixelShare(
        in: screenshot,
        normalizedRect: CGRect(x: 0.16, y: 0.34, width: 0.26, height: 0.18)
      ),
      0.005,
      "Устойчивые чернила должны остаться видимыми под изгибающейся обложкой"
    )
    let technicalBand = CGRect(
      x: notebook.frame.minX + notebook.frame.width * 0.29,
      y: notebook.frame.minY - 12,
      width: notebook.frame.width * 0.36,
      height: 9
    )
    let window = app.windows.firstMatch
    XCTAssertTrue(window.exists)
    XCTAssertLessThan(
      opaqueGrayPixelShare(
        in: screenshot,
        normalizedRect: CGRect(
          x: (technicalBand.minX - window.frame.minX) / window.frame.width,
          y: (technicalBand.minY - window.frame.minY) / window.frame.height,
          width: technicalBand.width / window.frame.width,
          height: technicalBand.height / window.frame.height
        )
      ),
      0.05,
      "The physical curl keeps its overscan transparent around the fold"
    )
    let proof = XCTAttachment(screenshot: screenshot)
    proof.name = "cover-ink-on-physical-curl"
    proof.lifetime = .keepAlways
    add(proof)
  }

  func testDocumentCoverUsesTheSamePhysicalCurl() async throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-simulator-finger-gestures",
      "--notebook-document-runtime-fixture",
    ]
    app.launch()

    let page = app.otherElements["page-turn-surface"]
    XCTAssertTrue(page.waitForExistence(timeout: 8))
    page.pinch(withScale: 0.9, velocity: -0.25)
    try await Task.sleep(for: .milliseconds(400))

    let cover = app.otherElements["cover-opening-surface"]
    XCTAssertTrue(cover.waitForExistence(timeout: 3))
    let document = app.descendants(matching: .any)
      .matching(
        identifier: "workspace-item-7e7a1000-0000-4000-8000-000000000006"
      )
      .firstMatch
    let window = app.windows.firstMatch
    XCTAssertTrue(document.exists)
    XCTAssertTrue(window.exists)
    XCTAssertEqual(app.state, .runningForeground)
    let screenshot = app.screenshot()
    let openingSideWidth = min(
      document.frame.minX - window.frame.minX,
      document.frame.width * 0.2
    )
    XCTAssertGreaterThan(openingSideWidth, 16)
    XCTAssertGreaterThan(
      warmPaperPixelShare(
        in: screenshot,
        normalizedRect: CGRect(
          x: (document.frame.minX - openingSideWidth - window.frame.minX)
            / window.frame.width,
          y: (document.frame.minY + document.frame.height * 0.12
            - window.frame.minY) / window.frame.height,
          width: openingSideWidth / window.frame.width,
          height: document.frame.height * 0.76 / window.frame.height
        )
      ),
      0.5,
      "The curling cover must remain visible after it crosses the notebook frame"
    )
    let proof = XCTAttachment(screenshot: screenshot)
    proof.name = "document-cover-outside-notebook-frame"
    proof.lifetime = .keepAlways
    add(proof)
  }

  func testNearPageApproachMagnetCompletesTheDock() async throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-simulator-finger-gestures",
      "--notebook-off-center-cover-fixture",
    ]
    app.launch()

    let notebook = app.descendants(matching: .any)
      .matching(
        identifier: "workspace-item-7e7a1000-0000-4000-8000-000000000002"
      )
      .firstMatch
    XCTAssertTrue(notebook.waitForExistence(timeout: 3))
    let window = app.windows.firstMatch
    XCTAssertTrue(window.exists)
    XCTAssertGreaterThan(
      abs(notebook.frame.midX - window.frame.midX),
      80
    )
    XCTAssertGreaterThan(
      abs(notebook.frame.midY - window.frame.midY),
      50
    )
    notebook.pinch(withScale: 1.35, velocity: 0.5)

    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout: 5))
    try await Task.sleep(for: .milliseconds(350))
    assertFittedAndCentered(paper.frame, in: window.frame)
  }

  func testEachStackMemberOpensAsOneCenteredPage() async throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    try await Task.sleep(for: .milliseconds(350))

    try await assertCenteredStackMember(
      launchArgument: "--notebook-stacked-page-fixture",
      selectedID: "7e7a1000-0000-4000-8000-000000000004",
      hiddenSiblingID: "7e7a1000-0000-4000-8000-000000000002",
      attachmentName: "stacked-upper-page"
    )
    try await assertCenteredStackMember(
      launchArgument: "--notebook-stacked-lower-page-fixture",
      selectedID: "7e7a1000-0000-4000-8000-000000000002",
      hiddenSiblingID: "7e7a1000-0000-4000-8000-000000000004",
      attachmentName: "stacked-lower-page"
    )
  }

  func testStackMembersOpenFromTheBoardWithoutSplittingTheScreen() async throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    try await Task.sleep(for: .milliseconds(350))

    try await openStackMemberFromBoard(
      selectedID: "7e7a1000-0000-4000-8000-000000000004",
      hiddenSiblingID: "7e7a1000-0000-4000-8000-000000000002",
      attachmentName: "stacked-upper-double-tap"
    )
    try await openStackMemberFromBoard(
      selectedID: "7e7a1000-0000-4000-8000-000000000002",
      hiddenSiblingID: "7e7a1000-0000-4000-8000-000000000004",
      attachmentName: "stacked-lower-double-tap"
    )
  }

  private func openStackMemberFromBoard(
    selectedID: String,
    hiddenSiblingID: String,
    attachmentName: String
  ) async throws {
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-simulator-finger-gestures",
      "--notebook-stacked-board-fixture",
    ]
    app.launch()
    XCTAssertTrue(app.buttons["create-workspace-item"].waitForExistence(timeout: 5))

    let selected = app.descendants(matching: .any)
      .matching(identifier: "workspace-item-\(selectedID)")
      .firstMatch
    let sibling = app.descendants(matching: .any)
      .matching(identifier: "workspace-item-\(hiddenSiblingID)")
      .firstMatch
    XCTAssertTrue(selected.waitForExistence(timeout: 3))
    XCTAssertTrue(sibling.exists)
    selected.doubleTap()

    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout: 5))
    let window = app.windows.firstMatch
    XCTAssertTrue(window.exists)
    try await Task.sleep(for: .milliseconds(350))
    assertFittedAndCentered(paper.frame, in: window.frame)
    XCTAssertFalse(
      app.descendants(matching: .any)
        .matching(identifier: "workspace-item-\(hiddenSiblingID)")
        .firstMatch.exists,
      "После входа соседняя тетрадь должна остаться в стопке"
    )

    let proof = XCTAttachment(screenshot: app.screenshot())
    proof.name = attachmentName
    proof.lifetime = .keepAlways
    add(proof)
    app.terminate()
  }

  private func assertCenteredStackMember(
    launchArgument: String,
    selectedID: String,
    hiddenSiblingID: String,
    attachmentName: String
  ) async throws {
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      launchArgument,
    ]
    app.launch()

    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout: 5))
    let window = app.windows.firstMatch
    XCTAssertTrue(window.exists)
    try await Task.sleep(for: .milliseconds(250))

    assertFittedAndCentered(paper.frame, in: window.frame)
    XCTAssertTrue(
      app.descendants(matching: .any)
        .matching(identifier: "workspace-item-\(selectedID)")
        .firstMatch.exists
    )
    XCTAssertFalse(
      app.descendants(matching: .any)
        .matching(identifier: "workspace-item-\(hiddenSiblingID)")
        .firstMatch.exists,
      "Соседняя тетрадь должна оставаться внутри стопки"
    )

    let proof = XCTAttachment(screenshot: app.screenshot())
    proof.name = attachmentName
    proof.lifetime = .keepAlways
    add(proof)
    app.terminate()
  }

  private func assertFittedAndCentered(_ paper: CGRect, in window: CGRect) {
    XCTAssertEqual(paper.midX, window.midX, accuracy: 2)
    XCTAssertEqual(paper.midY, window.midY, accuracy: 2)
    let fit = min(window.width / 834, window.height / 1_194)
    XCTAssertEqual(paper.width, 834 * fit, accuracy: 2)
    XCTAssertEqual(paper.height, 1_194 * fit, accuracy: 2)
  }

  private func darkPixelShare(
    in screenshot: XCUIScreenshot,
    normalizedRect: CGRect
  ) -> Double {
    pixelShare(in: screenshot, normalizedRect: normalizedRect) {
      red,
      green,
      blue,
      _ in
      max(red, green, blue) < 45
    }
  }

  private func visibleInkPixelShare(
    in screenshot: XCUIScreenshot,
    normalizedRect: CGRect
  ) -> Double {
    pixelShare(in: screenshot, normalizedRect: normalizedRect) {
      red,
      green,
      blue,
      _ in
      max(red, green, blue) < 180
    }
  }

  private func warmPaperPixelShare(
    in screenshot: XCUIScreenshot,
    normalizedRect: CGRect
  ) -> Double {
    pixelShare(in: screenshot, normalizedRect: normalizedRect) {
      red,
      green,
      blue,
      alpha in
      alpha > 240
        && red >= 245
        && green >= 243
        && blue <= 243
        && red >= blue + 4
    }
  }

  private func opaqueGrayPixelShare(
    in screenshot: XCUIScreenshot,
    normalizedRect: CGRect
  ) -> Double {
    pixelShare(in: screenshot, normalizedRect: normalizedRect) {
      red,
      green,
      blue,
      alpha in
      let darkest = min(red, green, blue)
      let lightest = max(red, green, blue)
      return alpha > 240
        && darkest >= 120
        && lightest <= 200
        && lightest - darkest <= 20
    }
  }

  private func pixelShare(
    in screenshot: XCUIScreenshot,
    normalizedRect: CGRect,
    matching predicate: (UInt8, UInt8, UInt8, UInt8) -> Bool
  ) -> Double {
    guard let image = screenshot.image.cgImage else {
      XCTFail("Снимок проверки должен содержать растровое изображение")
      return 0
    }

    let imageBounds = CGRect(
      x: 0,
      y: 0,
      width: image.width,
      height: image.height
    )
    let pixelRect = CGRect(
      x: normalizedRect.minX * imageBounds.width,
      y: normalizedRect.minY * imageBounds.height,
      width: normalizedRect.width * imageBounds.width,
      height: normalizedRect.height * imageBounds.height
    ).integral.intersection(imageBounds)
    guard !pixelRect.isEmpty, let crop = image.cropping(to: pixelRect) else {
      XCTFail("Область проверки чернил должна попадать в снимок")
      return 0
    }

    let bytesPerPixel = 4
    let bytesPerRow = crop.width * bytesPerPixel
    var pixels = [UInt8](
      repeating: 0,
      count: crop.height * bytesPerRow
    )
    let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress,
          width: crop.width,
          height: crop.height,
          bitsPerComponent: 8,
          bytesPerRow: bytesPerRow,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
      else { return false }
      context.draw(
        crop,
        in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height)
      )
      return true
    }
    guard rendered else {
      XCTFail("Снимок проверки чернил должен читаться как RGBA")
      return 0
    }

    var matchingPixels = 0
    for offset in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
      if predicate(
        pixels[offset],
        pixels[offset + 1],
        pixels[offset + 2],
        pixels[offset + 3]
      ) {
        matchingPixels += 1
      }
    }
    return Double(matchingPixels) / Double(crop.width * crop.height)
  }

  private func changedPixelShare(
    from first: XCUIScreenshot,
    to second: XCUIScreenshot,
    normalizedRect: CGRect
  ) -> Double {
    guard let firstImage = first.image.cgImage,
      let secondImage = second.image.cgImage,
      firstImage.width == secondImage.width,
      firstImage.height == secondImage.height
    else {
      XCTFail("Снимки листа должны иметь один размер")
      return 1
    }
    let imageBounds = CGRect(
      x: 0,
      y: 0,
      width: firstImage.width,
      height: firstImage.height
    )
    let pixelRect = CGRect(
      x: normalizedRect.minX * imageBounds.width,
      y: normalizedRect.minY * imageBounds.height,
      width: normalizedRect.width * imageBounds.width,
      height: normalizedRect.height * imageBounds.height
    ).integral.intersection(imageBounds)
    guard !pixelRect.isEmpty,
      let firstCrop = firstImage.cropping(to: pixelRect),
      let secondCrop = secondImage.cropping(to: pixelRect),
      let firstPixels = rgbaPixels(firstCrop),
      let secondPixels = rgbaPixels(secondCrop)
    else {
      XCTFail("Одинаковая область листа должна читаться с обоих снимков")
      return 1
    }

    let bytesPerPixel = 4
    var changedPixels = 0
    for offset in stride(
      from: 0,
      to: firstPixels.count,
      by: bytesPerPixel
    ) {
      let largestChannelChange = (0..<bytesPerPixel).reduce(0) { change, channel in
        max(
          change,
          abs(
            Int(firstPixels[offset + channel])
              - Int(secondPixels[offset + channel])
          )
        )
      }
      if largestChannelChange > 12 { changedPixels += 1 }
    }
    return Double(changedPixels)
      / Double(firstPixels.count / bytesPerPixel)
  }

  private func rgbaPixels(_ image: CGImage) -> [UInt8]? {
    let bytesPerPixel = 4
    let bytesPerRow = image.width * bytesPerPixel
    var pixels = [UInt8](
      repeating: 0,
      count: image.height * bytesPerRow
    )
    let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard let context = CGContext(
        data: buffer.baseAddress,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ) else { return false }
      context.draw(
        image,
        in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
      )
      return true
    }
    return rendered ? pixels : nil
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

    let secondStarted = ContinuousClock.now
    paper.coordinate(
      withNormalizedOffset: CGVector(dx: 0.12, dy: 0.68)
    ).press(
      forDuration: 0.04,
      thenDragTo: paper.coordinate(
        withNormalizedOffset: CGVector(dx: 0.88, dy: 0.76)
      ),
      withVelocity: .fast,
      thenHoldForDuration: 0
    )
    XCTAssertLessThan(
      ContinuousClock.now - secondStarted,
      .seconds(4),
      "Второй жест ластика должен начаться сразу после подъёма Pencil"
    )

    let responseStarted = ContinuousClock.now
    controls.tap()
    let controlsClosed = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@", "Настроить ручку"),
      object: controls
    )
    wait(for: [controlsClosed], timeout: 2)
    XCTAssertLessThan(ContinuousClock.now - responseStarted, .seconds(2))

    let bothErasersLanded = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value BEGINSWITH '2'"),
      object: paper
    )
    wait(for: [bothErasersLanded], timeout: 2)
  }

  func testErasureIsCommittedBeforeLeavingAndReopeningTheNotebook() async throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-simulator-finger-gestures",
      "--notebook-simulator-mixed-input",
    ]
    app.launch()

    let controls = app.buttons["pen-controls-toggle"]
    XCTAssertTrue(controls.waitForExistence(timeout: 5))
    controls.tap()
    let eraser = app.buttons["drawing-tool-eraser"]
    XCTAssertTrue(eraser.waitForExistence(timeout: 2))
    eraser.tap()

    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout: 2))
    let originalValue = paper.value as? String
    XCTAssertEqual(originalValue, "80 штрихов")
    paper.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.48))
      .press(
        forDuration: 0.04,
        thenDragTo: paper.coordinate(
          withNormalizedOffset: CGVector(dx: 0.88, dy: 0.56)
        ),
        withVelocity: .fast,
        thenHoldForDuration: 0
      )
    let erased = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value != %@", originalValue ?? ""),
      object: paper
    )
    await fulfillment(of: [erased], timeout: 2)
    try await Task.sleep(for: .milliseconds(700))
    let beforeClosing = app.screenshot()
    XCTAssertGreaterThan(
      visibleInkPixelShare(
        in: beforeClosing,
        normalizedRect: CGRect(x: 0.12, y: 0.16, width: 0.76, height: 0.68)
      ),
      0.005,
      "Суд повторного входа должен начинаться с видимых устойчивых чернил"
    )

    paper.pinch(withScale: 0.28, velocity: -2)
    XCTAssertTrue(app.buttons["create-workspace-item"].waitForExistence(timeout: 5))
    let notebook = app.descendants(matching: .any)
      .matching(
        identifier: "workspace-item-7e7a1000-0000-4000-8000-000000000002"
      )
      .firstMatch
    XCTAssertTrue(notebook.waitForExistence(timeout: 2))
    notebook.doubleTap()

    let reopened = app.otherElements["paper-input"]
    XCTAssertTrue(reopened.waitForExistence(timeout: 5))
    try await Task.sleep(for: .milliseconds(700))
    XCTAssertNotEqual(
      reopened.value as? String,
      originalValue,
      "Закрытие должно дождаться сериализации ластика"
    )
    let afterReopening = app.screenshot()
    XCTAssertLessThan(
      changedPixelShare(
        from: beforeClosing,
        to: afterReopening,
        normalizedRect: CGRect(x: 0.12, y: 0.16, width: 0.76, height: 0.68)
      ),
      0.01,
      "Повторный вход должен показать те же завершённые пиксели листа"
    )
  }
}

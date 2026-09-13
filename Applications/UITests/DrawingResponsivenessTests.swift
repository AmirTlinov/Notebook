import CoreGraphics
import UIKit
import Vision
import XCTest

@MainActor
final class DrawingResponsivenessTests: XCTestCase {
  func testCompanionAdditionsOwnPencilAboveTheBoard() {
    continueAfterFailure = false
    let app = XCUIApplication()
    // In this fixture direct test contacts exercise the actual spatial Pencil recognizer.
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-stacked-board-fixture", "--notebook-compact-chat-fixture"]
    launchPortraitFixture(app)
    let ink = app.otherElements["spatial-ink"]
    XCTAssertTrue(ink.waitForExistence(timeout: 8))
    let accepted = ink.value as? String
    let cover = app.descendants(matching: .any).matching(identifier: "workspace-item-7e7a1000-0000-4000-8000-000000000004").firstMatch
    XCTAssertTrue(cover.waitForExistence(timeout: 4)); let frame = cover.frame
    app.buttons["notebook-chat-toggle"].tap(); app.buttons["notebook-companion-compose"].tap()
    app.buttons["notebook-chat-actions"].tap()
    XCTAssertTrue(app.buttons["Плагины"].waitForExistence(timeout: 3))
    let proof = XCTAttachment(screenshot: app.screenshot())
    proof.name = "companion-additions-over-spatial-pencil"; proof.lifetime = .keepAlways; add(proof)
    app.buttons["Плагины"].tap()
    let plugin = app.buttons["notebook-chat-resource-fixture-resource"]
    XCTAssertTrue(plugin.waitForExistence(timeout: 5), "The menu, not the paper behind it, owns this contact")
    plugin.tap()
    XCTAssertTrue(app.buttons["notebook-chat-attachment-fixture-resource"].waitForExistence(timeout: 3))
    app.buttons["notebook-chat-actions"].tap()
    XCTAssertTrue(app.buttons["Файлы и папки"].waitForExistence(timeout: 3))
    app.buttons["notebook-chat-actions"].tap()
    XCTAssertFalse(app.buttons["Файлы и папки"].exists)
    XCTAssertEqual(ink.value as? String, accepted, "Choosing a menu item must not write through to the board")
    XCTAssertEqual(cover.frame, frame)
    let start = ink.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.3))
    start.press(forDuration: 0.1, thenDragTo: start.withOffset(.init(dx: -65, dy: 30)))
    let resumed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in ink.value as? String != accepted }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [resumed], timeout: 4), .completed, "Pencil resumes after the menu without resetting the scene")
    XCTAssertEqual(cover.frame, frame)
  }

  func testCompanionAdditionsDismissAndAttachWithAndWithoutKeyboard() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-compact-chat-fixture"]
    launchPortraitFixture(app)
    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout: 8))
    let frame = paper.frame, ink = paper.value as? String
    app.buttons["notebook-chat-toggle"].tap()
    app.buttons["notebook-companion-compose"].tap()
    let draft = app.descendants(matching: .any).matching(identifier: "notebook-companion-draft").firstMatch
    XCTAssertTrue(draft.waitForExistence(timeout: 4))
    let additions = app.buttons["notebook-chat-actions"]
    for _ in 0..<3 {
      additions.tap()
      XCTAssertTrue(app.buttons["Файлы и папки"].waitForExistence(timeout: 3))
      paper.coordinate(withNormalizedOffset: .init(dx: 0.1, dy: 0.3)).tap()
      XCTAssertTrue(additions.isHittable)
    }
    draft.tap(); draft.typeText("Keep draft")
    additions.tap()
    let menuProof = XCTAttachment(screenshot: app.screenshot())
    menuProof.name = "companion-additions-with-keyboard"; menuProof.lifetime = .keepAlways; add(menuProof)
    app.buttons["Плагины"].tap()
    let plugin = app.buttons["notebook-chat-resource-fixture-resource"]
    XCTAssertTrue(plugin.waitForExistence(timeout: 5)); plugin.tap()
    XCTAssertTrue(app.buttons["notebook-chat-attachment-fixture-resource"].waitForExistence(timeout: 3))
    XCTAssertEqual(draft.value as? String, "Keep draft")
    additions.tap(); app.buttons["Файлы и папки"].tap()
    let file = app.buttons["notebook-file-example.swift"]
    XCTAssertTrue(file.waitForExistence(timeout: 5)); file.tap()
    XCTAssertTrue(app.buttons["notebook-chat-attachment-example.swift"].waitForExistence(timeout: 3))
    XCTAssertFalse(app.otherElements["notebook-code-document"].exists)
    additions.tap(); app.buttons["Проверить изменения"].tap()
    XCTAssertTrue((draft.value as? String)?.hasPrefix("Keep draft\nПроверь изменения") == true)
    let edited = draft.value as? String
    app.buttons["notebook-companion-compose"].tap()
    app.buttons["notebook-chat-toggle"].tap()
    let fullDraft = app.descendants(matching: .any).matching(identifier: "notebook-chat-text").firstMatch
    XCTAssertEqual(fullDraft.value as? String, edited)
    XCTAssertFalse(app.webViews.staticTexts["Принято поручений: 1"].exists, "Menus and attachments never send the draft")
    XCTAssertEqual(paper.frame, frame); XCTAssertEqual(paper.value as? String, ink)
    let proof = XCTAttachment(screenshot: app.screenshot())
    proof.name = "companion-additions-return-to-same-draft"; proof.lifetime = .keepAlways; add(proof)
  }

  func testCompanionKeepsPaperDraftAndOneSubmissionWithoutReplyClouds() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-compact-chat-fixture"]
    launchPortraitFixture(app)
    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout: 8)); let frame = paper.frame
    let text = app.descendants(matching: .any).matching(identifier: "notebook-chat-text").firstMatch
    XCTAssertTrue(text.waitForExistence(timeout: 5)); text.tap(); text.typeText("Keep draft")
    app.buttons["notebook-chat-toggle"].tap()
    let taskCard = app.buttons["notebook-companion-task"]
    XCTAssertTrue(taskCard.waitForExistence(timeout: 8))
    XCTAssertFalse(app.buttons["notebook-reply-cloud"].exists)
    XCTAssertFalse(app.otherElements["notebook-chat-transcript"].exists)
    XCTAssertTrue(app.buttons["notebook-compact-dictation"].isHittable)
    XCTAssertTrue(app.buttons["notebook-compact-voice-settings"].isHittable)
    let priorInk = paper.value as? String
    let panel = app.descendants(matching: .any).matching(identifier: "notebook-chat-panel").firstMatch
    let clearPoints = [CGPoint(x: 0.15, y: 0.4), .init(x: 0.65, y: 0.4), .init(x: 0.15, y: 0.7), .init(x: 0.65, y: 0.7)]
      .map { CGPoint(x: paper.frame.minX + paper.frame.width * $0.x, y: paper.frame.minY + paper.frame.height * $0.y) }
      .filter { !panel.frame.intersects(CGRect(origin: $0, size: .init(width: 85, height: 40))) }
    XCTAssertFalse(clearPoints.isEmpty, "The companion must leave room to write")
    let start = app.coordinate(withNormalizedOffset: .zero).withOffset(.init(dx: clearPoints[0].x, dy: clearPoints[0].y))
    start.press(forDuration: 0.1, thenDragTo: start.withOffset(.init(dx: 80, dy: 35)))
    let inkChanged = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in paper.value as? String != priorInk }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [inkChanged], timeout: 4), .completed)
    let acceptedInk = paper.value as? String
    XCTAssertEqual(paper.frame, frame)
    XCTAssertLessThan(panel.frame.height, app.frame.height * 0.43)
    let first = XCTAttachment(screenshot: app.screenshot()); first.name = "companion-keeps-pencil"; first.lifetime = .keepAlways; add(first)
    let unread = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in taskCard.label.contains("Новых ответов: 1") }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [unread], timeout: 8), .completed)
    taskCard.tap()
    let full = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Объяснение формулы, часть 1.'")).firstMatch
    XCTAssertTrue(full.waitForExistence(timeout: 5)); XCTAssertTrue(full.isHittable, "Opening unread replies reveals the exact message, not the end of its long text")
    XCTAssertEqual(text.value as? String, "Keep draft")
    app.buttons["notebook-chat-toggle"].tap(); app.buttons["notebook-companion-compose"].tap()
    let draft = app.descendants(matching: .any).matching(identifier: "notebook-companion-draft").firstMatch
    XCTAssertEqual(draft.value as? String, "Keep draft"); draft.tap(); draft.typeText(" once")
    let edited = draft.value as? String
    XCTAssertFalse(edited?.isEmpty ?? true)
    let send = app.buttons["notebook-companion-send"]; XCTAssertTrue(send.isHittable); send.tap()
    let cleared = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in (draft.value as? String) != edited }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 5), .completed)
    app.buttons["notebook-companion-compose"].tap()
    XCTAssertTrue(taskCard.waitForExistence(timeout: 5)); XCTAssertTrue(taskCard.label.contains("Новых ответов: 1"))
    XCTAssertEqual(paper.value as? String, acceptedInk); XCTAssertEqual(paper.frame, frame)
    XCUIDevice.shared.orientation = .landscapeLeft
    let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.width > app.frame.height }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 5), .completed)
    XCUIDevice.shared.orientation = .portrait
    let portrait = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.width < app.frame.height }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [portrait], timeout: 5), .completed)
    XCTAssertTrue(app.buttons["notebook-companion-compose"].waitForExistence(timeout: 5))
    XCTAssertEqual(paper.value as? String, acceptedInk)
    taskCard.tap()
    let receipt = app.webViews.staticTexts["Принято поручений: 1"]
    XCTAssertTrue(receipt.waitForExistence(timeout: 5))
    let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in receipt.frame.intersects(app.otherElements["notebook-chat-transcript"].frame) }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed)
    XCTAssertTrue(receipt.isHittable)
    app.buttons["notebook-chat-toggle"].tap(); app.buttons["notebook-compact-voice-settings"].tap()
    XCTAssertTrue(app.staticTexts["Голосовой разговор"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.buttons["notebook-voice-arm"].exists)
    XCTAssertTrue(app.buttons["notebook-voice-begin"].exists)
    XCTAssertEqual(app.alerts.count, 0)
    app.buttons["notebook-voice-settings-close"].tap()
    XCTAssertEqual(paper.value as? String, acceptedInk)
  }

  func testComposerAddsResourcesChangesNativeSettingsAndKeepsVoiceAtNarrowWidth() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-chat-sync-fixture"]
    launchPortraitFixture(app)
    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout: 8))
    let frame = paper.frame, ink = paper.value as? String
    let model = app.buttons["notebook-chat-model"]
    XCTAssertTrue(model.waitForExistence(timeout: 8)); model.tap()
    app.buttons["notebook-chat-model-picker"].tap()
    app.buttons.matching(NSPredicate(format: "label CONTAINS 'Fixture B'")).firstMatch.tap()
    let picked = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      app.buttons["notebook-chat-model-picker"].label.contains("Fixture B")
    }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [picked], timeout: 8), .completed)
    app.buttons["notebook-chat-effort-picker"].tap(); app.buttons["Макс."].tap()
    let effort = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      app.buttons["notebook-chat-effort-picker"].label.contains("Макс.")
    }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [effort], timeout: 8), .completed)
    paper.coordinate(withNormalizedOffset: .init(dx: 0.1, dy: 0.3)).tap()
    app.buttons["notebook-chat-context"].tap()
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '193' AND label CONTAINS '258'")).firstMatch.waitForExistence(timeout: 3))
    paper.coordinate(withNormalizedOffset: .init(dx: 0.1, dy: 0.3)).tap()
    app.buttons["notebook-chat-actions"].tap(); app.buttons["Плагины"].tap()
    let resource = app.buttons["notebook-chat-resource-fixture-resource"]
    XCTAssertTrue(resource.waitForExistence(timeout: 5)); resource.tap()
    let attachment = app.buttons["notebook-chat-attachment-fixture-resource"]
    XCTAssertTrue(attachment.waitForExistence(timeout: 3))
    app.buttons["notebook-chat-actions"].tap()
    let addFiles = app.buttons["Файлы и папки"]
    XCTAssertTrue(addFiles.waitForExistence(timeout: 3)); addFiles.tap()
    let file = app.buttons["notebook-file-example.swift"]
    XCTAssertTrue(file.waitForExistence(timeout: 5)); file.tap()
    XCTAssertTrue(app.buttons["notebook-chat-attachment-example.swift"].waitForExistence(timeout: 3))
    XCTAssertFalse(app.otherElements["notebook-code-document"].exists, "Attaching a file is not opening or moving a document")
    let panel = app.descendants(matching: .any).matching(identifier: "notebook-chat-panel").firstMatch
    let corner = panel.coordinate(withNormalizedOffset: .zero).withOffset(.init(dx: 10, dy: panel.frame.height - 10))
    corner.press(forDuration: 0.1, thenDragTo: corner.withOffset(.init(dx: panel.frame.width - 320, dy: 80)))
    XCTAssertEqual(panel.frame.width, 320, accuracy: 4)
    for id in ["notebook-chat-dictation", "notebook-chat-voice", "notebook-chat-stop"] {
      let button = app.buttons[id]
      XCTAssertTrue(button.exists); XCTAssertTrue(button.isHittable)
      XCTAssertTrue(panel.frame.contains(button.frame)); XCTAssertEqual(button.frame.width, 44, accuracy: 1)
    }
    XCTAssertEqual(app.buttons["notebook-chat-dictation"].frame.maxX, app.buttons["notebook-chat-voice"].frame.minX, accuracy: 1)
    XCTAssertGreaterThan(model.frame.minX, app.buttons["notebook-chat-actions"].frame.maxX)
    XCTAssertLessThanOrEqual(model.frame.maxX, app.buttons["notebook-chat-dictation"].frame.minX + 1)
    XCTAssertTrue(model.isHittable); XCTAssertTrue(panel.frame.contains(model.frame))
    XCTAssertEqual(paper.frame, frame); XCTAssertEqual(paper.value as? String, ink)
    let proof = XCTAttachment(screenshot: app.screenshot()); proof.name = "composer-model-context-resource-narrow"; proof.lifetime = .keepAlways; add(proof)
  }

  func testScrollLoadsEarlierMessagesAndStopReplacesSendWithoutLosingDraftOrPaper() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-chat-sync-fixture"]
    launchPortraitFixture(app)
    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout: 8))
    let frame = paper.frame, ink = paper.value as? String
    let stop = app.buttons["notebook-chat-stop"], send = app.buttons["notebook-chat-send"]
    XCTAssertTrue(stop.waitForExistence(timeout: 8)); XCTAssertFalse(send.exists)
    XCTAssertEqual(stop.frame.width, 44, accuracy: 1)
    XCTAssertTrue(app.otherElements["notebook-chat-composer"].frame.contains(stop.frame))
    XCTAssertFalse(app.buttons["История"].exists); XCTAssertFalse(app.buttons["Ранее"].exists)
    XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Обновить'")).firstMatch.exists)
    XCTAssertTrue(app.webViews.staticTexts["code_image.png"].waitForExistence(timeout: 5))
    let transcript = app.otherElements["notebook-chat-transcript"]
    let old = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Ранний ответ 9.'")).firstMatch
    for _ in 0..<8 {
      if old.exists { break }
      transcript.swipeDown()
    }
    XCTAssertTrue(old.waitForExistence(timeout: 5), "The actual scroll gesture must request the older native page")
    let field = app.descendants(matching: .any).matching(identifier: "notebook-chat-text").firstMatch
    field.tap(); field.typeText("Keep this draft")
    stop.tap()
    XCTAssertTrue(send.waitForExistence(timeout: 8)); XCTAssertFalse(stop.exists)
    XCTAssertEqual(field.value as? String, "Keep this draft")
    XCTAssertEqual(paper.frame, frame); XCTAssertEqual(paper.value as? String, ink)
    let proof = XCTAttachment(screenshot: app.screenshot()); proof.name = "scroll-history-and-composer-stop"; proof.lifetime = .keepAlways; add(proof)
  }

  func testDictationControlBesideVoiceExplainsAvailabilityWithoutLosingTheDraftOrPaper() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-chat-conversation-fixture"]
    launchPortraitFixture(app)
    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout: 8))
    let frame = paper.frame, ink = paper.value as? String
    app.buttons["notebook-chat-toggle"].tap()
    let dictation = app.buttons["notebook-chat-dictation"], voice = app.buttons["notebook-chat-voice"]
    XCTAssertTrue(dictation.waitForExistence(timeout: 4)); XCTAssertTrue(voice.exists)
    XCTAssertEqual(dictation.frame.width, 44, accuracy: 1)
    XCTAssertEqual(dictation.frame.height, 44, accuracy: 1)
    XCTAssertEqual(dictation.frame.maxX, voice.frame.minX, accuracy: 1)
    XCTAssertEqual(dictation.value as? String, "Пока недоступен")
    let field = app.descendants(matching: .any).matching(identifier: "notebook-chat-text").firstMatch
    field.tap(); field.typeText("Keep this draft")
    dictation.tap()
    let notice = app.staticTexts["notebook-dictation-unavailable"]
    XCTAssertTrue(notice.waitForExistence(timeout: 3))
    XCTAssertTrue(notice.label.contains("не поддерживает диктовку в черновик"))
    let unavailableProof = XCTAttachment(screenshot: app.screenshot())
    unavailableProof.name = "dictation-unavailable-without-mode-change"; unavailableProof.lifetime = .keepAlways; add(unavailableProof)
    XCTAssertEqual(field.value as? String, "Keep this draft")
    XCTAssertFalse(app.buttons["Завершить голосовой разговор"].exists)
    XCTAssertEqual(app.alerts.count, 0, "Explaining unavailable dictation must not request microphone access")
    app.buttons["notebook-dictation-close"].tap()
    voice.tap()
    XCTAssertTrue(app.buttons["notebook-voice-arm"].waitForExistence(timeout: 3), "The open chat must expose explicit local wake activation after a dictation tap")
    XCTAssertTrue(app.buttons["notebook-voice-begin"].exists)
    XCTAssertFalse(app.buttons["notebook-voice-method"].exists, "An unavailable mode cannot be selected and poison the next wake attempt")
    let settingsProof = XCTAttachment(screenshot: app.screenshot())
    settingsProof.name = "same-voice-menu-with-explicit-wake"; settingsProof.lifetime = .keepAlways; add(settingsProof)
    XCTAssertEqual(app.alerts.count, 0, "Opening voice settings must not activate a microphone")
    app.buttons["notebook-voice-settings-close"].tap()
    app.buttons["notebook-chat-toggle"].tap()
    app.buttons["notebook-compact-dictation"].tap()
    XCTAssertTrue(notice.waitForExistence(timeout: 3))
    app.buttons["notebook-dictation-close"].tap()
    app.buttons["notebook-compact-voice-settings"].tap()
    XCTAssertTrue(app.buttons["notebook-voice-arm"].waitForExistence(timeout: 3))
    app.buttons["notebook-voice-settings-close"].tap()
    app.buttons["notebook-chat-toggle"].tap()
    XCTAssertEqual(field.value as? String, "Keep this draft")
    XCTAssertEqual(paper.frame, frame); XCTAssertEqual(paper.value as? String, ink)
    let proof = XCTAttachment(screenshot: app.screenshot())
    proof.name = "dictation-beside-voice-keeps-draft"; proof.lifetime = .keepAlways; add(proof)
  }

  func testTerminalDrawerKeepsChatTypesThroughTheKeyboardAndResizesWithoutMovingPaper() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-terminal-fixture"]
    launchPortraitFixture(app)
    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout: 8))
    let paperFrame = paper.frame, ink = paper.value as? String
    let chat = app.otherElements["notebook-chat-panel"]
    XCTAssertTrue(chat.waitForExistence(timeout: 5))
    let corner = chat.coordinate(withNormalizedOffset: .init(dx: 1, dy: 1)).withOffset(.init(dx: -5, dy: -20))
    corner.press(forDuration: 0.05, thenDragTo: corner.withOffset(.init(dx: 0, dy: 180)))
    app.buttons["notebook-terminal-toggle"].tap()
    let terminal = app.otherElements["notebook-terminal-panel"]
    let divider = app.otherElements["notebook-terminal-divider"]
    XCTAssertTrue(terminal.waitForExistence(timeout: 5))
    XCTAssertTrue(divider.waitForExistence(timeout: 5))
    let reply = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Терминал открыт под разговором'")).firstMatch
    XCTAssertTrue(reply.waitForExistence(timeout: 8))
    let tree = XCTAttachment(string: app.debugDescription); tree.name = "terminal-controls-and-transcript"; tree.lifetime = .keepAlways; add(tree)
    XCTAssertTrue(reply.isHittable, "The conversation must remain visible, not just exist in an offscreen DOM")
    XCTAssertTrue(app.otherElements["notebook-chat-composer"].exists)
    XCTAssertLessThan(app.otherElements["notebook-chat-composer"].frame.maxY, terminal.frame.minY)
    let original = terminal.frame
    divider.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).press(forDuration: 0.05,
      thenDragTo: divider.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).withOffset(.init(dx: 0, dy: -95)),
      withVelocity: .slow, thenHoldForDuration: 0)
    XCTAssertGreaterThan(terminal.frame.height, original.height + 35)
    let readable = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in reply.isHittable }, object: nil)
    let readingRestored = XCTWaiter.wait(for: [readable], timeout: 5)
    let resized = XCTAttachment(screenshot: app.screenshot()); resized.name = "terminal-resized-keeps-readable-reply"; resized.lifetime = .keepAlways; add(resized)
    let resizedTree = XCTAttachment(string: app.debugDescription); resizedTree.name = "terminal-resized-controls"; resizedTree.lifetime = .keepAlways; add(resizedTree)
    XCTAssertEqual(readingRestored, .completed)
    XCTAssertGreaterThanOrEqual(app.otherElements["notebook-chat-transcript"].frame.height, 65)
    let resizedHeight = terminal.frame.height
    let input = app.webViews.textViews["Ввод терминала"].firstMatch
    XCTAssertTrue(input.waitForExistence(timeout: 8))
    input.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "An actual terminal touch must open the iPad keyboard")
    input.typeText("terminal-input-123\n")
    let echoed = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS 'terminal-input-123'"))
    XCTAssertTrue(echoed.firstMatch.waitForExistence(timeout: 5), "Typing must traverse the controller and remote peer before appearing in output")
    XCTAssertEqual(paper.frame, paperFrame); XCTAssertEqual(paper.value as? String, ink)
    let proof = XCTAttachment(screenshot: app.screenshot()); proof.name = "terminal-below-chat-with-real-keyboard"; proof.lifetime = .keepAlways; add(proof)
    app.buttons["notebook-terminal-collapse"].coordinate(withNormalizedOffset: .init(dx: 0.2, dy: 0.25)).tap()
    XCTAssertTrue(terminal.waitForNonExistence(timeout: 4))
    app.buttons["notebook-terminal-toggle"].tap()
    XCTAssertTrue(terminal.waitForExistence(timeout: 5))
    XCTAssertTrue(echoed.firstMatch.waitForExistence(timeout: 5), "Reopening must replay the same process, not a new shell")
    XCTAssertEqual(terminal.frame.height, resizedHeight, accuracy: 3)
    XCTAssertTrue(reply.isHittable, "Restoring the drawer must retain readable conversation space")
    XCTAssertEqual(paper.frame, paperFrame); XCTAssertEqual(paper.value as? String, ink)
    let restored = XCTAttachment(screenshot: app.screenshot()); restored.name = "terminal-drawer-restored"; restored.lifetime = .keepAlways; add(restored)
    for point in [CGVector(dx: 0.85, dy: 0.2), .init(dx: 0.2, dy: 0.8), .init(dx: 0.85, dy: 0.8)] {
      let collapse = app.buttons["notebook-terminal-collapse"]
      XCTAssertGreaterThanOrEqual(collapse.frame.width, 44); XCTAssertGreaterThanOrEqual(collapse.frame.height, 44)
      collapse.coordinate(withNormalizedOffset: point).tap()
      XCTAssertTrue(terminal.waitForNonExistence(timeout: 4))
      app.buttons["notebook-terminal-toggle"].tap()
      XCTAssertTrue(terminal.waitForExistence(timeout: 5))
      XCTAssertTrue(echoed.firstMatch.waitForExistence(timeout: 5))
    }
    app.buttons["notebook-terminal-toggle"].tap()
    XCTAssertTrue(terminal.waitForNonExistence(timeout: 4))
    XCTAssertEqual(paper.frame, paperFrame); XCTAssertEqual(paper.value as? String, ink)
  }

  func testChatBrowserSeparatesAllChatsFromExpandableProjectFolders() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-terminal-fixture"]
    launchPortraitFixture(app)
    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout: 8))
    let frame = paper.frame, ink = paper.value as? String
    XCTAssertTrue(app.buttons["notebook-terminal-toggle"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.buttons["notebook-terminal-toggle"].frame.midY, app.buttons["notebook-files-toggle"].frame.midY, accuracy: 1)
    let chat = app.otherElements["notebook-chat-panel"]
    let corner = chat.coordinate(withNormalizedOffset: .init(dx: 1, dy: 1)).withOffset(.init(dx: -5, dy: -20))
    corner.press(forDuration: 0.05, thenDragTo: corner.withOffset(.init(dx: 90, dy: 200)))
    app.buttons["notebook-chat-tasks"].tap()
    let modes = app.segmentedControls["notebook-chat-browser-mode"]
    XCTAssertTrue(modes.waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["notebook-chat-project-all"].exists)
    modes.buttons["Чаты"].tap()
    let first = app.buttons["notebook-chat-task-7e7a1000-0000-4000-8000-000000000088"]
    let other = app.buttons["notebook-chat-task-7e7a1000-0000-4000-8000-000000000089"]
    XCTAssertTrue(first.waitForExistence(timeout: 5)); XCTAssertTrue(other.waitForExistence(timeout: 5))
    modes.buttons["Проекты"].tap()
    let folder = app.buttons["notebook-chat-project-terminal-fixture"]
    XCTAssertTrue(folder.waitForExistence(timeout: 5))
    // The selected project's folder was opened when this fixture selected it.
    if first.exists { folder.tap(); XCTAssertTrue(first.waitForNonExistence(timeout: 3)) }
    folder.tap(); XCTAssertTrue(first.waitForExistence(timeout: 5))
    app.buttons["notebook-chat-project-research-fixture"].tap()
    XCTAssertTrue(other.waitForExistence(timeout: 5))
    app.buttons["notebook-chat-project-empty-fixture"].tap()
    XCTAssertTrue(app.staticTexts["Нет чатов"].waitForExistence(timeout: 5))
    XCTAssertGreaterThan(first.frame.minX, folder.frame.minX + 20)
    XCTAssertGreaterThan(other.frame.minX, folder.frame.minX + 20)
    XCTAssertFalse(other.staticTexts["Исследование"].exists, "Folder rows do not reuse the context and layout of the all-chats projection")
    let proof = XCTAttachment(screenshot: app.screenshot()); proof.name = "chat-browser-project-folders"; proof.lifetime = .keepAlways; add(proof)
    modes.buttons["Чаты"].tap()
    XCTAssertTrue(first.waitForExistence(timeout: 3)); XCTAssertTrue(other.exists)
    XCTAssertFalse(folder.exists)
    other.tap()
    XCTAssertTrue(modes.waitForNonExistence(timeout: 3))
    XCTAssertTrue(app.buttons["notebook-chat-tasks"].staticTexts["Другой разговор"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.otherElements["notebook-terminal-panel"].exists, "Browsing and choosing a chat cannot start a shell")
    XCTAssertEqual(paper.frame, frame); XCTAssertEqual(paper.value as? String, ink)
  }

  func testHistoryOpensAndClosesRepeatedlyWithManySharedFragments() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-collaboration-fixture", "--notebook-history-performance-fixture"]
    launchPortraitFixture(app)
    for _ in 0..<5 {
      openSharedHistory(in: app)
      XCTAssertTrue(app.navigationBars["Совместные ходы"].waitForExistence(timeout: 2))
      XCTAssertTrue(app.buttons["Готово"].isHittable)
      app.buttons["Готово"].tap()
      XCTAssertTrue(app.navigationBars["Совместные ходы"].waitForNonExistence(timeout: 2))
    }
    let proof = XCTAttachment(screenshot: app.screenshot())
    proof.name = "history-remains-dismissible-after-five-openings"; proof.lifetime = .keepAlways; add(proof)
  }

  func testSharedActionUndoKeepsTheDrawingAndHumanPlacement() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-collaboration-fixture", "--notebook-simulator-finger-gestures"]
    launchPortraitFixture(app)
    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout:8))
    let drawing = paper.value as? String
    XCTAssertNotNil(drawing)
    let element = app.descendants(matching:.any).matching(identifier:"agent-element-shared-element").firstMatch
    XCTAssertTrue(element.waitForExistence(timeout:8))
    app.coordinate(withNormalizedOffset:.init(dx:0.22,dy:0.18)).press(forDuration:0.45,
      thenDragTo:app.coordinate(withNormalizedOffset:.init(dx:0.45,dy:0.25)))
    XCTAssertFalse(app.staticTexts["Укажите фрагмент · протяните для области"].exists)
    openSharedHistory(in: app)
    XCTAssertTrue(app.navigationBars["Совместные ходы"].waitForExistence(timeout: 3))
    let history = app.collectionViews["collaboration-history-list"]
    let result = app.buttons["show-action-result"].firstMatch
    // The newer human indication precedes the older action in the same history.
    // Scroll the real list to that action rather than assuming all rows are mounted.
    for _ in 0..<3 where !result.isHittable { history.swipeUp() }
    XCTAssertTrue(result.isHittable)
    result.tap()
    let showProof = XCTAttachment(screenshot: app.screenshot())
    showProof.name = "after-history-show"; showProof.lifetime = .keepAlways; add(showProof)
    XCTAssertTrue(element.waitForExistence(timeout:5))
    app.buttons["notebook-chat-toggle"].tap()
    element.tap()
    XCTAssertTrue(app.buttons["delete-agent-element"].waitForExistence(timeout:3))
    let card = app.descendants(matching: .any).matching(identifier: "notebook-context-count").firstMatch
    XCTAssertTrue(card.waitForExistence(timeout: 3), "Finger selection pins the object while the chat stays collapsed")
    for id in ["delete-agent-element", "resize-agent-element-bottomTrailing"] {
      let handle = app.descendants(matching: .any).matching(identifier: id).firstMatch
      let reachable = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in handle.isHittable }, object: nil)
      XCTAssertEqual(XCTWaiter.wait(for: [reachable], timeout: 3), .completed, "\(id): \(handle.debugDescription)")
    }
    let editingProof = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    editingProof.name = "finger-selection-keeps-editing-handles-reachable"
    editingProof.lifetime = .keepAlways; add(editingProof)
    let initial = element.frame
    element.coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.5)).press(forDuration:0.3,
      thenDragTo:element.coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.5)).withOffset(.init(dx:100,dy:60)),withVelocity:.slow,thenHoldForDuration:0)
    XCTAssertGreaterThan(element.frame.midX,initial.midX + 20)
    let moved = element.frame
    openSharedHistory(in: app)
    XCTAssertTrue(app.navigationBars["Совместные ходы"].waitForExistence(timeout: 3))
    let continuation = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Ваша доработка'")).firstMatch
    for _ in 0..<3 where !continuation.isHittable { history.swipeUp() }
    XCTAssertTrue(continuation.isHittable)
    app.buttons["Отменить этот ход"].firstMatch.tap()
    app.buttons["Готово"].tap()
    XCTAssertFalse(app.staticTexts["Ход отменён"].exists, "Undo does not add a board notification")
    XCTAssertTrue(element.exists)
    XCTAssertEqual(element.frame.midX,moved.midX,accuracy:2)
    app.buttons["drawing-tool-eraser"].tap()
    XCTAssertTrue(paper.waitForExistence(timeout:3))
    XCTAssertEqual(paper.value as? String,drawing,"Рукопись принадлежит человеку при указании, показе и отмене")
  }

  func testAgentChangesStayQuietAndHistoryKeepsItsActions() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-collaboration-fixture"]
    launchPortraitFixture(app)
    let notice = app.buttons["collaboration-dismiss"]
    XCTAssertFalse(notice.exists, "Agent work is highlighted on the object, not announced in a banner")
    openSharedHistory(in: app)
    XCTAssertTrue(app.buttons["Отменить этот ход"].firstMatch.waitForExistence(timeout:3))
    XCTAssertTrue(app.buttons["show-action-result"].firstMatch.exists)
  }

  func testFingerHoldSelectsARegionWithoutSwitchingTools() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-pointer-fixture", "--notebook-simulator-finger-gestures"]
    launchPortraitFixture(app)
    XCTAssertFalse(app.buttons["drawing-tool-pointer"].exists)
    XCTAssertTrue(app.otherElements["paper-input"].waitForExistence(timeout: 5))
    let start = app.coordinate(withNormalizedOffset:.init(dx:0.6,dy:0.25))
    let end = app.coordinate(withNormalizedOffset:.init(dx:0.85,dy:0.4))
    start.press(forDuration:0.45,thenDragTo:end)
    XCTAssertFalse(app.staticTexts["Укажите фрагмент · протяните для области"].exists)
    XCTAssertTrue(app.buttons["drawing-tool-eraser"].isHittable)
    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "notebook-context-count").firstMatch.waitForExistence(timeout: 3))
    openSharedHistory(in: app)
    XCTAssertTrue(app.navigationBars["Совместные ходы"].waitForExistence(timeout: 2))
    XCTAssertTrue(app.staticTexts["Область"].firstMatch.exists)
    let proof = XCTAttachment(screenshot: app.screenshot())
    proof.name = "human-pointer-prepared-source"; proof.lifetime = .keepAlways; add(proof)
    app.buttons["Готово"].tap()
    XCTAssertTrue(app.buttons["drawing-tool-eraser"].isHittable)
  }

  func testClosingQuestionRemovesVisibleIndicationAndHistoryCanResumeIt() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-pointer-fixture", "--notebook-simulator-finger-gestures"]
    launchPortraitFixture(app)
    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout: 5))
    let drawing = paper.value as? String
    let baseline = app.screenshot()
    // Read the real pixels along the bottom of the dragged rectangle, away
    // from the adjacent question card and its material/shadow.
    let edge = CGRect(x: 0.28, y: 0.338, width: 0.12, height: 0.004)
    app.coordinate(withNormalizedOffset: .init(dx: 0.24, dy: 0.20))
      .press(forDuration: 0.45, thenDragTo: app.coordinate(withNormalizedOffset: .init(dx: 0.48, dy: 0.34)))
    let card = app.descendants(matching: .any).matching(identifier: "notebook-context-count").firstMatch
    XCTAssertTrue(card.waitForExistence(timeout: 5))
    for attempt in 0..<2 {
      let indicated = app.screenshot()
      let indicatedProof = XCTAttachment(screenshot: indicated)
      indicatedProof.name = "indication-visible-\(attempt)"; indicatedProof.lifetime = .keepAlways; add(indicatedProof)
      XCTAssertGreaterThan(changedPixelShare(from: baseline, to: indicated, normalizedRect: edge), 0.04,
        "The selected frame must actually be visible before testing its removal")
      card.tap()
      app.buttons["notebook-context-clear"].tap()
      XCTAssertTrue(card.waitForNonExistence(timeout: 2))
      let closed = app.screenshot()
      let closedProof = XCTAttachment(screenshot: closed)
      closedProof.name = "indication-removed-\(attempt)"; closedProof.lifetime = .keepAlways; add(closedProof)
      XCTAssertLessThan(changedPixelShare(from: baseline, to: closed, normalizedRect: edge), 0.02,
        "Closing removes the actual selection pixels, not just the question card")
      XCTAssertEqual(paper.value as? String, drawing, "Removing indication never erases handwriting")
      if attempt == 0 {
        openSharedHistory(in: app)
        XCTAssertTrue(app.staticTexts["Область"].firstMatch.waitForExistence(timeout: 3))
        let resume = app.buttons["Продолжить этот фрагмент"]
        XCTAssertTrue(resume.waitForExistence(timeout: 2))
        resume.tap()
        app.buttons["Готово"].tap()
        // History opens from the expanded chat. Compare the same unobscured
        // paper as the baseline, not pixels covered by that unrelated window.
        app.buttons["notebook-chat-toggle"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 3))
      }
    }
  }

  func testHistoryReadsOlderContextsAndContinuesOneAddressedEntryPage() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-collaboration-fixture",
      "--notebook-history-performance-fixture", "--notebook-history-pages-fixture"]
    launchPortraitFixture(app)
    openSharedHistory(in: app)
    let nextContexts = app.buttons["context-directory-next"]
    XCTAssertTrue(nextContexts.waitForExistence(timeout: 5))
    nextContexts.tap()
    XCTAssertTrue(app.staticTexts["Фрагмент 88"].waitForExistence(timeout: 5))
    app.buttons["К новым фрагментам"].tap()
    let open = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "context-history-")).firstMatch
    XCTAssertTrue(open.waitForExistence(timeout: 5)); open.tap()
    XCTAssertTrue(app.staticTexts["Ответ 1"].waitForExistence(timeout: 5))
    let nextEntries = app.buttons["context-history-next"]
    XCTAssertTrue(nextEntries.exists); nextEntries.tap()
    XCTAssertTrue(app.staticTexts["Ответ 32"].waitForExistence(timeout: 5))
    XCTAssertFalse(nextEntries.exists, "The last bounded page does not invent another continuation")
    app.buttons["В начало"].tap()
    XCTAssertTrue(app.staticTexts["Ответ 1"].waitForExistence(timeout: 5))
    let proof = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    proof.name = "addressed-context-history"; proof.lifetime = .keepAlways; add(proof)
  }

  func testCodexPanelLeavesNavigationAndToolsReachableInBothOrientations() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    defer { XCUIDevice.shared.orientation = .portrait }
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture"]
    launchPortraitFixture(app)
    let panel = app.descendants(matching: .any).matching(identifier: "notebook-chat-panel").firstMatch
    let toggle = app.buttons["notebook-chat-toggle"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    for landscape in [false, true] {
      XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
      for expanded in [false, true] {
        if expanded { toggle.tap() }
        let controls = ["previous-page", "page-overview", "next-page",
          "pen-controls-toggle", "drawing-tool-eraser", "pen-settings"]
        let unobstructed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
          let window = app.frame, frame = panel.frame
          guard (window.width > window.height) == landscape,
            window.contains(frame), frame.width > (expanded ? 300 : 100),
            frame.width <= (expanded ? window.width - 36 : 344) + 1 else { return false }
          return controls.allSatisfy { id in
            let control = app.buttons[id]
            return control.exists && control.isHittable && !frame.intersects(control.frame)
          }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [unobstructed], timeout: 5), .completed,
          "Chat must not cover the existing navigation or Pencil controls")
        let proof = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        proof.name = "chat-controls-\(landscape ? "landscape" : "portrait")-\(expanded ? "expanded" : "collapsed")"
        proof.lifetime = .keepAlways; add(proof)
      }
      toggle.tap()
    }
  }

  func testCodexPanelCanCollapseFromTheWholeButtonAfterCreatingAChat() {
    assertNewChatDoesNotBlockCollapse(transcript: false)
  }

  func testCodePencilPersistsBesideNativeTextAndOwnUndoDoesNotTouchPaper() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-code-document-fixture", "--notebook-code-pencil-fixture"]
    launchPortraitFixture(app)
    let paper = app.otherElements["paper-input"], frame = paper.frame, previousInk = paper.value as? String
    app.buttons["notebook-chat-toggle"].tap(); app.buttons["notebook-file-reopen"].tap()
    XCTAssertTrue(app.otherElements["notebook-code-document"].waitForExistence(timeout: 3))
    app.buttons["notebook-chat-toggle"].tap()
    let ink = app.otherElements["notebook-code-ink"]
    XCTAssertTrue(ink.waitForExistence(timeout: 3))
    ink.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.2)).press(forDuration: 0.1,
      thenDragTo: ink.coordinate(withNormalizedOffset: .init(dx: 0.8, dy: 0.3)))
    let accepted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1 действий пера"), object: ink)
    XCTAssertEqual(XCTWaiter.wait(for: [accepted], timeout: 4), .completed)
    XCTAssertEqual(paper.frame, frame); XCTAssertEqual(paper.value as? String, previousInk)
    let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "code-native-pencil-contact"; shot.lifetime = .keepAlways; add(shot)
    app.buttons["code-xmark"].tap()
    app.buttons["notebook-chat-toggle"].tap(); app.buttons["notebook-file-reopen"].tap()
    XCTAssertTrue(ink.waitForExistence(timeout: 3))
    let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1 действий пера"), object: ink)
    XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 4), .completed)
    app.buttons["code-arrow.uturn.backward"].tap()
    let undone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "0 действий пера"), object: ink)
    XCTAssertEqual(XCTWaiter.wait(for: [undone], timeout: 4), .completed)
    XCTAssertEqual(paper.frame, frame); XCTAssertEqual(paper.value as? String, previousInk)
  }

  func testCodeNoteCanBeReboundThroughTheActualControlsWithoutChangingItsOriginalText() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-code-document-fixture", "--notebook-code-pencil-fixture"]
    launchPortraitFixture(app)
    let paper = app.otherElements["paper-input"], frame = paper.frame, previousInk = paper.value as? String
    app.buttons["notebook-chat-toggle"].tap(); app.buttons["notebook-file-reopen"].tap()
    XCTAssertTrue(app.otherElements["notebook-code-document"].waitForExistence(timeout: 3))
    app.buttons["notebook-chat-toggle"].tap()
    let ink = app.otherElements["notebook-code-ink"]
    ink.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.2)).press(forDuration: 0.1,
      thenDragTo: ink.coordinate(withNormalizedOffset: .init(dx: 0.8, dy: 0.3)))
    let marker = app.buttons["Открыть исходный код с пометкой"].firstMatch
    XCTAssertTrue(marker.waitForExistence(timeout: 4)); marker.tap()
    let original = app.textViews["notebook-reviewed-code-text"]
    XCTAssertTrue(original.waitForExistence(timeout: 3))
    let material = original.value as? String
    app.buttons["Перепривязать"].tap()
    XCTAssertTrue(app.buttons["code-rebind-selection"].waitForExistence(timeout: 3))
    app.buttons["code-keyboard"].tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 4))
    app.textViews["notebook-code-text"].typeText("# new destination\n")
    app.buttons["code-keyboard.chevron.compact.down"].tap()
    app.buttons["code-rebind-selection"].tap()
    XCTAssertTrue(app.buttons["code-rebind-selection"].waitForNonExistence(timeout: 4))
    XCTAssertTrue(marker.waitForExistence(timeout: 4)); marker.tap()
    XCTAssertTrue(original.waitForExistence(timeout: 3))
    XCTAssertEqual(original.value as? String, material)
    let proof = XCTAttachment(screenshot: app.screenshot()); proof.name = "rebound-note-keeps-original-text-and-ink"; proof.lifetime = .keepAlways; add(proof)
    app.buttons["Готово"].tap(); app.buttons["code-xmark"].tap()
    XCTAssertEqual(paper.frame, frame); XCTAssertEqual(paper.value as? String, previousInk)
  }

  func testCodeDocumentScrollsEditsAndClosesWithoutMovingPaper() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-code-document-fixture"]
    launchPortraitFixture(app)
    let paper = app.otherElements["paper-input"], frame = paper.frame, ink = paper.value as? String
    app.buttons["notebook-chat-toggle"].tap()
    let files = app.scrollViews["notebook-project-files"], composer = app.otherElements["notebook-chat-composer"]
    XCTAssertTrue(files.waitForExistence(timeout: 3))
    XCTAssertGreaterThanOrEqual(files.frame.minX, composer.frame.maxX, "The one divider separates conversation/composer on the left from files on the right")
    let panelShot = XCTAttachment(screenshot: app.screenshot()); panelShot.name = "files-right-of-conversation"; panelShot.lifetime = .keepAlways; add(panelShot)
    app.buttons["notebook-file-reopen"].tap()
    XCTAssertTrue(app.otherElements["notebook-code-document"].waitForExistence(timeout: 3))
    app.buttons["notebook-chat-toggle"].tap()
    let text = app.descendants(matching: .any).matching(identifier: "notebook-code-text").firstMatch
    XCTAssertTrue(text.waitForExistence(timeout: 3))
    let from = text.coordinate(withNormalizedOffset: .init(dx: 0.3, dy: 0.7))
    from.press(forDuration: 0.05, thenDragTo: text.coordinate(withNormalizedOffset: .init(dx: 0.3, dy: 0.3)))
    XCTAssertEqual(paper.frame, frame); XCTAssertEqual(paper.value as? String, ink)
    app.buttons["code-keyboard"].tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 4))
    text.typeText("# written on iPad\n")
    app.buttons["code-keyboard.chevron.compact.down"].tap()
    let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "code-scroll-and-native-keyboard"; shot.lifetime = .keepAlways; add(shot)
    app.buttons["code-xmark"].tap()
    XCTAssertFalse(text.exists)
    XCTAssertEqual(paper.frame, frame); XCTAssertEqual(paper.value as? String, ink)
    app.buttons["notebook-chat-toggle"].tap(); app.buttons["notebook-file-reopen"].tap()
    XCTAssertTrue(text.waitForExistence(timeout: 3))
    XCTAssertTrue((text.value as? String)?.contains("# written on iPad") == true)
  }

  func testChatMovesResizesAndOpensSettingsWithoutMovingPaper() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture"]
    launchPortraitFixture(app)
    XCTAssertFalse(app.buttons["pairing-settings"].exists)
    XCTAssertFalse(app.buttons["collaboration-history"].exists)
    app.buttons["notebook-chat-toggle"].tap()
    let panel = app.descendants(matching: .any).matching(identifier: "notebook-chat-panel").firstMatch
    let paper = app.otherElements["paper-input"], paperFrame = paper.frame, drawing = paper.value as? String
    let before = panel.frame
    let title = app.buttons["notebook-chat-tasks"]
    let titleBefore = app.staticTexts["Новый чат"].exists
    let translation = CGVector(dx: 30 - before.minX, dy: 100 - before.minY)
    let grip = title.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
    grip.press(forDuration: 0.1, thenDragTo: grip.withOffset(translation))
    XCTAssertEqual(panel.frame.minX, 30, accuracy: 4)
    XCTAssertEqual(panel.frame.minY, 100, accuracy: 4)
    XCTAssertEqual(app.staticTexts["Новый чат"].exists, titleBefore, "Dragging the header must not also choose a conversation")
    XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "notebook-chat-resize").firstMatch.exists)
    for (leading, top, dx, dy) in [(false, true, -40.0, 30.0), (true, true, 30.0, 20.0), (true, false, -20.0, -30.0), (false, false, 35.0, 25.0)] {
      let moved = panel.frame
      let corner = panel.coordinate(withNormalizedOffset: .zero).withOffset(.init(dx: leading ? 10 : moved.width - 10, dy: top ? 10 : moved.height - 10))
      corner.press(forDuration: 0.1, thenDragTo: corner.withOffset(.init(dx: dx, dy: dy)))
      let widthLimit = leading ? moved.maxX - 18 : app.frame.maxX - 18 - moved.minX
      XCTAssertEqual(panel.frame.width, min(widthLimit, max(320, moved.width + (leading ? -dx : dx))), accuracy: 4)
      XCTAssertEqual(panel.frame.height, max(240, moved.height + (top ? -dy : dy)), accuracy: 4)
      XCTAssertEqual(leading ? panel.frame.maxX : panel.frame.minX, leading ? moved.maxX : moved.minX, accuracy: 1)
      XCTAssertEqual(top ? panel.frame.maxY : panel.frame.minY, top ? moved.maxY : moved.minY, accuracy: 1)
      XCTAssertEqual(paper.frame, paperFrame); XCTAssertEqual(paper.value as? String, drawing)
    }
    let resized = panel.frame
    app.buttons["notebook-chat-toggle"].tap(); app.buttons["notebook-chat-toggle"].tap()
    XCTAssertEqual(panel.frame, resized)
    XCTAssertEqual(paper.frame, paperFrame)
    XCTAssertEqual(paper.value as? String, drawing)
    let proof = XCTAttachment(screenshot: app.screenshot())
    proof.name = "floating-chat-moved-and-resized"; proof.lifetime = .keepAlways; add(proof)
    openSharedHistory(in: app)
    XCTAssertTrue(app.navigationBars["Совместные ходы"].waitForExistence(timeout: 3))
    app.buttons["Готово"].tap()
    app.buttons["notebook-chat-menu"].tap()
    XCTAssertTrue(app.buttons["pairing-settings"].waitForExistence(timeout: 2))
    app.buttons["pairing-settings"].tap()
    XCTAssertTrue(app.navigationBars["Соединение"].waitForExistence(timeout: 3))
    app.buttons["Готово"].tap()
    XCTAssertEqual(paper.frame, paperFrame)
    XCTAssertEqual(paper.value as? String, drawing)
    app.terminate()
    launchPortraitFixture(app)
    app.buttons["notebook-chat-toggle"].tap()
    XCTAssertEqual(panel.frame, resized, "The scene restores the user's geometry after a cold launch")
  }

  func testCodexPanelCanCollapseAfterNewChatWithAMountedTranscript() {
    assertNewChatDoesNotBlockCollapse(transcript: true)
  }

  func testCodexPanelCanCollapseAfterNewChatWithTheKeyboard() {
    assertNewChatDoesNotBlockCollapse(transcript: true, keyboard: true)
  }

  private func assertNewChatDoesNotBlockCollapse(transcript: Bool, keyboard: Bool = false) {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    defer { XCUIDevice.shared.orientation = .portrait }
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture"]
    if transcript { app.launchArguments.append("--notebook-chat-conversation-fixture") }
    launchPortraitFixture(app)
    let toggle = app.buttons["notebook-chat-toggle"]
    let panel = app.descendants(matching: .any).matching(identifier: "notebook-chat-panel").firstMatch
    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    let offsets = [CGVector(dx: 0.5, dy: 0.5), .init(dx: 0.1, dy: 0.1), .init(dx: 0.9, dy: 0.9),
      .init(dx: 0.1, dy: 0.9), .init(dx: 0.9, dy: 0.1)]
    for (index, offset) in offsets.enumerated() {
      toggle.tap()
      if transcript && index == 0 {
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "notebook-chat-transcript")
          .firstMatch.waitForExistence(timeout: 3))
      }
      if keyboard {
        let field = app.descendants(matching: .any).matching(identifier: "notebook-chat-text").firstMatch
        field.tap(); field.typeText("Keep this draft")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 4))
      }
      let create = app.buttons["notebook-chat-new"]
      XCTAssertTrue(create.waitForExistence(timeout: 3)); create.tap()
      XCTAssertTrue(toggle.isEnabled)
      XCTAssertEqual(toggle.frame.width, 44, accuracy: 1)
      XCTAssertEqual(toggle.frame.height, 44, accuracy: 1)
      // A person taps the 44-point control, not a one-pixel SF Symbol stroke.
      toggle.coordinate(withNormalizedOffset: offset).tap()
      let collapsed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
        panel.frame.width <= 113 && panel.frame.height <= 49 && !create.exists
      }, object: nil)
      let result = XCTWaiter.wait(for: [collapsed], timeout: 3)
      let proof = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
      proof.name = "chat-collapse-after-new-\(offset.dx)-\(offset.dy)"; proof.lifetime = .keepAlways; add(proof)
      XCTAssertEqual(result, .completed, "The whole 44-point control must collapse the panel after New Chat")
    }
  }

  func testCodexPanelKeepsDraftWithoutMovingPaperOnCollapseAndRotation() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    defer { XCUIDevice.shared.orientation = .portrait }
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture"]
    launchPortraitFixture(app)
    let toggle = app.buttons["notebook-chat-toggle"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 5)); toggle.tap()
    let field = app.descendants(matching: .any).matching(identifier: "notebook-chat-text").firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 3))
    XCTAssertFalse(app.keyboards.firstMatch.exists, "Opening chat does not steal Pencil focus")
    let paper = app.otherElements["paper-input"], before = app.otherElements["paper-input"].frame
    field.tap(); field.typeText("Keep this draft")
    XCTAssertEqual(paper.frame, before, "Only chat follows the keyboard safe area")
    toggle.tap(); toggle.tap()
    XCTAssertEqual(field.value as? String, "Keep this draft")
    field.tap()
    let keyboard = app.keyboards.firstMatch
    XCTAssertTrue(keyboard.waitForExistence(timeout: 4), "The rotation scenario starts with actual system input, not a collapsed keyboard")
    XCUIDevice.shared.orientation = .landscapeLeft
    let panel = app.descendants(matching: .any).matching(identifier: "notebook-chat-panel").firstMatch
    var stableSince: Date?, previousWindow = CGRect.zero, previousPanel = CGRect.zero
    let inside = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      guard keyboard.exists else { stableSince = nil; return false }
      let window = app.frame, frame = panel.frame, keys = keyboard.frame
      guard window.width > window.height, window.insetBy(dx: -1, dy: -1).contains(frame),
        frame.width > 300, frame.height > 100, abs(keys.width - window.width) <= 1,
        keys.height > 0, window.contains(keys), keys.midY > window.midY,
        frame.maxY <= keys.minY + 1 else { stableSince = nil; return false }
      if window != previousWindow || frame != previousPanel { previousWindow = window; previousPanel = frame; stableSince = Date(); return false }
      if stableSince == nil { stableSince = Date() }
      return Date().timeIntervalSince(stableSince!) >= 0.5
    }, object: app)
    let rotation = XCTWaiter.wait(for: [inside], timeout: 5)
    let keyboardDescription = keyboard.exists ? String(describing: keyboard.frame) : "absent"
    let geometry = XCTAttachment(string: "window=\(app.frame) panel=\(panel.frame) keyboard=\(keyboardDescription)\n" + app.debugDescription)
    geometry.name = "codex-keyboard-rotation-geometry"; geometry.lifetime = .keepAlways; add(geometry)
    XCTAssertEqual(rotation, .completed)
    XCTAssertEqual(field.value as? String, "Keep this draft")
    XCTAssertTrue(field.isHittable, "The fixed composer stays reachable without scrolling the panel")
    XCTAssertLessThanOrEqual(field.frame.maxY, keyboard.frame.minY + 1)
    // The known one-line draft ends before the field's right edge. A real tap
    // in that empty first-line area sets the insertion point after its glyphs;
    // a hardware-key shortcut need not control the software keyboard selection.
    field.coordinate(withNormalizedOffset: .init(dx: 0.95, dy: 0.25)).tap()
    field.typeText(" after rotation")
    XCTAssertEqual(field.value as? String, "Keep this draft after rotation")
    XCTAssertFalse(app.buttons["notebook-chat-send"].isEnabled, "An offline fixture invents neither a task nor an executor")
    let proof = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    proof.name = "codex-panel-keyboard-landscape"; proof.lifetime = .keepAlways; add(proof)
  }

  func testEraserAndPenSelectDirectlyBeforeOpeningPenSettings() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture"]
    launchPortraitFixture(app)

    let pen = app.buttons["pen-controls-toggle"]
    let eraser = app.buttons["drawing-tool-eraser"]
    XCTAssertTrue(pen.waitForExistence(timeout: 5))
    XCTAssertTrue(
      eraser.waitForExistence(timeout: 2),
      "Ластик должен быть доступен рядом с ручкой без раскрытия настроек"
    )
    XCTAssertEqual(pen.frame.width, pen.frame.height, accuracy: 1)
    XCTAssertEqual(eraser.frame.width, eraser.frame.height, accuracy: 1)
    XCTAssertEqual(pen.frame.width, eraser.frame.width, accuracy: 1)
    XCTAssertFalse(pen.frame.intersects(eraser.frame))
    XCTAssertEqual(pen.frame.midY, eraser.frame.midY, accuracy: 1)
    XCTAssertLessThanOrEqual(
      abs(eraser.frame.minX - pen.frame.maxX),
      10,
      "Ластик должен стоять отдельным кружком непосредственно рядом с ручкой"
    )

    let settings = app.sliders["pen-width"]
    eraser.tap()
    XCTAssertTrue(eraser.isSelected)
    let inactivePen = pen.screenshot()
    pen.tap()
    XCTAssertFalse(settings.exists, "Первое касание выбирает ручку и сохраняет компактную панель")
    XCTAssertTrue(pen.isSelected)
    XCTAssertFalse(eraser.isSelected)
    let selectedPen = pen.screenshot()
    // Sample the selection circle beside the icon, so the pen's ink colour
    // alone cannot satisfy the visible-selection contract.
    let selectionBackground = CGRect(x: 0.2, y: 0.4, width: 0.08, height: 0.2)
    XCTAssertGreaterThan(
      changedPixelShare(from: inactivePen, to: selectedPen, normalizedRect: selectionBackground),
      0.8,
      "Выбранная ручка должна показывать круговую подложку, как ластик"
    )
    let penProof = XCTAttachment(screenshot: app.screenshot())
    penProof.name = "selected-pen-highlight"
    penProof.lifetime = .keepAlways
    add(penProof)

    pen.tap()
    XCTAssertFalse(settings.exists, "Повторное касание тоже только выбирает ручку")
    app.buttons["pen-settings"].tap()
    XCTAssertTrue(settings.waitForExistence(timeout: 2), "Настройки открывает отдельное действие")
    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "pen-stroke-preview").firstMatch.waitForExistence(timeout: 2))
    let previewProof = XCTAttachment(screenshot: app.screenshot())
    previewProof.name = "actual-pen-pressure-preview"; previewProof.lifetime = .keepAlways; add(previewProof)
    app.buttons["Закрыть настройки"].tap()
    XCTAssertTrue(settings.waitForNonExistence(timeout: 2))
    XCTAssertTrue(pen.isSelected, "Закрытие настроек сохраняет выбранную ручку")

    XCTAssertFalse(app.buttons["drawing-tool-pointer"].exists)
    XCTAssertTrue(pen.isSelected, "Selection by finger does not add a drawing mode")

    app.buttons["pen-settings"].tap()
    XCTAssertTrue(settings.waitForExistence(timeout: 2))
    app.buttons["Закрыть настройки"].tap()
    XCTAssertTrue(settings.waitForNonExistence(timeout: 2))
    XCTAssertTrue(pen.isSelected, "Настройки не создают скрытого инструмента редактирования")
  }

  func testEveryArtifactCornerResizesWithoutMovingTheOppositeCornerOrPaper() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-collaboration-fixture", "--notebook-simulator-finger-gestures"]
    launchPortraitFixture(app)
    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout: 8))
    let drawing = paper.value as? String, paperFrame = paper.frame
    let element = app.descendants(matching: .any).matching(identifier: "agent-element-shared-element").firstMatch
    XCTAssertTrue(element.waitForExistence(timeout: 8))
    let toggle = app.buttons["notebook-chat-toggle"]
    if toggle.label == "Свернуть чат" { toggle.tap() }
    element.tap()
    XCTAssertTrue(app.buttons["delete-agent-element"].waitForExistence(timeout: 4))
    XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "resize-agent-element").firstMatch.exists)
    for (name, leading, top) in [("topLeading", true, true), ("topTrailing", false, true), ("bottomLeading", true, false), ("bottomTrailing", false, false)] {
      let corner = app.descendants(matching: .any).matching(identifier: "resize-agent-element-" + name).firstMatch
      XCTAssertTrue(corner.waitForExistence(timeout: 4)); XCTAssertTrue(corner.isHittable)
      let before = element.frame
      let start = corner.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
      start.press(forDuration: 0.05, thenDragTo: start.withOffset(.init(dx: leading ? -22 : 22, dy: top ? -18 : 18)), withVelocity: .slow, thenHoldForDuration: 0)
      let resized = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in element.frame.width > before.width + 10 && element.frame.height > before.height + 8 }, object: nil)
      let outcome = XCTWaiter.wait(for: [resized], timeout: 4)
      if outcome != .completed {
        let proof = XCTAttachment(screenshot: app.screenshot()); proof.name = "corner-resize-failure"; proof.lifetime = .keepAlways; add(proof)
      }
      XCTAssertEqual(outcome, .completed, "Corner \(name): \(before) -> \(element.frame), target \(corner.frame)")
      XCTAssertEqual(leading ? element.frame.maxX : element.frame.minX, leading ? before.maxX : before.minX, accuracy: 2)
      XCTAssertEqual(top ? element.frame.maxY : element.frame.minY, top ? before.maxY : before.minY, accuracy: 2)
      XCTAssertEqual(paper.frame, paperFrame); XCTAssertEqual(paper.value as? String, drawing)
      XCTAssertEqual(app.buttons.matching(identifier: "delete-agent-element").count, 1)
    }
    let proof = XCTAttachment(screenshot: app.screenshot()); proof.name = "four-corners-one-frame"; proof.lifetime = .keepAlways; add(proof)
  }

  func testSuccessiveArtifactChoicesLeaveOneFrameAndClearTogether() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-agent-element-fixture",
      "--notebook-selection-transition-fixture", "--notebook-simulator-finger-gestures"]
    launchPortraitFixture(app)
    let first = app.otherElements["agent-element-shared-element"]
    let second = app.otherElements["agent-element-second-element"]
    XCTAssertTrue(first.waitForExistence(timeout: 8)); XCTAssertTrue(second.waitForExistence(timeout: 8))
    let paper = app.otherElements["paper-input"], paperFrame = paper.frame, ink = paper.value as? String
    let baseline = app.screenshot()
    let frame = first.frame, screen = app.frame
    let edge = CGRect(x: (frame.minX + frame.width * 0.2) / screen.width,
      y: (frame.minY - 2) / screen.height, width: frame.width * 0.5 / screen.width, height: 4 / screen.height)
    first.tap()
    XCTAssertEqual(app.buttons.matching(identifier: "delete-agent-element").count, 1)
    let selected = app.screenshot()
    XCTAssertGreaterThan(changedPixelShare(from: baseline, to: selected, normalizedRect: edge), 0.03)
    second.tap()
    XCTAssertEqual(app.buttons.matching(identifier: "delete-agent-element").count, 1)
    XCTAssertGreaterThan(app.buttons["delete-agent-element"].frame.midY, second.frame.minY - 65)
    let replaced = app.screenshot()
    XCTAssertLessThan(changedPixelShare(from: baseline, to: replaced, normalizedRect: edge), 0.02,
      "The previous artifact cannot retain a context outline after the next choice")
    let count = app.buttons["notebook-context-count"]
    XCTAssertTrue(count.waitForExistence(timeout: 3)); XCTAssertEqual(count.value as? String, "1")
    count.tap(); app.buttons["notebook-context-clear"].tap()
    XCTAssertTrue(count.waitForNonExistence(timeout: 3))
    XCTAssertEqual(app.buttons.matching(identifier: "delete-agent-element").count, 0,
      "Clearing context also clears editing, not just the counter")
    first.tap()
    XCTAssertTrue(count.waitForExistence(timeout: 3))
    paper.coordinate(withNormalizedOffset: .init(dx: 0.86, dy: 0.16)).tap()
    XCTAssertTrue(count.waitForNonExistence(timeout: 3))
    XCTAssertEqual(app.buttons.matching(identifier: "delete-agent-element").count, 0)
    XCTAssertEqual(paper.frame, paperFrame); XCTAssertEqual(paper.value as? String, ink)
    let proof = XCTAttachment(screenshot: replaced)
    proof.name = "only-second-artifact-selected"; proof.lifetime = .keepAlways; add(proof)
  }

  func testPersonMovesAndDeletesAnAgentElement() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-agent-element-fixture",
      "--notebook-simulator-finger-gestures",
    ]
    launchPortraitFixture(app)

    let sharedElement = app.otherElements["agent-element-shared-element"]
    XCTAssertTrue(sharedElement.waitForExistence(timeout: 8))
    let initialFrame = sharedElement.frame
    let paper = app.otherElements["paper-input"]
    let paperFrame = paper.frame, drawing = paper.value as? String

    sharedElement.tap()
    let delete = app.buttons["delete-agent-element"]
    XCTAssertTrue(
      delete.waitForExistence(timeout: 3),
      "Выбранный общий элемент должен показать действие удаления"
    )
    XCTAssertFalse(app.descendants(matching: .any)["move-agent-element"].exists)
    XCTAssertFalse(app.descendants(matching: .any)["agent-question-card"].exists)
    let count = app.buttons["notebook-context-count"]
    XCTAssertTrue(count.waitForExistence(timeout: 3))
    XCTAssertEqual(count.value as? String, "1")
    XCTAssertLessThan(count.frame.width, 45)

    var expectedFrame = initialFrame
    for delta in [CGVector(dx: 100, dy: 60), CGVector(dx: -60, dy: 40)] {
      let start = sharedElement.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
      start.press(forDuration: 0.3, thenDragTo: start.withOffset(delta),
        withVelocity: .slow, thenHoldForDuration: 0)
      expectedFrame = expectedFrame.offsetBy(dx: delta.dx, dy: delta.dy)
      XCTAssertEqual(sharedElement.frame.minX, expectedFrame.minX, accuracy: 3,
        "Следующий жест начинается с принятого положения, без возврата к прежнему")
      XCTAssertEqual(sharedElement.frame.minY, expectedFrame.minY, accuracy: 3)
      XCTAssertEqual(paper.frame, paperFrame); XCTAssertEqual(paper.value as? String, drawing)
    }

    XCTAssertEqual(paper.frame, paperFrame)
    XCTAssertEqual(paper.value as? String, drawing)
    XCTAssertEqual(count.value as? String, "1", "Moving keeps the original pinned source")
    let proof = XCTAttachment(screenshot: app.screenshot())
    proof.name = "body-hold-moved-artifact-with-compact-context-count"; proof.lifetime = .keepAlways; add(proof)
    app.buttons["notebook-chat-toggle"].tap()
    XCTAssertTrue(count.waitForExistence(timeout: 3)); XCTAssertEqual(count.value as? String, "1")
    XCTAssertFalse(app.staticTexts["Амир указал область"].exists)
    app.buttons["notebook-chat-toggle"].tap()
    XCTAssertEqual(paper.frame, paperFrame)

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
    launchPortraitFixture(app)

    // HTML page regions are siblings of the continuous text flow in WebKit's
    // accessibility tree. The UIKit shell owns the actual current document.
    let firstPage = app.otherElements["page-turn-page-0"].firstMatch
    XCTAssertTrue(firstPage.waitForExistence(timeout: 8))
    let heading = firstPage.staticTexts["Живая математика"].firstMatch
    XCTAssertTrue(
      heading.waitForExistence(timeout: 8),
      "Markdown должен стать читаемым текстом текущей страницы WebKit"
    )
    XCTAssertTrue(heading.isHittable, "Читаемый Markdown должен принимать касание")
    heading.doubleTap()

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
    XCTAssertTrue(
      app.keyboards.firstMatch.waitForExistence(timeout: 5),
      "Редактор должен получить клавиатуру до синтезированного ввода"
    )
    editor.typeText("\n\nНовая строка\n\n")

    if (editor.value as? String)?.contains("Новая строка") != true {
      let hierarchy = XCTAttachment(string: app.debugDescription)
      hierarchy.name = "Document editor after keyboard input"
      hierarchy.lifetime = .keepAlways
      add(hierarchy)
    }
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
    launchPortraitFixture(app)

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
    launchPortraitFixture(app)

    let firstPage = app.otherElements.matching(
      NSPredicate(format: "label BEGINSWITH 'Страница 1 из '")
    ).firstMatch
    XCTAssertTrue(
      firstPage.waitForExistence(timeout: 8),
      "WebKit должен разбить содержание на конечные листы"
    )
    let surface = app.otherElements["page-turn-surface"]
    let firstFrame = firstPage.frame
    let firstCount = firstPage.label.components(separatedBy: " из ").last
    await fulfillment(of: [XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value BEGINSWITH 'Страница 1 из ' AND value != 'Страница 1 из 1'"), object: surface
    )], timeout: 8)
    XCTAssertEqual(
      firstFrame.height / firstFrame.width,
      841.88976378 / 595.275590551,
      accuracy: 0.03,
      "Экранный лист должен сохранять физическую пропорцию A4"
    )
    // Each UIKit sheet now receives one prepared physical DOM fragment, not
    // the entire offscreen document. The next sheet must be checked after a
    // real page curl, rather than requiring deleted offscreen paper nodes.
    surface.swipeLeft()
    await fulfillment(of: [XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value BEGINSWITH 'Страница 2 из '"), object: surface
    )], timeout: 3)
    let secondSheet = app.otherElements["page-turn-page-1"]
    let secondPage = secondSheet.otherElements.matching(
      NSPredicate(format: "label BEGINSWITH 'Страница 2 из '")
    ).firstMatch
    XCTAssertTrue(
      secondPage.waitForExistence(timeout: 3),
      "Длинный текст должен перейти на второй лист"
    )
    let centered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      secondPage.exists && abs(secondPage.frame.midX - firstFrame.midX) <= 4
    }, object: nil)
    await fulfillment(of: [centered], timeout: 3)
    XCTAssertEqual(secondPage.label.components(separatedBy: " из ").last, firstCount)
    XCTAssertEqual(secondPage.frame.width, firstFrame.width, accuracy: 1)
    XCTAssertEqual(secondPage.frame.height, firstFrame.height, accuracy: 1)
    XCTAssertEqual(
      secondPage.frame.height / secondPage.frame.width,
      841.88976378 / 595.275590551,
      accuracy: 0.03,
      "Продолжение остаётся отдельным листом A4, не вертикальной лентой"
    )
    // Accessibility appends its localized role (for example ", область") to
    // the paper label; the page address remains its prefix, not the whole label.
    let pageLabels = secondSheet.otherElements.matching(NSPredicate(format: "label BEGINSWITH 'Страница '"))
      .allElementsBoundByIndex.map(\.label)
    let addresses = XCTAttachment(string: pageLabels.joined(separator: "\n"))
    addresses.name = "finite-A4-native-accessibility-page-addresses"; addresses.lifetime = .keepAlways; add(addresses)
    XCTAssertEqual(Set(pageLabels), [secondPage.label],
      "Физическая оболочка не содержит копий чужих листов")
    let proof = XCTAttachment(screenshot: app.screenshot())
    proof.name = "finite-A4-page-after-native-curl"; proof.lifetime = .keepAlways; add(proof)
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
    launchPortraitFixture(app)

    let selectedSheet = app.otherElements["page-turn-page-2"]
    let thirdPage = selectedSheet.otherElements.matching(
      NSPredicate(format: "label BEGINSWITH 'Страница 3 из '")
    ).firstMatch
    XCTAssertTrue(thirdPage.waitForExistence(timeout: 8))
    // WebKit publishes the document tree before its fixed page is positioned.
    // The selected sheet's completed placement owns this assertion.
    let centered = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        thirdPage.exists && abs(thirdPage.frame.midX - app.frame.midX) <= 4
      },
      object: nil
    )
    await fulfillment(of: [centered], timeout: 8)
    XCTAssertEqual(
      thirdPage.frame.midX,
      app.frame.midX,
      accuracy: 4,
      "SessionPresence должен поставить выбранный физический лист в центр"
    )

    let storedText = try visibleDocumentText(app: app, surface: app.otherElements["page-turn-surface"], name: "stored-document-page-3")
    // A marker in the old complete accessibility DOM could exist on an
    // unshown column. Compare actual visible text with an independent landing
    // through two native turns, without baking a typesetting boundary into IDs.
    app.terminate()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-document-runtime-fixture"]
    launchPortraitFixture(app)
    let surface = app.otherElements["page-turn-surface"]
    await fulfillment(of: [XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value BEGINSWITH 'Страница 1 из ' AND value != 'Страница 1 из 1'"), object: surface
    )], timeout: 8)
    for page in 2...3 {
      // Unlike an early swipe into an unprepared neighbour, the page control
      // retains an explicit destination until UIKit can install that sheet.
      app.buttons["next-page"].tap()
      await fulfillment(of: [XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "value BEGINSWITH %@", "Страница \(page) из "), object: surface
      )], timeout: 3)
      let paper = app.otherElements["page-turn-page-\(page - 1)"].otherElements.matching(
        NSPredicate(format: "label BEGINSWITH %@", "Страница \(page) из ")
      ).firstMatch
      XCTAssertTrue(paper.waitForExistence(timeout: 3))
      await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
        paper.exists && abs(paper.frame.midX - app.frame.midX) <= 4
      }, object: nil)], timeout: 3)
    }
    let turnedText = try visibleDocumentText(app: app, surface: surface, name: "turned-document-page-3-reference")
    let sections = try NSRegularExpression(pattern: #"Раздел\s+(\d+)"#)
    func sectionIDs(_ text: String) -> [String] {
      sections.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
        String(text[Range($0.range(at: 1), in: text)!])
      }
    }
    XCTAssertGreaterThanOrEqual(sectionIDs(storedText).count, 4)
    XCTAssertEqual(sectionIDs(storedText), sectionIDs(turnedText),
      "Сохранённый выбор должен показывать тот же физический лист, что и два настоящих перелистывания")
  }

  func testNotebookPageTurnCommitsBothDirections() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture"]
    launchPortraitFixture(app)

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
    launchPortraitFixture(app)

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
    launchPortraitFixture(app)

    let surface = app.otherElements["page-turn-surface"]
    XCTAssertTrue(surface.waitForExistence(timeout: 8))
    let paginationReady = XCTNSPredicateExpectation(
      predicate: NSPredicate(
        format: "value BEGINSWITH 'Страница 1 из ' AND value != 'Страница 1 из 1'"
      ),
      object: surface
    )
    await fulfillment(of: [paginationReady], timeout: 8)
    try await Task.sleep(for: .seconds(2.5))
    surface.swipeLeft()

    let landed = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value BEGINSWITH 'Страница 2 из '"),
      object: surface
    )
    await fulfillment(of: [landed], timeout: 3)

    let secondText = try visibleDocumentText(app: app, surface: surface, name: "document-page-2")
    surface.swipeLeft()
    await fulfillment(of: [XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value BEGINSWITH 'Страница 3 из '"), object: surface
    )], timeout: 3)
    try await Task.sleep(for: .milliseconds(600))
    let thirdText = try visibleDocumentText(app: app, surface: surface, name: "document-page-3")
    XCTAssertNotEqual(secondText, thirdText, "Соседние листы показывают разные фрагменты текста")
    surface.swipeRight()
    await fulfillment(of: [XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value BEGINSWITH 'Страница 2 из '"), object: surface
    )], timeout: 3)
    try await Task.sleep(for: .milliseconds(600))
    let returnedText = try visibleDocumentText(app: app, surface: surface, name: "document-page-2-return")
    let sections = try NSRegularExpression(pattern: #"Раздел\s+(\d+)"#)
    func sectionIDs(_ text: String) -> [String] {
      sections.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
        String(text[Range($0.range(at: 1), in: text)!])
      }
    }
    XCTAssertGreaterThanOrEqual(sectionIDs(secondText).count, 4)
    XCTAssertNotEqual(sectionIDs(secondText), sectionIDs(thirdText))
    XCTAssertEqual(sectionIDs(secondText), sectionIDs(returnedText),
      "Возврат восстанавливает содержание того же листа")
  }

  func testPageControlsAndSearchReturnToTheReadPage() async throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture", "--notebook-document-runtime-fixture", "--notebook-document-prose-fixture"]
    launchPortraitFixture(app)
    let surface = app.otherElements["page-turn-surface"]
    XCTAssertTrue(surface.waitForExistence(timeout: 8))
    await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH 'Страница 1 из ' AND value != 'Страница 1 из 1'"), object: surface)], timeout: 5)
    app.buttons["next-page"].tap()
    await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH 'Страница 2 из '"), object: surface)], timeout: 3)
    app.buttons["page-overview"].tap()
    let thumbnail = app.buttons["Страница 3"]
    XCTAssertTrue(thumbnail.waitForExistence(timeout: 5))
    try await Task.sleep(for: .seconds(2))
    let proof = XCTAttachment(screenshot: app.screenshot()); proof.name = "real-page-thumbnails"; proof.lifetime = .keepAlways; add(proof)
    thumbnail.tap()
    await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH 'Страница 3 из '"), object: surface)], timeout: 3)
    app.buttons["notebook-search"].tap()
    let search = app.searchFields.firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 3)); search.tap(); search.typeText("Глава 1")
    let result = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Глава 1'")).firstMatch
    XCTAssertTrue(result.waitForExistence(timeout: 5)); result.tap()
    await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH 'Страница 1 из '"), object: surface)], timeout: 6)
    app.buttons["leave-nested-board"].tap()
    await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH 'Страница 3 из '"), object: surface)], timeout: 5)
  }

  func testDocumentLinksOpenTheMeasuredDistantPageAndReturnToContents() async throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture",
      "--notebook-document-runtime-fixture", "--notebook-document-links-fixture"]
    launchPortraitFixture(app)
    let surface = app.otherElements["page-turn-surface"]
    let outward = app.links["К дальней главе"].firstMatch
    XCTAssertTrue(outward.waitForExistence(timeout: 8))
    XCTAssertTrue(outward.isHittable)
    outward.tap()
    let returning = app.links["К оглавлению"].firstMatch
    XCTAssertTrue(returning.waitForExistence(timeout: 5), "A link must mount its off-page destination, not scroll the current fragment")
    XCTAssertTrue(returning.isHittable)
    XCTAssertFalse((surface.value as? String ?? "").hasPrefix("Страница 1 из "))
    let proof = XCTAttachment(screenshot: app.screenshot())
    proof.name = "document-link-distant-page"; proof.lifetime = .keepAlways; add(proof)
    returning.tap()
    await fulfillment(of: [XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value BEGINSWITH 'Страница 1 из '"), object: surface)], timeout: 5)
    XCTAssertTrue(outward.waitForExistence(timeout: 3)); XCTAssertTrue(outward.isHittable)
    XCTAssertFalse(app.textViews["Исходный Markdown или LaTeX"].exists, "Following links must not start source editing")
    app.links["Отсутствующий раздел"].firstMatch.tap()
    XCTAssertTrue(app.alerts["Ссылка недоступна"].waitForExistence(timeout: 2))
    app.alerts.buttons["Понятно"].tap()
    XCTAssertTrue((surface.value as? String ?? "").hasPrefix("Страница 1 из "))
  }

  func testProseDocumentTurnsToDifferentTextAndBack() async throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture",
      "--notebook-document-runtime-fixture", "--notebook-document-prose-fixture"]
    launchPortraitFixture(app)
    let surface = app.otherElements["page-turn-surface"]
    XCTAssertTrue(surface.waitForExistence(timeout: 8))
    await fulfillment(of: [XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value BEGINSWITH 'Страница 1 из ' AND value != 'Страница 1 из 1'"),
      object: surface)], timeout: 4)
    try await Task.sleep(for: .seconds(2.5))
    let first = try visibleDocumentText(app: app, surface: surface, name: "prose-page-1")
    surface.swipeLeft()
    await fulfillment(of: [XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value BEGINSWITH 'Страница 2 из '"), object: surface
    )], timeout: 3)
    try await Task.sleep(for: .milliseconds(600))
    let second = try visibleDocumentText(app: app, surface: surface, name: "prose-page-2")
    XCTAssertNotEqual(first, second)
    XCTAssertFalse(second.contains("Глава 1"), "Первый заголовок остаётся на первом листе")
    surface.swipeLeft()
    await fulfillment(of: [XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value BEGINSWITH 'Страница 3 из '"), object: surface
    )], timeout: 3)
    try await Task.sleep(for: .milliseconds(600))
    let third = try visibleDocumentText(app: app, surface: surface, name: "prose-page-3")
    XCTAssertFalse(third.contains("Глава 1"))
    surface.swipeRight()
    await fulfillment(of: [XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value BEGINSWITH 'Страница 2 из '"), object: surface
    )], timeout: 3)
    surface.swipeRight()
    await fulfillment(of: [XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value BEGINSWITH 'Страница 1 из '"), object: surface
    )], timeout: 3)
    try await Task.sleep(for: .milliseconds(600))
    let returned = try visibleDocumentText(app: app, surface: surface, name: "prose-page-1-return")
    XCTAssertTrue(returned.contains("Глава 1"))
    let topics = try NSRegularExpression(pattern: #"[1-3]\.[1-4]"#)
    func topicIDs(_ text: String) -> [String] {
      topics.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
        String(text[Range($0.range, in: text)!])
      }
    }
    XCTAssertGreaterThanOrEqual(topicIDs(first).count, 4)
    XCTAssertEqual(topicIDs(first), topicIDs(returned))
  }

  private func workspaceWindow(in app: XCUIApplication) -> XCUIElement {
    app.windows.containing(.button, identifier: "pen-controls-toggle").firstMatch
  }

  private func openSharedHistory(in app: XCUIApplication) {
    if !app.buttons["collaboration-history"].exists {
      if !app.buttons["notebook-chat-tasks"].exists { app.buttons["notebook-chat-toggle"].tap() }
      app.buttons["notebook-chat-menu"].tap()
    }
    XCTAssertTrue(app.buttons["collaboration-history"].waitForExistence(timeout: 3))
    app.buttons["collaboration-history"].tap()
  }

  private func launchPortraitFixture(_ app: XCUIApplication) {
    XCUIDevice.shared.orientation = .portrait
    app.launch()
    let window = workspaceWindow(in: app)
    let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      guard window.exists else { return false }
      let frame = window.frame
      return frame.width > 0 && frame.height > frame.width && frame.origin == .zero
    }, object: app)
    XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed,
      "The real workspace, not an offscreen preparation window, owns the portrait fixture")
  }

  private func visibleDocumentText(app: XCUIApplication, surface: XCUIElement, name: String) throws -> String {
    let screenshot = app.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["ru-RU"]
    let frame = surface.frame.intersection(app.frame)
    let pageRegion = CGRect(x: (frame.minX - app.frame.minX) / app.frame.width,
      y: 1 - (frame.maxY - app.frame.minY) / app.frame.height,
      width: frame.width / app.frame.width, height: frame.height / app.frame.height)
    try VNImageRequestHandler(cgImage: screenshot.image.cgImage!, options: [:]).perform([request])
    // Recognize complete screen glyphs, then address observations to the real
    // sheet. Cropping the recognizer's input changes its word segmentation.
    let text = (request.results ?? []).filter {
      pageRegion.contains(CGPoint(x: $0.boundingBox.midX, y: $0.boundingBox.midY))
    }.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    XCTAssertFalse(text.isEmpty)
    let proof = XCTAttachment(string: text); proof.name = name + "-text"; proof.lifetime = .keepAlways; add(proof)
    return text
  }

  func testPageFitSurvivesPortraitLandscapePortrait() async throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    try await Task.sleep(for: .milliseconds(450))
    let app = XCUIApplication()
    app.launchArguments = ["--notebook-drawing-responsiveness-fixture"]
    launchPortraitFixture(app)

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
    launchPortraitFixture(app)

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
    // This is the system end-to-end route, not a calibrated scale measurement.
    // Exact small approaches run against the mounted native scene in PortalPassageTests.
    workspaceWindow(in: app).pinch(withScale: 4, velocity: 2)
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
    launchPortraitFixture(app)

    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout: 5))
    let originalPaperFrame = paper.frame
    paper.pinch(withScale: 0.28, velocity: -2)
    let boardShown = app.buttons["create-workspace-item"].waitForExistence(timeout: 5)
    let hierarchy = XCTAttachment(string: app.debugDescription)
    hierarchy.name = "after-pinch-hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
    let pixels = XCTAttachment(screenshot: app.screenshot())
    pixels.name = "after-pinch-pixels"; pixels.lifetime = .keepAlways; add(pixels)
    XCTAssertTrue(boardShown)

    let notebook = app.descendants(matching: .any)
      .matching(
        identifier: "workspace-item-7e7a1000-0000-4000-8000-000000000002"
      )
      .firstMatch
    XCTAssertTrue(notebook.waitForExistence(timeout: 3))
    let openedAt = Date()
    notebook.doubleTap()

    XCTAssertTrue(paper.waitForExistence(timeout: 3))
    XCTAssertEqual(paper.frame.midX, originalPaperFrame.midX, accuracy: 2)
    XCTAssertEqual(paper.frame.midY, originalPaperFrame.midY, accuracy: 2)
    XCTAssertEqual(paper.frame.width, originalPaperFrame.width, accuracy: 2)
    XCTAssertEqual(paper.frame.height, originalPaperFrame.height, accuracy: 2)
    let opened = XCTAttachment(screenshot: app.screenshot())
    opened.name = "notebook-opened-within-3-seconds"; opened.lifetime = .keepAlways; add(opened)
    let duration = XCTAttachment(string: "Double tap and whole paper readiness: \(Date().timeIntervalSince(openedAt)) seconds")
    duration.name = "notebook-opening-duration"; duration.lifetime = .keepAlways; add(duration)
  }

  func testCreatesAndEntersBoardsAtTwoNestedLevels() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-simulator-finger-gestures",
    ]
    launchPortraitFixture(app)

    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout: 5))
    paper.pinch(withScale: 0.28, velocity: -2)
    XCTAssertTrue(app.buttons["create-workspace-item"].waitForExistence(timeout: 5))

    func createAndEnterBoard() {
      let items = app.descendants(matching: .any).matching(
        NSPredicate(format: "identifier BEGINSWITH 'workspace-item-'")
      )
      let before = Set(items.allElementsBoundByIndex.map(\.identifier))
      app.buttons["create-workspace-item"].tap()
      let createBoard = app.buttons["create-nested-board"]
      XCTAssertTrue(createBoard.waitForExistence(timeout: 2))
      createBoard.tap()

      // Publication is asynchronous. Resolve the newly created physical owner,
      // never the last old item or an unsigned index computed from an empty list.
      let created = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
        !Set(items.allElementsBoundByIndex.map(\.identifier)).subtracting(before).isEmpty
      }, object: nil)
      XCTAssertEqual(XCTWaiter.wait(for: [created], timeout: 3), .completed)
      XCTAssertFalse(app.staticTexts["persistence-failure"].firstMatch.exists)
      let identifier = Set(items.allElementsBoundByIndex.map(\.identifier)).subtracting(before).sorted().first
      guard let identifier else { return XCTFail("Созданная доска не опубликована") }
      let portal = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
      portal.doubleTap()
      XCTAssertTrue(app.buttons["leave-nested-board"].waitForExistence(timeout: 3))
      XCTAssertTrue(app.buttons["create-workspace-item"].exists)
    }

    createAndEnterBoard()
    createAndEnterBoard()

    app.buttons["leave-nested-board"].tap()
    XCTAssertTrue(app.buttons["leave-nested-board"].waitForExistence(timeout: 2))
    app.buttons["leave-nested-board"].tap()
    XCTAssertTrue(app.buttons["leave-nested-board"].waitForNonExistence(timeout: 2))
    XCTAssertTrue(app.buttons["create-workspace-item"].exists)
    let portalProof = XCTAttachment(screenshot: app.screenshot())
    portalProof.name = "nested-board-live-portal"
    portalProof.lifetime = .keepAlways
    add(portalProof)
  }

  func testPinchEntersAndLeavesALiveBoardPortal() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-simulator-finger-gestures",
    ]
    launchPortraitFixture(app)

    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout: 5))
    paper.pinch(withScale: 0.28, velocity: -2)
    XCTAssertTrue(app.buttons["create-workspace-item"].waitForExistence(timeout: 5))
    app.buttons["create-workspace-item"].tap()
    let createBoard = app.buttons["create-nested-board"]
    XCTAssertTrue(createBoard.waitForExistence(timeout: 2))
    createBoard.tap()

    let portals = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH 'workspace-item-'")
    )
    let portal = portals.element(boundBy: portals.count - 1)
    XCTAssertTrue(portal.waitForExistence(timeout: 3))
    workspaceWindow(in: app).pinch(withScale: 3, velocity: 2)
    XCTAssertTrue(portal.waitForNonExistence(timeout: 4), "Вложенная сцена заменяет рамку портала")
    XCTAssertTrue(
      app.buttons["leave-nested-board"].waitForExistence(timeout: 4),
      "Щипок наружу должен продолжить окно портала во вложенную доску"
    )

    workspaceWindow(in: app).pinch(withScale: 0.55, velocity: -2)
    XCTAssertTrue(
      !portal.exists && app.buttons["leave-nested-board"].exists,
      "Обычное уменьшение внутри доски не должно выводить наружу по доле отдельного жеста"
    )
    workspaceWindow(in: app).pinch(withScale: 0.35, velocity: -2)
    XCTAssertTrue(
      portal.waitForExistence(timeout: 4),
      "Уменьшение за входной масштаб должно продолжить тот же вид на родительской доске"
    )
    XCTAssertLessThan(portal.frame.width, workspaceWindow(in: app).frame.width)
    // Continue the system gesture route to the parent's overview. Exact boundary
    // scales and release continuity are measured by the native PortalPassageTests.
    workspaceWindow(in: app).pinch(withScale: 0.4, velocity: -2)
    XCTAssertTrue(app.buttons["create-workspace-item"].exists)
  }

  func testDoubleTapCreatesAndReopensTextOnAFocusedCover() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-simulator-finger-gestures",
      "--notebook-nearby-cover-fixture",
    ]
    launchPortraitFixture(app)

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
    launchPortraitFixture(app)
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

    workspaceWindow(in: app).coordinate(
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

  func testImmediateDragFromACoverPansTheWholeBoard() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-simulator-finger-gestures",
      "--notebook-stacked-board-fixture",
    ]
    launchPortraitFixture(app)

    let covers = ["002", "004"].map { suffix in
      app.descendants(matching: .any).matching(
        identifier: "workspace-item-7e7a1000-0000-4000-8000-000000000\(suffix)"
      ).firstMatch
    }
    for cover in covers { XCTAssertTrue(cover.waitForExistence(timeout: 5)) }
    let initial = covers.map(\.frame)
    for delta in [CGVector(dx: 120, dy: 80), CGVector(dx: -90, dy: -50)] {
      let before = covers.map(\.frame)
      let start = covers[1].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      start.press(forDuration: 0.01, thenDragTo: start.withOffset(delta),
        withVelocity: .fast, thenHoldForDuration: 0)
      for (cover, frame) in zip(covers, before) {
        XCTAssertEqual(cover.frame.midX - frame.midX, delta.dx, accuracy: 6,
          "Движение с обложки должно сдвигать всю доску вместе с соседями")
        XCTAssertEqual(cover.frame.midY - frame.midY, delta.dy, accuracy: 6)
        XCTAssertEqual(cover.frame.width, frame.width, accuracy: 2)
      }
    }
    for (cover, frame) in zip(covers, initial) {
      XCTAssertEqual(cover.frame.midX - frame.midX, 30, accuracy: 6)
      XCTAssertEqual(cover.frame.midY - frame.midY, 30, accuracy: 6)
    }
    XCTAssertFalse(app.buttons["delete-workspace-item"].exists,
      "Завершённое движение камеры оставляет выбор у сцены")
  }

  func testLongPressPicksUpAndMovesTheNotebook() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-simulator-finger-gestures",
      "--notebook-cover-eraser-fixture",
    ]
    launchPortraitFixture(app)

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
    launchPortraitFixture(app)

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

    let window = workspaceWindow(in: app)
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
    launchPortraitFixture(app)

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
    launchPortraitFixture(app)

    let notebook = app.descendants(matching: .any)
      .matching(
        identifier: "workspace-item-7e7a1000-0000-4000-8000-000000000002"
      )
      .firstMatch
    XCTAssertTrue(notebook.waitForExistence(timeout: 3))
    let coverFrame = notebook.frame
    let window = workspaceWindow(in: app)
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
    launchPortraitFixture(app)

    let notebook = app.descendants(matching: .any)
      .matching(
        identifier: "workspace-item-7e7a1000-0000-4000-8000-000000000002"
      )
      .firstMatch
    let window = workspaceWindow(in: app)
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
    launchPortraitFixture(app)

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
    let proof = XCTAttachment(screenshot: screenshot)
    proof.name = "cover-ink-on-physical-curl"
    proof.lifetime = .keepAlways
    add(proof)
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
    let window = workspaceWindow(in: app)
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
  }

  func testDocumentCoverUsesTheSamePhysicalCurl() async throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-simulator-finger-gestures",
      "--notebook-document-runtime-fixture",
    ]
    launchPortraitFixture(app)

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
    let window = workspaceWindow(in: app)
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

  func testDocumentCoverAndPaperKeepOneRectangleInBothOrientations() async throws {
    continueAfterFailure = false
    defer { XCUIDevice.shared.orientation = .portrait }
    for letter in [false, true] {
      XCUIDevice.shared.orientation = .portrait
      let app = XCUIApplication()
      app.launchArguments = [
        "--notebook-drawing-responsiveness-fixture",
        "--notebook-simulator-finger-gestures",
        "--notebook-document-runtime-fixture",
      ] + (letter ? ["--notebook-document-letter-fixture"] : [])
      launchPortraitFixture(app)
      for landscape in [false, true] {
        XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
        try await Task.sleep(for: .milliseconds(600))
        let document = app.descendants(matching: .any).matching(
          identifier: "workspace-item-7e7a1000-0000-4000-8000-000000000006"
        ).firstMatch
        let paper = app.otherElements.matching(
          NSPredicate(format: "label BEGINSWITH 'Страница 1 из '")
        ).firstMatch
        XCTAssertTrue(paper.waitForExistence(timeout: 8))
        let ratio = letter ? 612.0 / 792 : 595.275590551 / 841.88976378
        let surface = app.otherElements["page-turn-surface"]
        // The native sheet owns the landing rectangle; remote WebKit
        // accessibility frames round the ancestor transform to screen points.
        XCTAssertEqual(surface.frame.width / surface.frame.height, ratio, accuracy: 0.002)
        if abs(paper.frame.width - surface.frame.width) > 2 {
          let hierarchy = XCTAttachment(string: app.debugDescription)
          hierarchy.name = "document-frame-failure-hierarchy"
          hierarchy.lifetime = .keepAlways
          add(hierarchy)
        }
        XCTAssertEqual(paper.frame.width, surface.frame.width, accuracy: 2)
        XCTAssertEqual(paper.frame.height, surface.frame.height, accuracy: 2)
        XCTAssertEqual(paper.frame.midX, surface.frame.midX, accuracy: 2)
        XCTAssertEqual(paper.frame.midY, surface.frame.midY, accuracy: 2)
        let opened = surface.frame
        let openProof = XCTAttachment(screenshot: app.screenshot())
        openProof.name = "\(letter ? "letter" : "a4")-\(landscape ? "landscape" : "portrait")-paper"
        openProof.lifetime = .keepAlways
        add(openProof)
        app.otherElements["page-turn-surface"].pinch(withScale: 0.28, velocity: -2)
        XCTAssertTrue(app.buttons["create-workspace-item"].waitForExistence(timeout: 5))
        XCTAssertEqual(document.frame.width / document.frame.height, ratio, accuracy: 0.01)
        let coverProof = XCTAttachment(screenshot: app.screenshot())
        coverProof.name = "\(letter ? "letter" : "a4")-\(landscape ? "landscape" : "portrait")-cover"
        coverProof.lifetime = .keepAlways
        add(coverProof)
        document.doubleTap()
        XCTAssertTrue(paper.waitForExistence(timeout: 5))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(surface.frame.minX, opened.minX, accuracy: 2)
        XCTAssertEqual(surface.frame.minY, opened.minY, accuracy: 2)
        XCTAssertEqual(surface.frame.width, opened.width, accuracy: 2)
        XCTAssertEqual(surface.frame.height, opened.height, accuracy: 2)
      }
      app.terminate()
    }
  }

  func testNearPageApproachMagnetCompletesTheDock() async throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--notebook-drawing-responsiveness-fixture",
      "--notebook-simulator-finger-gestures",
      "--notebook-off-center-cover-fixture",
    ]
    launchPortraitFixture(app)

    let notebook = app.descendants(matching: .any)
      .matching(
        identifier: "workspace-item-7e7a1000-0000-4000-8000-000000000002"
      )
      .firstMatch
    XCTAssertTrue(notebook.waitForExistence(timeout: 3))
    let window = workspaceWindow(in: app)
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
    launchPortraitFixture(app)
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
    let window = workspaceWindow(in: app)
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
    launchPortraitFixture(app)

    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout: 5))
    let window = workspaceWindow(in: app)
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
    launchPortraitFixture(app)

    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout: 5))
    XCTAssertEqual(paper.value as? String, "80 действий пера")

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
      predicate: NSPredicate(format: "value == %@", "81 действий пера"),
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
    launchPortraitFixture(app)

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
    XCTAssertEqual(initialValue, "80 действий пера")
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
      predicate: NSPredicate(format: "label == %@", "Ручка"),
      object: controls
    )
    wait(for: [controlsClosed], timeout: 2)
    XCTAssertLessThan(ContinuousClock.now - responseStarted, .seconds(2))

    let bothErasersLanded = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == '82 действий пера'"),
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
    launchPortraitFixture(app)

    let controls = app.buttons["pen-controls-toggle"]
    XCTAssertTrue(controls.waitForExistence(timeout: 5))
    let eraser = app.buttons["drawing-tool-eraser"]
    XCTAssertTrue(eraser.waitForExistence(timeout: 2))
    eraser.tap()

    let paper = app.otherElements["paper-input"]
    XCTAssertTrue(paper.waitForExistence(timeout: 2))
    let originalValue = paper.value as? String
    XCTAssertEqual(originalValue, "80 действий пера")
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

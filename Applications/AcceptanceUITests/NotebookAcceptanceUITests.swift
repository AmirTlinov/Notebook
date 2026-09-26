import UIKit
import XCTest

/// These tests launch the real synchronized application, never DrawingFixture
/// or ChatFixture. Environment is supplied by the isolated acceptance runner.
@MainActor final class NotebookAcceptanceUITests: XCTestCase {
  private let app = XCUIApplication(bundleIdentifier: "com.amirtlinov.notebook.acceptance")
  private var systemTrace: NotebookSystemTraceHandshake?
  private var unexpectedInterruption: Any?

  private func launch(readinessIdentifier: String = "spatial-ink") throws {
    continueAfterFailure = false
    unexpectedInterruption = addUIInterruptionMonitor(withDescription: "Unexpected system dialog during text/canvas acceptance") { [weak self] alert in
      let proof = XCTAttachment(screenshot: alert.screenshot())
      proof.name = "unexpected-system-dialog"; proof.lifetime = .keepAlways; self?.add(proof)
      // XCTest's default monitor grants some privacy dialogs. These scenarios
      // never request microphone/Speech access; a surprise grant is not a pass.
      let deny = alert.buttons.matching(NSPredicate(format: "label IN %@", ["Не разрешать", "Don't Allow", "Don’t Allow"])).firstMatch
      if deny.exists { deny.tap() }
      XCTFail("Unexpected system dialog: " + alert.label)
      return true
    }
    app.launchEnvironment["NOTEBOOK_ACCEPTANCE_MANIFEST"] = try XCTUnwrap(
      ProcessInfo.processInfo.environment["NOTEBOOK_ACCEPTANCE_MANIFEST"])
    if let session = ProcessInfo.processInfo.environment["NOTEBOOK_NAVIGATION_OBSERVATION_SESSION_ID"] {
      app.launchEnvironment["NOTEBOOK_NAVIGATION_OBSERVATION_SESSION_ID"] = session
    }
    if let session = ProcessInfo.processInfo.environment["NOTEBOOK_SCENE_OBSERVATION_SESSION_ID"] {
      app.launchEnvironment["NOTEBOOK_SCENE_OBSERVATION_SESSION_ID"] = session
    }
    systemTrace = try NotebookSystemTraceHandshake.configured(environment: ProcessInfo.processInfo.environment)
    systemTrace?.configure(app)
    app.launch()
    try systemTrace?.began(app)
    // Orient a launched app. Waiting for a terminated application's idle
    // snapshot here adds an unrelated 60-second XCTest synchronization wait.
    if XCUIDevice.shared.orientation != .portrait { XCUIDevice.shared.orientation = .portrait }
    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: readinessIdentifier).firstMatch
      .waitForExistence(timeout: 20), app.debugDescription)
    XCTAssertFalse(app.otherElements["persistence-failure"].exists)
  }

  private func openChat() {
    let tasks = app.buttons["notebook-chat-tasks"]
    if !tasks.isHittable {
      let companion = app.buttons["notebook-companion-compose"]
      XCTAssertTrue(companion.waitForExistence(timeout: 5)); XCTAssertTrue(companion.isHittable)
      companion.tap()
    }
    XCTAssertTrue(tasks.waitForExistence(timeout: 5)); XCTAssertTrue(tasks.isHittable)
  }

  private func beginNewChat() {
    openChat()
    // The header opens the catalogue; its Chats tab owns the projectless
    // creation button. Expanding the companion alone opens the current chat.
    let mode = app.segmentedControls["notebook-chat-browser-mode"]
    if !mode.exists { app.buttons["notebook-chat-tasks"].tap() }
    XCTAssertTrue(mode.waitForExistence(timeout: 5))
    let chats = mode.buttons["Чаты"]
    XCTAssertTrue(chats.isHittable)
    if !chats.isSelected { chats.tap() }
    let create = app.buttons["notebook-chat-new"]
    XCTAssertTrue(create.waitForExistence(timeout: 5))
    XCTAssertTrue(create.isHittable); XCTAssertTrue(create.isEnabled); create.tap()
  }

  private func screenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
  }

  /// Search the public fixture's exact source text, then use its ordinary
  /// addressed navigation. A preceding scenario may have left any page open.
  private func navigateToAcceptanceControls() throws {
    let collapse = app.buttons["notebook-chat-toggle"]
    if collapse.exists {
      XCTAssertTrue(collapse.isHittable); collapse.tap()
      XCTAssertTrue(collapse.waitForNonExistence(timeout: 5))
    }
    let searchButton = app.buttons["notebook-search"]
    XCTAssertTrue(searchButton.waitForExistence(timeout: 10)); XCTAssertTrue(searchButton.isHittable)
    searchButton.tap()
    let field = app.searchFields.firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 5)); XCTAssertTrue(field.isHittable)
    let sourceText = "Контрольные кнопка, ползунок и поле ввода"
    field.tap(); field.typeText(sourceText)
    XCTAssertEqual(field.value as? String, sourceText)
    let results = app.collectionViews.buttons.matching(NSPredicate(format: "label CONTAINS %@", sourceText))
    let found = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in results.count > 0 }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [found], timeout: 10), .completed, app.debugDescription)
    let matches = results.allElementsBoundByIndex
    let result = try XCTUnwrap(matches.count == 1 ? matches.first : nil,
      "The complete fixture source must identify one search result; found \(matches.count).\n\(app.debugDescription)")
    XCTAssertTrue(result.isHittable)
    screenshot("acceptance-controls-unique-search-result")
    result.tap()
    XCTAssertTrue(field.waitForNonExistence(timeout: 10))
    let controls = app.webViews.containing(.button, identifier: "Acceptance increment").firstMatch
    let buttons = app.webViews.buttons.matching(identifier: "Acceptance increment")
    let arrived = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
      // WebKit exposes several nested AX WebViews for one physical widget.
      // Uniqueness belongs to the actual control, not its ancestor chain.
      guard buttons.count == 1, controls.exists else { return false }
      let frame = controls.frame
      return !app.otherElements["page-turn-surface"].exists && buttons.element(boundBy: 0).isHittable
        && !frame.isEmpty && !frame.isNull && !frame.isInfinite
        && !frame.intersection(app.windows.firstMatch.frame).isEmpty
    }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [arrived], timeout: 20), .completed,
      "The real search selection must reach the live controls on their board.\n\(app.debugDescription)")
    let pencil = ProcessInfo.processInfo.environment["NOTEBOOK_ACCEPTANCE_PENCIL_CONTACTS"] == "1"
    try fitControlMaterial(using: app.otherElements["spatial-ink"], permitsFingerPan: !pencil)
    XCTAssertTrue(app.webViews.buttons["Acceptance increment"].isHittable)
    XCTAssertTrue(app.webViews.sliders["Acceptance slider"].exists)
    XCTAssertTrue(app.webViews.textFields["Acceptance text"].isHittable)
    screenshot("acceptance-controls-ready-after-real-navigation")
  }

  func testRealChatReplyThroughConnectedMac() throws {
    try launch()
    try sendRealChatReply()
    try systemTrace?.ended(app)
  }

  func testRealStreamingKeepsInkAndStopResponsive() throws {
    try launch(readinessIdentifier: "notebook-search")
    try navigateToAcceptanceControls()
    try sendRealStreamingWhileDrawing()
    try systemTrace?.ended(app)
  }

  /// A busy indicator is not streaming evidence. The actual assistant text must
  /// grow across a system-routed contact, which must also leave accepted ink.
  private func sendRealStreamingWhileDrawing() throws {
    XCTAssertEqual(ProcessInfo.processInfo.environment["NOTEBOOK_ACCEPTANCE_PENCIL_CONTACTS"], "1")
    try selectBlackPen()
    beginNewChat()
    let transcript = app.descendants(matching: .any).matching(identifier: "notebook-chat-transcript").firstMatch
    XCTAssertTrue(transcript.waitForExistence(timeout: 30))
    let marker = "STREAM_" + UUID().uuidString
    let text = app.descendants(matching: .any).matching(identifier: "notebook-chat-text").firstMatch
    XCTAssertTrue(text.waitForExistence(timeout: 10)); text.tap()
    text.typeText("Это проверка изолированного пространства Notebook. Без инструментов напиши 300 отдельных строк простых алгебраических равенств с коротким пояснением каждого. Каждую строку начинай с \(marker), затем её номер. Не сокращай список; я остановлю ответ после проверки рисования.")
    let send = app.buttons["notebook-chat-send"]
    XCTAssertTrue(send.isEnabled); send.tap()
    try dismissSystemKeyboard()
    let output = app.webViews.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", marker))
    XCTAssertTrue(output.firstMatch.waitForExistence(timeout: 90), "A real assistant packet must arrive before testing overlap")
    let stop = app.buttons["notebook-chat-stop"]
    XCTAssertTrue(stop.exists, "The observed reply must still be running")
    let ink = app.otherElements["spatial-ink"]
    XCTAssertTrue(ink.exists)
    let viewport = ink.frame.intersection(app.windows.firstMatch.frame).insetBy(dx: 48, dy: 96)
    let panel = app.otherElements["notebook-chat-panel"]
    XCTAssertTrue(panel.isHittable)
    let occupied = occupiedCanvasFrames(try app.snapshot())
    let candidates = [0.15, 0.35, 0.55, 0.75].flatMap { y in
      [0.15, 0.35, 0.55, 0.75].map { x in CGPoint(x: viewport.minX + viewport.width*x, y: viewport.minY + viewport.height*y) }
    }
    let point = try XCTUnwrap(candidates.first { point in
      let path = CGRect(x: point.x, y: point.y, width: 100, height: 30).insetBy(dx: -8, dy: -8)
      return viewport.contains(path) && !occupied.contains { $0.intersects(path) }
    }, "The real layout must expose a free canvas route beside chat")
    var observations: [[String: Any]] = []
    var overlapped = false
    for attempt in 0..<3 where !overlapped {
      XCTAssertTrue(stop.exists); XCTAssertTrue(panel.isHittable); XCTAssertTrue(transcript.exists)
      let before = output.allElementsBoundByIndex.map(\.label).joined(separator: "\n")
      let previous = ink.value as? String
      let start = point.applying(.init(translationX: 0, y: CGFloat(attempt)*3))
      let end = CGPoint(x: start.x+100, y: start.y+30)
      let began = ProcessInfo.processInfo.systemUptime
      screenCoordinate(start).press(forDuration: 0.02, thenDragTo: screenCoordinate(end), withVelocity: .slow, thenHoldForDuration: 0)
      let after = output.allElementsBoundByIndex.map(\.label).joined(separator: "\n")
      let ended = ProcessInfo.processInfo.systemUptime
      XCTAssertTrue(panel.isHittable); XCTAssertTrue(transcript.exists); XCTAssertTrue(stop.exists)
      XCTAssertNotEqual(ink.value as? String, previous, "Streaming must not suppress the accepted Pencil contact")
      XCTAssertGreaterThan(try darkPixels(near: CGPoint(x: start.x+50, y: start.y+15)), 8)
      overlapped = after.count > before.count && after != before
      observations.append(["began": began, "ended": ended, "beforeCharacters": before.count,
        "afterCharacters": after.count, "textGrewAcrossContact": overlapped])
    }
    let proof = XCTAttachment(data: try JSONSerialization.data(withJSONObject: observations,
      options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
    proof.name = "real-streaming-across-native-ink"; proof.lifetime = .keepAlways; add(proof)
    XCTAssertTrue(overlapped, "A pending turn without changing assistant text does not establish simultaneous streaming")
    XCTAssertTrue(stop.isHittable); stop.tap()
    XCTAssertTrue(stop.waitForNonExistence(timeout: 30))
    XCTAssertFalse(app.otherElements["persistence-failure"].exists)
    screenshot("real-streaming-ink-and-stop")
  }

  private func sendRealChatReply() throws {
    beginNewChat()
    let conversation = app.descendants(matching: .any).matching(identifier: "notebook-chat-transcript").firstMatch
    XCTAssertTrue(conversation.waitForExistence(timeout: 30), app.debugDescription)
    let marker = try XCTUnwrap(ProcessInfo.processInfo.environment["NOTEBOOK_ACCEPTANCE_REPLY_MARKER"]) + "_" + UUID().uuidString
    let text = app.descendants(matching: .any).matching(identifier: "notebook-chat-text").firstMatch
    XCTAssertTrue(text.waitForExistence(timeout: 10))
    screenshot("real-chat-before-text-input")
    text.tap()
    let existing = text.value as? String ?? ""
    if !existing.isEmpty, existing != "Сообщение Codex" {
      XCTAssertTrue(existing.hasPrefix("Это проверка изолированного пространства Notebook."),
        "Only this scenario's earlier unsent draft may be replaced")
      text.typeKey("a", modifierFlags: .command)
      text.typeText(XCUIKeyboardKey.delete.rawValue)
    }
    let prompt = "Это проверка изолированного пространства Notebook. Ответь только: " + marker + ". Не вызывай инструменты."
    text.typeText(prompt)
    XCTAssertEqual(text.value as? String, prompt)
    screenshot("real-chat-text-ready-to-send")
    let send = app.buttons["notebook-chat-send"]
    XCTAssertTrue(send.isEnabled, app.debugDescription); send.tap()
    let reply = app.webViews.staticTexts.matching(NSPredicate(format: "label == %@ OR label == %@", marker, marker + ".")).firstMatch
    XCTAssertTrue(reply.waitForExistence(timeout: 90), app.debugDescription)
    screenshot("real-codex-reply-on-ipad")
    XCTAssertFalse(app.otherElements["persistence-failure"].exists)
  }

  /// Run on the private Simulator after its microphone permission was denied.
  /// The notice comes from the real audio owner after a real button gesture;
  /// neither the error, the draft nor the assistant reply is injected.
  func testDeniedDictationRetainsDraftAndTextSend() throws {
    try launch(); beginNewChat()
    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "notebook-chat-transcript")
      .firstMatch.waitForExistence(timeout: 30), app.debugDescription)
    let marker = try XCTUnwrap(ProcessInfo.processInfo.environment["NOTEBOOK_ACCEPTANCE_REPLY_MARKER"]) + "_MIC_DENIED_" + UUID().uuidString
    let text = app.descendants(matching: .any).matching(identifier: "notebook-chat-text").firstMatch
    XCTAssertTrue(text.waitForExistence(timeout: 10))
    XCTAssertTrue((text.value as? String).map { $0.isEmpty || $0 == "Сообщение Codex" } == true,
      "The preceding real text scenario must leave no unsent draft")
    let prompt = "Это проверка изолированного пространства Notebook. Ответь только: " + marker + ". Не вызывай инструменты."
    text.tap(); text.typeText(prompt)
    let dictate = app.buttons["notebook-chat-dictation"]
    XCTAssertEqual(dictate.label, "Диктовать сообщение")
    XCTAssertTrue(dictate.isHittable); dictate.tap()
    let notice = app.staticTexts["notebook-dictation-notice"]
    XCTAssertTrue(notice.waitForExistence(timeout: 10), app.debugDescription)
    XCTAssertEqual(notice.label, "Разрешите Notebook доступ к микрофону в настройках iPad.")
    XCTAssertEqual(text.value as? String, prompt)
    let send = app.buttons["notebook-chat-send"]
    XCTAssertTrue(send.isEnabled); XCTAssertTrue(send.isHittable)
    XCTAssertFalse(app.otherElements["notebook-dictation-input"].exists)
    screenshot("denied-microphone-text-controls-and-draft")

    app.buttons["notebook-chat-toggle"].tap()
    XCTAssertTrue(app.buttons["notebook-compact-dictation"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["notebook-companion-compose"].isHittable)
    XCTAssertTrue(notice.exists)
    XCTAssertFalse(app.buttons["notebook-companion-task"].exists,
      "An idle microphone notice must not reserve an empty task header")
    screenshot("denied-microphone-compact-notice-and-controls")
    openChat()
    XCTAssertEqual(text.value as? String, prompt)
    XCTAssertTrue(notice.exists); XCTAssertTrue(send.isEnabled); send.tap()
    let reply = app.webViews.staticTexts.matching(NSPredicate(format: "label == %@ OR label == %@", marker, marker + ".")).firstMatch
    XCTAssertTrue(reply.waitForExistence(timeout: 90), app.debugDescription)
    screenshot("denied-microphone-real-text-reply")
    app.buttons["notebook-dictation-dismiss-notice"].tap()
    XCTAssertFalse(notice.exists)
    XCTAssertTrue(app.buttons["notebook-chat-dictation"].isHittable)
    screenshot("denied-microphone-notice-dismissed")
    try systemTrace?.ended(app)
  }

  /// Diagnostic observation of the real system input assistant. This does not
  /// count as software-keyboard acceptance until its visible keys are used.
  func testInspectVisibleKeyboardAssistant() throws {
    try launch()
    try navigateToAcceptanceControls()
    let input = app.webViews.textFields["Acceptance text"]
    XCTAssertTrue(input.waitForExistence(timeout: 10)); XCTAssertTrue(input.isHittable)
    input.tap()
    screenshot("actual-keyboard-assistant-after-touch")
    let attachment = XCTAttachment(string: app.debugDescription)
    attachment.name = "actual-keyboard-assistant-hierarchy"
    attachment.lifetime = .keepAlways; add(attachment)
    try systemTrace?.ended(app)
  }

  /// Separate actual keyboard observation from camera arbitration. No DOM
  /// focus, state injection, or synthetic text assignment is used.
  func testRepeatedNativeKeyboardInputPreservesExactTypedMarkers() throws {
    try launch()
    try navigateToAcceptanceControls()
    for pass in 0..<2 {
      let input = app.webViews.textFields["Acceptance text"]
      XCTAssertTrue(input.exists); XCTAssertTrue(input.isHittable)
      try typeAndObserve("Notebook keyboard \(pass) " + UUID().uuidString,
        in: input, name: "keyboard-\(pass)")
      try dismissSystemKeyboard()
    }
    XCTAssertFalse(app.otherElements["persistence-failure"].exists)
    try systemTrace?.ended(app)
  }

  private func typeAndObserve(_ marker: String, in input: XCUIElement, name: String, submits: Bool = false) throws {
    input.tap()
    let typingStartedAt = ProcessInfo.processInfo.systemUptime
    input.typeText(marker + (submits ? "\n" : ""))
    let typingReturnedAt = ProcessInfo.processInfo.systemUptime
    let immediateValue = input.value as? String
    let valueObservedAt = ProcessInfo.processInfo.systemUptime
    // XCTest can return before WebKit has consumed the synthesized keys. The
    // native input journal distinguishes that boundary from lost admitted
    // state. Keep the first observation, but assert the bounded final value.
    screenshot("widget-input-immediate-observation-\(name)")
    let entered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", marker), object: input)
    let complete = immediateValue?.contains(marker) == true || XCTWaiter.wait(for: [entered], timeout: 3) == .completed
    let finalValue = input.value as? String
    let inputObservation: [String: Any] = [
      "expectedMarker": marker,
      "typingStartedAt": typingStartedAt,
      "typingReturnedAt": typingReturnedAt,
      "valueObservedAt": valueObservedAt,
      "immediateValue": immediateValue as Any? ?? NSNull(),
      "finalValue": finalValue as Any? ?? NSNull(),
      "finalObservedAt": ProcessInfo.processInfo.systemUptime,
      "completionObserved": complete,
      "completionTimeoutSeconds": 3,
      "measurement": "XCTest input and accessibility observation; not native control latency"
    ]
    let observation = XCTAttachment(data: try JSONSerialization.data(withJSONObject: inputObservation,
      options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
    observation.name = "widget-input-observation-\(name)"
    observation.lifetime = .keepAlways; add(observation)
    XCTAssertTrue(complete && finalValue?.contains(marker) == true,
      "The completed input did not preserve the full new marker; see widget-input-observation-\(name)")
  }

  func testPinchStartingOnReadySliderDoesNotMoveTheScene() throws {
    try launch()
    try navigateToAcceptanceControls()
    let slider = app.webViews.sliders["Acceptance slider"]
    XCTAssertTrue(slider.isHittable)
    let frame = controlWebView.frame, beforeCount = try counterValue()
    let beforeText = app.webViews.textFields["Acceptance text"].value as? String
    let beforeSlider = try acceptanceSliderValue(slider)
    screenshot("control-owned-pinch-before")
    // This public XCTest gesture begins on the actual ready slider. The
    // synthesized-event attachment records its two real touch paths.
    slider.pinch(withScale: 1.02, velocity: 1)
    let after = controlWebView.frame, afterSlider = try acceptanceSliderValue(slider)
    screenshot("control-owned-pinch-after")
    let observation: [String: Any] = [
      "frameBefore": [frame.minX, frame.minY, frame.width, frame.height],
      "frameAfter": [after.minX, after.minY, after.width, after.height],
      "sliderBefore": beforeSlider, "sliderAfter": afterSlider,
      "measurement": "Actual control-origin pinch and native accessibility frames; not a system-frame or pixel-drift measurement"
    ]
    let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: observation,
      options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
    attachment.name = "control-owned-pinch-geometry"; attachment.lifetime = .keepAlways; add(attachment)
    XCTAssertEqual(after.minX, frame.minX, accuracy: 0.5)
    XCTAssertEqual(after.minY, frame.minY, accuracy: 0.5)
    XCTAssertEqual(after.width, frame.width, accuracy: 0.5)
    XCTAssertEqual(after.height, frame.height, accuracy: 0.5)
    XCTAssertEqual(try counterValue(), beforeCount)
    XCTAssertEqual(app.webViews.textFields["Acceptance text"].value as? String, beforeText)
    XCTAssertTrue(app.webViews.staticTexts["Acceptance slider: \(Int(afterSlider.rounded()))"].exists)
    XCTAssertFalse(app.otherElements["persistence-failure"].exists)
    try systemTrace?.ended(app)
  }

  func testCompanionRemainsReachableWhileWidgetKeyboardIsOpen() throws {
    try launch()
    try navigateToAcceptanceControls()
    let paper = app.otherElements["spatial-ink"]
    let originalPaper = paper.frame
    let field = app.webViews.textFields["Acceptance text"]
    let originalText = try XCTUnwrap(field.value as? String)
    XCTAssertTrue(field.isHittable); field.tap()
    let keyboard = app.keyboards.firstMatch
    XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
    XCTAssertGreaterThan(keyboard.frame.height, 200)
    let companion = app.buttons["notebook-companion-compose"]
    screenshot("companion-and-widget-keyboard-before-chat-open")
    let evidence = XCTAttachment(string: app.debugDescription)
    evidence.name = "companion-widget-keyboard-actual-hierarchy"; evidence.lifetime = .keepAlways; add(evidence)
    XCTAssertEqual(paper.frame, originalPaper, "Keyboard avoidance must not resize the drawing viewport")
    XCTAssertLessThanOrEqual(companion.frame.maxY, keyboard.frame.minY,
      "The user must be able to return to the agent while editing a widget")
    XCTAssertTrue(companion.isHittable); companion.tap()
    XCTAssertTrue(app.buttons["notebook-chat-tasks"].waitForExistence(timeout: 5))
    XCTAssertEqual(field.value as? String, originalText)
    XCTAssertEqual(paper.frame, originalPaper)
    screenshot("chat-opened-from-widget-keyboard-with-paper-preserved")
    try systemTrace?.ended(app)
  }

  /// A short causal workload for a standard system trace, not the displayed-
  /// pixel acceptance test. In particular, AX completion never proves 100 ms.
  func testTenReadyControlContactsForSystemTraceDiagnosis() throws {
    let session = UUID().uuidString
    app.launchEnvironment["NOTEBOOK_INTERACTION_SESSION_ID"] = session
    app.launchEnvironment["NOTEBOOK_INTERACTION_SELECTORS"] = "[\"#count\",\"#level\",\"#text\"]"
    let metadata = XCTAttachment(string: "interactionSessionID=\(session)\nscope=Native contacts and existing runtime journal; no displayed-pixel latency verdict")
    metadata.name = "system-trace-control-session"; metadata.lifetime = .keepAlways; add(metadata)
    try launch()
    // The stand must already be left on the control board. Opening Search here
    // would exercise the first-responder chain before the measured first tap.
    XCTAssertFalse(app.otherElements["page-turn-surface"].exists)
    let button = app.webViews.buttons["Acceptance increment"]
    XCTAssertTrue(button.waitForExistence(timeout: 20)); XCTAssertTrue(button.isHittable)
    let before = try counterValue()
    for index in 0..<10 {
      try tapAndObserveIncrement(button, expected: before + index + 1, name: "system-trace-\(index)")
    }
    XCTAssertFalse(app.otherElements["persistence-failure"].exists)
    try systemTrace?.ended(app)
  }

  func testCameraAndFirstTouchControlsOnAgentMaterial() throws {
    try launch()
    try navigateToAcceptanceControls()
    let ink = app.otherElements["spatial-ink"]
    XCTAssertTrue(controlWebView.waitForExistence(timeout: 10))
    screenshot("agent-material-before-camera")
    try panFreeBoard(by: .init(dx: -120, dy: 85))
    screenshot("agent-material-after-pan")
    // XCTest adds touchdown travel before the requested pinch segment. The
    // resulting camera scale must be judged from the displayed native frame.
    ink.pinch(withScale: 1.02, velocity: 1)
    screenshot("agent-material-after-pinch")
    try fitControlMaterial(using: ink)
    let button = app.webViews.buttons["Acceptance increment"]
    XCTAssertTrue(button.waitForExistence(timeout: 10))
    let before = try counterValue()
    for pass in 0..<2 {
      if pass > 0 {
        try panFreeBoard(by: .init(dx: 25, dy: -15))
        try fitControlMaterial(using: ink)
        XCTAssertEqual(try counterValue(), before + pass, "Camera motion must not activate the control")
      }
      let expected = before + pass + 1
      try tapAndObserveIncrement(button, expected: expected, name: "camera-\(pass)")
      screenshot("first-touch-button-after-camera-\(pass)")
      try dragAcceptanceSlider()
      XCTAssertEqual(try counterValue(), expected, "The accepted button tap must still have exactly one effect")
      screenshot("slider-changes-real-widget-\(pass)")
      let input = app.webViews.textFields["Acceptance text"]
      XCTAssertTrue(input.exists); XCTAssertTrue(input.isHittable)
      let marker = "Notebook acceptance \(pass) " + UUID().uuidString
      try typeAndObserve(marker, in: input, name: "camera-\(pass)")
      XCTAssertEqual(try counterValue(), expected)
      screenshot("widget-real-keyboard-input-\(pass)")
      if pass == 0 { try dismissSystemKeyboard() }
    }
    XCTAssertFalse(app.otherElements["persistence-failure"].exists)
    try systemTrace?.ended(app)
  }

  private func tapAndObserveIncrement(_ button: XCUIElement, expected: Int, name: String) throws {
    XCTAssertTrue(button.isHittable)
    let frame = button.frame, observedAt = ProcessInfo.processInfo.systemUptime
    let previous = try counterValue()
    let startedAt = ProcessInfo.processInfo.systemUptime
    button.tap()
    let returnedAt = ProcessInfo.processInfo.systemUptime
    let appeared = app.webViews.staticTexts["Acceptance count: \(expected)"].waitForExistence(timeout: 3)
    let afterFrame = button.frame
    let observation: [String: Any] = [
      "beforeCount": previous, "expectedCount": expected, "expectedAppeared": appeared,
      "frameObservedAt": observedAt, "tapStartedAt": startedAt, "tapReturnedAt": returnedAt,
      "afterObservedAt": ProcessInfo.processInfo.systemUptime,
      "frameBefore": [frame.minX, frame.minY, frame.width, frame.height],
      "frameAfter": [afterFrame.minX, afterFrame.minY, afterFrame.width, afterFrame.height],
      "measurement": "Actual XCTest tap and accessibility geometry; correlate with synthesized DOWN attachment. Not native latency."
    ]
    let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: observation,
      options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
    attachment.name = "widget-button-observation-\(name)"; attachment.lifetime = .keepAlways; add(attachment)
    screenshot("widget-button-observation-\(name)")
    XCTAssertTrue(appeared, "The actual tap did not produce the expected count; see widget-button-observation-\(name)")
    XCTAssertEqual(try counterValue(), expected, "A single accepted tap must have exactly one effect")
  }

  /// This probes the real attach lifecycle before a long performance workload.
  /// It uses the ordinary private app even when the Mac is not yet connected.
  func testSystemTraceAttachesToLaunchedApplication() throws {
    try launch(readinessIdentifier: "notebook-search")
    XCTAssertNotNil(systemTrace, "Run this probe with the explicit Time Profiler option")
    // A previous real journey can leave a page open. Trace readiness does not
    // reset navigation or require the launch surface to be the infinite board.
    let page = app.otherElements.matching(identifier: "paper-input").allElementsBoundByIndex.first { $0.isHittable }
    let ink = page ?? app.otherElements["spatial-ink"]
    XCTAssertTrue(ink.waitForExistence(timeout: 10), app.debugDescription)
    XCTAssertTrue(ink.isHittable)
    screenshot("trace-attached-before-real-gestures")
    let began = ProcessInfo.processInfo.systemUptime
    var count = 0
    while ProcessInfo.processInfo.systemUptime - began < 10 {
      let start = ink.coordinate(withNormalizedOffset: .init(dx: 0.20, dy: 0.30))
      let end = start.withOffset(.init(dx: count.isMultiple(of: 2) ? 80 : -80, dy: 30))
      start.press(forDuration: 0.01, thenDragTo: end)
      count += 1
    }
    XCTAssertGreaterThan(count, 1)
    XCTAssertFalse(app.otherElements["persistence-failure"].exists)
    screenshot("trace-attached-after-real-gestures")
    try systemTrace?.ended(app)
  }

  /// The material is created through the public API before this run. A separate
  /// agent may edit other owners concurrently; this test never seeds content.
  func testThirtyMinutesOfMixedInteraction() throws {
    let seconds = try XCTUnwrap(ProcessInfo.processInfo.environment["NOTEBOOK_ACCEPTANCE_WORKLOAD_SECONDS"].flatMap(Double.init))
    XCTAssertGreaterThanOrEqual(seconds, 1800); XCTAssertLessThanOrEqual(seconds, 2700)
    executionTimeAllowance = seconds + 120
    try launch()
    try navigateToAcceptanceControls()
    let began = ProcessInfo.processInfo.systemUptime
    var iteration = 0
    var lastScreenshot = began - 60
    let pencil = ProcessInfo.processInfo.environment["NOTEBOOK_ACCEPTANCE_PENCIL_CONTACTS"] == "1"
    while ProcessInfo.processInfo.systemUptime - began < seconds {
      try performMixedIteration(iteration, pencil: pencil, began: began, lastScreenshot: &lastScreenshot)
      iteration += 1
    }
    let elapsed = ProcessInfo.processInfo.systemUptime - began
    XCTAssertGreaterThanOrEqual(iteration, 10)
    XCTAssertGreaterThanOrEqual(elapsed, seconds)
    let receipt = XCTAttachment(string: "elapsedSeconds=\(elapsed)\ncompletedIterations=\(iteration)\ninputProfile=\(pencil ? "measured Simulator Pencil contacts" : "native finger contacts")")
    receipt.name = "mixed-workload-duration"; receipt.lifetime = .keepAlways; add(receipt)
    screenshot("mixed-workload-finished")
    try systemTrace?.ended(app)
  }

  /// The same native gestures as the long scenario, narrowed to its first
  /// repeated keyboard/rotation boundary. The existing observer only records.
  func testKeyboardAfterCameraAndRotationPreservesAcceptedInput() throws {
    let session = UUID().uuidString
    app.launchEnvironment["NOTEBOOK_INTERACTION_SESSION_ID"] = session
    app.launchEnvironment["NOTEBOOK_INTERACTION_SELECTORS"] = "[\"#text\",\"#count\",\"#slider\"]"
    let identity = XCTAttachment(string: session)
    identity.name = "input-state-observation-session"; identity.lifetime = .keepAlways; add(identity)
    try launch()
    try navigateToAcceptanceControls()
    let began = ProcessInfo.processInfo.systemUptime
    var lastScreenshot = began - 60
    for iteration in 0..<17 {
      try performMixedIteration(iteration, pencil: false, began: began, lastScreenshot: &lastScreenshot)
    }
    try systemTrace?.ended(app)
  }

  private func performMixedIteration(_ iteration: Int, pencil: Bool, began: TimeInterval,
    lastScreenshot: inout TimeInterval) throws {
      try XCTContext.runActivity(named: "mixed-interaction-\(iteration)") { _ in
        let ink = app.otherElements["spatial-ink"]
        try fitControlMaterial(using: ink, permitsFingerPan: !pencil)
        let button = app.webViews.buttons["Acceptance increment"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), app.debugDescription)
        let before = try counterValue()
        button.tap()
        XCTAssertTrue(app.webViews.staticTexts["Acceptance count: \(before + 1)"].waitForExistence(timeout: 3))
        try dragAcceptanceSlider()
        XCTAssertEqual(try counterValue(), before + 1, "One physical tap must produce exactly one effect")
        if iteration.isMultiple(of: 5) {
          let input = app.webViews.textFields["Acceptance text"]
          XCTAssertTrue(input.exists)
          let marker = "\(iteration)-" + UUID().uuidString
          try typeAndObserve(marker, in: input, name: "mixed-\(iteration)", submits: true)
          try dismissSystemKeyboard()
        }
        if pencil {
          try selectBlackPen()
          let start = ink.coordinate(withNormalizedOffset: .init(dx: 0.12, dy: 0.34))
          start.press(forDuration: 0.06, thenDragTo: start.withOffset(.init(dx: 55, dy: 25)))
        } else {
          // Rotation can place a live button under a fixed canvas fraction.
          // A camera contact must start on the observed free board, not ask
          // WebKit to reinterpret a legitimate control contact as navigation.
          try panFreeBoard(by: .init(dx: iteration.isMultiple(of: 2) ? 30 : -30, dy: 0), recordsEvidence: false)
        }
        let enlarge = controlWebView.frame.height < controlViewport.height * 0.52
        ink.pinch(withScale: enlarge ? 1.02 : 0.8, velocity: enlarge ? 0.6 : -0.6)
        if iteration.isMultiple(of: 5) {
          XCUIDevice.shared.orientation = iteration.isMultiple(of: 10) ? .landscapeLeft : .portrait
        }
        XCTAssertFalse(app.otherElements["persistence-failure"].exists)
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        try fitControlMaterial(using: ink, permitsFingerPan: !pencil)
        XCTAssertEqual(try counterValue(), before + 1)
        if ProcessInfo.processInfo.systemUptime - lastScreenshot >= 60 {
          screenshot("mixed-minute-\(Int((ProcessInfo.processInfo.systemUptime - began) / 60))")
          lastScreenshot = ProcessInfo.processInfo.systemUptime
        }
      }
  }

  /// System metrics are exported from xcresult. A missing/unsupported hitch
  /// series is an unmeasured gate, never zero dropped frames. Video is separate.
  func testSystemMeasuredCameraMotion() throws {
    try launch()
    try navigateToAcceptanceControls()
    XCTAssertTrue(app.webViews.buttons["Acceptance increment"].waitForExistence(timeout: 10))
    let ink = app.otherElements["spatial-ink"]
    screenshot("system-motion-before")
    let options = XCTMeasureOptions()
    options.iterationCount = 10
    options.invocationOptions = [.manuallyStop]
    #if targetEnvironment(simulator)
    let metrics: [XCTMetric] = [XCTClockMetric(), XCTCPUMetric(application: app), XCTMemoryMetric(application: app)]
    let unsupported = XCTAttachment(string: "Simulator Hitches backend refused this platform. CPU/memory and attached Time Profiler are separate measurements; dropped-frame acceptance remains unmeasured.")
    unsupported.name = "system-frame-measurement-unavailable"; unsupported.lifetime = .keepAlways; add(unsupported)
    #else
    let metrics: [XCTMetric] = [XCTClockMetric(), XCTCPUMetric(application: app), XCTMemoryMetric(application: app), XCTHitchMetric(application: app)]
    #endif
    measure(metrics: metrics, options: options) {
      let start = ink.coordinate(withNormalizedOffset: .init(dx: 0.35, dy: 0.28))
      let end = start.withOffset(.init(dx: 140, dy: 45))
      start.press(forDuration: 0.01, thenDragTo: end)
      stopMeasuring()
      end.press(forDuration: 0.01, thenDragTo: start)
    }
    XCTAssertTrue(app.webViews.buttons["Acceptance increment"].exists)
    XCTAssertFalse(app.otherElements["persistence-failure"].exists)
    screenshot("system-motion-after-ten-repetitions")
    try systemTrace?.ended(app)
  }

  private var controlWebView: XCUIElement {
    app.webViews.containing(.button, identifier: "Acceptance increment").firstMatch
  }

  private var controlViewport: CGRect {
    let window = app.windows.firstMatch.frame
    return CGRect(x: window.minX + 28, y: window.minY + 90,
      width: window.width - 56, height: window.height - 200)
  }

  private struct ControlGeometryError: Error, CustomStringConvertible {
    let description: String
  }

  private struct ControlFitGeometry {
    let webFrame: CGRect
    let controlFrames: [CGRect]
    let viewport: CGRect

    func hasFrozenControls(after previous: Self) -> Bool {
      func change(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        max(abs(lhs.minX - rhs.minX), abs(lhs.minY - rhs.minY),
          abs(lhs.width - rhs.width), abs(lhs.height - rhs.height))
      }
      // The same one-point precision as the real native pan assertion. A
      // subpixel frame read is not evidence that the camera moved a control.
      return change(webFrame, previous.webFrame) > 1
        && controlFrames.count == previous.controlFrames.count && !controlFrames.isEmpty
        && zip(controlFrames, previous.controlFrames).allSatisfy { change($0, $1) <= 1 }
    }

    var evidence: [String: Any] {
      func components(_ frame: CGRect) -> [CGFloat] { [frame.minX, frame.minY, frame.width, frame.height] }
      return ["webFrame": components(webFrame), "controlFrames": controlFrames.map(components),
        "viewport": components(viewport)]
    }
  }

  func testControlFitObserverRejectsFrozenAXAfterNativeMovement() {
    let web = CGRect(x: 50, y: 400, width: 720, height: 370)
    let frames = [CGRect(x: 140, y: 497, width: 87, height: 53),
      CGRect(x: 143, y: 583, width: 349, height: 17), CGRect(x: 140, y: 629, width: 669, height: 53)]
    let viewport = CGRect(x: 28, y: 90, width: 764, height: 980)
    let before = ControlFitGeometry(webFrame: web, controlFrames: frames, viewport: viewport)
    XCTAssertTrue(ControlFitGeometry(webFrame: web.offsetBy(dx: -65, dy: -9.5),
      controlFrames: frames, viewport: viewport).hasFrozenControls(after: before), "Do not send the second corrective pan")
    XCTAssertTrue(ControlFitGeometry(webFrame: web.applying(.init(scaleX: 0.8, y: 0.8)),
      controlFrames: frames, viewport: viewport).hasFrozenControls(after: before), "A pinch must not reuse frozen AX either")
    XCTAssertFalse(before.hasFrozenControls(after: before), "No native movement is not the stale-AX diagnosis")
    XCTAssertFalse(ControlFitGeometry(webFrame: web.offsetBy(dx: 0.5, dy: 0.5),
      controlFrames: frames, viewport: viewport).hasFrozenControls(after: before), "Ignore subpixel native jitter")
    XCTAssertFalse(ControlFitGeometry(webFrame: web.offsetBy(dx: -65, dy: -9.5),
      controlFrames: frames.map { $0.offsetBy(dx: -65, dy: -9.5) }, viewport: viewport)
      .hasFrozenControls(after: before), "Following AX must still permit ordinary fitting")
    XCTAssertFalse(ControlFitGeometry(webFrame: web.applying(.init(scaleX: 0.8, y: 0.8)),
      controlFrames: frames.map { $0.applying(.init(scaleX: 0.8, y: 0.8)) }, viewport: viewport)
      .hasFrozenControls(after: before), "Following AX must still permit an ordinary pinch")
  }

  private func controlFitGeometry() throws -> ControlFitGeometry {
    // Native WK and its AX children must come from one immutable observation,
    // not a series of queries across different camera/layout instants.
    let snapshot = try controlWebView.snapshot()
    func find(_ node: XCUIElementSnapshot, type: XCUIElement.ElementType, name: String) -> XCUIElementSnapshot? {
      if node.elementType == type && (node.identifier == name || node.label == name) { return node }
      return node.children.lazy.compactMap { find($0, type: type, name: name) }.first
    }
    let frames = try [(XCUIElement.ElementType.button, "Acceptance increment"),
      (.slider, "Acceptance slider"), (.textField, "Acceptance text")].map { type, name in
        try XCTUnwrap(find(snapshot, type: type, name: name), "Missing control in native WK observation: \(name)").frame
      }
    return ControlFitGeometry(webFrame: snapshot.frame, controlFrames: frames, viewport: controlViewport)
  }

  private func failControlFitObservation(_ reason: String, before: ControlFitGeometry?,
    after: ControlFitGeometry, corrections: Int) throws -> Never {
    let geometry: [String: Any] = ["reason": reason, "completedCorrections": corrections,
      "coordinateSpace": "screen points", "controlOrder": ["Acceptance increment", "Acceptance slider", "Acceptance text"],
      "before": before?.evidence ?? [:], "after": after.evidence]
    let observation = XCTAttachment(data: try JSONSerialization.data(withJSONObject: geometry, options: [.sortedKeys]),
      uniformTypeIdentifier: "public.json")
    observation.name = "control-fit-observation-failure"; observation.lifetime = .keepAlways; add(observation)
    screenshot("control-fit-observation-failure")
    throw ControlGeometryError(description: "Control-fit observation failed after \(corrections) correction(s): \(reason). No further corrective gesture was sent.")
  }

  private func screenCoordinate(_ point: CGPoint) -> XCUICoordinate {
    let window = app.windows.firstMatch
    return window.coordinate(withNormalizedOffset: .zero)
      .withOffset(.init(dx: point.x - window.frame.minX, dy: point.y - window.frame.minY))
  }

  /// These are ordinary camera gestures over the real material. In particular,
  /// a nominal inverse XCTest pinch is not assumed to restore the earlier pose.
  private func fitControlMaterial(using ink: XCUIElement, permitsFingerPan: Bool = true) throws {
    XCTAssertTrue(controlWebView.waitForExistence(timeout: 5))
    var previous: ControlFitGeometry?
    for corrections in 0...6 {
      // Input acceptance needs the actual button, slider and field completely
      // visible. Empty HTML padding can extend under chrome without covering
      // any control; shrinking that padding is not a user interaction gate.
      let controls = [app.webViews.buttons["Acceptance increment"],
        app.webViews.sliders["Acceptance slider"], app.webViews.textFields["Acceptance text"]]
      let geometry = try controlFitGeometry()
      let frame = geometry.controlFrames.reduce(CGRect.null) { $0.union($1) }, viewport = geometry.viewport
      guard !frame.isEmpty, !frame.isInfinite, !frame.isNull else {
        throw ControlGeometryError(description: "The live control has no finite AX frame: \(frame)")
      }
      if let previous, geometry.hasFrozenControls(after: previous) {
        try failControlFitObservation("Native surface moved but AX control frames stayed unchanged",
          before: previous, after: geometry, corrections: corrections)
      }
      if viewport.contains(frame) {
        XCTAssertTrue(controls.allSatisfy(\.isHittable), "Every fully visible control must accept an actual touch")
        XCTAssertGreaterThanOrEqual(app.webViews.buttons["Acceptance increment"].frame.height, 18,
          "The control must remain large enough for a real touch after fitting")
        return
      }
      guard corrections < 6 else {
        try failControlFitObservation("Real camera gestures did not fit the actual controls",
          before: previous, after: geometry, corrections: corrections)
      }
      previous = geometry
      if frame.width > viewport.width || frame.height > viewport.height || !permitsFingerPan {
        // In the Pencil profile a one-finger camera repair would be a stroke.
        // A real inward two-finger gesture can bring the source into view.
        ink.pinch(withScale: 0.8, velocity: -0.6)
      } else {
        let dx = min(max(viewport.midX - frame.midX, -viewport.width * 0.35), viewport.width * 0.35)
        let dy = min(max(viewport.midY - frame.midY, -viewport.height * 0.35), viewport.height * 0.35)
        try panFreeBoard(by: .init(dx: dx, dy: dy), recordsEvidence: false)
      }
    }
  }

  private func occupiedCanvasFrames(_ element: XCUIElementSnapshot) -> [CGRect] {
    let occupies = [.webView, .button, .textView, .textField, .keyboard]
      .contains(element.elementType) || element.identifier == "notebook-chat-panel"
    if occupies, element.frame.height > 1 { return [element.frame] }
    return element.children.flatMap(occupiedCanvasFrames)
  }

  private func selectBlackPen() throws {
    let group = app.buttons["drawing-group"]
    if !group.isSelected { group.tap() }
    if !app.buttons["drawing-tool-pen"].exists { group.tap() }
    XCTAssertTrue(app.buttons["drawing-tool-pen"].waitForExistence(timeout: 3))
    app.buttons["drawing-tool-pen"].tap()
    app.buttons["drawing-primary-color"].tap()
    let black = app.buttons["drawing-color-black"]
    XCTAssertTrue(black.waitForExistence(timeout: 3)); black.tap()
    XCTAssertTrue(black.waitForNonExistence(timeout: 3))
  }

  private func panFreeBoard(by delta: CGVector, recordsEvidence: Bool = true) throws {
    // Leave the system's edge-gesture area outside the scene-pan route.
    // A narrow visual strip next to a widget is not a proven app touch area.
    let viewport = app.windows.firstMatch.frame.insetBy(dx: 44, dy: 44)
    // One immutable AX snapshot keeps transient keyboard children from
    // invalidating positional queries while their individual frames are read.
    let snapshot = try app.snapshot()
    let occupied = occupiedCanvasFrames(snapshot)
    let fractions: [CGFloat] = [0.5, 0.25, 0.75, 0.08, 0.92, 0.03, 0.97, 0.01, 0.99]
    // A source may leave only a narrow free strip. Move by a feasible portion
    // and let the caller re-read the resulting geometry before the next drag.
    for portion: CGFloat in [1, 0.75, 0.5, 0.25] {
      let translation = CGVector(dx: delta.dx * portion, dy: delta.dy * portion)
      guard hypot(translation.dx, translation.dy) >= 12 else { continue }
      for y in fractions {
        for x in fractions {
          let point = CGPoint(x: viewport.minX + viewport.width * x, y: viewport.minY + viewport.height * y)
          let end = CGPoint(x: point.x + translation.dx, y: point.y + translation.dy)
          guard viewport.contains(end), !occupied.contains(where: { $0.insetBy(dx: -6, dy: -6).contains(point) }) else { continue }
          let before = controlWebView.frame
          screenCoordinate(point).press(forDuration: 0.01, thenDragTo: screenCoordinate(end))
          let after = controlWebView.frame
          let proof: [String: Any] = ["start": [point.x, point.y], "end": [end.x, end.y],
            "requestedTranslation": [translation.dx, translation.dy],
            "frameBefore": [before.minX, before.minY, before.width, before.height],
            "frameAfter": [after.minX, after.minY, after.width, after.height],
            "excludedFrames": occupied.map { [$0.minX, $0.minY, $0.width, $0.height] },
            "systemEdgeInset": 44]
          if recordsEvidence {
            let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: proof,
              options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
            attachment.name = "actual-free-board-pan-route"; attachment.lifetime = .keepAlways; add(attachment)
            screenshot("actual-free-board-after-pan")
          }
          XCTAssertEqual(after.midX - before.midX, translation.dx, accuracy: 1,
            "The real board pan must move the displayed control horizontally")
          XCTAssertEqual(after.midY - before.midY, translation.dy, accuracy: 1,
            "The real board pan must move the displayed control vertically")
          return
        }
      }
    }
    throw ControlGeometryError(description: "No visible free-board start/end for camera translation \(delta)")
  }

  private func acceptanceSliderValue(_ slider: XCUIElement) throws -> Double {
    let raw = try XCTUnwrap(slider.value as? String)
    let number = raw.replacingOccurrences(of: "%", with: "")
      .replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespacesAndNewlines)
    let value = try XCTUnwrap(Double(number), "Unexpected slider value: " + raw)
    guard (0...100).contains(value) else {
      throw ControlGeometryError(description: "Acceptance slider value is outside its authored 0...100 range: \(value)")
    }
    return value
  }

  /// WebKit exposes the actual thumb as a child, even when its slider parent's
  /// AX origin is clipped. XCTest's min/max scrubber attributes can both be zero;
  /// drive the real thumb with a native drag instead of an accessibility setter.
  private func dragAcceptanceSlider() throws {
    let slider = app.webViews.sliders["Acceptance slider"]
    XCTAssertTrue(slider.exists)
    let previous = try acceptanceSliderValue(slider)
    let children = slider.children(matching: .other).allElementsBoundByIndex.filter {
      !$0.frame.isEmpty && $0.frame.width < slider.frame.width && $0.frame.height <= slider.frame.height
    }
    let thumb = try XCTUnwrap(children.count == 1 ? children.first : nil,
      "A unique native thumb is required: " + slider.debugDescription)
    let thumbFrame = thumb.frame, window = app.windows.firstMatch.frame.insetBy(dx: 16, dy: 16)
    XCTAssertTrue(window.contains(thumbFrame), "The whole thumb must be visible: \(thumbFrame)")
    let travel = slider.frame.width - thumbFrame.width
    XCTAssertGreaterThan(travel, 24)
    let center = CGPoint(x: thumbFrame.midX, y: thumbFrame.midY)
    let lower = max(window.minX + thumbFrame.width / 2, center.x - CGFloat(previous / 100) * travel)
    let upper = min(window.maxX - thumbFrame.width / 2, center.x + CGFloat(1 - previous / 100) * travel)
    let destination = previous >= 50 ? lower : upper
    let distance = min(100, abs(destination - center.x) * 0.8)
    XCTAssertGreaterThanOrEqual(distance, 12, "The visible track must permit a meaningful drag")
    let target = CGPoint(x: center.x + (destination < center.x ? -distance : distance), y: center.y)
    XCTAssertTrue(window.contains(target))
    screenCoordinate(center).press(forDuration: 0.05, thenDragTo: screenCoordinate(target))
    let changed = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
      guard let current = try? acceptanceSliderValue(slider) else { return false }
      return abs(current - previous) >= 0.01
    }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 3), .completed,
      "A real drag from \(center) to \(target) must change the actual slider value")
    let current = try acceptanceSliderValue(slider)
    XCTAssertNotEqual(current, previous)
    let visibleValue = app.webViews.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Acceptance slider: ")).firstMatch
    XCTAssertTrue(visibleValue.waitForExistence(timeout: 3))
    let rendered = try XCTUnwrap(Double(visibleValue.label.replacingOccurrences(of: "Acceptance slider: ", with: "")
      .replacingOccurrences(of: ",", with: ".")))
    XCTAssertEqual(rendered, current, accuracy: 0.01, "The user's visible output must agree with the dragged control")
    let receipt = XCTAttachment(string: "thumbFrame=\(thumbFrame)\nstart=\(center)\ntarget=\(target)\nbefore=\(previous)\nafter=\(current)")
    receipt.name = "actual-slider-native-drag"; receipt.lifetime = .keepAlways; add(receipt)
  }

  private func dismissSystemKeyboard() throws {
    let keyboard = app.keyboards.firstMatch
    // XCTest also exposes a zero-height keyboard while Simulator uses the
    // hardware keyboard. Its existence does not mean a visible panel exists.
    guard keyboard.exists, keyboard.frame.height > 1 else { return }
    let hide = app.keyboards.buttons.matching(NSPredicate(format: "label IN %@",
      ["Hide keyboard", "Скрыть клавиатуру", "Dismiss keyboard", "Убрать клавиатуру"])).firstMatch
    guard hide.exists, hide.isHittable else {
      throw ControlGeometryError(description: "The visible system keyboard has no accessible dismissal control: " + app.keyboards.debugDescription)
    }
    hide.tap()
    let hidden = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
      !app.keyboards.firstMatch.exists || app.keyboards.firstMatch.frame.height <= 1
    }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 3), .completed)
  }

  private func counterValue() throws -> Int {
    let prefix = "Acceptance count: "
    let labels = app.webViews.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).allElementsBoundByIndex
    let value = try XCTUnwrap(labels.first).label
    return try XCTUnwrap(Int(value.dropFirst(prefix.count)), "Unexpected counter: " + value)
  }

  /// Ordinary navigation and system-routed Simulator contacts. The straight
  /// lasso tests its real entry/rejection path; XCTest has no public API for a
  /// multi-segment closed Pencil contour (native contact tests cover that path).
  func testTenPageInkUndoLassoAndNavigationJourneys() throws {
    executionTimeAllowance=600
    try launch(readinessIdentifier:"notebook-search")
    for iteration in 0..<10 { try pageInkJourney(iteration) }
    try systemTrace?.ended(app)
  }

  func testThirtyMinutesOfPageInkUndoLassoAndNavigation() throws {
    let seconds=try XCTUnwrap(ProcessInfo.processInfo.environment["NOTEBOOK_ACCEPTANCE_WORKLOAD_SECONDS"].flatMap(Double.init))
    XCTAssertGreaterThanOrEqual(seconds,1800);XCTAssertLessThanOrEqual(seconds,2700)
    executionTimeAllowance=seconds+120
    try launch(readinessIdentifier:"notebook-search")
    let began=ProcessInfo.processInfo.systemUptime
    var iteration=0, replies=0
    var lastScreenshot=began-60, lastReply=began-300
    while ProcessInfo.processInfo.systemUptime-began < seconds {
      try pageInkJourney(iteration)
      try navigateToAcceptanceControls()
      try performMixedIteration(iteration,pencil:true,began:began,lastScreenshot:&lastScreenshot)
      if ProcessInfo.processInfo.systemUptime-lastReply >= 300 {
        if replies == 0 { try sendRealStreamingWhileDrawing() }
        else { try sendRealChatReply() }
        replies += 1;lastReply=ProcessInfo.processInfo.systemUptime
      }
      iteration += 1
    }
    XCTAssertGreaterThanOrEqual(iteration,10);XCTAssertGreaterThan(replies,0)
    let proof=XCTAttachment(string:"elapsedSeconds=\(ProcessInfo.processInfo.systemUptime-began)\ncompletedJourneys=\(iteration)\nrealChatResponses=\(replies)\nEvery cycle uses page ink/history/lasso/navigation and live program controls; first response grows across actual ink and is stopped, subsequent connected replies every five minutes. System-routed Simulator gestures, not physical FPS/Pencil latency. Closed lasso is exercised by native contacts.")
    proof.name="page-ink-mixed-workload-duration";proof.lifetime = .keepAlways;add(proof)
    try systemTrace?.ended(app)
  }

  private func pageInkJourney(_ iteration:Int) throws {
    try XCTContext.runActivity(named:"page-ink-journey-\(iteration)") { _ in
      let environment=ProcessInfo.processInfo.environment
      XCTAssertEqual(environment["NOTEBOOK_ACCEPTANCE_PENCIL_CONTACTS"],"1","Use the existing isolated Simulator Pencil profile")
      let notebook=try XCTUnwrap(environment["NOTEBOOK_ACCEPTANCE_NOTEBOOK_ID"].flatMap(UUID.init(uuidString:)))
      let title=try XCTUnwrap(environment["NOTEBOOK_ACCEPTANCE_NOTEBOOK_TITLE"])
      if XCUIDevice.shared.orientation != .portrait { XCUIDevice.shared.orientation = .portrait }
      let collapse=app.buttons["notebook-chat-toggle"]
      if collapse.isHittable { collapse.tap() }
      app.buttons["notebook-search"].tap()
      let search=app.searchFields.firstMatch
      let query="Лист ввода "+notebook.uuidString.lowercased()
      XCTAssertTrue(search.waitForExistence(timeout:5));search.tap();search.typeText(query)
      let matches=app.collectionViews.buttons.matching(NSPredicate(format:"label CONTAINS %@ AND label CONTAINS %@",query,title))
      XCTAssertTrue(matches.firstMatch.waitForExistence(timeout:10));XCTAssertEqual(matches.count,1)
      screenshot("page-ink-unique-addressed-search-\(iteration)")
      matches.firstMatch.tap()
      XCTAssertTrue(search.waitForNonExistence(timeout:10))
      let surface=app.otherElements["page-turn-surface"]
      XCTAssertTrue(surface.waitForExistence(timeout:10))
      var input:XCUIElement?
      let ready=XCTNSPredicateExpectation(predicate:NSPredicate { [self] _,_ in
        input=app.otherElements.matching(identifier:"paper-input").allElementsBoundByIndex.first { $0.isHittable }
        return input != nil
      },object:nil)
      XCTAssertEqual(XCTWaiter.wait(for:[ready],timeout:10),.completed)
      let paper=try XCTUnwrap(input)
      let frameReadStarted=ProcessInfo.processInfo.systemUptime
      let frame=paper.frame
      let frameReadEnded=ProcessInfo.processInfo.systemUptime
      @MainActor func diagnose(_ stage:String,_ samples:[(String,DarkPixelSample)]) throws {
        try attachPageInkFailure(iteration:iteration,stage:stage,paper:paper,initialFrame:frame,
          frameReadStarted:frameReadStarted,frameReadEnded:frameReadEnded,samples:samples)
      }
      try selectBlackPen()
      let y=0.32+Double(iteration%5)*0.025
      let from=paper.coordinate(withNormalizedOffset:.init(dx:0.35,dy:y))
      let to=paper.coordinate(withNormalizedOffset:.init(dx:0.65,dy:y+0.15))
      let previous=paper.value as? String
      from.press(forDuration:0.02,thenDragTo:to,withVelocity:.fast,thenHoldForDuration:0)
      let written=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in paper.value as? String != previous },object:nil)
      XCTAssertEqual(XCTWaiter.wait(for:[written],timeout:5),.completed)
      let probe=CGPoint(x:frame.midX,y:frame.minY+frame.height*(y+0.075))
      let baseline=try darkPixelSample(near:probe),ink=baseline.count
      if ink <= 8 { try diagnose("baseline",[("baseline",baseline)]) }
      XCTAssertGreaterThan(ink,8,"A committed contact must leave actual pixels")
      app.buttons["drawing-tool-eraser"].tap()
      let eraseFrom=paper.coordinate(withNormalizedOffset:.init(dx:0.5,dy:y+0.03))
      eraseFrom.press(forDuration:0.02,thenDragTo:paper.coordinate(withNormalizedOffset:.init(dx:0.5,dy:y+0.12)),
        withVelocity:.fast,thenHoldForDuration:0)
      // No artificial settle wait before the accepted inverse/repeat.
      surface.tap(withNumberOfTaps:1,numberOfTouches:2)
      let undone=try darkPixelSample(near:probe)
      if undone.count <= 8 { try diagnose("undo",[("baseline",baseline),("undo",undone)]) }
      XCTAssertGreaterThan(undone.count,8,"Undo immediately revokes the eraser material")
      surface.tap(withNumberOfTaps:1,numberOfTouches:3)
      let redone=try darkPixelSample(near:probe)
      if redone.count >= ink { try diagnose("redo",[("baseline",baseline),("undo",undone),("redo",redone)]) }
      XCTAssertLessThan(redone.count,ink,"Redo must restore the cut, not resurrect the line")
      let actions=paper.value as? String
      app.buttons["drawing-tool-lasso"].tap()
      paper.coordinate(withNormalizedOffset:.init(dx:0.18,dy:0.22)).press(forDuration:0.02,
        thenDragTo:paper.coordinate(withNormalizedOffset:.init(dx:0.25,dy:0.27)),withVelocity:.slow,thenHoldForDuration:0)
      XCTAssertEqual(paper.value as? String,actions,"A lasso is read-only, including a zero-area contour")
      XCTAssertFalse(app.buttons["finish-graphic-selection"].exists)
      let page=try XCTUnwrap((surface.value as? String)?.components(separatedBy:" из ").first)+" из "
      app.buttons["next-page"].tap()
      let forward=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in (surface.value as? String)?.hasPrefix(page) == false },object:nil)
      XCTAssertEqual(XCTWaiter.wait(for:[forward],timeout:10),.completed)
      app.buttons["previous-page"].tap()
      let back=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in (surface.value as? String)?.hasPrefix(page) == true },object:nil)
      XCTAssertEqual(XCTWaiter.wait(for:[back],timeout:10),.completed)
      surface.pinch(withScale:1.08,velocity:0.6)
      XCTAssertTrue(surface.exists);XCTAssertFalse(app.otherElements["persistence-failure"].exists)
      screenshot("page-ink-journey-\(iteration)-settled")
    }
  }

  private struct DarkPixelSample {
    let screenshot:XCUIScreenshot
    let croppedImage:CGImage
    let imageSize:CGSize
    let point:CGPoint
    let crop:CGRect
    let scale:CGFloat
    let widthFrame:CGRect
    let originXFrame:CGRect
    let originYFrame:CGRect
    let captureStarted:TimeInterval
    let captureEnded:TimeInterval
    let decodedAt:TimeInterval
    let count:Int
  }

  private func darkPixels(near point:CGPoint) throws -> Int { try darkPixelSample(near:point).count }

  private func darkPixelSample(near point:CGPoint) throws -> DarkPixelSample {
    let captureStarted=ProcessInfo.processInfo.systemUptime
    let screenshot=app.screenshot()
    let captureEnded=ProcessInfo.processInfo.systemUptime
    let image=try XCTUnwrap(screenshot.image.cgImage)
    // Keep the original three AX frame reads and arithmetic order. These are
    // separate observations, not an asserted screenshot-synchronous geometry.
    let widthFrame=app.frame
    let scale=Double(image.width)/widthFrame.width
    let size=17
    let originXFrame=app.frame
    let centerX=Int((point.x-originXFrame.minX)*scale)
    let originYFrame=app.frame
    let centerY=Int((point.y-originYFrame.minY)*scale)
    let crop=CGRect(x:centerX-size/2,y:centerY-size/2,width:size,height:size)
    let sample=try XCTUnwrap(image.cropping(to:crop))
    var bytes=[UInt8](repeating:0,count:size*size*4)
    let context=try XCTUnwrap(CGContext(data:&bytes,width:size,height:size,bitsPerComponent:8,bytesPerRow:size*4,
      space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(sample,in:.init(x:0,y:0,width:size,height:size))
    let count=(0..<size*size).filter { bytes[$0*4] < 96 && bytes[$0*4+1] < 96 && bytes[$0*4+2] < 96 }.count
    return .init(screenshot:screenshot,croppedImage:sample,imageSize:.init(width:image.width,height:image.height),
      point:point,crop:crop,scale:scale,widthFrame:widthFrame,originXFrame:originXFrame,originYFrame:originYFrame,
      captureStarted:captureStarted,captureEnded:captureEnded,decodedAt:ProcessInfo.processInfo.systemUptime,count:count)
  }

  private func attachPageInkFailure(iteration:Int,stage:String,paper:XCUIElement,initialFrame:CGRect,
    frameReadStarted:TimeInterval,frameReadEnded:TimeInterval,samples:[(String,DarkPixelSample)]) throws {
    // Only after a failed sample: no new AX read, image capture or attachment
    // delays the immediate eraser → Undo → Redo path being diagnosed.
    let postStarted=ProcessInfo.processInfo.systemUptime
    let postFrame=paper.frame
    let postValue=paper.value as? String
    let postEnded=ProcessInfo.processInfo.systemUptime
    func rect(_ value:CGRect) -> [CGFloat] { [value.minX,value.minY,value.width,value.height] }
    let prefix="page-ink-journey-\(iteration)-\(stage)-failure"
    let observations:[[String:Any]]=samples.map { name,sample in
      let full=XCTAttachment(screenshot:sample.screenshot)
      full.name=prefix+"-"+name+"-full";full.lifetime = .keepAlways;add(full)
      let crop=XCTAttachment(image:UIImage(cgImage:sample.croppedImage))
      crop.name=prefix+"-"+name+"-crop";crop.lifetime = .keepAlways;add(crop)
      return ["stage":name,"darkPixelCount":sample.count,"probe":[sample.point.x,sample.point.y],
        "imageSizePixels":[sample.imageSize.width,sample.imageSize.height],"cropPixels":rect(sample.crop),"scale":sample.scale,
        "appFrameReadsInOrder":[rect(sample.widthFrame),rect(sample.originXFrame),rect(sample.originYFrame)],
        "captureStartedUptime":sample.captureStarted,"captureEndedUptime":sample.captureEnded,"decodedUptime":sample.decodedAt]
    }
    let evidence:[String:Any]=["iteration":iteration,"failedStage":stage,
      "initialPaperFrame":rect(initialFrame),"initialFrameReadStartedUptime":frameReadStarted,"initialFrameReadEndedUptime":frameReadEnded,
      "samples":observations,"postFailedCapturePaperFrame":rect(postFrame),"postFailedCapturePaperValue":postValue as Any? ?? NSNull(),
      "postFailedCaptureReadStartedUptime":postStarted,"postFailedCaptureReadEndedUptime":postEnded,
      "boundary":"The original probe, three captures, three app.frame reads per capture, crop and RGB predicate are unchanged. Post-failure AX is later than the measured screenshot, not a causal acceptance or presentation receipt."]
    let attachment=XCTAttachment(data:try JSONSerialization.data(withJSONObject:evidence,options:[.prettyPrinted,.sortedKeys]),
      uniformTypeIdentifier:"public.json")
    attachment.name=prefix+"-geometry";attachment.lifetime = .keepAlways;add(attachment)
  }

  func testMeasuredPencilContactsCommitAndEraserRemainsReachable() throws {
    try launch()
    let ink = app.otherElements["spatial-ink"]
    let previous = ink.value as? String
    let start = ink.coordinate(withNormalizedOffset: .init(dx: 0.12, dy: 0.35))
    start.press(forDuration: 0.1, thenDragTo: start.withOffset(.init(dx: 170, dy: 80)))
    let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in ink.value as? String != previous }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
    screenshot("measured-simulator-pencil-committed")
    let eraser = app.buttons["drawing-tool-eraser"]
    XCTAssertTrue(eraser.isHittable); eraser.tap()
    let written = ink.value as? String
    start.withOffset(.init(dx: 40, dy: 15)).press(forDuration: 0.1,
      thenDragTo: start.withOffset(.init(dx: 120, dy: 70)))
    let erased = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in ink.value as? String != written }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [erased], timeout: 5), .completed)
    screenshot("measured-simulator-eraser-committed")
    XCTAssertFalse(app.otherElements["persistence-failure"].exists)
    try systemTrace?.ended(app)
  }
}

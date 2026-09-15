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
    if !app.buttons["notebook-chat-menu"].isHittable {
      if app.buttons["notebook-chat-toggle"].isHittable { app.buttons["notebook-chat-toggle"].tap() }
      if app.buttons["notebook-companion-compose"].waitForExistence(timeout: 5) {
        app.buttons["notebook-companion-compose"].tap()
      }
    }
    XCTAssertTrue(app.buttons["notebook-chat-menu"].waitForExistence(timeout: 5))
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

  private func assertPresentedPairingIdentity() throws {
    // LabeledContent exposes its value on the combined accessible row. It
    // need not create a separate StaticText on every iOS version.
    for (key, label) in [("NOTEBOOK_ACCEPTANCE_PEER_ID", "Устройство"),
                         ("NOTEBOOK_ACCEPTANCE_WORKSPACE_ID", "Пространство")] {
      let expected = try XCTUnwrap(ProcessInfo.processInfo.environment[key]).lowercased()
      let identity = app.descendants(matching: .any).matching(
        NSPredicate(format: "label == %@ OR label == %@ OR value == %@",
                    label + ", " + expected, expected, expected)).firstMatch
      XCTAssertTrue(identity.exists, "Expected visible identity \(expected): \(app.debugDescription)")
    }
  }

  func testJoinRealMacThroughPairingUI() throws {
    try launch(readinessIdentifier: "notebook-companion-compose"); openChat()
    app.buttons["notebook-chat-menu"].tap()
    app.buttons["pairing-settings"].tap()
    let invitation = try XCTUnwrap(ProcessInfo.processInfo.environment["NOTEBOOK_ACCEPTANCE_INVITATION"])
    let field = app.descendants(matching: .any).matching(identifier: "pairing-invitation").firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(invitation)
    let entered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      (field.value as? String) == invitation
    }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [entered], timeout: 5), .completed,
      "The complete invitation must reach the ordinary field before connecting")
    let hideKeyboard = app.keyboards.buttons["Hide keyboard"]
    if hideKeyboard.exists && hideKeyboard.isHittable { hideKeyboard.tap() }
    let connect = app.buttons["Подключиться"]
    var previousFrame: CGRect?
    let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      guard connect.exists && connect.isEnabled && connect.isHittable else { return false }
      let frame = connect.frame
      defer { previousFrame = frame }
      return !frame.isEmpty && previousFrame == frame
    }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed,
      "The multi-line field and keyboard must finish moving the visible button before the real tap")
    connect.tap()
    let confirm = app.buttons["Разрешить этому Mac доступ"]
    XCTAssertTrue(confirm.waitForExistence(timeout: 20), app.debugDescription)
    screenshot("ipad-real-peer-before-confirmation")
    try assertPresentedPairingIdentity()
    confirm.tap()
    XCTAssertTrue(app.staticTexts["Вы подтвердили. Ожидается подтверждение на Mac."].waitForExistence(timeout: 10),
      "The local approval must be saved before this UI step completes")
    screenshot("ipad-confirmed-awaiting-mac")
    try systemTrace?.ended(app)
  }

  /// The Mac invitation is copied with its visible product button. This test
  /// focuses the ordinary iPad field, then waits for Simulator's Edit > Paste.
  /// It neither reads UIPasteboard nor accepts invitation text from the runner.
  func testJoinRealMacAfterSystemPaste() throws {
    executionTimeAllowance = 160
    try launch(readinessIdentifier: "notebook-companion-compose"); openChat()
    app.buttons["notebook-chat-menu"].tap()
    app.buttons["pairing-settings"].tap()
    let restart = app.buttons["Начать заново"]
    if restart.waitForExistence(timeout: 1) {
      screenshot("ipad-pairing-failed-before-visible-restart")
      restart.tap()
    }
    let field = app.descendants(matching: .any).matching(identifier: "pairing-invitation").firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 5)); XCTAssertTrue(field.isHittable)
    field.tap()
    FileHandle.standardOutput.write(Data("NOTEBOOK_ACCEPTANCE_READY_FOR_SYSTEM_PASTE\n".utf8))
    screenshot("ipad-invitation-field-ready-for-system-paste")
    let pasted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      (field.value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        .hasPrefix("notebook-pair:v2:") == true
    }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [pasted], timeout: 90), .completed,
      "Paste the invitation using the Simulator Edit menu while the real field is focused.")
    let connect = app.buttons["Подключиться"]
    XCTAssertTrue(connect.isEnabled); connect.tap()
    let confirm = app.buttons["Разрешить этому Mac доступ"]
    XCTAssertTrue(confirm.waitForExistence(timeout: 20), app.debugDescription)
    screenshot("ipad-pasted-invitation-real-peer-before-confirmation")
    try assertPresentedPairingIdentity()
    confirm.tap()
    XCTAssertTrue(app.staticTexts["Вы подтвердили. Ожидается подтверждение на Mac."].waitForExistence(timeout: 5))
    screenshot("ipad-pasted-invitation-confirmed-awaiting-mac")
    try systemTrace?.ended(app)
  }

  func testRealChatReplyAfterPairing() throws {
    try launch(); openChat()
    let create = app.buttons["notebook-chat-new"]
    XCTAssertTrue(create.isEnabled); create.tap()
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
    try systemTrace?.ended(app)
  }

  /// Run on the private Simulator after its microphone permission was denied.
  /// The notice comes from the real audio owner after a real button gesture;
  /// neither the error, the draft nor the assistant reply is injected.
  func testDeniedDictationRetainsDraftAndTextSend() throws {
    try launch(); openChat()
    let create = app.buttons["notebook-chat-new"]
    XCTAssertTrue(create.isEnabled); create.tap()
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
    XCTAssertTrue(app.buttons["notebook-chat-menu"].waitForExistence(timeout: 5))
    XCTAssertEqual(field.value as? String, originalText)
    XCTAssertEqual(paper.frame, originalPaper)
    screenshot("chat-opened-from-widget-keyboard-with-paper-preserved")
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
  /// It uses the ordinary private app even when pairing has not completed yet.
  func testSystemTraceAttachesToLaunchedApplication() throws {
    try launch(readinessIdentifier: "notebook-companion-compose")
    XCTAssertNotNil(systemTrace, "Run this probe with the explicit Time Profiler option")
    let ink = app.otherElements["spatial-ink"]
    XCTAssertTrue(ink.waitForExistence(timeout: 10), app.debugDescription)
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
          let start = ink.coordinate(withNormalizedOffset: .init(dx: 0.12, dy: 0.34))
          start.press(forDuration: 0.06, thenDragTo: start.withOffset(.init(dx: 55, dy: 25)))
        } else {
          let start = ink.coordinate(withNormalizedOffset: .init(dx: 0.14, dy: 0.36))
          start.press(forDuration: 0.01, thenDragTo: start.withOffset(.init(dx: iteration.isMultiple(of: 2) ? 30 : -30, dy: 0)))
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

  private func panFreeBoard(by delta: CGVector, recordsEvidence: Bool = true) throws {
    // Leave the system's edge-gesture area outside the scene-pan route.
    // A narrow visual strip next to a widget is not a proven app touch area.
    let viewport = app.windows.firstMatch.frame.insetBy(dx: 44, dy: 44)
    // One immutable AX snapshot keeps transient keyboard children from
    // invalidating positional queries while their individual frames are read.
    let snapshot = try app.snapshot()
    func occupiedFrames(_ element: XCUIElementSnapshot) -> [CGRect] {
      let occupies = [.webView, .button, .textView, .textField, .keyboard]
        .contains(element.elementType) || element.identifier == "notebook-chat-panel"
      if occupies, element.frame.height > 1 { return [element.frame] }
      return element.children.flatMap(occupiedFrames)
    }
    let occupied = occupiedFrames(snapshot)
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

import UIKit
import XCTest

/// Exercises the paired application's real conversation and human controls.
/// Agent-reported addresses are evidence for a subsequent public-API audit;
/// the XCTest never treats prose as a storage or presentation receipt.
@MainActor final class NotebookCollaborationAcceptanceUITests: XCTestCase {
  private let app = XCUIApplication(bundleIdentifier: "com.amirtlinov.notebook.acceptance")
  private var systemTrace: NotebookSystemTraceHandshake?
  private var increment: XCUIElement { app.webViews.buttons["Acceptance increment"].firstMatch }
  private var input: XCUIElement { app.webViews.textFields["Acceptance text"].firstMatch }
  private var context: XCUIElement {
    app.descendants(matching: .any).matching(identifier: "notebook-context-count").firstMatch
  }
  private var transcript: XCUIElement {
    app.descendants(matching: .any).matching(identifier: "notebook-chat-transcript").firstMatch
  }
  private var catalogue: XCUIElement {
    app.descendants(matching: .any).matching(identifier: "notebook-chat-recents").firstMatch
  }
  private var taskRows: XCUIElementQuery {
    app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "notebook-chat-task-"))
  }

  private func launchControls() throws {
    continueAfterFailure = false
    executionTimeAllowance = 600
    app.launchEnvironment["NOTEBOOK_ACCEPTANCE_MANIFEST"] = try XCTUnwrap(
      ProcessInfo.processInfo.environment["NOTEBOOK_ACCEPTANCE_MANIFEST"])
    systemTrace = try NotebookSystemTraceHandshake.configured(environment: ProcessInfo.processInfo.environment)
    systemTrace?.configure(app)
    app.launch()
    try systemTrace?.began(app)
    if XCUIDevice.shared.orientation != .portrait { XCUIDevice.shared.orientation = .portrait }
    XCTAssertTrue(app.buttons["notebook-companion-compose"].waitForExistence(timeout: 20), app.debugDescription)
    XCTAssertFalse(app.otherElements["persistence-failure"].exists)
    let collapse = app.buttons["notebook-chat-toggle"]
    if collapse.exists { XCTAssertTrue(collapse.isHittable); collapse.tap()
      XCTAssertTrue(collapse.waitForNonExistence(timeout: 5)) }
    // Each independent scenario navigates through the real search owner; a
    // preceding document/camera test may have left the controls offscreen.
    let searchButton = app.buttons["notebook-search"]
    XCTAssertTrue(searchButton.isHittable); searchButton.tap()
    let search = app.searchFields.firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap()
    let sourceText = "Контрольные кнопка, ползунок и поле ввода"
    search.typeText(sourceText)
    let results = app.collectionViews.buttons.matching(NSPredicate(format: "label CONTAINS %@", sourceText))
    XCTAssertTrue(results.firstMatch.waitForExistence(timeout: 10)); XCTAssertEqual(results.count, 1)
    XCTAssertTrue(results.firstMatch.isHittable); results.firstMatch.tap()
    XCTAssertTrue(search.waitForNonExistence(timeout: 10))
    XCTAssertTrue(app.otherElements["page-turn-surface"].waitForNonExistence(timeout: 10),
      "Addressed search must finish leaving the preceding paper before the board gesture")
    XCTAssertTrue(increment.waitForExistence(timeout: 30)); XCTAssertTrue(increment.isHittable)
  }

  private func launch() throws {
    try launchControls()
    openChat()
    XCTAssertFalse(app.buttons["notebook-chat-stop"].exists,
      "An existing real agent turn must finish before starting this isolated scenario.")
    if context.exists {
      context.tap()
      let clear = app.buttons["notebook-context-clear"]
      XCTAssertTrue(clear.waitForExistence(timeout: 3)); clear.tap()
    }
    try createFreshChat()
    collapseChat()
    XCTAssertTrue(increment.waitForExistence(timeout: 30),
      "The public acceptance-controls material must be delivered and actually mounted.\n\(app.debugDescription)")
    XCTAssertTrue(increment.isHittable)
  }

  private func openChat() {
    if !app.buttons["notebook-chat-menu"].isHittable {
      let compose = app.buttons["notebook-companion-compose"]
      XCTAssertTrue(compose.waitForExistence(timeout: 5)); compose.tap()
    }
    XCTAssertTrue(app.buttons["notebook-chat-menu"].waitForExistence(timeout: 5))
  }

  private func collapseChat() {
    let collapse = app.buttons["notebook-chat-toggle"]
    XCTAssertTrue(collapse.isHittable); collapse.tap()
    XCTAssertTrue(collapse.waitForNonExistence(timeout: 5))
  }

  private func showCatalogue() {
    if !catalogue.exists {
      let tasks = app.buttons["notebook-chat-tasks"]
      XCTAssertTrue(tasks.isHittable); tasks.tap()
    }
    XCTAssertTrue(catalogue.waitForExistence(timeout: 5))
    let chats = app.segmentedControls["notebook-chat-browser-mode"].buttons["Чаты"]
    XCTAssertTrue(chats.exists)
    if !chats.isSelected { chats.tap() }
  }

  private func createFreshChat() throws {
    let conversationPrefix = "notebook-chat-conversation-"
    let conversations = app.descendants(matching: .any).matching(NSPredicate(
      format: "identifier BEGINSWITH %@", conversationPrefix))
    let previousConversationIDs = Set(conversations.allElementsBoundByIndex.map(\.identifier))
    showCatalogue()
    let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
      taskRows.count > 0 || app.descendants(matching: .any)["notebook-project-empty-chats"].exists
    }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 30), .completed,
      "Read the actual Codex catalogue before requesting a new conversation.")
    let previous = Set(taskRows.allElementsBoundByIndex.map(\.identifier))
    let pending = app.descendants(matching: .any).matching(NSPredicate(
      format: "identifier BEGINSWITH %@", "notebook-chat-creation-"))
    XCTAssertEqual(pending.count, 0, "An earlier creation must finish before this scenario starts.")
    let newChat = app.buttons["notebook-chat-new"]
    XCTAssertTrue(newChat.isHittable); XCTAssertTrue(newChat.isEnabled); newChat.tap()

    // The creation receipt opens its exact task. Codex's history catalogue
    // need not include a task before its first user turn. Reopening that list
    // here would navigate away from the successful creation we are observing.
    let opened = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
      !catalogue.exists && conversations.allElementsBoundByIndex.contains {
        !previousConversationIDs.contains($0.identifier) &&
        UUID(uuidString: String($0.identifier.dropFirst(conversationPrefix.count))) != nil
      }
    }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 60), .completed,
      "A real creation receipt must open a new, addressable conversation.")
    let identifiers = Set(conversations.allElementsBoundByIndex.map(\.identifier))
    XCTAssertEqual(identifiers.count, 1)
    let identifier = try XCTUnwrap(identifiers.first)
    let threadID = String(identifier.dropFirst(conversationPrefix.count))
    XCTAssertNotNil(UUID(uuidString: threadID))
    XCTAssertFalse(previousConversationIDs.contains(identifier))
    XCTAssertFalse(previous.contains("notebook-chat-task-" + threadID))
    XCTAssertTrue(catalogue.waitForNonExistence(timeout: 5))
    XCTAssertTrue(transcript.waitForExistence(timeout: 30), app.debugDescription)
    XCTAssertFalse(app.buttons["notebook-chat-stop"].exists)
    let empty = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
      transcript.exists && transcript.descendants(matching: .staticText).count == 0
    }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [empty], timeout: 30), .completed,
      "A fresh conversation must not inherit another conversation's displayed messages.")
    try attach(["previousCatalogueTaskIdentifiers": previous.sorted(),
      "previousConversationIdentifiers": previousConversationIDs.sorted(),
      "selectedNewConversationIdentifier": identifier, "threadID": threadID],
      name: "actual-new-codex-conversation-selection")
    screenshot("collaboration-new-conversation-before-selection")
  }

  private func screenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
  }

  private func attach(_ value: Any, name: String) throws {
    let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: value,
      options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
    attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
  }

  /// Streaming text can replace AX children between indexed element reads.
  /// Traverse one immutable observation instead of querying each stale index.
  private func staticTextLabels(in element: XCUIElement) throws -> [String] {
    func labels(_ node: XCUIElementSnapshot) -> [String] {
      (node.elementType == .staticText ? [node.label] : []) + node.children.flatMap(labels)
    }
    return labels(try element.snapshot())
  }

  /// Exercise the ordinary request UI for the two tools explicitly authorized
  /// by this isolated scenario. Never grant file, shell, network or global access.
  @discardableResult
  private func approveNotebookAccessIfRequested() throws -> Bool {
    let request = app.descendants(matching: .any).matching(identifier: "notebook-codex-request").firstMatch
    guard request.exists else { return false }
    XCTAssertTrue(request.staticTexts["Доступ к notebook"].exists,
      "Unexpected permission request must be inspected separately: \(request.debugDescription)")
    let details = request.buttons["Подробности запроса"]
    if details.exists { XCTAssertTrue(details.isHittable); details.tap() }
    let description = request.debugDescription
    screenshot("collaboration-notebook-access-request-details")
    let evidence = XCTAttachment(string: description)
    evidence.name = "actual-notebook-access-request"; evidence.lifetime = .keepAlways; add(evidence)
    let offered = try XCTUnwrap(staticTextLabels(in: request).compactMap { label -> (String, [String: Any])? in
      guard let data = label.data(using: .utf8) else { return nil }
      guard let parameters = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
      return (label, parameters)
    }.first(where: { $0.1["serverName"] != nil }), "The actual request details must expose its structured parameters")
    let parameters = offered.1
    let metadata = try XCTUnwrap(parameters["_meta"] as? [String: Any])
    XCTAssertEqual(parameters["serverName"] as? String, "notebook")
    XCTAssertEqual(parameters["mode"] as? String, "form")
    XCTAssertEqual(metadata["codex_approval_kind"] as? String, "mcp_tool_call")
    let expectedMessages = ["notebook_execute", "notebook_context"].map {
      "Allow the notebook MCP server to run tool \"\($0)\"?"
    }
    XCTAssertTrue(expectedMessages.contains(parameters["message"] as? String ?? ""),
      "Only an exact public Notebook tool request is authorized; mentions inside code or prose are insufficient")
    let threadID = try XCTUnwrap(parameters["threadId"] as? String)
    XCTAssertTrue(app.descendants(matching: .any).matching(identifier:
      "notebook-chat-conversation-" + threadID).firstMatch.exists,
      "The decision must belong to the currently displayed test conversation")
    let remember = request.buttons["notebook-approval-remember"]
    XCTAssertTrue(remember.isHittable); remember.tap()
    let session = app.buttons["Разрешить на весь чат"]
    XCTAssertTrue(session.waitForExistence(timeout: 3)); XCTAssertTrue(session.isHittable); session.tap()
    let originalDetails = request.staticTexts.matching(NSPredicate(format: "label == %@", offered.0)).firstMatch
    XCTAssertTrue(originalDetails.waitForNonExistence(timeout: 10),
      "Codex must retire this exact request; a following request is handled separately")
    return true
  }

  func testApproveAuthorizedNotebookAccessInExistingConversation() throws {
    continueAfterFailure = false
    XCTAssertEqual(app.state, .runningForeground)
    XCTAssertTrue(app.buttons["notebook-chat-stop"].exists)
    XCTAssertTrue(try approveNotebookAccessIfRequested())
    screenshot("collaboration-notebook-session-access-accepted")
  }

  func testObserveExistingConversationAfterAuthorizedAccess() throws {
    continueAfterFailure = false
    app.launchEnvironment["NOTEBOOK_ACCEPTANCE_MANIFEST"] = try XCTUnwrap(
      ProcessInfo.processInfo.environment["NOTEBOOK_ACCEPTANCE_MANIFEST"])
    app.activate()
    XCTAssertTrue(app.buttons["notebook-companion-compose"].waitForExistence(timeout: 20)
      || app.buttons["notebook-chat-menu"].exists)
    openChat()
    XCTAssertTrue(app.buttons["notebook-chat-menu"].waitForExistence(timeout: 10))
    let completed = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
      do { if try approveNotebookAccessIfRequested() { return false } }
      catch { XCTFail("Cannot complete authorized access: \(error)"); return true }
      return !app.buttons["notebook-chat-stop"].exists
    }, object: nil)
    let result = XCTWaiter.wait(for: [completed], timeout: 180)
    screenshot("collaboration-existing-conversation-after-access")
    let state = XCTAttachment(string: app.debugDescription)
    state.name = "actual-existing-conversation-after-access"; state.lifetime = .keepAlways; add(state)
    XCTAssertEqual(result, .completed)
  }

  func testCancelExistingConversationPreservesAcceptedHumanState() throws {
    continueAfterFailure = false
    app.activate()
    XCTAssertTrue(input.waitForExistence(timeout: 10))
    let beforeCount = try count(), beforeText = try XCTUnwrap(input.value as? String)
    let hide = app.keyboards.buttons["Hide keyboard"]
    if hide.exists { XCTAssertTrue(hide.isHittable); hide.tap() }
    openChat()
    let stop = app.buttons["notebook-chat-stop"]
    XCTAssertTrue(stop.waitForExistence(timeout: 10), "Only a currently running real turn can be cancelled")
    screenshot("collaboration-existing-running-turn-before-cancel")
    XCTAssertTrue(stop.isHittable); stop.tap()
    XCTAssertTrue(stop.waitForNonExistence(timeout: 30))
    screenshot("collaboration-existing-turn-after-real-cancel")
    let transcriptState = XCTAttachment(string: app.debugDescription)
    transcriptState.name = "cancelled-conversation-actual-transcript"; transcriptState.lifetime = .keepAlways; add(transcriptState)
    collapseChat()
    XCTAssertEqual(try count(), beforeCount); XCTAssertEqual(input.value as? String, beforeText)
    try attach(["actualHumanCount": beforeCount, "actualHumanText": beforeText],
      name: "cancel-preserved-human-state-for-public-audit")
  }

  private func count() throws -> Int {
    let prefix = "Acceptance count: "
    let labels = app.webViews.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix))
      .allElementsBoundByIndex.map(\.label)
    let counts = labels.compactMap { Int($0.dropFirst(prefix.count)) }
    XCTAssertEqual(counts.count, 1, "The actual visible fixture must have exactly one counter: \(labels)")
    return try XCTUnwrap(counts.first)
  }

  /// Start outside the live WebKit, so the long hold belongs to board selection,
  /// then include the actual button and count. Coordinates come from current AX
  /// geometry, not saved camera/DOM coordinates or a model-injected selection.
  private func selectCounterRegion() throws {
    let web = app.webViews.containing(.button, identifier: "Acceptance increment").firstMatch
    XCTAssertTrue(web.exists)
    let value = app.webViews.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Acceptance count: "))
      .firstMatch
    let content = increment.frame.union(value.frame)
    let screen = app.frame.insetBy(dx: 8, dy: 8)
    let left = CGPoint(x: web.frame.minX - 14, y: content.minY - 14)
    let right = CGPoint(x: web.frame.maxX + 14, y: content.minY - 14)
    let from: CGPoint, to: CGPoint
    if screen.contains(left) {
      from = left; to = CGPoint(x: min(screen.maxX, content.maxX + 10), y: content.maxY + 10)
    } else {
      XCTAssertTrue(screen.contains(right), "No empty visible board edge beside the public widget; frame=\(web.frame)")
      from = right; to = CGPoint(x: max(screen.minX, content.minX - 10), y: content.maxY + 10)
    }
    XCTAssertTrue(screen.contains(to)); XCTAssertFalse(web.frame.contains(from))
    let origin = app.coordinate(withNormalizedOffset: .zero)
    origin.withOffset(CGVector(dx: from.x - app.frame.minX, dy: from.y - app.frame.minY))
      .press(forDuration: 0.55, thenDragTo: origin.withOffset(
        CGVector(dx: to.x - app.frame.minX, dy: to.y - app.frame.minY)))
    XCTAssertTrue(context.waitForExistence(timeout: 5), "The real hold must create human context.")
    XCTAssertGreaterThan(Int(context.value as? String ?? "") ?? 0, 0)
    try attach(["start": ["x": from.x, "y": from.y], "end": ["x": to.x, "y": to.y],
      "contextCount": context.value as? String ?? ""], name: "actual-human-selection-gesture")
    screenshot("collaboration-human-region-before-send")
  }

  private func send(_ message: String) throws {
    openChat()
    let composer = app.descendants(matching: .any).matching(identifier: "notebook-chat-text").firstMatch
    XCTAssertTrue(composer.waitForExistence(timeout: 5)); composer.tap()
    let existing = composer.value as? String ?? ""
    if !existing.isEmpty, existing != "Сообщение Codex" {
      XCTAssertTrue(["Помоги разобраться с выделенным фрагментом.", "Совместная проверка конфликта ",
        "Это проверка изолированного пространства Notebook.", "Продолжи тот же материал проверки ",
        "Это проверка отмены того же материала "].contains { existing.hasPrefix($0) },
        "Only an earlier acceptance scenario's unsent draft may be replaced.")
      screenshot("collaboration-earlier-acceptance-draft-before-replacement")
      composer.typeKey("a", modifierFlags: .command)
      composer.typeText(XCUIKeyboardKey.delete.rawValue)
    }
    composer.typeText(message)
    XCTAssertEqual(composer.value as? String, message, "Send must submit this exact request once, without an older draft.")
    let send = app.buttons["notebook-chat-send"]
    XCTAssertTrue(send.isHittable); XCTAssertTrue(send.isEnabled); send.tap()
    XCTAssertTrue(app.buttons["notebook-chat-stop"].waitForExistence(timeout: 30),
      "A saved outgoing message or a locally prepared answer is not a running Codex turn.")
    screenshot("collaboration-real-codex-running")
    try attach(["message": message], name: "actual-sent-collaboration-request")
  }

  /// The prompt describes field names but never contains a completed packet.
  /// UUIDs/hashes must come from actual API results, and each packet is scoped
  /// to this fresh conversation. This is an observation, not proof of a write.
  private func packet(test: String, phase: String, timeout: TimeInterval = 300) throws -> [String: Any] {
    let expression = try NSRegularExpression(pattern: #"\{[^{}]{1,16384}\}"#)
    var found: [String: Any]?
    let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
      let labels: [String]
      do {
        if try approveNotebookAccessIfRequested() { return false }
        labels = try staticTextLabels(in: transcript)
      } catch { XCTFail("Cannot observe the real conversation/access request: \(error)"); return true }
      for label in labels.suffix(128)
        where label.contains(test) && label.contains(phase) {
        let range = NSRange(label.startIndex..<label.endIndex, in: label)
        for match in expression.matches(in: label, range: range) {
          guard let slice = Range(match.range, in: label), let bytes = String(label[slice]).data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
            object["test"] as? String == test, object["phase"] as? String == phase else { continue }
          found = object; return true
        }
      }
      return false
    }, object: nil)
    let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
    screenshot("collaboration-\(phase)-agent-response")
    XCTAssertEqual(result, .completed,
      "No real response packet. Inspect the transcript/tool failures; never substitute a canned reply.\n\(app.debugDescription)")
    let value = try XCTUnwrap(found)
    try attach(value, name: "agent-reported-\(phase)-public-addresses-unverified")
    XCTAssertTrue(app.buttons["notebook-chat-stop"].waitForNonExistence(timeout: 30))
    return value
  }

  private func string(_ packet: [String: Any], _ key: String) throws -> String {
    let value = try XCTUnwrap(packet[key] as? String, key)
    XCTAssertFalse(value.isEmpty, key); return value
  }

  @discardableResult private func uuid(_ packet: [String: Any], _ key: String) throws -> UUID {
    try XCTUnwrap(UUID(uuidString: try string(packet, key)), key)
  }

  private func tapIncrement(from before: Int) throws {
    XCTAssertTrue(increment.isHittable); increment.tap()
    XCTAssertTrue(app.webViews.staticTexts["Acceptance count: \(before + 1)"].firstMatch
      .waitForExistence(timeout: 3), "One actual tap must update the control exactly once.")
    XCTAssertEqual(try count(), before + 1)
  }

  private func replaceInputThroughSelectionMenu(_ text: String) throws {
    XCTAssertTrue(input.isHittable); input.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    // WebKit's AX element press may choose its top-left +5pt hit point,
    // which lies in this padded input's border. Press the visible text line.
    let fieldFrame = input.frame
    let textPoint = input.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.55))
    try attach(["fieldFrame": ["x": fieldFrame.minX, "y": fieldFrame.minY,
      "width": fieldFrame.width, "height": fieldFrame.height],
      "requestedContact": ["x": textPoint.screenPoint.x, "y": textPoint.screenPoint.y]],
      name: "native-selection-visible-text-contact")
    textPoint.press(forDuration: 1.1)
    screenshot("collaboration-native-insertion-point-after-press")
    // Holding on iPad places the insertion point. A tap on that actual caret
    // asks the native editor to show its editing commands.
    textPoint.tap()
    screenshot("collaboration-native-text-selection-menu")
    let menu = app.descendants(matching: .any).matching(NSPredicate(
      format: "(elementType == %d OR elementType == %d) AND label IN %@",
      XCUIElement.ElementType.button.rawValue, XCUIElement.ElementType.menuItem.rawValue,
      ["Select All", "Выбрать все", "Выбрать всё", "Выделить все", "Выделить всё"]))
    XCTAssertTrue(menu.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
    let choices = menu.allElementsBoundByIndex.filter(\.isHittable)
    XCTAssertEqual(choices.count, 1, app.debugDescription)
    try XCTUnwrap(choices.first).tap()
    screenshot("collaboration-native-text-selected-before-replacement")
    input.typeText(text)
    let immediate = input.value as? String
    screenshot("collaboration-native-text-immediately-after-typing")
    let accepted = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
      input.value as? String == text
    }, object: nil)
    let completion = XCTWaiter.wait(for: [accepted], timeout: 3)
    try attach(["immediateAXValue": immediate ?? "", "expectedText": text,
      "subsequentAXValue": input.value as? String ?? "",
      "measurement": "XCTest accessibility observations; not a control latency measurement"],
      name: "actual-keyboard-value-before-and-after-webkit-publication")
    XCTAssertEqual(completion, .completed, "The complete keyboard value must reach the real text field")
    XCTAssertEqual(input.value as? String, text)
  }

  func testWidgetTextReplacementUsesNativeSelectionMenu() throws {
    try launchControls()
    let before = try count()
    let previousText = try XCTUnwrap(input.value as? String)
    XCTAssertFalse(previousText.isEmpty, "The native selection must replace existing content.")
    let replacement = "Native selection \(UUID().uuidString.lowercased())"
    screenshot("widget-native-text-before-selection")
    try replaceInputThroughSelectionMenu(replacement)
    XCTAssertEqual(try count(), before)
    screenshot("widget-native-text-replacement-visible")
    try tapIncrement(from: before)
    XCTAssertEqual(input.value as? String, replacement)
    try attach(["previousText": previousText, "replacementText": replacement,
      "beforeCount": before, "actualCountAfterOneTap": try count()],
      name: "actual-native-selection-and-first-touch")
    try systemTrace?.ended(app)
  }

  /// Continue the exact failed keyboard boundary without creating a new turn,
  /// reapplying the agent effect or manufacturing a conflict receipt.
  func testCompletePendingHumanEditThroughNativeSelectionMenu() throws {
    continueAfterFailure = false
    app.activate()
    XCTAssertTrue(input.waitForExistence(timeout: 10))
    let previous = try XCTUnwrap(input.value as? String)
    let pattern = #"^Human edit ([0-9a-f-]{36})Agent ready \1$"#
    let regex = try NSRegularExpression(pattern: pattern)
    let match = try XCTUnwrap(regex.firstMatch(in: previous,
      range: NSRange(previous.startIndex..<previous.endIndex, in: previous)))
    let range = try XCTUnwrap(Range(match.range(at: 1), in: previous))
    let nonce = String(previous[range]); _ = try XCTUnwrap(UUID(uuidString: nonce))
    let humanCount = try count(), humanText = "Human edit \(nonce)"
    try replaceInputThroughSelectionMenu(humanText)
    XCTAssertEqual(try count(), humanCount)
    screenshot("collaboration-recovered-human-text-actually-visible")
    openChat()
    let receipt = try packet(test: nonce, phase: "conflict_undone", timeout: 240)
    XCTAssertEqual(try string(receipt, "casErrorCode"), "revision_conflict")
    XCTAssertEqual(try uuid(receipt, "effectActionID"), try uuid(receipt, "undoReceiptID"))
    XCTAssertEqual(receipt["humanCount"] as? Int, humanCount)
    XCTAssertEqual(receipt["afterUndoCount"] as? Int, humanCount)
    XCTAssertEqual(receipt["afterUndoText"] as? String, humanText)
    collapseChat()
    XCTAssertEqual(try count(), humanCount); XCTAssertEqual(input.value as? String, humanText)
    try attach(["test": nonce, "actualHumanCount": humanCount, "actualHumanText": humanText,
      "agentReportedPublicAddresses": receipt], name: "ui-recovered-conflict-for-independent-public-audit")
  }

  func testCreatedMaterialRetainsHumanEditsThroughAgentUndoAndCancellation() throws {
    try launch()
    let nonce = UUID().uuidString.lowercased()
    let title = "Collaboration \(nonce)"
    let button = "Collaboration increment \(nonce)"
    let output = "Collaboration count \(nonce): "
    let svg = Data("<svg xmlns='http://www.w3.org/2000/svg' width='160' height='48'><path d='M4 40L80 4L156 40' fill='none' stroke='#173d69'/><text x='12' y='32'>Joint Figure</text></svg>".utf8).base64EncodedString()
    let before = try count()
    try selectCounterRegion()
    try send("""
      Помоги разобраться с выделенным фрагментом. Это настоящая совместная проверка \(nonce).
      Работай только через notebook_context и notebook_execute; точные методы узнай через nb.help.
      Прочитай внимание именно отправленного сообщения через nb.attention, получи source_pixels,
      вызови emitImage с его artifact и самостоятельно прочитай Acceptance count на этих пикселях.
      Я сейчас нажму кнопку исходного acceptance-controls. Не меняй его. Дождись через ограниченные
      публичные чтения его нового count, отличного от значения в отправленном изображении; не проси
      подтверждения и не делай сетевых/файловых вызовов. Повторно прочитай то же внимание: SHA должен
      остаться прежним. В текущей доске создай одной транзакцией документ «\(title)»: короткое объяснение
      увиденного и интерактивный блок на первой странице, исходный count 0, настоящая кнопка с aria-label
      «\(button)», output «\(output)0». Кнопка прибавляет 1, notebook.commit сохраняет состояние,
      notebookstate его восстанавливает, notebook.ready объявляет готовность. Прочитай сохранённый документ.
      Первый markdown-блок должен иметь id joint-reading, заголовок «Joint route \(nonce)»,
      короткое объяснение, формулу x^2+1 с обычными MathJax delimiters, внутреннюю ссылку
      <a href='#joint-reading'>Joint reading</a> и <img width='160' height='48'
      src='data:image/svg+xml;base64,\(svg)'>. Поставь id joint-reading также на его HTML-заголовке.
      Не заменяй формулу картинкой. Весь первый блок и кнопка должны помещаться на первой странице.
      Не двигай мою камеру. В финале дай один плоский JSON без вложенных объектов: test=\(nonce),
      phase=attention_created, contextID, referenceID, artifactSHA256, artifactSHA256After, boardID,
      documentID, programID, creationActionID, creationRunID, attentionRunID, beforeRevision, afterRevision,
      sentCount (число с исходных
      пикселей), currentCount (новое публичное значение). IDs/версии/SHA возьми из настоящих результатов.
      RunID — действительный run_id вызова notebook_execute с соответствующим действием или изображением.
      Версии относятся к boardID: beforeRevision из expected создания, afterRevision из его сохранённой
      квитанции. Выведи через emit фактическую квитанцию создания и прочитанные значения; они нужны
      для независимой проверки по журналу публичного запуска.
      Если изображения или операции недоступны, опиши реальную ошибку, не придумывай успешный пакет.
      """)
    collapseChat()
    try tapIncrement(from: before)
    screenshot("collaboration-human-control-changed-after-send")
    openChat()
    let receipt = try packet(test: nonce, phase: "attention_created")
    for key in ["contextID", "referenceID", "boardID", "documentID", "creationActionID", "creationRunID", "attentionRunID"] {
      try uuid(receipt, key)
    }
    _ = try string(receipt, "programID")
    let sha = try string(receipt, "artifactSHA256")
    XCTAssertNotNil(sha.range(of: #"^[0-9a-fA-F]{64}$"#, options: .regularExpression))
    XCTAssertEqual(try string(receipt, "artifactSHA256After").lowercased(), sha.lowercased())
    XCTAssertEqual(receipt["sentCount"] as? Int, before)
    XCTAssertEqual(receipt["currentCount"] as? Int, before + 1)
    XCTAssertNotEqual(try string(receipt, "beforeRevision"), try string(receipt, "afterRevision"))
    collapseChat()
    XCTAssertEqual(try count(), before + 1)
    try useCreatedDocument(receipt: receipt, nonce: nonce, before: before)
    try systemTrace?.ended(app)
  }

  private func useCreatedDocument(receipt: [String: Any], nonce: String, before: Int) throws {
    try inspectCreatedDocument(receipt: receipt, nonce: nonce, before: before)
    let humanMarker = try editAndExportCreatedDocument(receipt: receipt, nonce: nonce)
    try continueCreatedMaterial(receipt: receipt, nonce: nonce)
    XCTAssertTrue(app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", humanMarker)).firstMatch.exists,
      "Agent continuation and undo must preserve the human source edit in the same installed document")
  }

  /// Close the previously separate Save/export boundary inside the real
  /// agent/human conversation. Agent prose only supplies addresses for the
  /// independent public export audit; it is not accepted as a file receipt.
  private func editAndExportCreatedDocument(receipt: [String: Any], nonce: String) throws -> String {
    let heading = app.webViews.staticTexts["Joint route \(nonce)"].firstMatch
    XCTAssertTrue(heading.isHittable); heading.doubleTap()
    let editor = app.textViews["Исходный Markdown или LaTeX"].firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
    let keyboard = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
      app.keyboards.firstMatch.exists && app.keyboards.firstMatch.frame.height > 100
    }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [keyboard], timeout: 3), .completed)
    let original = try XCTUnwrap(editor.value as? String)
    let marker = "Human source \(nonce)"
    // A centre tap can put the caret inside the SVG's data URI. Move through
    // the ordinary keyboard command and prove the original source survives.
    editor.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: .command)
    editor.typeText("\n\n" + marker)
    let entered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      editor.value as? String == original + "\n\n" + marker
    }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [entered], timeout: 3), .completed)
    screenshot("joint-route-human-source-before-save")
    let save = app.webViews.buttons["Сохранить"].firstMatch
    XCTAssertTrue(save.isHittable); save.tap()
    XCTAssertTrue(editor.waitForNonExistence(timeout: 10))
    let installedText = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch
    XCTAssertTrue(installedText.waitForExistence(timeout: 15),
      "Save ends only when the saved source is installed, not when the editor disappears")
    XCTAssertTrue(installedText.isHittable)
    screenshot("joint-route-saved-human-source-actually-installed")
    let documentID = try uuid(receipt, "documentID").uuidString
    try send("""
      Продолжим тот же маршрут \(nonce), документ \(documentID). Я отредактировал первый блок
      через настоящий редактор и Save: в joint-reading теперь есть «\(marker)».
      Через notebook_context/notebook_execute прочитай именно сохранённый документ, убедись в маркере,
      прежней формуле, SVG data URI, ссылке и count=1 интерактивного блока. Ничего не изменяй.
      Создай один nb.export для этой сохранённой версии. Дождись nb.exportStatus с готовым файлом,
      не повторяя запрос экспорта. Emit полные фактические ответы document, export и exportStatus.
      Ответь одним плоским JSON: test=\(nonce), phase=human_saved_exported, documentID,
      jobID, exportRunID, contentRevision, stateRevision, markerPresent (boolean),
      formulaPresent (boolean), svgPresent (boolean), linkPresent (boolean), actualCount (1).
      Адреса и версии возьми из реальных ответов, не из этого сообщения. Ошибка не заменяется пакетом PASS.
      """)
    try readSavedExport(receipt: receipt, nonce: nonce)
    return marker
  }

  private func readSavedExport(receipt: [String: Any], nonce: String) throws {
    let documentID = try uuid(receipt, "documentID").uuidString
    let marker = "Human source \(nonce)"
    let export = try packet(test: nonce, phase: "human_saved_exported", timeout: 240)
    XCTAssertEqual(try uuid(export, "documentID"), try uuid(receipt, "documentID"))
    for key in ["jobID", "exportRunID"] { try uuid(export, key) }
    for key in ["contentRevision", "stateRevision"] { _ = try string(export, key) }
    for key in ["markerPresent", "formulaPresent", "svgPresent", "linkPresent"] {
      XCTAssertEqual(export[key] as? Bool, true)
    }
    XCTAssertEqual(export["actualCount"] as? Int, 1)
    try attach(["test": nonce, "documentID": documentID, "blockID": "joint-reading", "marker": marker,
      "agentReportedExportAddresses": export], name: "joint-route-save-export-addresses-for-independent-public-audit")
    collapseChat()
    XCTAssertTrue(app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch.exists)
  }

  /// Continue the same completed creation through its remaining human/agent
  /// transitions. The earlier interrupted attempt retains its own failure.
  func testUseCreatedDocumentFromTheExistingRealConversation() throws {
    continueAfterFailure = false
    executionTimeAllowance = 600
    app.launchEnvironment["NOTEBOOK_ACCEPTANCE_MANIFEST"] = try XCTUnwrap(
      ProcessInfo.processInfo.environment["NOTEBOOK_ACCEPTANCE_MANIFEST"])
    app.launch()
    XCTAssertTrue(app.buttons["notebook-companion-compose"].waitForExistence(timeout: 20)
      || app.buttons["notebook-chat-menu"].exists)
    openChat()
    XCTAssertFalse(app.buttons["notebook-chat-stop"].exists)
    let receipt = try currentCreationReceipt()
    let nonce = try string(receipt, "test"), before = try XCTUnwrap(receipt["sentCount"] as? Int)
    collapseChat()
    // The earlier board observation belongs to the original scenario, not to
    // an offscreen control in the currently restored document.
    try useCreatedDocument(receipt: receipt, nonce: nonce, before: before)
  }

  /// The Save and outgoing export request already happened before an observer
  /// failed. Read that same real turn; never press Save/Send/export a second time.
  func testContinueSavedDocumentFromTheExistingRealConversation() throws {
    continueAfterFailure = false; executionTimeAllowance = 600
    app.activate(); openChat()
    let receipt = try currentCreationReceipt(), nonce = try string(receipt, "test")
    try readSavedExport(receipt: receipt, nonce: nonce)
    if app.webViews.staticTexts["Collaboration count \(nonce): 102"].firstMatch.exists {
      // A host timeout may leave the real human edit and agent undo complete.
      // Validate that same response instead of resending the +100 request.
      openChat()
      try readCreatedConflictAndCancel(receipt: receipt, nonce: nonce)
    } else {
      try continueCreatedMaterial(receipt: receipt, nonce: nonce)
    }
    XCTAssertTrue(app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Human source \(nonce)")).firstMatch.exists)
  }

  private func currentCreationReceipt() throws -> [String: Any] {
    var packets: [[String: Any]] = []
    let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
      let labels: [String]
      do { labels = try staticTextLabels(in: transcript) }
      catch { XCTFail("Cannot observe the existing creation response: \(error)"); return true }
      packets = labels.compactMap { label -> [String: Any]? in
      guard let data = label.data(using: .utf8),
        let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
        value["phase"] as? String == "attention_created" else { return nil }
      return value
    }
      return !packets.isEmpty
    }, object: nil)
    let loadResult = XCTWaiter.wait(for: [loaded], timeout: 30)
    screenshot("collaboration-existing-creation-response-before-opening")
    let state = XCTAttachment(string: app.debugDescription)
    state.name = "actual-existing-creation-response"; state.lifetime = .keepAlways; add(state)
    XCTAssertEqual(loadResult, .completed, "The real transcript must load before interpreting a completed response")
    XCTAssertEqual(packets.count, 1, "Read exactly one actual creation response from the current conversation")
    let receipt = try XCTUnwrap(packets.first)
    let nonce = try string(receipt, "test")
    XCTAssertNotNil(UUID(uuidString: nonce))
    let before = try XCTUnwrap(receipt["sentCount"] as? Int)
    XCTAssertEqual(receipt["currentCount"] as? Int, before + 1)
    try attach(receipt, name: "completed-real-turn-public-addresses-unverified")
    return receipt
  }

  private func inspectCreatedDocument(receipt: [String: Any], nonce: String, before: Int) throws {
    let title = "Collaboration \(nonce)"
    let button = "Collaboration increment \(nonce)"
    let output = "Collaboration count \(nonce): "
    app.buttons["notebook-search"].tap()
    let search = app.searchFields.firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText(title)
    let results = app.collectionViews.buttons.matching(NSPredicate(format: "label CONTAINS %@", title))
    let result = results.firstMatch
    XCTAssertTrue(result.waitForExistence(timeout: 15)); XCTAssertEqual(results.count, 1)
    let searchRow = XCTAttachment(string: result.debugDescription)
    searchRow.name = "created-document-search-row-before-first-touch"; searchRow.lifetime = .keepAlways; add(searchRow)
    XCTAssertTrue(result.isHittable)
    result.tap()
    XCTAssertTrue(search.waitForNonExistence(timeout: 5), "One result tap must close search and navigate")
    // A title search locates its cover; the ordinary double tap opens the
    // document. The agent-reported ID only addresses this subsequent UI check.
    let cover = app.buttons["workspace-item-" + (try uuid(receipt, "documentID")).uuidString.lowercased()]
    XCTAssertTrue(cover.waitForExistence(timeout: 10)); XCTAssertTrue(cover.isHittable); cover.doubleTap()
    XCTAssertTrue(app.otherElements["page-turn-surface"].waitForExistence(timeout: 10))
    let createdButton = app.webViews.buttons[button].firstMatch
    XCTAssertTrue(createdButton.waitForExistence(timeout: 30)); XCTAssertTrue(createdButton.isHittable)
    XCTAssertTrue(app.webViews.staticTexts[output + "0"].firstMatch.exists)
    screenshot("collaboration-created-document-before-first-touch")
    createdButton.tap()
    XCTAssertTrue(app.webViews.staticTexts[output + "1"].firstMatch.waitForExistence(timeout: 3))
    XCTAssertFalse(app.webViews.staticTexts[output + "2"].firstMatch.exists)
    screenshot("collaboration-created-document-first-touch-result")
    try attach(["test": nonce, "recordedBeforeSendCount": before, "recordedAfterSendCount": before + 1,
      "actualCreatedProgramCount": 1, "agentReportedPublicAddresses": receipt],
      name: "ui-observations-for-independent-public-receipt-audit")
  }

  /// Continue the same document and conversation. No new fixture, direct
  /// model mutation or second data writer can substitute for this transition.
  private func continueCreatedMaterial(receipt: [String: Any], nonce: String) throws {
    let documentID = try uuid(receipt, "documentID").uuidString
    let programID = try string(receipt, "programID")
    let output = "Collaboration count \(nonce): "
    let createdButton = app.webViews.buttons["Collaboration increment \(nonce)"].firstMatch
    XCTAssertTrue(app.webViews.staticTexts[output + "1"].firstMatch.exists)
    try send("""
      Продолжи тот же материал проверки \(nonce), документ \(documentID), блок \(programID), в этом же чате.
      Работай только через notebook_context/notebook_execute. Я уже нажал созданную тобой кнопку один раз.
      Прочитай реальное состояние: count должен быть 1. Если он другой — остановись с настоящей ошибкой.
      Сохраняя остальные поля, одной nb.transaction/setBlockState прибавь 100: получится 101.
      expected содержит contentRevision И stateRevision из nb.document. Сохрани actionID и точные
      revisions из квитанции этого эффекта, не из последующего чтения. Emit полную квитанцию и state.
      Не меняй исходник, разметку, камеру или другие владельцы. Я увижу 101 и нажму ту же кнопку ещё раз.
      Жди actual count 102 ограниченными публичными чтениями; один JS run не дольше 30 секунд,
      продолжения без повторения эффекта. После моей правки намеренно попробуй setBlockState с
      ожиданиями именно твоей сохранённой версии 101. Ожидается revision_conflict; не обновляй expected
      и не повторяй запись. Если запись принята — остановись и сообщи реальную ошибку.
      Emit фактическую ошибку. Отмени только свой эффект +100 через nb.undo, прочитай итог:
      человеческая версия 102 должна сохраниться. Создание документа не отменяй.
      В финале один плоский JSON: test=\(nonce), phase=created_conflict_undone, documentID,
      programID, effectActionID, effectRunID, casRunID, undoRunID, undoReceiptID,
      observedHumanCount (1), agentCount (101), humanCount, afterUndoCount, casErrorCode,
      undoPreservedCount (из receipt.undo.preservedCount). RunID и все квитанции только из реальных
      ответов; emit полные ответы эффекта, отказа и undo для независимого публичного аудита.
      """)
    let ready = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
      do { if try approveNotebookAccessIfRequested() { return false } }
      catch { XCTFail("Cannot complete Notebook access: \(error)"); return true }
      return app.webViews.staticTexts[output + "101"].firstMatch.exists && app.buttons["notebook-chat-stop"].exists
    }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 240), .completed,
      "The agent must continue the user's saved 1, not recreate its initial 0")
    collapseChat(); XCTAssertTrue(createdButton.isHittable); createdButton.tap()
    XCTAssertTrue(app.webViews.staticTexts[output + "102"].firstMatch.waitForExistence(timeout: 3))
    screenshot("same-created-material-human-second-edit")
    openChat()
    try readCreatedConflictAndCancel(receipt: receipt, nonce: nonce)
  }

  private func readCreatedConflictAndCancel(receipt: [String: Any], nonce: String) throws {
    let documentID = try uuid(receipt, "documentID").uuidString
    let programID = try string(receipt, "programID")
    let output = "Collaboration count \(nonce): "
    let conflict = try packet(test: nonce, phase: "created_conflict_undone", timeout: 240)
    XCTAssertEqual(try uuid(conflict, "documentID"), try uuid(receipt, "documentID"))
    XCTAssertEqual(try string(conflict, "programID"), programID)
    for key in ["effectActionID", "effectRunID", "casRunID", "undoRunID", "undoReceiptID"] { try uuid(conflict, key) }
    XCTAssertEqual(try uuid(conflict, "effectActionID"), try uuid(conflict, "undoReceiptID"))
    XCTAssertEqual(conflict["observedHumanCount"] as? Int, 1)
    XCTAssertEqual(conflict["agentCount"] as? Int, 101)
    XCTAssertEqual(conflict["humanCount"] as? Int, 102)
    XCTAssertEqual(conflict["afterUndoCount"] as? Int, 102)
    XCTAssertEqual(try string(conflict, "casErrorCode"), "revision_conflict")
    XCTAssertGreaterThan(try XCTUnwrap(conflict["undoPreservedCount"] as? Int), 0)
    collapseChat()
    XCTAssertTrue(app.webViews.staticTexts[output + "102"].firstMatch.exists)
    screenshot("same-created-material-human-version-after-agent-undo")

    try send("""
      Это проверка отмены того же материала \(nonce). Ничего не записывай. В течение 120 секунд
      наблюдай его состояние через публичный Notebook API с nb.wait между чтениями, используя
      ограниченные JS runs. Не меняй камеру/содержимое и не запускай другие инструменты.
      Я прерву этот настоящий ход кнопкой Stop; до этого продолжай наблюдение.
      """)
    let stop = app.buttons["notebook-chat-stop"]
    XCTAssertTrue(stop.isHittable); stop.tap()
    XCTAssertTrue(stop.waitForNonExistence(timeout: 30))
    let thread = try currentConversationID()
    screenshot("same-conversation-real-turn-cancelled")
    collapseChat()
    XCTAssertTrue(app.webViews.staticTexts[output + "102"].firstMatch.exists)
    try attach(["test": nonce, "threadID": thread, "documentID": documentID, "programID": programID,
      "actualCountAfterCancel": 102, "creationAddresses": receipt, "continuationAddresses": conflict],
      name: "linked-agent-human-cancel-chain-for-public-audit")
  }

  private func currentConversationID() throws -> String {
    let prefix = "notebook-chat-conversation-"
    let ids = Set(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
      .allElementsBoundByIndex.map(\.identifier))
    XCTAssertEqual(ids.count, 1)
    let id = String(try XCTUnwrap(ids.first).dropFirst(prefix.count))
    XCTAssertNotNil(UUID(uuidString: id)); return id
  }

  private func launchExistingCreatedMaterial() throws -> String {
    continueAfterFailure = false; executionTimeAllowance = 600
    app.launchEnvironment["NOTEBOOK_ACCEPTANCE_MANIFEST"] = try XCTUnwrap(
      ProcessInfo.processInfo.environment["NOTEBOOK_ACCEPTANCE_MANIFEST"])
    app.launch()
    XCTAssertTrue(app.otherElements["page-turn-surface"].waitForExistence(timeout: 30))
    let collapse = app.buttons["notebook-chat-toggle"]
    if collapse.exists { XCTAssertTrue(collapse.isHittable); collapse.tap() }
    let prefix = "Collaboration increment "
    let buttons = app.webViews.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix))
    XCTAssertTrue(buttons.firstMatch.waitForExistence(timeout: 30)); XCTAssertEqual(buttons.count, 1)
    let nonce = String(buttons.firstMatch.label.dropFirst(prefix.count))
    XCTAssertNotNil(UUID(uuidString: nonce))
    XCTAssertTrue(app.webViews.staticTexts["Collaboration count \(nonce): 102"].firstMatch.exists,
      "The preceding agent/human/undo/cancel chain must remain visible in this same document")
    return nonce
  }

  /// The external acceptance runner first stops only the manifest's private
  /// Mac process. This method never fakes connectivity or changes stored jobs.
  func testOfflineOutgoingAndDraftSurviveRelaunchInTheSameConversation() throws {
    let nonce = try launchExistingCreatedMaterial()
    openChat()
    let threadID = try currentConversationID()
    let notice = app.staticTexts["Mac недоступен · сообщения сохраняются на iPad"]
    XCTAssertTrue(notice.waitForExistence(timeout: 20), "A real disconnected peer is required")
    let outgoing = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "notebook-chat-outgoing-"))
    let acknowledgement = "RECONNECTED \(nonce)"
    XCTAssertFalse(app.webViews.staticTexts[acknowledgement].firstMatch.exists)
    let composer = app.descendants(matching: .any).matching(identifier: "notebook-chat-text").firstMatch
    XCTAssertTrue(composer.waitForExistence(timeout: 5)); composer.tap()
    XCTAssertTrue((composer.value as? String ?? "").isEmpty || composer.value as? String == "Сообщение Codex")
    let message = "После восстановления связи ответь только: \(acknowledgement). Не вызывай инструменты и ничего не меняй."
    let savedMessage = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@",
      "notebook-chat-outgoing-", message))
    // The text and its delivery label share one job ID. Count jobs, not AX
    // descendants. Continue an already accepted exact message without Send.
    let existingIDs = Set(outgoing.allElementsBoundByIndex.map(\.identifier))
    if existingIDs.isEmpty {
      composer.typeText(message); XCTAssertEqual(composer.value as? String, message)
      let send = app.buttons["notebook-chat-send"]
      XCTAssertTrue(send.isHittable); XCTAssertTrue(send.isEnabled); send.tap()
    }
    XCTAssertTrue(outgoing.firstMatch.waitForExistence(timeout: 10))
    let outgoingIDs = Set(outgoing.allElementsBoundByIndex.map(\.identifier))
    XCTAssertEqual(outgoingIDs.count, 1); XCTAssertEqual(savedMessage.count, 1)
    let outgoingID = try XCTUnwrap(outgoingIDs.first)
    XCTAssertNotNil(UUID(uuidString: String(outgoingID.dropFirst("notebook-chat-outgoing-".count))))
    XCTAssertFalse(app.buttons["notebook-chat-stop"].exists)
    let draft = "Неотправленный черновик \(nonce)"
    composer.tap(); composer.typeText(draft); XCTAssertEqual(composer.value as? String, draft)
    screenshot("same-chat-offline-outgoing-and-separate-draft")
    app.terminate(); app.launch()
    XCTAssertTrue(app.buttons["notebook-companion-compose"].waitForExistence(timeout: 20)
      || app.buttons["notebook-chat-menu"].exists)
    openChat()
    XCTAssertEqual(try currentConversationID(), threadID)
    XCTAssertTrue(notice.waitForExistence(timeout: 10))
    XCTAssertTrue(outgoing.firstMatch.waitForExistence(timeout: 10))
    XCTAssertEqual(Set(outgoing.allElementsBoundByIndex.map(\.identifier)), [outgoingID])
    XCTAssertEqual(composer.value as? String, draft)
    XCTAssertEqual(savedMessage.count, 1)
    screenshot("same-chat-offline-relaunch-preserves-message-identity-and-draft")
    try attach(["test": nonce, "threadID": threadID, "outgoingID": outgoingID,
      "message": message, "draft": draft, "actualCount": 102,
      "continuedExistingOutgoingWithoutResending": !existingIDs.isEmpty], name: "offline-same-conversation-durable-observations")
  }

  /// Run after restarting the exact same private Mac manifest and binary.
  func testReconnectedConversationDeliversOnceAndRetainsUnsentDraft() throws {
    let nonce = try launchExistingCreatedMaterial()
    openChat()
    let threadID = try currentConversationID()
    let composer = app.descendants(matching: .any).matching(identifier: "notebook-chat-text").firstMatch
    let draft = "Неотправленный черновик \(nonce)"
    XCTAssertEqual(composer.value as? String, draft)
    let acknowledgement = "RECONNECTED \(nonce)"
    // The requested marker is followed by sentence punctuation in the real
    // prompt. Either exact response is valid; the outgoing prompt is neither.
    let replies = app.webViews.staticTexts.matching(NSPredicate(format: "label IN %@",
      [acknowledgement, acknowledgement + "."]))
    XCTAssertTrue(replies.firstMatch.waitForExistence(timeout: 240),
      "A local outbox receipt is not an actual Codex response")
    XCTAssertTrue(app.buttons["notebook-chat-stop"].waitForNonExistence(timeout: 30))
    let outgoing = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "notebook-chat-outgoing-"))
    XCTAssertEqual(outgoing.count, 0)
    XCTAssertEqual(replies.count, 1)
    let actualReply = replies.firstMatch.label
    // Stop may arrive before the first tool activity. Do not require a
    // fabricated one-action work group; the same turn's interrupted status
    // is checked independently against the actual Codex owner.
    XCTAssertEqual(composer.value as? String, draft)
    XCTAssertFalse(app.staticTexts["Mac недоступен · сообщения сохраняются на iPad"].exists)
    screenshot("same-chat-reconnected-single-reply-and-unsent-draft")
    collapseChat()
    XCTAssertTrue(app.webViews.staticTexts["Collaboration count \(nonce): 102"].firstMatch.exists)
    try attach(["test": nonce, "threadID": threadID, "acknowledgement": actualReply,
      "draft": draft, "actualCountAfterReconnect": 102], name: "reconnected-same-conversation-for-independent-history-audit")
  }

  func testConcurrentHumanStateRejectsStaleAgentWriteAndSurvivesItsUndo() throws {
    try launch()
    let nonce = UUID().uuidString.lowercased()
    let agentMarker = "Agent ready \(nonce)"
    let humanMarker = "Human edit \(nonce)"
    let before = try count()
    try selectCounterRegion()
    try send("""
      Совместная проверка конфликта \(nonce). Работай только через notebook_context и notebook_execute,
      точные формы читай через nb.help. Прочитай внимание этого сообщения и emitImage его исходного
      artifact. Найди acceptance-controls на текущей доске. Одной атомарной транзакцией измени только
      его state.text на «\(agentMarker)», сохрани count/slider. Сохрани actionID и expectedA прямо
      из результата этой транзакции: saved.receipt.id и saved.receipt.revisions. Это версия той же
      принятой SQL записи; НЕ делай новое чтение для expectedA после появления маркера, иначе туда
      уже может попасть моя правка. Сохрани также state, который ты передал этой транзакции.
      Здесь saved — элемент массива ответа nb.transaction. Сразу emit фактические actionID,
      expectedA и state, чтобы продолжение другого run сохранило именно эту исходную квитанцию.
      Сообщи commentary с фактическими actionID/версией. Я увижу текст в самом виджете, нажму его
      counter и введу «\(humanMarker)» в то же поле. Жди эти ОБА изменения через ограниченные публичные
      чтения, оставаясь в текущем ходе; один JS run не дольше 30 секунд, продолжения без повторения
      эффектов. Не проси подтверждения, не используй файловую систему/сеть. После пользовательской
      правки намеренно попытайся setElementState с точным expectedA из той квитанции: должен вернуться
      revision_conflict. Не обновляй expected и не повторяй запись на новой версии. Если она неожиданно
      принята, сообщи ошибку и остановись. Emit фактический объект ошибки и expectedA; не подменяй
      ошибку ожидаемой строкой. Затем nb.undo отмени только свой исходный actionID. Ещё раз
      прочитай state и квитанцию undo: пользовательские count и text должны сохраниться. В финале
      один плоский JSON без вложенных объектов: test=\(nonce), phase=conflict_undone, contextID,
      referenceID, artifactSHA256, boardID, effectActionID, undoReceiptID, effectRunID, casRunID,
      undoRunID, attentionRunID, beforeRevision (board revision после твоего эффекта, до моей правки),
      humanRevision, afterUndoRevision, casErrorCode, undoSavedStatus (publication.saved),
      undoCompletedAt (исходное число receipt.undo.completedAt), undoRestoredCount (receipt.undo.restored),
      undoPreservedCount (receipt.undo.preservedCount), beforeCount, humanCount, afterUndoCount,
      agentText, humanText, afterUndoText. Это реальные публичные значения, не ожидаемые или выдуманные.
      Undo возвращает изменённую квитанцию первоначального действия: undoReceiptID должен быть равен
      effectActionID, отдельного actionID отмены здесь нет. RunID — действительный run_id вызова
      notebook_execute с соответствующей операцией или изображением. Emit полный ответ undo и итоговое
      чтение state для независимой проверки публичного журнала.
      """)
    let ready = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
      do { if try approveNotebookAccessIfRequested() { return false } }
      catch { XCTFail("Cannot complete the authorized Notebook access request: \(error)"); return true }
      return input.value as? String == agentMarker && app.buttons["notebook-chat-stop"].exists
    }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 240), .completed,
      "The actual live text field must show the agent's accepted state while Codex is still running.")
    collapseChat()
    XCTAssertTrue(input.isHittable)
    XCTAssertEqual(input.value as? String, agentMarker)
    XCTAssertEqual(try count(), before)
    screenshot("collaboration-agent-state-actually-visible-before-human-edit")
    try tapIncrement(from: before)
    try replaceInputThroughSelectionMenu(humanMarker)
    let actualText = try XCTUnwrap(input.value as? String)
    XCTAssertEqual(actualText, humanMarker)
    screenshot("collaboration-human-counter-and-field-concurrent-edit")
    openChat()
    let receipt = try packet(test: nonce, phase: "conflict_undone", timeout: 240)
    for key in ["contextID", "referenceID", "boardID", "effectActionID", "undoReceiptID", "effectRunID",
      "casRunID", "undoRunID", "attentionRunID"] { try uuid(receipt, key) }
    XCTAssertEqual(try uuid(receipt, "undoReceiptID"), try uuid(receipt, "effectActionID"))
    XCTAssertNotNil(try string(receipt, "artifactSHA256").range(of: #"^[0-9a-fA-F]{64}$"#, options: .regularExpression))
    XCTAssertEqual(try string(receipt, "casErrorCode"), "revision_conflict")
    XCTAssertNotEqual(try string(receipt, "beforeRevision"), try string(receipt, "humanRevision"))
    _ = try string(receipt, "afterUndoRevision")
    XCTAssertEqual(try string(receipt, "undoSavedStatus"), "confirmed")
    let undoCompletedAt = try XCTUnwrap(receipt["undoCompletedAt"] as? Double)
    XCTAssertTrue(undoCompletedAt.isFinite); XCTAssertGreaterThan(undoCompletedAt, 0)
    XCTAssertGreaterThanOrEqual(try XCTUnwrap(receipt["undoRestoredCount"] as? Int), 0)
    XCTAssertGreaterThan(try XCTUnwrap(receipt["undoPreservedCount"] as? Int), 0)
    XCTAssertEqual(receipt["beforeCount"] as? Int, before)
    XCTAssertEqual(receipt["humanCount"] as? Int, before + 1)
    XCTAssertEqual(receipt["afterUndoCount"] as? Int, before + 1)
    XCTAssertEqual(receipt["agentText"] as? String, agentMarker)
    XCTAssertEqual(receipt["humanText"] as? String, actualText)
    XCTAssertEqual(receipt["afterUndoText"] as? String, actualText)
    collapseChat()
    XCTAssertEqual(try count(), before + 1)
    XCTAssertEqual(input.value as? String, actualText)
    screenshot("collaboration-human-state-survives-agent-undo")
    try attach(["test": nonce, "actualBeforeCount": before, "actualAfterCount": before + 1,
      "actualHumanText": actualText, "agentReportedPublicAddresses": receipt],
      name: "ui-conflict-observations-for-independent-public-receipt-audit")
    try systemTrace?.ended(app)
  }
}

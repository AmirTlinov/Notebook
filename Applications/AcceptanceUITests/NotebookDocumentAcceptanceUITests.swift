import UIKit
import XCTest

/// One application's accepted requests form a strictly increasing history.
/// Returning to a page must not reuse that page's earlier successful receipt.
private struct DocumentInstallationHistory {
  private var acceptedIDs: Set<UUID> = []
  private var lastRequestedAt: Double?

  func canAccept(id: UUID, requestedAt: Double) -> Bool {
    requestedAt.isFinite && !acceptedIDs.contains(id)
      && (lastRequestedAt.map { requestedAt > $0 } ?? true)
  }

  mutating func accept(id: UUID, requestedAt: Double) -> Bool {
    guard canAccept(id: id, requestedAt: requestedAt) else { return false }
    acceptedIDs.insert(id); lastRequestedAt = requestedAt
    return true
  }
}

/// The separate public create-control.js program creates the content through
/// the paired Mac. These tests use only the ordinary iPad UI and read-only
/// timestamps published by the actual document presentation owner.
@MainActor final class NotebookDocumentAcceptanceUITests: XCTestCase {
  private let app = XCUIApplication(bundleIdentifier: "com.amirtlinov.notebook.acceptance")
  private var systemTrace: NotebookSystemTraceHandshake?
  private var installationHistory = DocumentInstallationHistory()
  private struct PagePreparationIdentity: Codable {
    let requestID: UUID
    let attemptID: UUID
    let coordinatorID: UUID
    let documentID: UUID
    let generation: String
    let runtimeID: UUID
    let sourceKey: String
    let stateKey: String
    let token: String
    let pageIndex: Int
    let configuredAt: Double
  }
  private struct Installation: Codable {
    let id: UUID
    let documentID: UUID
    let pageIndex: Int
    let cause: String
    let requestedAt: Double
    let demandedAt: Double?
    let contentReadyAt: Double?
    let installedAt: Double?
    let sourceToken: String?
    let failure: String?
    let observationIntervalMS: Int
    let sourcePreparationPhasesMS: [String: Double]?
    let sourcePreparationMeasurement: Int?
    let pagePreparationPhasesMS: [String: Double]?
    let pagePreparationIdentity: PagePreparationIdentity?
    let pagePreparationBrowserPhasesMS: [String: Double]?
    let pagePreparationBrowserStates: [String: [String: Double]]?
    let pagePreparationNativeVisibility: [String: [String: Double]]?
    var elapsedMS: Double? { installedAt.map { ($0 - requestedAt) * 1_000 } }
  }
  private var expectedDocumentID: UUID {
    get throws {
      try XCTUnwrap(ProcessInfo.processInfo.environment["NOTEBOOK_ACCEPTANCE_DOCUMENT_ID"].flatMap(UUID.init(uuidString:)),
        "Supply the ID returned by the actual public create-control.js run.")
    }
  }
  private var title: String { ProcessInfo.processInfo.environment["NOTEBOOK_ACCEPTANCE_DOCUMENT_TITLE"] ?? "Notebook canonical control" }
  private var surface: XCUIElement { app.otherElements["page-turn-surface"] }

  private func launch() throws {
    continueAfterFailure = false
    _ = try expectedDocumentID
    app.launchEnvironment["NOTEBOOK_ACCEPTANCE_MANIFEST"] = try XCTUnwrap(
      ProcessInfo.processInfo.environment["NOTEBOOK_ACCEPTANCE_MANIFEST"])
    if let sessionID = ProcessInfo.processInfo.environment["NOTEBOOK_NAVIGATION_OBSERVATION_SESSION_ID"] {
      app.launchEnvironment["NOTEBOOK_NAVIGATION_OBSERVATION_SESSION_ID"] = sessionID
    }
    if systemTrace == nil {
      systemTrace = try NotebookSystemTraceHandshake.configured(environment: ProcessInfo.processInfo.environment)
    }
    systemTrace?.configure(app)
    app.launch()
    installationHistory = DocumentInstallationHistory()
    try systemTrace?.began(app)
    if XCUIDevice.shared.orientation != .portrait { XCUIDevice.shared.orientation = .portrait }
    XCTAssertTrue(app.buttons["notebook-search"].waitForExistence(timeout: 20), app.debugDescription)
    XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "persistence-failure").firstMatch.exists,
      "A native persistence or publication error must be reported before navigation")
  }

  private func terminate() throws {
    try systemTrace?.ended(app)
    app.terminate()
  }

  private func screenshot(_ name: String) {
    let value = XCTAttachment(screenshot: app.screenshot())
    value.name = name; value.lifetime = .keepAlways; add(value)
  }

  private func attach<T: Encodable>(_ value: T, name: String) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let attachment = XCTAttachment(data: try encoder.encode(value), uniformTypeIdentifier: "public.json")
    attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
  }

  private func searchForDocument() throws {
    app.buttons["notebook-search"].tap()
    let search = app.searchFields.firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText(title)
    let result = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    XCTAssertTrue(result.waitForExistence(timeout: 10), app.debugDescription)
    XCTAssertTrue(result.isHittable); result.tap()
    // A title hit addresses the cover. Open the actual located document with
    // its ordinary gesture; body preparation is timed from this open request.
    let coverID = "workspace-item-" + (try expectedDocumentID).uuidString.lowercased()
    let cover = app.buttons[coverID]
    XCTAssertTrue(cover.waitForExistence(timeout: 10), app.debugDescription)
    XCTAssertTrue(cover.isHittable); cover.doubleTap()
  }

  private func installed(after priorID: UUID? = nil, pageIndex: Int? = nil, timeout: TimeInterval = 30) throws -> Installation {
    let expected = try expectedDocumentID
    var found: Installation?
    var observed: [Installation] = []
    let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
      let hosts = app.descendants(matching: .any).matching(identifier: "document-runtime").allElementsBoundByIndex
      for host in hosts {
        guard let value = host.value as? String, let bytes = value.data(using: .utf8),
          let record = try? JSONDecoder().decode(Installation.self, from: bytes),
          record.documentID == expected, record.id != priorID,
          pageIndex == nil || record.pageIndex == pageIndex else { continue }
        observed.append(record)
        if observed.count > 64 { observed.removeFirst(observed.count - 64) }
        // Page hosts can retain their last accessibility value after departure.
        // A different ID from the immediately preceding page alone is not fresh.
        guard installationHistory.canAccept(id: record.id, requestedAt: record.requestedAt),
          host.isHittable, !host.frame.intersection(app.frame).isEmpty,
          let currentPage = surface.value as? String,
          currentPage.hasPrefix("Страница \(record.pageIndex + 1) из ") else { continue }
        if record.installedAt != nil || record.failure != nil { found = record; return true }
      }
      return false
    }, object: nil)
    let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
    try attach(observed, name: "observed-native-document-records")
    if result != .completed { screenshot("failed-native-document-installation") }
    XCTAssertEqual(result, .completed,
      "No actual native installation record. Layout completion, an existing WebKit, or a cached PNG is insufficient. See the bounded native records and screenshot attachments.")
    let record = try XCTUnwrap(found)
    XCTAssertNil(record.failure); XCTAssertNotNil(record.sourceToken)
    let demanded = try XCTUnwrap(record.demandedAt), ready = try XCTUnwrap(record.contentReadyAt)
    let installed = try XCTUnwrap(record.installedAt)
    XCTAssertLessThanOrEqual(record.requestedAt, demanded)
    XCTAssertLessThanOrEqual(demanded, ready); XCTAssertLessThanOrEqual(ready, installed)
    XCTAssertEqual(record.observationIntervalMS, 5)
    XCTAssertTrue(installationHistory.accept(id: record.id, requestedAt: record.requestedAt),
      "Every accepted installation must have a unique ID and a later request within this app launch")
    return record
  }


  private func closeDocument() {
    // Back traverses the real navigation history. No model or presence write
    // is made by the test. The bounded loop also handles link return places.
    for _ in 0..<8 {
      if !surface.exists { return }
      let back = app.buttons["leave-nested-board"]
      XCTAssertTrue(back.isHittable); back.tap()
      if surface.waitForNonExistence(timeout: 2) { return }
    }
    XCTFail("The ordinary Back action did not return to the board.\n\(app.debugDescription)")
  }

  private func p95(_ values: [Double]) throws -> Double {
    XCTAssertGreaterThanOrEqual(values.count, 10)
    return try XCTUnwrap(values.sorted().dropFirst(Int(ceil(Double(values.count) * 0.95)) - 1).first)
  }

  private func assertPreparationBelongsToRequest(_ record: Installation) throws {
    let identity = try XCTUnwrap(record.pagePreparationIdentity)
    let phases = try XCTUnwrap(record.pagePreparationPhasesMS)
    XCTAssertEqual(identity.requestID, record.id)
    XCTAssertEqual(identity.documentID, record.documentID)
    XCTAssertEqual(identity.pageIndex, record.pageIndex)
    XCTAssertEqual(identity.token, record.sourceToken)
    XCTAssertTrue(identity.configuredAt.isFinite)
    XCTAssertGreaterThanOrEqual(identity.configuredAt, record.requestedAt)
    let ready = try XCTUnwrap(record.contentReadyAt)
    XCTAssertFalse(phases.isEmpty)
    for (name, offset) in phases {
      XCTAssertTrue(offset.isFinite && offset >= 0, name)
      XCTAssertLessThanOrEqual(identity.configuredAt + offset / 1_000, ready, name)
    }
  }

  /// A short diagnostic route preserves the same real gesture and installation
  /// contract before spending a complete ten-run performance workload. Its
  /// success alone does not certify either latency percentile.
  func testClosedDocumentCoverPinchChangesSceneScaleWithoutOpening() throws {
    try launch(); closeDocument()
    app.buttons["notebook-search"].tap()
    let search = app.searchFields.firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText(title)
    let result = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    XCTAssertTrue(result.waitForExistence(timeout: 10)); XCTAssertTrue(result.isHittable); result.tap()
    let cover = app.buttons["workspace-item-" + (try expectedDocumentID).uuidString.lowercased()]
    XCTAssertTrue(cover.waitForExistence(timeout: 10)); XCTAssertTrue(cover.isHittable)
    XCTAssertFalse(surface.exists)
    let before = cover.frame
    screenshot("closed-cover-before-real-camera-pinch")
    // Both contacts start on the actual closed cover, whose physical touch
    // owner delegates a pair to the scene. A ready HTML slider owns its own pair.
    cover.pinch(withScale: 0.8, velocity: -0.6)
    let after = cover.frame
    screenshot("closed-cover-after-real-camera-pinch")
    let value = ["before": [before.minX, before.minY, before.width, before.height],
      "after": [after.minX, after.minY, after.width, after.height]]
    try attach(value, name: "actual-closed-cover-camera-scale")
    XCTAssertFalse(surface.exists, "A pinch must not also open the document")
    XCTAssertGreaterThan(after.width, 0)
    XCTAssertLessThan(after.width, before.width * 0.98,
      "The scene must actually zoom out; merely delivering a pair of contacts is insufficient")
    XCTAssertEqual(after.width / before.width, after.height / before.height, accuracy: 0.002)
    try systemTrace?.ended(app)
  }

  func testColdOpeningAndDistantLinkPublishFreshNativeInstallations() throws {
    executionTimeAllowance = 180
    try launch(); closeDocument(); try terminate()
    try launch(); try searchForDocument()
    let first = try installed(pageIndex: 0)
    try assertPreparationBelongsToRequest(first)
    try attach(first, name: "diagnostic-cold-first-page-installation")
    screenshot("diagnostic-cold-first-page")
    let outward = app.links["К дальней главе"].firstMatch
    XCTAssertTrue(outward.isHittable); outward.tap()
    let distant = try installed(after: first.id)
    try assertPreparationBelongsToRequest(distant)
    XCTAssertGreaterThan(distant.pageIndex, 20)
    try attach(distant, name: "diagnostic-first-distant-page-installation")
    screenshot("diagnostic-first-distant-page")
    let returning = app.links["К оглавлению"].firstMatch
    XCTAssertTrue(returning.isHittable); returning.tap()
    let returned = try installed(after: distant.id, pageIndex: 0)
    try assertPreparationBelongsToRequest(returned)
    try attach(returned, name: "diagnostic-returned-first-page-installation")
    screenshot("diagnostic-returned-first-page")
    closeDocument()
    try systemTrace?.ended(app)
  }

  /// The accepted user journey is one continuous route. Each navigation uses
  /// the native installed-surface receipt, and editing uses only system input.
  /// This first complete route diagnoses blockers before the percentile run.
  func testBigDocumentFullLifecyclePreservesActualSource() throws {
    executionTimeAllowance = 300
    try launch(); closeDocument(); try terminate()
    try launch(); try searchForDocument()
    let first = try installed(pageIndex: 0)
    try assertPreparationBelongsToRequest(first)
    screenshot("lifecycle-cold-first-page")
    let outward = app.links["К дальней главе"].firstMatch
    XCTAssertTrue(outward.isHittable); outward.tap()
    let distant = try installed(after: first.id)
    try assertPreparationBelongsToRequest(distant)
    XCTAssertGreaterThan(distant.pageIndex, 20)
    screenshot("lifecycle-distant-page")
    let returning = app.links["К оглавлению"].firstMatch
    XCTAssertTrue(returning.isHittable); returning.tap()
    let returned = try installed(after: distant.id, pageIndex: 0)
    try assertPreparationBelongsToRequest(returned)
    screenshot("lifecycle-returned-first-page")
    try attach([first, distant, returned], name: "lifecycle-actual-native-navigation-records")
    try editFirstBlockAndReopen()
    closeDocument()
    try systemTrace?.ended(app)
  }

  /// Classify observer interference before changing the loading owner. The
  /// application still timestamps its actual installation; the deliberate
  /// quiet interval is neither subtracted from nor used as that measurement.
  func testColdOpeningWithoutAccessibilityTraversalDuringPreparation() throws {
    executionTimeAllowance = 120
    try launch(); closeDocument(); try terminate()
    try launch(); try searchForDocument()
    let quiet = XCTestExpectation(description: "No accessibility traversal during source preparation")
    XCTAssertEqual(XCTWaiter.wait(for: [quiet], timeout: 8), .timedOut)
    let first = try installed(pageIndex: 0)
    try assertPreparationBelongsToRequest(first)
    try attach(first, name: "quiet-observer-cold-native-installation")
    screenshot("quiet-observer-cold-first-page")
    XCTAssertTrue(app.links["К дальней главе"].firstMatch.isHittable)
    closeDocument()
    try systemTrace?.ended(app)
  }

  /// Observe the failed v15 state without recreating the document/WebKit. The
  /// coordinate comes from its original 1640x2360 screenshot, not DOM focus.
  func testInspectDisplayedDocumentAndTapVisibleFirstLink() throws {
    continueAfterFailure = false
    XCTAssertEqual(app.state, .runningForeground, "This diagnostic requires the already displayed failed document")
    XCTAssertTrue(surface.exists)
    XCTAssertEqual(app.windows.firstMatch.frame.size, CGSize(width: 820, height: 1180))
    screenshot("displayed-document-before-physical-link-tap")
    let hierarchy = XCTAttachment(string: app.debugDescription)
    hierarchy.name = "displayed-document-before-link-hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
    let window = app.windows.firstMatch
    let before = window.coordinate(withNormalizedOffset: .zero)
    // Centre of the visibly underlined first link in the recorded v15 page.
    before.withOffset(.init(dx: 160, dy: 178)).tap()
    let distant = app.descendants(matching: .any).matching(identifier: "page-turn-page-35").firstMatch
    let appeared = distant.waitForExistence(timeout: 12)
    screenshot("displayed-document-after-physical-link-tap")
    let after = XCTAttachment(string: app.debugDescription)
    after.name = "displayed-document-after-link-hierarchy"; after.lifetime = .keepAlways; add(after)
    XCTAssertTrue(appeared, "The actual visible link did not open its destination")
  }

  func testTenColdOpeningsAndWarmDistantLinksMeetNativeInstallationBudgets() throws {
    executionTimeAllowance = 600
    var cold: [Installation] = [], warm: [Installation] = []
    try launch(); closeDocument(); try terminate()
    for iteration in 0..<10 {
      // A new application/WebKit process starts on the board. Search then
      // performs the user's open request before the document body is loaded.
      try launch(); XCTAssertFalse(surface.exists)
      try searchForDocument()
      let first = try installed(pageIndex: 0)
      cold.append(first)
      XCTAssertEqual(first.cause, "open")
      let outward = app.links["К дальней главе"].firstMatch
      XCTAssertTrue(outward.waitForExistence(timeout: 3)); XCTAssertTrue(outward.isHittable)
      XCTAssertTrue(app.webViews.staticTexts["Chapter 0"].firstMatch.exists)
      screenshot("canonical-cold-first-page-\(iteration)")
      closeDocument(); try terminate()
    }
    try launch(); try searchForDocument()
    var previous = try installed(pageIndex: 0)
    // Prime the two destinations through real links before measuring warm
    // returns. The first distant preparation is retained as separate evidence.
    app.links["К дальней главе"].firstMatch.tap()
    previous = try installed(after: previous.id)
    XCTAssertGreaterThan(previous.pageIndex, 20)
    try attach(previous, name: "first-distant-page-preparation")
    app.links["К оглавлению"].firstMatch.tap()
    previous = try installed(after: previous.id, pageIndex: 0)
    for iteration in 0..<10 {
      app.links["К дальней главе"].firstMatch.tap()
      let distant = try installed(after: previous.id)
      XCTAssertGreaterThan(distant.pageIndex, 20); warm.append(distant)
      screenshot("canonical-warm-distant-page-\(iteration)")
      let returning = app.links["К оглавлению"].firstMatch
      XCTAssertTrue(returning.isHittable); returning.tap()
      previous = try installed(after: distant.id, pageIndex: 0); warm.append(previous)
    }
    try attach(cold, name: "simulator-release-ten-cold-open-native-records")
    try attach(warm, name: "simulator-release-twenty-warm-link-native-records")
    XCTAssertLessThanOrEqual(try p95(cold.compactMap(\.elapsedMS)), 3_000)
    XCTAssertLessThanOrEqual(try p95(warm.compactMap(\.elapsedMS)), 300)
    // These are request-to-observed-installation measurements in Simulator.
    // Observation targets 5 ms intervals; MainActor scheduling can add delay,
    // which remains in the measured time. This is not a frame-rate measurement.
    closeDocument()
    try systemTrace?.ended(app)
  }

  func testRealPageControlsLinksAndTouchSourceEditingSurviveColdReopening() throws {
    executionTimeAllowance = 240
    try launch(); closeDocument(); try searchForDocument()
    var previous = try installed(pageIndex: 0)
    app.buttons["next-page"].tap()
    previous = try installed(after: previous.id, pageIndex: 1)
    app.buttons["page-overview"].tap()
    let third = app.buttons["Страница 3"]
    XCTAssertTrue(third.waitForExistence(timeout: 5)); third.tap()
    previous = try installed(after: previous.id, pageIndex: 2)
    screenshot("canonical-real-page-overview-selection")
    app.buttons["previous-page"].tap(); previous = try installed(after: previous.id, pageIndex: 1)
    app.buttons["previous-page"].tap(); _ = try installed(after: previous.id, pageIndex: 0)
    app.links["Отсутствующий раздел"].firstMatch.tap()
    XCTAssertTrue(app.alerts["Ссылка недоступна"].waitForExistence(timeout: 3))
    app.alerts.buttons["Понятно"].tap()

    try editFirstBlockAndReopen()
    closeDocument()
    try systemTrace?.ended(app)
  }

  private func editFirstBlockAndReopen() throws {
    let heading = app.webViews.staticTexts["Chapter 0"].firstMatch
    XCTAssertTrue(heading.isHittable); heading.doubleTap()
    let editor = app.textViews["Исходный Markdown или LaTeX"].firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
    let visibleKeyboard = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
      let keyboard = app.keyboards.firstMatch
      return keyboard.exists && keyboard.frame.height > 100
    }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [visibleKeyboard], timeout: 3), .completed,
      "The real touch must open a visible software keyboard; a zero-height hardware-keyboard AX node is insufficient")
    let marker = "Notebook UI edit " + UUID().uuidString
    editor.typeText("\n\n" + marker)
    let entered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      (editor.value as? String)?.contains(marker) == true
    }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [entered], timeout: 3), .completed,
      "The complete physical input must reach the editor before Save")
    screenshot("canonical-real-software-keyboard-source-edit")
    let save = app.webViews.buttons["Сохранить"].firstMatch
    XCTAssertTrue(save.isHittable); save.tap()
    XCTAssertTrue(editor.waitForNonExistence(timeout: 10))
    // Saving must make the updated paper usable before it is closed. Merely
    // reopening a successfully written source hides a failed live replacement.
    let committedText = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch
    XCTAssertTrue(committedText.waitForExistence(timeout: 15),
      "The saved text must appear on the current physical page without closing the document")
    XCTAssertTrue(committedText.isHittable)
    screenshot("lifecycle-saved-source-visible-before-closing")
    closeDocument(); try terminate()

    try launch(); try searchForDocument()
    let reopened = try installed(pageIndex: 0)
    try assertPreparationBelongsToRequest(reopened)
    try attach(reopened, name: "lifecycle-edited-document-reopened-native-installation")
    app.webViews.staticTexts["Chapter 0"].firstMatch.doubleTap()
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    XCTAssertTrue((editor.value as? String)?.contains(marker) == true,
      "The actual source must survive closing, persistence, process termination, and reopening")
    screenshot("canonical-source-survives-cold-reopening")
    let cancel = app.webViews.buttons["Отменить"].firstMatch
    XCTAssertTrue(cancel.isHittable); cancel.tap()
    XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
    try attach(["documentID": try expectedDocumentID.uuidString, "blockID": "part-0", "marker": marker],
      name: "public-addressed-read-witness-for-ui-edit")
  }
}

/// Pure receipt-history contract; this test never launches an application.
final class NotebookDocumentInstallationHistoryTests: XCTestCase {
  func testInstallationHistoryRejectsReplayedOrOutOfOrderPageReceipts() {
    let first = UUID(), distant = UUID(), returned = UUID()
    var history = DocumentInstallationHistory()
    XCTAssertTrue(history.accept(id: first, requestedAt: 1))
    XCTAssertTrue(history.accept(id: distant, requestedAt: 2))
    // The old filter `id != distant` incorrectly accepts this page-0 receipt.
    XCTAssertNotEqual(first, distant)
    XCTAssertFalse(history.accept(id: first, requestedAt: 1))
    XCTAssertFalse(history.accept(id: first, requestedAt: 3))
    XCTAssertFalse(history.accept(id: returned, requestedAt: 2))
    XCTAssertFalse(history.accept(id: returned, requestedAt: 1.5))
    XCTAssertFalse(history.accept(id: returned, requestedAt: .nan))
    XCTAssertFalse(history.accept(id: returned, requestedAt: .infinity))
    XCTAssertTrue(history.accept(id: returned, requestedAt: 3))
    // A new application has a new history and may start at any finite time.
    history = DocumentInstallationHistory()
    XCTAssertTrue(history.accept(id: first, requestedAt: 1))
  }

}

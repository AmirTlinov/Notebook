import Foundation
import UIKit
import XCTest

/// The product is already paired and contains the ordinary public-API control.
/// This scenario performs real taps. The 100 ms verdict belongs to the separate
/// journal/WindowServer-frame analysis, never to XCTest AX waiting durations.
@MainActor final class NotebookInteractionAcceptanceUITests: XCTestCase {
  func testTenReadyControlTapsWithNativeAndDisplayedFrameEvidence() throws {
    continueAfterFailure = false; executionTimeAllowance = 150
    let environment = ProcessInfo.processInfo.environment
    let session = try XCTUnwrap(environment["NOTEBOOK_INTERACTION_SESSION_ID"])
    XCTAssertNotNil(UUID(uuidString: session))
    let control = URL(fileURLWithPath: try XCTUnwrap(environment["NOTEBOOK_INTERACTION_CONTROL_DIRECTORY"]), isDirectory: true)
    XCTAssertTrue(control.path.hasPrefix("/")); XCTAssertTrue(FileManager.default.fileExists(atPath: control.path))
    let app = XCUIApplication(bundleIdentifier: "com.amirtlinov.notebook.acceptance")
    app.launchEnvironment["NOTEBOOK_ACCEPTANCE_MANIFEST"] = try XCTUnwrap(environment["NOTEBOOK_ACCEPTANCE_MANIFEST"])
    app.launchEnvironment["NOTEBOOK_INTERACTION_SESSION_ID"] = session
    app.launchEnvironment["NOTEBOOK_INTERACTION_SELECTORS"] = "[\"#count\",\"#level\",\"#text\"]"
    // This existing surface reports the actual binary/PID only. No xctrace
    // acknowledgement or system frame-rate measurement is fabricated here.
    app.launchEnvironment["NOTEBOOK_TRACE_SESSION_ID"] = session
    app.launch()
    if XCUIDevice.shared.orientation != .portrait { XCUIDevice.shared.orientation = .portrait }
    XCTAssertTrue(app.buttons["notebook-companion-compose"].waitForExistence(timeout: 20))
    for _ in 0..<8 where app.otherElements["page-turn-surface"].exists {
      let back = app.buttons["leave-nested-board"]; XCTAssertTrue(back.isHittable); back.tap()
    }
    let collapse = app.buttons["notebook-chat-toggle"]
    if collapse.isHittable { collapse.tap() }
    let button = app.webViews.buttons["Acceptance increment"].firstMatch
    XCTAssertTrue(button.waitForExistence(timeout: 25)); XCTAssertTrue(button.isHittable)
    let identityElement = app.otherElements["notebook-system-trace-identity"]
    let identityText = try XCTUnwrap(identityElement.value as? String)
    let identity = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(identityText.utf8)) as? [String: Any])
    XCTAssertEqual((identity["sessionID"] as? String)?.lowercased(), session.lowercased())
    let ready: [String: Any] = ["format": 1, "sessionID": session, "status": "ui_ready",
      "identity": identity, "uptimeSeconds": ProcessInfo.processInfo.systemUptime,
      "buttonFrame": frame(button.frame), "appFrame": frame(app.frame)]
    try write(ready, to: control.appendingPathComponent("ui-ready.json"))
    attach(app.screenshot(), name: "ready-control-before-window-capture")
    let started = control.appendingPathComponent("capture/started.json")
    var captureFailure: String?
    let wait = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      let status = control.appendingPathComponent("capture-coordinator.json")
      if let data = try? Data(contentsOf: status),
        let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        value["status"] as? String == "unmeasured" {
        captureFailure = value["error"] as? String ?? "Window capture is unavailable"; return true
      }
      return FileManager.default.fileExists(atPath: started.path)
    }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [wait], timeout: 45), .completed,
      "Actual WindowServer frame capture must start before the taps; no latency measurement otherwise")
    XCTAssertNil(captureFailure, captureFailure ?? "")
    let acknowledgement = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: started)) as? [String: Any])
    XCTAssertEqual((acknowledgement["sessionID"] as? String)?.lowercased(), session.lowercased())
    XCTAssertEqual(acknowledgement["status"] as? String, "started")
    var steps: [[String: Any]] = []
    for index in 0..<10 {
      let before = try count(app)
      XCTAssertTrue(button.isHittable)
      let started = ProcessInfo.processInfo.systemUptime
      button.tap()
      XCTAssertTrue(app.webViews.staticTexts["Acceptance count: \(before + 1)"].waitForExistence(timeout: 3))
      XCTAssertEqual(try count(app), before + 1, "A real tap has exactly one visible count change")
      steps.append(["index": index, "before": before, "after": before + 1,
        "testCallStartedUptime": started, "axObservedUptime": ProcessInfo.processInfo.systemUptime])
    }
    attach(app.screenshot(), name: "ten-ready-control-taps-visible-result")
    let result: [String: Any] = ["format": 1, "sessionID": session, "status": "ui_ended", "identity": identity,
      "steps": steps, "uptimeSeconds": ProcessInfo.processInfo.systemUptime,
      "latencyMeasured": false, "scope": "Real taps and AX state only; join native journal to captured displayed pixels"]
    try write(result, to: control.appendingPathComponent("ui-ended.json"))
    try write(["sessionID": session, "status": "ui_ended"], to: control.appendingPathComponent("capture/stop.json"))
    let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
      uniformTypeIdentifier: "public.json")
    attachment.name = "ready-controls-real-gesture-sequence"; attachment.lifetime = .keepAlways; add(attachment)
  }

  private func frame(_ value: CGRect) -> [String: Double] {
    ["x": value.minX, "y": value.minY, "width": value.width, "height": value.height]
  }
  private func count(_ app: XCUIApplication) throws -> Int {
    let prefix = "Acceptance count: "
    let values = app.webViews.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).allElementsBoundByIndex
    XCTAssertEqual(values.count, 1)
    return try XCTUnwrap(values.first.flatMap { Int($0.label.dropFirst(prefix.count)) })
  }
  private func attach(_ screenshot: XCUIScreenshot, name: String) {
    let attachment = XCTAttachment(screenshot: screenshot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
  }
  private func write(_ value: [String: Any], to url: URL) throws {
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Evidence must not be overwritten")
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url, options: .atomic)
  }
}

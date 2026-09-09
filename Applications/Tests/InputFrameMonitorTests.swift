import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class InputFrameMonitorTests: XCTestCase {
  func testFreshSQLWorkspaceRecordsShortContactsAndHistoryWithoutAnExistingRuntimeDirectory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try await Task.detached {
      try NotebookStore(root: root).initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    }.value
    let runtime = root.appendingPathComponent("runtime")
    XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.path))
    let monitor = InputFrameMonitor(root: root)
    monitor.begin(mode: "board")
    monitor.end()
    monitor.recordHistoryMount(durationMS: 137)
    let contactURL = runtime.appendingPathComponent("input-frames.json")
    let historyURL = runtime.appendingPathComponent("collaboration-ui.json")
    try await waitUntil { FileManager.default.fileExists(atPath: contactURL.path)
      && FileManager.default.fileExists(atPath: historyURL.path) }
    XCTAssertNil(monitor.writeFailure)
    let contacts = try rows(at: contactURL), history = try rows(at: historyURL)
    XCTAssertEqual(contacts.count, 1)
    XCTAssertEqual(contacts.first?["mode"] as? String, "board")
    let cadence = try XCTUnwrap(contacts.first?["cadence"] as? [String: Any])
    XCTAssertEqual(cadence["totalIntervals"] as? Int, 0,
      "A contact with no display callback is retained, not mistaken for a missing measurement or FPS")
    XCTAssertEqual(history.count, 1)
    XCTAssertEqual(history.first?["tapToMountMS"] as? Double, 137)
  }

  func testFailedDiagnosticWriteIsReportedAndALaterContactCanRecover() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let runtime = root.appendingPathComponent("runtime")
    let obstruction = Data("preserve this file".utf8)
    try obstruction.write(to: runtime)
    let monitor = InputFrameMonitor(root: root)
    monitor.begin(mode: "blocked")
    monitor.end()
    try await waitUntil { monitor.writeFailure != nil }
    XCTAssertEqual(try Data(contentsOf: runtime), obstruction,
      "Diagnostics cannot remove an existing file to manufacture success")
    try FileManager.default.removeItem(at: runtime)
    monitor.begin(mode: "recovered")
    monitor.end()
    let url = runtime.appendingPathComponent("input-frames.json")
    try await waitUntil { FileManager.default.fileExists(atPath: url.path) && monitor.writeFailure == nil }
    let contacts = try rows(at: url)
    XCTAssertEqual(contacts.count, 1)
    XCTAssertEqual(contacts.first?["mode"] as? String, "recovered",
      "The failed measurement is not invented later")
  }

  private func rows(at url: URL) throws -> [[String: Any]] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
  }

  private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(predicate(), "The diagnostic writer did not finish within its bounded wait")
  }
}

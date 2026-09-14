import Foundation
import XCTest

/// Coordinates only the measurement lifecycle. All application actions remain
/// ordinary XCUITest gestures after a real xctrace start acknowledgement.
@MainActor final class NotebookSystemTraceHandshake {
  struct Identity: Codable, Equatable {
    let format: Int
    let sessionID: UUID
    let launchID: UUID
    let pid: Int32
    let bundleID: String
    let executableUUID: String
    let executablePath: String
    let reportedUptime: TimeInterval
  }
  private struct Message: Codable {
    let format: Int
    let sessionID: UUID
    let segmentID: UUID
    let identity: Identity
    let status: String
    let uptime: TimeInterval
    let error: String?
  }
  private let directory: URL
  private let sessionID: UUID
  private var current: Message?

  static func configured(environment: [String: String]) throws -> NotebookSystemTraceHandshake? {
    let session = environment["NOTEBOOK_TRACE_SESSION_ID"]
    let directory = environment["NOTEBOOK_TRACE_CONTROL_DIRECTORY"]
    guard session != nil || directory != nil else { return nil }
    guard let raw = session, let id = UUID(uuidString: raw), let path = directory,
      path.hasPrefix("/"), !path.contains("\0") else {
      throw Failure("Both valid trace session UUID and absolute control directory are required")
    }
    return .init(directory: URL(fileURLWithPath: path, isDirectory: true), sessionID: id)
  }

  private init(directory: URL, sessionID: UUID) { self.directory = directory; self.sessionID = sessionID }

  func configure(_ app: XCUIApplication) { app.launchEnvironment["NOTEBOOK_TRACE_SESSION_ID"] = sessionID.uuidString }

  func began(_ app: XCUIApplication) throws {
    guard current == nil else { throw Failure("A previous process trace was not closed before launching another app") }
    let probe = app.otherElements["notebook-system-trace-identity"]
    guard probe.waitForExistence(timeout: 15), let text = probe.value as? String,
      let data = text.data(using: .utf8) else { throw Failure("The launched app did not publish its actual process identity") }
    let identity = try JSONDecoder().decode(Identity.self, from: data)
    guard identity.format == 1, identity.sessionID == sessionID, identity.pid > 0,
      identity.bundleID == "com.amirtlinov.notebook.acceptance",
      UUID(uuidString: identity.executableUUID) != nil else { throw Failure("Trace identity does not match the requested acceptance launch") }
    let message = Message(format: 1, sessionID: sessionID, segmentID: UUID(), identity: identity,
      status: "ready", uptime: ProcessInfo.processInfo.systemUptime, error: nil)
    current = message
    try write(message, suffix: "ready")
    try wait(for: "started", message: message, timeout: 35)
    guard let latest = probe.value as? String, let bytes = latest.data(using: .utf8),
      try JSONDecoder().decode(Identity.self, from: bytes) == identity else {
      throw Failure("The target process identity changed while attaching the system trace")
    }
  }

  func ended(_ app: XCUIApplication) throws {
    guard let message = current else { return }
    let probe = app.otherElements["notebook-system-trace-identity"]
    guard let text = probe.value as? String, let bytes = text.data(using: .utf8),
      try JSONDecoder().decode(Identity.self, from: bytes) == message.identity else {
      throw Failure("The target process changed before the measured workload finished")
    }
    try write(Message(format: 1, sessionID: sessionID, segmentID: message.segmentID, identity: message.identity,
      status: "end", uptime: ProcessInfo.processInfo.systemUptime, error: nil), suffix: "end")
    try wait(for: "closed", message: message, timeout: 85)
    current = nil
  }

  private func write(_ value: Message, suffix: String) throws {
    guard FileManager.default.fileExists(atPath: directory.path) else { throw Failure("Trace coordinator control directory is missing") }
    let url = directory.appendingPathComponent(value.segmentID.uuidString + "." + suffix + ".json")
    guard !FileManager.default.fileExists(atPath: url.path) else { throw Failure("Trace segment messages must not be overwritten") }
    try JSONEncoder().encode(value).write(to: url, options: .atomic)
  }

  private func wait(for status: String, message: Message, timeout: TimeInterval) throws {
    var failure: Error?
    let waiter = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
      for suffix in ["failed", status] {
        let url = directory.appendingPathComponent(message.segmentID.uuidString + "." + suffix + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { continue }
        do {
          let value = try JSONDecoder().decode(Message.self, from: Data(contentsOf: url))
          guard value.format == 1, value.sessionID == sessionID, value.segmentID == message.segmentID,
            value.identity == message.identity, value.status == suffix else { throw Failure("Trace acknowledgement belongs to a different process or segment") }
          if suffix == "failed" { throw Failure(value.error ?? "System trace failed") }
        } catch { failure = error }
        return true
      }
      return false
    }, object: nil)
    guard XCTWaiter.wait(for: [waiter], timeout: timeout) == .completed else {
      throw Failure("Timed out waiting for system trace \(status); no measured workload is claimed")
    }
    if let failure { throw failure }
  }

  struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }
}

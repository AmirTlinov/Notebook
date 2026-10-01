import Foundation
import NotebookCore
import XCTest
@testable import Notebook

final class NotebookWorkspaceWritersTests: XCTestCase {
  private enum Failure: Error { case storageUnavailable }

  @MainActor
  func testCanonicalAliasesShareAcceptedWriteOrder() async throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let root = parent.appendingPathComponent("workspace"), alias = parent.appendingPathComponent("alias")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
    defer { try? FileManager.default.removeItem(at: parent) }

    let owners = NotebookWorkspaceWriters()
    let first = owners.persistence(for: NotebookStore(root: root))
    let second = owners.persistence(for: NotebookStore(root: alias))
    XCTAssertTrue(first === second, "A new surface and the agent borrow the same workspace FIFO")
    let accepted = root.appendingPathComponent("accepted")
    first.enqueue { _ in try Data("first".utf8).write(to: accepted); return false }
    let observed = try await second.submit { _ in try String(contentsOf: accepted, encoding: .utf8) }
    XCTAssertEqual(observed, "first", "A second client reads after the first client's accepted write")
    let stopped = await owners.shutdown()
    XCTAssertTrue(stopped)
  }

  @MainActor
  func testFailedRetirementRetainsTheWriterAndAcceptedTailForRetry() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), owners = NotebookWorkspaceWriters()
    let writer = owners.persistence(for: store)
    let repaired = root.appendingPathComponent("repaired"), accepted = root.appendingPathComponent("accepted")
    writer.enqueue { _ in
      guard FileManager.default.fileExists(atPath: repaired.path) else { throw Failure.storageUnavailable }
      try Data("first".utf8).write(to: accepted)
      return false
    }
    writer.enqueue { _ in
      let before = try Data(contentsOf: accepted)
      try (before + Data(" second".utf8)).write(to: accepted)
      return false
    }
    do {
      try await owners.remove(root: root)
      XCTFail("Unpersisted accepted work prevents writer retirement")
    } catch NotebookTransportError.storageUnavailable { }
    XCTAssertTrue(owners.persistence(for: store) === writer)
    XCTAssertEqual(writer.pendingCount, 2)
    try Data().write(to: repaired)
    writer.retry()
    try await owners.remove(root: root)
    XCTAssertEqual(try String(contentsOf: accepted, encoding: .utf8), "first second")
    XCTAssertFalse(owners.persistence(for: store) === writer, "Only a drained workspace can acquire a replacement owner")
    let stopped = await owners.shutdown()
    XCTAssertTrue(stopped)
  }
}

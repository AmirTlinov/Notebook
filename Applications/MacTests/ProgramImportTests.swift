import CryptoKit
import Foundation
import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class ProgramImportTests: XCTestCase {
  private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

  func testLargeFileImportYieldsToTheExistingWriterAndSurvivesColdStatus() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    let workspace = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let persistence = NotebookPersistenceQueue(store: store)
    let importer = NotebookProgramImporter(persistence: persistence, workspaceID: workspace.workspaceID)
    defer { importer.stop() }
    let sourceURL = root.appendingPathComponent("main.js"), source = Data(repeating: 32, count: 1_048_577)
    try source.write(to: sourceURL)
    let dataURL = root.appendingPathComponent("data.bin")
    XCTAssertTrue(FileManager.default.createFile(atPath: dataURL.path, contents: nil))
    let dataFile = try FileHandle(forWritingTo: dataURL)
    var parts: [NotebookProgramPackage.Part] = []
    for index in 0..<16 {
      let bytes = Data(repeating: UInt8(index), count: NotebookProgramPackage.partBytes)
      try dataFile.write(contentsOf: bytes)
      parts.append(.init(sha256: hash(bytes), byteCount: bytes.count))
    }
    try dataFile.close()
    let package = NotebookProgramPackage(javaScript: "main.js", files: [
      .init(path: "data.bin", mimeType: "application/octet-stream", byteCount: 64 * 1024 * 1024, parts: parts),
      .init(path: "main.js", mimeType: "text/javascript", byteCount: Int64(source.count), parts: [.init(sha256: hash(source), byteCount: source.count)])])
    let packageHash = try package.sha256, manifestURL = root.appendingPathComponent("import.json")
    let descriptor = NotebookProgramImport(packageHash: packageHash, package: package, sources: [
      .init(path: "data.bin", sourcePath: dataURL.path), .init(path: "main.js", sourcePath: sourceURL.path)])
    try JSONEncoder().encode(descriptor).write(to: manifestURL)
    let started = try await importer.handle(.init(op: .start, packageHash: packageHash, manifestPath: manifestURL.path))
    XCTAssertEqual(started["status"], .string("staging"))
    let deadline = ContinuousClock.now + .seconds(20)
    var progress = started
    while progress["stagedBytes"] == .number(0), ContinuousClock.now < deadline {
      await Task.yield(); progress = try await importer.handle(.init(op: .status, packageHash: packageHash))
    }
    // This ordinary contact passes through the same FIFO between file parts.
    let pageID = try XCTUnwrap(try store.loadIndex().selectedPageID)
    try await persistence.submit(publishesChanges: true) { store in
      var page = try store.loadPage(pageID)
      _ = page.replaceElements([.init(id: "small-note", kind: .web, frame: .init(x: 0, y: 0, width: 80, height: 30),
        source: "Small accepted edit", html: "<p>Still responsive</p>")], actor: actor)
      try store.savePage(page)
    }
    progress = try await importer.handle(.init(op: .status, packageHash: packageHash))
    XCTAssertNotEqual(progress["status"], .string("ready"), "A 64 MiB import cannot monopolize the writer until completion")
    while progress["status"] == .string("staging"), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5)); progress = try await importer.handle(.init(op: .status, packageHash: packageHash))
    }
    XCTAssertEqual(progress["status"], .string("ready"), String(describing: progress))
    XCTAssertEqual(try store.loadPage(pageID).elements.first?.id, "small-note")
    XCTAssertEqual(try store.readProgramPackage(packageHash), package)
    let cold = NotebookProgramImporter(persistence: persistence, workspaceID: workspace.workspaceID)
    let received = try await cold.handle(.init(op: .status, packageHash: packageHash))
    XCTAssertEqual(received["status"], .string("ready"))
    let before = try store.currentChangeCursor()
    let repeated = try await cold.handle(.init(op: .start, packageHash: packageHash, manifestPath: manifestURL.path))
    XCTAssertEqual(repeated["status"], .string("ready"))
    XCTAssertEqual(try store.currentChangeCursor(), before, "Retrying bytes is not another document edit")
  }

  func testCancelBeforeReadingDoesNotAdmitTheManifestAndRetryUsesTheSameIdentity() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    let workspace = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    let importer = NotebookProgramImporter(persistence: NotebookPersistenceQueue(store: store), workspaceID: workspace.workspaceID)
    defer { importer.stop() }
    let bytes = Data("export{}".utf8), source = root.appendingPathComponent("main.js")
    try bytes.write(to: source)
    let package = NotebookProgramPackage(javaScript: "main.js", files: [
      .init(path: "main.js", mimeType: "text/javascript", byteCount: Int64(bytes.count), parts: [.init(sha256: hash(bytes), byteCount: bytes.count)])])
    let hash = try package.sha256, path = root.appendingPathComponent("manifest.json")
    try JSONEncoder().encode(NotebookProgramImport(packageHash: hash, package: package, sources: [.init(path: "main.js", sourcePath: source.path)])).write(to: path)
    _ = try await importer.handle(.init(op: .start, packageHash: hash, manifestPath: path.path))
    _ = try await importer.handle(.init(op: .cancel, packageHash: hash))
    var status: JSONValue = .null
    let deadline = ContinuousClock.now + .seconds(10)
    repeat {
      await Task.yield(); status = try await importer.handle(.init(op: .status, packageHash: hash))
    } while status["status"] == .string("staging") && ContinuousClock.now < deadline
    XCTAssertEqual(status["status"], .string("cancelled"))
    XCTAssertThrowsError(try store.readProgramPackage(hash))
    _ = try await importer.handle(.init(op: .start, packageHash: hash, manifestPath: path.path))
    repeat {
      try await Task.sleep(for: .milliseconds(5)); status = try await importer.handle(.init(op: .status, packageHash: hash))
    } while status["status"] == .string("staging") && ContinuousClock.now < deadline
    XCTAssertEqual(status["status"], .string("ready"))
  }
}

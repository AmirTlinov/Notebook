import CryptoKit
import Foundation
import Testing
@testable import NotebookCore

@Suite("Bounded transport staging has one durable owner")
struct NotebookTransportStorageTests {
  @Test func aWindowCommitsTogetherWithoutPublishingContentOrACursor() throws {
    try fixture { store, root in
      let batch = try (0..<16).map { index in
        try file(Data(repeating: UInt8(index), count: 512), in: root)
      }
      let revision = try store.currentReadCursor(), cursor = try store.currentChangeCursor()
      try store.stageBlobs(batch)
      #expect(try store.currentReadCursor() == revision + 1, "One staging commit, not sixteen")
      #expect(try store.currentChangeCursor() == cursor, "Blob availability is not content publication")
      let reopened = NotebookStore(root: store.root)
      for blob in batch {
        #expect(try reopened.readBlobChunk(hash: blob.hash, offset: 0, maxBytes: 512) == Data(contentsOf: blob.file))
      }
    }
  }

  @Test func aCorruptLastFileRollsBackTheEntireWindow() throws {
    try fixture { store, root in
      let first = try file(Data("first".utf8), in: root)
      let last = try file(Data("last!".utf8), in: root)
      try Data("wrong".utf8).write(to: last.file)
      let revision = try store.currentReadCursor()
      #expect(throws: NotebookStorageError.blobHashMismatch) { try store.stageBlobs([first, last]) }
      #expect(throws: NotebookStorageError.blobMissing(first.hash)) { try store.blobSize(hash: first.hash) }
      #expect(try store.currentReadCursor() == revision)
      #expect(throws: NotebookTransportError.invalidBlob) { try store.stageBlobs([]) }
      #expect(throws: NotebookTransportError.invalidBlob) { try store.stageBlobs([first, first]) }
    }
  }

  @Test func stagedFilesAreDisposableUntilTheStoreAcceptsThem() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let assembly = try NotebookTransportBlobAssembly(stagingRoot: root, generation: UUID())
    let a = Data("one".utf8), b = Data("two".utf8)
    let first = try #require(await assembly.append(.init(hash: hash(a), offset: 0, totalBytes: 3, data: a),
      expectedHash: hash(a), maximumBytes: 3))
    let second = try #require(await assembly.append(.init(hash: hash(b), offset: 0, totalBytes: 3, data: b),
      expectedHash: hash(b), maximumBytes: 3))
    #expect(try Data(contentsOf: first.file) == a)
    #expect(try Data(contentsOf: second.file) == b)
    await assembly.cancel()
    #expect(!FileManager.default.fileExists(atPath: first.file.path))
    #expect(!FileManager.default.fileExists(atPath: second.file.path))
  }

  private func fixture(_ body: (NotebookStore, URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root.appendingPathComponent("store"))
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    try body(store, root)
  }

  private func file(_ data: Data, in root: URL) throws -> NotebookTransportCompletedBlob {
    let file = root.appendingPathComponent(UUID().uuidString)
    try data.write(to: file)
    return .init(hash: hash(data), file: file, byteCount: Int64(data.count))
  }

  private func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

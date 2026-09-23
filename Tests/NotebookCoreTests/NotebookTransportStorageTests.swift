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
        #expect(try reopened.readBlobChunk(hash: blob.hash, offset: 0, maxBytes: 512) == Data(contentsOf: fileURL(blob)))
      }
    }
  }

  @Test func aCorruptLastFileRollsBackTheEntireWindow() throws {
    try fixture { store, root in
      let first = try file(Data("first".utf8), in: root)
      let last = try file(Data("last!".utf8), in: root)
      try Data("wrong".utf8).write(to: fileURL(last))
      let revision = try store.currentReadCursor()
      #expect(throws: NotebookStorageError.blobHashMismatch) { try store.stageBlobs([first, last]) }
      #expect(throws: NotebookStorageError.blobMissing(first.hash)) { try store.blobSize(hash: first.hash) }
      #expect(try store.currentReadCursor() == revision)
      #expect(throws: NotebookTransportError.invalidBlob) { try store.stageBlobs([]) }
      #expect(throws: NotebookTransportError.invalidBlob) { try store.stageBlobs([first, first]) }
    }
  }

  @Test func completeChunksStayBoundedInMemoryAndPartialChunksRemainDisposableFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let generation = UUID(), assembly = try NotebookTransportBlobAssembly(stagingRoot: root, generation: generation)
    let a = Data("one".utf8), b = Data("two".utf8)
    let first = try #require(await assembly.append(.init(hash: hash(a), offset: 0, totalBytes: 3, data: a),
      expectedHash: hash(a), maximumBytes: 3))
    guard case .bytes(let digest, let bytes) = first else { Issue.record("A complete bounded chunk must not write a file"); return }
    #expect(digest == hash(a)); #expect(bytes == a)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(generation.uuidString).path).isEmpty)
    #expect(try await assembly.append(.init(hash: hash(b), offset: 0, totalBytes: 3, data: Data(b.prefix(1))),
      expectedHash: hash(b), maximumBytes: 3) == nil)
    let second = try #require(await assembly.append(.init(hash: hash(b), offset: 1, totalBytes: 3, data: Data(b.dropFirst())),
      expectedHash: hash(b), maximumBytes: 3))
    let file = try fileURL(second)
    #expect(try Data(contentsOf: file) == b)
    await assembly.cancel()
    #expect(!FileManager.default.fileExists(atPath: file.path))
  }

  @Test func boundedBytesAndFilesHaveTheSameAtomicHashAdmission() throws {
    try fixture { store, root in
      let a = Data("bounded".utf8), b = Data("wrong".utf8), empty = Data()
      let before = try store.currentReadCursor()
      #expect(throws: NotebookStorageError.blobHashMismatch) {
        try store.stageBlobs([.bytes(hash: hash(a), data: a), .bytes(hash: hash(b), data: a)])
      }
      #expect(throws: NotebookStorageError.blobMissing(hash(a))) { try store.blobSize(hash: hash(a)) }
      #expect(try store.currentReadCursor() == before)
      try store.stageBlobs([.bytes(hash: hash(a), data: a), .bytes(hash: hash(empty), data: empty), file(b, in: root)])
      #expect(try store.blobSize(hash: hash(empty)) == 0)
      #expect(try store.readBlobWindow([.init(hash: hash(a))]).first?.data == a)
      #expect(try store.currentReadCursor() == before + 1)
    }
  }

  @Test func stagingAndDependencyDiscoveryShareOneCommitWithoutManufacturingContent() throws {
    try fixture { source, root in
      let peer = NotebookStore(root: root.appendingPathComponent("peer"))
      try peer.prepareEmptyWorkspace(workspaceID: source.storedWorkspaceID())
      let sender = try source.replicationSource(deviceID: UUID())
      _ = try peer.admitReplicationSource(sender)
      let change = try #require(source.changeJournal(after: 0).first)
      let delivery = NotebookReplicationDelivery(source: sender, change: change)
      var missing = try peer.prepareIncomingBlobs(delivery, staging: [])
      var windows = 0
      while !missing.isEmpty, windows < 20 {
        let chunks = try source.readBlobWindow(missing.map { .init(hash: $0) })
        #expect(chunks.allSatisfy { $0.offset == 0 && $0.data.count == $0.totalBytes })
        let revision = try peer.currentReadCursor()
        missing = try peer.prepareIncomingBlobs(delivery, staging: chunks.map { .bytes(hash: $0.hash, data: $0.data) })
        #expect(try peer.currentReadCursor() == revision + 1, "Staging and index discovery are one durable cut")
        #expect(try peer.currentChangeCursor() == 0)
        #expect(try peer.peerCursor(peerID: sender.deviceID, direction: .incoming) == 0)
        windows += 1
      }
      #expect(missing.isEmpty)
      let revision = try peer.currentReadCursor()
      #expect(try peer.prepareIncomingBlobs(delivery, staging: []).isEmpty)
      #expect(try peer.currentReadCursor() == revision, "Unchanged dependency checks must not create writes/fsyncs")
      _ = try peer.applyDelivery(delivery)
      #expect(try peer.peerCursor(peerID: sender.deviceID, direction: .incoming) == change.sequence)
    }
  }

  @Test func aReadWindowUsesOneSnapshotAndNeverLoadsAWholeLargeBlob() throws {
    try fixture { store, root in
      let small = Data(repeating: 1, count: 512), large = Data(repeating: 2, count: 70_000)
      let last = Data(repeating: 3, count: 32_768), empty = Data()
      for data in [small, large, last, empty] { try store.stageBlobs([file(data, in: root)]) }
      let requests: [NotebookTransportBlobRequest] = [small, large, last].map { .init(hash: hash($0)) }
      let first = try store.readBlobWindow(requests)
      #expect(first.map(\.hash) == [hash(small), hash(large)])
      #expect(first.map { $0.data.count } == [512, 32_768])
      #expect(first.last?.totalBytes == 70_000)
      let second = try store.readBlobWindow([.init(hash: hash(large), offset: 32_768), .init(hash: hash(last))])
      #expect(second.count == 1)
      let third = try store.readBlobWindow([.init(hash: hash(large), offset: 65_536), .init(hash: hash(last))])
      #expect(third.map { $0.data.count } == [4_464, 32_768])
      #expect(first[1].data + second[0].data + third[0].data == large)
      #expect(third[1].data == last)
      #expect(try store.readBlobWindow([.init(hash: hash(empty))]).first?.data == empty)
      #expect(throws: NotebookTransportError.invalidBlob) {
        try store.readBlobWindow([.init(hash: hash(small), offset: 512)])
      }
    }
  }

  @Test func readWindowStopsAtByteLimitAndDoesNotReadUnrequestedOrLaterHashes() throws {
    try fixture { store, root in
      let batch = try (0..<16).map { try file(Data(repeating: UInt8($0), count: 4096), in: root) }
      try store.stageBlobs(batch)
      let revision = try store.currentReadCursor(), cursor = try store.currentChangeCursor()
      let chunks = try store.readBlobWindow(batch.map { .init(hash: $0.hash) })
      #expect(chunks.count == 16)
      #expect(chunks.reduce(0) { $0 + $1.data.count } == NotebookTransportLimits.maximumBlobWindowBytes)
      #expect(try store.currentReadCursor() == revision)
      #expect(try store.currentChangeCursor() == cursor)
      let large = try file(Data(repeating: 255, count: 70_000), in: root)
      try store.stageBlobs([large])
      let absent = String(repeating: "e", count: 64)
      #expect(try store.readBlobWindow([.init(hash: large.hash), .init(hash: absent)]).count == 1)
      #expect(throws: NotebookStorageError.blobMissing(absent)) { try store.readBlobWindow([.init(hash: absent)]) }
    }
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
    return .file(hash: hash(data), url: file, byteCount: Int64(data.count))
  }

  private func fileURL(_ blob: NotebookTransportCompletedBlob) throws -> URL {
    guard case .file(_, let file, _) = blob else { throw NotebookTransportError.invalidBlob }
    return file
  }

  private func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

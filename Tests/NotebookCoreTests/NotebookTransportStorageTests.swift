import CSQLite
import CryptoKit
import Foundation
import Testing
@testable import NotebookCore

@Suite("Bounded transport staging has one durable owner")
struct NotebookTransportStorageTests {
  @Test func closingTheReaderReleasesTheDatabaseAndCannotReopenIt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    let reader = NotebookTransportReader(store: store)
    let changes = try await reader.changes(after: 0, limit: 16)
    let hash = try #require(changes.first?.manifestHash)
    _ = try await reader.blobs([.init(hash: hash)])
    // WAL files may persist after SQLITE_OK close. A journal-mode switch
    // requires the exclusive lock that an idle WAL reader still prevents.
    func exclusiveJournalSwitch() -> Int32 {
      var database: OpaquePointer?
      let opened = sqlite3_open_v2(store.databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil)
      defer { sqlite3_close(database) }
      guard opened == SQLITE_OK else { return opened }
      return sqlite3_exec(database, "PRAGMA journal_mode=DELETE", nil, nil, nil)
    }
    #expect(exclusiveJournalSwitch() == SQLITE_BUSY, "The control must detect this live reader")
    await reader.close()
    #expect(exclusiveJournalSwitch() == SQLITE_OK, "No idle handle may survive terminal close")
    await reader.close()
    try FileManager.default.removeItem(at: root)
    await #expect(throws: NotebookTransportError.disconnected) { try await reader.changes(after: 0, limit: 16) }
    await #expect(throws: NotebookTransportError.disconnected) { try await reader.blobs([.init(hash: hash)]) }
    #expect(!FileManager.default.fileExists(atPath: root.path))
  }

  @Test func transportReaderSeesEachCommittedCutWithoutPinningThePriorSnapshot() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let reader = NotebookTransportReader(store: store)
    let initial = try await reader.changes(after: 0, limit: 16)
    #expect(try initial == store.changeJournal(after: 0, limit: 16))
    let cursor = try #require(initial.last?.sequence)
    var page = try store.loadPage(#require(store.loadIndex().selectedPageID))
    page.replaceDrawing(pageDrawingFixture(Data([4, 5])), actor: actor)
    try store.savePage(page)
    let changed = try await reader.changes(after: cursor, limit: 16)
    #expect(try changed == store.changeJournal(after: cursor, limit: 16))
    #expect(changed.count == 1)
    let bytes = Data(repeating: 37, count: 70_000), digest = hash(bytes)
    try store.stageBlobs([file(bytes, in: root)])
    var restored = Data()
    while restored.count < bytes.count {
      let chunk = try #require(await reader.blobs([.init(hash: digest, offset: Int64(restored.count))]).first)
      #expect(chunk.data.count <= NotebookTransportLimits.maximumChunkBytes)
      restored.append(chunk.data)
    }
    #expect(restored == bytes)
    // Idle transport keeps the useful handle, not a read transaction. Writers
    // still use FULL, and even a truncating checkpoint is never pinned by it.
    let wal = URL(fileURLWithPath: store.databaseURL.path + "-wal")
    #expect((try FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? NSNumber)?.int64Value ?? 0 > 0)
    let checkpoint = try store.prepareDatabase()
    #expect(try checkpoint.rows("PRAGMA synchronous").first?.first?.integer == 2)
    #expect(try checkpoint.rows("PRAGMA wal_autocheckpoint").first?.first?.integer == 1000)
    #expect(try checkpoint.rows("PRAGMA wal_checkpoint(TRUNCATE)").first?.first?.integer == 0)
    #expect(try await reader.changes(after: cursor, limit: 16) == changed)
    #expect(try await reader.blobs([.init(hash: digest)]).first?.data == bytes.prefix(32_768))
  }

  @Test func transportReaderRechecksAdmissionAndRecoversOnlyWithinTheSameDatabase() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    let reader = NotebookTransportReader(store: store)
    let expected = try await reader.changes(after: 0, limit: 16)
    let marker = root.appendingPathComponent("workspace.json"), bytes = Data("not an admitted archive".utf8)
    try bytes.write(to: marker)
    await #expect(throws: NotebookStorageError.legacyStoreRequiresConversion) {
      try await reader.changes(after: 0, limit: 16)
    }
    #expect(try Data(contentsOf: marker) == bytes)
    try FileManager.default.removeItem(at: marker)
    #expect(try await reader.changes(after: 0, limit: 16) == expected)
    let database = try store.prepareDatabase()
    try database.run("PRAGMA user_version=\(NotebookStore.currentDatabaseVersion + 1)")
    await #expect(throws: NotebookStorageError.unsupportedFormat) {
      try await reader.changes(after: 0, limit: 16)
    }
    try database.run("PRAGMA user_version=\(NotebookStore.currentDatabaseVersion)")
    #expect(try await reader.changes(after: 0, limit: 16) == expected)
  }

  @Test func replacingTheDatabaseCannotOfferAnotherWorkspaceUnderTheOldTransport() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let live = root.appendingPathComponent("live"), retired = root.appendingPathComponent("retired")
    let store = NotebookStore(root: live)
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    let reader = NotebookTransportReader(store: store)
    let original = try await reader.changes(after: 0, limit: 16)
    let oldBytes = Data("old committed WAL".utf8), newBytes = Data("new committed WAL".utf8)
    try store.stageBlobs([file(oldBytes, in: root)])
    try FileManager.default.moveItem(at: live, to: retired)
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    let replacement = NotebookTransportReader(store: store)
    let newChanges = try await replacement.changes(after: 0, limit: 16)
    #expect(newChanges != original)
    try store.stageBlobs([file(newBytes, in: root)])
    for _ in 0..<2 {
      await #expect(throws: NotebookStorageError.invalidTransaction("database file identity changed")) {
        try await reader.changes(after: 0, limit: 16)
      }
    }
    #expect(try await replacement.blobs([.init(hash: hash(newBytes))]).first?.data == newBytes)
    let oldStore = NotebookStore(root: retired)
    #expect(try oldStore.changeJournal(after: 0, limit: 16) == original)
    #expect(try oldStore.readBlobWindow([.init(hash: hash(oldBytes))]).first?.data == oldBytes)
    #expect(try store.readBlobWindow([.init(hash: hash(newBytes))]).first?.data == newBytes)
  }

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

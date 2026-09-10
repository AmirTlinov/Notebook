import CSQLite
import Foundation
import Testing
@testable import NotebookCore

private final class ReplicationWindowTrace {
  var rows: [OpaquePointer: Int] = [:]
  var maximumManifestRows = 0
  var maximumRequestRows = 0
  var manifestQueries = 0
  var requestQueries = 0

  func record(_ event: UInt32, _ statement: OpaquePointer) {
    guard let raw = sqlite3_sql(statement) else { return }
    let sql = String(cString: raw)
    let manifest = sql.hasPrefix("SELECT address,blob_hash FROM manifest_records")
    let request = sql.hasPrefix("SELECT request_id,execution_before FROM replication_agent_checks")
    guard manifest || request else { return }
    if event == UInt32(SQLITE_TRACE_STMT) { rows[statement] = 0 }
    if event == UInt32(SQLITE_TRACE_ROW) { rows[statement, default: 0] += 1 }
    if event == UInt32(SQLITE_TRACE_PROFILE) {
      let count = rows.removeValue(forKey: statement) ?? 0
      if manifest { maximumManifestRows = max(maximumManifestRows, count); manifestQueries += 1 }
      if request { maximumRequestRows = max(maximumRequestRows, count); requestQueries += 1 }
    }
  }
}

@Suite("Replication releases independent owners before reading the next", .serialized)
struct NotebookReplicationOwnerWindowTests {
  private func fixture(_ body: (NotebookStore, NotebookStore, UUID, NotebookWorkspaceHeader) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = NotebookStore(root: root.appendingPathComponent("a")), b = NotebookStore(root: root.appendingPathComponent("b")), actor = UUID()
    let header = try a.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    try b.prepareEmptyWorkspace(workspaceID: header.workspaceID)
    let initial = try #require(a.changeJournal(after: 0).first)
    try stage(initial, a, b)
    _ = try b.applyRemoteChange(initial, peerID: actor)
    try body(a, b, actor, header)
  }

  private func stage(_ change: NotebookDurableChange, _ a: NotebookStore, _ b: NotebookStore) throws {
    while true {
      let hashes = try b.missingBlobHashes(for: change)
      if hashes.isEmpty { return }
      for hash in hashes {
        let size = try a.blobSize(hash: hash)
        var data = Data()
        while Int64(data.count) < size { data += try a.readBlobChunk(hash: hash, offset: Int64(data.count), maxBytes: 1_048_576) }
        try b.stageBlob(data: data, expectedHash: hash)
      }
    }
  }

  private func measured(_ change: NotebookDurableChange, _ store: NotebookStore, _ peer: UUID) throws -> ReplicationWindowTrace {
    let trace = ReplicationWindowTrace()
    try withExtendedLifetime(trace) {
      try store.commandTransaction {
        sqlite3_trace_v2(store.currentSQL!.handle, UInt32(SQLITE_TRACE_STMT | SQLITE_TRACE_ROW | SQLITE_TRACE_PROFILE), { event, context, statement, _ in
          guard let context, let statement else { return 0 }
          Unmanaged<ReplicationWindowTrace>.fromOpaque(context).takeUnretainedValue().record(event, OpaquePointer(statement))
          return 0
        }, Unmanaged.passUnretained(trace).toOpaque())
        _ = try store.applyRemoteChange(change, peerID: peer)
      }
    }
    return trace
  }

  private func receiptFile(_ id: UUID) -> String { "collaboration/delivery/" + id.uuidString.lowercased() + ".json" }

  @Test func oneAtomicPacketReadsAtMostOneManifestPageAcrossIndependentReceipts() throws {
    try fixture { a, b, actor, header in
      let receipts = (0..<513).map { _ in DeviceActionReceipt(id: UUID(), deviceID: actor) }
      try a.publishRecords(writes: Dictionary(uniqueKeysWithValues: receipts.map { (receiptFile($0.id), try JSONValue.encode($0)) }))
      let change = try #require(a.changeJournal(after: header.cursor).first)
      try stage(change, a, b)
      let before = try b.currentChangeCursor(), trace = try measured(change, b, actor)
      #expect(trace.maximumManifestRows > 0 && trace.maximumManifestRows <= 64)
      #expect(trace.manifestQueries >= receipts.count, "Each independent owner is released before the next indexed read")
      #expect(try b.currentChangeCursor() == before + 1)
      for receipt in receipts { #expect(try b.storedValue(receiptFile(receipt.id))?.decode(DeviceActionReceipt.self) == receipt) }
      _ = try b.applyRemoteChange(change, peerID: actor)
      #expect(try b.currentChangeCursor() == before + 1)
    }
  }

  @Test func anInvalidLastOwnerRollsBackAllEarlierPublicationsAndAcknowledgement() throws {
    try fixture { a, b, actor, header in
      let receipts = (0..<129).map { _ in DeviceActionReceipt(id: UUID(), deviceID: actor) }
      try a.publishRecords(writes: Dictionary(uniqueKeysWithValues: receipts.map { (receiptFile($0.id), try JSONValue.encode($0)) }))
      let valid = try #require(a.changeJournal(after: header.cursor).first)
      try stage(valid, a, b)
      let original = try b.commandTransaction { try JSONDecoder().decode(NotebookChangeManifest.self, from: b.currentSQL!.blob(valid.manifestHash)) }
      #expect(original.parts.isEmpty)
      let invalid = try b.commandTransaction {
        let rows = try NotebookRecordCodec.encode(.bool(true), file: "zz-rejected.json")
        let hash = try b.currentSQL!.putBlob(NotebookStore.storageEncoder.encode(rows[0]))
        let manifest = NotebookChangeManifest(transactionID: UUID(), workspaceID: header.workspaceID,
          records: original.records + [.init(address: rows[0].address, blobHash: hash)])
        let bytes = try NotebookStore.storageEncoder.encode(manifest)
        return NotebookDurableChange(sequence: valid.sequence, transactionID: manifest.transactionID,
          manifestHash: try b.currentSQL!.putBlob(bytes), byteCount: bytes.count)
      }
      let before = try b.currentChangeCursor()
      #expect(throws: NotebookStorageError.self) { try b.applyRemoteChange(invalid, peerID: actor) }
      #expect(try b.currentChangeCursor() == before)
      #expect(try b.peerCursor(peerID: actor, direction: .incoming) == header.cursor)
      for receipt in receipts { #expect(try b.storedValue(receiptFile(receipt.id)) == nil) }
      _ = try b.applyRemoteChange(valid, peerID: actor)
      #expect(try b.currentChangeCursor() == before + 1)
    }
  }

  @Test func requestChecksArePagedAndRetainThePriorExecutionWithoutRereadingOldChunks() throws {
    try fixture { a, b, actor, header in
      let target = CollaborationTarget(kind: .page, id: try #require(a.loadIndex().selectedPageID))
      let files = try a.referenceSourceFiles(target: target)
      let reference = CollaborationReference(target: target, revision: try NotebookStore.referenceRevision(target: target, files: files))
      var executions: [AgentExecution] = []
      try a.commandTransaction {
        for _ in 0..<65 {
          let context = try a.appendContext(references: [reference], author: .human, actor: actor, text: "Question")
          let id = UUID(), source = try AgentPinnedSource.capture(requestID: id, reference: reference, files: files)
          let request = AgentRequest(id: id, contextID: context.id, questionEntryID: context.entry.id,
            grant: try .init(mode: .question, references: [reference]), authorDeviceID: actor, sourceIDs: [source.id])
          let execution = AgentExecution(requestID: id, executionID: UUID(), status: .running,
            stamp: .init(counter: 1, actor: actor), responseSequence: 1, responseBytes: 1, receiptIDs: [])
          let chunk = AgentResponseChunk(requestID: id, executionID: execution.executionID, sequence: 1, text: "A")
          try a.publishRecords(writes: [a.agentRequestFile(id): .encode(request), a.agentSourceFile(id, source.id): .encode(source),
            a.agentExecutionFile(id): .encode(execution), a.agentChunkFile(id, 1): .encode(chunk)])
          executions.append(execution)
        }
      }
      let first = try #require(a.changeJournal(after: header.cursor).first)
      try stage(first, a, b)
      let firstTrace = try measured(first, b, actor)
      #expect(firstTrace.maximumRequestRows == 64 && firstTrace.requestQueries >= 3)
      try b.commandTransaction {
        for execution in executions {
          let address = b.agentChunkFile(execution.requestID, 1) + "#"
          let hash = try #require(b.currentSQL!.rows("SELECT hash FROM records WHERE address=?", [.text(address)]).first?[0].text)
          try b.currentSQL!.run("UPDATE blobs SET data=? WHERE hash=?", [.blob(Data("not readable history".utf8)), .text(hash)])
        }
      }
      try a.commandTransaction {
        for var execution in executions {
          execution.responseSequence = 2; execution.responseBytes = 2
          execution.stamp = .init(counter: 2, actor: actor)
          let chunk = AgentResponseChunk(requestID: execution.requestID, executionID: execution.executionID, sequence: 2, text: "B")
          try a.publishRecords(writes: [a.agentExecutionFile(execution.requestID): .encode(execution),
            a.agentChunkFile(execution.requestID, 2): .encode(chunk)])
        }
      }
      let next = try #require(a.changeJournal(after: first.sequence).first)
      try stage(next, a, b)
      let trace = try measured(next, b, actor)
      #expect(trace.maximumRequestRows == 64 && trace.requestQueries >= 3)
      #expect(trace.maximumManifestRows <= 64)
      for execution in executions {
        #expect(try b.storedValue(b.agentExecutionFile(execution.requestID))?.decode(AgentExecution.self).responseBytes == 2)
      }
    }
  }
}

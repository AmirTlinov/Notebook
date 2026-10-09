import Foundation
import Testing
@testable import NotebookCore

@Suite("Native inverse allocation belongs to one transaction", .serialized)
struct NotebookNativeWriteAllowanceTests {
  private func fixture(_ body: (NotebookStore, UUID) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-memory-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    try body(store, store.workspaceHeader().workspaceID)
  }

  private func records(_ count: Int, offset: Int = 0) -> [NotebookActionRecordChange] {
    (offset..<offset + count).map {
      .init(address: "pages/old.json#/elements/@" + String(format: "%06d", $0),
        beforeHash: String(repeating: "a", count: 64), afterHash: nil)
    }
  }

  @Test func escapedUTF8KeepsExactCreditAndACaughtCumulativeRefusalStillRollsBack() async throws {
    try await Task.detached {
      try fixture { store, _ in
        let text = "\0\t\n\"\\/Пример 🖋️", utf16 = Array(text.utf16)
        let bridged = utf16.withUnsafeBufferPointer {
          NSString(characters: $0.baseAddress!, length: $0.count) as String
        }
        // Scalar/string headers, three controls, three escaped ASCII bytes,
        // then twenty literal UTF-8 bytes. Both String representations pay it.
        let phaseBytes = 704 + 528 + 3 * 48 + 3 * 16 + 20 * 8
        func allowance(_ bytes: Int) -> NotebookSQLReadAllowance {
          .init(rows: 1_024, bytes: 1_048_576, valueBytes: 1_048_576,
            reason: "resource_limit", jsonDecodeBytes: bytes)
        }
        for source in [text, bridged] {
          try store.commandTransaction(readAllowance: allowance(phaseBytes * 2)) {
            try store.currentSQL!.admitNativeJSONPhase(.string(source), copies: 2)
          }
          var firstAdmitted = false, refusalCaught = false, commandRefused = false
          do {
            try store.commandTransaction(readAllowance: allowance(phaseBytes * 2 - 1)) {
              let database = store.currentSQL!
              try database.admitNativeJSONPhase(.string(source))
              firstAdmitted = true
              try database.run("INSERT INTO metadata(key,value) VALUES('utf8_admission_provisional','must rollback')")
              do { try database.admitNativeJSONPhase(.string(source)) }
              catch NotebookStorageError.limitExceeded { refusalCaught = true }
            }
            Issue.record("A caught cumulative refusal must veto COMMIT")
          } catch NotebookStorageError.limitExceeded { commandRefused = true }
          #expect(firstAdmitted && refusalCaught && commandRefused)
          try store.readTransaction { _ in
            let rows = try store.currentSQL!.rows("SELECT value FROM metadata WHERE key='utf8_admission_provisional'")
            #expect(rows.isEmpty)
          }
        }
        var cancelled = false
        do {
          try store.readTransaction { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            try store.currentSQL!.admitNativeJSONPhase(.string(bridged))
          }
        } catch is CancellationError { cancelled = true }
        #expect(cancelled)
        // The same cancelled caller can finish an already accepted writer.
        try store.commandTransaction(readAllowance: allowance(phaseBytes)) {
          try store.currentSQL!.admitNativeJSONPhase(.string(text))
        }
      }
    }.value
  }

  @Test func rootAndPartsShareAdmissionAndCaughtExhaustionRollsBackTheWholeCommand() throws {
    try fixture { store, workspace in
      let id = UUID()
      let parts = try (0..<2).map { ordinal in
        try NotebookStore.storageEncoder.encode(NotebookLifecycleInversePart(format: 1,
          workspaceID: workspace, actionID: id, ordinal: ordinal,
          records: records(64, offset: ordinal * 64)))
      }
      let reference = try store.commandTransaction {
        let hashes = try parts.map { try store.currentSQL!.putBlob($0) }
        let root = NotebookLifecycleInverseRoot(format: 1, workspaceID: workspace,
          actionID: id, recordCount: 128, parts: hashes)
        return try NotebookLifecycleInverseReference(
          rootHash: store.currentSQL!.putBlob(NotebookStore.storageEncoder.encode(root)), recordCount: 128)
      }
      let rootData = try store.readTransaction { _ in try store.currentSQL!.blob(reference.rootHash) }
      let rootCost = try NotebookJSONAdmission.allocationCost(rootData,
        maximumBytes: NotebookNativeWriteAllowance.maximumExecutionBytes) + rootData.count * 2
      let partCost = try NotebookJSONAdmission.allocationCost(parts[0],
        maximumBytes: NotebookNativeWriteAllowance.maximumExecutionBytes) + parts[0].count * 2
      let cursor = try store.currentChangeCursor()
      var firstAdmitted = false, refusalCaught = false
      do {
        try store.withNativeWriteAllowance {
          let db = store.currentSQL!
          try db.limitReads(.init(rows: 1_024, bytes: 8 * 1_024 * 1_024,
            valueBytes: 2 * 1_024 * 1_024, reason: "resource_limit",
            jsonDecodeBytes: rootCost + partCost + partCost / 2))
          let root = try store.readLifecycleInverseRoot(reference: reference, actionID: id)
          _ = try store.readLifecycleInversePart(hash: root.parts[0], actionID: id, ordinal: 0)
          firstAdmitted = true
          try db.run("INSERT INTO metadata(key,value) VALUES('native_memory_provisional','must rollback')")
          do { _ = try store.readLifecycleInversePart(hash: root.parts[1], actionID: id, ordinal: 1) }
          catch NotebookStorageError.limitExceeded { refusalCaught = true }
        }
        Issue.record("A caught allocation refusal must still veto COMMIT")
      } catch let error as CollaborationError { #expect(error.code == "resource_limit") }
      #expect(firstAdmitted && refusalCaught)
      #expect(try store.currentChangeCursor() == cursor)
      try store.readTransaction { _ in
        let rows = try store.currentSQL!.rows("SELECT value FROM metadata WHERE key='native_memory_provisional'")
        #expect(rows.isEmpty)
      }
    }
  }

  @Test func oldFormatPartStaysReadableAndATightenedNativeCutRefusesWithoutTruncation() throws {
    try fixture { store, workspace in
      let id = UUID()
      let data = try NotebookStore.storageEncoder.encode(NotebookLifecycleInversePart(format: 1,
        workspaceID: workspace, actionID: id, ordinal: 0, records: records(NotebookLifecycleInverseLimits.partRecords)))
      #expect(data.count > NotebookLifecycleInverseLimits.writtenPartBytes)
      let hash = try store.commandTransaction { try store.currentSQL!.putBlob(data) }
      try store.readTransaction { _ in
        let part = try store.readLifecycleInversePart(hash: hash, actionID: id, ordinal: 0)
        #expect(part.format == 1 && part.records.count == NotebookLifecycleInverseLimits.partRecords)
      }
      let cursor = try store.currentChangeCursor()
      do {
        try store.withNativeWriteAllowance(.init(executionBytes: 1_024 * 1_024)) {
          try store.currentSQL!.run("INSERT INTO metadata(key,value) VALUES('old_part_provisional','must rollback')")
          _ = try store.readLifecycleInversePart(hash: hash, actionID: id, ordinal: 0)
        }
        Issue.record("An old valid part does not enlarge the native command's memory allowance")
      } catch let error as CollaborationError { #expect(error.code == "resource_limit") }
      #expect(try store.currentChangeCursor() == cursor)
      try store.readTransaction { _ in
        let rows = try store.currentSQL!.rows("SELECT value FROM metadata WHERE key='old_part_provisional'")
        #expect(rows.isEmpty)
      }
    }
  }
}

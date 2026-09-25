import CSQLite
import Foundation
import Testing
@testable import NotebookCore

private final class ArchitectureSQLWork {
  var steps = 0
  var uploadBytes = 0
  func attach(_ db: NotebookSQLConnection) {
    sqlite3_trace_v2(db.handle, UInt32(SQLITE_TRACE_PROFILE | SQLITE_TRACE_ROW), { event, context, raw, _ in
      guard let context, let raw else { return 0 }
      let owner = Unmanaged<ArchitectureSQLWork>.fromOpaque(context).takeUnretainedValue(), statement = OpaquePointer(raw)
      if event == UInt32(SQLITE_TRACE_PROFILE) { owner.steps += Int(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 1)) }
      if event == UInt32(SQLITE_TRACE_ROW), let sql = sqlite3_sql(statement), String(cString: sql).contains("FROM file_uploads") {
        for column in 0..<sqlite3_column_count(statement) where sqlite3_column_type(statement, column) == SQLITE_BLOB {
          owner.uploadBytes += Int(sqlite3_column_bytes(statement, column))
        }
      }
      return 0
    }, Unmanaged.passUnretained(self).toOpaque())
  }
  func detach(_ db: NotebookSQLConnection) { sqlite3_trace_v2(db.handle, 0, nil, nil) }
}

@Suite("Durable delivery bounded work", .serialized)
struct NotebookArchitectureDeliveryTests {
  private func fixture(_ body: (NotebookStore, UUID) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    try body(store, actor)
  }

  @Test func maximalUploadWritesOnlyTheCurrentChunkAndRetryReadsOnlyItsSlice() throws {
    try fixture { store, actor in
      let address = NotebookFileAddress(computer: UUID(), project: "project", root: "/tmp/project", path: "main.py")
      let text = String(repeating: "\t", count: NotebookFileVersion.maximumBytes)
      let edit = NotebookFileEdit(address: address, base: text, text: text)
      let payload = try JSONEncoder().encode(edit), id = UUID(), hash = NotebookFileVersion.hash(payload)
      let trace = ArchitectureSQLWork()
      var chunks = 0
      try store.commandTransaction(advancesReadRevision: false) { () throws -> Void in
        let db = store.currentSQL!
        trace.attach(db); defer { trace.detach(db) }
        for offset in stride(from: 0, to: payload.count, by: NotebookFileVersion.chunkBytes) {
          let end = min(payload.count, offset + NotebookFileVersion.chunkBytes)
          let chunk = NotebookFileUpload(id: id, digest: hash, total: payload.count, offset: offset, data: payload.subdata(in: offset..<end))
          #expect(try store.stageFileUpload(chunk, author: actor) == end)
          #expect(try store.stageFileUpload(chunk, author: actor) == end)
          chunks += 1
        }
      }
      #expect(trace.uploadBytes == payload.count, "Only explicit retries read data, exactly once per chunk")
      #expect(trace.steps < chunks * 150)
      #expect(try NotebookStore(root: store.root).stagedFileEdit(id, author: actor) == edit)
      print("FILE_UPLOAD payload=\(payload.count) chunks=\(chunks) sql_blob_read_bytes=\(trace.uploadBytes) sql_vm_steps=\(trace.steps)")
    }
  }

  @Test func causalCountAdmissionPreservesContentAndTracksInsertUpdateMoveDelete() throws {
    enum Rollback: Error { case fixture }
    try fixture { store, _ in
      let proof = try store.archiveContentProof(), cursor = try store.currentChangeCursor()
      try store.commandTransaction(advancesReadRevision: false) {
        let db = store.currentSQL!
        for name in ["insert", "delete", "update"] { try db.run("DROP TRIGGER causal_count_" + name) }
        try db.run("DROP TABLE causal_field_counts")
        try db.run("PRAGMA user_version=23")
      }
      let reopened = NotebookStore(root: store.root)
      try reopened.prepare()
      #expect(try reopened.archiveContentProof() == proof && reopened.currentChangeCursor() == cursor)
      #expect(throws: Rollback.self) {
        try reopened.commandTransaction {
          let db = reopened.currentSQL!
          func counts(_ sql: String) throws -> [String] {
            try db.rows(sql).map { $0[0].text! + "|" + $0[1].text! + "|" + String($0[2].integer!) }
          }
          let original = try counts("SELECT parent,collection,COUNT(*) FROM records WHERE collection IN ('collaboration/fields','board/collaboration/fields') GROUP BY parent,collection ORDER BY parent,collection")
          #expect(try counts("SELECT parent,collection,count FROM causal_field_counts ORDER BY parent,collection") == original)
          let hash = try #require(db.rows("SELECT hash FROM records LIMIT 1").first?[0].text)
          // This rollback-only fixture addresses the index writer itself; no
          // synthetic metadata becomes admitted application content.
          try db.run("INSERT INTO records(address,file,parent,collection,member,position,hash) VALUES('probe#/@field','probe','one','collaboration/fields','x',0,?)", [.text(hash)])
          #expect(try db.rows("SELECT count FROM causal_field_counts WHERE parent='one'").first?[0].integer == 1)
          try db.run("INSERT INTO records(address,file,parent,collection,member,position,hash) VALUES('probe#/@field','probe','one','collaboration/fields','x',0,?) ON CONFLICT(address) DO UPDATE SET parent=excluded.parent,collection=excluded.collection,member=excluded.member,position=excluded.position,hash=excluded.hash", [.text(hash)])
          #expect(try db.rows("SELECT count FROM causal_field_counts WHERE parent='one'").first?[0].integer == 1)
          try db.run("UPDATE records SET parent='two',collection='board/collaboration/fields' WHERE address='probe#/@field'")
          #expect(try db.rows("SELECT count FROM causal_field_counts WHERE parent='one'").isEmpty)
          #expect(try db.rows("SELECT count FROM causal_field_counts WHERE parent='two'").first?[0].integer == 1)
          try db.run("UPDATE records SET collection='elements' WHERE address='probe#/@field'")
          #expect(try db.rows("SELECT count FROM causal_field_counts WHERE parent='two'").isEmpty)
          try db.run("UPDATE records SET collection='board/collaboration/fields' WHERE address='probe#/@field'")
          #expect(try db.rows("SELECT count FROM causal_field_counts WHERE parent='two'").first?[0].integer == 1)
          try db.run("DELETE FROM records WHERE address='probe#/@field'")
          #expect(try counts("SELECT parent,collection,count FROM causal_field_counts ORDER BY parent,collection") == original)
          throw Rollback.fixture
        }
      }
      #expect(try reopened.archiveContentProof() == proof && reopened.currentChangeCursor() == cursor)
    }
  }

  @Test func prefixMigrationPreservesBinaryBytesIdentityAndIncompleteProgress() throws {
    try fixture { store, actor in
      let id = UUID(), prefix = Data([0, 255, 128, 0, 10]), total = 100
      let hash = NotebookFileVersion.hash(prefix), touched = 1234.0
      try store.commandTransaction(advancesReadRevision: false) {
        let db = store.currentSQL!
        try db.run("ALTER TABLE file_uploads DROP COLUMN received")
        try db.run("INSERT INTO file_uploads(id,author,digest,total,value,touched) VALUES(?,?,?,?,?,?)", [.text(id.uuidString), .text(actor.uuidString), .text(hash), .integer(Int64(total)), .blob(prefix), .real(touched)])
        try db.run("PRAGMA user_version=23")
      }
      let reopened = NotebookStore(root: store.root)
      try reopened.prepare()
      try reopened.sqlRead { db in
        let row = try #require(db.rows("SELECT author,digest,total,received,value,touched FROM file_uploads WHERE id=?", [.text(id.uuidString)]).first)
        #expect(row[0].text == actor.uuidString && row[1].text == hash && row[2].integer == Int64(total))
        #expect(row[3].integer == Int64(prefix.count) && row[4].blob == prefix + Data(count: total - prefix.count))
        #expect(row[5].spatialNumber == touched)
      }
      #expect(try reopened.stageFileUpload(.init(id: id, digest: hash, total: total, offset: 0, data: prefix), author: actor) == prefix.count)
      #expect(throws: NotebookStorageError.self) { try reopened.stagedFileEdit(id, author: actor) }
      #expect(throws: NotebookStorageError.self) {
        try reopened.stageFileUpload(.init(id: id, digest: hash, total: total, offset: 1, data: Data([1])), author: actor)
      }
      #expect(throws: NotebookStorageError.self) {
        try reopened.stageFileUpload(.init(id: id, digest: hash, total: total, offset: 9, data: Data([1])), author: actor)
      }
      let tail = Data([7, 8, 9])
      #expect(try reopened.stageFileUpload(.init(id: id, digest: hash, total: total, offset: prefix.count, data: tail), author: actor) == prefix.count + tail.count)
    }
  }
}

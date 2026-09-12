import Foundation

extension NotebookStore {
  public func runRecord(_ id: UUID) throws -> NotebookRunRecord? {
    try sqlRead { db in try db.rows("SELECT value FROM project_runs WHERE id=?", [.text(id.uuidString)]).first.map {
      try JSONDecoder().decode(NotebookRunRecord.self, from: $0[0].blob!)
    } }
  }
  public func activeRuns() throws -> [NotebookRunRecord] {
    try sqlRead { db in try db.rows("SELECT value FROM project_runs WHERE active=1 ORDER BY ordinal LIMIT 4").map {
      try JSONDecoder().decode(NotebookRunRecord.self, from: $0[0].blob!)
    } }
  }
  public func latestRun(root: NotebookFileAddress) throws -> NotebookRunRecord? {
    try sqlRead { db in try db.rows("SELECT value FROM project_runs WHERE root=? ORDER BY ordinal DESC LIMIT 1", [.text(root.id)]).first.map {
      try JSONDecoder().decode(NotebookRunRecord.self, from: $0[0].blob!)
    } }
  }
  public func admitRun(_ record: NotebookRunRecord) throws {
    guard record.request.isValid, record.phase == .starting else { throw NotebookStorageError.invalidTransaction("run request") }
    try commandTransaction(advancesReadRevision: false) {
      if let previous = try runRecord(record.id) {
        guard previous.request == record.request, previous.author == record.author else { throw NotebookStorageError.transactionConflict }
        return
      }
      let active = try activeRuns()
      guard active.count < 4, !active.contains(where: { $0.request.root == record.request.root }) else {
        throw NotebookStorageError.invalidTransaction("Проект уже выполняется либо заняты четыре запуска.")
      }
      try currentSQL!.run("INSERT INTO project_runs(id,root,active,value) VALUES(?,?,1,?)", [
        .text(record.id.uuidString), .text(record.request.root.id), .blob(try Self.storageEncoder.encode(record))])
      // Finished history is finite; removing it also removes its output chunks.
      try currentSQL!.run("DELETE FROM project_runs WHERE active=0 AND ordinal NOT IN (SELECT ordinal FROM project_runs ORDER BY ordinal DESC LIMIT 24)")
    }
  }
  public func receiveRunEvent(_ id: UUID, _ event: NotebookProcessEvent) throws {
    try commandTransaction(advancesReadRevision: false) {
      guard var record = try runRecord(id), record.isActive else { return }
      let db = currentSQL!
      switch event {
      case .running: record.phase = .running
      case .exited(let code): record.phase = .exited; record.exitCode = code
      case .interrupted(let message): record.phase = .interrupted; record.error = String(message.prefix(4096))
      case .output(let data):
        guard data.count <= 131_072 else { throw NotebookStorageError.limitExceeded("process output frame") }
        let row = try db.rows("SELECT last_sequence,output_bytes FROM project_runs WHERE id=?", [.text(id.uuidString)])[0]
        var sequence = UInt64(row[0].integer!), bytes = Int(row[1].integer!)
        for offset in stride(from: 0, to: data.count, by: 8192) {
          guard sequence < VersionStamp.maximumCounter else { throw NotebookStorageError.limitExceeded("process output sequence") }
          sequence += 1
          let chunk = data.subdata(in: offset..<min(data.count, offset + 8192)); bytes += chunk.count
          try db.run("INSERT INTO run_output(run,sequence,value) VALUES(?,?,?)", [.text(id.uuidString), .integer(Int64(sequence)), .blob(chunk)])
        }
        while bytes > 1_048_576 {
          guard let first = try db.rows("SELECT sequence,length(value) FROM run_output WHERE run=? ORDER BY sequence LIMIT 1", [.text(id.uuidString)]).first else { break }
          bytes -= Int(first[1].integer!)
          try db.run("DELETE FROM run_output WHERE run=? AND sequence=?", [.text(id.uuidString), .integer(first[0].integer!)])
        }
        try db.run("UPDATE project_runs SET last_sequence=?,output_bytes=? WHERE id=?", [.integer(Int64(sequence)), .integer(Int64(bytes)), .text(id.uuidString)])
        record.phase = .running
      }
      try db.run("UPDATE project_runs SET active=?,value=? WHERE id=?", [.integer(record.isActive ? 1 : 0), .blob(try Self.storageEncoder.encode(record)), .text(id.uuidString)])
    }
  }
  public func readRun(_ query: NotebookRunRead) throws -> NotebookRunOutput {
    guard query.isValid else { throw NotebookStorageError.invalidTransaction("process read") }
    return try readTransaction { _ in
      guard let record = try latestRun(root: query.root) else { return .init(record: nil) }
      let after = query.runID == record.id ? UInt64(query.after)! : 0
      let db = currentSQL!, first = try db.rows("SELECT MIN(sequence),MAX(sequence) FROM run_output WHERE run=?", [.text(record.id.uuidString)])[0]
      let rows = try db.rows("SELECT sequence,value FROM run_output WHERE run=? AND sequence>? ORDER BY sequence LIMIT 6", [.text(record.id.uuidString), .integer(Int64(after))])
      var data = Data(); for row in rows { data.append(row[1].blob!) }
      let last = rows.last?[0].integer.map(UInt64.init) ?? after
      return .init(record: record, data: data, after: String(last),
        lostPrefix: first[0].integer.map { UInt64($0) > after + 1 } ?? false,
        more: first[1].integer.map { UInt64($0) > last } ?? false)
    }
  }
  public func runCommand(root: NotebookFileAddress) throws -> String {
    try sqlRead { try $0.rows("SELECT command FROM run_commands WHERE root=?", [.text(root.id)]).first?[0].text ?? "" }
  }
  public func saveRunCommand(_ command: String, root: NotebookFileAddress) throws {
    guard root.isValid, root.path.isEmpty, command.utf8.count <= 8192, !command.contains("\0") else { throw NotebookStorageError.invalidTransaction("run command") }
    try commandTransaction(advancesReadRevision: false) {
      try currentSQL!.run("INSERT INTO run_commands(root,command) VALUES(?,?) ON CONFLICT(root) DO UPDATE SET command=excluded.command", [.text(root.id), .text(command)])
    }
  }
}

import CSQLite
import Foundation

extension NotebookStore {
  public func fileDraft(_ address: NotebookFileAddress) throws -> NotebookFileDraft? {
    try sqlRead { db in try db.rows("SELECT value FROM file_drafts WHERE id=?", [.text(address.id)]).first.map {
      try JSONDecoder().decode(NotebookFileDraft.self, from: $0[0].blob!)
    } }
  }
  public func saveFileDraft(_ draft: NotebookFileDraft) throws {
    guard draft.isValid else { throw NotebookStorageError.invalidTransaction("invalid file draft") }
    try commandTransaction(advancesReadRevision: false) {
      try currentSQL!.run("INSERT INTO file_drafts(id,value) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value", [.text(draft.address.id), .blob(try Self.storageEncoder.encode(draft))])
    }
  }
  public func fileWindow(author: UUID, computer: UUID? = nil) throws -> NotebookFileWindowState {
    try sqlRead { db in
      let key = try chatScope(author: author, computer: computer ?? activeChatComputer(author: author))
      return try db.rows("SELECT value FROM file_window WHERE id=?", [.text(key)]).first.map {
      try JSONDecoder().decode(NotebookFileWindowState.self, from: $0[0].blob!)
    } ?? .init() }
  }
  public func saveFileWindow(_ state: NotebookFileWindowState, author: UUID, computer: UUID? = nil) throws {
    guard state.selected?.isValid != false else { throw NotebookStorageError.invalidTransaction("invalid file selection") }
    try commandTransaction(advancesReadRevision: false) {
      try currentSQL!.run("INSERT INTO file_window(id,value) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value", [.text(try chatScope(author: author, computer: computer ?? activeChatComputer(author: author))), .blob(try Self.storageEncoder.encode(state))])
    }
  }
  public func saveFileSubmission(_ input: NotebookChatInput, draft: NotebookFileDraft) throws -> NotebookChatJob {
    guard case .saveFile(let address) = input.action, address == draft.address, draft.pending == input.id else { throw NotebookStorageError.invalidTransaction("file submission identity") }
    return try commandTransaction(advancesReadRevision: false) {
      let job = try saveChatInput(input, to: address.computer); try saveFileDraft(draft); return job
    }
  }
  @discardableResult public func cacheFileVersion(_ data: Data, address: NotebookFileAddress) throws -> NotebookFileVersion {
    guard data.count <= NotebookFileVersion.maximumBytes else { throw NotebookStorageError.limitExceeded("file size") }
    let version = NotebookFileVersion(data)
    try commandTransaction(advancesReadRevision: false) {
      try currentSQL!.run("INSERT INTO file_versions(hash,value,touched) VALUES(?,?,?) ON CONFLICT(hash) DO UPDATE SET touched=excluded.touched", [.text(version.hash), .blob(data), .real(Date().timeIntervalSince1970)])
      try currentSQL!.run("INSERT OR IGNORE INTO file_version_files(address,hash) VALUES(?,?)", [.text(address.id), .text(version.hash)])
      // Published results pin their immutable bytes. Only unreferenced reading
      // snapshots are evicted; a late receipt cannot name someone else's version.
      try currentSQL!.run("DELETE FROM file_versions WHERE hash NOT IN (SELECT before_hash FROM file_commits UNION SELECT after_hash FROM file_commits) AND hash NOT IN (SELECT hash FROM file_versions ORDER BY touched DESC LIMIT 32)")
    }
    return version
  }
  public func filePart(_ version: NotebookFileVersion, address: NotebookFileAddress, offset: Int) throws -> NotebookFilePart {
    guard version.isValid, offset >= 0, offset <= version.size else { throw NotebookStorageError.invalidTransaction("invalid file offset") }
    return try sqlRead { db in
      guard let row = try db.rows("SELECT length(value),substr(value,?,?) FROM file_versions WHERE hash=? AND EXISTS(SELECT 1 FROM file_version_files WHERE address=? AND hash=file_versions.hash)", [.integer(Int64(offset + 1)), .integer(Int64(NotebookFileVersion.chunkBytes)), .text(version.hash), .text(address.id)]).first,
        row[0].integer == Int64(version.size), let data = row[1].blob else { throw NotebookStorageError.invalidTransaction("Версия файла больше не доступна; прочитайте файл заново.") }
      return .init(version: version, offset: offset, data: data)
    }
  }
  public func stageFileUpload(_ chunk: NotebookFileUpload, author: UUID) throws -> Int {
    guard chunk.isValid else { throw NotebookStorageError.invalidTransaction("invalid file upload") }
    return try commandTransaction(advancesReadRevision: false) {
      let db = currentSQL!
      let rowID: Int64
      if let row = try db.rows("SELECT rowid,author,digest,total,received,length(value) FROM file_uploads WHERE id=?", [.text(chunk.id.uuidString)]).first {
        guard row[1].text == author.uuidString, row[2].text == chunk.digest,
          row[3].integer == Int64(chunk.total), row[5].integer == Int64(chunk.total),
          let received = row[4].integer, received >= 0, received <= Int64(chunk.total) else {
          throw NotebookStorageError.invalidTransaction("file upload collision")
        }
        if chunk.offset < received {
          guard Int64(chunk.offset + chunk.data.count) <= received,
            try db.rows("SELECT substr(value,?,?) FROM file_uploads WHERE id=?", [.integer(Int64(chunk.offset + 1)), .integer(Int64(chunk.data.count)), .text(chunk.id.uuidString)]).first?[0].blob == chunk.data else {
            throw NotebookStorageError.invalidTransaction("file upload changed")
          }
          return Int(received)
        }
        guard chunk.offset == received else { throw NotebookStorageError.invalidTransaction("file upload gap") }
        rowID = row[0].integer!
      } else {
        guard chunk.offset == 0 else { throw NotebookStorageError.invalidTransaction("file upload missing") }
        try db.run("DELETE FROM file_uploads WHERE touched<? AND id NOT IN (SELECT id FROM chat_jobs WHERE state IN ('saved','attempting','uncertain'))", [.real(Date().addingTimeInterval(-604800).timeIntervalSince1970)])
        guard try db.rows("SELECT COUNT(*) FROM file_uploads WHERE id NOT IN (SELECT id FROM chat_jobs WHERE state='accepted')")[0][0].integer! < 32 else { throw NotebookStorageError.limitExceeded("unfinished file uploads") }
        try db.run("INSERT INTO file_uploads(id,author,digest,total,value,received,touched) VALUES(?,?,?,?,zeroblob(?),0,?)", [.text(chunk.id.uuidString), .text(author.uuidString), .text(chunk.digest), .integer(Int64(chunk.total)), .integer(Int64(chunk.total)), .real(Date().timeIntervalSince1970)])
        rowID = sqlite3_last_insert_rowid(db.handle)
      }
      // Allocation happens once. Each admitted chunk writes only its own bytes;
      // the blob handle must close before updating the same row's progress.
      try Self.writeFileUpload(chunk.data, at: chunk.offset, rowID: rowID, database: db)
      let received = chunk.offset + chunk.data.count
      try db.run("UPDATE file_uploads SET received=?,touched=? WHERE rowid=?", [.integer(Int64(received)), .real(Date().timeIntervalSince1970), .integer(rowID)])
      return received
    }
  }

  private static func writeFileUpload(_ data: Data, at offset: Int, rowID: Int64, database: NotebookSQLConnection) throws {
    var blob: OpaquePointer?
    guard sqlite3_blob_open(database.handle, "main", "file_uploads", "value", rowID, 1, &blob) == SQLITE_OK,
      let blob else { throw NotebookStorageError.corruptRecord("file upload blob") }
    defer { sqlite3_blob_close(blob) }
    guard offset >= 0, offset + data.count <= Int(sqlite3_blob_bytes(blob)),
      data.withUnsafeBytes({ sqlite3_blob_write(blob, $0.baseAddress, Int32(data.count), Int32(offset)) }) == SQLITE_OK else {
      throw NotebookStorageError.corruptRecord("file upload write")
    }
  }

  public func stagedFileEdit(_ id: UUID, author: UUID) throws -> NotebookFileEdit {
    try sqlRead { db in
      guard let row = try db.rows("SELECT digest,total,value FROM file_uploads WHERE id=? AND author=? AND received=total", [.text(id.uuidString), .text(author.uuidString)]).first,
        let data = row[2].blob, row[1].integer == Int64(data.count), row[0].text == NotebookFileVersion.hash(data) else { throw NotebookStorageError.invalidTransaction("Неполная отправка черновика; рабочий файл не изменён.") }
      let edit = try JSONDecoder().decode(NotebookFileEdit.self, from: data)
      guard edit.isValid else { throw NotebookStorageError.invalidTransaction("invalid file edit") }; return edit
    }
  }
  public func prepareFileCommit(_ id: UUID, address: NotebookFileAddress, before: Data, after: Data) throws {
    try commandTransaction(advancesReadRevision: false) {
      let old = try cacheFileVersion(before, address: address), new = try cacheFileVersion(after, address: address)
      try currentSQL!.run("INSERT INTO file_commits(id,address,before_hash,after_hash) VALUES(?,?,?,?)", [.text(id.uuidString), .blob(try Self.storageEncoder.encode(address)), .text(old.hash), .text(new.hash)])
    }
  }
  public func fileCommit(_ id: UUID) throws -> (address: NotebookFileAddress, hash: String, result: NotebookFileResult?)? {
    try sqlRead { db in try db.rows("SELECT address,after_hash,result FROM file_commits WHERE id=?", [.text(id.uuidString)]).first.map {
      (try JSONDecoder().decode(NotebookFileAddress.self, from: $0[0].blob!), $0[1].text!, try $0[2].blob.map { try JSONDecoder().decode(NotebookFileResult.self, from: $0) })
    } }
  }
  public func finishFileCommit(_ id: UUID, result: NotebookFileResult) throws {
    try commandTransaction(advancesReadRevision: false) {
      guard let commit = try fileCommit(id), commit.address == result.address, commit.hash == result.version.hash,
        commit.result == nil || commit.result == result else { throw NotebookStorageError.invalidTransaction("file result identity") }
      try currentSQL!.run("UPDATE file_commits SET result=? WHERE id=?", [.blob(try Self.storageEncoder.encode(result)), .text(id.uuidString)])
    }
  }
  public func prepareFileRename(_ id: UUID, request: NotebookFileRename, identity: Data) throws {
    guard request.isValid, !identity.isEmpty, identity.count <= 1024 else { throw NotebookStorageError.invalidTransaction("rename intent") }
    try commandTransaction(advancesReadRevision: false) {
      guard try fileRename(id) == nil else { throw NotebookStorageError.transactionConflict }
      try currentSQL!.run("INSERT INTO file_renames(id,request,identity) VALUES(?,?,?)",
        [.text(id.uuidString), .blob(try Self.storageEncoder.encode(request)), .blob(identity)])
    }
  }
  public func fileRename(_ id: UUID) throws -> (request: NotebookFileRename, identity: Data, completed: Bool)? {
    try sqlRead { db in try db.rows("SELECT request,identity,completed FROM file_renames WHERE id=?", [.text(id.uuidString)]).first.map {
      (try JSONDecoder().decode(NotebookFileRename.self, from: $0[0].blob!), $0[1].blob!, $0[2].integer == 1)
    } }
  }
  public func finishFileRename(_ id: UUID) throws {
    try commandTransaction {
      guard let intent = try fileRename(id) else { throw NotebookStorageError.invalidTransaction("missing rename intent") }
      guard !intent.completed else { return }
      try relocateCodeFragments(intent.request)
      try currentSQL!.run("UPDATE file_renames SET completed=1 WHERE id=?", [.text(id.uuidString)])
    }
  }
  public func saveFileRenameSubmission(_ input: NotebookChatInput, draft: NotebookFileDraft) throws {
    guard case .renameFile(let request) = input.action, request.address == draft.address, draft.rename == input.id,
      draft.pending == nil else { throw NotebookStorageError.invalidTransaction("rename draft identity") }
    try commandTransaction(advancesReadRevision: false) {
      if let existing = try fileDraft(draft.address)?.rename, existing != input.id { throw NotebookStorageError.transactionConflict }
      _ = try saveChatInput(input, to: request.address.computer); try saveFileDraft(draft)
    }
  }
  /// Moves one local draft after the Mac's durable receipt. A pre-existing draft
  /// at the new path is a real collision; neither independent copy is deleted.
  public func acceptFileRename(_ job: NotebookChatJob) throws -> NotebookFileDraft? {
    guard job.isValid, case .renameFile(let request) = job.input.action, job.isTerminal else { throw NotebookStorageError.invalidTransaction("rename receipt") }
    return try commandTransaction {
      guard var draft = try fileDraft(request.address), draft.rename == job.id else { return nil }
      draft.rename = nil
      guard case .renamed = job.result else { try saveFileDraft(draft); return draft }
      guard try fileDraft(request.destination) == nil else {
        throw CollaborationError("draft_collision", "По новому пути есть другой локальный черновик. Обе копии сохранены; откройте новый файл отдельно.")
      }
      let moved = draft.relocated(to: request.destination)
      try saveFileDraft(moved)
      try currentSQL!.run("DELETE FROM file_drafts WHERE id=?", [.text(request.address.id)])
      try relocateCodeFragments(request)
      var window = try fileWindow(author: job.input.author, computer: request.address.computer)
      if window.selected == request.address { window.selected = request.destination; try saveFileWindow(window, author: job.input.author, computer: request.address.computer) }
      return moved
    }
  }

}

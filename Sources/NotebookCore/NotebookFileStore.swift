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
  public func fileWindow(author: UUID) throws -> NotebookFileWindowState {
    try sqlRead { db in try db.rows("SELECT value FROM file_window WHERE id=?", [.text(author.uuidString)]).first.map {
      try JSONDecoder().decode(NotebookFileWindowState.self, from: $0[0].blob!)
    } ?? .init() }
  }
  public func saveFileWindow(_ state: NotebookFileWindowState, author: UUID) throws {
    guard state.selected?.isValid != false else { throw NotebookStorageError.invalidTransaction("invalid file selection") }
    try commandTransaction(advancesReadRevision: false) {
      try currentSQL!.run("INSERT INTO file_window(id,value) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value", [.text(author.uuidString), .blob(try Self.storageEncoder.encode(state))])
    }
  }
  public func saveFileSubmission(_ input: NotebookChatInput, draft: NotebookFileDraft) throws -> NotebookChatJob {
    guard case .saveFile(let address) = input.action, address == draft.address, draft.pending == input.id else { throw NotebookStorageError.invalidTransaction("file submission identity") }
    return try commandTransaction(advancesReadRevision: false) {
      let job = try saveChatInput(input); try saveFileDraft(draft); return job
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
      if let row = try db.rows("SELECT author,digest,total,value FROM file_uploads WHERE id=?", [.text(chunk.id.uuidString)]).first {
        guard row[0].text == author.uuidString, row[1].text == chunk.digest, row[2].integer == Int64(chunk.total) else { throw NotebookStorageError.invalidTransaction("file upload collision") }
        let existing = row[3].blob!
        if chunk.offset < existing.count {
          guard chunk.offset + chunk.data.count <= existing.count, existing[chunk.offset..<(chunk.offset + chunk.data.count)] == chunk.data else { throw NotebookStorageError.invalidTransaction("file upload changed") }
          return existing.count
        }
        guard chunk.offset == existing.count else { throw NotebookStorageError.invalidTransaction("file upload gap") }
        var next = existing; next.append(chunk.data)
        try db.run("UPDATE file_uploads SET value=?,touched=? WHERE id=?", [.blob(next), .real(Date().timeIntervalSince1970), .text(chunk.id.uuidString)])
        return next.count
      }
      guard chunk.offset == 0 else { throw NotebookStorageError.invalidTransaction("file upload missing") }
      try db.run("DELETE FROM file_uploads WHERE touched<? AND id NOT IN (SELECT id FROM chat_jobs WHERE state IN ('saved','attempting','uncertain'))", [.real(Date().addingTimeInterval(-604800).timeIntervalSince1970)])
      guard try db.rows("SELECT COUNT(*) FROM file_uploads WHERE id NOT IN (SELECT id FROM chat_jobs WHERE state='accepted')")[0][0].integer! < 32 else { throw NotebookStorageError.limitExceeded("unfinished file uploads") }
      try db.run("INSERT INTO file_uploads(id,author,digest,total,value,touched) VALUES(?,?,?,?,?,?)", [.text(chunk.id.uuidString), .text(author.uuidString), .text(chunk.digest), .integer(Int64(chunk.total)), .blob(chunk.data), .real(Date().timeIntervalSince1970)])
      return chunk.data.count
    }
  }
  public func stagedFileEdit(_ id: UUID, author: UUID) throws -> NotebookFileEdit {
    try sqlRead { db in
      guard let row = try db.rows("SELECT digest,total,value FROM file_uploads WHERE id=? AND author=?", [.text(id.uuidString), .text(author.uuidString)]).first,
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
}

import Foundation

extension NotebookStore {
  /// A queued native command belongs to the account that admitted it. Existing
  /// unbound saved commands are not silently inherited by a newly signed-in user.
  @discardableResult public func admitCodexAccount(_ identity: String) throws -> Bool {
    guard identity == "signed-out" || (identity.count == 64 && identity.allSatisfy({ "0123456789abcdef".contains($0) })) else {
      throw NotebookStorageError.invalidTransaction("invalid account identity")
    }
    return try commandTransaction(advancesReadRevision: false) {
      let previous = try currentSQL!.rows("SELECT value FROM metadata WHERE key='codex_account'").first?[0].text
      guard previous != identity else { return false }
      for job in try pendingChatJobs() where job.state == .saved {
        _ = try advanceChatJob(job.id, from: .saved, to: .rejected,
          error: "Аккаунт Codex изменился. Действие не выполнено; отправьте его заново явно.")
      }
      try currentSQL!.run("INSERT INTO metadata(key,value) VALUES('codex_account',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(identity)])
      return true
    }
  }

  public func rejectSavedChatInputs(from author: UUID) throws {
    try commandTransaction(advancesReadRevision: false) {
      for job in try pendingChatJobs() where job.state == .saved && job.input.author == author {
        _ = try advanceChatJob(job.id, from: .saved, to: .rejected, error: "Доступ устройства отозван. Действие не выполнено.")
      }
    }
  }

  public func chatJob(_ id: UUID) throws -> NotebookChatJob? {
    try sqlRead { db in
      try db.rows("SELECT value FROM chat_jobs WHERE id=?", [.text(id.uuidString)]).first.map {
        try JSONDecoder().decode(NotebookChatJob.self, from: $0[0].blob!)
      }
    }
  }

  /// The first durable write precedes all network/native calls. Same ID with a
  /// different payload is a conflict, never an edit or a second model turn.
  @discardableResult public func saveChatInput(_ input: NotebookChatInput, to computer: UUID? = nil) throws -> NotebookChatJob {
    guard input.isValid else { throw NotebookStorageError.invalidTransaction("invalid chat input") }
    return try commandTransaction(advancesReadRevision: false) {
      if let existing = try chatJob(input.id) {
        guard existing.input == input else { throw NotebookStorageError.invalidTransaction("chat ID collision") }
        if let computer { try routeChatInput(input.id, to: computer) }
        return existing
      }
      guard try currentSQL!.rows("SELECT COUNT(*) FROM chat_jobs WHERE state IN ('saved','attempting','uncertain')")[0][0].integer! < 128 else {
        throw NotebookStorageError.limitExceeded("chat pending jobs")
      }
      let job = NotebookChatJob(input: input)
      try currentSQL!.run("INSERT INTO chat_jobs(id,author,state,value) VALUES(?,?,?,?)", [
        .text(input.id.uuidString), .text(input.author.uuidString), .text(job.state.rawValue), .blob(try Self.storageEncoder.encode(job))])
      if let computer { try routeChatInput(input.id, to: computer) }
      return job
    }
  }

  /// Commit the message and clear only its own editor value atomically. A crash
  /// between enqueue and UI refresh must not restore a sendable duplicate draft.
  public func saveChatSubmission(_ input: NotebookChatInput, to computer: UUID? = nil) throws -> NotebookChatJob {
    try commandTransaction(advancesReadRevision: false) {
      let job = try saveChatInput(input, to: computer)
      if let (thread, text, _) = input.action.message {
        var panel = try chatPanel(author: input.author, computer: computer)
        if panel.threadID == thread, panel.draft == text, (panel.attachments ?? []) == (input.attachments ?? []).filter { $0.kind != .image } {
          panel.draft = ""; panel.attachments = nil; try saveChatPanel(panel, author: input.author)
        }
      }
      return job
    }
  }

  /// Only the sidecar advances native execution. An attempt survives a crash;
  /// neither a restart nor the iPad's retransmission can turn it back into saved.
  public func advanceChatJob(_ id: UUID, from expected: NotebookChatJob.State,
    to state: NotebookChatJob.State, result: NotebookChatResult? = nil, error: String? = nil) throws -> NotebookChatJob {
    try commandTransaction(advancesReadRevision: false) {
      guard let old = try chatJob(id), old.state == expected else { throw NotebookStorageError.invalidTransaction("chat transition conflict") }
      let allowed: Bool
      switch (expected, state) {
      case (.saved, .attempting), (.saved, .rejected), (.attempting, .accepted), (.attempting, .rejected), (.attempting, .uncertain),
        (.attempting, .saved), (.uncertain, .accepted), (.uncertain, .unconfirmed): allowed = true
      default: allowed = false
      }
      guard allowed, (state == .accepted) == (result != nil), (error?.utf8.count ?? 0) <= 4096 else {
        throw NotebookStorageError.invalidTransaction("invalid chat transition")
      }
      let job = NotebookChatJob(input: old.input, state: state, result: result, error: error, revision: old.revision + 1, createdTask: old.createdTask)
      guard job.isValid else { throw NotebookStorageError.invalidTransaction("invalid chat result") }
      try writeChatJob(job)
      return job
    }
  }

  /// The native task already exists even if a later setup RPC loses its reply.
  public func recordCreatedChatTask(_ id: UUID, task: CodexTask) throws {
    try commandTransaction(advancesReadRevision: false) {
      guard let old = try chatJob(id), case .create = old.input.action,
        old.state == .attempting, old.createdTask == nil || old.createdTask?.id == task.id else {
        throw NotebookStorageError.invalidTransaction("invalid created task checkpoint")
      }
      let job = NotebookChatJob(input: old.input, state: old.state, result: old.result, error: old.error,
        revision: old.revision + 1, createdTask: task)
      guard job.isValid else { throw NotebookStorageError.invalidTransaction("invalid native task") }
      try writeChatJob(job)
    }
  }

  public func stopWaitingForChatJob(_ id: UUID, author: UUID) throws -> NotebookChatJob {
    try commandTransaction(advancesReadRevision: false) {
      guard let old = try chatJob(id), old.input.author == author else { throw NotebookStorageError.invalidTransaction("unknown chat input") }
      if old.isTerminal { return old }
      guard old.state == .uncertain else { throw NotebookStorageError.invalidTransaction("command is still active") }
      return try advanceChatJob(id, from: .uncertain, to: .unconfirmed,
        error: "Ожидание завершено. Исход действия остался неизвестным; повторного исполнения нет.")
    }
  }

  /// Both presentations reuse the immutable payload, not just a deterministic ID.
  public func savedChatControl(_ action: NotebookChatAction, author: UUID, computer: UUID?) throws -> NotebookChatJob? {
    guard let id = action.controlID(author: author), let job = try chatJob(id) else { return nil }
    guard job.input.action == action, try chatDestination(id) == computer else {
      throw NotebookStorageError.invalidTransaction("a different control decision is already saved")
    }
    return job
  }

  /// A verified reply only advances the iPad's display receipt, never execution.
  @discardableResult public func receiveChatReceipt(_ job: NotebookChatJob) throws -> NotebookChatJob {
    try commandTransaction(advancesReadRevision: false) {
      guard let old = try chatJob(job.id), old.input == job.input, job.isValid else { throw NotebookStorageError.invalidTransaction("invalid chat receipt") }
      if job.revision < old.revision { return old }
      if job.revision == old.revision {
        guard job == old else { throw NotebookStorageError.invalidTransaction("conflicting chat receipt") }
        return old
      }
      guard !old.isTerminal else { throw NotebookStorageError.invalidTransaction("terminal chat receipt changed") }
      try writeChatJob(job); return job
    }
  }

  private func writeChatJob(_ job: NotebookChatJob) throws {
    try currentSQL!.run("UPDATE chat_jobs SET state=?,value=? WHERE id=?", [
      .text(job.state.rawValue), .blob(try Self.storageEncoder.encode(job)), .text(job.id.uuidString)])
  }

  public func pendingChatJobs() throws -> [NotebookChatJob] {
    try sqlRead { db in
      try db.rows("SELECT value FROM chat_jobs WHERE state IN ('saved','attempting','uncertain') ORDER BY ordinal LIMIT 128").map {
        try JSONDecoder().decode(NotebookChatJob.self, from: $0[0].blob!)
      }
    }
  }

  public func recentChatJobs(author: UUID) throws -> [NotebookChatJob] {
    try sqlRead { db in
      try db.rows("SELECT value FROM chat_jobs WHERE author=? ORDER BY ordinal DESC LIMIT 32", [.text(author.uuidString)]).map {
        try JSONDecoder().decode(NotebookChatJob.self, from: $0[0].blob!)
      }
    }
  }

  public func chatPanel(author: UUID, computer: UUID? = nil) throws -> NotebookChatPanelState {
    try sqlRead { db in
      let key = try chatScope(author: author, computer: computer ?? activeChatComputer(author: author))
      return try db.rows("SELECT value FROM chat_panel WHERE id=?", [.text(key)]).first.map {
        try JSONDecoder().decode(NotebookChatPanelState.self, from: $0[0].blob!)
      } ?? .init()
    }
  }

  public func saveChatPanel(_ state: NotebookChatPanelState, author: UUID) throws {
    guard CodexInputAttachment.valid(state.attachments ?? []), state.draft.utf8.count <= 32768, state.threadID == nil || UUID(uuidString: state.threadID!) != nil else {
      throw NotebookStorageError.invalidTransaction("invalid chat panel")
    }
    if let read = state.readPosition {
      guard read.threadID == state.threadID, ([read.readThrough].compactMap({ $0 }) + Array(read.previewEndsAt.keys)).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 }) else {
        throw NotebookStorageError.invalidTransaction("invalid chat read position")
      }
    }
    try commandTransaction(advancesReadRevision: false) {
      try currentSQL!.run("INSERT INTO chat_panel(id,value) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value", [
        .text(chatScope(author: author, computer: state.sidecarID)), .blob(try Self.storageEncoder.encode(state))])
      if let computer = state.sidecarID {
        try currentSQL!.run("INSERT OR IGNORE INTO chat_active_computer(author,computer) VALUES(?,?)", [.text(author.uuidString), .text(computer.uuidString)])
      }
    }
  }
}

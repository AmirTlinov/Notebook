import Foundation

extension NotebookStore {
  func chatScope(author: UUID, computer: UUID?) -> String { author.uuidString + (computer.map { ":" + $0.uuidString } ?? "") }
  public func activeChatComputer(author: UUID) throws -> UUID? {
    try sqlRead { try $0.rows("SELECT computer FROM chat_active_computer WHERE author=?", [.text(author.uuidString)]).first?[0].text.flatMap(UUID.init(uuidString:)) }
  }
  public func chatDestination(_ id: UUID) throws -> UUID? {
    try sqlRead { try $0.rows("SELECT computer FROM chat_jobs WHERE id=?", [.text(id.uuidString)]).first?[0].text.flatMap(UUID.init(uuidString:)) }
  }
  func routeChatInput(_ id: UUID, to computer: UUID) throws {
    if let previous = try chatDestination(id) {
      guard previous == computer else { throw NotebookStorageError.invalidTransaction("A saved command cannot change computers") }; return
    }
    try currentSQL!.run("UPDATE chat_jobs SET computer=? WHERE id=?", [.text(computer.uuidString), .text(id.uuidString)])
  }
  /// Move the current single-computer window into its explicit scope once.
  /// Message IDs/payloads and all shared content remain byte-for-byte unchanged.
  public func prepareChatComputers(author: UUID) throws {
    try commandTransaction(advancesReadRevision: false) {
      let db = currentSQL!, key = author.uuidString
      if let data = try db.rows("SELECT value FROM chat_panel WHERE id=?", [.text(key)]).first?[0].blob {
        let value = try JSONDecoder().decode(NotebookChatPanelState.self, from: data)
        if let computer = value.sidecarID {
          try db.run("INSERT OR IGNORE INTO chat_panel(id,value) VALUES(?,?)", [.text(chatScope(author: author, computer: computer)), .blob(data)])
          try db.run("INSERT OR IGNORE INTO chat_active_computer(author,computer) VALUES(?,?)", [.text(key), .text(computer.uuidString)])
          try db.run("UPDATE chat_jobs SET computer=? WHERE author=? AND computer IS NULL", [.text(computer.uuidString), .text(key)])
          try db.run("DELETE FROM chat_panel WHERE id=?", [.text(key)])
        }
      }
      if let data = try db.rows("SELECT value FROM file_window WHERE id=?", [.text(key)]).first?[0].blob {
        let value = try JSONDecoder().decode(NotebookFileWindowState.self, from: data)
        if let computer = try activeChatComputer(author: author) ?? value.selected?.computer {
          try db.run("INSERT OR IGNORE INTO file_window(id,value) VALUES(?,?)", [.text(chatScope(author: author, computer: computer)), .blob(data)])
          try db.run("DELETE FROM file_window WHERE id=?", [.text(key)])
        }
      }
    }
  }
  public func chatComputerWindow(author: UUID, computer: UUID) throws -> (panel: NotebookChatPanelState, window: NotebookFileWindowState, document: NotebookFileDraft?, jobs: [NotebookChatJob]) {
    try readTransaction { store in
      let panel = try store.chatPanel(author: author, computer: computer)
      let window = try store.fileWindow(author: author, computer: computer)
      return (panel, window, try window.selected.flatMap { try store.fileDraft($0) }, try store.routedChatJobs(author: author, computer: computer))
    }
  }
  public func selectChatComputer(_ computer: UUID, author: UUID) throws -> (panel: NotebookChatPanelState, window: NotebookFileWindowState, document: NotebookFileDraft?, jobs: [NotebookChatJob]) {
    try commandTransaction(advancesReadRevision: false) {
      try prepareChatComputers(author: author)
      let db = currentSQL!, key = author.uuidString, target = chatScope(author: author, computer: computer)
      if try activeChatComputer(author: author) == nil {
        // An unassigned local draft becomes bound only to the first chosen Mac.
        if let data = try db.rows("SELECT value FROM chat_panel WHERE id=?", [.text(key)]).first?[0].blob {
          var panel = try JSONDecoder().decode(NotebookChatPanelState.self, from: data); panel.sidecarID = computer
          try db.run("INSERT OR IGNORE INTO chat_panel(id,value) VALUES(?,?)", [.text(target), .blob(try Self.storageEncoder.encode(panel))])
          try db.run("DELETE FROM chat_panel WHERE id=?", [.text(key)])
        }
        try db.run("UPDATE chat_jobs SET computer=? WHERE author=? AND computer IS NULL", [.text(computer.uuidString), .text(key)])
        try db.run("INSERT OR IGNORE INTO file_window(id,value) SELECT ?,value FROM file_window WHERE id=?", [.text(target), .text(key)])
        try db.run("DELETE FROM file_window WHERE id=?", [.text(key)])
      }
      try db.run("INSERT INTO chat_active_computer(author,computer) VALUES(?,?) ON CONFLICT(author) DO UPDATE SET computer=excluded.computer", [.text(key), .text(computer.uuidString)])
      var panel = try chatPanel(author: author, computer: computer); panel.sidecarID = computer
      try saveChatPanel(panel, author: author)
      return try chatComputerWindow(author: author, computer: computer)
    }
  }
  public func routedChatJobs(author: UUID, computer: UUID?) throws -> [NotebookChatJob] {
    return try sqlRead { db in
      let args: [NotebookSQLValue] = [.text(author.uuidString), computer.map { .text($0.uuidString) } ?? .null]
      let rows = try db.rows("""
        WITH recent AS (SELECT ordinal,value FROM chat_jobs WHERE author=? AND computer IS ? ORDER BY ordinal DESC LIMIT 32),
        pending AS (SELECT ordinal,value FROM chat_jobs WHERE author=? AND computer IS ? AND state IN ('saved','attempting','uncertain') ORDER BY ordinal LIMIT 128)
        SELECT value FROM (SELECT ordinal,value FROM recent UNION SELECT ordinal,value FROM pending) ORDER BY ordinal DESC
        """, args + args)
      return try rows.map { try JSONDecoder().decode(NotebookChatJob.self, from: $0[0].blob!) }
    }
  }
}

import Foundation

/// The native writer may close a refused slot only after its transaction has
/// proved rollback. A failed storage/commit response keeps the accepted payload.
public struct NotebookAcceptedWriteError: Error, LocalizedError, Sendable {
  public enum Outcome: Sendable { case rejected, storageUnavailable, unresolved }
  public let outcome: Outcome
  public let underlying: Error
  public var errorDescription: String? { underlying.localizedDescription }

  init(_ outcome: Outcome, _ underlying: Error) {
    self.outcome = outcome; self.underlying = underlying
  }

  /// These diagnostics describe command validation, never disk availability.
  /// The successful outer rollback supplies their definitive outcome evidence.
  static func isDomainRefusal(_ error: Error) -> Bool {
    switch error {
    case let error as NotebookAcceptedWriteError: return error.outcome == .rejected
    case let error as NotebookStorageError:
      switch error {
      case .invalidTransaction, .transactionConflict, .readOnlyTransaction, .limitExceeded: return true
      default: return false
      }
    case is NotebookStoreError: return true
    case is PageInkDrawing.InkError: return true
    case let error as CollaborationError:
      switch error.code {
      case "storage_error", "operation_failed", "conversion_required", "unsupported_format",
        "format_checkpoint_required", "publication_pending", "edit_receipt_unavailable",
        "action_version_unavailable", "request_identity_unavailable", "ipc_timeout": return false
      default: return true
      }
    default: return false
    }
  }
}

/// One retained native FIFO owns one local commit witness. The next accepted
/// COMMIT replaces that row; a drained writer removes it. Values never enter
/// this metadata or the replicated content/change journal.
public final class NotebookAcceptedWriteWitnesses: @unchecked Sendable {
  private let lock = NSLock()
  let id = UUID()
  private let rootPath: String
  let processLease: NotebookIPCProcessLease?
  private(set) var workspaceID: UUID?
  fileprivate var confirmedIdentity: UUID?
  fileprivate var unresolvedIdentity: UUID?

  public init(root: URL, processLease: NotebookIPCProcessLease? = nil) {
    rootPath = NotebookStore.canonicalWorkspacePath(root)
    self.processLease = processLease
  }

  fileprivate func withLock<Value>(_ operation: () throws -> Value) rethrows -> Value {
    lock.lock(); defer { lock.unlock() }
    return try operation()
  }

  fileprivate func requireRoot(_ store: NotebookStore) throws {
    guard NotebookStore.canonicalWorkspacePath(store.root) == rootPath else {
      throw NotebookStorageError.corruptRecord("accepted writer workspace root")
    }
    if workspaceID != nil, !FileManager.default.fileExists(atPath: store.databaseURL.path) {
      throw NotebookStorageError.corruptRecord("accepted writer workspace missing")
    }
  }

  func bindWorkspace(database: NotebookSQLConnection) throws {
    guard let identity = try database.rows("SELECT value FROM metadata WHERE key='workspace_id'").first?[0].text.flatMap(UUID.init(uuidString:)) else {
      throw NotebookStorageError.corruptRecord("accepted writer workspace identity")
    }
    guard workspaceID == nil || workspaceID == identity else {
      throw NotebookStorageError.corruptRecord("accepted writer workspace changed")
    }
    workspaceID = identity
  }

  /// This is local schema admission before BEGIN, outside content accounting.
  /// A retry of an uncertain COMMIT reads the existing table without recreating
  /// it: an unreadable witness can never become evidence of rollback.
  static func prepareTable(database: NotebookSQLConnection) throws {
    try database.run("CREATE TABLE IF NOT EXISTS accepted_write_witnesses(writer TEXT PRIMARY KEY NOT NULL,accepted TEXT NOT NULL,workspace TEXT NOT NULL,lease TEXT,generation TEXT,CHECK((lease IS NULL)=(generation IS NULL))) WITHOUT ROWID")
  }

  func install(_ identity: UUID, database: NotebookSQLConnection) throws {
    guard let workspaceID else { throw NotebookStorageError.corruptRecord("unbound accepted writer") }
    if let processLease {
      // The retained descriptor proves every older generation of this exact
      // lease has retired. Other live scopes in our generation remain intact.
      try database.run("DELETE FROM accepted_write_witnesses WHERE lease=? AND generation<>?",
        [.text(processLease.acceptedWitnessLeaseIdentity), .text(processLease.acceptedWitnessGeneration.uuidString)])
    }
    try database.run("INSERT INTO accepted_write_witnesses(writer,accepted,workspace,lease,generation) VALUES(?,?,?,?,?) ON CONFLICT(writer) DO UPDATE SET accepted=excluded.accepted,workspace=excluded.workspace,lease=excluded.lease,generation=excluded.generation",
      [.text(id.uuidString), .text(identity.uuidString), .text(workspaceID.uuidString),
        processLease.map { .text($0.acceptedWitnessLeaseIdentity) } ?? .null,
        processLease.map { .text($0.acceptedWitnessGeneration.uuidString) } ?? .null])
  }

  fileprivate func readWitness(in store: NotebookStore) throws -> UUID? {
    try requireRoot(store)
    try store.storageFault?(.beforeAcceptedWitnessRead)
    let database = try NotebookSQLConnection(url: store.databaseURL, writable: false)
    try database.limitReads(.init(rows: 2, bytes: 16_384, valueBytes: 8_192, reason: "accepted_write_witness"))
    return try store.readTransaction(using: database) { _ in
      try bindWorkspace(database: database)
      guard let row = try database.rows("SELECT accepted,workspace,lease,generation FROM accepted_write_witnesses WHERE writer=?", [.text(id.uuidString)]).first else { return nil }
      guard let accepted = row[0].text.flatMap(UUID.init(uuidString:)),
        row[1].text == workspaceID?.uuidString,
        row[2].text == processLease?.acceptedWitnessLeaseIdentity,
        row[3].text == processLease?.acceptedWitnessGeneration.uuidString else {
        throw NotebookStorageError.corruptRecord("accepted write witness")
      }
      return accepted
    }
  }

  fileprivate func requireWorkspace(in store: NotebookStore) throws {
    let database = try NotebookSQLConnection(url: store.databaseURL, writable: false)
    try database.limitReads(.init(rows: 1, bytes: 128, valueBytes: 128, reason: "accepted_workspace_identity"))
    try store.readTransaction(using: database) { _ in try bindWorkspace(database: database) }
  }

  /// Called at an actual FIFO flush/retirement cut. Failure keeps this scope
  /// available for Retry; bookkeeping never advances a content/read cursor.
  public func flush(in store: NotebookStore) throws {
    try withLock {
      try requireRoot(store)
      guard unresolvedIdentity == nil else {
        throw NotebookAcceptedWriteError(.unresolved, NotebookStorageError.corruptRecord("unresolved accepted writer"))
      }
      guard confirmedIdentity != nil else { return }
      try store.commandTransaction(advancesReadRevision: false) {
        let database = store.currentSQL!
        try bindWorkspace(database: database)
        try database.run("DELETE FROM accepted_write_witnesses WHERE writer=?", [.text(id.uuidString)])
      }
      confirmedIdentity = nil
    }
  }
}

/// The accepted body, immutable identity and exact prepared output survive an
/// unknown COMMIT. Peer edits cannot turn a Retry into a second mutation.
public final class NotebookAcceptedWrite<Value: Sendable>: @unchecked Sendable {
  public let identity = UUID()
  private enum State { case pending, prepared(Value), confirmed(Value), rejected(NotebookAcceptedWriteError) }
  private var state: State = .pending
  private let witnesses: NotebookAcceptedWriteWitnesses
  private let operation: @Sendable (NotebookStore) throws -> Value

  public init(witnesses: NotebookAcceptedWriteWitnesses,
    _ operation: @escaping @Sendable (NotebookStore) throws -> Value) {
    self.witnesses = witnesses; self.operation = operation
  }

  /// Preparation/awaiting stays outside this synchronous scope. Nested typed
  /// Core methods borrow its transaction; accepted instances cannot nest.
  public func apply(to store: NotebookStore) throws -> Value {
    guard store.currentSQL == nil else {
      throw NotebookStorageError.invalidTransaction("nested accepted write")
    }
    return try witnesses.withLock {
      do { try witnesses.requireRoot(store) }
      catch { throw NotebookAcceptedWriteError(.storageUnavailable, error) }
      switch state {
      case .confirmed(let value):
        // A retired marker does not invalidate the known output. A different
        // workspace at the same filesystem root cannot adopt that output.
        do { try witnesses.requireWorkspace(in: store) }
        catch { throw NotebookAcceptedWriteError(.storageUnavailable, error) }
        return value
      case .rejected(let error):
        do { try witnesses.requireWorkspace(in: store) }
        catch { throw NotebookAcceptedWriteError(.storageUnavailable, error) }
        throw error
      case .pending, .prepared: break
      }
      if let unresolved = witnesses.unresolvedIdentity {
        guard unresolved == identity else {
          throw NotebookAcceptedWriteError(.unresolved, NotebookStorageError.corruptRecord("earlier accepted write unresolved"))
        }
        let saved: UUID?
        do { saved = try witnesses.readWitness(in: store) }
        catch { throw NotebookAcceptedWriteError(.unresolved, error) }
        if saved == identity {
          guard case .prepared(let value) = state else {
            throw NotebookAcceptedWriteError(.unresolved, NotebookStorageError.corruptRecord("accepted output missing"))
          }
          state = .confirmed(value)
          witnesses.confirmedIdentity = identity; witnesses.unresolvedIdentity = nil
          return value
        }
        guard saved == nil || saved == witnesses.confirmedIdentity else {
          throw NotebookAcceptedWriteError(.unresolved, NotebookStorageError.corruptRecord("accepted witness replaced"))
        }
        // Fresh absence attests that this attempt did not commit. The original
        // accepted instance/body remains; its rolled-back output does not.
        state = .pending; witnesses.unresolvedIdentity = nil
      }
      do {
        let value = try store.commandTransaction(acceptedWitness: .init(witnesses: witnesses, identity: identity)) {
          try witnesses.bindWorkspace(database: store.currentSQL!)
          let value = try operation(store)
          state = .prepared(value)
          return value
        }
        state = .confirmed(value); witnesses.confirmedIdentity = identity
        return value
      } catch let error as NotebookAcceptedWriteError {
        switch error.outcome {
        case .rejected: state = .rejected(error)
        case .storageUnavailable: state = .pending
        case .unresolved: witnesses.unresolvedIdentity = identity
        }
        throw error
      }
    }
  }
}

/// Concrete outer-transaction bookkeeping, installed after content/read-cut
/// accounting and committed atomically with the accepted body.
struct NotebookAcceptedWriteWitness {
  let witnesses: NotebookAcceptedWriteWitnesses
  let identity: UUID
}

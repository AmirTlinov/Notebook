import Foundation

/// The reader's lifetime can close from its application owner while SQLite is
/// running on another executor. Accepted writers never borrow this token.
public final class NotebookReadCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  public init() { }
  public func cancel() { lock.withLock { cancelled = true } }
  var isCancelled: Bool { lock.withLock { cancelled } }
  func check() throws { if isCancelled { throw CancellationError() } }
}

/// One serial owner reuses an idle connection, not a WAL snapshot or decoded
/// content. Each synchronous call rechecks admission and starts a fresh cut;
/// no transaction, statement borrow or content cache crosses the caller's await.
/// Deliberately not Sendable: the composition/transport actor owns this session.
public final class NotebookReadSession {
  private let store: NotebookStore
  public let cancellation: NotebookReadCancellation
  private var connection: NotebookSQLConnection?
  private var identity: FileIdentity?

  public init(store: NotebookStore, cancellation: NotebookReadCancellation = .init()) {
    self.store = store; self.cancellation = cancellation
  }

  /// External observers receive only the exact live read cut. Its domain
  /// capability exposes no write API or store and cannot escape this snapshot.
  public func observe<Value>(_ operation: (NotebookQueryCut) throws -> Value) throws -> Value {
    try read { store in
      guard let connection = store.currentSQL, !connection.writable,
        let identity = connection.readSnapshotIdentity else { throw NotebookStorageError.readOnlyTransaction }
      try connection.limitReads(.agentCommand)
      return try operation(.init(store: store, connection: connection, identity: identity))
    }
  }

  public func read<Value>(_ operation: (NotebookStore) throws -> Value) throws -> Value {
    try cancellation.check()
    if store.currentSQL != nil { return try operation(store) }
    do {
      let next = try FileIdentity(store.databaseURL)
      guard identity == nil || identity == next else {
        throw NotebookStorageError.invalidTransaction("database file identity changed")
      }
      let admitted = try store.prepareDatabase(reusing: connection)
      connection = admitted; identity = next
      return try store.readTransaction(using: admitted, cancellation: cancellation, operation)
    } catch { connection = nil; throw error }
  }

  private struct FileIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    init(_ file: URL) throws {
      let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
      guard let device = attributes[.systemNumber] as? NSNumber,
        let inode = attributes[.systemFileNumber] as? NSNumber else {
        throw NotebookStorageError.invalidTransaction("database file identity")
      }
      self.device = device.uint64Value; self.inode = inode.uint64Value
    }
  }
}

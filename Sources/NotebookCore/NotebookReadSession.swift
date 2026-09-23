import Foundation

/// One serial owner reuses an idle connection, not a WAL snapshot or decoded
/// content. Each synchronous call rechecks admission and starts a fresh cut;
/// no transaction, statement borrow or content cache crosses the caller's await.
/// Deliberately not Sendable: the composition/transport actor owns this session.
public final class NotebookReadSession {
  private let store: NotebookStore
  private var connection: NotebookSQLConnection?
  private var identity: FileIdentity?

  public init(store: NotebookStore) { self.store = store }

  public func read<Value>(_ operation: (NotebookStore) throws -> Value) throws -> Value {
    if store.currentSQL != nil { return try operation(store) }
    do {
      let next = try FileIdentity(store.databaseURL)
      guard identity == nil || identity == next else {
        throw NotebookStorageError.invalidTransaction("database file identity changed")
      }
      let admitted = try store.prepareDatabase(reusing: connection)
      connection = admitted; identity = next
      return try store.readTransaction(using: admitted, operation)
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

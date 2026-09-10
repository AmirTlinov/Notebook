import Foundation

/// The native program captures its accepted value and causal version before
/// entering the persistence queue. It never sends the other programs' history.
public struct NotebookDocumentStateCommand: Sendable {
  public let documentID: UUID
  public let record: DocumentStateRecord
  public let journalStamp: VersionStamp

  public init(documentID: UUID, record: DocumentStateRecord, journalStamp: VersionStamp) {
    self.documentID = documentID; self.record = record; self.journalStamp = journalStamp
  }

  public var expectedResult: NotebookDocumentStateResult {
    .init(documentID: documentID, record: record, journalStamp: journalStamp)
  }
}

/// Only the addressed value and aggregate clock return to the native queue.
/// A differing result asks the model to read the concurrently changed scene.
public struct NotebookDocumentStateResult: Equatable, Sendable {
  public let documentID: UUID
  public let record: DocumentStateRecord
  public let journalStamp: VersionStamp
}

extension NotebookStore {
  @discardableResult
  public func commitDocumentState(_ command: NotebookDocumentStateCommand) throws -> NotebookDocumentStateResult {
    guard command.journalStamp.counter <= VersionStamp.maximumCounter,
      command.record.fieldVersion != nil, command.record.isValid(in: command.journalStamp) else {
      throw NotebookStorageError.invalidTransaction("document state clock or value")
    }
    return try commandTransaction {
      guard try readItemHeader(command.documentID)?.kind == .document else { throw CocoaError(.fileNoSuchFile) }
      let file = stateFile(command.documentID), rootAddress = file + "#"
      guard let root = try storedFragments(address: rootAddress, descendants: false).first else {
        throw NotebookStorageError.corruptRecord(rootAddress)
      }
      let header = try documentStateHeader(root, id: command.documentID)
      let address = rootAddress + "/records/@" + fieldKey([collaborationIdentity(command.record.id)])
      let rows = try storedFragments(address: address)
      let previous = try rows.isEmpty ? nil : NotebookRecordCodec.decode(rows, root: address).decode(DocumentStateRecord.self)
      var resolved = command.record
      if let previous {
        guard previous.id == resolved.id, previous.isValid(in: header.stamp) else {
          throw NotebookStorageError.corruptRecord(address)
        }
        // Preserve the same candidate.merge(stored) direction as replication;
        // the value's existing field-version owner decides concurrent authors.
        _ = resolved.replace(previous.value, version: previous.fieldVersion ?? .init(stamp: previous.stamp, human: true))
      }
      var stamp = max(header.stamp, command.journalStamp)
      guard resolved.isValid(in: stamp) else { throw NotebookStorageError.invalidTransaction("document state causal version") }
      if resolved.value != previous?.value, header.stamp >= command.journalStamp {
        // The stored aggregate already names another accepted value. Publishing
        // this new combination must invalidate that frame, but an exact retry
        // or a losing old value must not advance it a second time.
        guard let next = stamp.advanced(by: stamp.actor) else {
          throw NotebookStorageError.limitExceeded("document state clock")
        }
        stamp = next
      }
      let before = root.value.setting("records", .array(try previous.map { [try JSONValue.encode($0)] } ?? []))
      let after = root.value.setting("stamp", try .encode(stamp))
        .setting("records", .array([try .encode(resolved)]))
      try publishProjectionEdits(file: file, before: before, after: after)
      return .init(documentID: command.documentID, record: resolved, journalStamp: stamp)
    }
  }

  /// Both local publication and incoming delivery validate the exact root
  /// descriptor without reconstructing the journal's historical children.
  func documentStateHeader(_ root: NotebookStoredFragment, id: UUID) throws -> DocumentStateJournal {
    let file = stateFile(id), address = file + "#"
    let journal = try NotebookRecordCodec.decode([root], root: address).decode(DocumentStateJournal.self)
    guard journal.id == id, journal.isValid,
      try NotebookRecordCodec.encode(.encode(journal), file: file) == [root] else {
      throw NotebookStorageError.corruptRecord(address)
    }
    return journal
  }
}

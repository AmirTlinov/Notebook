import Foundation

/// The native program captures its accepted value and causal version before
/// entering the persistence queue. It never sends the other programs' history.
public struct NotebookDocumentStateCommand: Sendable {
  public let documentID: UUID
  public let record: DocumentStateRecord
  public let journalStamp: VersionStamp
  public let expectedSourceVersion: ContentFieldVersion
  public let stateCondition: NotebookDocumentStateCondition

  public init(documentID: UUID, record: DocumentStateRecord, journalStamp: VersionStamp,
    expectedSourceVersion: ContentFieldVersion, stateCondition: NotebookDocumentStateCondition = .any) {
    self.documentID = documentID; self.record = record; self.journalStamp = journalStamp
    self.expectedSourceVersion = expectedSourceVersion; self.stateCondition = stateCondition
  }

  public var expectedResult: NotebookDocumentStateResult {
    .committed(.init(documentID: documentID, record: record, journalStamp: journalStamp))
  }
}

/// Ordinary contacts merge causally. A lifecycle checkpoint may only advance
/// the exact state observed by that executor, including an absent first value.
public enum NotebookDocumentStateCondition: Sendable {
  case any
  case matching(ContentFieldVersion?)
}

/// Only the addressed value and aggregate clock return to the native queue.
/// A differing result asks the model to read the concurrently changed scene.
public enum NotebookDocumentStateResult: Equatable, Sendable {
  case committed(NotebookDocumentStatePublication)
  /// Admission in memory cannot authorize a different durable program. A nil
  /// version identifies a missing target; neither case advances the journal.
  case targetChanged(documentID: UUID, currentSourceVersion: ContentFieldVersion?)
  case stateChanged(documentID: UUID, currentStateVersion: ContentFieldVersion?)
}

public struct NotebookDocumentStatePublication: Equatable, Sendable {
  public let documentID: UUID
  public let record: DocumentStateRecord
  public let journalStamp: VersionStamp
}

extension NotebookStore {
  @discardableResult
  public func commitDocumentState(_ command: NotebookDocumentStateCommand) throws -> NotebookDocumentStateResult {
    guard command.journalStamp.counter <= VersionStamp.maximumCounter,
      command.record.fieldVersion != nil, command.record.isValid(in: command.journalStamp),
      command.expectedSourceVersion.isValid else {
      throw NotebookStorageError.invalidTransaction("document state clock or value")
    }
    return try commandTransaction {
      guard try readItemHeader(command.documentID)?.kind == .document,
        let target = try readDocumentBlock(documentID: command.documentID, blockID: command.record.id) else {
        return .targetChanged(documentID: command.documentID, currentSourceVersion: nil)
      }
      guard target.block.kind == .interactive, target.sourceVersion == command.expectedSourceVersion else {
        return .targetChanged(documentID: command.documentID, currentSourceVersion: target.sourceVersion)
      }
      let file = stateFile(command.documentID), rootAddress = file + "#"
      guard let root = try storedFragments(address: rootAddress, descendants: false).first else {
        throw NotebookStorageError.corruptRecord(rootAddress)
      }
      let header = try documentStateHeader(root, id: command.documentID)
      let address = rootAddress + "/records/@" + fieldKey([collaborationIdentity(command.record.id)])
      let rows = try storedFragments(address: address)
      let previous = try rows.isEmpty ? nil : NotebookRecordCodec.decode(rows, root: address).decode(DocumentStateRecord.self)
      if case .matching(let expected) = command.stateCondition,
        previous?.valueVersion != expected, previous != command.record {
        return .stateChanged(documentID: command.documentID, currentStateVersion: previous?.valueVersion)
      }
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
      return .committed(.init(documentID: command.documentID, record: resolved, journalStamp: stamp))
    }
  }

  /// A detached document is outside the model's working set, not deleted.
  /// Its final heap still addresses one durable block through the same writer.
  public func checkpointDocumentState(documentID: UUID, blockID: String, value: JSONValue,
    sourceVersion: ContentFieldVersion, stateVersion: ContentFieldVersion?, actor: UUID) throws -> ContentFieldVersion? {
    guard value.isValid else { throw NotebookStorageError.invalidTransaction("document checkpoint value") }
    return try commandTransaction {
      guard try readItemHeader(documentID)?.kind == .document,
        let target = try readDocumentBlock(documentID: documentID, blockID: blockID),
        target.block.kind == .interactive, target.sourceVersion == sourceVersion,
        target.stateVersion == stateVersion else { return nil }
      if target.state == value, let stateVersion { return stateVersion }
      let address = stateFile(documentID) + "#"
      guard let root = try storedFragments(address: address, descendants: false).first else {
        throw NotebookStorageError.corruptRecord(address)
      }
      let header = try documentStateHeader(root, id: documentID)
      guard let stamp = header.stamp.advanced(by: actor) else { throw NotebookStorageError.limitExceeded("document state clock") }
      let version = ContentFieldVersion(stamp: stamp, human: true, previous: stateVersion)
      let command = NotebookDocumentStateCommand(documentID: documentID,
        record: .init(id: blockID, value: value, stamp: stamp, fieldVersion: version),
        journalStamp: stamp, expectedSourceVersion: sourceVersion, stateCondition: .matching(stateVersion))
      guard case .committed(let accepted) = try commitDocumentState(command) else { return nil }
      return accepted.record.valueVersion
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

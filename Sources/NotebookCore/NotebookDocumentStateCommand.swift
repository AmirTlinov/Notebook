import Foundation

/// The native program captures its accepted value and causal version before
/// entering the persistence queue. It never sends the other programs' history.
public struct NotebookDocumentStateCommand: Sendable {
  public let documentID: UUID
  public let record: DocumentStateRecord
  public let journalStamp: VersionStamp
  public let expectedProgramIdentity: DocumentProgramIdentity
  public let stateCondition: NotebookDocumentStateCondition

  public init(documentID: UUID, record: DocumentStateRecord, journalStamp: VersionStamp,
    expectedProgramIdentity: DocumentProgramIdentity, stateCondition: NotebookDocumentStateCondition = .any) {
    self.documentID = documentID; self.record = record; self.journalStamp = journalStamp
    self.expectedProgramIdentity = expectedProgramIdentity; self.stateCondition = stateCondition
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
  case targetChanged(documentID: UUID, currentProgramIdentity: DocumentProgramIdentity?)
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
      command.expectedProgramIdentity.isValid else {
      throw NotebookStorageError.invalidTransaction("document state clock or value")
    }
    return try commandTransaction {
      guard try readItemHeader(command.documentID)?.kind == .document,
        let target = try readDocumentProgramSource(documentID: command.documentID, blockID: command.record.id) else {
        return .targetChanged(documentID: command.documentID, currentProgramIdentity: nil)
      }
      guard target.block.kind == .interactive, target.programIdentity == command.expectedProgramIdentity else {
        return .targetChanged(documentID: command.documentID, currentProgramIdentity: target.programIdentity)
      }
      return try commitDocumentState(command,
        projection: documentStateProjection(documentID: command.documentID, blockID: command.record.id))
    }
  }

  /// The document may leave the active model after this program has accepted a
  /// value. Its captured source identity, not a loaded journal, owns the event.
  @discardableResult
  public func commitDocumentState(documentID: UUID, blockID: String, value: JSONValue,
    programIdentity: DocumentProgramIdentity, actor: UUID) throws -> ContentFieldVersion? {
    try commitDocumentState(documentID: documentID, blockID: blockID, value: value,
      programIdentity: programIdentity, condition: .any, actor: actor)
  }

  /// A detached document is outside the model's working set, not deleted.
  /// Its final heap still addresses one durable block through the same writer.
  public func checkpointDocumentState(documentID: UUID, blockID: String, value: JSONValue,
    programIdentity: DocumentProgramIdentity, stateVersion: ContentFieldVersion?, actor: UUID) throws -> ContentFieldVersion? {
    try commitDocumentState(documentID: documentID, blockID: blockID, value: value,
      programIdentity: programIdentity, condition: .matching(stateVersion), actor: actor)
  }

  private func commitDocumentState(documentID: UUID, blockID: String, value: JSONValue,
    programIdentity: DocumentProgramIdentity, condition: NotebookDocumentStateCondition, actor: UUID) throws -> ContentFieldVersion? {
    guard value.isValid else { throw NotebookStorageError.invalidTransaction("document state value") }
    return try commandTransaction {
      guard try readItemHeader(documentID)?.kind == .document,
        let target = try readDocumentProgramSource(documentID: documentID, blockID: blockID),
        target.block.kind == .interactive, target.programIdentity == programIdentity else { return nil }
      let projection = try documentStateProjection(documentID: documentID, blockID: blockID)
      let previous = projection.previous
      if case .matching(let expected) = condition, previous?.valueVersion != expected { return nil }
      if previous?.value == value, let version = previous?.valueVersion { return version }
      guard let stamp = projection.header.stamp.advanced(by: actor) else { throw NotebookStorageError.limitExceeded("document state clock") }
      let version = ContentFieldVersion(stamp: stamp, human: true, previous: previous?.valueVersion)
      let command = NotebookDocumentStateCommand(documentID: documentID,
        record: .init(id: blockID, value: value, stamp: stamp, fieldVersion: version),
        journalStamp: stamp, expectedProgramIdentity: programIdentity, stateCondition: condition)
      guard case .committed(let accepted) = try commitDocumentState(command, projection: projection) else { return nil }
      return accepted.record.valueVersion
    }
  }

  private struct DocumentStateProjection {
    let root: NotebookStoredFragment
    let header: DocumentStateJournal
    let previous: DocumentStateRecord?
  }

  private func documentStateProjection(documentID: UUID, blockID: String) throws -> DocumentStateProjection {
    let rootAddress = stateFile(documentID) + "#"
    guard let root = try storedFragments(address: rootAddress, descendants: false).first else {
      throw NotebookStorageError.corruptRecord(rootAddress)
    }
    let header = try documentStateHeader(root, id: documentID)
    let address = rootAddress + "/records/@" + fieldKey([collaborationIdentity(blockID)])
    let rows = try storedFragments(address: address)
    let previous = try rows.isEmpty ? nil : NotebookRecordCodec.decode(rows, root: address).decode(DocumentStateRecord.self)
    if let previous {
      guard previous.id == blockID, previous.isValid(in: header.stamp) else { throw NotebookStorageError.corruptRecord(address) }
    }
    return .init(root: root, header: header, previous: previous)
  }

  /// One addressed merge and publisher for all native events and checkpoints.
  /// Its caller holds the transaction containing this exact state projection.
  private func commitDocumentState(_ command: NotebookDocumentStateCommand,
    projection: DocumentStateProjection) throws -> NotebookDocumentStateResult {
    let (root, header, previous) = (projection.root, projection.header, projection.previous)
    if case .matching(let expected) = command.stateCondition,
      previous?.valueVersion != expected, previous != command.record {
      return .stateChanged(documentID: command.documentID, currentStateVersion: previous?.valueVersion)
    }
    var resolved = command.record
    if let previous {
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
    try publishProjectionEdits(file: stateFile(command.documentID), before: before, after: after)
    return .committed(.init(documentID: command.documentID, record: resolved, journalStamp: stamp))
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

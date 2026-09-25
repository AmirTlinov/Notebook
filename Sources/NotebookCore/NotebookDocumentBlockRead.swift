import Foundation

/// One block and its committed state share a WAL snapshot. This is not a
/// document/journal archive and carries neither format nor unrelated children.
public struct NotebookDocumentBlockRead: Codable, Equatable, Sendable {
  public let documentID: UUID
  public let contentStamp: VersionStamp
  public let stateStamp: VersionStamp
  public let sourceVersion: ContentFieldVersion
  public let programIdentity: DocumentProgramIdentity
  public let stateVersion: ContentFieldVersion?
  public let block: DocumentBlock
  public let state: JSONValue?

  init(documentID: UUID, contentStamp: VersionStamp, stateStamp: VersionStamp,
    sourceVersion: ContentFieldVersion, programIdentity: DocumentProgramIdentity, stateVersion: ContentFieldVersion?, block: DocumentBlock, state: JSONValue?) {
    self.documentID = documentID; self.contentStamp = contentStamp; self.stateStamp = stateStamp
    self.block = block; self.state = state
    self.programIdentity = programIdentity; self.sourceVersion = sourceVersion; self.stateVersion = stateVersion
  }

  private enum CodingKeys: String, CodingKey { case documentID, contentStamp, stateStamp, sourceVersion, programIdentity, stateVersion, block, state }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    documentID = try values.decode(UUID.self, forKey: .documentID)
    contentStamp = try values.decode(VersionStamp.self, forKey: .contentStamp)
    stateStamp = try values.decode(VersionStamp.self, forKey: .stateStamp)
    sourceVersion = try values.decode(ContentFieldVersion.self, forKey: .sourceVersion)
    programIdentity = try values.decode(DocumentProgramIdentity.self, forKey: .programIdentity)
    stateVersion = try values.decodeIfPresent(ContentFieldVersion.self, forKey: .stateVersion)
    block = try values.decode(DocumentBlock.self, forKey: .block)
    // A committed JSON null is a value, not an absent state record.
    state = values.contains(.state) ? try values.decode(JSONValue.self, forKey: .state) : nil
  }
}

extension NotebookStore {
  public func readDocumentBlock(documentID: UUID, blockID: String) throws -> NotebookDocumentBlockRead? {
    try readDocumentBlock(documentID: documentID, blockID: blockID, stateRead: .publicEnvelope)
  }

  /// Internal runtime transfer, not the bounded public document-block tool.
  /// The caller reserves this transient budget before materializing the state.
  public func readDocumentProgramState(documentID: UUID, blockID: String, admittedBytes: Int) throws -> NotebookDocumentBlockRead? {
    guard admittedBytes > 0 else { throw NotebookStorageError.limitExceeded("program_state_admission") }
    return try readDocumentBlock(documentID: documentID, blockID: blockID, stateRead: .admitted(admittedBytes))
  }

  func readDocumentProgramSource(documentID: UUID, blockID: String) throws -> NotebookDocumentBlockRead? {
    try readDocumentBlock(documentID: documentID, blockID: blockID, stateRead: .omitted)
  }

  private enum StateRead { case publicEnvelope, omitted, admitted(Int) }
  private func readDocumentBlock(documentID: UUID, blockID: String, stateRead: StateRead) throws -> NotebookDocumentBlockRead? {
    guard !blockID.isEmpty, blockID.utf16.count <= 120 else {
      throw NotebookStorageError.invalidTransaction("document block address")
    }
    return try readTransaction { _ -> NotebookDocumentBlockRead? in
      guard try readItemHeader(documentID)?.kind == .document else { throw CocoaError(.fileNoSuchFile) }
      let sourceFile = documentFile(documentID), journalFile = stateFile(documentID)
      let sourceRoot = sourceFile + "#", journalRoot = journalFile + "#"
      let member = fieldKey([collaborationIdentity(blockID)])
      let sourceAddress = sourceRoot + "/blocks/@" + member, stateAddress = journalRoot + "/records/@" + member
      let sourceFields = ["content", "css", "javaScript", "initialState"].map { field in
        (field, fieldKey(["blocks", collaborationIdentity(blockID), field]))
      }
      let clockReads = sourceFields.map { (sourceRoot + "/collaboration/fields/@" + fieldKey([$0.1]), false) }
      let stateInEnvelope: [(String, Bool)] = if case .publicEnvelope = stateRead { [(stateAddress, true)] } else { [] }
      var admittedRows = try boundedStoredFragments([(sourceRoot, false), (journalRoot, false),
        (sourceAddress, true)] + stateInEnvelope + clockReads, maximumCount: 4_096,
        maximumBytes: 4 * 1_024 * 1_024, budget: "document_block_read")
      if case .admitted(let bytes) = stateRead {
        admittedRows += try programStateFragments(address: stateAddress, admittedBytes: bytes)
      }
      let fragments = Dictionary(uniqueKeysWithValues: admittedRows.map { ($0.address, $0) })
      guard let root = fragments[sourceRoot], let stateRoot = fragments[journalRoot] else {
        throw NotebookStorageError.corruptRecord("document block headers")
      }
      let document = try NotebookRecordCodec.decode([root], root: sourceRoot).decode(DocumentDocument.self)
      guard document.id == documentID, document.isValid,
        try NotebookRecordCodec.encode(.encode(document), file: sourceFile) == [root] else {
        throw NotebookStorageError.corruptRecord(sourceRoot)
      }
      let stateHeader = try documentStateHeader(stateRoot, id: documentID)
      guard fragments[sourceAddress] != nil else { return nil }
      func rows(at address: String) -> [NotebookStoredFragment] {
        fragments.values.filter { $0.address == address || $0.address.hasPrefix(address + "/") }
      }
      let blockRows = rows(at: sourceAddress)
      let blockValue = try NotebookRecordCodec.decode(blockRows, root: sourceAddress)
      let block = try blockValue.decode(DocumentBlock.self)
      guard block.isValid, collaborationIdentity(block.id) == collaborationIdentity(blockID) else {
        throw NotebookStorageError.corruptRecord(sourceAddress)
      }
      func requireExactMember(_ members: [NotebookStoredFragment], value: JSONValue, root: NotebookStoredFragment,
        collection: String, file: String) throws {
        let actual = Dictionary(uniqueKeysWithValues: members.map { ($0.address, $0) })
        let expected = try NotebookRecordCodec.encode(root.value.setting(collection, .array([value])), file: file)
          .filter { $0.address != root.address }
        guard expected.count == actual.count, expected.allSatisfy({ row in
          guard let stored = actual[row.address] else { return false }
          return row.replacing(value: row.value, position: stored.position) == stored
        }) else { throw NotebookStorageError.corruptRecord(file) }
      }
      try requireExactMember(blockRows, value: .encode(block), root: root, collection: "blocks", file: sourceFile)
      var versions: [String: ContentFieldVersion] = [:]
      for (field, key) in sourceFields {
        let address = sourceRoot + "/collaboration/fields/@" + fieldKey([key])
        guard let row = fragments[address] else { continue }
        let version = try row.value.decode(ContentFieldVersion.self)
        guard version.isValid,
          row == NotebookStoredFragment(address: address, file: sourceFile, parent: sourceRoot,
            collection: "collaboration/fields", member: key, position: 0,
            value: try .encode(version), collections: []) else {
          throw NotebookStorageError.corruptRecord(address)
        }
        versions[field] = version
      }
      let sourceVersion = versions["content"] ?? document.sourceVersion(blockID: blockID)
      let programIdentity = DocumentProgramIdentity(versions: versions, fallback: document.contentStamp)
      let stateRows = rows(at: stateAddress)
      let state: DocumentStateRecord?
      if stateRows.isEmpty { state = nil }
      else {
        let record = try NotebookRecordCodec.decode(stateRows, root: stateAddress).decode(DocumentStateRecord.self)
        guard collaborationIdentity(record.id) == collaborationIdentity(block.id), record.isValid(in: stateHeader.stamp) else {
          throw NotebookStorageError.corruptRecord(stateAddress)
        }
        try requireExactMember(stateRows, value: .encode(record), root: stateRoot, collection: "records", file: journalFile)
        state = record
      }
      return .init(documentID: documentID, contentStamp: document.contentStamp, stateStamp: stateHeader.stamp,
        sourceVersion: sourceVersion, programIdentity: programIdentity, stateVersion: state?.valueVersion,
        block: block, state: state?.value)
    }
  }
}

import Foundation

/// One instance and its state share a WAL snapshot. Inspection neither stages
/// executable resources nor runs the program; the files remain authoritative.
public struct NotebookDocumentProgramRead: Codable, Sendable {
  public let documentID: UUID
  public let instanceID: String
  public let programPath: String
  public let sourceBasis: String
  public let initialState: JSONValue
  public let state: JSONValue
  public let stateVersion: ContentFieldVersion?
}

extension NotebookStore {
  public func readDocumentProgram(documentID: UUID, instanceID: String, programPath: String) throws -> NotebookDocumentProgramRead {
    try readDocumentProgram(documentID: documentID, instanceID: instanceID, programPath: programPath, admittedBytes: nil)
  }

  /// Runtime callers reserve transient credit before materializing a large
  /// state. The public inspection envelope stays bounded independently.
  public func readDocumentProgramState(documentID: UUID, instanceID: String, programPath: String,
    admittedBytes: Int) throws -> NotebookDocumentProgramRead {
    guard admittedBytes > 0 else { throw NotebookStorageError.limitExceeded("program_state_admission") }
    return try readDocumentProgram(documentID: documentID, instanceID: instanceID, programPath: programPath,
      admittedBytes: admittedBytes)
  }

  /// State commits validate executable files without decoding the state again.
  func readDocumentProgramSource(documentID: UUID, instanceID: String, programPath: String) throws -> DocumentProgramSource? {
    let document = try documentProgramProjection(documentID: documentID, programPath: programPath)
    return try? DocumentProgramSource(document: document, instanceID: instanceID, path: programPath)
  }

  /// Directory predicates are evaluated in SQLite. Only the selected resource
  /// bodies and clocks cross into the program reader, not a neighbouring chapter.
  func documentProgramProjection(documentID: UUID, programPath: String) throws -> DocumentDocument {
    guard DocumentFile.validPath(programPath) else { throw NotebookStorageError.invalidTransaction("document program path") }
    let root = documentFile(documentID) + "#"
    func members(prefix: String? = nil, paths: [String] = []) throws -> Set<String> {
      let predicate: String, bindings: [NotebookSQLValue]
      if let prefix {
        predicate = "substr(json_extract(CAST(b.data AS TEXT),'$.value.path'),1,length(?))=?"
        bindings = [.text(prefix), .text(prefix)]
      } else {
        guard !paths.isEmpty else { return [] }
        predicate = "json_extract(CAST(b.data AS TEXT),'$.value.path') IN (" + Array(repeating: "?", count: paths.count).joined(separator: ",") + ")"
        bindings = paths.map(NotebookSQLValue.text)
      }
      let rows = try currentSQL!.rows("SELECT r.member FROM records r JOIN blobs b ON b.hash=r.hash WHERE r.parent=? AND r.collection='files' AND " + predicate + " LIMIT 4097",
        [.text(root)] + bindings)
      guard rows.count <= DocumentDocument.maximumFileCount else { throw NotebookStorageError.limitExceeded("document_files") }
      return Set(try rows.map { row in
        guard let member = row[0].text else { throw NotebookStorageError.corruptRecord(root) }
        return member
      })
    }
    let configIDs = try members(paths: [programPath + "/program.json"])
    let config = try documentFilesProjection(documentID: documentID, fileIDs: configIDs)
    guard let config else { throw CocoaError(.fileNoSuchFile) }
    let (_, dependencies) = try DocumentProgramSource.configuration(config.files.first)
    let selected = try members(prefix: programPath + "/").union(members(paths: dependencies))
    guard let document = try documentFilesProjection(documentID: documentID, fileIDs: selected) else { throw CocoaError(.fileNoSuchFile) }
    return document
  }

  private func readDocumentProgram(documentID: UUID, instanceID: String, programPath: String,
    admittedBytes: Int?) throws -> NotebookDocumentProgramRead {
    try readTransaction { _ in
      guard try readItemHeader(documentID)?.kind == .document else { throw CocoaError(.fileNoSuchFile) }
      let source = try DocumentProgramSource(document: documentProgramProjection(documentID: documentID, programPath: programPath), instanceID: instanceID, path: programPath)
      let file = stateFile(documentID), rootAddress = file + "#"
      guard let root = try storedFragments(address: rootAddress, descendants: false).first else {
        throw NotebookStorageError.corruptRecord(rootAddress)
      }
      let header = try documentStateHeader(root, id: documentID)
      let address = rootAddress + "/records/@" + fieldKey([collaborationIdentity(instanceID)])
      let rows: [NotebookStoredFragment]
      if let admittedBytes { rows = try programStateFragments(address: address, admittedBytes: admittedBytes) }
      else {
        rows = try boundedStoredFragments([(address, true)], maximumCount: 4096,
          maximumBytes: 4 * 1_024 * 1_024, budget: "document_program_state")
      }
      let record = try rows.isEmpty ? nil : NotebookRecordCodec.decode(rows, root: address).decode(DocumentStateRecord.self)
      if let record {
        guard collaborationIdentity(record.id) == collaborationIdentity(instanceID), record.isValid(in: header.stamp) else {
          throw NotebookStorageError.corruptRecord(address)
        }
        let actual = Dictionary(uniqueKeysWithValues: rows.map { ($0.address, $0) })
        let expected = try NotebookRecordCodec.encode(root.value.setting("records", .array([try .encode(record)])), file: file)
          .filter { $0.address != rootAddress }
        guard expected.count == actual.count, expected.allSatisfy({ row in
          guard let stored = actual[row.address] else { return false }
          return row.replacing(value: row.value, position: stored.position) == stored
        }) else { throw NotebookStorageError.corruptRecord(address) }
      }
      return .init(documentID: documentID, instanceID: instanceID, programPath: programPath,
        sourceBasis: source.sourceBasis, initialState: source.initialState, state: record?.value ?? source.initialState,
        stateVersion: record?.valueVersion)
    }
  }
}

import Foundation

public struct NotebookDocumentFileRead: Codable, Equatable, Sendable {
  public let documentID: UUID
  public let contentStamp: VersionStamp
  public let sourceVersion: ContentFieldVersion
  public let file: DocumentFile
}

public struct NotebookDocumentDirectory: Codable, Sendable {
  public struct Entry: Codable, Sendable {
    public let id: String
    public let path: String
    public let byteCount: Int64
    public let mimeType: String
    public let sourceVersion: ContentFieldVersion
  }
  public let documentID: UUID
  public let entrypoint: String
  public let contentStamp: VersionStamp
  public let files: [Entry]
}

extension NotebookStore {
  /// The addressed file and its causal clocks are read in one WAL snapshot.
  public func readDocumentFile(documentID: UUID, fileID: String) throws -> NotebookDocumentFileRead? {
    try readTransaction { _ in
      guard let document = try documentFileProjection(documentID: documentID, fileID: fileID), let file = document.files.first else { return nil }
      return .init(documentID: documentID, contentStamp: document.contentStamp, sourceVersion: document.fileVersion(fileID: fileID), file: file)
    }
  }

  func documentFileProjection(documentID: UUID, fileID: String) throws -> DocumentDocument? {
    try documentFilesProjection(documentID: documentID, fileIDs: [fileID])
  }

  /// Reused by an editor's one file and a program's declared resource cut.
  /// Neither caller decodes unrelated authored files or their retained clocks.
  func documentFilesProjection(documentID: UUID, fileIDs: Set<String>) throws -> DocumentDocument? {
    guard fileIDs.count <= DocumentDocument.maximumFileCount,
      fileIDs.allSatisfy({ !$0.isEmpty && $0.utf16.count <= 120 }) else {
      throw NotebookStorageError.invalidTransaction("document file address")
    }
    guard try readItemHeader(documentID)?.kind == .document else { return nil }
    let file = documentFile(documentID), root = file + "#"
    let ids = Set(fileIDs.map(collaborationIdentity))
    let addresses = [(root, false)] + ids.sorted().flatMap { id in
      [(root + "/files/@" + fieldKey([id]), true)] + DocumentFile.causalFieldKeys(id: id).map {
        (root + "/collaboration/fields/@" + fieldKey([$0]), false)
      }
    }
    let rows = try boundedStoredFragments(addresses, maximumCount: max(4096, ids.count * 8 + 1),
      maximumBytes: 16 * 1_024 * 1_024, budget: "document_file_read")
    guard !rows.isEmpty else { return nil }
    let value = try NotebookRecordCodec.decode(rows, root: root), document = try value.decode(DocumentDocument.self)
    let actual = Dictionary(uniqueKeysWithValues: rows.map { ($0.address, $0) })
    let canonical = try NotebookRecordCodec.encode(.encode(document), file: file)
    guard document.id == documentID, document.files.count <= ids.count,
      document.files.allSatisfy({ ids.contains(collaborationIdentity($0.id)) }),
      canonical.count == actual.count, canonical.allSatisfy({ actual[$0.address] == $0 }) else {
      throw NotebookStorageError.corruptRecord(root)
    }
    return document
  }

  public func readDocumentDirectory(documentID: UUID) throws -> NotebookDocumentDirectory {
    try readTransaction { _ in
      guard try readItemHeader(documentID)?.kind == .document else { throw CocoaError(.fileNoSuchFile) }
      let file = documentFile(documentID), root = file + "#"
      guard let row = try boundedStoredFragments([(root, false)], maximumCount: 1, maximumBytes: 1_048_576, budget: "document_directory").first else {
        throw NotebookStorageError.corruptRecord(root)
      }
      let header = try documentSourceHeader(row, id: documentID)
      // SQLite extracts metadata without copying every text body into the directory.
      let records = try currentSQL!.rows("""
        SELECT r.member,json_extract(CAST(b.data AS TEXT),'$.value.id'),json_extract(CAST(b.data AS TEXT),'$.value.path'),
          COALESCE(json_extract(CAST(b.data AS TEXT),'$.value.resource.byteCount'),length(CAST(json_extract(CAST(b.data AS TEXT),'$.value.source') AS BLOB)))
        FROM records r JOIN blobs b ON b.hash=r.hash WHERE r.parent=? AND r.collection='files' ORDER BY r.member LIMIT 4097
        """, [.text(root)])
      guard records.count <= DocumentDocument.maximumFileCount else { throw NotebookStorageError.limitExceeded("document_files") }
      let entries = try records.map { row -> NotebookDocumentDirectory.Entry in
        guard let member = row[0].text, let id = row[1].text, let path = row[2].text, let bytes = row[3].integer,
          member == collaborationIdentity(id), DocumentFile.validPath(path), bytes >= 0 else { throw NotebookStorageError.corruptRecord(root) }
        let fields = try boundedStoredFragments(DocumentFile.causalFieldKeys(id: id).map {
          (root + "/collaboration/fields/@" + fieldKey([$0]), false)
        }, maximumCount: 4, maximumBytes: 16 * 1_024 * 1_024, budget: "document_file_version")
        let versions = try fields.map { try $0.value.decode(ContentFieldVersion.self) }
        let version = ContentFieldVersion.fileBasis(versions, fallback: header.contentStamp)
        return .init(id: id, path: path, byteCount: bytes, mimeType: NotebookProgramPackage.mimeType(for: path), sourceVersion: version)
      }
      guard Set(entries.map(\.path)).count == entries.count else { throw NotebookStorageError.corruptRecord(root) }
      return .init(documentID: documentID, entrypoint: header.entrypoint, contentStamp: header.contentStamp, files: entries)
    }
  }
}

extension NotebookStore {
  /// Validate the merged directory, including siblings absent from a command's
  /// projection. No source text is decoded to check names or total size.
  func validateDocumentFileNamespace(file: String, replacing document: DocumentDocument? = nil) throws {
    let rows = try currentSQL!.rows("""
      SELECT r.member,json_extract(CAST(b.data AS TEXT),'$.value.path'),
        COALESCE(json_extract(CAST(b.data AS TEXT),'$.value.resource.byteCount'),length(CAST(json_extract(CAST(b.data AS TEXT),'$.value.source') AS BLOB)))
      FROM records r JOIN blobs b ON b.hash=r.hash WHERE r.parent=? AND r.collection='files' ORDER BY r.member LIMIT 4097
      """, [.text(file + "#")])
    var files: [String: (String, Int64)] = [:]
    for row in rows {
      guard let id = row[0].text, let path = row[1].text, let size = row[2].integer, size >= 0 else { throw NotebookStorageError.corruptRecord(file) }
      files[id] = (path, size)
    }
    if let document {
      for key in document.collaboration?.fields.keys ?? Dictionary<String, ContentFieldVersion>().keys {
        let parts = key.split(separator: "/")
        if parts.count == 3, parts[0] == "files", parts[2] == "exists" {
          let id = String(parts[1]).replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
          files[id] = nil
        }
      }
      for file in document.files { files[collaborationIdentity(file.id)] = (file.path, file.byteCount) }
    }
    guard files.count <= DocumentDocument.maximumFileCount, Set(files.values.map(\.0)).count == files.count,
      files.values.allSatisfy({ DocumentFile.validPath($0.0) }),
      files.values.reduce(Int64(0), { $0 + $1.1 }) <= DocumentDocument.maximumSourceBytes else {
      throw CollaborationError("invalid_document_directory", "Пути файлов уникальны, до 4096 файлов и 16 МиБ суммарно.")
    }
  }
}

import CryptoKit
import Darwin
import Foundation

/// A trusted local-file capability. It stages immutable bytes only; attaching
/// them to a document still requires the ordinary putDocumentFile CAS command.
public struct NotebookDocumentResourceImportRequest: Codable, Sendable {
  public let filePath: String
  public let path: String
  public let sha256: String
  public init(filePath: String, path: String, sha256: String) {
    self.filePath = filePath; self.path = path; self.sha256 = sha256
  }
}

public struct NotebookDocumentResourceImport: Sendable {
  public let fileURL: URL
  public let sha256: String
  public let resource: NotebookProgramPackage.File

  /// Preparation has no store access and runs outside the persistence queue.
  public static func prepare(_ request: NotebookDocumentResourceImportRequest) throws -> Self {
    guard request.filePath.hasPrefix("/"), !request.filePath.contains("\0"), request.filePath.utf8.count <= 4096,
      DocumentFile.validPath(request.path), NotebookProgramPackage.validHash(request.sha256) else {
      throw CollaborationError("invalid_document_resource", "Нужны абсолютный путь файла, относительный путь ресурса и SHA-256.")
    }
    let url = URL(fileURLWithPath: request.filePath)
    let file = try NotebookProgramImport.openRegularFile(url); defer { try? file.close() }
    var before = stat()
    guard fstat(file.fileDescriptor, &before) == 0, before.st_size >= 0,
      before.st_size <= Int64(DocumentDocument.maximumSourceBytes) else {
      throw NotebookStorageError.limitExceeded("document_resource_import")
    }
    var whole = SHA256(), parts: [NotebookProgramPackage.Part] = [], position: Int64 = 0
    while position < before.st_size {
      try Task.checkCancellation()
      let count = Int(min(Int64(NotebookProgramPackage.partBytes), before.st_size-position))
      var data = Data()
      while data.count < count {
        let chunk = try file.read(upToCount: count-data.count) ?? Data()
        guard !chunk.isEmpty else { throw NotebookStorageError.invalidTransaction("document resource changed") }
        data.append(chunk)
      }
      whole.update(data: data)
      parts.append(.init(sha256: NotebookProgramPackage.hash(data), byteCount: data.count))
      position += Int64(data.count)
    }
    var after = stat()
    guard (try file.read(upToCount: 1) ?? Data()).isEmpty, fstat(file.fileDescriptor, &after) == 0,
      before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
      throw NotebookStorageError.invalidTransaction("document resource changed")
    }
    let hash = whole.finalize().map { String(format: "%02x", $0) }.joined()
    guard hash == request.sha256 else { throw NotebookStorageError.blobHashMismatch }
    let resource = NotebookProgramPackage.File(path: request.path,
      mimeType: NotebookProgramPackage.mimeType(for: request.path), byteCount: position, parts: parts)
    try resource.validate()
    return .init(fileURL: url, sha256: hash, resource: resource)
  }
}

public struct NotebookDocumentFileBytes: Codable, Sendable {
  public let documentID: UUID
  public let fileID: String
  public let path: String
  public let mimeType: String
  public let sourceVersion: ContentFieldVersion
  public let offset: Int64
  public let byteCount: Int
  public let totalBytes: Int64
  public let eof: Bool
  public let base64: String
}

extension NotebookStore {
  /// The source CAS and selected byte window belong to the same read snapshot.
  /// No arbitrary SHA or local path from the reader can grant a blob capability.
  public func readDocumentFileBytes(documentID: UUID, fileID: String, sourceVersion: ContentFieldVersion,
    offset: Int64, maxBytes: Int) throws -> NotebookDocumentFileBytes {
    guard offset >= 0, (1...1_048_576).contains(maxBytes) else {
      throw CollaborationError("invalid_resource_range", "Нужен диапазон до 1 MiB с неотрицательным смещением.")
    }
    return try readTransaction { _ in
      let target = CollaborationTarget(kind: .document, id: documentID)
      guard let addressed = try readDocumentFile(documentID: documentID, fileID: fileID) else {
        throw CollaborationError("target_missing", "Файл отсутствует.", target: target)
      }
      guard addressed.sourceVersion == sourceVersion else {
        throw CollaborationError("file_conflict", "Файл изменился. Прочитайте его новую версию.", target: target)
      }
      let file = addressed.file
      guard offset <= file.byteCount else { throw CollaborationError("invalid_resource_range", "Смещение выходит за конец файла.") }
      let bytes: Data
      if let resource = file.resource { bytes = try readProgramFile(resource, offset: offset, maxBytes: maxBytes) }
      else {
        let data = Data(file.source.utf8), start = Int(offset)
        bytes = data.subdata(in: start..<min(data.count, start+maxBytes))
      }
      return .init(documentID: documentID, fileID: file.id, path: file.path, mimeType: file.mimeType,
        sourceVersion: addressed.sourceVersion, offset: offset, byteCount: bytes.count, totalBytes: file.byteCount,
        eof: offset+Int64(bytes.count) == file.byteCount, base64: bytes.base64EncodedString())
    }
  }
}

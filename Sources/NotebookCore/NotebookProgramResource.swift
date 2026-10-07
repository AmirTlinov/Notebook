import Foundation

/// An admitted immutable file descriptor. The package capability owns its
/// lifetime; range reads validate only their bounds and touched SHA blobs.
public struct NotebookProgramResource: Sendable {
  fileprivate let file: NotebookProgramPackage.File
  public var path: String { file.path }
  public var mimeType: String { file.mimeType }
  public var byteCount: Int64 { file.byteCount }

  public init(_ file: NotebookProgramPackage.File) throws {
    try file.validate()
    self.file = file
  }
}

extension NotebookStore {
  /// Raw public descriptors always pass complete namespace/part validation.
  public func readProgramFile(_ file: NotebookProgramPackage.File, offset: Int64, maxBytes: Int) throws -> Data {
    try readProgramResource(NotebookProgramResource(file), offset: offset, maxBytes: maxBytes)
  }

  /// Each read owns one SQLite cut and the existing bounded byte window. An
  /// untouched part is not inspected again after capability registration.
  public func readProgramResource(_ resource: NotebookProgramResource, offset: Int64, maxBytes: Int) throws -> Data {
    let file = resource.file
    guard offset >= 0, offset <= file.byteCount, (1...1_048_576).contains(maxBytes) else {
      throw NotebookStorageError.invalidTransaction("program resource range")
    }
    return try readTransaction { snapshot in
      var result = Data(), position = offset
      let end = offset + min(Int64(maxBytes), file.byteCount - offset)
      while position < end {
        try Task.checkCancellation()
        let partIndex = Int(position / Int64(NotebookProgramPackage.partBytes))
        let part = file.parts[partIndex], inside = position % Int64(NotebookProgramPackage.partBytes)
        guard try snapshot.blobSize(hash: part.sha256) == part.byteCount else { throw NotebookStorageError.blobHashMismatch }
        let count = Int(min(end - position, Int64(part.byteCount) - inside))
        let data = try snapshot.readBlobChunk(hash: part.sha256, offset: inside, maxBytes: count)
        guard data.count == count else { throw NotebookStorageError.blobHashMismatch }
        result.append(data); position += Int64(count)
      }
      return result
    }
  }
}

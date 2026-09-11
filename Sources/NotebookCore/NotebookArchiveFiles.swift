import CryptoKit
import Darwin
import Foundation

public struct NotebookArchiveFileProof: Codable, Equatable, Sendable {
  public let path: String
  public let bytes: UInt64
  public let sha256: String
}

/// Opaque file evidence. Even a previous archive is only hashed here, never
/// decoded. The external converter alone understands previous domain formats.
public struct NotebookArchiveFingerprint: Codable, Equatable, Sendable {
  public let files: [NotebookArchiveFileProof]
  public var sha256: String { get throws { try collaborationHash(files) } }

  public static func read(_ root: URL) throws -> Self {
    let root = root.standardizedFileURL
    try NotebookArchiveFiles.requireDirectory(root)
    let manager = FileManager.default
    var enumerationError: Error?
    guard let enumerator = manager.enumerator(at: root,
      includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey],
      errorHandler: { _, error in enumerationError = error; return false }) else {
      throw NotebookStorageError.invalidTransaction("archive is not readable")
    }
    var files: [NotebookArchiveFileProof] = []
    for case let url as URL in enumerator {
      let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
      guard values.isSymbolicLink != true, values.isRegularFile == true || values.isDirectory == true else {
        throw NotebookStorageError.invalidTransaction("archive contains a link or special file")
      }
      if values.isDirectory == true { continue }
      guard files.count < 2_000_000 else { throw NotebookStorageError.limitExceeded("archive_files") }
      let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
      guard descriptor >= 0 else { throw NotebookArchiveFiles.failure("open archive file") }
      let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
      defer { try? handle.close() }
      var hash = SHA256(), size: UInt64 = 0
      while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
        try Task.checkCancellation()
        hash.update(data: data); size += UInt64(data.count)
      }
      let path = url.standardizedFileURL.path
      guard path.hasPrefix(root.path + "/") else { throw NotebookStorageError.invalidTransaction("archive file escaped root") }
      files.append(.init(path: String(path.dropFirst(root.path.count + 1)), bytes: size,
        sha256: hash.finalize().map { String(format: "%02x", $0) }.joined()))
    }
    if let enumerationError { throw enumerationError }
    return .init(files: files.sorted { $0.path < $1.path })
  }
}

enum NotebookArchiveFiles {
  static let maximumControlBytes = 256 * 1024 * 1024
  static func requireDirectory(_ url: URL) throws {
    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw NotebookStorageError.invalidTransaction("archive directory is missing or is a link")
    }
  }

  static func failure(_ operation: String) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: operation])
  }

  static func read<T: Decodable>(_ type: T.Type, at url: URL, maximumBytes: Int = 16_384) throws -> T {
    let properties = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
    guard properties.isSymbolicLink != true, properties.isRegularFile == true,
      let bytes = properties.fileSize, bytes <= maximumBytes, maximumBytes <= maximumControlBytes else {
      throw NotebookStorageError.invalidTransaction("invalid archive control file")
    }
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw failure("open archive control file") }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
    guard data.count <= maximumBytes else { throw NotebookStorageError.limitExceeded("archive_control") }
    return try JSONDecoder().decode(type, from: data)
  }

  /// The rename publishes only bytes already forced to disk. A caller does not
  /// admit a model until the containing directory has also been synchronized.
  static func publish<T: Encodable>(_ value: T, at url: URL, withoutOverwriting: Bool = false) throws {
    let data = try NotebookStore.storageEncoder.encode(value)
    guard data.count <= maximumControlBytes else { throw NotebookStorageError.limitExceeded("archive_control") }
    let temporary = url.deletingLastPathComponent().appendingPathComponent(".publish-" + UUID().uuidString)
    let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw failure("create archive control file") }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
    try handle.write(contentsOf: data)
    guard fsync(descriptor) == 0, fcntl(descriptor, F_FULLFSYNC) == 0 else { throw failure("flush archive control file") }
    let published = withoutOverwriting ? renamex_np(temporary.path, url.path, UInt32(RENAME_EXCL)) : rename(temporary.path, url.path)
    guard published == 0 else { throw failure("publish archive control file") }
    try syncDirectory(url.deletingLastPathComponent())
  }

  static func syncDirectory(_ root: URL) throws {
    let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw failure("open archive directory") }
    defer { close(descriptor) }
    guard fsync(descriptor) == 0 else { throw failure("flush archive directory") }
  }

  static func syncFile(_ url: URL) throws {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw failure("open prepared archive") }
    defer { close(descriptor) }
    guard fsync(descriptor) == 0, fcntl(descriptor, F_FULLFSYNC) == 0 else { throw failure("flush prepared archive") }
  }

  static func syncTree(_ root: URL, proof: NotebookArchiveFingerprint,
    syncFile: (URL) throws -> Void = NotebookArchiveFiles.syncFile) throws {
    for file in proof.files { try syncFile(root.appendingPathComponent(file.path)) }
    let directories = Set(proof.files.flatMap { file -> [String] in
      var path = (file.path as NSString).deletingLastPathComponent, result: [String] = []
      while !path.isEmpty { result.append(path); path = (path as NSString).deletingLastPathComponent }
      return result
    })
    for path in directories.sorted(by: { $0.count > $1.count }) { try syncDirectory(root.appendingPathComponent(path)) }
    try syncDirectory(root)
  }
}

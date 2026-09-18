import Foundation
import Darwin

/// The local Mac file capability is separate from the sandboxed author program.
/// Only this typed import descriptor can name files; none of its paths become
/// shared document content or browser capabilities.
public struct NotebookProgramImport: Codable, Sendable {
  public let packageHash: String
  public let package: NotebookProgramPackage
  public let sources: [Source]
  public struct Source: Codable, Sendable {
    public let path: String
    public let sourcePath: String
    public init(path: String, sourcePath: String) { self.path = path; self.sourcePath = sourcePath }
  }
  public init(packageHash: String, package: NotebookProgramPackage, sources: [Source]) {
    self.packageHash = packageHash; self.package = package; self.sources = sources
  }

  public func validate(expectedHash: String) throws {
    guard packageHash == expectedHash, try package.sha256 == expectedHash,
      sources.count == package.files.count, Set(sources.map(\.path)) == Set(package.files.map(\.path)),
      sources.allSatisfy({ $0.sourcePath.hasPrefix("/") && !$0.sourcePath.contains("\0") && $0.sourcePath.utf8.count <= 4096 }) else {
      throw NotebookStorageError.invalidTransaction("program import descriptor")
    }
  }

  static func openRegularFile(_ file: URL) throws -> FileHandle {
    // Nonblocking open plus fstat prevents a named pipe/device from capturing
    // the shared writer indefinitely. A final symlink is not an import file.
    let fd = file.withUnsafeFileSystemRepresentation { path in
      path.map { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW) } ?? -1
    }
    guard fd >= 0 else { throw NotebookStorageError.invalidTransaction("program import file open") }
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
      Darwin.close(fd); throw NotebookStorageError.invalidTransaction("program import requires a regular file")
    }
    return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
  }

  public static func read(file: URL, expectedHash: String) throws -> Self {
    guard file.isFileURL else { throw NotebookStorageError.invalidTransaction("program import file") }
    let input = try openRegularFile(file); defer { try? input.close() }
    let bytes = try input.read(upToCount: 2_097_153) ?? Data()
    guard bytes.count <= 2_097_152 else { throw NotebookStorageError.limitExceeded("program import metadata") }
    let descriptor = try JSONDecoder().decode(Self.self, from: bytes)
    try descriptor.validate(expectedHash: expectedHash)
    return descriptor
  }
}

public struct NotebookProgramImportRequest: Codable, Sendable {
  public enum Operation: String, Codable, Sendable { case start, status, cancel }
  public let op: Operation
  public let packageHash: String
  public let manifestPath: String?
  public init(op: Operation, packageHash: String, manifestPath: String? = nil) {
    self.op = op; self.packageHash = packageHash; self.manifestPath = manifestPath
  }
}

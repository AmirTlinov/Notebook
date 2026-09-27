import Foundation
import CryptoKit
import NotebookCore

public struct NotebookTypesetterFile: Codable, Sendable {
  public let path: String
  public let data: Data
  public init(path: String, data: Data) { self.path = path; self.data = data }
}
/// A closed, immutable namespace. The compiler cannot reach the blob store,
/// app container or a changing document while a pass is running.
public struct NotebookTypesetterInput: Sendable {
  public let entrypoint: String
  public let files: [NotebookTypesetterFile]
  public init(entrypoint: String, files: [NotebookTypesetterFile]) throws {
    self.entrypoint = entrypoint; self.files = files.sorted { $0.path < $1.path }
    try validate()
  }
  public init(document: DocumentDocument, readResource: ((DocumentFile) throws -> Data)? = nil) throws {
    let files = try document.files.map { file -> NotebookTypesetterFile in
      if file.resource != nil {
        guard let readResource else { throw NotebookTypesetterError("typesetter_resource_missing: \(file.path)") }
        return .init(path: file.path, data: try readResource(file))
      }
      return .init(path: file.path, data: Data(file.source.utf8))
    }
    try self.init(entrypoint: document.entrypoint, files: files)
    try validate(document: document)
  }
  public func validate() throws {
    guard (1...4096).contains(files.count), files.reduce(0, { $0+$1.data.count }) <= 16*1024*1024,
      files.allSatisfy({ Self.validPath($0.path) && $0.path != "notebook.sty" }),
      Set(files.map(\.path)).count == files.count else { throw NotebookTypesetterError("typesetter_input_limit_or_namespace") }
    let names = Set(files.map(\.path))
    for file in files {
      let components = file.path.split(separator: "/")
      if components.count > 1 {
        for end in 1..<components.count where names.contains(components.prefix(end).joined(separator: "/")) {
          throw NotebookTypesetterError("typesetter_file_directory_collision: \(file.path)")
        }
      }
    }
    guard entrypoint.hasSuffix(".tex"), let entry = files.first(where: { $0.path == entrypoint }),
      entry.data.count <= 4*1024*1024, String(data: entry.data, encoding: .utf8) != nil else {
      throw NotebookTypesetterError("typesetter_entrypoint_missing_encoding_or_limit")
    }
  }
  public func validate(document: DocumentDocument) throws {
    guard entrypoint == document.entrypoint, files.count == document.files.count else { throw NotebookTypesetterError("typesetter_input_snapshot_mismatch") }
    let input = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.data) })
    for file in document.files {
      guard let data = input[file.path] else { throw NotebookTypesetterError("typesetter_input_snapshot_mismatch") }
      if let resource = file.resource {
        guard data.count == resource.byteCount else { throw NotebookTypesetterError("typesetter_resource_hash_mismatch: \(file.path)") }
        var offset = 0
        for part in resource.parts {
          guard part.byteCount > 0, part.byteCount <= data.count-offset else { throw NotebookTypesetterError("typesetter_resource_hash_mismatch: \(file.path)") }
          let digest = SHA256.hash(data: data.subdata(in: offset..<offset+part.byteCount)).map { String(format: "%02x", $0) }.joined()
          guard digest == part.sha256 else { throw NotebookTypesetterError("typesetter_resource_hash_mismatch: \(file.path)") }
          offset += part.byteCount
        }
        guard offset == data.count else { throw NotebookTypesetterError("typesetter_resource_hash_mismatch: \(file.path)") }
      } else if data != Data(file.source.utf8) { throw NotebookTypesetterError("typesetter_input_snapshot_mismatch") }
    }
  }
  public static func validPath(_ path: String) -> Bool {
    !path.isEmpty && path.utf8.count <= 1024 && !path.contains("\\") && !path.contains("\0")
      && path.split(separator: "/", omittingEmptySubsequences: false).count <= 32
      && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
  }
}

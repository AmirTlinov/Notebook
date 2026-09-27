import CryptoKit
import Foundation

/// The compiler's observed input namespace. Failed lookup and directory reads
/// are dependencies too: adding a file may change TeX resolution without editing
/// any previously opened file. Causal clocks and program execution are separate.
public struct DocumentPrintDependencies: Codable, Equatable, Sendable {
  public struct Lookup: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case path, directory }
    public let kind: Kind
    public let path: String
    public let digest: String
  }
  public let entrypoint: String
  public let compilerRevision: String
  public let lookups: [Lookup]

  public init(records: Data, document: DocumentDocument, compilerRevision: String) throws {
    guard !records.isEmpty, records.count <= 4 * 1024 * 1024 else { throw Self.invalid() }
    var fields = records.split(separator: 0, omittingEmptySubsequences: false)
    guard fields.last?.isEmpty == true else { throw Self.invalid() }
    fields.removeLast()
    guard fields.count % 2 == 0, fields.count <= 65_536 else { throw Self.invalid() }
    var requests: [String: Lookup.Kind] = [:]
    for index in stride(from: 0, to: fields.count, by: 2) {
      let kind: Lookup.Kind
      if fields[index] == Data([112]) { kind = .path }
      else if fields[index] == Data([100]) { kind = .directory }
      else { throw Self.invalid() }
      guard let path = String(data: Data(fields[index + 1]), encoding: .utf8),
        path.isEmpty || Self.validLookup(path) else { throw Self.invalid() }
      requests[(kind == .path ? "p" : "d") + "\0" + path] = kind
    }
    guard requests["p\0" + document.entrypoint] == .path else { throw Self.invalid() }
    self.entrypoint = document.entrypoint; self.compilerRevision = compilerRevision
    lookups = try requests.keys.sorted().map { key in
      let kind = requests[key]!, path = String(key.dropFirst(2))
      return .init(kind: kind, path: path, digest: try Self.digest(kind: kind, path: path, document: document))
    }
  }

  /// An imported artifact without an observed read set safely binds the entire
  /// namespace. A later native compilation supplies the narrower actual set.
  public init(namespace document: DocumentDocument, compilerRevision: String) throws {
    entrypoint = document.entrypoint; self.compilerRevision = compilerRevision
    lookups = try [.init(kind: .directory, path: "", digest: Self.namespaceDigest(document))]
      + document.files.sorted { $0.path < $1.path }.map {
        .init(kind: .path, path: $0.path, digest: try Self.digest(kind: .path, path: $0.path, document: document))
      }
  }

  public func matches(_ document: DocumentDocument, compilerRevision: String) throws -> Bool {
    guard self.compilerRevision == compilerRevision, entrypoint == document.entrypoint,
      lookups.count <= 32_769 else { return false }
    for lookup in lookups {
      // Full namespace fallback is distinguishable from a real readdir digest.
      let digest = lookup.kind == .directory && lookup.path.isEmpty && lookup.digest.hasPrefix("namespace:")
        ? try Self.namespaceDigest(document) : try Self.digest(kind: lookup.kind, path: lookup.path, document: document)
      if lookup.digest != digest { return false }
    }
    return true
  }

  public var identity: String {
    get throws {
      struct Identity: Encodable { let recipe: String; let dependencies: DocumentPrintDependencies }
      return try Self.hash(Identity(recipe: DocumentPrintSourceMap.renderingRecipe, dependencies: self))
    }
  }
  public static func namespaceIdentity(_ document: DocumentDocument, compilerRevision: String) throws -> String {
    try DocumentPrintDependencies(namespace: document, compilerRevision: compilerRevision).identity
  }
  private static func namespaceDigest(_ document: DocumentDocument) throws -> String {
    "namespace:" + (try hash(document.files.map(\.path).sorted()))
  }
  private static func digest(kind: Lookup.Kind, path: String, document: DocumentDocument) throws -> String {
    let prefix = path.isEmpty ? "" : path + "/"
    if kind == .directory {
      var children: [String: String] = [:]
      for file in document.files where file.path.hasPrefix(prefix) {
        let tail = file.path.dropFirst(prefix.count), parts = tail.split(separator: "/")
        guard let first = parts.first else { continue }
        children[String(first)] = parts.count == 1 ? "file" : "directory"
      }
      return try hash(children)
    }
    if path.isEmpty { return "directory" }
    guard let file = document.files.first(where: { $0.path == path }) else {
      return document.files.contains { $0.path.hasPrefix(prefix) } ? "directory" : "missing"
    }
    if let resource = file.resource {
      struct Bytes: Encodable { let count: Int64; let parts: [NotebookProgramPackage.Part] }
      return "parts:" + (try hash(Bytes(count: resource.byteCount, parts: resource.parts)))
    }
    return "text:" + hash(Data(file.source.utf8))
  }
  private static func hash<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return hash(try encoder.encode(value))
  }
  private static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
  private static func validLookup(_ path: String) -> Bool {
    !path.isEmpty && path.utf8.count <= 1024 && !path.contains("\\") && !path.contains("\0")
      && path.split(separator: "/", omittingEmptySubsequences: false).count <= 32
      && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
  }
  private static func invalid() -> CollaborationError { .init("invalid_print_dependencies", "Некорректные зависимости печатной сборки.") }
}

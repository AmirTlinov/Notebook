import CryptoKit
import Foundation

/// The compiler's observed input namespace. Failed lookup and directory reads
/// are dependencies too: adding a file may change TeX resolution without editing
/// any previously opened file. Causal clocks and program execution are separate.
public struct DocumentPrintDependencies: Codable, Equatable, Sendable {
  /// One request's immutable source. Candidates and the eventual compilation
  /// share its path index and computed digests; causal state is never a cache key.
  public struct Source: Sendable {
    public let document: DocumentDocument
    public var entrypoint: String { document.entrypoint }
    private let fileIndexes: [String: Int]
    private var pathDigests: [String: String] = [:]
    private var directoryDigests: [String: String] = [:]
    private var emptyDirectoryDigest: String?
    private var lastPrefixIndex: Int?
    private var namespace: String?
    private var paths: [String]?

    public init(_ document: DocumentDocument) {
      self.document = document
      var files: [String: Int] = [:]
      files.reserveCapacity(document.files.count)
      for (index, file) in document.files.enumerated() {
        files[file.path] = index
      }
      fileIndexes = files
    }

    public func file(at path: String) -> DocumentFile? {
      fileIndexes[path].map { document.files[$0] }
    }

    public mutating func digest(at path: String) throws -> String {
      if path.isEmpty { return "directory" }
      if let digest = pathDigests[path] { return digest }
      guard let file = file(at: path) else {
        let prefix = path + "/", paths = orderedPaths()
        let start = lowerBound(prefix, in: paths)
        guard start < paths.count, paths[start].hasPrefix(prefix) else { return "missing" }
        pathDigests[path] = "directory"
        return "directory"
      }
      let digest: String
      if let resource = file.resource {
        struct Bytes: Encodable { let count: Int64; let parts: [NotebookProgramPackage.Part] }
        digest = "parts:" + (try DocumentPrintDependencies.hash(Bytes(count: resource.byteCount, parts: resource.parts)))
      } else { digest = "text:" + DocumentPrintDependencies.hash(Data(file.source.utf8)) }
      pathDigests[path] = digest
      return digest
    }

    fileprivate mutating func digest(kind: Lookup.Kind, path: String) throws -> String {
      if kind == .path { return try digest(at: path) }
      if let digest = directoryDigests[path] { return digest }
      let prefix = path.isEmpty ? "" : path + "/", paths = orderedPaths()
      var index = lowerBound(prefix, in: paths)
      guard index < paths.count, paths[index].hasPrefix(prefix) else {
        if let digest = emptyDirectoryDigest { return digest }
        let digest = try DocumentPrintDependencies.hash([String: String]())
        emptyDirectoryDigest = digest
        return digest
      }
      // Only the observed prefix range is visited. Across all directories a
      // file contributes at most once per path component (bounded to 32).
      var children: [String: (index: Int, kind: String)] = [:]
      while index < paths.count, paths[index].hasPrefix(prefix) {
        let filePath = paths[index], tail = filePath.dropFirst(prefix.count)
        let slash = tail.firstIndex(of: "/"), name = String(tail[..<(slash ?? tail.endIndex)])
        let fileIndex = fileIndexes[filePath]!
        // Preserve the original document-order winner if a file and directory
        // share a child name; sorting the range must not change its digest.
        if fileIndex > (children[name]?.index ?? -1) {
          children[name] = (fileIndex, slash == nil ? "file" : "directory")
        }
        index += 1
      }
      let digest = try DocumentPrintDependencies.hash(children.mapValues(\.kind))
      directoryDigests[path] = digest
      return digest
    }

    private mutating func lowerBound(_ prefix: String, in paths: [String]) -> Int {
      // Repeated probes often share the same gap in this immutable namespace.
      // Both neighbors prove the lower bound even when requests arrive unsorted.
      if let index = lastPrefixIndex,
        (index == 0 || paths[index - 1] < prefix),
        (index == paths.count || prefix <= paths[index]) { return index }
      var lower = 0, upper = paths.count
      while lower < upper {
        let middle = lower + (upper - lower) / 2
        if paths[middle] < prefix { lower = middle + 1 } else { upper = middle }
      }
      lastPrefixIndex = lower
      return lower
    }

    fileprivate mutating func orderedPaths() -> [String] {
      if let paths { return paths }
      let paths = fileIndexes.keys.sorted()
      self.paths = paths
      return paths
    }

    fileprivate mutating func namespaceDigest() throws -> String {
      if let namespace { return namespace }
      let namespace = "namespace:" + (try DocumentPrintDependencies.hash(orderedPaths()))
      self.namespace = namespace
      return namespace
    }
  }

  public struct Lookup: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case path, directory }
    public let kind: Kind
    public let path: String
    public let digest: String
  }
  public let entrypoint: String
  public let compilerRevision: String
  public let lookups: [Lookup]

  public init(records: Data, source: inout Source, compilerRevision: String) throws {
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
    guard requests["p\0" + source.entrypoint] == .path else { throw Self.invalid() }
    self.entrypoint = source.entrypoint; self.compilerRevision = compilerRevision
    lookups = try requests.keys.sorted().map { key in
      let kind = requests[key]!, path = String(key.dropFirst(2))
      return .init(kind: kind, path: path, digest: try source.digest(kind: kind, path: path))
    }
  }

  /// An imported artifact without an observed read set safely binds the entire
  /// namespace. A later native compilation supplies the narrower actual set.
  public init(namespace source: inout Source, compilerRevision: String) throws {
    entrypoint = source.entrypoint; self.compilerRevision = compilerRevision
    lookups = try [.init(kind: .directory, path: "", digest: source.namespaceDigest())]
      + source.orderedPaths().map { path in
        .init(kind: .path, path: path, digest: try source.digest(at: path))
      }
  }

  public func matches(_ source: inout Source, compilerRevision: String) throws -> Bool {
    guard self.compilerRevision == compilerRevision, entrypoint == source.entrypoint,
      lookups.count <= 32_769 else { return false }
    for lookup in lookups {
      // Full namespace fallback is distinguishable from a real readdir digest.
      let digest = lookup.kind == .directory && lookup.path.isEmpty && lookup.digest.hasPrefix("namespace:")
        ? try source.namespaceDigest() : try source.digest(kind: lookup.kind, path: lookup.path)
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
  public static func namespaceIdentity(_ source: inout Source, compilerRevision: String) throws -> String {
    try DocumentPrintDependencies(namespace: &source, compilerRevision: compilerRevision).identity
  }
  private static func hash<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return hash(try encoder.encode(value))
  }
  private static func hash(_ bytes: Data) -> String { NotebookHexEncoding.encode(SHA256.hash(data: bytes)) }
  private static func validLookup(_ path: String) -> Bool {
    !path.isEmpty && path.utf8.count <= 1024 && !path.contains("\\") && !path.contains("\0")
      && path.split(separator: "/", omittingEmptySubsequences: false).count <= 32
      && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
  }
  private static func invalid() -> CollaborationError { .init("invalid_print_dependencies", "Некорректные зависимости печатной сборки.") }
}

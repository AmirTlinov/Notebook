import CryptoKit
import Foundation

/// One publication's immutable file namespace. Bytes remain in the existing
/// SHA blob store; a large file is an ordered sequence of bounded blobs, not
/// one oversized transport message. The package hash binds paths/MIME/lengths
/// and every part hash. It is not advertised as a flat file checksum.
public struct NotebookProgramPackage: Codable, Equatable, Sendable {
  public static let partBytes = 4 * 1024 * 1024
  public static let maximumManifestBytes = 1_048_576
  public let format: Int
  public let html: String?
  public let css: String?
  public let javaScript: String?
  public let module: Bool
  public let files: [File]

  public struct Part: Codable, Equatable, Sendable {
    public let sha256: String
    public let byteCount: Int
    public init(sha256: String, byteCount: Int) { self.sha256 = sha256; self.byteCount = byteCount }
  }

  public struct File: Codable, Equatable, Sendable {
    public let path: String
    public let mimeType: String
    public let byteCount: Int64
    public let parts: [Part]
    public init(path: String, mimeType: String, byteCount: Int64, parts: [Part]) {
      self.path = path; self.mimeType = mimeType; self.byteCount = byteCount; self.parts = parts
    }
  }

  public init(html: String? = nil, css: String? = nil, javaScript: String? = nil, module: Bool = true, files: [File]) {
    format = 1; self.html = html; self.css = css; self.javaScript = javaScript; self.module = module; self.files = files
  }

  public static func validHash(_ hash: String) -> Bool {
    hash.utf8.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  /// A program has one authored source: inline, or this immutable namespace.
  /// Empty inline fields on a packaged source are intentional, not fallbacks.
  public static func validSourceReference(_ hash: String?, isProgram: Bool, source: String, html: String, css: String, javaScript: String) -> Bool {
    guard let hash else { return true }
    return isProgram && validHash(hash) && source.isEmpty && html.isEmpty && css.isEmpty && javaScript.isEmpty
  }

  public static func validPath(_ path: String) -> Bool {
    guard !path.isEmpty, path.utf8.count <= 512, !path.hasPrefix("/"), !path.hasSuffix("/"),
      path.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
        || [45, 46, 47, 64, 95].contains($0) }) else { return false }
    return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
  }

  /// MIME belongs to the immutable namespace, not an arbitrary response header.
  /// Unknown binary filenames can use application/octet-stream; executable and
  /// markup entrypoints have exact types and cannot silently reinterpret bytes.
  public static func mimeType(for path: String) -> String {
    let suffix = (path as NSString).pathExtension.lowercased()
    return ["html":"text/html", "htm":"text/html", "css":"text/css", "js":"text/javascript", "mjs":"text/javascript",
      "json":"application/json", "map":"application/json", "svg":"image/svg+xml", "png":"image/png",
      "jpg":"image/jpeg", "jpeg":"image/jpeg", "webp":"image/webp", "gif":"image/gif", "avif":"image/avif",
      "woff":"font/woff", "woff2":"font/woff2", "ttf":"font/ttf", "otf":"font/otf",
      "mp4":"video/mp4", "webm":"video/webm", "mp3":"audio/mpeg", "m4a":"audio/mp4", "wav":"audio/wav",
      "ogg":"audio/ogg", "wasm":"application/wasm", "gltf":"model/gltf+json", "glb":"model/gltf-binary",
      "csv":"text/csv", "txt":"text/plain"][suffix] ?? "application/octet-stream"
  }

  public func validate() throws {
    guard format == 1, (1...4096).contains(files.count), files.map(\.path) == files.map(\.path).sorted(),
      Set(files.map(\.path)).count == files.count, html != nil || javaScript != nil,
      files.reduce(0, { $0 + $1.parts.count }) <= 16_384 else {
      throw NotebookStorageError.invalidTransaction("program package namespace")
    }
    var sizes: [String: Int] = [:]
    for file in files {
      guard Self.validPath(file.path), file.mimeType == Self.mimeType(for: file.path), file.byteCount >= 0,
        file.parts.allSatisfy({ Self.validHash($0.sha256) && (1...Self.partBytes).contains($0.byteCount) }),
        file.parts.dropLast().allSatisfy({ $0.byteCount == Self.partBytes }),
        file.parts.reduce(Int64(0), { $0 + Int64($1.byteCount) }) == file.byteCount else {
        throw NotebookStorageError.invalidTransaction("program package file")
      }
      for part in file.parts {
        if let size = sizes[part.sha256], size != part.byteCount { throw NotebookStorageError.blobHashMismatch }
        sizes[part.sha256] = part.byteCount
      }
    }
    for (path, mime) in [(html, "text/html"), (css, "text/css"), (javaScript, "text/javascript")] {
      if let path, !files.contains(where: { $0.path == path && $0.mimeType == mime }) {
        throw NotebookStorageError.invalidTransaction("program package entry")
      }
    }
  }

  public func canonicalData() throws -> Data {
    try validate()
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(self)
    guard data.count <= Self.maximumManifestBytes else { throw NotebookStorageError.limitExceeded("program package manifest") }
    return data
  }

  public var sha256: String { get throws { Self.hash(try canonicalData()) } }
  static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

extension NotebookStore {
  /// This only admits the immutable descriptor after all its parts are staged.
  /// Publishing a scene still belongs to the normal causal transaction.
  public func stageProgramPackage(_ package: NotebookProgramPackage) throws -> String {
    let data = try package.canonicalData()
    return try commandTransaction {
      for part in package.files.flatMap(\.parts) {
        guard try blobSize(hash: part.sha256) == part.byteCount else { throw NotebookStorageError.blobHashMismatch }
      }
      return try currentSQL!.putBlob(data)
    }
  }

  public func readProgramPackage(_ hash: String) throws -> NotebookProgramPackage {
    guard NotebookProgramPackage.validHash(hash) else { throw NotebookStorageError.invalidTransaction("program package hash") }
    return try readTransaction { snapshot in
      let size = try snapshot.blobSize(hash: hash)
      guard (1...Int64(NotebookProgramPackage.maximumManifestBytes)).contains(size) else {
        throw NotebookStorageError.limitExceeded("program package manifest")
      }
      let data = try snapshot.readBlobChunk(hash: hash, offset: 0, maxBytes: Int(size))
      guard NotebookProgramPackage.hash(data) == hash else { throw NotebookStorageError.blobHashMismatch }
      let package = try JSONDecoder().decode(NotebookProgramPackage.self, from: data)
      guard try package.canonicalData() == data else { throw NotebookStorageError.invalidTransaction("program package canonical encoding") }
      return package
    }
  }

  /// The caller carries a descriptor read from its admitted publication. A
  /// browser never supplies a blob hash; the scoped adapter resolves its path.
  /// Each read owns one SQLite snapshot and at most the existing 1 MiB window.
  public func readProgramFile(_ file: NotebookProgramPackage.File, offset: Int64, maxBytes: Int) throws -> Data {
    guard offset >= 0, offset <= file.byteCount, (1...1_048_576).contains(maxBytes),
      file.byteCount >= 0, file.parts.count <= 16_384,
      file.parts.dropLast().allSatisfy({ $0.byteCount == NotebookProgramPackage.partBytes }),
      file.parts.allSatisfy({ NotebookProgramPackage.validHash($0.sha256) && (1...NotebookProgramPackage.partBytes).contains($0.byteCount) }),
      file.parts.reduce(Int64(0), { $0 + Int64($1.byteCount) }) == file.byteCount else {
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

import CryptoKit
import Foundation

/// One authored file address in the exact compiler snapshot, not generated TeX.
public struct DocumentPrintSourceFile: Codable, Equatable, Sendable {
  public let fileID: String
  public let path: String
  public let sha256: String
  public let lineCount: Int
  public init(fileID: String, path: String, sha256: String, lineCount: Int) {
    self.fileID = fileID; self.path = path; self.sha256 = sha256; self.lineCount = lineCount
  }
}

/// Derived addresses never own content. Both the causal snapshot and the full
/// compiler namespace are bound: a maximum version alone cannot identify a merge.
public struct DocumentPrintSourceMap: Codable, Equatable, Sendable {
  public static let renderingRecipe = "NotebookFilePrint/1"
  public let format: Int
  public let documentID: UUID
  public let documentRevision: String
  public let documentSHA256: String
  public let sourceSHA256: String
  public let inputSHA256: String
  public let compilerRevision: String
  public let pdfSHA256: String
  public let entrypoint: String
  public let files: [DocumentPrintSourceFile]

  public init(document: DocumentDocument, source: String, pdf: Data, compilerRevision: String) throws {
    try self.init(document: document, source: source, pdfSHA256: Self.digest(pdf), compilerRevision: compilerRevision)
  }
  /// Streaming export binds its separately validated PDF without copying it.
  public init(document: DocumentDocument, source: String, pdfSHA256: String, compilerRevision: String) throws {
    format = 2; documentID = document.id; documentRevision = document.contentStamp.revision
    documentSHA256 = try Self.documentDigest(document)
    sourceSHA256 = Self.digest(Data(source.utf8)); self.pdfSHA256 = pdfSHA256
    self.compilerRevision = compilerRevision; entrypoint = document.entrypoint
    files = Self.sourceFiles(document)
    inputSHA256 = try Self.inputDigest(document, compilerRevision: compilerRevision)
    try validate(document: document, source: source, pdfSHA256: pdfSHA256)
  }
  public func validate(document: DocumentDocument, source: String, pdf: Data) throws {
    try validate(document: document, source: source, pdfSHA256: Self.digest(pdf))
  }
  public func validate(document: DocumentDocument, source: String, pdfSHA256: String) throws {
    guard source.utf8.count <= 4*1024*1024, NotebookProgramPackage.validHash(pdfSHA256),
      NotebookProgramPackage.validHash(compilerRevision), format == 2,
      documentID == document.id, documentRevision == document.contentStamp.revision,
      documentSHA256 == (try Self.documentDigest(document)), entrypoint == document.entrypoint,
      document.files.first(where: { $0.path == entrypoint && $0.resource == nil })?.source == source,
      sourceSHA256 == Self.digest(Data(source.utf8)), self.pdfSHA256 == pdfSHA256,
      inputSHA256 == (try Self.inputDigest(document, compilerRevision: compilerRevision)), files == Self.sourceFiles(document)
    else { throw Self.invalid() }
  }
  /// An old-page edit retains its original field/version for the normal CAS.
  public func edit(fileID: String, snapshot: DocumentDocument, source: String,
    sessionID: UUID = UUID(), sequence: UInt64 = 1) throws -> DocumentSourceEdit {
    guard format == 2, documentID == snapshot.id, documentRevision == snapshot.contentStamp.revision,
      documentSHA256 == (try Self.documentDigest(snapshot)), files.contains(where: { $0.fileID == fileID }),
      let file = snapshot.files.first(where: { $0.id == fileID && $0.resource == nil }) else { throw Self.invalid() }
    return .init(sessionID: sessionID, documentID: documentID, fileID: fileID,
      baseSource: file.source, baseVersion: snapshot.fileVersion(fileID: fileID), source: source, sequence: sequence)
  }
  private static func sourceFiles(_ document: DocumentDocument) -> [DocumentPrintSourceFile] {
    document.files.filter { $0.resource == nil }.sorted { $0.path < $1.path }.map {
      .init(fileID: $0.id, path: $0.path, sha256: digest(Data($0.source.utf8)),
        lineCount: $0.source.utf8.reduce(1) { $1 == 10 ? $0+1 : $0 })
    }
  }
  /// Binary parts are already exact SHA-addressed bytes. Binding the ordered
  /// part manifest does not pretend that its hash is a flat file checksum.
  private static func inputDigest(_ document: DocumentDocument, compilerRevision: String) throws -> String {
    struct Namespace: Encodable {
      let recipe: String
      let compilerRevision: String
      let entrypoint: String
      let files: [DocumentFile]
    }
    return digest(try encode(Namespace(recipe: renderingRecipe, compilerRevision: compilerRevision,
      entrypoint: document.entrypoint, files: document.files.sorted { $0.path < $1.path })))
  }
  private static func documentDigest(_ document: DocumentDocument) throws -> String { digest(try encode(document)) }
  private static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }
  private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
  private static func invalid() -> CollaborationError {
    .init("invalid_print_source_map", "Печатные страницы и адреса файлов должны принадлежать одному точному исходнику и компилятору.")
  }
}

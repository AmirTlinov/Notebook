import CryptoKit
import Foundation

/// Addresses in the generated TeX, not in Markdown. Layout engines report
/// these one-based lines; no block identifier is interpolated into TeX code.
public struct DocumentPrintSourceRange: Codable, Equatable, Sendable {
  public let blockID: String
  public let firstLine: Int
  public let lastLine: Int
  /// Nearest authored paragraph (Markdown) or exact source line (TeX), UTF-16.
  public let sourceOffsets: [Int]?

  public init(blockID: String, firstLine: Int, lastLine: Int, sourceOffsets: [Int]? = nil) {
    self.blockID = blockID; self.firstLine = firstLine; self.lastLine = lastLine; self.sourceOffsets = sourceOffsets
  }
}

/// A derived address map, never a second content owner or an undo journal.
/// Its digest binds the complete causal snapshot: a maximum VersionStamp alone
/// cannot distinguish every concurrent merge that changes the visible source.
public struct DocumentPrintSourceMap: Codable, Equatable, Sendable {
  public static let renderingRecipe = "NotebookCanonicalPrint/3"

  public let format: Int
  public let documentID: UUID
  public let documentRevision: String
  public let documentSHA256: String
  public let sourceSHA256: String
  public let pdfSHA256: String
  public let ranges: [DocumentPrintSourceRange]

  public init(document: DocumentDocument, source: String, pdf: Data, ranges: [DocumentPrintSourceRange]) throws {
    try self.init(document: document, source: source, pdfSHA256: Self.digest(pdf), ranges: ranges)
  }

  /// Streaming export validates the file bytes separately, without rebuilding a
  /// whole PDF Data merely to bind its source map.
  public init(document: DocumentDocument, source: String, pdfSHA256: String, ranges: [DocumentPrintSourceRange]) throws {
    format = 1; documentID = document.id; documentRevision = document.contentStamp.revision
    documentSHA256 = try Self.documentDigest(document)
    sourceSHA256 = Self.digest(Data(source.utf8)); self.pdfSHA256 = pdfSHA256
    self.ranges = ranges
    try validate(document: document, source: source, pdfSHA256: pdfSHA256)
  }

  public func validate(document: DocumentDocument, source: String, pdf: Data) throws {
    try validate(document: document, source: source, pdfSHA256: Self.digest(pdf))
  }

  public func validate(document: DocumentDocument, source: String, pdfSHA256: String) throws {
    guard source.utf8.count <= 4 * 1024 * 1024, NotebookProgramPackage.validHash(pdfSHA256),
      format == 1, documentID == document.id, documentRevision == document.contentStamp.revision,
      documentSHA256 == (try Self.documentDigest(document)), sourceSHA256 == Self.digest(Data(source.utf8)),
      self.pdfSHA256 == pdfSHA256,
      ranges.map(\.blockID) == document.blocks.map(\.id) else { throw Self.invalid() }
    let lineCount = source.utf8.reduce(1) { $1 == 10 ? $0 + 1 : $0 }
    var previousEnd = 0
    for (range, block) in zip(ranges, document.blocks) {
      guard range.firstLine > previousEnd, range.lastLine >= range.firstLine,
        range.lastLine < lineCount,
        previousEnd == 0 || range.firstLine == previousEnd + 1 else { throw Self.invalid() }
      if let offsets = range.sourceOffsets {
        let sourceCount = block.source.utf16.count
        guard offsets.count == range.lastLine-range.firstLine+1, offsets.count <= 200_000,
          offsets.allSatisfy({ $0 >= 0 && $0 <= sourceCount }),
          zip(offsets, offsets.dropFirst()).allSatisfy({ $0 <= $1 }) else { throw Self.invalid() }
      }
      previousEnd = range.lastLine
    }
  }

  /// A hit on an old page must edit its original field, not silently adopt the
  /// latest text/version. The existing commit owner performs the causal CAS.
  public func edit(blockID: String, snapshot: DocumentDocument, source: String,
    sessionID: UUID = UUID(), sequence: UInt64 = 1) throws -> DocumentSourceEdit {
    guard format == 1, documentID == snapshot.id, documentRevision == snapshot.contentStamp.revision,
      documentSHA256 == (try Self.documentDigest(snapshot)),
      ranges.contains(where: { $0.blockID == blockID }),
      let block = snapshot.blocks.first(where: { $0.id == blockID }), block.kind != .interactive
    else { throw Self.invalid() }
    return .init(sessionID: sessionID, documentID: documentID, blockID: blockID,
      baseSource: block.source, baseVersion: snapshot.sourceVersion(blockID: blockID), source: source, sequence: sequence)
  }

  public func blockID(atGeneratedLine line: Int) -> String? {
    var low = 0, high = ranges.count
    while low < high {
      let middle = low + (high - low) / 2
      if ranges[middle].lastLine < line { low = middle + 1 } else { high = middle }
    }
    guard low < ranges.count, ranges[low].firstLine <= line else { return nil }
    return ranges[low].blockID
  }

  private static func documentDigest(_ document: DocumentDocument) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return digest(try encoder.encode(document))
  }
  private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
  private static func invalid() -> CollaborationError {
    CollaborationError("invalid_print_source_map", "Печатные страницы и адреса блоков должны принадлежать одному точному исходнику.")
  }
}

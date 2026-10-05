import CryptoKit
import Foundation
import XCTest
@testable import NotebookCore

final class DocumentPrintSourceMapTests: XCTestCase {
  func testCanonicalMapPreservesFrozenBytesForTextAndBinaryNamespace() throws {
    let map = try DocumentPrintSourceMap(document: document, source: source, pdf: pdf, compilerRevision: revision)
    let encoded = try encode(map)
    // Captured before removing constructor self-validation and formatter-based hex.
    XCTAssertEqual(String(decoding: encoded, as: UTF8.self), goldenJSON)
    let decoded = try JSONDecoder().decode(DocumentPrintSourceMap.self, from: encoded)
    XCTAssertEqual(decoded, map)
    try decoded.validate(document: document, source: source, pdf: pdf)
    try decoded.validate(document: document, source: source, pdfSHA256: pdfHash)
    XCTAssertEqual(try DocumentPrintSourceMap(document: document, source: source, pdfSHA256: pdfHash,
      compilerRevision: revision), map)
  }

  func testConstructorRequiresExactTextEntrypointAndValidInputHashes() throws {
    for invalid in ["", String(repeating: "a", count: 63), String(repeating: "a", count: 65),
      String(repeating: "A", count: 64), String(repeating: "g", count: 64)] {
      assertInvalid { try DocumentPrintSourceMap(document: document, source: source,
        pdfSHA256: invalid, compilerRevision: revision) }
      assertInvalid { try DocumentPrintSourceMap(document: document, source: source,
        pdfSHA256: pdfHash, compilerRevision: invalid) }
    }
    assertInvalid { try DocumentPrintSourceMap(document: document, source: source + "changed",
      pdf: pdf, compilerRevision: revision) }
    for entrypoint in ["absent.tex", "media/scan.pdf"] {
      let unavailable = DocumentDocument(id: document.id, actor: actor, entrypoint: entrypoint, files: document.files)
      assertInvalid { try DocumentPrintSourceMap(document: unavailable, source: "", pdf: pdf, compilerRevision: revision) }
    }
    let maximum = String(repeating: "x", count: DocumentFile.maximumSourceLength)
    let full = DocumentDocument(actor: actor, files: [.init(id: "main", path: "main.tex", source: maximum)])
    let fullMap = try DocumentPrintSourceMap(document: full, source: maximum, pdf: pdf, compilerRevision: revision)
    try fullMap.validate(document: full, source: maximum, pdf: pdf)
    assertInvalid { try DocumentPrintSourceMap(document: full, source: maximum + "x", pdf: pdf, compilerRevision: revision) }
  }

  func testDecodedMapChecksEveryStoredBindingAndSourceAddress() throws {
    let map = try DocumentPrintSourceMap(document: document, source: source, pdf: pdf, compilerRevision: revision)
    let original = try XCTUnwrap(JSONSerialization.jsonObject(with: encode(map)) as? [String: Any])
    let otherHash = String(repeating: "d", count: 64)
    let fields: [(String, Any)] = [
      ("format", 1), ("documentID", "00000000-0000-0000-0000-000000000003"),
      ("documentRevision", "1@00000000-0000-0000-0000-000000000001"), ("documentSHA256", otherHash),
      ("sourceSHA256", otherHash), ("inputSHA256", otherHash), ("compilerRevision", otherHash),
      ("pdfSHA256", otherHash), ("entrypoint", "chapters/a.tex"), ("files", [])]
    for (field, value) in fields {
      var corrupt = original; corrupt[field] = value
      try assertRejected(corrupt, field)
    }
    let files = try XCTUnwrap(original["files"] as? [[String: Any]])
    for (field, value) in [("fileID", "other" as Any), ("path", "other.tex"),
      ("sha256", otherHash), ("lineCount", 99)] {
      var corruptFiles = files; corruptFiles[0][field] = value
      var corrupt = original; corrupt["files"] = corruptFiles
      try assertRejected(corrupt, "files.\(field)")
    }
    var reversed = original; reversed["files"] = Array(files.reversed())
    try assertRejected(reversed, "files.order")
    var edited = document
    XCTAssertTrue(edited.replaceFileSource(id: "chapter", source: "Changed chapter", actor: actor))
    assertInvalid { try map.validate(document: edited, source: source, pdf: pdf) }
    assertInvalid { try map.validate(document: document, source: source + "changed", pdf: pdf) }
    assertInvalid { try map.validate(document: document, source: source, pdf: Data("%PDF-other".utf8)) }
  }

  private func assertRejected(_ object: [String: Any], _ field: String,
    file: StaticString = #filePath, line: UInt = #line) throws {
    let bytes = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(DocumentPrintSourceMap.self, from: bytes)
    assertInvalid(field, file: file, line: line) { try decoded.validate(document: document, source: source, pdf: pdf) }
  }
  private func assertInvalid<T>(_ message: String = "", file: StaticString = #filePath, line: UInt = #line,
    _ body: () throws -> T) {
    XCTAssertThrowsError(try body(), message, file: file, line: line) {
      XCTAssertEqual(($0 as? CollaborationError)?.code, "invalid_print_source_map", message, file: file, line: line)
    }
  }
  private func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }
  private let actor = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
  private let revision = String(repeating: "a", count: 64)
  private let source = "Main / café\nПривет 😀\n"
  private let pdf = Data("%PDF-1.4\nfixture".utf8)
  private var pdfHash: String { NotebookHexEncoding.encode(SHA256.hash(data: pdf)) }
  private var document: DocumentDocument {
    let resource = NotebookProgramPackage.File(path: "media/scan.pdf", mimeType: "application/pdf", byteCount: 4_194_311,
      parts: [.init(sha256: String(repeating: "b", count: 64), byteCount: 4_194_304),
        .init(sha256: String(repeating: "c", count: 64), byteCount: 7)])
    return DocumentDocument(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, actor: actor, files: [
      .init(id: "main", path: "main.tex", source: source),
      .init(id: "chapter", path: "chapters/a.tex", source: "Alpha\nBeta"),
      .init(id: "resource", path: "media/scan.pdf", resource: resource),
      .init(id: "empty", path: "chapters/empty.tex", source: "")])
  }
  private let goldenJSON = #"""
{"compilerRevision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","documentID":"00000000-0000-0000-0000-000000000002","documentRevision":"0@00000000-0000-0000-0000-000000000001","documentSHA256":"e626b0638730452423d695a1761b64abb256d72a4d0972561adaa29a08fe726c","entrypoint":"main.tex","files":[{"fileID":"chapter","lineCount":2,"path":"chapters/a.tex","sha256":"c4457665fd3e62b0c9fc21865ea17bb837f9b86b2c2fa353f693eda8c9e97760"},{"fileID":"empty","lineCount":1,"path":"chapters/empty.tex","sha256":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"},{"fileID":"main","lineCount":3,"path":"main.tex","sha256":"0fd62c9e624d86e7a317d4e5cd0e57c8782b3e73369af3cbcea4c51b26bde6bf"}],"format":2,"inputSHA256":"3fdd8463467518f6c97ab8647ce9e69f151f3d429931af7c87087fc57629a0cb","pdfSHA256":"7dfd2b80df499f12a5740d2f0ac27c27549ca76b03158339618d4f7d2b22d233","sourceSHA256":"0fd62c9e624d86e7a317d4e5cd0e57c8782b3e73369af3cbcea4c51b26bde6bf"}
"""#
}

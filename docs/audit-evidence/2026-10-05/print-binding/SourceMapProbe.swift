import CryptoKit
import Foundation
import NotebookCore

@main struct SourceMapProbe {
  static let actor = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
  static let id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
  static let revision = String(repeating: "a", count: 64)
  static let pdf = Data("%PDF-1.4\nfixture".utf8)
  static func milliseconds<T>(_ body: () throws -> T) rethrows -> (T, Double) {
    let start = ContinuousClock.now, value = try body(), elapsed = start.duration(to: .now).components
    return (value, Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
  }
  static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }
  static func main() throws {
    var reports: [[String: Any]] = []
    for count in [1, 64, 512, 4096] {
      let files: [DocumentFile] = (0..<count).map { index in
        .init(id: String(format: "%05d", index), path: index == 0 ? "main.tex" : "chapters/g\(index % 64)/f\(index).tex",
          source: "\(index):" + String(repeating: "x", count: 256) + "\n")
      }
      let document = DocumentDocument(id: id, actor: actor, files: files)
      let source = files[0].source, pdfHash = NotebookHexEncoding.encode(SHA256.hash(data: pdf))
      let initial = try MeasuredSourceMap(document: document, source: source, pdfSHA256: pdfHash, compilerRevision: revision)
      let golden = try encode(initial)
      try initial.validate(document: document, source: source, pdf: pdf)
      var samples: [Double] = [], checksum = 0
      for _ in 0..<15 {
        let (map, ms) = try milliseconds {
          try MeasuredSourceMap(document: document, source: source, pdfSHA256: pdfHash, compilerRevision: revision)
        }
        samples.append(ms); checksum += map.files.count
        let encoded = try encode(map); precondition(encoded == golden)
      }
      precondition(checksum == count * 15)
      reports.append(["files": count, "sourceBytes": files.reduce(0) { $0 + $1.source.utf8.count },
        "constructMS": samples, "goldenSHA256": NotebookHexEncoding.encode(SHA256.hash(data: golden))])
    }
    let resource = NotebookProgramPackage.File(path: "media/scan.pdf", mimeType: "application/pdf", byteCount: 4_194_311,
      parts: [.init(sha256: String(repeating: "b", count: 64), byteCount: 4_194_304),
        .init(sha256: String(repeating: "c", count: 64), byteCount: 7)])
    let document = DocumentDocument(id: id, actor: actor, files: [
      .init(id: "main", path: "main.tex", source: "Main / café\nПривет 😀\n"),
      .init(id: "chapter", path: "chapters/a.tex", source: "Alpha\nBeta"),
      .init(id: "resource", path: "media/scan.pdf", resource: resource),
      .init(id: "empty", path: "chapters/empty.tex", source: "")])
    let map = try MeasuredSourceMap(document: document, source: "Main / café\nПривет 😀\n", pdf: pdf, compilerRevision: revision)
    let golden = try encode(map)
    let report: [String: Any] = ["samples": reports, "goldenJSON": String(decoding: golden, as: UTF8.self),
      "goldenSHA256": NotebookHexEncoding.encode(SHA256.hash(data: golden))]
    print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]), as: UTF8.self))
  }
}

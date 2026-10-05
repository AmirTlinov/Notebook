import Foundation
import NotebookCore

@main struct DependencyProbe {
  static let actor = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
  static let revision = "dependency-probe-v1"
  static func milliseconds<T>(_ body: () throws -> T) rethrows -> (T, Double) {
    let start = ContinuousClock.now, value = try body(), elapsed = start.duration(to: .now).components
    return (value, Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
  }
  static func main() throws {
    var reports: [[String: Any]] = []
    for count in [64, 512, 4096] {
      let files: [DocumentFile] = (0..<count).map { index in
        .init(id: String(format: "%05d", index), path: index == 0 ? "main.tex" : "chapters/g\(index % 64)/f\(index).tex", source: "\(index):" + String(repeating: "x", count: 256))
      }
      let document = DocumentDocument(actor: actor, files: files)
      let hits = min(2000, count)
      var records = Data()
      func record(_ kind: String, _ path: String) { records.append(contentsOf: (kind + "\0" + path + "\0").utf8) }
      for file in files.prefix(hits) { record("p", file.path) }
      for index in 0..<(3000 - hits) { record("p", "missing/f\(index).tex") }
      for index in 0..<1000 { record("d", index < 64 ? "chapters/g\(index)" : "absent/d\(index)") }
      let (indexed, indexMS) = milliseconds { MeasuredDependencies.Source(document) }
      var source = indexed
      let (dependencies, receiptMS) = try milliseconds { try MeasuredDependencies(records: records, source: &source, compilerRevision: revision) }
      precondition(dependencies.lookups.count == 4000)
      let (_, matchesMS) = try milliseconds {
        for _ in 0..<25 { let matches = try dependencies.matches(&source, compilerRevision: revision); precondition(matches) }
      }
      var freshSource = MeasuredDependencies.Source(document)
      let (_, firstMatchMS) = try milliseconds { let match = try dependencies.matches(&freshSource, compilerRevision: revision); precondition(match) }
      let (_, warmOneMatchMS) = try milliseconds { let match = try dependencies.matches(&freshSource, compilerRevision: revision); precondition(match) }
      let (_, freshRequestsMS) = try milliseconds {
        for _ in 0..<25 {
          var requestSource = MeasuredDependencies.Source(document)
          let match = try dependencies.matches(&requestSource, compilerRevision: revision); precondition(match)
        }
      }
      let (identity, namespaceMS) = try milliseconds { try MeasuredDependencies.namespaceIdentity(&source, compilerRevision: revision) }
      reports.append(["files": count, "lookupEntries": 100_000, "indexMS": indexMS, "firstMatchMS": firstMatchMS, "warmOneMatchMS": warmOneMatchMS, "fresh25RequestsMS": freshRequestsMS, "receiptMS": receiptMS, "matchesMS": matchesMS, "namespaceMS": namespaceMS, "identity": identity])
    }
    let resource = NotebookProgramPackage.File(path: "media/scan.pdf", mimeType: "application/pdf", byteCount: 4_194_311, parts: [
      .init(sha256: String(repeating: "a", count: 64), byteCount: 4_194_304), .init(sha256: String(repeating: "b", count: 64), byteCount: 7)])
    let golden = DocumentDocument(actor: actor, files: [
      .init(id: "00", path: "main.tex", source: "Main / café\n"), .init(id: "01", path: "chapters/a.tex", source: "Alpha"),
      .init(id: "02", path: "media/scan.pdf", resource: resource), .init(id: "03", path: "chapters/deep/b.tex", source: "Beta"),
      .init(id: "04", path: "collision", source: "Root file"), .init(id: "05", path: "collision/nested.tex", source: "Nested")])
    let goldenRecords = Data("p\0main.tex\0p\0media/scan.pdf\0p\0chapters\0p\0missing.tex\0d\0chapters\0d\0\0d\0missing\0p\0\0p\0collision\0d\0collision\0".utf8)
    var goldenSource = MeasuredDependencies.Source(golden)
    let dependencies = try MeasuredDependencies(records: goldenRecords, source: &goldenSource, compilerRevision: revision)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let goldenData = try encoder.encode(dependencies)
    let report: [String: Any] = ["samples": reports, "golden": try JSONSerialization.jsonObject(with: goldenData), "goldenIdentity": try dependencies.identity,
      "goldenNamespaceIdentity": try MeasuredDependencies.namespaceIdentity(&goldenSource, compilerRevision: revision)]
    print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]), as: UTF8.self))
  }
}

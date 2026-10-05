import Foundation
import XCTest
@testable import NotebookCore

final class DocumentPrintDependenciesTests: XCTestCase {
  func testReadDirectoryInvalidatesOnNewChildButNotUnreadContentsOrCausalClocks() throws {
    let actor = UUID(), revision = String(repeating: "a", count: 64)
    var document = DocumentDocument(actor: actor, files: [
      .init(id: "main", path: "main.tex", source: "Main"),
      .init(id: "optional", path: "figures/a.svg", source: "old")])
    let reads = Data("p\0main.tex\0d\0figures\0p\0missing.tex\0".utf8)
    var source = DocumentPrintDependencies.Source(document)
    let dependencies = try DocumentPrintDependencies(records: reads, source: &source, compilerRevision: revision)
    document.replaceContent(files: document.files.map { $0.id == "optional" ? $0.replacingSource("new") : $0 }, actor: actor)
    var unreadEdit = DocumentPrintDependencies.Source(document)
    XCTAssertTrue(try dependencies.matches(&unreadEdit, compilerRevision: revision))
    document.replaceContent(files: document.files + [.init(id: "second", path: "figures/b.svg", source: "new child")], actor: actor)
    var addedChild = DocumentPrintDependencies.Source(document)
    XCTAssertFalse(try dependencies.matches(&addedChild, compilerRevision: revision))
    XCTAssertTrue(try dependencies.matches(&source, compilerRevision: revision))
    XCTAssertEqual(source.file(at: "figures/a.svg")?.source, "old")
  }

  func testDependencyReceiptRequiresTheNativeObservedEntrypoint() {
    var source = DocumentPrintDependencies.Source(DocumentDocument(actor: UUID()))
    XCTAssertThrowsError(try DocumentPrintDependencies(records: Data(), source: &source, compilerRevision: "compiler"))
    XCTAssertThrowsError(try DocumentPrintDependencies(records: Data("p\0another.tex\0".utf8), source: &source, compilerRevision: "compiler"))
    XCTAssertThrowsError(try DocumentPrintDependencies(records: Data(String(repeating: "p\0main.tex\0", count: 32_769).utf8),
      source: &source, compilerRevision: "compiler"))
  }

  func testObservedAndNamespaceFingerprintsPreserveTextPartsAndDirectorySemantics() throws {
    let document = DocumentDocument(actor: UUID(), files: fixtureFiles)
    var source = DocumentPrintDependencies.Source(document)
    let dependencies = try DocumentPrintDependencies(records: fixtureReads, source: &source, compilerRevision: revision)
    // Captured from the original encoder and digest contract before indexing.
    XCTAssertEqual(try dependencies.identity, "0e1c0c373d72384a64791d0665eafa90c71899c311104ecf99079a9cb8db78cf")
    let namespace = try DocumentPrintDependencies(namespace: &source, compilerRevision: revision)
    XCTAssertEqual(try namespace.identity, "2b055b356c0a9b75b566333cdb9327cbc2d44d1c5a7416c12bd14d89e27d1dd3")
    XCTAssertTrue(try dependencies.matches(&source, compilerRevision: revision))
    XCTAssertTrue(try namespace.matches(&source, compilerRevision: revision))
    XCTAssertEqual(try source.digest(at: "chapters"), "directory")
    XCTAssertEqual(try source.digest(at: "missing.tex"), "missing")
    XCTAssertEqual(try source.digest(at: "media/scan.pdf"), "parts:8152d446784ebb4c5606aa5b3ba524c7baa9c973109b8b4808a8e52343ab0334")

    // Path probes prefer the file; readdir preserves the existing last-child
    // semantics for a source that contains both a file and its descendants.
    let reordered = fixtureFiles.map { file in
      file.path == "collision" ? DocumentFile(id: "06", path: file.path, source: file.source) : file
    }
    var reorderedSource = DocumentPrintDependencies.Source(DocumentDocument(actor: UUID(), files: reordered))
    XCTAssertEqual(try source.digest(at: "collision"), try reorderedSource.digest(at: "collision"))
    XCTAssertFalse(try dependencies.matches(&reorderedSource, compilerRevision: revision))
    XCTAssertTrue(try namespace.matches(&reorderedSource, compilerRevision: revision))
  }

  func testNegativeProbesAndImmediateChildrenInvalidateOnlyTheirObservedNamespace() throws {
    let actor = UUID()
    let files: [DocumentFile] = [.init(id: "main", path: "main.tex", source: "Main"),
      .init(id: "nested", path: "chapters/deep/a.tex", source: "Nested")]
    var source = DocumentPrintDependencies.Source(DocumentDocument(actor: actor, files: files))
    let reads = Data("p\0main.tex\0p\0optional.tex\0p\0chapters\0d\0chapters\0d\0absent\0".utf8)
    let observed = try DocumentPrintDependencies(records: reads, source: &source, compilerRevision: revision)
    let namespace = try DocumentPrintDependencies(namespace: &source, compilerRevision: revision)
    for (path, matches) in [("chapters/deep/b.tex", true), ("elsewhere/b.tex", true), ("optional.texz/child", true),
      ("chapters/b.tex", false), ("optional.tex", false), ("optional.tex/child", false), ("absent/child", false)] {
      var candidate = DocumentPrintDependencies.Source(DocumentDocument(actor: actor,
        files: files + [.init(id: "new", path: path, source: "New")]))
      XCTAssertEqual(try observed.matches(&candidate, compilerRevision: revision), matches, path)
      XCTAssertFalse(try namespace.matches(&candidate, compilerRevision: revision), path)
    }
  }

  func testFrozenDigestsIgnoreCausalRebindingAndNoticeChangedResourceParts() throws {
    let actor = UUID()
    var document = DocumentDocument(actor: actor, files: fixtureFiles)
    var source = DocumentPrintDependencies.Source(document)
    let dependencies = try DocumentPrintDependencies(records: fixtureReads, source: &source, compilerRevision: revision)
    let namespace = try DocumentPrintDependencies.namespaceIdentity(&source, compilerRevision: revision)
    XCTAssertTrue(document.replaceFileSource(id: "00", source: "Temporary edit", actor: actor))
    var edited = DocumentPrintDependencies.Source(document)
    XCTAssertFalse(try dependencies.matches(&edited, compilerRevision: revision))
    XCTAssertTrue(try dependencies.matches(&source, compilerRevision: revision))
    XCTAssertTrue(document.replaceFileSource(id: "00", source: fixtureFiles[0].source, actor: actor))
    XCTAssertNotEqual(document.contentStamp, source.document.contentStamp)
    var rebound = DocumentPrintDependencies.Source(document)
    XCTAssertTrue(try dependencies.matches(&rebound, compilerRevision: revision))
    XCTAssertEqual(try DocumentPrintDependencies.namespaceIdentity(&rebound, compilerRevision: revision), namespace)
    XCTAssertFalse(try dependencies.matches(&rebound, compilerRevision: "different compiler"))

    let changed = fixtureFiles.map { file -> DocumentFile in
      guard let resource = file.resource else { return file }
      return .init(id: file.id, path: file.path, resource: .init(path: file.path, mimeType: resource.mimeType,
        byteCount: resource.byteCount, parts: [resource.parts[0], .init(sha256: String(repeating: "c", count: 64), byteCount: 7)]))
    }
    var resourceEdit = DocumentPrintDependencies.Source(DocumentDocument(actor: actor, files: changed))
    XCTAssertFalse(try dependencies.matches(&resourceEdit, compilerRevision: revision))
    XCTAssertNotEqual(try DocumentPrintDependencies.namespaceIdentity(&resourceEdit, compilerRevision: revision), namespace)
    XCTAssertTrue(try dependencies.matches(&source, compilerRevision: revision))
  }

  func testDeepDirectoryProbesDoNotTreatDescendantEditsAsNewChildren() throws {
    let components = (0..<31).map { "level\($0)_" + String(repeating: "x", count: 24) }
    let directory = components.joined(separator: "/"), path = directory + "/leaf.tex"
    let actor = UUID(), files: [DocumentFile] = [.init(id: "main", path: "main.tex", source: "Main"),
      .init(id: "leaf", path: path, source: "Leaf")]
    var source = DocumentPrintDependencies.Source(DocumentDocument(actor: actor, files: files))
    var records = Data("p\0main.tex\0".utf8)
    for depth in 1...31 {
      let prefix = components.prefix(depth).joined(separator: "/")
      XCTAssertEqual(try source.digest(at: prefix), "directory")
      records.append(contentsOf: ("d\0" + prefix + "\0").utf8)
    }
    XCTAssertEqual(try source.digest(at: directory + "-other"), "missing")
    let dependencies = try DocumentPrintDependencies(records: records, source: &source, compilerRevision: revision)
    var contentEdit = DocumentPrintDependencies.Source(DocumentDocument(actor: actor,
      files: [files[0], files[1].replacingSource("Edited leaf")]))
    XCTAssertTrue(try dependencies.matches(&contentEdit, compilerRevision: revision))
    var sibling = DocumentPrintDependencies.Source(DocumentDocument(actor: actor,
      files: files + [.init(id: "sibling", path: directory + "/sibling.tex", source: "Sibling")]))
    XCTAssertFalse(try dependencies.matches(&sibling, compilerRevision: revision))
    XCTAssertTrue(try dependencies.matches(&source, compilerRevision: revision))
  }

  func testReorderedLookupsCrossInteriorGapsAndNearPrefixDirectories() throws {
    let files = ["main.tex", "b/one.tex", "b-extra/one.tex", "f/one.tex", "r/one.tex", "r-more/one.tex"]
      .enumerated().map { DocumentFile(id: "f\($0.offset)", path: $0.element, source: "Text") }
    let document = DocumentDocument(actor: UUID(), files: files)
    let order: [(DocumentPrintDependencies.Lookup.Kind, String)] = [
      (.directory, "m"), (.path, "a"), (.path, "b"), (.directory, "r"), (.path, "q"),
      (.directory, "b"), (.directory, "b-"), (.path, "r-more"), (.directory, "r-"),
      (.path, "b-extra"), (.directory, "c"), (.path, "z"), (.directory, "f"), (.path, "m"), (.path, "main.tex")]
    var records = Data()
    for (kind, path) in order { records.append(contentsOf: ((kind == .path ? "p" : "d") + "\0" + path + "\0").utf8) }
    var source = DocumentPrintDependencies.Source(document)
    let observed = try DocumentPrintDependencies(records: records, source: &source, compilerRevision: revision)
    struct Receipt: Encodable {
      let entrypoint: String, compilerRevision: String
      let lookups: [DocumentPrintDependencies.Lookup]
    }
    // Persisted receipts may arrive in arbitrary order. Exercise both ends of
    // each reused interval, including names close to a real directory prefix.
    let encoded = try JSONEncoder().encode(Receipt(entrypoint: document.entrypoint, compilerRevision: revision,
      lookups: order.map { kind, path in observed.lookups.first { $0.kind == kind && $0.path == path }! }))
    let reordered = try JSONDecoder().decode(DocumentPrintDependencies.self, from: encoded)
    var fresh = DocumentPrintDependencies.Source(document)
    XCTAssertTrue(try reordered.matches(&fresh, compilerRevision: revision))
    XCTAssertTrue(try reordered.matches(&fresh, compilerRevision: revision))
    var nearPrefix = DocumentPrintDependencies.Source(DocumentDocument(actor: UUID(),
      files: files + [.init(id: "new", path: "b-extra2/one.tex", source: "Unobserved")]))
    XCTAssertTrue(try reordered.matches(&nearPrefix, compilerRevision: revision))
    var addedDirectory = DocumentPrintDependencies.Source(DocumentDocument(actor: UUID(),
      files: files + [.init(id: "new", path: "m/one.tex", source: "Observed")]))
    XCTAssertFalse(try reordered.matches(&addedDirectory, compilerRevision: revision))
  }

  private let revision = "dependency-probe-v1"
  private var fixtureReads: Data {
    Data("p\0main.tex\0p\0media/scan.pdf\0p\0chapters\0p\0missing.tex\0d\0chapters\0d\0\0d\0missing\0p\0\0p\0collision\0d\0collision\0".utf8)
  }
  private var fixtureFiles: [DocumentFile] {
    let resource = NotebookProgramPackage.File(path: "media/scan.pdf", mimeType: "application/pdf", byteCount: 4_194_311,
      parts: [.init(sha256: String(repeating: "a", count: 64), byteCount: 4_194_304),
        .init(sha256: String(repeating: "b", count: 64), byteCount: 7)])
    return [.init(id: "00", path: "main.tex", source: "Main / café\n"),
      .init(id: "01", path: "chapters/a.tex", source: "Alpha"), .init(id: "02", path: "media/scan.pdf", resource: resource),
      .init(id: "03", path: "chapters/deep/b.tex", source: "Beta"), .init(id: "04", path: "collision", source: "Root file"),
      .init(id: "05", path: "collision/nested.tex", source: "Nested")]
  }
}

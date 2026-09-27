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
    let dependencies = try DocumentPrintDependencies(records: reads, document: document, compilerRevision: revision)
    document.replaceContent(files: document.files.map { $0.id == "optional" ? $0.replacingSource("new") : $0 }, actor: actor)
    XCTAssertTrue(try dependencies.matches(document, compilerRevision: revision))
    document.replaceContent(files: document.files + [.init(id: "second", path: "figures/b.svg", source: "new child")], actor: actor)
    XCTAssertFalse(try dependencies.matches(document, compilerRevision: revision))
  }
  func testDependencyReceiptRequiresTheNativeObservedEntrypoint() {
    let document = DocumentDocument(actor: UUID())
    XCTAssertThrowsError(try DocumentPrintDependencies(records: Data(), document: document, compilerRevision: "compiler"))
    XCTAssertThrowsError(try DocumentPrintDependencies(records: Data("p\0another.tex\0".utf8), document: document, compilerRevision: "compiler"))
  }
}

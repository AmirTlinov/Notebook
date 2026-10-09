import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class DocumentProgramIdentityTests: XCTestCase {
  func testExecutableFileReplacementChangesIdentityButPaperDoesNot() throws {
    let actor = UUID()
    var document = DocumentTestFiles.document(actor: actor, contents: [.tex(id: "body", source: "Before"),
      .program(id: "p", html: "<button>First</button>", height: 100)])
    let original = try DocumentProgramSource(document: document, instanceID: "p", path: "programs/p")
    XCTAssertTrue(document.replaceFileSource(id: "body", source: "After", actor: actor))
    XCTAssertEqual(try DocumentProgramSource(document: document, instanceID: "p", path: "programs/p"), original)
    let main = try XCTUnwrap(document.files.first { $0.path == "main.tex" })
    XCTAssertTrue(document.replaceFileSource(id: main.id, source: main.source.replacingOccurrences(of: "width=\\linewidth", with: "width=.8\\linewidth"), actor: actor))
    XCTAssertEqual(try DocumentProgramSource(document: document, instanceID: "p", path: "programs/p"), original,
      "Viewport geometry is not executable identity")
    XCTAssertTrue(document.replaceFileSource(id: "p-html", source: "<button>Second</button>", actor: actor))
    let replacement = try DocumentProgramSource(document: document, instanceID: "p", path: "programs/p")
    XCTAssertNotEqual(replacement.sourceBasis, original.sourceBasis)
    XCTAssertNotEqual(replacement.programPackage, original.programPackage)
  }

  func testMaximumFileSnapshotDoesNotCreateAnExecutorBeforeCompilation() throws {
    let files = [DocumentFile(id: "main", path: "main.tex", source: "\\documentclass{article}\\begin{document}Text\\end{document}")]
      + (1..<DocumentDocument.maximumFileCount).map { DocumentFile(id: "file-\($0)", path: "sections/file-\($0).tex", source: "Source \($0)") }
    let document = DocumentDocument(actor: UUID(), files: files), resources = SceneRenderResources()
    let source = DocumentRenderSession(documentID: document.id).source(document)
    XCTAssertEqual(source.document.files.count, DocumentDocument.maximumFileCount)
    XCTAssertTrue(source.programs.isEmpty)
    XCTAssertNil(source.layout)
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
  }

  func testCausalRoundTripCannotReviveAnOldProgramIdentity() throws {
    let actor = UUID()
    var document = DocumentTestFiles.document(actor: actor, contents: [
      .program(id: "first", html: "Original"), .program(id: "other", html: "Independent")])
    let original = try DocumentProgramSource(document: document, instanceID: "first", path: "programs/first")
    let other = try DocumentProgramSource(document: document, instanceID: "other", path: "programs/other")
    XCTAssertTrue(document.replaceFileSource(id: "first-html", source: "Changed", actor: actor))
    XCTAssertTrue(document.replaceFileSource(id: "first-html", source: "Original", actor: actor))
    let current = try DocumentProgramSource(document: document, instanceID: "first", path: "programs/first")
    XCTAssertEqual(current.programPackage, original.programPackage)
    XCTAssertNotEqual(current.sourceBasis, original.sourceBasis)
    XCTAssertEqual(try DocumentProgramSource(document: document, instanceID: "other", path: "programs/other"), other)
  }
}

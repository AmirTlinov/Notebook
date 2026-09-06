import Foundation
import NotebookCore
import XCTest
@testable import Notebook

final class NotebookAttentionSelectionTests: XCTestCase {
  @MainActor
  func testPagePreparationUsesOnlyTheCapturedPageAmongTenThousandRegisteredPages() async throws {
    let actor = UUID(), itemID = UUID(), stamp = VersionStamp(counter: 0, actor: UUID())
    let size = PageSize(width: 834, height: 1194)
    var pages = Dictionary(uniqueKeysWithValues: (0..<10_000).map { _ in
      let page = PageDocument(id: UUID(), size: size, actor: actor)
      return (page.id, page)
    })
    let selected = try XCTUnwrap(pages.values.first)
    let workspace = WorkspaceIndex(items: [.notebook(id: itemID, title: "Archive", pageIDs: Array(pages.keys))],
      selectedItemID: itemID, selectedPageID: selected.id, stamp: stamp)
    let hierarchy = BoardHierarchy.initial(rootBoardID: workspace.rootBoardID, itemIDs: [itemID], actor: actor)
    let fragment = NotebookAttentionSelection.Fragment(target: .init(kind: .page, id: selected.id),
      elementID: nil, region: .init(x: 30, y: 40, width: 150, height: 200), worldOrigin: nil, pageIndex: nil, label: "Рисунок")
    let selection = NotebookAttentionSelection(fragments: [fragment], workspace: workspace, hierarchy: hierarchy,
      ink: .init(stamp: stamp), pages: pages, documents: [:], states: [:])
    var changed = selected
    XCTAssertTrue(changed.replaceElements([.init(id: "later", kind: .markdown,
      frame: .init(x: 20, y: 20, width: 200, height: 100), source: "После указания", html: "<p>Позже</p>")], actor: actor))
    pages[changed.id] = changed
    let files = try await Task.detached { try selection.sourceFiles() }.value
    let path = "pages/\(selected.id.uuidString.lowercased()).json"
    XCTAssertEqual(Set(files.keys), [path])
    XCTAssertEqual(try files[path]?.decode(PageDocument.self), selected)
    let references = try await Task.detached { try selection.resolvedReferences() }.value
    let reference = try XCTUnwrap(references.first)
    XCTAssertEqual(reference.id, fragment.id)
    XCTAssertEqual(reference.revision, try NotebookStore.referenceRevision(target: fragment.target,
      files: [path: .encode(selected)]))
    XCTAssertNotEqual(reference.revision, try NotebookStore.referenceRevision(target: fragment.target,
      files: [path: .encode(changed)]))
    XCTAssertEqual(reference.region, fragment.region)
  }

  @MainActor
  func testCoverPreparationUsesPhysicalPaperRatherThanDocumentProgramsOrState() async throws {
    let actor = UUID(), id = UUID(), stamp = VersionStamp(counter: 0, actor: UUID())
    let workspace = WorkspaceIndex(items: [.document(id: id, title: "Letter")],
      selectedItemID: id, selectedPageID: nil, stamp: stamp)
    let hierarchy = BoardHierarchy.initial(rootBoardID: workspace.rootBoardID, itemIDs: [id], actor: actor)
    let document = DocumentDocument(id: id, actor: actor, paperSize: .letter,
      blocks: [.markdown(id: "unrelated-program", source: String(repeating: "Not part of a cover. ", count: 40_000))])
    let fragment = NotebookAttentionSelection.Fragment(target: .init(kind: .cover, id: id, boardID: workspace.rootBoardID),
      elementID: nil, region: .init(x: 0, y: 0, width: 300, height: 400), worldOrigin: nil, pageIndex: nil, label: "Обложка")
    let selection = NotebookAttentionSelection(fragments: [fragment], workspace: workspace, hierarchy: hierarchy,
      ink: .init(stamp: stamp), pages: [:], documents: [id: document], states: [:])
    let files = try await Task.detached { try selection.sourceFiles() }.value
    XCTAssertEqual(files.count, 4)
    XCTAssertEqual(files["documents/\(id.uuidString.lowercased()).json"], .object(["paperSize": .string("letter")]))
    let full = CollaborationContent(workspace: workspace, hierarchy: hierarchy,
      ink: .init(stamp: stamp), pages: [], documents: [document], states: [])
    let references = try await Task.detached { try selection.resolvedReferences() }.value
    XCTAssertEqual(try XCTUnwrap(references.first).revision,
      try NotebookStore.referenceRevision(target: fragment.target, files: full.sourceFiles()))
  }
}

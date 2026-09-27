import Foundation
import Testing
@testable import NotebookCore

@Test("A reading position is addressed local state, not a replacement document")
func documentReadingPositionSurvivesReopeningItsStore() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = NotebookStore(root: root), actor = UUID()
  let document = DocumentDocument(actor: actor, files: [.init(id: "body", path: "main.tex", source: "\\documentclass{article}\\begin{document}Original source\\end{document}")])
  let index = WorkspaceIndex(items: [.document(id: document.id, title: "Reading")],
    selectedItemID: document.id, selectedPageID: nil, stamp: .init(counter: 0, actor: actor))
  try store.saveDocumentWorkspaceBundle(index: index, document: document,
    state: DocumentStateJournal(id: document.id, actor: actor),
    board: BoardHierarchy.initial(rootBoardID: index.rootBoardID, itemIDs: [document.id], actor: actor))
  let storedSource = try store.loadDocument(document.id)
  let position = DocumentReadingPosition(documentID: document.id, sourceStamp: document.contentStamp,
    anchor: .init(fileID: "body", nodeID: "abcd1234abcd1234", textOffset: 10, offset: 3, fileOrder: ["body"]),
    zoomRatio: 2.5, centerOffset: .init(x: 12, y: -30))
  try store.saveDocumentReadingPosition(position)
  #expect(try NotebookStore(root: root).readDocumentReadingPosition(document.id) == position)
  #expect(try store.loadDocument(document.id) == storedSource)
  #expect(try store.readDocumentReadingPosition(UUID()) == nil)
  let invalid = DocumentReadingPosition(documentID: document.id, sourceStamp: document.contentStamp,
    anchor: .init(fileID: "missing", nodeID: "bad", textOffset: -1, offset: 0, fileOrder: ["body"]),
    zoomRatio: 0, centerOffset: .zero)
  #expect(throws: (any Error).self) { try store.saveDocumentReadingPosition(invalid) }
  #expect(try store.readDocumentReadingPosition(document.id) == position)
}

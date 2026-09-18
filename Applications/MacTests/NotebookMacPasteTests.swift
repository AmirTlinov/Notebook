import AppKit
import UniformTypeIdentifiers
import NotebookCore
import XCTest
@testable import Notebook

@MainActor final class NotebookMacPasteTests: XCTestCase {
  func testMenuCapturePreservesRepresentationsWithoutRereadingLiveClipboard() async throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let item = NSPasteboardItem()
    item.setString("Copied text", forType: .string)
    item.setString("<b>Copied text</b>", forType: .html)
    XCTAssertTrue(pasteboard.writeObjects([item]))
    let providers = NotebookMacPasteWindow.providers(from: pasteboard)
    pasteboard.clearContents()
    pasteboard.setString("New clipboard", forType: .string)
    guard case .fragment(let fragment) = try await NotebookClipboard.read(providers, availableSize: .init(x: 600, y: 800)) else { return XCTFail() }
    XCTAssertEqual(fragment.elements[0].source, "Copied text")
    XCTAssertEqual(fragment.elements[0].html, "<p>Copied text</p>")
  }

  func testMacPasteUsesNativeBoardWriterAndOneUndo() async throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.setString("From Mac", forType: .string)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fixture = MacCommandFixture(root: root), model = fixture.model
    retainNotebookUntilTeardown(model, removing: root)
    try await fixture.start()
    let workspace = try XCTUnwrap(model.workspace)
    model.updatePresence(.init(boardID: workspace.rootBoardID, mode: .board, camera: .init(),
      viewport: .init(x: 834, y: 1194), openProgress: 0), settled: true)
    let destination = try XCTUnwrap(model.pasteDestination)
    guard case .fragment(let fragment) = try await NotebookClipboard.read(NotebookMacPasteWindow.providers(from: pasteboard), availableSize: destination.availableSize) else { return XCTFail() }
    let saved = await model.insertClipboardFragment(fragment, at: destination)
    XCTAssertTrue(saved)
    let rows = try model.store.readSceneWindow(boardID: destination.target.id, bounds: .init(origin: .zero.offsetBy(x: -1000, y: -1000), width: 2000, height: 2000))
    XCTAssertTrue(rows.boards.first?.board.elements.contains { $0.id == fragment.elements[0].id } == true)
    model.undoLastSurfaceAction()
    let finished = await model.finishPendingPersistence()
    XCTAssertTrue(finished)
    let undone = try model.store.readSceneWindow(boardID: destination.target.id, bounds: .init(origin: .zero.offsetBy(x: -1000, y: -1000), width: 2000, height: 2000))
    XCTAssertFalse(undone.boards.first?.board.elements.contains { $0.id == fragment.elements[0].id } == true)
  }
}

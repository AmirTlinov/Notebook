import AppKit
import UniformTypeIdentifiers
import NotebookCore
import XCTest
@testable import Notebook

@MainActor final class NotebookClipboardWriterTests: XCTestCase {
  func testClipboardFragmentUsesNativeBoardWriterAndOneUndo() async {
    do { try await assertClipboardFragmentUsesNativeWriter() }
    catch { XCTFail("Runtime clipboard failed: \(error)") }
  }

  private func assertClipboardFragmentUsesNativeWriter() async throws {
    let provider = NSItemProvider()
    provider.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all) { completion in
      completion(Data("From runtime input".utf8), nil); return nil
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fixture = MacCommandFixture(root: root), model = fixture.model
    retainNotebookUntilTeardown(model, removing: root)
    try await fixture.start()
    let workspace = try XCTUnwrap(model.workspace)
    model.updatePresence(.init(boardID: workspace.rootBoardID, mode: .board, camera: .init(),
      viewport: .init(x: 834, y: 1194), openProgress: 0), settled: true)
    let destination = try XCTUnwrap(model.pasteDestination)
    guard case .fragment(let fragment) = try await NotebookClipboard.read([provider], availableSize: destination.availableSize) else { return XCTFail() }
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

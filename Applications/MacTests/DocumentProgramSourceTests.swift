import AppKit
import CryptoKit
import NotebookCore
import SwiftUI
import XCTest
@testable import Notebook

@MainActor
final class DocumentProgramSourceTests: XCTestCase {
  func testProgramFileUsesTheSameEditableNativeSourceAndWriter() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let id = try XCTUnwrap(model.createDocument(at: .zero))
    await model.finishPendingPersistence()
    let before = try model.store.loadDocument(id)
    let request = try await model.insertDocumentFile(documentID: id, path: "programs/scene/main.js")
    let session = DocumentSourceEditorSession(request: request, model: model)
    let code = "const фаза = 0.25;\nnotebook.ready(Promise.resolve());"
    session.input(code, selection: .init(location: code.utf16.count, length: 0), composing: false, scroll: 0)
    await session.save()
    let view = NSHostingView(rootView: DocumentNativeSourceEditor(session: session))
    let window = NSWindow(contentRect: .init(x: -20_000, y: -20_000, width: 600, height: 500),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = view; window.orderBack(nil)
    defer { session.finish(); window.orderOut(nil); window.close() }
    func textView(_ parent: NSView) -> NSTextView? {
      if let text = parent as? NSTextView { return text }
      for child in parent.subviews {
        if let found = textView(child) { return found }
      }
      return nil
    }
    let deadline = ContinuousClock.now + .seconds(5)
    while textView(view)?.string != code, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    let editor = try XCTUnwrap(textView(view))
    XCTAssertEqual(editor.string, code); XCTAssertTrue(editor.isEditable); XCTAssertTrue(editor.isSelectable)
    editor.insertText("\n// Живой исходник 🪐", replacementRange: .init(location: code.utf16.count, length: 0))
    await session.save(); await model.finishPendingPersistence()
    let saved = try model.store.loadDocument(id)
    XCTAssertEqual(saved.files.first { $0.id == session.fileID }?.source, code + "\n// Живой исходник 🪐")
    XCTAssertEqual(saved.files.filter { $0.id != session.fileID }, before.files)
    XCTAssertTrue(try model.store.documentEditingSessions().isEmpty)
  }

  func testFileBytesPreserveUTF8AndBinaryResourcesStayExplicit() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = NotebookStore(root: root)
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    defer { try? FileManager.default.removeItem(at: root) }
    for glyph in ["я", "€", "🪐"] {
      let original = String(repeating: "a", count: 1_048_575) + glyph + "\nconst value = 42;"
      let file = DocumentFile(id: "code", path: "programs/scene/main.js", source: original)
      XCTAssertTrue(file.isText)
      XCTAssertEqual(try store.readDocumentFileBytes(file), Data(original.utf8))
    }
    let bytes = Data([0xff, 0, 1, 127]), hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    try store.stageBlob(data: bytes, expectedHash: hash)
    let binary = DocumentFile(id: "data", path: "programs/scene/data.bin", resource: .init(path: "programs/scene/data.bin",
      mimeType: "application/octet-stream", byteCount: Int64(bytes.count), parts: [.init(sha256: hash, byteCount: bytes.count)]))
    XCTAssertFalse(binary.isText); XCTAssertTrue(binary.source.isEmpty)
    XCTAssertEqual(try store.readDocumentFileBytes(binary), bytes)
  }
}

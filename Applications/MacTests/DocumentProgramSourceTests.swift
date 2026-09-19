import Foundation
import AppKit
import CryptoKit
import NotebookCore
import SwiftUI
import XCTest
@testable import Notebook

final class DocumentProgramSourceTests: XCTestCase {
  @MainActor func testPackageViewerShowsTheStoredCodeWithoutCreatingAnEditableCopy() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    let code = "const фаза = 0.25;\nnotebook.ready(Promise.resolve());"
    let bytes = Data(code.utf8), hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    try store.stageBlob(data: bytes, expectedHash: hash)
    let file = NotebookProgramPackage.File(path: "scene.js", mimeType: "text/javascript", byteCount: Int64(bytes.count),
      parts: [.init(sha256: hash, byteCount: bytes.count)])
    let package = try store.stageProgramPackage(.init(javaScript: file.path, files: [file]))
    let cursor = try store.currentChangeCursor()
    let view = NSHostingView(rootView: DocumentProgramSourceView(
      block: .interactive(id: "scene", html: "", programPackage: package), store: store, findRequest: 0))
    let window = NSWindow(contentRect: .init(x: -20_000, y: -20_000, width: 600, height: 500),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = view; window.orderBack(nil)
    defer { window.orderOut(nil); window.close() }
    func textView(_ parent: NSView) -> NSTextView? {
      if let text = parent as? NSTextView { return text }
      return parent.subviews.lazy.compactMap(textView).first
    }
    let deadline = ContinuousClock.now + .seconds(5)
    while textView(view)?.string != code, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    let text = try XCTUnwrap(textView(view))
    XCTAssertEqual(text.string, code); XCTAssertFalse(text.isEditable); XCTAssertTrue(text.isSelectable)
    XCTAssertEqual(try store.currentChangeCursor(), cursor)
    XCTAssertEqual(try DocumentProgramSourceText.read(file, page: 0, store: store), code)
  }

  func testPagedSourcePreservesEveryUTF8CharacterAcrossTheReadBoundary() throws {
    let size = DocumentProgramSourceText.pageBytes
    for glyph in ["я", "€", "🪐"] {
      for distance in 0..<4 {
        let original = String(repeating: "a", count: size-distance) + glyph + "\nconst value = 42;"
        let bytes = Data(original.utf8)
        var result = ""
        for offset in stride(from: 0, to: bytes.count, by: size) {
          result += try DocumentProgramSourceText.decodePage(bytes.subdata(in: offset..<min(bytes.count, offset+size+3)))
        }
        XCTAssertEqual(result, original)
      }
    }
    XCTAssertThrowsError(try DocumentProgramSourceText.decodePage(Data([0xff])))
    XCTAssertEqual(try DocumentProgramSourceText.decodePage(Data()), "")
  }

  func testBinaryAssetsAreNotLoadedIntoTheTextViewer() {
    for (path, expected) in [("main.js", true), ("src/main.ts", true), ("model.gltf", true), ("source.svg", true), ("data.bin", false), ("model.glb", false), ("font.woff2", false)] {
      let file = NotebookProgramPackage.File(path: path, mimeType: NotebookProgramPackage.mimeType(for: path), byteCount: 0, parts: [])
      XCTAssertEqual(DocumentProgramSourceText.isText(file), expected)
    }
  }
}

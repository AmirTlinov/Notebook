import UIKit
import UniformTypeIdentifiers
import XCTest
import NotebookCore
@testable import Notebook

@MainActor final class NotebookClipboardTests: XCTestCase {
  private let size = SpatialPoint(x: 834, y: 1194)
  private func provider(_ values: [(UTType, Data)]) -> NSItemProvider {
    let provider = NSItemProvider()
    for (type, data) in values {
      provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in completion(data, nil); return nil }
    }
    return provider
  }
  private func read(_ values: [(UTType, Data)]) async throws -> NotebookPasteFragment {
    guard case .fragment(let fragment) = try await NotebookClipboard.read([provider(values)], availableSize: size) else {
      throw CollaborationError("unexpected_structure", "Expected ordinary clipboard content")
    }
    return fragment
  }
  func testPlainTextIsLiteralAndOrdinaryHTMLUsesTextWithoutExecution() async throws {
    let text = "# Не заголовок\n<script>alert(1)</script> **literal**"
    let fragment = try await read([(.html, Data("<script>fetch('https://example.com')</script>".utf8)), (.plainText, Data(text.utf8))])
    let element = try XCTUnwrap(fragment.elements.first)
    XCTAssertEqual(element.kind, .markdown)
    XCTAssertTrue(element.source.hasPrefix("\\#"))
    XCTAssertTrue(element.html.contains("&lt;script&gt;"))
    XCTAssertFalse(element.html.contains("<script>"))
    XCTAssertEqual(element.javaScript, "")
  }
  func testURLAndUnknownJSONUseOrdinaryNativeElements() async throws {
    let link = try await read([(.url, Data("https://example.com/path?q=1&x=2".utf8))])
    XCTAssertTrue(link.elements[0].html.contains("href=\"https://example.com/path?q=1&amp;x=2\""))
    let json = try await read([(.json, Data(#"{"value":42}"#.utf8))])
    XCTAssertEqual(json.elements.count, 1)
    XCTAssertTrue(json.elements[0].html.contains("42"))
  }
  func testImageWinsOverCaptionAndReencodesOnlyPixels() async throws {
    let image = UIGraphicsImageRenderer(size: .init(width: 100, height: 60)).image { context in
      UIColor.red.setFill(); context.fill(.init(x: 0, y: 0, width: 100, height: 60))
    }
    let fragment = try await read([(.png, try XCTUnwrap(image.pngData())), (.plainText, Data("caption".utf8))])
    let element = fragment.elements[0]
    XCTAssertEqual(element.kind, .web)
    XCTAssertTrue(element.html.hasPrefix("<img "))
    XCTAssertTrue(element.html.contains("data:image/"))
    XCTAssertEqual(element.javaScript, "")
    XCTAssertEqual(element.frame.width / element.frame.height, 100 / 60.0, accuracy: 0.001)
  }
  func testMultipleMaterialsStaySeparateAndFitCapturedSurface() async throws {
    let providers = ["first", "second"].map { provider([(.plainText, Data($0.utf8))]) }
    guard case .fragment(let fragment) = try await NotebookClipboard.read(providers, availableSize: .init(x: 150, y: 70)) else { return XCTFail() }
    XCTAssertEqual(fragment.elements.count, 2)
    XCTAssertNotEqual(fragment.elements[0].id, fragment.elements[1].id)
    XCTAssertLessThanOrEqual(fragment.size.x, 150)
    XCTAssertLessThanOrEqual(fragment.size.y, 70)
    XCTAssertGreaterThan(fragment.elements[1].frame.y, fragment.elements[0].frame.y)
  }
  func testMalformedStructuredEnvelopeNeverFallsBackToText() async throws {
    let input = provider([(.html, Data("<div data-tldraw>broken</div>".utf8)), (.plainText, Data("labels".utf8))])
    guard case .composition(let source) = try await NotebookClipboard.read([input], availableSize: size) else { return XCTFail() }
    XCTAssertThrowsError(try NotebookTldrawImport.prepare(source: source, namespace: UUID()))
  }
  func testUnsupportedAndOversizedInputHaveNoPartialResult() async throws {
    for input in [NSItemProvider(), provider([(.url, Data("file:///private/hidden.png".utf8))]), provider([(.plainText, Data(repeating: 65, count: 65_537))]), provider([(.png, Data("not an image".utf8))])] {
      do { _ = try await NotebookClipboard.read([input], availableSize: size); XCTFail("Invalid input must be rejected") }
      catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
    }
  }
  func testOrdinaryPasteUsesOneUndoOnPageAndBoard() async throws {
    let fragment = try await read([(.plainText, Data("Обычная вставка".utf8))])
    for onBoard in [false, true] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-clipboard-\(UUID())")
      let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
      retainNotebookUntilTeardown(model, removing: root)
      await model.start(pageSize: NotebookAppModel.defaultPageSize)
      let workspace = try XCTUnwrap(model.workspace), pageID = try XCTUnwrap(workspace.selectedPageID)
      let center = try XCTUnwrap(model.boardHierarchy?.focusedCenter(of: workspace.selectedItemID, in: workspace.rootBoardID))
      model.updatePresence(.init(boardID: workspace.rootBoardID, mode: onBoard ? .board : .page,
        camera: .init(center: center, scale: 1), viewport: size, focusedItemID: onBoard ? nil : workspace.selectedItemID,
        openProgress: onBoard ? 0 : 1, notebookPageID: onBoard ? nil : pageID), settled: true)
      let destination = try XCTUnwrap(model.pasteDestination)
      let saved = await model.insertClipboardFragment(fragment, at: destination)
      XCTAssertTrue(saved)
      await model.reloadExternalChanges()?.value
      func ids() throws -> Set<String> {
        if onBoard { return Set(try model.store.readSceneWindow(boardID: workspace.rootBoardID, bounds: .init(origin: center.offsetBy(x: -1000, y: -1000), width: 2000, height: 2000)).boards.first!.board.elements.map(\.id)) }
        return Set(try model.store.loadPage(pageID).elements.map(\.id))
      }
      XCTAssertTrue(try ids().contains(fragment.elements[0].id))
      model.undoLastSurfaceAction()
      let finished = await model.finishPendingPersistence()
      XCTAssertTrue(finished)
      XCTAssertFalse(try ids().contains(fragment.elements[0].id))
    }
  }
}

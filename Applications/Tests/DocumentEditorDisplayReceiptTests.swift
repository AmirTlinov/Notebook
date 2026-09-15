import NotebookCore
import UIKit
import WebKit
import XCTest
@testable import Notebook

@MainActor
final class DocumentEditorDisplayReceiptTests: XCTestCase {
  func testUncommittedEditorCannotAcknowledgeTheCanonicalActionAsDisplayed() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let id = try XCTUnwrap(model.createDocument(at: .zero, paperSize: .letter))
    await model.finishPendingPersistence()
    try await model.performStoreCommand(publishesChanges: true) { store in
      var document = try store.loadDocument(id)
      _ = document.replaceContent(blocks: [.markdown(id: "body", source: "# Edit me"),
        .interactive(id: "broken", html: "<button>Broken</button>", javaScript: "throw new Error('broken receipt neighbour')", height: 100)], actor: UUID())
      _ = try store.saveMergedDocument(document)
    }
    await model.reloadExternalChanges()?.value
    let opening = try XCTUnwrap(model.presence), center = try XCTUnwrap(model.board?.focusedCenter(of: id))
    let viewport = SpatialPoint(x: 820, y: 1180)
    model.updatePresence(.init(boardID: opening.boardID, mode: .document,
      camera: .init(center: center, scale: model.itemGeometry(id).fitScale(viewport: viewport)),
      viewport: viewport, focusedItemID: id, openProgress: 1, selectedItemID: id), settled: true)
    await model.prepareDocumentOpening(id, pageIndex: 0)?.value
    await model.finishPendingPersistence()
    let initial = try XCTUnwrap(model.documents[id]), target = CollaborationTarget(kind: .document, id: id)
    // Use the real scene and its admitted item, not an unrelated WebKit floating
    // above an uninstalled scene projection. No duplicate document renderer.
    let window = try await mountNotebookScene(model)
    func find(_ view: UIView) -> WKWebView? {
      if let web = view as? WKWebView, let renderer = web.navigationDelegate as? DocumentWebCoordinator,
        renderer.payload?.documentID == id, renderer.hasCanonicalPixels, renderer.acceptsInput { return web }
      return view.subviews.lazy.compactMap(find).first
    }
    await wait { find(window) != nil }
    let web = try XCTUnwrap(find(window)), coordinator = try XCTUnwrap(web.navigationDelegate as? DocumentWebCoordinator)
    _ = try await web.evaluateJavaScript("""
      document.querySelector('[data-block-id=body]').dispatchEvent(new MouseEvent('dblclick',{bubbles:true}));
      window.editor=document.querySelector('textarea');editor.value='Мой незавершённый текст';
      editor.dispatchEvent(new Event('compositionstart'));editor.dispatchEvent(new Event('input'));true
      """)
    await wait { coordinator.isPresentingEditor && !model.documentEditingSessions.isEmpty }
    let action = CollaborationAction(summary: "Показать канонический результат",
      expected: [.init(target: target, revision: initial.contentStamp.revision)],
      operations: [.init(kind: .updateBlock, target: target, id: "body", values: ["source": .string("# Результат агента")])])
    _ = try await model.performStoreCommand(publishesChanges: true) { try $0.applyCollaborationAction(action, actor: UUID()) }
    await model.reloadExternalChanges()?.value
    await model.finishPendingPersistence()
    let document = try XCTUnwrap(model.documents[id]), state = try XCTUnwrap(model.documentStates[id])
    XCTAssertEqual(document.blocks.first { $0.id == "body" }?.source, "# Результат агента")
    await wait { coordinator.payload?.source.matches(document) == true && coordinator.renderIsReady }
    XCTAssertTrue(coordinator.ownsEditing)
    XCTAssertFalse(coordinator.hasCanonicalPixels)
    XCTAssertFalse(DocumentRenderRegistry.shared.hasLiveSurface(document: document, state: state, pageIndex: 0))
    let draft = try await web.evaluateJavaScript("editor===document.querySelector('textarea')&&editor.value==='Мой незавершённый текст'")
    XCTAssertEqual(draft as? Bool, true)
    await model.refreshCollaborationDetails()
    model.confirmVisibleActions(presence: try XCTUnwrap(model.presence))
    await model.finishPendingPersistence()
    let whileEditing = try await model.performStoreCommand { try $0.deviceActionReceipts(actionIDs: [action.id]) }
    XCTAssertFalse(try XCTUnwrap(whileEditing.first).displayComplete)
    _ = try await web.evaluateJavaScript("editor.dispatchEvent(new Event('compositionend'));editor.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape'}));true")
    await wait { coordinator.hasCanonicalPixels && !model.scenePreparationPending }
    await model.refreshCollaborationDetails()
    XCTAssertTrue(DocumentRenderRegistry.shared.hasLiveSurface(document: document, state: state, pageIndex: 0, scope: .block("body")))
    XCTAssertFalse(DocumentRenderRegistry.shared.hasLiveSurface(document: document, state: state, pageIndex: 0))
    let rendered = try await web.evaluateJavaScript("document.querySelector('#document').textContent.includes('Результат агента')")
    XCTAssertEqual(rendered as? Bool, true)
    model.confirmVisibleActions(presence: try XCTUnwrap(model.presence))
    await model.finishPendingPersistence()
    let afterClose = try await model.performStoreCommand { try $0.deviceActionReceipts(actionIDs: [action.id]) }
    XCTAssertTrue(try XCTUnwrap(afterClose.first).displayComplete,
      "Only the actually installed canonical result after editor dismissal may confirm the action")
    XCTAssertTrue(coordinator.webView === web)
  }

  private func wait(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(8)
    while !condition(), .now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(condition(), "The real document frame did not reach its bounded state", file: file, line: line)
  }
}

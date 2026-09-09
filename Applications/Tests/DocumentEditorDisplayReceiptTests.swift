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
    let initial = try XCTUnwrap(model.documents[id]), target = CollaborationTarget(kind: .document, id: id)
    let action = CollaborationAction(summary: "Показать канонический результат",
      expected: [.init(target: target, revision: initial.contentStamp.revision)],
      operations: [.init(kind: .updateBlock, target: target, id: "body", values: ["source": .string("# Результат агента")])])
    _ = try await model.performStoreCommand(publishesChanges: true) {
      try $0.applyCollaborationAction(action, actor: UUID())
    }
    await model.reloadExternalChanges()?.value
    await model.finishPendingPersistence()
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene), controller = UIViewController(), host = DocumentWebHost()
    window.rootViewController = controller
    window.makeKeyAndVisible()
    let document = try XCTUnwrap(model.documents[id]), state = try XCTUnwrap(model.documentStates[id])
    let geometry = WorkspaceItemGeometry.document(document.paperSize)
    let viewport = SpatialPoint(x: window.bounds.width, y: window.bounds.height)
    let center = try XCTUnwrap(model.board?.focusedCenter(of: id))
    let requested = SessionPresence(boardID: try XCTUnwrap(model.workspace).rootBoardID, mode: .document,
      camera: .init(center: center, scale: geometry.fitScale(viewport: viewport)),
      viewport: viewport, focusedItemID: id, openProgress: 1).selecting(itemID: id, pageID: nil)
    model.updatePresence(requested, settled: true)
    await model.finishPendingPersistence()
    // Settlement owns the document camera. The host and display receipt must
    // use that accepted value, not an independently scaled preview camera.
    let presence = try XCTUnwrap(model.presence)
    let frame = geometry.screenFrame(center: center, camera: presence.camera, viewport: presence.viewport)
    host.frame = .init(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
    controller.view.addSubview(host)
    let resources = SceneRenderResources(maximumWebSurfaces: 1)
    let coordinator = DocumentWebCoordinator(resources: resources, onRenderReady: .init { _ in },
      onPageLayout: { _ in }, onSourceChange: { edit in try await model.commitDocumentSource(edit: edit) }, onStateChange: { _,_ in })
    defer { coordinator.invalidate(); window.isHidden = true }
    coordinator.update(document: document, state: state, selectedPageIndex: 0, capturesSnapshot: false,
      onRenderReady: .init { _ in }, onPageLayout: { _ in },
      onSourceChange: { edit in try await model.commitDocumentSource(edit: edit) }, onStateChange: { _,_ in },
      onDraftChange: model.saveDocumentDraft, onDraftDiscard: model.discardDocumentDraft)
    coordinator.mount(in: host, physicalSize: .init(width: geometry.width, height: geometry.height),
      isInteractive: true, priority: .currentPage)
    await wait { !model.scenePreparationPending && coordinator.hasCanonicalPixels }
    await model.refreshCollaborationDetails()
    try await assertDisplayPrerequisites(model: model, actionID: action.id, document: document, state: state, presence: presence)
    let registry = DocumentRenderRegistry.shared
    XCTAssertTrue(registry.hasLiveSurface(document: document, state: state, pageIndex: 0))
    let web = try XCTUnwrap(coordinator.webView)
    _ = try await js("""
      document.querySelector('[data-block-id=body]').dispatchEvent(new MouseEvent('dblclick',{bubbles:true}));
      window.editor=document.querySelector('textarea');editor.value='Мой незавершённый текст';
      editor.dispatchEvent(new Event('compositionstart'));editor.dispatchEvent(new Event('input'));'editing'
      """, web)
    await wait { !coordinator.hasCanonicalPixels && !model.documentEditingSessions.isEmpty }
    XCTAssertTrue(coordinator.renderIsReady)
    XCTAssertTrue(coordinator.ownsEditing)
    XCTAssertFalse(registry.hasLiveSurface(document: document, state: state, pageIndex: 0))
    await model.finishPendingPersistence()
    await model.refreshCollaborationDetails()
    try await assertDisplayPrerequisites(model: model, actionID: action.id, document: document, state: state, presence: presence)
    model.confirmVisibleActions(presence: presence)
    await model.finishPendingPersistence()
    let whileEditing = try await model.performStoreCommand { try $0.deviceActionReceipts(actionIDs: [action.id]) }
    XCTAssertFalse(try XCTUnwrap(whileEditing.first).displayComplete)
    let draft = try await js("editor.value", web)
    XCTAssertEqual(draft, "Мой незавершённый текст")
    _ = try await js("editor.dispatchEvent(new Event('compositionend'));editor.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape'}));'closed'", web)
    await wait { coordinator.hasCanonicalPixels && !model.scenePreparationPending }
    await model.finishPendingPersistence()
    await model.refreshCollaborationDetails()
    XCTAssertTrue(registry.hasLiveSurface(document: document, state: state, pageIndex: 0))
    try await assertDisplayPrerequisites(model: model, actionID: action.id, document: document, state: state, presence: presence)
    model.confirmVisibleActions(presence: presence)
    await model.finishPendingPersistence()
    let afterClose = try await model.performStoreCommand { try $0.deviceActionReceipts(actionIDs: [action.id]) }
    XCTAssertTrue(try XCTUnwrap(afterClose.first).displayComplete,
      "Only the real canonical frame after editor dismissal may confirm the action")
    XCTAssertTrue(coordinator.webView === web)
    XCTAssertEqual(resources.activeWebSurfaceCount, 1)
  }

  private func assertDisplayPrerequisites(model: NotebookAppModel, actionID: UUID,
    document: DocumentDocument, state: DocumentStateJournal, presence: SessionPresence,
    file: StaticString = #filePath, line: UInt = #line) async throws {
    let receipts = try await model.performStoreCommand { try $0.deviceActionReceipts(actionIDs: [actionID]) }
    XCTAssertEqual(model.presence, presence, "The receipt names the actually settled camera", file: file, line: line)
    XCTAssertEqual(model.presencePhase, .settled, file: file, line: line)
    XCTAssertFalse(model.isPointing, file: file, line: line)
    XCTAssertFalse(model.scenePreparationPending, file: file, line: line)
    XCTAssertTrue(model.collaborationDetailsAreCurrent, file: file, line: line)
    XCTAssertEqual(model.documents[document.id], document, file: file, line: line)
    XCTAssertEqual(model.documentStates[document.id], state, file: file, line: line)
    let action = try XCTUnwrap(model.collaborationActions.first { $0.id == actionID }, file: file, line: line)
    let result = try XCTUnwrap(model.results(for: action).first, file: file, line: line)
    XCTAssertEqual(result.target, CollaborationTarget(kind: .document, id: document.id), file: file, line: line)
    XCTAssertEqual(result.elementID, "body", file: file, line: line)
    let expected = try XCTUnwrap(action.revisions.first { $0.target == result.target }, file: file, line: line)
    XCTAssertEqual(expected.revision, document.contentStamp.revision, file: file, line: line)
    if let stateRevision = expected.stateRevision { XCTAssertEqual(stateRevision, state.stamp.revision, file: file, line: line) }
    let rect = try XCTUnwrap(NotebookAttentionProjection.frame(result, model: model, presence: presence), file: file, line: line)
    XCTAssertTrue(CGRect(x: 0, y: 0, width: presence.viewport.x, height: presence.viewport.y).contains(rect),
      "The real canonical block layout must be inside the displayed document frame: \(rect)", file: file, line: line)
    let receipt = try XCTUnwrap(receipts.first, file: file, line: line)
    XCTAssertEqual(receipt.revisions, action.revisions, file: file, line: line)
    XCTAssertFalse(receipt.displayComplete, file: file, line: line)
  }

  private func js(_ source: String, _ web: WKWebView) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      web.evaluateJavaScript(source) { value, error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume(returning: value as? String ?? String(describing: value)) }
      }
    }
  }
  private func wait(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(8)
    while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(condition(), "The real document frame did not reach its bounded state", file: file, line: line)
  }
}

import NotebookCore
import UIKit
import WebKit
import XCTest
@testable import Notebook

@MainActor
final class DocumentSaveTransitionTests: XCTestCase {
  func testDurableSaveKeepsTextAcrossAHostGapAndCompletesOnlyOnNativeInstallation() async throws {
    try await savedTransition(brokenNeighbour: false)
  }

  func testSavedTextInstallsWhileAnIndependentProgramHasFailed() async throws {
    try await savedTransition(brokenNeighbour: true)
  }

  private func savedTransition(brokenNeighbour: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let id = try XCTUnwrap(model.createDocument(at: .zero, paperSize: .a4))
    await model.finishPendingPersistence()
    if brokenNeighbour {
      try await model.performStoreCommand(publishesChanges: true) { store in
        var document = try store.loadDocument(id)
        _ = document.replaceContent(blocks: [.markdown(id: "body", source: "# Edit this text"),
          .interactive(id: "broken", html: "<button>Broken</button>", javaScript: "throw new Error('broken save neighbour')", height: 100)], actor: UUID())
        _ = try store.saveMergedDocument(document)
      }
      await model.reloadExternalChanges()?.value
    }
    let initial = try XCTUnwrap(model.presence), center = try XCTUnwrap(model.board?.focusedCenter(of: id))
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene), rootController = UIViewController(), host = DocumentWebHost()
    let previous = scene.windows.first { $0.isKeyWindow }
    window.rootViewController = rootController; window.makeKeyAndVisible()
    let viewport = SpatialPoint(x: window.bounds.width, y: window.bounds.height), geometry = model.itemGeometry(id)
    model.updatePresence(.init(boardID: initial.boardID, mode: .document,
      camera: .init(center: center, scale: geometry.fitScale(viewport: viewport)), viewport: viewport,
      focusedItemID: id, openProgress: 1, selectedItemID: id), settled: true)
    await model.prepareDocumentOpening(id, pageIndex: 0)?.value
    host.frame = .init(x: 20, y: 20, width: geometry.width, height: geometry.height)
    rootController.view.addSubview(host)
    let resources = brokenNeighbour ? SceneRenderResources() : SceneRenderResources(maximumWebSurfaces: 1)
    let lifetime = DocumentPagePresentationOwner.shared(documentID: id, resources: resources).retainOpenDocument()
    var physical = DocumentPhysicalPageCoordinator()
    defer { physical.invalidate(); lifetime.close(); window.isHidden = true; previous?.makeKey() }
    func update() throws {
      let document = try XCTUnwrap(model.documents[id]), state = try XCTUnwrap(model.documentStates[id])
      physical.update(.init(document: document, state: state, pageIndex: 0, isCurrent: true, isVisible: true,
        isInteractive: true, pageTurnActive: false, onRenderReady: .init { _ in },
        onPageLayout: { model.acceptDocumentReadingLayout($0, documentID: id) },
         onStateChange: { _, _ in nil },
         onLinkActivation: { _ in }, snapshotPixelWidth: nil,
        onPreparationFailure: { _ in }), in: host, resources: resources)
    }
    func paper() -> WKWebView? {
      func find(_ view: UIView) -> WKWebView? {
        if let web = view as? WKWebView, host.ownsSurface(web) { return web }
        return view.subviews.lazy.compactMap(find).first
      }
      return find(host)
    }
    try update()
    await wait { (paper()?.navigationDelegate as? DocumentWebCoordinator)?.hasCanonicalPixels == true && host.isUserInteractionEnabled }
    let web = try XCTUnwrap(paper())
    let current = try XCTUnwrap(model.documents[id])
    let block = try XCTUnwrap(current.blocks.first { $0.kind != .interactive })
    let editor = DocumentSourceEditorSession(request: .init(documentID: id, block: block,
      version: current.sourceVersion(blockID: block.id), offset: 0), model: model)
    editor.input("# Saved by the sole writer", selection: .init(location: 5, length: 0), composing: false, scroll: 0)
    await editor.save()
    await wait { model.documentSavePresentation?.phase == .saved }
    XCTAssertEqual(model.documentSavePresentation?.source, "# Saved by the sole writer")
    let savedDocument = try await model.performStoreCommand { try $0.loadDocument(id) }
    XCTAssertEqual(savedDocument.blocks.first { $0.id == "body" }?.source, "# Saved by the sole writer")
    // The exact new source exists in SQLite, but has not been sent to this WK.
    XCTAssertFalse(DocumentRenderRegistry.shared.hasLiveSurface(document: savedDocument,
      state: try XCTUnwrap(model.documentStates[id]), pageIndex: 0))
    physical.invalidate()
    XCTAssertEqual(model.documentSavePresentation?.phase, .saved)
    XCTAssertEqual(model.documentSavePresentation?.source, "# Saved by the sole writer")
    physical = DocumentPhysicalPageCoordinator()
    try update()
    await wait { model.documentSavePresentation?.phase == .installed }
    if brokenNeighbour {
      XCTAssertFalse(DocumentRenderRegistry.shared.hasLiveSurface(document: savedDocument,
        state: try XCTUnwrap(model.documentStates[id]), pageIndex: 0))
      XCTAssertTrue(DocumentRenderRegistry.shared.hasLiveSurface(document: savedDocument,
        state: try XCTUnwrap(model.documentStates[id]), pageIndex: 0, scope: .paper))
    }
    XCTAssertTrue(paper() === web, "A host gap is not a document close or a replacement WK runtime")
    let rendered = try await web.evaluateJavaScript("!document.querySelector('textarea') && document.querySelector('#document').textContent.includes('Saved by the sole writer')")
    XCTAssertEqual(rendered as? Bool, true)
    XCTAssertNil(model.documentSavePresentation?.source, "Only a proven native installation releases the retained saved text")
  }

  private func wait(file: StaticString = #filePath, line: UInt = #line, _ ready: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(8)
    while !ready(), .now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(ready(), "The document transition did not complete", file: file, line: line)
  }
}

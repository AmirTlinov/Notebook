import NotebookCore
import PDFKit
import UIKit
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
    let idResult = await model.createDocument(at: .zero)
    let id = try XCTUnwrap(idResult)
    await model.finishPendingPersistence()
    do {
      try await model.performStoreCommand(publishesChanges: true) { store in
        var document = try store.loadDocument(id)
        _ = document.replaceContent(files: DocumentTestFiles.document(contents: [.tex(id: "body", source: "\\section{Edit this text}")] +
          (brokenNeighbour ? [.program(id: "broken", html: "<button>Broken</button>", javaScript: "throw new Error('broken save neighbour')", height: 100)] : [])).files, actor: UUID())
        _ = try store.saveMergedDocument(document)
      }
      await model.reloadExternalChanges()?.value
    }
    let initial = try XCTUnwrap(model.presence), center = try XCTUnwrap(model.board?.focusedCenter(of: id))
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene), rootController = UIViewController(), host = DocumentPageHost()
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
        onPreparationFailure: { _ in }, programStore: model.store), in: host, resources: resources)
    }
    func paper() -> DocumentPaperView? {
      host.subviews.compactMap { $0 as? DocumentPaperView }.first { host.hasCanonicalPaper($0) }
    }
    try update()
    await wait { paper()?.raster != nil && host.isUserInteractionEnabled }
    let installed = try XCTUnwrap(paper())
    let current = try XCTUnwrap(model.documents[id])
    let block = try XCTUnwrap(current.files.first { $0.id == "body" })
    let editor = DocumentSourceEditorSession(request: .init(documentID: id, file: block,
      version: current.fileVersion(fileID: block.id), offset: 0), model: model)
    editor.input("\\section{Saved by the sole writer}\\hypertarget{saved-by-the-sole-writer}{}", selection: .init(location: 5, length: 0), composing: false, scroll: 0)
    await editor.save()
    await wait { model.documentSavePresentation?.phase == .saved }
    XCTAssertEqual(model.documentSavePresentation?.source, "\\section{Saved by the sole writer}\\hypertarget{saved-by-the-sole-writer}{}")
    let savedDocument = try await model.performStoreCommand { try $0.loadDocument(id) }
    XCTAssertEqual(savedDocument.files.first { $0.id == "body" }?.source, "\\section{Saved by the sole writer}\\hypertarget{saved-by-the-sole-writer}{}")
    // The exact new source exists in SQLite, but has not been installed on this paper.
    XCTAssertFalse(DocumentRenderRegistry.shared.hasLiveSurface(document: savedDocument,
      state: try XCTUnwrap(model.documentStates[id]), pageIndex: 0))
    physical.invalidate()
    XCTAssertEqual(model.documentSavePresentation?.phase, .saved)
    XCTAssertEqual(model.documentSavePresentation?.source, "\\section{Saved by the sole writer}\\hypertarget{saved-by-the-sole-writer}{}")
    physical = DocumentPhysicalPageCoordinator()
    try update()
    await wait { model.documentSavePresentation?.phase == .installed }
    if brokenNeighbour {
      XCTAssertFalse(DocumentRenderRegistry.shared.hasLiveSurface(document: savedDocument,
        state: try XCTUnwrap(model.documentStates[id]), pageIndex: 0))
      XCTAssertTrue(DocumentRenderRegistry.shared.hasLiveSurface(document: savedDocument,
        state: try XCTUnwrap(model.documentStates[id]), pageIndex: 0, scope: .paper))
    }
    XCTAssertTrue(paper() === installed, "A host gap retains the same paper owner")
    XCTAssertEqual(paper()?.raster?.page.artifact.document, savedDocument)
    XCTAssertFalse(host.subviews.contains { $0 is UITextView }, "Only canonical PDF pixels enter the paper")
    let print = try await DocumentCanonicalPrint.store.artifact(for: savedDocument)
    XCTAssertTrue(PDFDocument(data: print.pdf)?.string?.contains("Saved by the sole writer") == true)
    XCTAssertNil(model.documentSavePresentation?.source, "Only a proven native installation releases the retained saved text")
  }

  private func wait(file: StaticString = #filePath, line: UInt = #line, _ ready: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(8)
    while !ready(), .now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(ready(), "The document transition did not complete", file: file, line: line)
  }
}

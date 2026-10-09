import NotebookCore
import UIKit
import XCTest
@testable import Notebook

@MainActor
final class DocumentEditorDisplayReceiptTests: XCTestCase {
  func testNativeDraftRemainsSeparateFromTheActuallyInstalledCanonicalAction() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let idResult = await model.createDocument(at: .zero)
    let id = try XCTUnwrap(idResult)
    await model.finishPendingPersistence()
    try await model.performStoreCommand(publishesChanges: true) { store in
      var document = try store.loadDocument(id)
      _ = document.replaceContent(files: DocumentTestFiles.document(contents: [.tex(id: "body", source: "\\section{Edit me}\\hypertarget{edit-me}{}"),
        .program(id: "broken", html: "<button>Broken</button>", javaScript: "throw new Error('broken receipt neighbour')", height: 100)]).files, actor: UUID())
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
    let window = try await mountNotebookScene(model)
    func find(_ view: UIView) -> DocumentPaperView? {
      if let paper = view as? DocumentPaperView, paper.raster?.page.artifact.document.id == id,
        (paper.superview as? DocumentPageHost)?.hasCanonicalPaper(paper) == true { return paper }
      for child in view.subviews { if let found = find(child) { return found } }
      return nil
    }
    await wait { find(window) != nil }
    let paper = try XCTUnwrap(find(window))
    let editor = DocumentSourceEditorSession(request: .init(documentID: id,
      file: try XCTUnwrap(initial.files.first { $0.id == "body" }),
      version: initial.fileVersion(fileID: "body"), offset: 0), model: model)
    editor.input("Мой незавершённый текст", selection: NSRange(location: 3, length: 4), composing: true, scroll: 0)
    await editor.checkpoint()
    await model.finishPendingPersistence()
    let action = CollaborationAction(summary: "Показать канонический результат",
      expected: [.init(target: target, revision: initial.contentStamp.revision)],
      operations: [.init(kind: .putDocumentFile, target: target, id: "body", values: ["path": .string("sections/body.tex"), "source": .string("\\section{Результат агента}"), "expectedVersion": try .encode(initial.fileVersion(fileID: "body"))])])
    _ = try await model.performStoreCommand(publishesChanges: true) { try $0.applyCollaborationAction(action, actor: UUID()) }
    await model.reloadExternalChanges()?.value
    await model.finishPendingPersistence()
    let document = try XCTUnwrap(model.documents[id]), state = try XCTUnwrap(model.documentStates[id])
    XCTAssertEqual(document.files.first { $0.id == "body" }?.source, "\\section{Результат агента}")
    await wait { paper.raster?.page.artifact.document == document && (paper.superview as? DocumentPageHost)?.hasCanonicalPaper(paper) == true }
    XCTAssertEqual(paper.raster?.page.artifact.document, document)
    XCTAssertEqual(editor.text, "Мой незавершённый текст")
    XCTAssertEqual(try model.store.documentEditingSessions().last?.selectionStart, 3)
    await model.refreshCollaborationDetails()
    model.confirmVisibleActions(presence: try XCTUnwrap(model.presence))
    await model.finishPendingPersistence()
    await model.refreshCollaborationDetails()
    XCTAssertTrue(DocumentRenderRegistry.shared.hasLiveSurface(document: document, state: state, pageIndex: 0, scope: .block("body")))
    XCTAssertFalse(DocumentRenderRegistry.shared.hasLiveSurface(document: document, state: state, pageIndex: 0))
    model.confirmVisibleActions(presence: try XCTUnwrap(model.presence))
    await model.finishPendingPersistence()
    let afterClose = try await model.performStoreCommand { try $0.deviceActionReceipts(actionIDs: [action.id]) }
    XCTAssertTrue(try XCTUnwrap(afterClose.first).displayComplete,
      "The native draft is not part of the printed page; only installed canonical pixels confirm the action")
    XCTAssertTrue(find(window) === paper)
    await wait { model.compositionTiles.published?.isPaintInstalled == true }
    let presence = try XCTUnwrap(model.presence), cohort = try XCTUnwrap(model.compositionTiles.published)
    XCTAssertTrue(cohort.plan.presentations[.board(presence.boardID)] != nil)
    XCTAssertTrue(cohort.plan.allowsLive(.item(id), in: .board(presence.boardID)))
    for block in ["body", "broken"] {
      let reference = CollaborationReference(target: target, elementID: block, pageIndex: 0,
        revision: document.contentStamp.revision)
      let rect = try XCTUnwrap(NotebookAttentionProjection.frame(reference, model: model, presence: presence)).insetBy(dx: 2, dy: 2)
      let measured = try XCTUnwrap(DocumentRenderRegistry.shared.regions(document: document).first { $0.id == block && $0.pageIndex == 0 })
      if block == "body" {
        XCTAssertTrue(DocumentRenderRegistry.shared.hasLiveSurface(document: document, state: state, pageIndex: 0, scope: .region(measured.frame)))
      }
      let selected = NotebookAttentionProjection.capture(start: .init(x: rect.minX, y: rect.minY),
        end: .init(x: rect.maxX, y: rect.maxY), model: model, presence: presence, cohort: cohort,
        installedInk: [:], itemID: id)
      if block == "body" { XCTAssertNotNil(selected, "A region of canonical text does not depend on a broken neighbour: \(rect), measured=\(measured.frame), presence=\(presence)") }
      else { XCTAssertNil(selected, "The selected broken program cannot masquerade as captured content") }
    }

  }

  private func wait(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(8)
    while !condition(), .now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(condition(), "The real document frame did not reach its bounded state", file: file, line: line)
  }
}

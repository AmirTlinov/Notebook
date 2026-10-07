import Foundation
import NotebookCore
import XCTest
@testable import Notebook

final class NotebookPanelPageContentTests: XCTestCase {
  override func setUp() async throws { try await InkRasterRenderer.shared.prepareInk() }

  @MainActor
  func testPagePublicationRefreshesPresenceAndMembershipChangedDuringNativePreparation() async throws {
    try await preparationWithConcurrentWrite(changesSource: false)
  }

  @MainActor
  func testPagePublicationRejectsSourceChangedDuringNativePreparation() async throws {
    try await preparationWithConcurrentWrite(changesSource: true)
  }

  @MainActor
  private func preparationWithConcurrentWrite(changesSource: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("panel-page-cut-\(UUID())")
    let fixture = MacCommandFixture(root: root)
    retainNotebookUntilTeardown(fixture.model, removing: root)
    try await fixture.start()
    let workspace = try fixture.store.loadIndex(), itemID = workspace.selectedItemID
    let pageID = try XCTUnwrap(workspace.selectedPageID), target = CollaborationTarget(kind: .page, id: pageID)
    try await fixture.apply([
      .init(kind: .insertElement, target: target, id: "caption", values: ["kind": .string("nativeText"),
        "source": .string("Immutable caption"), "frame": try .encode(PageRect(x: 20, y: 30, width: 200, height: 70))]),
      .init(kind: .appendInkStroke, target: target, id: UUID().uuidString,
        values: ["width": .number(8), "points": .array([
          .object(["x": .number(80), "y": .number(180)]),
          .object(["x": .number(300), "y": .number(210)])])])])
    let cut = try fixture.store.requestPanelPresentation(.init(target: target,
      appearance: .init(viewport: .init(x: 600, y: 800), pixelScale: 1)))
    var appended = workspace
    let append = try XCTUnwrap(appended.appendPage(in: itemID, actor: fixture.model.actorID,
      pageSize: NotebookAppModel.defaultPageSize))
    let nextWorkspace = appended, nextPage = try XCTUnwrap(append.createdPage)
    var changedPage = try fixture.store.loadPage(pageID)
    let didChange = changedPage.replaceElements([.init(id: "caption", kind: .nativeText,
      frame: .init(x: 20, y: 30, width: 200, height: 70), source: "Changed during preparation", html: "")],
      actor: fixture.model.actorID)
    XCTAssertTrue(didChange)
    let replacement = changedPage
    var phases: [String: TimeInterval] = [:], mutation: Task<Void, Error>?
    XCTAssertNil(NotebookNavigationObservation.onPageMaterialPreparation)
    NotebookNavigationObservation.onPageMaterialPreparation = { stage, owner, _, _, _, time in
      guard owner == cut.id else { return }
      phases[stage] = time
      guard stage == "panel_content_captured", mutation == nil else { return }
      // This task joins the real writer while the native painter awaits its
      // ink/raster work. It does not replace a cut or inject a renderer result.
      mutation = Task { @MainActor in
        try await fixture.model.performStoreCommand { store in
          if changesSource { _ = try store.savePage(replacement) }
          else { _ = try store.saveWorkspaceSelection(index: nextWorkspace, createdPage: nextPage) }
        }
      }
    }
    defer { NotebookNavigationObservation.onPageMaterialPreparation = nil }
    let result: Result<JSONValue, Error>
    do {
      let prepared = try await CurrentViewPreviewWriter.panelMaterial(cut, model: fixture.model, knownAssets: [])
      prepared.leafRasterCollector.close()
      result = .success(prepared.snapshot)
    }
    catch { result = .failure(error) }
    try await XCTUnwrap(mutation).value
    XCTAssertNotNil(phases["panel_content_captured"])
    XCTAssertNotNil(phases["panel_material_prepared"])
    if changesSource {
      switch result {
      case .success: XCTFail("A page changed while painting cannot publish the old projection and new basis")
      case .failure(let error):
        guard case NotebookStorageError.transactionConflict = error else { throw error }
      }
      XCTAssertNil(phases["panel_published"])
      XCTAssertNotEqual(try fixture.store.referenceRevision(target: target), cut.sourceRevision)
    } else {
      let snapshot = try result.get()
      XCTAssertEqual(snapshot["elements"]?.arrayValues.first?["source"]?["source"], .string("Immutable caption"))
      XCTAssertEqual(snapshot["navigation"]?["directory"]?["header"]?["selectedPageID"], try .encode(nextPage.id))
      XCTAssertEqual(snapshot["navigation"]?["directory"]?["header"]?["item"]?["pageCount"], .number(2))
      XCTAssertNotEqual(snapshot["cursor"], .string(String(cut.cursor)))
      XCTAssertEqual(snapshot["basis"], try .encode(fixture.store.readBasis(targets: [target], includeSource: true)))
      XCTAssertEqual(snapshot["appearance"]?["sourceRevision"], .string(cut.sourceRevision))
      XCTAssertFalse(snapshot["appearance"]?["layers"]?.arrayValues.isEmpty ?? true)
      let started = try XCTUnwrap(phases["panel_prepare_started"])
      let captured = try XCTUnwrap(phases["panel_content_captured"])
      let painted = try XCTUnwrap(phases["panel_material_prepared"])
      let published = try XCTUnwrap(phases["panel_published"])
      XCTAssertLessThanOrEqual(started, captured)
      XCTAssertLessThanOrEqual(captured, painted)
      XCTAssertLessThanOrEqual(painted, published)
      print("PANEL_PAGE_CUT capture_ms=\((captured - started) * 1000) paint_ms=\((painted - captured) * 1000) publication_ms=\((published - painted) * 1000)")
    }
  }
}

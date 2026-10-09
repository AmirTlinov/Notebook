import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class NotebookDocumentReadingTests: XCTestCase {
  func testFirstOpeningResolvesItsFitFromLateMeasuredPaperBeforeMoving() async throws {
    for paper in [DocumentPaperLayout(widthPoints: 1440, heightPoints: 400),
      DocumentPaperLayout(widthPoints: 240, heightPoints: 420)] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
      retainNotebookUntilTeardown(model, removing: root)
      await model.start(pageSize: NotebookAppModel.defaultPageSize)
      let created = await model.createDocument(at: .zero)
      let id = try XCTUnwrap(created)
      let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
      await model.prepareDocumentOpening(id, pageIndex: 0)?.value
      let initial = try XCTUnwrap(model.presence), document = try XCTUnwrap(model.documents[id])
      let center = try XCTUnwrap(model.board?.focusedCenter(of: id))
      let viewport = SpatialPoint(x: 834, y: 1194)
      let provisional = SpatialCamera(center: center,
        scale: WorkspaceItemGeometry.uncompiledDocument.fitScale(viewport: viewport))
      // The cover has already approached. No PDF measurement exists yet, and
      // native movement must remain pending on its actual paper owner.
      model.updatePresence(.init(boardID: initial.boardID, mode: .cover, camera: provisional,
        viewport: viewport, focusedItemID: id, openProgress: 0), settled: true)
      await model.prepareDocumentOpening(id, pageIndex: 0)?.value
      let target = SessionPresence(boardID: initial.boardID, mode: .document, camera: provisional,
        viewport: viewport, focusedItemID: id, openProgress: 1)
      let owner = WorkspaceCameraOwner(); owner.attach(model)
      defer { owner.detach() }
      owner.settle(to: target, duration: 0.3, bounce: 0, navigationID: nil,
        portal: nil, handoff: nil, rollback: nil, completion: {})
      guard case .settling(let pending) = owner.state else { return XCTFail("Opening must await native paper") }
      XCTAssertFalse(pending.isApproaching)
      XCTAssertEqual(pending.target.camera, provisional)
      XCTAssertNil(model.documentReadingPosition(id))

      let measured = try layout(document, target: 1, papers: [paper, paper])
      model.acceptDocumentReadingLayout(measured, documentID: id)
      owner.preparationChanged()
      try await NotebookPersistenceFenceContract.until {
        abs(pending.target.camera.scale - paper.geometry.fitScale(viewport: viewport)) < 0.0001
      }
      XCTAssertFalse(pending.started, "Measurement alone does not establish native paper readiness")
      XCTAssertEqual(model.documentPaperSizes[id], paper.geometry)
      assertFittedPaper(pending.target, geometry: paper.geometry, center: center)

      // Apply the camera selected for the physical settlement, then rotate its
      // viewport through the production presence owner.
      let resolved = pending.target
      owner.interrupt(settlesPose: false)
      model.updatePresence(resolved, settled: true)
      XCTAssertEqual(try XCTUnwrap(model.documentReadingPosition(id)).zoomRatio, 1, accuracy: 0.0001)
      let rotated = resolved.adapted(to: .init(x: viewport.y, y: viewport.x), geometry: paper.geometry)
      model.updatePresence(rotated, settled: true)
      assertFittedPaper(try XCTUnwrap(model.presence), geometry: paper.geometry, center: center)
      XCTAssertEqual(try XCTUnwrap(model.documentReadingPosition(id)).zoomRatio, 1, accuracy: 0.0001)
    }
  }

  func testPendingReopeningUsesSavedZoomAndANewContactOwnsTheCamera() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let created = await model.createDocument(at: .zero)
    let id = try XCTUnwrap(created)
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    await model.prepareDocumentOpening(id, pageIndex: 0)?.value
    let initial = try XCTUnwrap(model.presence), document = try XCTUnwrap(model.documents[id])
    let center = try XCTUnwrap(model.board?.focusedCenter(of: id)), viewport = initial.viewport
    let paper = DocumentPaperLayout(widthPoints: 900, heightPoints: 600)
    let measured = try layout(document, target: 1, papers: [paper, paper])
    let zoomed = SpatialCamera(center: center.offsetBy(x: 25, y: 0),
      scale: paper.geometry.fitScale(viewport: viewport) * 1.8)
    let visible = SessionPresence(boardID: initial.boardID, mode: .document, camera: zoomed,
      viewport: viewport, focusedItemID: id, openProgress: 1)
    model.beginDocumentCameraInteraction()
    model.updatePresence(visible, settled: true)
    model.acceptDocumentReadingLayout(measured, documentID: id)
    model.updatePresence(visible, settled: true)
    let reading = try XCTUnwrap(model.documentReadingPosition(id))
    XCTAssertEqual(reading.zoomRatio, 1.8, accuracy: 0.0001)
    let fitted = SpatialCamera(center: center, scale: paper.geometry.fitScale(viewport: viewport))
    model.updatePresence(.init(boardID: initial.boardID, mode: .cover, camera: fitted,
      viewport: viewport, focusedItemID: id, openProgress: 0), settled: true)
    await model.prepareDocumentOpening(id, pageIndex: 0)?.value
    let owner = WorkspaceCameraOwner(); owner.attach(model)
    defer { owner.detach() }
    owner.settle(to: visible.replacingCamera(fitted), duration: 0.3, bounce: 0, navigationID: nil,
      portal: nil, handoff: nil, rollback: nil, completion: {})
    model.acceptDocumentReadingLayout(measured, documentID: id)
    owner.preparationChanged()
    guard case .settling(let pending) = owner.state else { return XCTFail("Opening must await native paper") }
    try await NotebookPersistenceFenceContract.until { pending.target.camera == zoomed }
    XCTAssertEqual(pending.target.camera, zoomed)
    owner.interrupt(settlesPose: false)
    model.beginDocumentCameraInteraction()
    let touched = visible.replacingCamera(.init(center: center,
      scale: paper.geometry.fitScale(viewport: viewport) * 2.2))
    model.updatePresence(touched, settled: true)
    model.acceptDocumentReadingLayout(measured, documentID: id)
    owner.preparationChanged()
    await Task.yield()
    XCTAssertTrue(owner.isIdle)
    XCTAssertEqual(model.presence?.camera, touched.camera,
      "A late measurement cannot revive a cancelled opening over a new contact")
  }

  private func assertFittedPaper(_ presence: SessionPresence, geometry: WorkspaceItemGeometry,
    center: WorldPoint, file: StaticString = #filePath, line: UInt = #line) {
    let frame = geometry.screenFrame(center: center, camera: presence.camera, viewport: presence.viewport)
    XCTAssertGreaterThanOrEqual(frame.x, -0.001, file: file, line: line)
    XCTAssertGreaterThanOrEqual(frame.y, -0.001, file: file, line: line)
    XCTAssertLessThanOrEqual(frame.x + frame.width, presence.viewport.x + 0.001, file: file, line: line)
    XCTAssertLessThanOrEqual(frame.y + frame.height, presence.viewport.y + 0.001, file: file, line: line)
    XCTAssertEqual(max(frame.width / presence.viewport.x, frame.height / presence.viewport.y), 1,
      accuracy: 0.0001, "The measured page fills its limiting viewport dimension", file: file, line: line)
  }

  func testReflowAndReopeningRequestTheContentAnchorWithoutInventingALanding() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let idResult = await model.createDocument(at: .zero)
    let id = try XCTUnwrap(idResult)
    let saved1 = await model.finishPendingPersistence(); XCTAssertTrue(saved1)
    let initial = try XCTUnwrap(model.presence), center = try XCTUnwrap(model.board?.focusedCenter(of: id))
    let viewport = initial.viewport, geometry = model.itemGeometry(id)
    let camera = SpatialCamera(center: center.offsetBy(x: 15, y: 40), scale: geometry.fitScale(viewport: viewport) * 2)
    func open(_ camera: SpatialCamera) {
      model.updatePresence(.init(boardID: initial.boardID, mode: .document, camera: camera, viewport: viewport,
        focusedItemID: id, openProgress: 1, documentPageIndex: 0, selectedItemID: id), settled: true)
    }
    open(camera)
    await model.prepareDocumentOpening(id, pageIndex: 0)?.value
    var document = try XCTUnwrap(model.documents[id])
    var source = DocumentPageNavigation.sourceRevision(document)
    model.acceptDocumentReadingLayout(try layout(document, target: 2), documentID: id)
    var controller = UUID()
    model.bindDocumentPageController(controller, documentID: id, source: source)
    XCTAssertTrue(model.acceptDocumentPageLanding(.init(controllerID: controller, documentID: id,
      sourceRevision: source, revision: 1, pageIndex: 2, requestID: nil)))
    let place = try XCTUnwrap(model.documentReadingPosition(id))
    XCTAssertEqual(place.anchor.nodeID, "2222222222222222")
    XCTAssertEqual(place.zoomRatio, 2, accuracy: 0.001)
    XCTAssertEqual(place.centerOffset.y, 40, accuracy: 0.001)
    let saved2 = await model.finishPendingPersistence(); XCTAssertTrue(saved2)
    XCTAssertEqual(try model.store.readDocumentReadingPosition(id), place)

    let block = try XCTUnwrap(document.files.first)
    let edit = DocumentSourceEdit(sessionID: UUID(), documentID: id, fileID: block.id,
      baseSource: block.source, baseVersion: document.fileVersion(fileID: block.id),
      source: block.source.replacingOccurrences(of: "\\begin{document}", with: "\\begin{document} Preceding content changes pagination. "), sequence: 1)
    let status = try await model.commitDocumentSource(edit: edit); XCTAssertEqual(status, .committed)
    document = try XCTUnwrap(model.documents[id]); source = DocumentPageNavigation.sourceRevision(document)
    model.acceptDocumentReadingLayout(try layout(document, target: 5), documentID: id)
    XCTAssertEqual(model.presence?.documentPageIndex, 2, "Resolving the anchor does not confirm its display")
    XCTAssertEqual(model.documentNavigation.request?.pageIndex, 5)
    let obsoleteRestore = try XCTUnwrap(model.documentNavigation.request)
    let changedFile = try XCTUnwrap(document.files.first)
    let changedEdit = DocumentSourceEdit(sessionID: UUID(), documentID: id, fileID: changedFile.id,
      baseSource: changedFile.source, baseVersion: document.fileVersion(fileID: changedFile.id),
      source: changedFile.source.replacingOccurrences(of: "\\begin{document}", with: "\\begin{document} A newer source. "), sequence: 1)
    let changedStatus = try await model.commitDocumentSource(edit: changedEdit); XCTAssertEqual(changedStatus, .committed)
    document = try XCTUnwrap(model.documents[id]); source = DocumentPageNavigation.sourceRevision(document)
    model.acceptDocumentReadingLayout(try layout(document, target: 5), documentID: id)
    XCTAssertNotEqual(try XCTUnwrap(model.documentNavigation.request).id, obsoleteRestore.id,
      "A new source must resolve its own restoration instead of waiting for an impossible old-source landing")
    controller = UUID(); model.bindDocumentPageController(controller, documentID: id, source: source)
    XCTAssertTrue(model.acceptDocumentPageLanding(.init(controllerID: controller, documentID: id,
      sourceRevision: source, revision: 1, pageIndex: 2, requestID: nil)))
    XCTAssertEqual(model.documentReadingPosition(id), place, "The interim old-number page cannot destroy the reading anchor")
    let request = try XCTUnwrap(model.documentNavigation.request)
    XCTAssertTrue(model.acceptDocumentPageLanding(.init(controllerID: controller, documentID: id,
      sourceRevision: source, revision: 2, pageIndex: 5, requestID: request.id)))
    XCTAssertEqual(model.presence?.documentPageIndex, 5)
    XCTAssertEqual(model.documentReadingPosition(id)?.anchor.nodeID, place.anchor.nodeID)

    model.updatePresence(.init(boardID: initial.boardID, mode: .cover, camera: camera,
      viewport: viewport, focusedItemID: id, openProgress: 0, selectedItemID: id), settled: true)
    await model.prepareDocumentOpening(id, pageIndex: 0)?.value
    open(.init(center: center, scale: geometry.fitScale(viewport: viewport)))
    model.acceptDocumentReadingLayout(try layout(document, target: 5), documentID: id)
    XCTAssertEqual(model.documentNavigation.request?.pageIndex, 5)
    XCTAssertEqual(model.presence?.documentPageIndex, 0)
    XCTAssertEqual(try XCTUnwrap(model.presence).camera.scale, geometry.fitScale(viewport: viewport), accuracy: 0.001,
      "A bookmark camera belongs to the actual destination landing, not the interim page")
    controller = UUID(); model.bindDocumentPageController(controller, documentID: id, source: source)
    let reopening = try XCTUnwrap(model.documentNavigation.request)
    XCTAssertTrue(model.acceptDocumentPageLanding(.init(controllerID: controller, documentID: id,
      sourceRevision: source, revision: 1, pageIndex: 5, requestID: reopening.id)))
    XCTAssertEqual(try XCTUnwrap(model.presence).camera.scale, camera.scale, accuracy: 0.001)
    XCTAssertEqual(try XCTUnwrap(model.presence).camera.center, camera.center)
    let saved3 = await model.finishPendingPersistence(); XCTAssertTrue(saved3)
    XCTAssertEqual(try NotebookStore(root: root).readDocumentReadingPosition(id)?.anchor.nodeID, place.anchor.nodeID)
  }

  func testMixedPaperReopeningRestoresOnlyTheLandedGeometryAndNeverOverwritesANewCamera() async throws {
    for movesCamera in [false, true] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
      retainNotebookUntilTeardown(model, removing: root)
      await model.start(pageSize: NotebookAppModel.defaultPageSize)
      let idResult = await model.createDocument(at: .zero)
      let id = try XCTUnwrap(idResult)
      let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
      let start = try XCTUnwrap(model.presence), center = try XCTUnwrap(model.board?.focusedCenter(of: id))
      await model.prepareDocumentOpening(id, pageIndex: 2)?.value
      let document = try XCTUnwrap(model.documents[id])
      let papers: [DocumentPaperLayout] = [.uncompiled, .uncompiled,
        .init(widthPoints: 1190.551181102, heightPoints: 1683.77952756)]
      let measured = try layout(document, target: 2, papers: papers, publishes: true)
      let targetCamera = SpatialCamera(center: center, scale: papers[2].geometry.fitScale(viewport: start.viewport) * 1.6)
      func open(page: Int, camera: SpatialCamera) {
        model.updatePresence(.init(boardID: start.boardID, mode: .document, camera: camera,
          viewport: start.viewport, focusedItemID: id, openProgress: 1, documentPageIndex: page), settled: true)
      }
      open(page: 2, camera: targetCamera)
      model.acceptDocumentReadingLayout(measured, documentID: id)
      open(page: 2, camera: targetCamera)
      let bookmark = try XCTUnwrap(model.documentReadingPosition(id))
      XCTAssertEqual(bookmark.zoomRatio, 1.6, accuracy: 0.0001)
      await model.prepareDocumentOpening(id, pageIndex: 0)?.value
      XCTAssertEqual(model.documentPaperSizes[id], papers[2].geometry,
        "Preparing a different sheet cannot resize the still-open physical page before its landing")
      model.updatePresence(.init(boardID: start.boardID, mode: .cover, camera: targetCamera,
        viewport: start.viewport, focusedItemID: id, openProgress: 0), settled: true)
      XCTAssertEqual(model.documentOpeningPage(id, fallback: 0), 2,
        "The existing source layout selects the saved page before preparing any wrong-page body")
      XCTAssertEqual(model.documentReadingCamera(id, page: 2, center: center, viewport: start.viewport), targetCamera)

      // A source whose layout reaches the model after opening still follows the
      // existing page controller. It must not apply N's ratio to the old page.
      await model.prepareDocumentOpening(id, pageIndex: 0)?.value
      let interim = SpatialCamera(center: center, scale: papers[0].geometry.fitScale(viewport: start.viewport))
      open(page: 0, camera: interim)
      model.acceptDocumentReadingLayout(measured, documentID: id)
      let request = try XCTUnwrap(model.documentNavigation.request)
      XCTAssertEqual(request.pageIndex, 2)
      XCTAssertEqual(model.presence?.camera, interim)
      XCTAssertEqual(model.documentReadingPosition(id), bookmark)
      let controller = UUID(), source = DocumentPageNavigation.sourceRevision(document)
      model.bindDocumentPageController(controller, documentID: id, source: source)
      var expected = targetCamera
      if movesCamera {
        model.inputGate.notifyAcceptedContact()
        expected = .init(center: center, scale: interim.scale * 1.2)
        open(page: 0, camera: expected)
      }
      XCTAssertTrue(model.acceptDocumentPageLanding(.init(controllerID: controller, documentID: id,
        sourceRevision: source, revision: 1, pageIndex: 2, requestID: request.id)))
      XCTAssertEqual(model.presence?.documentPageIndex, 2)
      XCTAssertEqual(try XCTUnwrap(model.presence).camera.scale, expected.scale, accuracy: 0.0001)
      XCTAssertEqual(try XCTUnwrap(model.documentReadingPosition(id)).zoomRatio,
        expected.scale / papers[2].geometry.fitScale(viewport: start.viewport), accuracy: 0.0001)
      XCTAssertFalse(model.acceptDocumentPageLanding(.init(controllerID: controller, documentID: id,
        sourceRevision: source, revision: 1, pageIndex: 0, requestID: request.id)), "A repeated old landing cannot restore the previous page")
      let landedBookmark = model.documentReadingPosition(id)
      _ = model.selectDocumentPage(0, documentID: id)
      let newer = try XCTUnwrap(model.documentNavigation.request)
      XCTAssertTrue(model.acceptDocumentPageLanding(.init(controllerID: controller, documentID: id,
        sourceRevision: source, revision: 2, pageIndex: 2, requestID: request.id)))
      XCTAssertEqual(model.documentNavigation.request?.id, newer.id)
      XCTAssertEqual(model.documentReadingPosition(id), landedBookmark,
        "An interim receipt cannot save over the newer page's pending reading intent")
      withExtendedLifetime(measured) {}
    }
  }

  func testCancelledBookmarkPreparationReleasesReadingWithoutWaitingForALanding() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let idResult = await model.createDocument(at: .zero)
    let id = try XCTUnwrap(idResult)
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    let start = try XCTUnwrap(model.presence), center = try XCTUnwrap(model.board?.focusedCenter(of: id))
    await model.prepareDocumentOpening(id, pageIndex: 2)?.value
    let document = try XCTUnwrap(model.documents[id]), measured = try layout(document, target: 2)
    let camera = SpatialCamera(center: center, scale: WorkspaceItemGeometry.uncompiledDocument.fitScale(viewport: start.viewport))
    func open(page: Int, camera: SpatialCamera) {
      model.updatePresence(.init(boardID: start.boardID, mode: .document, camera: camera,
        viewport: start.viewport, focusedItemID: id, openProgress: 1, documentPageIndex: page), settled: true)
    }
    open(page: 2, camera: camera)
    model.acceptDocumentReadingLayout(measured, documentID: id)
    open(page: 2, camera: camera)
    let bookmark = try XCTUnwrap(model.documentReadingPosition(id))
    XCTAssertEqual(bookmark.anchor.nodeID, "2222222222222222")

    await model.prepareDocumentOpening(id, pageIndex: 0)?.value
    open(page: 0, camera: camera)
    let cancelled = try XCTUnwrap(model.documentNavigation.request)
    XCTAssertEqual(cancelled.pageIndex, 2)
    model.cancelRequestedNavigation()
    XCTAssertNil(model.documentNavigation.request)
    let acceptedCamera = SpatialCamera(center: center.offsetBy(x: 0, y: 25), scale: camera.scale * 1.5)
    open(page: 0, camera: acceptedCamera)
    XCTAssertEqual(model.documentReadingPosition(id)?.anchor.nodeID, "1111111111111111",
      "A cancelled preparation has no future landing to release its reading intent")
    XCTAssertEqual(model.documentReadingPosition(id)?.zoomRatio ?? 0, 1.5, accuracy: 0.0001)

    let controller = UUID(), source = DocumentPageNavigation.sourceRevision(document)
    model.bindDocumentPageController(controller, documentID: id, source: source)
    XCTAssertTrue(model.acceptDocumentPageLanding(.init(controllerID: controller, documentID: id,
      sourceRevision: source, revision: 1, pageIndex: 2, requestID: cancelled.id)))
    XCTAssertEqual(model.presence?.documentPageIndex, 2,
      "Cancellation still accepts the physical result of an already admitted native operation")
    XCTAssertEqual(model.presence?.camera, acceptedCamera)
    XCTAssertEqual(model.documentReadingPosition(id)?.zoomRatio ?? 0, 1.5, accuracy: 0.0001)
  }

  private func layout(_ document: DocumentDocument, target: Int, papers: [DocumentPaperLayout]? = nil, publishes: Bool = false) throws -> DocumentPageLayout {
    let id = try XCTUnwrap(document.files.first?.id)
    let source = DocumentPageNavigation.sourceRevision(document)
    let regions: [DocumentBlockRegion] = [0, target].map { page in
      .init(id: id, pageIndex: page, frame: .init(x: 20, y: 30, width: 100, height: 100), sourceOffset: Double(page) * 100)
    }
    let record = try DocumentLayoutFixture.make(pages: papers ?? Array(repeating: .uncompiled, count: target + 1),
      regions: regions, reading: [
        .init(fileID: id, nodeID: "1111111111111111", textOffset: 0, start: 0, end: 10, pageIndex: 0, y: 30),
        .init(fileID: id, nodeID: "2222222222222222", textOffset: target * 100, start: 0, end: 10, pageIndex: target, y: 30)
      ])
    if publishes {
      let snapshot = DocumentSourceSnapshot(document)
      try snapshot.acceptPreparedLayout(record)
      try DocumentRenderRegistry.shared.publishNative(source: snapshot, token: "reading-fixture", pageIndex: target)
    }
    return .init(pageCount: record.pageCount, sourceRevision: source, record: record)
  }
}

import Foundation
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import NotebookCore
@testable import Notebook

@MainActor
final class NotebookDocumentOpeningTests: XCTestCase {
  func testHistoryReferenceInstallsAnUnloadedDocumentOutsideTheCurrentCamera() async throws {
    try await assertHistoryOpening(onAnotherBoard: false)
  }

  func testHistoryReferenceInstallsAnUnloadedDocumentOnAnotherBoard() async throws {
    try await assertHistoryOpening(onAnotherBoard: true)
  }

  private func assertHistoryOpening(onAnotherBoard: Bool) async throws {
    let (model, _, destination) = try await fixture(secondOnAnotherBoard: onAnotherBoard)
    defer {
      if model.documentMeasurements.enabled, let data = try? JSONEncoder().encode(model.documentMeasurements.records) {
        let measurements = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        measurements.name = "history-opening-phases"; measurements.lifetime = .keepAlways; add(measurements)
      }
    }
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let host = UIHostingController(rootView: SpatialWorkspaceView().environment(model).ignoresSafeArea())
    window.rootViewController = host; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil; model.compositionTiles.cancelPreparation() }
    let initialDeadline = ContinuousClock.now + .seconds(10)
    while model.compositionTiles.published?.isPaintInstalled != true, ContinuousClock.now < initialDeadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(model.compositionTiles.published?.isPaintInstalled == true)
    XCTAssertNil(model.documents[destination.id])
    let target = CollaborationTarget(kind: .document, id: destination.id)
    let revision = try await model.performStoreCommand { try $0.referenceRevision(target: target) }
    let viewport = try XCTUnwrap(model.presence?.viewport)
    let geometry = WorkspaceItemGeometry.document(destination.paperSize)
    let destinationCamera = SpatialCamera(center: .init(x: 2_000, y: 0), scale: geometry.fitScale(viewport: viewport))
    if !onAnotherBoard {
      let origin = try XCTUnwrap(model.presence)
      let visible = geometry.screenFrame(center: destinationCamera.center, camera: origin.camera, viewport: viewport)
      XCTAssertTrue(visible.x < viewport.x && visible.x + visible.width > 0
        && visible.y < viewport.y && visible.y + visible.height > 0,
        "A visible closed cover must approach while preparing; it need not straddle the viewport edge")
      XCTAssertNotEqual(origin.camera, destinationCamera)
    }
    func paperReady() -> Bool {
      guard model.documents[destination.id] == destination, let state = model.documentStates[destination.id] else { return false }
      return DocumentRenderRegistry.shared.hasLiveSurface(document: destination, state: state, pageIndex: 0, scope: .paper)
    }
    let readyAtRequest = paperReady()
    XCTAssertFalse(readyAtRequest)
    var closedAt: TimeInterval?, closedWhilePreparing = false, firstOpeningAt: TimeInterval?
    var openedBeforeReady = false
    let observation = DocumentOpeningCameraObservation { sample in
      guard sample.focusedItemID == destination.id else { return }
      if closedAt == nil, sample.mode == .cover, sample.camera == destinationCamera,
        sample.viewport == viewport, sample.openProgress == 0 {
        closedAt = ProcessInfo.processInfo.systemUptime
        closedWhilePreparing = !paperReady()
      }
      if firstOpeningAt == nil, sample.openProgress > 0 {
        firstOpeningAt = ProcessInfo.processInfo.systemUptime
        openedBeforeReady = !paperReady()
      }
    }
    // The registry holds distinct weak ObjectIdentifiers: this passive fixture
    // observes the ordinary broadcast without replacing a mounted native plane.
    model.nativeCameraProjection.register(observation)
    defer {
      model.nativeCameraProjection.remove(observation)
      let phase = XCTAttachment(string: "closedAt=\(String(describing: closedAt)); closedWhilePreparing=\(closedWhilePreparing); firstOpeningAt=\(String(describing: firstOpeningAt)); openedBeforeReady=\(openedBeforeReady)")
      phase.name = "document-closed-approach"; phase.lifetime = .keepAlways; add(phase)
    }
    let openingStarted = ContinuousClock.now
    model.requestShow(.init(target: target, revision: revision))
    func installed() -> Bool {
      guard let document = model.documents[destination.id], let state = model.documentStates[destination.id] else { return false }
      return model.presence?.mode == .document && model.presence?.focusedItemID == destination.id
        && model.presencePhase == .settled && model.compositionTiles.published?.isPaintInstalled == true
        && DocumentRenderRegistry.shared.hasLiveSurface(document: document, state: state, pageIndex: 0, scope: .paper)
    }
    let deadline = ContinuousClock.now + .seconds(15)
    while !installed(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertTrue(installed(), "A history reference must install the actual document, not only change the title: \(model.persistenceFailure ?? model.compositionTiles.failure ?? "no failure reported"); document=\(model.documents[destination.id] != nil), indexed=\(model.sceneIndex?.item(id: destination.id) != nil), scenePending=\(model.scenePreparationPending), permits=\(model.permitsScenePreparation), preparing=\(model.compositionTiles.isPreparing), presence=\(String(describing: model.presence))")
    XCTAssertEqual(model.documents[destination.id], destination)
    if !readyAtRequest {
      XCTAssertNotNil(closedAt, "The closed destination camera must not wait behind canonical paper preparation")
    }
    XCTAssertNotNil(firstOpeningAt)
    XCTAssertFalse(openedBeforeReady, "A positive opening sample requires the exact installed current paper")
    if let closedAt, let firstOpeningAt { XCTAssertLessThanOrEqual(closedAt, firstOpeningAt) }
    let captureStarted = ProcessInfo.processInfo.systemUptime
    let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    let captureEnded = ProcessInfo.processInfo.systemUptime
    let proof = XCTAttachment(image: image); proof.name = "history-opens-unloaded-document"
    proof.lifetime = .keepAlways; add(proof)
    let attachmentEnded = ProcessInfo.processInfo.systemUptime
    // A generous diagnostic wait must not silently bless a slow opening. The
    // registry checks the installed current source, not just focus/title/model.
    try await assertUX(onAnotherBoard ? "document-other-board-installed" : "document-installed",
      since: openingStarted, budget: NotebookUXObservation.opening, window: window) { installed() }
    let capturePhases = XCTAttachment(string: "captureMS=\((captureEnded-captureStarted)*1000); attachmentMS=\((attachmentEnded-captureEnded)*1000); both remain included in the unchanged opening oracle")
    capturePhases.name = "document-window-observation-cost"; capturePhases.lifetime = .keepAlways; add(capturePhases)
    if model.documentMeasurements.enabled {
      let record = try XCTUnwrap(model.documentMeasurements.records.last { $0.documentID == destination.id })
      XCTAssertEqual(record.sourcePreparationMeasurement, 1)
      // Pending at the closed endpoint is evidence, not a required delay: a
      // faster compiler may legitimately finish during the closed approach.
      if let closedAt, let contentReadyAt = record.contentReadyAt, closedWhilePreparing {
        XCTAssertLessThanOrEqual(closedAt, contentReadyAt)
      }
    }
  }

  func testAcceptedNavigationDoesNotStartAnOptionalShellBeforeItsResolverRuns() async throws {
    let (model, first, _) = try await fixture()
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let previous = window.windowScene?.windows.first(where: \.isKeyWindow)
    window.rootViewController = UIHostingController(rootView: SpatialWorkspaceView().environment(model).ignoresSafeArea())
    window.makeKeyAndVisible()
    defer {
      model.cancelRequestedNavigation()
      window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
      model.compositionTiles.cancelPreparation()
    }
    let deadline = ContinuousClock.now + .seconds(10)
    while model.compositionTiles.published?.isPaintInstalled != true, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    let cohort = try XCTUnwrap(model.compositionTiles.published)
    XCTAssertTrue(cohort.isPaintInstalled)
    let visible = try XCTUnwrap(model.presence)
    let resources = SceneRenderResources.shared
    resources.documentShellPreparation?.retireUnused()
    model.requestShow(.init(target: .init(kind: .document, id: first.id), revision: first.contentStamp.revision))
    XCTAssertNotNil(model.requestedReference)
    XCTAssertEqual(model.presencePhase, .settled, "The resolver has not yet moved the camera")
    model.prepareCommonDocumentShellIfIdle(presence: visible, cohort: cohort)
    XCTAssertNil(resources.documentShellPreparation?.unusedCoordinator,
      "Accepted navigation is not an idle opportunity, even before its first camera sample")
    model.cancelRequestedNavigation()
    model.prepareCommonDocumentShellIfIdle(presence: visible, cohort: cohort)
    XCTAssertNotNil(resources.documentShellPreparation?.unusedCoordinator,
      "The same installed board can prepare its optional shell after cancellation")
  }

  func testOpenedDocumentOwnsPixelsHitTestingAndAttentionAboveAnOverlappingCoverWithoutMovingIt() async throws {
    let (model, first, second) = try await fixture()
    model.moveItem(second.id, to: .zero)
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    await model.reloadExternalChanges()?.value
    let boardID = try XCTUnwrap(model.presence?.boardID)
    let placements = try XCTUnwrap(model.boardHierarchy?.board(boardID)?.placements)
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let host = UIHostingController(rootView: SpatialWorkspaceView().environment(model).ignoresSafeArea())
    window.rootViewController = host
    let viewport = SpatialPoint(x: window.bounds.width, y: window.bounds.height)
    let camera = SpatialCamera(center: .zero, scale: model.itemGeometry(first.id).fitScale(viewport: viewport))
    model.selectItem(first.id)
    await model.prepareDocumentOpening(first.id, pageIndex: 0)?.value
    model.updatePresence(.init(boardID: boardID, mode: .document, camera: camera, viewport: viewport,
      focusedItemID: first.id, openProgress: 1, selectedItemID: first.id), settled: true)
    window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil; model.compositionTiles.cancelPreparation() }
    func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
    func until(_ predicate: () -> Bool) async throws {
      let deadline = ContinuousClock.now + .seconds(15)
      while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
      XCTAssertTrue(predicate(), model.compositionTiles.failure ?? "The opened document was not installed")
      if !predicate() { throw CocoaError(.featureUnsupported) }
    }
    try await until {
      guard let document = model.documents[first.id], let state = model.documentStates[first.id] else { return false }
      return !model.scenePreparationPending && model.compositionTiles.published?.isPaintInstalled == true
        && DocumentRenderRegistry.shared.hasLiveSurface(document: document, state: state, pageIndex: 0, scope: .paper)
    }
    let presence = try XCTUnwrap(model.presence), cohort = try XCTUnwrap(model.compositionTiles.published)
    let workset = model.presentedWorkset(cohort: cohort, boardID: boardID, presence: presence)
    let opened = try XCTUnwrap(workset.items.first { $0.id == first.id })
    let neighbour = try XCTUnwrap(workset.items.first { $0.id == second.id })
    XCTAssertLessThan(opened.zIndex, neighbour.zIndex, "The test must open a paper underneath an actual overlapping cover")
    XCTAssertTrue(WorkspaceSceneProjection.isPaintedBelow(neighbour, opened, in: presence))
    let rank = try XCTUnwrap(WorkspaceSceneProjection.presentationRank(of: opened, in: presence))
    XCTAssertGreaterThan(rank, Double(cohort.plan.bands.filter { $0.plane == .board(boardID) }.map(\.rank).max() ?? 0))
    let point = CGPoint(x: window.bounds.midX, y: window.bounds.midY)
    let hit = try XCTUnwrap(window.hitTest(point, with: nil))
    let web = try XCTUnwrap(views(host.view).compactMap { $0 as? WKWebView }.first {
      $0.navigationDelegate is DocumentWebCoordinator && hit.isDescendant(of: $0)
    }, "The native contact must reach the opened document, not its overlapping neighbour")
    XCTAssertGreaterThan(web.convert(web.bounds, to: window).intersection(window.bounds).width, 100)
    let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    let pixels = XCTAttachment(image: image); pixels.name = "opened-document-above-unchanged-overlapping-cover"
    pixels.lifetime = .keepAlways; add(pixels)
    var selected: CollaborationTarget?
    _ = NotebookAttentionProjection.capture(start: point, end: point, model: model, presence: presence,
      cohort: cohort, installedInk: [:], acceptsFirstFragment: { fragment in selected = fragment.target; return false })
    XCTAssertEqual(selected, .init(kind: .document, id: first.id), "Attention resolves the same paper as native hit testing")
    let paper = opened.geometry.screenFrame(center: opened.center, camera: presence.camera, viewport: presence.viewport)
    var area: NotebookAttentionSelection.Fragment?
    _ = NotebookAttentionProjection.capture(start: .init(x: paper.x - 20, y: paper.y - 20),
      end: .init(x: paper.x + 120, y: paper.y + 160), model: model, presence: presence,
      cohort: cohort, installedInk: [:], acceptsFirstFragment: { area = $0; return false })
    XCTAssertEqual(area?.target, .init(kind: .document, id: first.id),
      "A region crossing open paper must not pick an overlapping cover or the board behind it")
    XCTAssertEqual(area?.pageIndex, presence.documentPageIndex)
    XCTAssertNil(area?.elementID)
    XCTAssertEqual(area?.region, .init(x: 0, y: 0, width: 120 / presence.camera.scale, height: 160 / presence.camera.scale))
    let pose = try XCTUnwrap(model.compositionTiles.surfaceRegistry.pose(for: .cover(first.id)))
    let surface = try XCTUnwrap(pose.screenSurface(in: host.view))
    XCTAssertEqual(surface.presentationRank, rank, "Accepted native surface samples retain this same presentation tier")
    XCTAssertEqual(model.boardHierarchy?.board(boardID)?.placements, placements)
    let closed = SessionPresence(boardID: boardID, mode: .cover, camera: camera, viewport: viewport,
      focusedItemID: first.id, openProgress: 0, selectedItemID: first.id)
    model.updatePresence(closed, settled: true)
    XCTAssertNil(WorkspaceSceneProjection.presentationRank(of: opened, in: closed))
    XCTAssertTrue(WorkspaceSceneProjection.isPaintedBelow(opened, neighbour, in: closed))
    let persisted = await model.finishPendingPersistence(); XCTAssertTrue(persisted)
    XCTAssertEqual(try model.store.loadBoard(items: try XCTUnwrap(model.workspace).items).board(boardID)?.placements, placements,
      "Opening/closing must not author a move, alter a stack, or change causal placement heads")
  }

  func testAcceptedOpeningReadsAnAlreadySelectedCoverBeforeAnyCameraSample() async throws {
    let (model, first, second) = try await fixture()
    let closed = try XCTUnwrap(model.presence)
    XCTAssertEqual(closed.selectedItemID, first.id)
    XCTAssertEqual(closed.openProgress, 0)
    XCTAssertTrue(model.documents.isEmpty)
    // This is the former open path before its camera animation. Selection by
    // itself correctly stays light, but it cannot own an accepted opening.
    model.documentMeasurements.request(documentID: first.id, pageIndex: 0, cause: .open)
    model.selectItem(first.id)
    _ = await model.finishPendingPersistence()
    XCTAssertNil(model.documents[first.id])
    let opening = try XCTUnwrap(model.prepareDocumentOpening(first.id, pageIndex: 0))
    await opening.value
    XCTAssertEqual(model.documents[first.id], first)
    XCTAssertEqual(model.documentStates[first.id]?.id, first.id)
    XCTAssertNil(model.documents[second.id])
    XCTAssertNil(model.documentStates[second.id])
    XCTAssertEqual(model.presence, closed, "Reading the accepted body cannot jump the actual camera")
  }

  func testAnUnrelatedCorruptClosedBodyDoesNotBlockAcceptedOpening() async throws {
    let (model, first, second) = try await fixture()
    try await model.performStoreCommand { store in
      let database = try NotebookSQLConnection(url: store.databaseURL, writable: true)
      let address = "documents/" + second.id.uuidString.lowercased() + ".json#/blocks/@text"
      try database.run("UPDATE blobs SET data=? WHERE hash=(SELECT hash FROM records WHERE address=?)",
        [.blob(Data("not a document block".utf8)), .text(address)])
      XCTAssertThrowsError(try store.loadDocument(second.id))
    }
    let opening = try XCTUnwrap(model.prepareDocumentOpening(first.id, pageIndex: 0))
    await opening.value
    XCTAssertEqual(model.documents[first.id], first)
    XCTAssertNil(model.documents[second.id])
    XCTAssertNil(model.persistenceFailure)
  }

  func testResolvedOpeningOutsideTheCameraCacheUsesItsDestinationBoardBeforeAnyCameraSample() async throws {
    let (model, first, second) = try await fixture()
    let oldBoard = try XCTUnwrap(model.presence?.boardID)
    let (boardID, document) = try await model.performStoreCommand { store in
      let actor = UUID(), header = try store.workspaceHeader()
      var index = try store.loadIndex(), hierarchy = try store.loadBoard(items: index.items)
      let board = try XCTUnwrap(index.createBoard(title: "Distant board", actor: actor))
      XCTAssertTrue(hierarchy.createBoard(board.id, in: header.rootBoardID,
        near: .init(x: 900_000, y: -700_000), actor: actor))
      let item = try XCTUnwrap(index.createDocument(title: "Distant document", actor: actor))
      XCTAssertTrue(hierarchy.addItem(item.id, to: board.id, near: .init(x: 90_000, y: -70_000), actor: actor))
      let document = DocumentDocument(id: item.id, actor: actor, paperSize: .a4,
        blocks: [.markdown(id: "text", source: "Addressed document body")])
      try store.saveDocumentWorkspaceBundle(index: index, document: document,
        state: .init(id: item.id, actor: actor), board: hierarchy)
      return (board.id, try store.loadDocument(document.id))
    }
    XCTAssertNil(model.itemForDisplay(id: document.id), "This is an addressed result outside the bounded scene")
    model.selectItem(document.id)
    let selected = try XCTUnwrap(model.presence)
    XCTAssertEqual(selected.boardID, oldBoard)
    let opening = try XCTUnwrap(model.prepareDocumentOpening(document.id, pageIndex: 0, boardID: boardID))
    await opening.value
    XCTAssertEqual(model.documents[document.id], document)
    XCTAssertNil(model.documents[first.id]); XCTAssertNil(model.documents[second.id])
    XCTAssertEqual(model.presence, selected, "Source preparation does not publish an unpresented destination camera")
  }

  func testCancelledOpeningCannotPublishItsDelayedBody() async throws {
    let (model, first, _) = try await fixture()
    let blocker = NotebookPersistenceFenceContract.Blocker()
    defer { blocker.release() }
    let predecessor = Task { try await model.performStoreCommand { _ in try blocker.hold() } }
    try await NotebookPersistenceFenceContract.until { blocker.entered.value == true }
    let opening = try XCTUnwrap(model.prepareDocumentOpening(first.id, pageIndex: 0))
    model.inputGate.notifyAcceptedContact()
    blocker.release()
    try await predecessor.value
    await opening.value
    XCTAssertNil(model.documents[first.id])
    XCTAssertNil(model.documentStates[first.id])
    XCTAssertNil(model.persistenceFailure)
    let replacement = try XCTUnwrap(model.prepareDocumentOpening(first.id, pageIndex: 0))
    await replacement.value
    XCTAssertEqual(model.documents[first.id], first, "Cancelling one request does not poison later admission")
  }

  func testCancellationBeforeTheFirstTaskTurnRetainsTheSinglePendingReadOwner() async throws {
    let (model, first, _) = try await fixture()
    let blocker = NotebookPersistenceFenceContract.Blocker()
    defer { blocker.release() }
    let predecessor = Task { try await model.performStoreCommand { _ in try blocker.hold() } }
    try await NotebookPersistenceFenceContract.until { blocker.entered.value == true }
    let opening = try XCTUnwrap(model.prepareDocumentOpening(first.id, pageIndex: 0))
    model.inputGate.notifyAcceptedContact()
    let premature = expectation(description: "The submitted FIFO read still owns the opening task")
    premature.isInverted = true
    let isHoldingWriter = NotebookPersistenceFenceContract.Signal<Bool>()
    isHoldingWriter.set(true)
    let observer = Task { await opening.value; if isHoldingWriter.value == true { premature.fulfill() } }
    // Repeated accepted/revoked openings replace intent, while the one source
    // read stays behind the controlled writer until its actual completion.
    for _ in 0..<5 {
      _ = model.prepareDocumentOpening(first.id, pageIndex: 0)
      model.inputGate.notifyAcceptedContact()
      await Task.yield()
    }
    await fulfillment(of: [premature], timeout: 0.1)
    XCTAssertNil(model.documents[first.id])
    isHoldingWriter.set(false)
    blocker.release()
    try await predecessor.value
    await observer.value
    XCTAssertNil(model.documents[first.id])
    let replacement = try XCTUnwrap(model.prepareDocumentOpening(first.id, pageIndex: 0))
    await replacement.value
    XCTAssertEqual(model.documents[first.id], first)
  }

  func testOnlyTheLatestOpeningSurvivesADelayedPredecessor() async throws {
    let (model, first, second) = try await fixture()
    let blocker = NotebookPersistenceFenceContract.Blocker()
    defer { blocker.release() }
    let predecessor = Task { try await model.performStoreCommand { _ in try blocker.hold() } }
    try await NotebookPersistenceFenceContract.until { blocker.entered.value == true }
    let opening = try XCTUnwrap(model.prepareDocumentOpening(first.id, pageIndex: 0))
    model.selectItem(second.id)
    let replacement = try XCTUnwrap(model.prepareDocumentOpening(second.id, pageIndex: 0))
    blocker.release()
    try await predecessor.value
    await opening.value; await replacement.value
    XCTAssertNil(model.documents[first.id], "A late source cannot enter the new document's live set")
    XCTAssertEqual(model.documents[second.id], second)
    XCTAssertEqual(model.presence?.selectedItemID, second.id)
    XCTAssertEqual(model.presence?.openProgress, 0)
  }

  func testPreparedDocumentRefreshRetainsActualCoverAndRejectsRetiredDemand() async throws {
    let (model, _, destination) = try await fixture()
    model.selectItem(destination.id)
    let actual = try XCTUnwrap(model.presence)
    let target = SessionPresence(boardID: actual.boardID, mode: .document,
      camera: .init(center: .init(x: 2_000, y: 0), scale: 0.8), viewport: actual.viewport,
      focusedItemID: destination.id, openProgress: 1, selectedItemID: destination.id)
    model.updatePresence(actual, settled: false)
    model.prepareComposition(presence: target, frame: nil, pinned: [], displayScale: 1)
    let state = try NotebookSceneState.read(store: model.store, presence: target, viewport: target.viewport)
    XCTAssertTrue(model.acceptExternalScene(state, observedEpoch: model.collaborationReadEpoch,
      observedPresence: actual, observedPreparation: target, itemPins: [:]))
    XCTAssertEqual(model.presence, actual, "Preparing another paper cannot teleport the actual cover")
    XCTAssertEqual(model.documents[destination.id], destination, "The accepted opening demand owns its fresh body even while the cover is closed")
    model.updatePresence(actual, settled: true)
    XCTAssertFalse(model.acceptExternalScene(state, observedEpoch: model.collaborationReadEpoch,
      observedPresence: actual, observedPreparation: target, itemPins: [:]),
      "A cancelled passage cannot restore its stale preparation demand")
  }

  private func fixture(secondOnAnotherBoard: Bool = false) async throws -> (NotebookAppModel, DocumentDocument, DocumentDocument) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("document-opening-" + UUID().uuidString)
    let store = NotebookStore(root: root), actor = UUID()
    let pageSize = NotebookAppModel.defaultPageSize
    let documents = try await Task.detached {
      _ = try store.initializeWorkspace(actor: actor, pageSize: pageSize)
      var index = try store.loadIndex(), hierarchy = try store.loadBoard(items: index.items)
      let first = try XCTUnwrap(index.createDocument(title: "First", actor: actor))
      XCTAssertTrue(hierarchy.addItem(first.id, to: index.rootBoardID, near: .zero, actor: actor))
      let a = DocumentDocument(id: first.id, actor: actor, paperSize: .a4, blocks: [.markdown(id: "text", source: "First real body")])
      try store.saveDocumentWorkspaceBundle(index: index, document: a, state: .init(id: a.id, actor: actor), board: hierarchy)
      var secondBoard = index.rootBoardID
      if secondOnAnotherBoard {
        let board = try XCTUnwrap(index.createBoard(title: "Other board", actor: actor))
        XCTAssertTrue(hierarchy.createBoard(board.id, in: index.rootBoardID,
          near: .init(x: 90_000, y: 0), actor: actor))
        secondBoard = board.id
      }
      let second = try XCTUnwrap(index.createDocument(title: "Second", actor: actor))
      XCTAssertTrue(hierarchy.addItem(second.id, to: secondBoard, near: .init(x: 2_000, y: 0), actor: actor))
      let b = DocumentDocument(id: second.id, actor: actor, paperSize: .a4, blocks: [.markdown(id: "text", source: "Second closed body")])
      _ = index.selectItem(first.id, actor: actor)
      try store.saveDocumentWorkspaceBundle(index: index, document: b, state: .init(id: b.id, actor: actor), board: hierarchy)
      try store.savePresence(.init(boardID: index.rootBoardID, mode: .cover, camera: .init(),
        viewport: .init(x: 834, y: 1194), focusedItemID: first.id, openProgress: 0, selectedItemID: first.id))
      return (try store.loadDocument(a.id), try store.loadDocument(b.id))
    }.value
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let ready = await model.finishPendingPersistence()
    XCTAssertTrue(ready, model.persistenceFailure ?? "")
    XCTAssertTrue(model.documents.isEmpty)
    return (model, documents.0, documents.1)
  }
}

/// A test-only listener to the existing native camera owner, not a new clock or
/// a replacement plane. It never projects, requests, or acknowledges content.
@MainActor
private final class DocumentOpeningCameraObservation: SceneNativeCameraOwner {
  private let receive: (SessionPresence) -> Void
  init(_ receive: @escaping (SessionPresence) -> Void) { self.receive = receive }
  func projectSceneCamera(_ presence: SessionPresence) { receive(presence) }
}

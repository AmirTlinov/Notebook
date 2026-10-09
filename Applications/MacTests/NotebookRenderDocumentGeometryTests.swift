import Foundation
@testable import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class NotebookRenderDocumentGeometryTests: XCTestCase {
  func testHundredThousandBoardElementsKeepSequentialPrintedSourcesAndCreditBounded() async throws {
    let fixture = try makeFixture(papers: [(720, 400), (360, 640)], distantElements: 100_000)
    defer { try? FileManager.default.removeItem(at: fixture.store.root) }
    let resources = SceneRenderResources()
    let capture = try await NotebookRenderDocumentGeometry.capture(store: fixture.store,
      presence: fixture.presence, resources: resources)
    let metadataBytes = resources.reservedBytes
    XCTAssertGreaterThan(metadataBytes, 0)
    XCTAssertLessThan(metadataBytes, NotebookRenderDocumentGeometry.sourceReadBytes)
    weak var previousSource: DocumentSourceSnapshot?
    var readIDs: [UUID] = [], loadedIDs: [UUID] = []
    let previous = NotebookRenderDocumentGeometry.acceptanceConfiguration
    NotebookRenderDocumentGeometry.acceptanceConfiguration = .init(storeRoot: fixture.store.root,
      beforeBodyRead: { id in
        XCTAssertNil(previousSource, "The previous printed source must leave before another document body is admitted")
        XCTAssertEqual(resources.reservedBytes, metadataBytes + NotebookRenderDocumentGeometry.sourceReadBytes,
          "Only scalar discovery and this body's admission remain; previous source and PDF credit have returned")
        readIDs.append(id)
      }, sourceLoaded: { source in
        previousSource = source
        loadedIDs.append(source.document.id)
      })
    defer { NotebookRenderDocumentGeometry.acceptanceConfiguration = previous }

    let prepared = try await NotebookRenderDocumentGeometry.prepare(store: fixture.store,
      capture: capture, resources: resources)
    XCTAssertEqual(readIDs.count, 2)
    XCTAssertEqual(Set(readIDs), Set(fixture.ids))
    XCTAssertEqual(loadedIDs, readIDs)
    XCTAssertNil(previousSource)
    XCTAssertEqual(resources.reservedBytes, metadataBytes)
    XCTAssertEqual(resources.pendingDerivedRequestCount, 0)
    XCTAssertEqual(resources.activeWebSurfaceCount, 0, "Paper geometry uses the actual canonical print without mounting a web executor")
    for (id, paper) in zip(fixture.ids, fixture.papers) {
      let actual = try XCTUnwrap(prepared.values[id])
      let expected = WorkspaceItemGeometry.document(widthPoints: paper.0, heightPoints: paper.1)
      XCTAssertEqual(actual.width, expected.width, accuracy: 0.1)
      XCTAssertEqual(actual.height, expected.height, accuracy: 0.1)
      XCTAssertEqual(actual.cornerRadius, expected.cornerRadius)
    }
    XCTAssertTrue(try prepared.isCurrent(fixture.store))
    let originalSceneIdentity = try PreviewSourceIdentity.read(fixture.store, presence: fixture.presence)
    try changeSource(fixture.ids[0], in: fixture)
    XCTAssertEqual(try PreviewSourceIdentity.read(fixture.store, presence: fixture.presence), originalSceneIdentity,
      "A document edit does not change the board's own reference identity")
    XCTAssertFalse(try prepared.isCurrent(fixture.store), "The final publication cut must still reject changed document text")
  }

  func testBodyReadWaitsForCapacityAndCancelledAdmissionReturnsItsQueuePosition() async throws {
    let fixture = try makeFixture(papers: [(720, 400)])
    defer { try? FileManager.default.removeItem(at: fixture.store.root) }
    var bodyReads = 0
    let previous = NotebookRenderDocumentGeometry.acceptanceConfiguration
    NotebookRenderDocumentGeometry.acceptanceConfiguration = .init(storeRoot: fixture.store.root,
      beforeBodyRead: { _ in bodyReads += 1 })
    defer { NotebookRenderDocumentGeometry.acceptanceConfiguration = previous }
    let tooSmall = SceneRenderResources(byteLimit: NotebookRenderDocumentGeometry.sourceReadBytes - 1)
    do {
      _ = try await NotebookRenderDocumentGeometry.capture(store: fixture.store,
        presence: fixture.presence, resources: tooSmall)
      XCTFail("A body-read admission larger than the pool must be refused")
    } catch SceneRenderError.resourceLimit {}
    XCTAssertEqual(bodyReads, 0)
    XCTAssertEqual(tooSmall.reservedBytes, 0)
    XCTAssertEqual(tooSmall.pendingDerivedRequestCount, 0)

    let resources = SceneRenderResources()
    let capture = try await NotebookRenderDocumentGeometry.capture(store: fixture.store,
      presence: fixture.presence, resources: resources)
    let metadataBytes = resources.reservedBytes
    let held = try XCTUnwrap(resources.reserveDerivedBytes(NotebookRenderDocumentGeometry.sourceReadBytes,
      priority: .input))
    defer { held.release() }
    let preparation = Task { @MainActor in
      try await NotebookRenderDocumentGeometry.prepare(store: fixture.store, capture: capture, resources: resources)
    }
    defer { preparation.cancel() }
    let deadline = ContinuousClock.now + .seconds(5)
    while resources.pendingDerivedRequestCount == 0, .now < deadline { await Task.yield() }
    XCTAssertEqual(resources.pendingDerivedRequestCount, 1)
    XCTAssertEqual(bodyReads, 0, "A queued source admission must not decode or retain its document")
    preparation.cancel()
    do { _ = try await preparation.value; XCTFail("A cancelled admission returned geometry") }
    catch { XCTAssertTrue(error is CancellationError, "\(error)") }
    XCTAssertEqual(resources.pendingDerivedRequestCount, 0)
    XCTAssertEqual(bodyReads, 0)
    XCTAssertEqual(resources.reservedBytes, metadataBytes + held.byteCount)
    held.release()
    XCTAssertEqual(resources.reservedBytes, metadataBytes)
  }

  func testSourceChangedAfterActualPrintRefusesTheOriginalImageCut() async throws {
    let fixture = try makeFixture(papers: [(720, 400)])
    defer { try? FileManager.default.removeItem(at: fixture.store.root) }
    let resources = SceneRenderResources()
    let capture = try await NotebookRenderDocumentGeometry.capture(store: fixture.store,
      presence: fixture.presence, resources: resources)
    let metadataBytes = resources.reservedBytes
    var printedIDs: [UUID] = []
    let previous = NotebookRenderDocumentGeometry.acceptanceConfiguration
    NotebookRenderDocumentGeometry.acceptanceConfiguration = .init(storeRoot: fixture.store.root,
      printed: { id in
        printedIDs.append(id)
        try self.changeSource(id, in: fixture)
      })
    defer { NotebookRenderDocumentGeometry.acceptanceConfiguration = previous }
    do {
      _ = try await NotebookRenderDocumentGeometry.prepare(store: fixture.store, capture: capture, resources: resources)
      XCTFail("Paper compiled from an obsolete original cut cannot escape as current geometry")
    } catch {
      XCTAssertEqual((error as? CollaborationError)?.code, "snapshot_changed", "\(error)")
    }
    XCTAssertEqual(printedIDs, fixture.ids, "The real compiler completed before the source changed")
    XCTAssertEqual(try PreviewSourceIdentity.read(fixture.store, presence: fixture.presence), capture.identity)
    XCTAssertEqual(resources.reservedBytes, metadataBytes)
    XCTAssertEqual(resources.pendingDerivedRequestCount, 0)
  }

  private struct Fixture {
    let store: NotebookStore
    let actor: UUID
    let presence: SessionPresence
    let ids: [UUID]
    let papers: [(Double, Double)]
  }

  private func makeFixture(papers: [(Double, Double)], distantElements: Int = 0) throws -> Fixture {
    let store = NotebookStore(root: FileManager.default.temporaryDirectory
      .appendingPathComponent("render-document-geometry-" + UUID().uuidString))
    let actor = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    var index = try store.loadIndex(), board = try store.loadBoard(items: index.items)
    var ids: [UUID] = []
    for (number, paper) in papers.enumerated() {
      let item = try XCTUnwrap(index.createDocument(title: "Geometry \(number)", actor: actor))
      XCTAssertTrue(board.addItem(item.id, to: index.rootBoardID,
        near: .init(x: Double(number) * 700 - 350, y: 0), actor: actor))
      let document = DocumentTestFiles.document(id: item.id, actor: actor,
        contents: [.tex(id: "body", source: "Actual bounded paper \(item.id.uuidString).")],
        width: paper.0, height: paper.1)
      try store.saveDocumentWorkspaceBundle(index: index, document: document,
        state: .init(id: item.id, actor: actor), board: board)
      ids.append(item.id)
    }
    if distantElements > 0 {
      let parent = "board.json#/boards/@" + index.rootBoardID.uuidString.lowercased()
      let stamp = VersionStamp(counter: 0, actor: actor), started = ContinuousClock.now
      // The existing fragment writer publishes real bodies and normal derived
      // bounds, streaming the fixture without a full BoardDocument in memory.
      try store.commandTransaction {
        for number in 0..<distantElements {
          let distance = Double(number + 1) * 5_000
          let origin: WorldPoint
          switch number % 4 {
          case 0: origin = .init(x: 0, y: distance)
          case 1: origin = .init(x: 0, y: -distance)
          case 2: origin = .init(x: distance, y: 0)
          default: origin = .init(x: -distance, y: 0)
          }
          let element = SpatialElement(id: "distant-\(number)", surface: .board(index.rootBoardID), kind: .nativeText,
            frame: .init(x: 0, y: 0, width: 24, height: 24), worldOrigin: origin, source: "\(number)", stamp: stamp)
          try store.writeFragment(.init(address: parent + "/board/elements/@" + element.id, file: "board.json",
            parent: parent, collection: "board/elements", member: element.id, position: number,
            value: try .encode(element), collections: []), database: store.currentSQL!)
        }
      }
      print("DOCUMENT_GEOMETRY_SEED board_elements=\(distantElements) visible_documents=\(ids.count) elapsed=\(started.duration(to: .now))")
    }
    return .init(store: store, actor: actor,
      presence: .init(boardID: index.rootBoardID, mode: .board,
        camera: .init(), viewport: .init(x: 2000, y: 1400)), ids: ids, papers: papers)
  }

  private func changeSource(_ id: UUID, in fixture: Fixture) throws {
    var document = try fixture.store.loadDocument(id)
    XCTAssertTrue(document.replaceFileSource(id: "body", source: "A newer authored paper.", actor: fixture.actor))
    try fixture.store.saveDocument(document)
  }
}

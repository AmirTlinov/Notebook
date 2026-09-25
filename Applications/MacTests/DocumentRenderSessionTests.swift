import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class DocumentRenderSessionTests: XCTestCase {
  private func coordinator(resources: SceneRenderResources, document: DocumentDocument, state: DocumentStateJournal, page: Int = 0) -> DocumentWebCoordinator {
    let value = DocumentWebCoordinator(resources: resources, onRenderReady: .init { _ in },
      onPageLayout: { _ in },  onStateChange: { _, _ in nil })
    update(value, document: document, state: state, page: page)
    return value
  }

  private func update(_ value: DocumentWebCoordinator, document: DocumentDocument, state: DocumentStateJournal, page: Int = 0) {
    value.update(document: document, state: state, selectedPageIndex: page, capturesSnapshot: false,
      onRenderReady: .init { _ in }, onPageLayout: { _ in },  onStateChange: { _, _ in nil })
  }

  func testClosedMultiPageProgramExportSharesOnePDFSyncTeXPreparation() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.interactive(id: "long-program",
      html: "<div style='height:1800px;background:linear-gradient(red,blue)'></div>",
      javaScript: "notebook.exportFrame(() => null); notebook.ready(Promise.resolve());", height: 1800)])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    let resources = SceneRenderResources(), session = DocumentRenderSession(documentID: document.id)
    let source = session.source(document)
    let printed: DocumentPrintedSource
    do { printed = try await source.printedSource(resources: resources) }
    catch {
      XCTFail("The export-owned PDF/SyncTeX source must prepare before any page heap: \(error)")
      throw error
    }
    let pageCount = try XCTUnwrap(source.layout).pageCount
    XCTAssertGreaterThan(pageCount, 1)
    let isolation = UUID()
    let output=FileManager.default.temporaryDirectory.appendingPathComponent("shared-print-\(UUID()).pdf")
    defer { try? FileManager.default.removeItem(at:output) }
    let composer=try await PrintedPDFComposer.open(printed.pdf,outputURL:output)
    for index in 0..<pageCount {
      do { try await DocumentSnapshotCache.shared.withPreparedPage(document: document, state: state, pageIndex: index,
        resources: resources, programStore: nil, isolationID: isolation, renderSession: session) { coordinator in
        let pixels = try await coordinator.retainPreparedSnapshot(pixelWidth: 160, force: true, waitsForRasterAdmission: true)
        defer { pixels.release() }
        XCTAssertTrue(coordinator.payload?.source === source,
          "The isolated page heap must use the export-owned immutable print source")
        let rendered=try XCTUnwrap(coordinator.payload?.source)
        let current=try await rendered.printedSource(resources:resources)
        XCTAssertTrue(current === printed)
        XCTAssertTrue(current.pdf === printed.pdf)
        let openings=await printed.pdf.openedDocumentCount()
        XCTAssertEqual(openings,1,"Mounted paper and composed snapshots borrow the same actual PDF parser")
        try await composer.append(pageIndex:index,image:nil,regions:[])
        XCTAssertEqual(source.preparationCount, 1)
        XCTAssertEqual(source.measurementCount, 1, "PDF, SyncTeX, navigation and hit regions are decoded once, not once per page")
      }
      } catch { XCTFail("Export page \(index) must reuse the prepared source: \(error)"); throw error }
      XCTAssertEqual(resources.activeWebSurfaceCount, 0, "Each isolated page executor retires while the print source stays owned")
    }
    try await composer.finish()
    let openings=await printed.pdf.openedDocumentCount()
    XCTAssertEqual(openings,1,"Composition does not open its own copy of the common PDF")
  }

  func testFourPagesShareExactlyOneImmutableSourceAndStateEncodingWithoutAllocatingWebKit() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: (0..<512).map { .markdown(id: "block-\($0)", source: "Source \($0)") })
    let state = DocumentStateJournal(id: document.id, actor: UUID()), resources = SceneRenderResources()
    let pages = (0..<4).map { coordinator(resources: resources, document: document, state: state, page: $0) }
    defer { pages.forEach { $0.invalidate() } }
    let first = try XCTUnwrap(pages[0].payload)
    for page in pages {
      XCTAssertTrue(page.payload?.source === first.source)
      XCTAssertTrue(page.payload?.state === first.state)
      XCTAssertTrue(page.renderSession === pages[0].renderSession)
      XCTAssertNil(page.webView)
    }
    async let stateA = first.state.encodedState(resources: resources)
    async let stateB = first.state.encodedState(resources: resources)
    let encoded = try await (stateA, stateB)
    XCTAssertTrue(encoded.0 === encoded.1)
    XCTAssertEqual(first.state.encodingCount, 1)
    XCTAssertEqual(first.source.preparedSourceBlockCount, 0,
      "Mounting neighbours does not encode or transfer the source before a page demand")
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
  }

  func testEqualMaxSourceStampDoesNotAliasDifferentContentOrChangeTheOldNeighbor() throws {
    let actor = UUID(), id = UUID(), resources = SceneRenderResources()
    let before = DocumentDocument(id: id, actor: actor, blocks: [.markdown(id: "body", source: "Before")])
    let after = DocumentDocument(id: id, actor: actor, blocks: [.markdown(id: "body", source: "After")])
    let state = DocumentStateJournal(id: id, actor: actor)
    XCTAssertEqual(before.contentStamp, after.contentStamp)
    let current = coordinator(resources: resources, document: before, state: state)
    let neighbor = coordinator(resources: resources, document: before, state: state, page: 1)
    defer { current.invalidate(); neighbor.invalidate() }
    let original = try XCTUnwrap(current.payload?.source)
    update(current, document: after, state: state)
    XCTAssertFalse(current.payload?.source === original)
    XCTAssertTrue(neighbor.payload?.source === original)
    XCTAssertEqual(neighbor.payload?.blocks.first?.source, "Before")
    XCTAssertEqual(current.payload?.blocks.first?.source, "After")
    XCTAssertTrue(current.renderSession?.source(before) === original,
      "Interning another value at the same stamp must not replace the old immutable version")
  }

  func testEqualMaxStateStampDoesNotAliasDifferentRecordsOrRewriteTheOldSnapshot() throws {
    let actor = UUID(), document = DocumentDocument(actor: UUID(), blocks: [.interactive(id: "body", html: "<button>Control</button>", height: 100)]), resources = SceneRenderResources()
    let stamp = VersionStamp(counter: 0, actor: actor)
    let before = DocumentStateJournal(id: document.id, actor: actor, records: [.init(id: "body", value: .number(1), stamp: stamp)])
    let after = DocumentStateJournal(id: document.id, actor: actor, records: [.init(id: "body", value: .number(2), stamp: stamp)])
    XCTAssertEqual(before.stamp, after.stamp)
    let current = coordinator(resources: resources, document: document, state: before)
    let neighbor = coordinator(resources: resources, document: document, state: before, page: 1)
    defer { current.invalidate(); neighbor.invalidate() }
    let first = try XCTUnwrap(current.payload)
    update(current, document: document, state: after)
    XCTAssertTrue(current.payload?.source === first.source)
    XCTAssertFalse(current.payload?.state === first.state)
    XCTAssertTrue(neighbor.payload?.state === first.state)
    XCTAssertEqual(first.states["body"], .number(1))
    XCTAssertEqual(current.payload?.states["body"], .number(2))
    XCTAssertEqual(current.payload?.blockTokens, first.blockTokens)
  }

  func testAPageReceiptCannotCreateAFullLayoutOrNameAnAbsentPage() throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: "Body")])
    let source = DocumentRenderSession(documentID: document.id).source(document)
    let geometry = WorkspaceItemGeometry.document(document.paperSize)
    var receipt: [String: Any] = ["sourceKey": source.message.key, "layoutScope": "page", "layoutCanonical": true, "anchors": [], "reading": [],
      "pageIndex": 0, "pageCount": 1, "width": geometry.width, "height": geometry.height, "regions": []]
    XCTAssertThrowsError(try source.acceptLayout(receipt as NSDictionary, geometry: geometry))
    XCTAssertNil(source.layout)
    receipt["layoutScope"] = "source"
    let full = try source.acceptLayout(receipt as NSDictionary, geometry: geometry)
    receipt["layoutScope"] = "page"; receipt["pageIndex"] = 1
    XCTAssertThrowsError(try source.acceptLayout(receipt as NSDictionary, geometry: geometry))
    XCTAssertTrue(source.layout === full)
    receipt["pageIndex"] = 0
    XCTAssertTrue(try source.acceptLayout(receipt as NSDictionary, geometry: geometry) === full)
    receipt["layoutScope"] = "partial-but-pretending"
    XCTAssertThrowsError(try source.acceptLayout(receipt as NSDictionary, geometry: geometry))
  }

  func testStateProjectionSharesUnchangedProgramsAcrossJournalVersions() throws {
    let document = DocumentDocument(actor: UUID()), actor = UUID()
    let session = DocumentRenderSession(documentID: document.id)
    var state = DocumentStateJournal(id: document.id, actor: actor)
    XCTAssertTrue(state.commit(blockID: "first", value: .number(1), actor: actor))
    let first = session.state(state, blockIDs: ["first"])
    let paper = session.state(state, blockIDs: [])
    XCTAssertTrue(state.commit(blockID: "other", value: .number(2), actor: actor))
    XCTAssertTrue(session.state(state, blockIDs: ["first"]) === first)
    XCTAssertTrue(session.state(state, blockIDs: []) === paper)
    XCTAssertTrue(paper.records.isEmpty)
    XCTAssertTrue(state.commit(blockID: "first", value: .number(3), actor: actor))
    XCTAssertFalse(session.state(state, blockIDs: ["first"]) === first)
    XCTAssertEqual(first.message.states, ["first": .number(1)])
  }

  func testLayoutAcceptanceRejectsAnInconsistentNeighborWithoutReplacingTheFirstRecord() throws {
    let registry = DocumentRenderRegistry(), resources = SceneRenderResources()
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: "Body")])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    let session = registry.session(documentID: document.id, resources: resources), source = session.source(document)
    let geometry = WorkspaceItemGeometry.document(document.paperSize)
    func receipt(height: Double) -> NSDictionary {
      ["sourceKey": source.message.key, "layoutScope": "source", "layoutCanonical": true, "anchors": [], "reading": [], "pageIndex": 0, "pageCount": 1,
        "width": geometry.width, "height": geometry.height,
        "regions": [["id": "body", "pageIndex": 0, "x": 70.0, "y": 70.0, "width": 200.0, "height": height, "sourceOffset": 0.0]]]
    }
    let token = DocumentSnapshotCache.token(document: document, state: state, pageIndex: 0)
    try registry.publish(documentID: document.id, token: token, source: source, receipt: receipt(height: 100), geometry: geometry)
    let first = try XCTUnwrap(source.layout)
    try registry.publish(documentID: document.id, token: token, source: source, receipt: receipt(height: 100), geometry: geometry)
    XCTAssertTrue(source.layout === first)
    XCTAssertThrowsError(try registry.publish(documentID: document.id, token: token, source: source, receipt: receipt(height: 101), geometry: geometry)) { error in
      XCTAssertEqual(error.localizedDescription, "document_layout_inconsistent")
    }
    XCTAssertTrue(source.layout === first)
    XCTAssertTrue(registry.entry(document: document, pageIndex: 0)?.layout === first)
    XCTAssertEqual(first.regions.first?.frame.height, 100)
  }

  func testSessionAndUnreferencedSnapshotsAreNotASecondPermanentDocumentHistory() throws {
    let registry = DocumentRenderRegistry(), resources = SceneRenderResources()
    let document = DocumentDocument(actor: UUID())
    var session: DocumentRenderSession? = registry.session(documentID: document.id, resources: resources)
    weak let observedSession = session
    var source: DocumentSourceSnapshot? = session?.source(document)
    weak let observedSource = source
    XCTAssertNotNil(observedSource)
    source = nil
    XCTAssertNil(observedSource, "The session's intern table does not retain unused revisions")
    session = nil
    XCTAssertNil(observedSession, "The registry is a weak lookup, not another session owner")
  }
}

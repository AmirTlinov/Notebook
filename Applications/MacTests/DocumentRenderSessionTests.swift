import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class DocumentRenderSessionTests: XCTestCase {
  private func coordinator(resources: SceneRenderResources, document: DocumentDocument, state: DocumentStateJournal, page: Int = 0) -> DocumentWebCoordinator {
    let value = DocumentWebCoordinator(resources: resources, onRenderReady: .init { _ in },
      onPageLayout: { _ in }, onSourceChange: { _ in .committed }, onStateChange: { _,_ in })
    update(value, document: document, state: state, page: page)
    return value
  }

  private func update(_ value: DocumentWebCoordinator, document: DocumentDocument, state: DocumentStateJournal, page: Int = 0) {
    value.update(document: document, state: state, selectedPageIndex: page, capturesSnapshot: false,
      onRenderReady: .init { _ in }, onPageLayout: { _ in }, onSourceChange: { _ in .committed }, onStateChange: { _,_ in })
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
    async let sourceA = first.source.encodedJSON()
    async let sourceB = first.source.encodedJSON()
    async let stateA = first.state.encodedJSON()
    async let stateB = first.state.encodedJSON()
    let encoded = try await (sourceA, sourceB, stateA, stateB)
    XCTAssertEqual(encoded.0, encoded.1); XCTAssertEqual(encoded.2, encoded.3)
    XCTAssertEqual(first.source.encodingCount, 1); XCTAssertEqual(first.state.encodingCount, 1)
    let source = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.0.utf8)) as? [String: Any])
    XCTAssertNil(source["states"]); XCTAssertNil(source["pageIndex"]); XCTAssertNil(source["renderToken"])
    XCTAssertEqual((source["blocks"] as? [Any])?.count, 512)
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
    let actor = UUID(), document = DocumentDocument(actor: UUID()), resources = SceneRenderResources()
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
    var receipt: [String: Any] = ["sourceKey": source.message.key, "layoutScope": "page", "layoutCanonical": true,
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

  func testLayoutAcceptanceRejectsAnInconsistentNeighborWithoutReplacingTheFirstRecord() throws {
    let registry = DocumentRenderRegistry(), resources = SceneRenderResources()
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: "Body")])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    let session = registry.session(documentID: document.id, resources: resources), source = session.source(document)
    let geometry = WorkspaceItemGeometry.document(document.paperSize)
    func receipt(height: Double) -> NSDictionary {
      ["sourceKey": source.message.key, "layoutScope": "source", "layoutCanonical": true, "pageIndex": 0, "pageCount": 1,
        "width": geometry.width, "height": geometry.height,
        "regions": [["id": "body", "pageIndex": 0, "x": 70.0, "y": 70.0, "width": 200.0, "height": height, "sourceOffset": 0.0]]]
    }
    let token = DocumentSnapshotCache.token(document: document, state: state, pageIndex: 0)
    try registry.publish(documentID: document.id, token: token, receipt: receipt(height: 100), geometry: geometry)
    let first = try XCTUnwrap(source.layout)
    try registry.publish(documentID: document.id, token: token, receipt: receipt(height: 100), geometry: geometry)
    XCTAssertTrue(source.layout === first)
    XCTAssertThrowsError(try registry.publish(documentID: document.id, token: token, receipt: receipt(height: 101), geometry: geometry)) { error in
      XCTAssertEqual(error.localizedDescription, "document_layout_inconsistent")
    }
    XCTAssertTrue(source.layout === first)
    XCTAssertTrue(registry.entry(document: document, state: state, pageIndex: 0)?.layout === first)
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

import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class DocumentRenderSessionTests: XCTestCase {
  func testClosedMultiPageProgramExportSharesOnePDFSyncTeXPreparation() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.program(id: "long-program",
      html: "<div style='height:1800px;background:linear-gradient(red,blue)'></div>",
      javaScript: "notebook.exportFrame(() => null); notebook.ready(Promise.resolve());", height: 1800)])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    let resources = SceneRenderResources(), session = DocumentRenderSession(documentID: document.id)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shared-print-store-" + UUID().uuidString)
    let store = NotebookStore(root: root)
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    defer { try? FileManager.default.removeItem(at: root) }
    let source = session.source(document, store: store)
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
        resources: resources, programStore: store, isolationID: isolation, renderSession: session) { coordinator in
        let pixels = try await coordinator.retainPreparedSnapshot(pixelWidth: 160, force: true, waitsForRasterAdmission: true)
        defer { pixels.release() }
        XCTAssertTrue(coordinator.source === source,
          "The isolated page heap must use the export-owned immutable print source")
        let rendered=coordinator.source
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

  func testFourPagesShareExactlyOneImmutableSourceAndStateWithoutAllocatingWebKit() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: (0..<512).map { .tex(id: "block-\($0)", source: "Source \($0)") })
    let state = DocumentStateJournal(id: document.id, actor: UUID()), resources = SceneRenderResources()
    let session = DocumentRenderSession(documentID: document.id)
    let sources = (0..<4).map { _ in session.source(document) }
    let first = session.state(state)
    for source in sources { XCTAssertTrue(source === sources[0]); XCTAssertTrue(session.state(state) === first) }
    XCTAssertEqual(sources[0].preparedSourceBlockCount, 0)
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
  }

  func testEqualMaxSourceStampDoesNotAliasDifferentContentOrChangeTheOldNeighbor() throws {
    let actor = UUID(), id = UUID()
    let before = DocumentTestFiles.document(id: id, actor: actor, contents: [.tex(id: "body", source: "Before")])
    let after = DocumentTestFiles.document(id: id, actor: actor, contents: [.tex(id: "body", source: "After")])
    XCTAssertEqual(before.contentStamp, after.contentStamp)
    let session = DocumentRenderSession(documentID: id), original = session.source(before)
    let replacement = session.source(after)
    XCTAssertFalse(replacement === original)
    XCTAssertEqual(original.document.files.first { $0.id == "body" }?.source, "Before")
    XCTAssertEqual(replacement.document.files.first { $0.id == "body" }?.source, "After")
    XCTAssertTrue(session.source(before) === original)
  }

  func testEqualMaxStateStampDoesNotAliasDifferentRecordsOrRewriteTheOldSnapshot() throws {
    let actor = UUID(), id = UUID(), stamp = VersionStamp(counter: 0, actor: UUID())
    let before = DocumentStateJournal(id: id, actor: actor, records: [.init(id: "body", value: .number(1), stamp: stamp)])
    let after = DocumentStateJournal(id: id, actor: actor, records: [.init(id: "body", value: .number(2), stamp: stamp)])
    XCTAssertEqual(before.stamp, after.stamp)
    let session = DocumentRenderSession(documentID: id), first = session.state(before), next = session.state(after)
    XCTAssertFalse(first === next); XCTAssertTrue(session.state(before) === first)
    XCTAssertEqual(first.message.states["body"], .number(1)); XCTAssertEqual(next.message.states["body"], .number(2))
  }

  func testPagePublicationRequiresAnAcceptedPhysicalLayoutAndAnExistingPage() throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.tex(id: "body", source: "Body")])
    let source = DocumentRenderSession(documentID: document.id).source(document), registry = DocumentRenderRegistry()
    XCTAssertThrowsError(try registry.publishNative(source: source, token: "unprepared", pageIndex: 0))
    XCTAssertNil(source.layout)
    let paper = DocumentPaperLayout(widthPoints: 720, heightPoints: 400)
    let full = try DocumentLayoutFixture.make(pages: [paper])
    try source.acceptPreparedLayout(full)
    XCTAssertThrowsError(try registry.publishNative(source: source, token: "absent-page", pageIndex: 1))
    XCTAssertTrue(source.layout === full)
    try registry.publishNative(source: source, token: "physical-page", pageIndex: 0)
    XCTAssertTrue(registry.entry(document: document, pageIndex: 0)?.layout === full)
    XCTAssertEqual(full.paper(on: 0), paper)
    XCTAssertEqual(full.paper(on: 0).widthPoints, 720)
    XCTAssertEqual(full.paper(on: 0).heightPoints, 400)
  }

  func testStateProjectionSharesUnchangedProgramsAcrossJournalVersions() throws {
    let document = DocumentDocument(actor: UUID()), actor = UUID()
    let session = DocumentRenderSession(documentID: document.id)
    var state = DocumentStateJournal(id: document.id, actor: actor)
    XCTAssertTrue(state.commit(instanceID: "first", value: .number(1), actor: actor))
    let first = session.state(state, blockIDs: ["first"])
    let paper = session.state(state, blockIDs: [])
    XCTAssertTrue(state.commit(instanceID: "other", value: .number(2), actor: actor))
    XCTAssertTrue(session.state(state, blockIDs: ["first"]) === first)
    XCTAssertTrue(session.state(state, blockIDs: []) === paper)
    XCTAssertTrue(paper.records.isEmpty)
    XCTAssertTrue(state.commit(instanceID: "first", value: .number(3), actor: actor))
    XCTAssertFalse(session.state(state, blockIDs: ["first"]) === first)
    XCTAssertEqual(first.message.states, ["first": .number(1)])
  }

  func testLayoutAcceptanceRejectsAnInconsistentNeighborWithoutReplacingTheFirstRecord() throws {
    let registry = DocumentRenderRegistry(), resources = SceneRenderResources()
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.tex(id: "body", source: "Body")])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    let session = registry.session(documentID: document.id, resources: resources), source = session.source(document)
    func layout(height: Double) throws -> DocumentLayoutRecord {
      try DocumentLayoutFixture.make(regions: [.init(id: "body", pageIndex: 0,
        frame: .init(x: 70, y: 70, width: 200, height: height), sourceOffset: 0)])
    }
    let token = DocumentSnapshotCache.token(document: document, state: state, pageIndex: 0)
    try source.acceptPreparedLayout(layout(height: 100))
    try registry.publishNative(source: source, token: token, pageIndex: 0)
    let first = try XCTUnwrap(source.layout)
    try source.acceptPreparedLayout(layout(height: 100))
    try registry.publishNative(source: source, token: token, pageIndex: 0)
    XCTAssertTrue(source.layout === first)
    XCTAssertThrowsError(try source.acceptPreparedLayout(layout(height: 101))) { error in
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

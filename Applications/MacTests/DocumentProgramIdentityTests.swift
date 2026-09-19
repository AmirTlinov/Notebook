import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class DocumentProgramIdentityTests: XCTestCase {
  private func update(_ coordinator: DocumentWebCoordinator, document: DocumentDocument, state: DocumentStateJournal,
    pageIndex: Int = 0) {
    coordinator.update(document: document, state: state, selectedPageIndex: pageIndex, capturesSnapshot: false,
      onRenderReady: .init { _ in }, onPageLayout: { _ in },  onStateChange: { _, _ in nil })
  }

  func testPackageReplacementInvalidatesProgramAndRasterIdentityWithoutChangingPlacement() throws {
    let actor = UUID(), first = String(repeating: "a", count: 64), second = String(repeating: "b", count: 64)
    let a = AgentElement(id: "p", kind: .web, frame: .init(x: 0, y: 0, width: 100, height: 100), source: "", html: "", programPackage: first)
    let b = AgentElement(id: "p", kind: .web, frame: a.frame, source: "", html: "", programPackage: second)
    XCTAssertNotEqual(AgentProgramSource(a), AgentProgramSource(b))
    XCTAssertNotEqual(SceneRasterSource.agent(a), .agent(b))
    XCTAssertEqual(SceneRasterSource.agent(a), .agent(a.updating(frame: .init(x: 80, y: 70, width: 100, height: 100))))
    var document = DocumentDocument(actor: actor, blocks: [.interactive(id: "p", html: "", programPackage: first)])
    let state = DocumentStateJournal(id: document.id, actor: actor)
    let coordinator = DocumentWebCoordinator(onRenderReady: .init { _ in }, onPageLayout: { _ in },
      onStateChange: { _, _ in nil })
    defer { coordinator.invalidate() }
    update(coordinator, document: document, state: state)
    let before = try XCTUnwrap(coordinator.payload?.blockTokens["p"])
    XCTAssertTrue(document.replaceContent(blocks: [.interactive(id: "p", html: "", programPackage: second)], actor: actor))
    update(coordinator, document: document, state: state)
    XCTAssertNotEqual(coordinator.payload?.blockTokens["p"], before)
  }

  func testStateAndPageChangesKeepEveryProgramAtTheMaximumDocumentSize() throws {
    let document = DocumentDocument(actor: UUID(), blocks: (0..<DocumentDocument.maximumBlockCount).map {
      .interactive(id: "block-\($0)", html: "<button>Program \($0)</button>", height: 100)
    })
    var state = DocumentStateJournal(id: document.id, actor: UUID())
    let coordinator = DocumentWebCoordinator(onRenderReady: .init { _ in }, onPageLayout: { _ in },
       onStateChange: { _, _ in nil })
    defer { coordinator.invalidate() }
    update(coordinator, document: document, state: state)
    let first = try XCTUnwrap(coordinator.payload)
    XCTAssertEqual(first.blockTokens.count, DocumentDocument.maximumBlockCount)
    for page in 1...4 {
      XCTAssertTrue(state.commit(blockID: "block-0", value: .number(Double(page)), actor: UUID()))
      update(coordinator, document: document, state: state, pageIndex: page)
      let current = try XCTUnwrap(coordinator.payload)
      XCTAssertEqual(current.blockTokens, first.blockTokens)
      XCTAssertEqual(current.runtimeID, first.runtimeID)
      XCTAssertEqual(current.states["block-0"], .number(Double(page)))
      XCTAssertEqual(current.pageIndex, page)
    }
    XCTAssertNil(coordinator.webView, "Preparing source identities cannot allocate a hidden fifth WebKit")
  }

  func testReorderAndRemovalPreserveOnlyTheProgramsWhoseSourceStillExists() throws {
    let actor = UUID()
    var document = DocumentDocument(actor: actor, blocks: (0..<12).map { .markdown(id: "block-\($0)", source: "Source \($0)") })
    let state = DocumentStateJournal(id: document.id, actor: actor)
    let coordinator = DocumentWebCoordinator(onRenderReady: .init { _ in }, onPageLayout: { _ in },
       onStateChange: { _, _ in nil })
    defer { coordinator.invalidate() }
    update(coordinator, document: document, state: state)
    let first = try XCTUnwrap(coordinator.payload?.blockTokens)
    XCTAssertTrue(document.replaceContent(blocks: Array(document.blocks.reversed()), actor: actor))
    update(coordinator, document: document, state: state)
    XCTAssertEqual(coordinator.payload?.blockTokens, first, "Order is not a program restart")
    XCTAssertTrue(document.replaceBlockSource(id: "block-3", source: "Changed", actor: actor))
    update(coordinator, document: document, state: state)
    let edited = try XCTUnwrap(coordinator.payload?.blockTokens)
    XCTAssertNotEqual(edited["block-3"], first["block-3"])
    for (id, token) in first where id != "block-3" { XCTAssertEqual(edited[id], token) }
    XCTAssertTrue(document.replaceContent(blocks: document.blocks.filter { $0.id != "block-5" } + [.markdown(id: "new", source: "New")], actor: actor))
    update(coordinator, document: document, state: state)
    let final = try XCTUnwrap(coordinator.payload?.blockTokens)
    XCTAssertEqual(final.count, 12)
    XCTAssertNil(final["block-5"])
    XCTAssertNotNil(final["new"])
    for (id, token) in edited where id != "block-5" { XCTAssertEqual(final[id], token) }
  }
}

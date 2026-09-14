import NotebookCore
import UIKit
import WebKit
import XCTest
@testable import Notebook

@MainActor
final class DocumentLinkActivationTests: XCTestCase {
  func testAnActuallyAdmittedWebKitActivationRoutesAfterInputPolicyChanges() async throws {
    let fixture = try await fixture()
    defer { fixture.close() }
    let activation = try await fixture.activation()
    guard case .page(let target) = activation.destination else { return XCTFail("The real measured anchor must resolve to a page") }
    XCTAssertGreaterThan(target, 1)
    XCTAssertEqual(activation.origin.pageIndex, 0)
    fixture.coordinator.updateInputAdmission(in: fixture.host, isInteractive: false)
    XCTAssertFalse(fixture.coordinator.nativeInputIsReady(in: fixture.host))
    // This is an actual JS→native terminal receipt accepted while input was
    // admitted, whose model delivery follows the policy change. It does not
    // claim that a scripted click is trusted or replace the real-touch UI test.
    XCTAssertEqual(fixture.model.activateDocumentLink(activation), .page(target))
    XCTAssertEqual(fixture.model.presence?.documentPageIndex, 0)
    XCTAssertEqual(fixture.model.documentPageSelection?.pageIndex, target)
    let request = try XCTUnwrap(fixture.model.documentPageSelection)
    let controller = UUID(), source = NotebookAppModel.documentPageSourceRevision(try XCTUnwrap(fixture.model.documents[activation.origin.documentID]))
    fixture.model.bindDocumentPageController(controller, documentID: activation.origin.documentID, source: source)
    XCTAssertTrue(fixture.model.acceptDocumentPageLanding(.init(controllerID: controller,
      documentID: activation.origin.documentID, sourceRevision: source, revision: 1, pageIndex: target, requestID: request.id)))
    XCTAssertNil(fixture.model.activateDocumentLink(activation), "Only a reached different page retires the old model origin")
  }

  func testStateCommitBeforeNavigationKeepsTheUserChangeAndTheCurrentDestination() async throws {
    let fixture = try await fixture()
    defer { fixture.close() }
    let activation = try await fixture.activation()
    let sourceVersion = try XCTUnwrap(fixture.model.documents[activation.origin.documentID]?.sourceVersion(blockID: "widget"))
    let changed = fixture.model.commitDocumentState(documentID: activation.origin.documentID,
      blockID: "widget", value: .string("later user state"), sourceVersion: sourceVersion)
    XCTAssertNotNil(changed)
    XCTAssertEqual(fixture.model.activateDocumentLink(activation), activation.destination)
    if case .page(let target) = activation.destination {
      XCTAssertEqual(fixture.model.documentPageSelection?.pageIndex, target)
      XCTAssertEqual(fixture.model.presence?.documentPageIndex, 0)
    }
    XCTAssertEqual(fixture.model.documentStates[activation.origin.documentID]?.records.first { $0.id == "widget" }?.value,
      .string("later user state"))
  }

  func testSourceReplacementRejectsTheOldActivation() async throws {
    let fixture = try await fixture()
    defer { fixture.close() }
    let activation = try await fixture.activation()
    let document = try XCTUnwrap(fixture.model.documents[activation.origin.documentID])
    let block = try XCTUnwrap(document.blocks.first { $0.id == "far" })
    let edit = DocumentSourceEdit(sessionID: UUID(), documentID: document.id, blockID: block.id,
      baseSource: block.source, baseVersion: document.sourceVersion(blockID: block.id),
      source: "# A changed destination", sequence: 1)
    let status = try await fixture.model.commitDocumentSource(edit: edit)
    XCTAssertEqual(status, .committed)
    XCTAssertNil(fixture.model.activateDocumentLink(activation))
    XCTAssertEqual(fixture.model.presence?.documentPageIndex, 0)
  }

  func testTheStableOwnerUsesTheCanonicalRangeAndRejectsAClosedOrigin() async throws {
    let fixture = try await fixture()
    defer { fixture.close() }
    let activation = try await fixture.activation()
    let layout = try XCTUnwrap(activation.origin.source.layout)
    XCTAssertNil(fixture.model.activateDocumentLink(.init(origin: activation.origin, destination: .page(layout.pageCount))))
    let presence = try XCTUnwrap(fixture.model.presence)
    fixture.model.updatePresence(.init(boardID: presence.boardID, mode: .cover,
      camera: presence.camera, viewport: presence.viewport, focusedItemID: activation.origin.documentID,
      openProgress: 0, selectedItemID: activation.origin.documentID), settled: true)
    XCTAssertNil(fixture.model.activateDocumentLink(activation))
    XCTAssertNil(fixture.model.activateDocumentLink(.init(origin: activation.origin,
      destination: .external(URL(string: "https://example.com")!))))
  }

  private func fixture() async throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("document-activation-" + UUID().uuidString)
    let store = NotebookStore(root: root), actor = UUID(), pageSize = NotebookAppModel.defaultPageSize
    let documentID = try await Task.detached {
      _ = try store.initializeWorkspace(actor: actor, pageSize: pageSize)
      var index = try store.loadIndex(), board = try store.loadBoard(items: index.items)
      let item = try XCTUnwrap(index.createDocument(title: "Link owner", actor: actor))
      XCTAssertTrue(board.addItem(item.id, to: index.rootBoardID, near: .zero, actor: actor))
      let document = DocumentDocument(id: item.id, actor: actor, blocks: [
        .markdown(id: "contents", source: "[Far chapter](#far)"),
        .markdown(id: "body", source: String(repeating: "A physical canonical paragraph preserves its navigation origin.\n\n", count: 140)),
        .markdown(id: "far", source: "# Far\n\nThe actual measured destination."),
        .interactive(id: "widget", html: "<output>A real stateful block</output>")])
      try store.saveDocumentWorkspaceBundle(index: index, document: document,
        state: .init(id: item.id, actor: actor), board: board)
      try store.savePresence(.init(boardID: index.rootBoardID, mode: .document, camera: .init(),
        viewport: .init(x: 834, y: 1194), focusedItemID: item.id, openProgress: 1,
        documentPageIndex: 0, selectedItemID: item.id))
      return item.id
    }.value
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: pageSize)
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved)
    let document = try XCTUnwrap(model.documents[documentID]), state = try XCTUnwrap(model.documentStates[documentID])
    return try Fixture(model: model, document: document, state: state)
  }

  @MainActor private final class Fixture {
    let model: NotebookAppModel
    let coordinator: DocumentWebCoordinator
    let host = DocumentWebHost()
    let window: UIWindow
    private let previousKeyWindow: UIWindow?
    private var received: DocumentLinkActivation?

    init(model: NotebookAppModel, document: DocumentDocument, state: DocumentStateJournal) throws {
      self.model = model
      coordinator = DocumentWebCoordinator(resources: SceneRenderResources(), onRenderReady: .init { _ in },
        onPageLayout: { _ in }, onSourceChange: { _ in .committed }, onStateChange: { _, _ in nil })
      let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
      previousKeyWindow = scene.windows.first { $0.isKeyWindow }
      window = UIWindow(windowScene: scene)
      let controller = UIViewController(), geometry = WorkspaceItemGeometry.document(document.paperSize)
      window.rootViewController = controller
      host.frame = .init(x: 0, y: 0, width: geometry.width, height: geometry.height)
      controller.view.addSubview(host); window.makeKeyAndVisible()
      coordinator.externallyHostedPrograms = true
      coordinator.update(document: document, state: state, selectedPageIndex: 0, capturesSnapshot: false,
        onRenderReady: .init { _ in }, onPageLayout: { _ in }, onSourceChange: { _ in .committed },
        onStateChange: { _, _ in nil }, onLinkActivation: { [weak self] in self?.received = $0 })
      coordinator.mount(in: host, physicalSize: .init(width: geometry.width, height: geometry.height),
        isInteractive: true, priority: .currentPage)
    }

    func activation() async throws -> DocumentLinkActivation {
      let deadline = ContinuousClock.now + .seconds(8)
      while !coordinator.nativeInputIsReady(in: host), coordinator.acquisitionError == nil, .now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      if let error = coordinator.acquisitionError { throw error }
      XCTAssertTrue(coordinator.nativeInputIsReady(in: host))
      let web = try XCTUnwrap(coordinator.webView)
      _ = try await web.evaluateJavaScript("document.querySelector('a[href]').click(); true")
      while received == nil, .now < deadline { try await Task.sleep(for: .milliseconds(5)) }
      return try XCTUnwrap(received)
    }

    func close() {
      coordinator.invalidate(); window.isHidden = true; window.rootViewController = nil
      previousKeyWindow?.makeKey()
    }
  }
}

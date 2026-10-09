import NotebookCore
import UIKit
import XCTest
@testable import Notebook

@MainActor
final class DocumentLinkActivationTests: XCTestCase {
  func testNativeExternalGrantIsCurrentOneShotAndKeepsItsDestinationAfterStateCommit() async throws {
    let fixture = try await fixture(external: true)
    defer { fixture.close() }
    let grant = try await fixture.activation(), origin = grant.origin, copy = grant
    let destination = DocumentLinkDestination.external(try XCTUnwrap(URL(string: "https://example.com/captured")))
    XCTAssertFalse(DocumentLinkActivation(origin: origin, destination: destination).consumeExternalAuthority())
    fixture.setInteractive(false)
    let program = try DocumentProgramSource(document: XCTUnwrap(fixture.model.documents[origin.documentID]), instanceID: "widget", path: "programs/widget")
    let saved = try await fixture.model.commitDocumentState(documentID: origin.documentID,
      program: program, value: .string("accepted before external navigation"))
    XCTAssertNotNil(saved)
    XCTAssertEqual(grant.destination, destination)
    XCTAssertEqual(fixture.model.activateDocumentLink(grant), destination)
    XCTAssertNil(fixture.model.activateDocumentLink(copy), "Copied activation values share one external consume")
    XCTAssertFalse(DocumentLinkActivation(origin: origin,
      destination: .external(URL(string: "https://example.com/swapped")!)).consumeExternalAuthority())
    let expired = DocumentLinkActivation.admitted(origin: origin, destination: destination,
      admittedAt: .now.advanced(by: .seconds(-11)), isCurrent: { true })
    XCTAssertFalse(expired.consumeExternalAuthority())
    fixture.setInteractive(true)
    let retired = try await fixture.activation()
    fixture.retire()
    XCTAssertFalse(retired.consumeExternalAuthority(), "A current model cannot revive a retired physical authority")
  }

  func testAnActuallyAdmittedNativeActivationRoutesAfterInputPolicyChanges() async throws {
    let fixture = try await fixture()
    defer { fixture.close() }
    let activation = try await fixture.activation()
    guard case .page(let target) = activation.destination else { return XCTFail("The real measured anchor must resolve to a page") }
    XCTAssertGreaterThan(target, 1)
    XCTAssertEqual(activation.origin.pageIndex, 0)
    fixture.setInteractive(false)
    XCTAssertFalse(fixture.nativeInputIsReady)
    // Native accessibility activation was admitted before the policy change;
    // model delivery still owns its accepted terminal outcome.
    XCTAssertEqual(fixture.model.activateDocumentLink(activation), .page(target))
    XCTAssertEqual(fixture.model.presence?.documentPageIndex, 0)
    XCTAssertEqual(fixture.model.documentNavigation.request?.pageIndex, target)
    let request = try XCTUnwrap(fixture.model.documentNavigation.request)
    let controller = UUID(), source = DocumentPageNavigation.sourceRevision(try XCTUnwrap(fixture.model.documents[activation.origin.documentID]))
    fixture.model.bindDocumentPageController(controller, documentID: activation.origin.documentID, source: source)
    XCTAssertTrue(fixture.model.acceptDocumentPageLanding(.init(controllerID: controller,
      documentID: activation.origin.documentID, sourceRevision: source, revision: 1, pageIndex: target, requestID: request.id)))
    XCTAssertNil(fixture.model.activateDocumentLink(activation), "Only a reached different page retires the old model origin")
  }

  func testStateCommitBeforeNavigationKeepsTheUserChangeAndTheCurrentDestination() async throws {
    let fixture = try await fixture()
    defer { fixture.close() }
    let activation = try await fixture.activation()
    let program = try DocumentProgramSource(document: XCTUnwrap(fixture.model.documents[activation.origin.documentID]), instanceID: "widget", path: "programs/widget")
    let changed = try await fixture.model.commitDocumentState(documentID: activation.origin.documentID,
      program: program, value: .string("later user state"))
    XCTAssertNotNil(changed)
    XCTAssertEqual(fixture.model.activateDocumentLink(activation), activation.destination)
    if case .page(let target) = activation.destination {
      XCTAssertEqual(fixture.model.documentNavigation.request?.pageIndex, target)
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
    let block = try XCTUnwrap(document.files.first { $0.id == "far" })
    let edit = DocumentSourceEdit(sessionID: UUID(), documentID: document.id, fileID: block.id,
      baseSource: block.source, baseVersion: document.fileVersion(fileID: block.id),
      source: "\\section{A changed destination}\\hypertarget{a-changed-destination}{}", sequence: 1)
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

  func testNativePaperContactKeepsItsAdmissionThroughPolicyChangesAndRejectsCancelledDelivery() async throws {
    let fixture = try await fixture(external: true)
    defer { fixture.close() }
    try await fixture.ready()
    fixture.window.layoutIfNeeded()
    let button = try fixture.link()
    let touch = PaperLinkTouch(button: button, window: fixture.window)
    // The installed control's public tracking callbacks own physical contact
    // admission. No fabricated UIEvent is sent through UIKit's dispatcher.
    fixture.setInteractive(false)
    XCTAssertTrue(button.beginTracking(touch, with: nil))
    fixture.setInteractive(true)
    button.endTracking(touch, with: nil)
    XCTAssertTrue(fixture.received.isEmpty, "A refused down cannot be admitted again at its terminal action")
    button.cancelTracking(with: nil)

    XCTAssertTrue(button.beginTracking(touch, with: nil))
    fixture.setInteractive(false)
    button.endTracking(touch, with: nil)
    XCTAssertEqual(fixture.received.count, 1)
    let accepted = try XCTUnwrap(fixture.received.last)
    XCTAssertTrue(accepted.consumeExternalAuthority(), "Closing new input keeps the accepted contact's physical installation")
    button.endTracking(touch, with: nil)
    XCTAssertEqual(fixture.received.count, 1, "One contact has one terminal outcome")
    button.cancelTracking(with: nil)

    fixture.setInteractive(true)
    XCTAssertTrue(button.beginTracking(touch, with: nil))
    button.cancelTracking(with: nil)
    button.endTracking(touch, with: nil)
    XCTAssertTrue(button.beginTracking(touch, with: nil))
    try XCTUnwrap(button as? NotebookSceneFingerInputOwner).cancelTransferredFingerInput()
    button.endTracking(touch, with: nil)
    XCTAssertEqual(fixture.received.count, 1, "Cancel and scene transfer revoke the contact")

    button.sendActions(for: .primaryActionTriggered)
    XCTAssertTrue(button.accessibilityActivate())
    XCTAssertEqual(fixture.received.count, 3, "Keyboard and accessibility each admit their own native action")
    fixture.setInteractive(false)
    button.sendActions(for: .primaryActionTriggered)
    XCTAssertFalse(button.accessibilityActivate())
    XCTAssertEqual(fixture.received.count, 3)
  }

  func testNativeExternalPaperGrantRetiresWithItsPhysicalEntryAcrossReturn() async throws {
    let fixture = try await fixture(external: true)
    defer { fixture.close() }
    let original = try await fixture.activation(), paper = try XCTUnwrap(fixture.paper)
    let expected = DocumentLinkDestination.external(try XCTUnwrap(URL(string: "https://example.com/captured")))
    XCTAssertEqual(original.destination, expected)
    fixture.retire()
    await fixture.owner.observePendingPresentationWork()
    fixture.restore()
    let returned = try await fixture.activation()
    XCTAssertTrue(fixture.paper === paper)
    XCTAssertTrue(original.origin.hasSamePresentation(as: returned.origin), "The regression must reuse the exact coordinator, source and pixels")
    // First consume is deliberately after return: an earlier consume would
    // hide revived authority behind the one-shot's already-consumed state.
    XCTAssertFalse(original.consumeExternalAuthority())
    XCTAssertEqual(fixture.model.activateDocumentLink(returned), expected)
    XCTAssertNil(fixture.model.activateDocumentLink(returned))
    XCTAssertNil(fixture.model.activateDocumentLink(.init(origin: returned.origin, destination: expected)))
  }

  private func fixture(external: Bool = false) async throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("document-activation-" + UUID().uuidString)
    let store = NotebookStore(root: root), actor = UUID(), pageSize = NotebookAppModel.defaultPageSize
    let documentID = try await Task.detached {
      _ = try store.initializeWorkspace(actor: actor, pageSize: pageSize)
      var index = try store.loadIndex(), board = try store.loadBoard(items: index.items)
      let item = try XCTUnwrap(index.createDocument(title: "Link owner", actor: actor))
      XCTAssertTrue(board.addItem(item.id, to: index.rootBoardID, near: .zero, actor: actor))
      let document = DocumentTestFiles.document(id: item.id, actor: actor, contents: [
        .tex(id: "contents", source: external ? "\\href{https://example.com/captured}{Outside}" : "\\hyperlink{far}{Far chapter}"),
        .tex(id: "body", source: String(repeating: "A physical canonical paragraph preserves its navigation origin.\n\n", count: 140)),
        .tex(id: "far", source: "\\section{Far}\\hypertarget{far}{}\n\nThe actual measured destination."),
        .program(id: "widget", html: "<output>A real stateful block</output>")])
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
    let resources = SceneRenderResources()
    let coordinator = DocumentPhysicalPageCoordinator()
    let owner: DocumentPagePresentationOwner
    let lifetime: DocumentPagePresentationOwner.OpenDocument
    let host = DocumentPageHost()
    let window: UIWindow
    let document: DocumentDocument
    private let state: DocumentStateJournal
    private let activity = PageTurnActivity()
    private var readiness: PageTurnReadiness?
    private var interactive = true
    private var acquisitionError: Error?
    private let previousKeyWindow: UIWindow?
    private(set) var received: [DocumentLinkActivation] = []
    var paper: DocumentPaperView? { views(host).compactMap { $0 as? DocumentPaperView }.first }
    var nativeInputIsReady: Bool {
      guard let paper else { return false }
      return host.hasCanonicalPaper(paper)
        && views(host).compactMap { $0 as? DocumentPaperInteractionView }.first?.admitsInput == true
    }

    init(model: NotebookAppModel, document: DocumentDocument, state: DocumentStateJournal) throws {
      self.model = model; self.document = document; self.state = state
      owner = DocumentPagePresentationOwner.shared(documentID: document.id, resources: resources)
      lifetime = owner.retainOpenDocument()
      let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
      previousKeyWindow = scene.windows.first { $0.isKeyWindow }
      window = UIWindow(windowScene: scene)
      let controller = UIViewController(), geometry = WorkspaceItemGeometry.uncompiledDocument
      window.rootViewController = controller
      host.frame = .init(x: 0, y: 0, width: geometry.width, height: geometry.height)
      controller.view.addSubview(host); window.makeKeyAndVisible()
      refresh()
    }

    private func refresh() {
      let readiness = PageTurnReadiness(activity: activity, pageIndex: 0) { _ in }
      self.readiness = readiness
      coordinator.update(.init(document: document, state: state, pageIndex: 0,
        isCurrent: true, isVisible: true, isInteractive: interactive, pageTurnActive: false,
        onRenderReady: readiness, onPageLayout: { _ in }, onStateChange: { _, _ in nil },
        onLinkActivation: { [weak self] in self?.received.append($0) }, snapshotPixelWidth: nil,
        onPreparationFailure: { [weak self] in self?.acquisitionError = $0 }, programStore: model.store),
        in: host, resources: resources)
    }
    func setInteractive(_ value: Bool) { interactive = value; refresh() }
    func retire() { lifetime.parkForReturn(); coordinator.invalidate() }
    func restore() { lifetime.resume(); refresh() }
    func link() throws -> UIButton {
      try XCTUnwrap(views(host).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "document-link" })
    }
    private func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
    func ready() async throws {
      let deadline = ContinuousClock.now + .seconds(8)
      while !nativeInputIsReady, acquisitionError == nil, .now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      if let acquisitionError { throw acquisitionError }
      XCTAssertTrue(nativeInputIsReady)
    }
    func activation() async throws -> DocumentLinkActivation {
      try await ready()
      let before = received.count
      XCTAssertTrue(try link().accessibilityActivate())
      XCTAssertEqual(received.count, before + 1)
      return try XCTUnwrap(received.last)
    }

    func close() {
      coordinator.invalidate(); lifetime.close(); window.isHidden = true; window.rootViewController = nil
      previousKeyWindow?.makeKey()
    }
  }
}

@MainActor private final class PaperLinkTouch: UITouch {
  private let button: UIButton
  private let sourceWindow: UIWindow
  init(button: UIButton, window: UIWindow) { self.button = button; sourceWindow = window; super.init() }
  override var view: UIView? { button }
  override var window: UIWindow? { sourceWindow }
  override var type: UITouch.TouchType { .direct }
  override func location(in view: UIView?) -> CGPoint {
    button.convert(.init(x: button.bounds.midX, y: button.bounds.midY), to: view)
  }
}

import NotebookCore
import SwiftUI
import UIKit
import WebKit
import XCTest

@testable import Notebook

final class PreparedAgentElementViewTests: XCTestCase {
  @MainActor
  func testCachedStaticSourceReportsReadyWithoutMountingWebKit() async throws {
    let fixture = makeModel()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = element(id: UUID().uuidString, source: "cached")
    XCTAssertTrue(SceneRenderResources.shared.store(raster(), for: source))
    var ready = false
    let host = try SurfaceHost(content: AnyView(
      PreparedAgentElementView(element: source, allowsInteraction: true,
        focus: .board(boardID: UUID(), elementID: source.id),
        onRenderReady: { ready = $0 }, onState: { _ in XCTFail("Static content cannot commit state") })
        .frame(width: 160, height: 120).environment(fixture.model)))
    defer { host.close() }
    try await waitUntil("Cached raster must confirm its first mounted frame") { ready }
    XCTAssertTrue(webViews(in: host.controller.view).isEmpty)
  }

  @MainActor
  func testStaticSourceEditPreparesItsReplacementInsteadOfKeepingTheOldRaster() async throws {
    let fixture = makeModel()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let id = UUID().uuidString
    let first = element(id: id, source: "first")
    let second = element(id: id, source: "second")
    XCTAssertTrue(SceneRenderResources.shared.store(raster(), for: first))
    XCTAssertNil(SceneRenderResources.shared.image(for: second))
    var readiness: [String: Bool] = [:]
    func content(_ source: AgentElement) -> AnyView {
      AnyView(PreparedAgentElementView(element: source, allowsInteraction: true,
        focus: .board(boardID: WorkspaceRoot.boardID, elementID: source.id),
        onRenderReady: { readiness[source.source] = $0 }, onState: { _ in })
        .frame(width: 160, height: 120).environment(fixture.model))
    }
    let host = try SurfaceHost(content: content(first))
    defer { host.close() }
    try await waitUntil("First source ready") { readiness[first.source] == true }
    host.controller.rootView = content(second)
    try await waitUntil("Changed source must acquire its own completed raster") {
      readiness[second.source] == true && SceneRenderResources.shared.image(for: second) != nil
        && self.webViews(in: host.controller.view).isEmpty
    }
    XCTAssertNotNil(SceneRenderResources.shared.image(for: second))
  }

  @MainActor
  func testChangingFocusKeepsOnlyOneLiveInteractiveOwnerAndStopsPreviousCommits() async throws {
    let fixture = makeModel()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let boardID = UUID()
    let first = element(id: UUID().uuidString, source: "first", interactive: true)
    let second = element(id: UUID().uuidString, source: "second", interactive: true)
    for source in [first, second] { XCTAssertTrue(SceneRenderResources.shared.store(raster(), for: source)) }
    var commits: [String: Int] = [:]
    var ticks: [String: [Int]] = [:]
    let host = try SurfaceHost(content: AnyView(HStack {
      ForEach([first, second]) { source in
        PreparedAgentElementView(element: source, allowsInteraction: true,
          focus: .board(boardID: boardID, elementID: source.id), onRenderReady: { _ in },
          onState: { value in
            commits[source.id, default: 0] += 1
            if case .object(let fields) = value, case .number(let tick) = fields["tick"] {
              ticks[source.id, default: []].append(Int(tick))
            }
          })
          .frame(width: 160, height: 120)
      }
    }.environment(fixture.model)))
    defer { host.close() }
    fixture.model.interactiveElementFocus = .board(boardID: boardID, elementID: first.id)
    try await waitUntil("First interactive owner mounted") {
      self.webViews(in: host.controller.view).count == 1 && commits[first.id, default: 0] > 0
    }
    fixture.model.interactiveElementFocus = .board(boardID: boardID, elementID: second.id)
    try await waitUntil("Focus transfers to one live owner") {
      self.webViews(in: host.controller.view).count == 1 && commits[second.id, default: 0] > 0
    }
    let firstCommitCount = commits[first.id, default: 0]
    let secondCommitCount = commits[second.id, default: 0]
    try await waitUntil("Current owner's timer remains live") { commits[second.id, default: 0] > secondCommitCount }
    XCTAssertEqual(commits[first.id, default: 0], firstCommitCount,
      "A timer from the previous owner must not write after focus changes.")
    for values in ticks.values {
      XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy { pair in pair.0 < pair.1 },
        "The same runtime's timer advances; a reload must not reset its local counter")
    }
    let web = try XCTUnwrap(webViews(in: host.controller.view).first)
    let owner = try await web.evaluateJavaScript("document.body.dataset.owner") as? String
    XCTAssertEqual(owner, second.id)
  }

  @MainActor
  func testPreparationFailureUnmountsHiddenWebKitWithoutAutomaticRetryStorm() async throws {
    let fixture = makeModel()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let id = UUID().uuidString
    let source = AgentElement(id: id, kind: .web,
      frame: .init(x: 0, y: 0, width: 160, height: 120), source: "native readiness failure",
      html: "<p>Visible source</p>", javaScript: """
        Object.defineProperty(document, 'fonts', {
          get() { throw new Error('Expected test preparation failure'); }
        });
        """)
    var ready = false
    let host = try SurfaceHost(content: AnyView(
      PreparedAgentElementView(element: source, allowsInteraction: false,
        focus: .board(boardID: UUID(), elementID: id), onRenderReady: { ready = $0 }, onState: { _ in })
        .frame(width: 160, height: 120).environment(fixture.model)))
    defer { host.close() }
    try await waitUntil("A failed snapshot must finish its lease, not remain hidden indefinitely") {
      SceneRenderResources.shared.diagnostics(for: [source]).contains { $0.kind == "render_error" }
        && self.webViews(in: host.controller.view).isEmpty
    }
    let generation = SceneRenderResources.shared.webAdmissionGeneration
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(SceneRenderResources.shared.webAdmissionGeneration, generation,
      "Releasing the failed view is not a reason to immediately retry the same failed source.")
    XCTAssertTrue(webViews(in: host.controller.view).isEmpty)
    XCTAssertFalse(ready)
  }

  @MainActor
  func testPassivePageWithMatchingFocusDoesNotExecuteInteractiveContent() async throws {
    let fixture = makeModel()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    fixture.model.start(pageSize: NotebookAppModel.defaultPageSize)
    let source = element(id: UUID().uuidString, source: "passive", interactive: true)
    var page = try XCTUnwrap(fixture.model.activePage)
    page.replaceElements([source], actor: fixture.model.actorID)
    try fixture.model.store.savePage(page)
    fixture.model.reloadExternalChanges()
    await fixture.model.finishPendingPersistence()
    page = try XCTUnwrap(fixture.model.pages[page.id])
    XCTAssertEqual(page.elements, [source])
    let originalStamp = page.agentStamp
    XCTAssertTrue(SceneRenderResources.shared.store(raster(), for: source))
    fixture.model.interactiveElementFocus = .page(pageID: page.id, elementID: source.id)
    var ready = false
    let host = try SurfaceHost(content: AnyView(PageSurface(page: page, isInteractive: false,
      isVisible: true, onRenderReady: .init { ready = $0 })
      .environment(fixture.model)))
    defer { host.close() }
    try await waitUntil("A passive page renders its cached overlay") { ready }
    XCTAssertTrue(webViews(in: host.controller.view).isEmpty,
      "Page thumbnails and neighboring sheets do not activate the focused element.")
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(fixture.model.pages[page.id]?.agentStamp, originalStamp)
    XCTAssertEqual(fixture.model.pages[page.id]?.elements, [source])
    await fixture.model.finishPendingPersistence()
  }

  @MainActor
  private func makeModel() -> (root: URL, model: NotebookAppModel) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return (root, NotebookAppModel(store: .init(root: root), startsNearbySync: false))
  }

  private func element(id: String, source: String, interactive: Bool = false) -> AgentElement {
    AgentElement(id: id, kind: .web, frame: .init(x: 0, y: 0, width: 160, height: 120), source: source,
      html: "<div style='width:100%;height:100%;background:#67aade'>\(source)</div>",
      javaScript: interactive ? """
        document.body.dataset.owner = '\(id)';
        let tick = 0;
        window.notebook.commit({owner: '\(id)', tick});
        setInterval(() => window.notebook.commit({owner: '\(id)', tick: ++tick}), 30);
        """ : "")
  }

  @MainActor
  private func raster() -> UIImage {
    let format = UIGraphicsImageRendererFormat(); format.scale = 2
    return UIGraphicsImageRenderer(size: CGSize(width: 160, height: 120), format: format).image { context in
      UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
    }
  }

  @MainActor
  private func webViews(in view: UIView) -> [WKWebView] {
    (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap { webViews(in: $0) }
  }

  @MainActor
  private func waitUntil(_ message: String, timeout: Duration = .seconds(8),
    condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    guard condition() else {
      XCTFail(message)
      throw NSError(domain: "PreparedAgentElementViewTests", code: 1,
        userInfo: [NSLocalizedDescriptionKey: message])
    }
  }
}

@MainActor
private final class SurfaceHost {
  let window: UIWindow
  let controller: UIHostingController<AnyView>

  init(content: AnyView) throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    window = UIWindow(windowScene: scene)
    controller = UIHostingController(rootView: content)
    window.rootViewController = controller
    window.makeKeyAndVisible()
  }

  func close() {
    controller.rootView = AnyView(EmptyView())
    window.isHidden = true
    window.rootViewController = nil
  }
}

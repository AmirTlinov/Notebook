#if os(iOS)
import NotebookCore
import UIKit
import XCTest
@testable import Notebook

@MainActor
final class DocumentPresentationWaitTests: XCTestCase {
  func testNativeCanonicalInstallationCompletesTheExactRequest() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    let token = try XCTUnwrap(fixture.renderer.payload?.renderToken)
    let request = Task { @MainActor in try await fixture.renderer.awaitPresentation(token: token) }
    defer { request.cancel() }
    try await subscribed(fixture.renderer)
    fixture.blocker.release()
    try await request.value
    XCTAssertTrue(fixture.renderer.hasCanonicalPixels)
    XCTAssertTrue(fixture.host.hasCanonicalPaper(fixture.renderer.view))
    XCTAssertEqual(fixture.renderer.payload?.renderToken, token)
    XCTAssertEqual(fixture.renderer.pendingPresentationRequestCount, 0)
    XCTAssertEqual(fixture.resources.activeWebSurfaceCount, 0)
  }

  func testSourceReplacementCancelsOnlyTheOldVersion() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    let token = try XCTUnwrap(fixture.renderer.payload?.renderToken)
    let request = Task { @MainActor in try await fixture.renderer.awaitPresentation(token: token) }
    defer { request.cancel() }
    try await subscribed(fixture.renderer)
    var document = fixture.document
    XCTAssertTrue(document.replaceFileSource(id: "body", source: "Replacement source", actor: UUID()))
    fixture.update(document)
    do { try await request.value; XCTFail("A superseded reader completed") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(fixture.renderer.pendingPresentationRequestCount, 0)
    XCTAssertNotEqual(fixture.renderer.payload?.renderToken, token)
  }

  func testCancellingOneReaderPreservesAnotherReadersPreparation() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    let token = try XCTUnwrap(fixture.renderer.payload?.renderToken)
    let first = Task { @MainActor in try await fixture.renderer.awaitPresentation(token: token) }
    let second = Task { @MainActor in try await fixture.renderer.awaitPresentation(token: token) }
    defer { first.cancel(); second.cancel() }
    try await subscribed(fixture.renderer, count: 2)
    first.cancel()
    do { try await first.value; XCTFail("A cancelled reader completed") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(fixture.renderer.pendingPresentationRequestCount, 1)
    fixture.blocker.release()
    try await second.value
    XCTAssertTrue(fixture.renderer.hasCanonicalPixels)
    XCTAssertEqual(fixture.renderer.pendingPresentationRequestCount, 0)
  }

  private func subscribed(_ renderer: DocumentPaperCoordinator, count: Int = 1) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while renderer.pendingPresentationRequestCount != count, .now < deadline { await Task.yield() }
    XCTAssertEqual(renderer.pendingPresentationRequestCount, count)
    if renderer.pendingPresentationRequestCount != count { throw CancellationError() }
  }

  @MainActor private final class Fixture {
    let resources = SceneRenderResources(profile: .interactive)
    let document = DocumentTestFiles.document(contents: [.tex(id: "body", source: "The exact native print cut.")])
    let renderer: DocumentPaperCoordinator
    let blocker: RasterReservation
    let host = DocumentPageHost()
    let window: UIWindow
    init() throws {
      blocker = try XCTUnwrap(resources.reserveDerivedBytes(resources.passiveByteLimit - 1, priority: .passive))
      renderer = .init(resources: resources, renderSession: .init(documentID: document.id))
      let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
      window = UIWindow(windowScene: scene)
      let controller = UIViewController(); controller.view = host
      window.rootViewController = controller; window.makeKeyAndVisible()
      update(document)
      let size = WorkspaceItemGeometry.uncompiledDocument
      renderer.mount(in: host, physicalSize: .init(width: size.width, height: size.height), isInteractive: true, priority: .currentPage)
    }
    func update(_ document: DocumentDocument) {
      renderer.update(document: document, state: .init(id: document.id, actor: UUID()), selectedPageIndex: 0,
        onPageLayout: { _ in }, onPreparationFailure: { _ in }, onLinkActivation: { _ in }, preparationRequestID: nil)
    }
    func close() { blocker.release(); renderer.invalidate(); window.isHidden = true; window.rootViewController = nil }
  }
}
#endif

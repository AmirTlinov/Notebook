import Foundation
import NotebookCore
import WebKit
import XCTest
#if os(iOS)
import UIKit
#else
import AppKit
#endif
@testable import Notebook

@MainActor
final class DocumentPresentationWaitTests: XCTestCase {
  func testUnconfirmedAdmittedSurfaceKeepsTheCoordinatorsExecutionDeadline() async throws {
    let (renderer, _) = makeRenderer()
    defer { renderer.invalidate() }
    // A native surface exists, but there is no canonical receipt. A legacy
    // render-ready flag must not leave the event subscription without an end.
    let web = WKWebView(), host = DocumentWebHost()
    let token = try XCTUnwrap(renderer.payload?.renderToken)
    let finished = expectation(description: "coordinator execution deadline")
    let task = Task { @MainActor in
      do { try await renderer.awaitPresentation(token: token); XCTFail("Unconfirmed surface became ready") }
      catch { XCTAssertEqual(error as? SceneRenderError, .snapshotPending("document_preparation_timeout")) }
      finished.fulfill()
    }
    defer { task.cancel() }
    try await subscribed(renderer)
    renderer.webView = web; renderer.renderIsReady = true
    renderer.mount(in: host, physicalSize: .init(width: 400, height: 566), isInteractive: false, priority: .currentPage)
    await fulfillment(of: [finished], timeout: 10)
    XCTAssertEqual(renderer.pendingPresentationRequestCount, 0)
  }

  func testNativeCanonicalReceiptCompletesTheExactRequest() async throws {
    let (renderer, document) = makeRenderer()
    let host = DocumentWebHost(), geometry = WorkspaceItemGeometry.document(document.paperSize)
    #if os(iOS)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene), controller = UIViewController()
    window.rootViewController = controller; controller.view.addSubview(host)
    host.frame = .init(x: 0, y: 0, width: 400, height: 566)
    window.makeKeyAndVisible()
    defer { renderer.invalidate(); window.isHidden = true; window.rootViewController = nil }
    #else
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 566),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = host; window.makeKeyAndOrderFront(nil)
    defer { renderer.invalidate(); window.orderOut(nil); window.contentView = nil }
    #endif
    let finished = expectation(description: "canonical request")
    let token = try XCTUnwrap(renderer.payload?.renderToken)
    let task = Task { @MainActor in
      do { try await renderer.awaitPresentation(token: token) }
      catch { XCTFail("Canonical request failed: \(error)") }
      finished.fulfill()
    }
    defer { task.cancel() }
    try await subscribed(renderer)
    renderer.mount(in: host, physicalSize: .init(width: geometry.width, height: geometry.height),
      isInteractive: false, priority: .currentPage)
    await fulfillment(of: [finished], timeout: 10)
    XCTAssertTrue(renderer.hasCanonicalPixels)
    XCTAssertEqual(renderer.payload?.renderToken, token)
    XCTAssertEqual(renderer.pendingPresentationRequestCount, 0)
  }

  func testSourceReplacementCancelsTheOldVersionRatherThanWaitingForTheNewOne() async throws {
    let (renderer, document) = makeRenderer()
    defer { renderer.invalidate() }
    let finished = expectation(description: "superseded request")
    let token = try XCTUnwrap(renderer.payload?.renderToken)
    let task = Task { @MainActor in
      do { try await renderer.awaitPresentation(token: token); XCTFail("Superseded request became ready") }
      catch { XCTAssertTrue(error is CancellationError) }
      finished.fulfill()
    }
    defer { task.cancel() }
    try await subscribed(renderer)
    var changed = document
    XCTAssertTrue(changed.replaceBlockSource(id: "body", source: "# Replaced source", actor: UUID()))
    update(renderer, document: changed)
    await fulfillment(of: [finished], timeout: 1)
    XCTAssertEqual(renderer.pendingPresentationRequestCount, 0)
    XCTAssertNotEqual(renderer.payload?.renderToken, token)
  }

  func testCancellingOneReaderDoesNotCancelAnotherReadersRequest() async throws {
    let (renderer, _) = makeRenderer()
    defer { renderer.invalidate() }
    let token = try XCTUnwrap(renderer.payload?.renderToken)
    let finished = expectation(description: "cancelled reader")
    let first = Task { @MainActor in
      do { try await renderer.awaitPresentation(token: token); XCTFail("Cancelled reader became ready") }
      catch { XCTAssertTrue(error is CancellationError) }
      finished.fulfill()
    }
    let second = Task { @MainActor in try await renderer.awaitPresentation(token: token) }
    defer { first.cancel(); second.cancel() }
    try await subscribed(renderer, count: 2)
    first.cancel()
    await fulfillment(of: [finished], timeout: 1)
    XCTAssertEqual(renderer.pendingPresentationRequestCount, 1)
    renderer.invalidate()
    if case .success = await second.result { XCTFail("Closed request became ready") }
    XCTAssertEqual(renderer.pendingPresentationRequestCount, 0)
  }

  func testNativeFailureCompletesTheWaitWithItsDefinedError() async throws {
    let (renderer, _) = makeRenderer()
    defer { renderer.invalidate() }
    let web = WKWebView()
    renderer.webView = web
    let failure = NSError(domain: "DocumentPresentationWaitTests", code: 37)
    let finished = expectation(description: "native failure")
    let token = try XCTUnwrap(renderer.payload?.renderToken)
    let task = Task { @MainActor in
      do { try await renderer.awaitPresentation(token: token); XCTFail("Failed request became ready") }
      catch { XCTAssertEqual(error as NSError, failure) }
      finished.fulfill()
    }
    defer { task.cancel() }
    try await subscribed(renderer)
    renderer.webView(web, didFailProvisionalNavigation: nil, withError: failure)
    await fulfillment(of: [finished], timeout: 1)
    XCTAssertEqual(renderer.pendingPresentationRequestCount, 0)
  }

  private func makeRenderer() -> (DocumentWebCoordinator, DocumentDocument) {
    let renderer = DocumentWebCoordinator(resources: SceneRenderResources(), onRenderReady: .init { _ in },
      onPageLayout: { _ in },  onStateChange: { _, _ in nil })
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: "# Ready from a native receipt")])
    update(renderer, document: document)
    return (renderer, document)
  }

  private func update(_ renderer: DocumentWebCoordinator, document: DocumentDocument) {
    renderer.update(document: document, state: .init(id: document.id, actor: UUID()),
      selectedPageIndex: 0, capturesSnapshot: false, onRenderReady: .init { _ in },
      onPageLayout: { _ in },  onStateChange: { _, _ in nil })
  }

  private func subscribed(_ renderer: DocumentWebCoordinator, count: Int = 1) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while renderer.pendingPresentationRequestCount != count, ContinuousClock.now < deadline { await Task.yield() }
    XCTAssertEqual(renderer.pendingPresentationRequestCount, count)
    if renderer.pendingPresentationRequestCount != count { throw CancellationError() }
  }
}


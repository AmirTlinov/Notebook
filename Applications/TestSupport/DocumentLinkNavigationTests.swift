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
final class DocumentLinkNavigationTests: XCTestCase {
  private func book() -> DocumentDocument {
    DocumentDocument(actor: UUID(), blocks: [
      .markdown(id: "contents", source: "<h1 id='contents'>Contents</h1><a id='dup' href='#%D1%80%D0%B0%D0%B7%D0%B4%D0%B5%D0%BB%3A%CE%B2'>Far section</a>"),
      .markdown(id: "body", source: String(repeating: "Intermediate content occupies physical sheets.\n\n", count: 120)),
      .markdown(id: "far", source: "<h1 id='раздел:β'>Far section</h1><a name='named'></a><p><a href='#contents'>Return</a></p><h2>Generated heading</h2><p id='dup'>Later duplicate</p>"),
      .markdown(id: "duplicate", source: "## Generated heading\n\nThe second automatic address stays distinct.")
    ])
  }

  private func layout(anchors: [[String: Any]]) throws -> DocumentLayoutRecord {
    let geometry = WorkspaceItemGeometry.document(.a4)
    return try DocumentLayoutRecord(receipt: ["sourceKey": "source", "layoutScope": "source", "layoutCanonical": true,
      "pageCount": 4, "width": geometry.width, "height": geometry.height, "regions": [], "anchors": anchors] as NSDictionary,
      sourceKey: "source", blockIDs: [], geometry: geometry)
  }

  func testLinkIndexRejectsInvalidAddressesAndCannotBeReplacedByADifferentSourceLayout() throws {
    let first = try layout(anchors: [["name": "section", "pageIndex": 2]])
    XCTAssertEqual(first.destination(for: "#section"), .page(2))
    XCTAssertEqual(first.destination(for: "#"), .page(0))
    XCTAssertEqual(first.destination(for: "#top"), .page(0))
    for href in ["#absent", "#%ZZ", "javascript:alert(1)", "file:///etc/passwd", "data:text/html,x", "relative.html#section", "https://"] {
      guard case .unavailable = first.destination(for: href) else { return XCTFail("Accepted \(href)") }
    }
    for href in ["https://example.com/book#section", "http://example.com", "mailto:reader@example.com"] {
      XCTAssertEqual(first.destination(for: href), .external(try XCTUnwrap(URL(string: href))))
    }
    XCTAssertFalse(first.matches(try layout(anchors: [["name": "section", "pageIndex": 3]])))
    for anchors: [[String: Any]] in [
      [["name": "", "pageIndex": 0]], [["name": "bad", "pageIndex": true]],
      [["name": "bad", "pageIndex": 1.5]], [["name": "bad", "pageIndex": -1]],
      [["name": "bad", "pageIndex": 4]], [["name": String(repeating: "x", count: 4097), "pageIndex": 0]],
      [["name": "duplicate", "pageIndex": 0], ["name": "duplicate", "pageIndex": 1]]
    ] { XCTAssertThrowsError(try layout(anchors: anchors)) }
  }

  func testSourceMeasurementRetainsEncodedNamedAndGeneratedLinkDestinationsWithoutFullDOM() async throws {
    let surface = try surface(book())
    defer { surface.close() }
    try await ready(surface.coordinator)
    let source = try XCTUnwrap(surface.coordinator.payload?.source), layout = try XCTUnwrap(source.layout)
    let far = try XCTUnwrap(layout.anchorPages["раздел:β"])
    XCTAssertGreaterThan(far, 0)
    XCTAssertEqual(layout.destination(for: "#%D1%80%D0%B0%D0%B7%D0%B4%D0%B5%D0%BB%3A%CE%B2"), .page(far))
    XCTAssertEqual(layout.anchorPages["named"], far)
    XCTAssertNotNil(layout.anchorPages["generated-heading"])
    XCTAssertNotNil(layout.anchorPages["generated-heading-1"])
    XCTAssertEqual(layout.anchorPages["dup"], 0, "Duplicate author IDs keep their first DOM destination")
    let web = try XCTUnwrap(surface.coordinator.webView)
    let value = try await evaluate("return String(document.querySelectorAll('.document-layout-preparation').length);", web)
    XCTAssertEqual(value, "0")
    XCTAssertEqual(source.preparationCount, 1)
  }

  func testOnlyTheCurrentCanonicalFragmentCanRequestNavigation() async throws {
    let surface = try surface(book())
    defer { surface.close() }
    try await ready(surface.coordinator)
    let coordinator = surface.coordinator, web = try XCTUnwrap(coordinator.webView)
    var destinations: [DocumentLinkDestination] = []
    coordinator.onLinkNavigation = { destinations.append($0) }
    let raw = try await evaluate("document.querySelector('#document a[href]').click(); return JSON.stringify(notebookRenderer.presentationReceipt());", web)
    let deadline = ContinuousClock.now + .seconds(1)
    while destinations.isEmpty, .now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertEqual(destinations, [.page(try XCTUnwrap(coordinator.payload?.source.layout?.anchorPages["раздел:β"]))])
    var message = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]); message["kind"] = "link"; message["href"] = "#contents"
    for field in ["sourceKey", "stateKey", "runtimeID", "generation", "renderToken", "pageIndex", "presentationEpoch"] {
      var stale = message; stale[field] = "stale"; coordinator.receive(body: stale, from: web)
    }
    var external = message; external["href"] = "https://example.com"; external["userActivated"] = false
    coordinator.receive(body: external, from: web)
    XCTAssertEqual(destinations.count, 1)
    external["userActivated"] = true; coordinator.receive(body: external, from: web)
    XCTAssertEqual(destinations.last, .external(URL(string: "https://example.com")!))
    let size = WorkspaceItemGeometry.document(.a4)
    coordinator.mount(in: surface.host, physicalSize: .init(width: size.width, height: size.height), isInteractive: false, priority: .neighbor)
    coordinator.receive(body: message, from: web)
    coordinator.invalidate(); coordinator.receive(body: message, from: web)
    XCTAssertEqual(destinations.count, 2, "Neighbors and dismantled hosts do not own human navigation")
  }

  @MainActor private struct Surface {
    let coordinator: DocumentWebCoordinator
    let host: DocumentWebHost
    #if os(iOS)
    let window: UIWindow
    #else
    let window: NSWindow
    #endif
    func close() {
      coordinator.invalidate()
      #if os(iOS)
      window.isHidden = true; window.rootViewController = nil
      #else
      window.orderOut(nil); window.close()
      #endif
    }
  }

  private func surface(_ document: DocumentDocument) throws -> Surface {
    let coordinator = DocumentWebCoordinator(resources: SceneRenderResources(), onRenderReady: .init { _ in },
      onPageLayout: { _ in }, onSourceChange: { _ in .committed }, onStateChange: { _,_ in })
    coordinator.update(document: document, state: .init(id: document.id, actor: UUID()), selectedPageIndex: 0,
      capturesSnapshot: false, onRenderReady: .init { _ in }, onPageLayout: { _ in }, onSourceChange: { _ in .committed }, onStateChange: { _,_ in })
    let host = DocumentWebHost(), size = WorkspaceItemGeometry.document(document.paperSize)
    #if os(iOS)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = NotebookPreparationWindow(windowScene: scene), controller = UIViewController()
    window.frame = .init(x: 0, y: 0, width: size.width, height: size.height)
    controller.view = host; window.rootViewController = controller; window.isHidden = false
    host.frame = window.bounds; host.layoutIfNeeded()
    #else
    let window = NSWindow(contentRect: .init(x: -20_000, y: -20_000, width: size.width, height: size.height), styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
    #endif
    coordinator.mount(in: host, physicalSize: .init(width: size.width, height: size.height), isInteractive: true, priority: .currentPage)
    return .init(coordinator: coordinator, host: host, window: window)
  }

  private func ready(_ coordinator: DocumentWebCoordinator) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !coordinator.renderIsReady, coordinator.acquisitionError == nil, .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    if let error = coordinator.acquisitionError { throw error }
    XCTAssertTrue(coordinator.renderIsReady)
  }

  private func evaluate(_ script: String, _ web: WKWebView) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      web.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
        switch result {
        case .success(let value):
          if let string = value as? String { continuation.resume(returning: string) }
          else { continuation.resume(throwing: DocumentSessionError.invalidLayout) }
        case .failure(let error): continuation.resume(throwing: error)
        }
      }
    }
  }
}

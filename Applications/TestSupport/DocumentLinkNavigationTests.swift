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
      "pageCount": 4, "width": geometry.width, "height": geometry.height, "regions": [], "anchors": anchors, "reading": []] as NSDictionary,
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

  func testPrintedLinksComeFromTheSamePDFAndKeepTheirPhysicalDestinations() async throws {
    let surface = try surface(book())
    defer { surface.close() }
    try await ready(surface.coordinator)
    let source = try XCTUnwrap(surface.coordinator.payload?.source), layout = try XCTUnwrap(source.layout)
    let far = try XCTUnwrap(layout.regions.first { $0.id == "far" }?.pageIndex)
    XCTAssertGreaterThan(far, 0)
    let printed = try await source.printedSource(resources: SceneRenderResources.shared)
    let links = try DocumentPrintNavigation.read(printed.artifact.pdf).links
    XCTAssertTrue(links.contains { $0.page == 0 && layout.destination(for: $0.href) == .page(far) })
    XCTAssertTrue(links.contains { $0.page == far && layout.destination(for: $0.href) == .page(0) })
    XCTAssertEqual(source.measurementCount, 1)
  }

  func testMeasuredReadingAddressKeepsTheSameTextAfterPrecedingSourceInsertion() async throws {
    var document = book()
    let first = try surface(document)
    defer { first.close() }
    try await ready(first.coordinator)
    let oldLayout = try XCTUnwrap(first.coordinator.payload?.source.layout)
    let far = try XCTUnwrap(oldLayout.regions.first { $0.id == "far" })
    let page = far.pageIndex
    let anchor = try XCTUnwrap(oldLayout.reading.anchor(page: page, blockOrder: document.blocks.map(\.id), y: far.frame.y))
    XCTAssertEqual(anchor.blockID, "far")
    XCTAssertFalse(anchor.nodeID.isEmpty)
    let originalBody = try XCTUnwrap(document.blocks.first { $0.id == "body" }).source
    XCTAssertTrue(document.replaceBlockSource(id: "body", source:
      String(repeating: "A new preceding paragraph changes page boundaries.\n\n", count: 80) + originalBody, actor: UUID()))
    let next = try surface(document)
    defer { next.close() }
    try await ready(next.coordinator)
    let layout = try XCTUnwrap(next.coordinator.payload?.source.layout)
    let restoredPage = try XCTUnwrap(layout.reading.page(for: anchor,
      survivingBlockOrder: document.blocks.map(\.id), regions: layout.regions))
    XCTAssertGreaterThan(restoredPage, page)
    XCTAssertTrue(layout.reading.segments.contains { $0.pageIndex == restoredPage && $0.nodeID == anchor.nodeID },
      "The new page contains the actual old text, not the old numeric page")
    let source = try XCTUnwrap(next.coordinator.payload?.source)
    await source.discardIdlePreparation()
    XCTAssertEqual(layout.reading.page(for: anchor, survivingBlockOrder: document.blocks.map(\.id), regions: layout.regions), restoredPage)
  }

  func testOnlyTheCurrentCanonicalFragmentCanRequestNavigation() async throws {
    let surface = try surface(book())
    defer { surface.close() }
    try await ready(surface.coordinator)
    let coordinator = surface.coordinator, web = try XCTUnwrap(coordinator.webView)
    var destinations: [DocumentLinkDestination] = []
    coordinator.onLinkActivation = { destinations.append($0.destination) }
    let raw = try await evaluate("document.querySelector('#document a[href]').click(); return JSON.stringify(notebookRenderer.presentationReceipt());", web)
    let deadline = ContinuousClock.now + .seconds(1)
    while destinations.isEmpty, .now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertEqual(destinations, [.page(try XCTUnwrap(coordinator.payload?.source.layout?.regions.first { $0.id == "far" }?.pageIndex))])
    var message = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]); message["kind"] = "link"; message["href"] = "#contents"; message["activationSequence"] = "2"
    for field in ["sourceKey", "stateKey", "runtimeID", "generation", "renderToken", "pageIndex", "presentationEpoch"] {
      var stale = message; stale[field] = "stale"; coordinator.receive(body: stale, from: web)
    }
    var external = message; external["href"] = "https://example.com"; external["userActivated"] = false
    coordinator.receive(body: external, from: web)
    XCTAssertEqual(destinations.count, 1)
    let size = WorkspaceItemGeometry.document(.a4)
    coordinator.mount(in: surface.host, physicalSize: .init(width: size.width, height: size.height), isInteractive: false, priority: .neighbor)
    coordinator.receive(body: message, from: web)
    coordinator.invalidate(); coordinator.receive(body: message, from: web)
    XCTAssertEqual(destinations.count, 1, "Neighbors and dismantled hosts do not own human navigation")
  }

  @MainActor private struct Surface {
    let coordinator: DocumentWebCoordinator
    let host: DocumentWebHost
    #if os(iOS)
    let window: UIWindow
    let previousKeyWindow: UIWindow?
    #else
    let window: NSWindow
    #endif
    func close() {
      coordinator.invalidate()
      #if os(iOS)
      window.isHidden = true; window.rootViewController = nil
      previousKeyWindow?.makeKey()
      #else
      window.orderOut(nil); window.close()
      #endif
    }
  }

  private func surface(_ document: DocumentDocument) throws -> Surface {
    let coordinator = DocumentWebCoordinator(resources: SceneRenderResources(), onRenderReady: .init { _ in },
      onPageLayout: { _ in },  onStateChange: { _, _ in nil })
    coordinator.update(document: document, state: .init(id: document.id, actor: UUID()), selectedPageIndex: 0,
      capturesSnapshot: false, onRenderReady: .init { _ in }, onPageLayout: { _ in },  onStateChange: { _, _ in nil })
    let host = DocumentWebHost(), size = WorkspaceItemGeometry.document(document.paperSize)
    #if os(iOS)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
    let window = UIWindow(windowScene: scene), controller = UIViewController()
    window.frame = .init(x: 0, y: 0, width: size.width, height: size.height)
    controller.view = host; window.rootViewController = controller; window.makeKeyAndVisible()
    host.frame = window.bounds; host.layoutIfNeeded()
    #else
    let window = NSWindow(contentRect: .init(x: -20_000, y: -20_000, width: size.width, height: size.height), styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
    #endif
    coordinator.mount(in: host, physicalSize: .init(width: size.width, height: size.height), isInteractive: true, priority: .currentPage)
    #if os(iOS)
      return .init(coordinator: coordinator, host: host, window: window, previousKeyWindow: previousKeyWindow)
    #else
      return .init(coordinator: coordinator, host: host, window: window)
    #endif
  }

  private func ready(_ coordinator: DocumentWebCoordinator) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while (!coordinator.renderIsReady || coordinator.payload?.source.layout?.isComplete != true),
      coordinator.acquisitionError == nil, .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    if let error = coordinator.acquisitionError { throw error }
    XCTAssertTrue(coordinator.renderIsReady)
    XCTAssertEqual(coordinator.payload?.source.layout?.isComplete, true)
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

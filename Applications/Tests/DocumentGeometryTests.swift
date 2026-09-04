import NotebookCore
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import Notebook

final class DocumentGeometryTests: XCTestCase {
  @MainActor
  func testWebKitAndCoverShareOnePhysicalRectangleAcrossResizing() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    for paper in DocumentPaperSize.allCases {
      let document = DocumentDocument(id: UUID(), actor: UUID(), paperSize: paper,
        blocks: [.markdown(id: "body", source: "# Пространство мысли\n\nОдин физический лист для текста и формул.")])
      let state = DocumentStateJournal(id: document.id, actor: UUID())
      let geometry = WorkspaceItemGeometry.document(paper)
      // Integral sheet sizes isolate paper geometry from UIKit pixel rounding.
      let baseWidth = paper == .a4 ? 420.0 : 408.0
      let window = UIWindow(windowScene: scene)
      defer { window.isHidden = true }
      let container = UIViewController()
      window.rootViewController = container
      let ready = expectation(description: "Готовый WebKit-лист \(paper)")
      var completed = false
      let host = UIHostingController(rootView: DocumentWebView(
        document: document, state: state, isInteractive: true,
        selectedPageIndex: 0, capturesSnapshot: false,
        onRenderReady: PageTurnReadiness { value in
          if value && !completed { completed = true; ready.fulfill() }
        }, onPageLayout: { _ in }, onSourceChange: { _, _ in }, onStateChange: { _, _ in }
      ).ignoresSafeArea())
      container.addChild(host)
      container.view.addSubview(host.view)
      host.didMove(toParent: container)
      host.view.frame = CGRect(x: 0, y: 0, width: baseWidth, height: baseWidth * geometry.height / geometry.width)
      window.makeKeyAndVisible()
      host.view.layoutIfNeeded()
      await fulfillment(of: [ready], timeout: 8)
      let web = try XCTUnwrap(webView(in: host.view))
      for width in [baseWidth, baseWidth * 1.5, baseWidth] {
        let target = CGSize(width: width, height: width * geometry.height / geometry.width)
        host.view.frame.size = target
        host.view.layoutIfNeeded()
        let deadline = ContinuousClock.now + .seconds(3)
        var bounds: [String: Double] = [:]
        repeat {
          try await Task.sleep(for: .milliseconds(30))
          let value = try await web.evaluateJavaScript("(() => { const s = document.querySelector('.paper-sheet'); const r = s.getBoundingClientRect(); return { left:r.left, top:r.top, width:r.width, height:r.height, radius:parseFloat(getComputedStyle(s).borderTopLeftRadius), viewport:innerWidth, scale:visualViewport.scale }; })()")
          bounds = try XCTUnwrap(value as? [String: Double])
        } while abs((bounds["width"] ?? 0) - target.width) > 0.05 && ContinuousClock.now < deadline
        print("DOCUMENT WEB GEOMETRY", paper, target, host.view.frame, web.frame, bounds)
        XCTAssertEqual(bounds["left"]!, 0, accuracy: 0.05)
        XCTAssertEqual(bounds["top"]!, 0, accuracy: 0.05)
        XCTAssertEqual(bounds["width"]!, target.width, accuracy: 0.05)
        XCTAssertEqual(bounds["height"]!, target.height, accuracy: 0.05)
        XCTAssertEqual(bounds["scale"]!, 1, accuracy: 1e-8)
        XCTAssertEqual(bounds["viewport"]!, width, accuracy: 0.05)
        XCTAssertEqual(bounds["radius"]!, geometry.cornerRadius * width / geometry.width, accuracy: 0.05)
      }
      let configuration = WKSnapshotConfiguration()
      let page = try await web.takeSnapshot(configuration: configuration)
      let proof = XCTAttachment(image: page)
      proof.name = "\(paper.rawValue)-physical-paper"
      proof.lifetime = .keepAlways
      add(proof)
    }
  }

  @MainActor
  private func webView(in view: UIView) -> WKWebView? {
    if let web = view as? WKWebView { return web }
    return view.subviews.lazy.compactMap { self.webView(in: $0) }.first
  }
}

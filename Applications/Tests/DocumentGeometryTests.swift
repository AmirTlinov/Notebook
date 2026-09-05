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
      let document = DocumentDocument(
        id: UUID(), actor: UUID(), paperSize: paper,
        blocks: [
          .markdown(
            id: "body",
            source:
              "# Пространство мысли\n\nОдин физический лист для текста и формул.\n\n## Раздел\n\nТекст раздела.\n\n### Уточнение\n\nТекст уточнения."
          )
        ])
      let state = DocumentStateJournal(id: document.id, actor: UUID())
      let geometry = WorkspaceItemGeometry.document(paper)
      // Fractional sizes exercise the subpixel rounding of a moving camera.
      let baseWidth = paper == .a4 ? 420.0 : 408.0
      let window = UIWindow(windowScene: scene)
      defer { window.isHidden = true }
      let container = UIViewController()
      window.rootViewController = container
      let ready = expectation(description: "Готовый WebKit-лист \(paper)")
      var completed = false
      let host = UIHostingController(
        rootView: DocumentWebView(
          document: document, state: state, isInteractive: true,
          selectedPageIndex: 0, capturesSnapshot: false,
          onRenderReady: PageTurnReadiness { value in
            if value && !completed {
              completed = true
              ready.fulfill()
            }
          }, onPageLayout: { _ in }, onSourceChange: { _, _ in }, onStateChange: { _, _ in }
        ).ignoresSafeArea())
      container.addChild(host)
      container.view.addSubview(host.view)
      host.didMove(toParent: container)
      host.view.frame = CGRect(
        x: 0, y: 0, width: baseWidth, height: baseWidth * geometry.height / geometry.width)
      window.makeKeyAndVisible()
      host.view.layoutIfNeeded()
      await fulfillment(of: [ready], timeout: 8)
      let web = try XCTUnwrap(webView(in: host.view))
      let physicalValue = try await web.evaluateJavaScript(
        """
        (() => {
          const sheet = document.querySelector('.paper-sheet').getBoundingClientRect();
          const scale = sheet.width / \(paper.widthPoints);
          const paragraph = getComputedStyle(document.querySelector('#document p'));
          return {
            body: parseFloat(paragraph.fontSize) / scale,
            leading: parseFloat(paragraph.lineHeight) / scale,
            h1: parseFloat(getComputedStyle(document.querySelector('h1')).fontSize) / scale,
            h2: parseFloat(getComputedStyle(document.querySelector('h2')).fontSize) / scale,
            h3: parseFloat(getComputedStyle(document.querySelector('h3')).fontSize) / scale,
            top: (document.querySelector('h1').getBoundingClientRect().top - sheet.top) / scale,
            left: (document.querySelector('h1').getBoundingClientRect().left - sheet.left) / scale
          };
        })()
        """)
      let physical = try XCTUnwrap(physicalValue as? [String: Double])
      print("DOCUMENT PHYSICAL TYPE", paper, physical)
      XCTAssertEqual(try XCTUnwrap(physical["body"]), 12, accuracy: 0.05)
      XCTAssertEqual(try XCTUnwrap(physical["leading"]), 14.5, accuracy: 0.05)
      XCTAssertEqual(try XCTUnwrap(physical["h1"]), 17.28, accuracy: 0.05)
      XCTAssertEqual(try XCTUnwrap(physical["h2"]), 14.4, accuracy: 0.05)
      XCTAssertEqual(try XCTUnwrap(physical["h3"]), 12, accuracy: 0.05)
      XCTAssertEqual(try XCTUnwrap(physical["top"]), paper.marginPoints, accuracy: 0.1)
      XCTAssertEqual(try XCTUnwrap(physical["left"]), paper.marginPoints, accuracy: 0.1)
      let initialMetrics = try await textMetrics(in: web)
      for width in [baseWidth, baseWidth + 0.15, baseWidth - 0.2, baseWidth * 1.5, baseWidth] {
        let target = CGSize(width: width, height: width * geometry.height / geometry.width)
        host.view.frame.size = target
        host.view.layoutIfNeeded()
        let deadline = ContinuousClock.now + .seconds(3)
        var bounds: [String: Double] = [:]
        repeat {
          try await Task.sleep(for: .milliseconds(30))
          let value = try await web.evaluateJavaScript(
            "(() => { const s = document.querySelector('.paper-sheet'); const r = s.getBoundingClientRect(); return { left:r.left, top:r.top, width:r.width, height:r.height, radius:parseFloat(getComputedStyle(s).borderTopLeftRadius), viewport:innerWidth, scale:visualViewport.scale }; })()"
          )
          bounds = try XCTUnwrap(value as? [String: Double])
        } while abs((bounds["width"] ?? 0) - geometry.width) > 1 && ContinuousClock.now < deadline
        print("DOCUMENT WEB GEOMETRY", paper, target, host.view.frame, web.frame, bounds)
        XCTAssertEqual(bounds["left"]!, 0, accuracy: 0.05)
        XCTAssertEqual(bounds["top"]!, 0, accuracy: 0.05)
        XCTAssertEqual(bounds["width"]!, geometry.width, accuracy: 1)
        XCTAssertEqual(bounds["height"]!, geometry.height, accuracy: 1)
        XCTAssertEqual(bounds["scale"]!, 1, accuracy: 1e-8)
        XCTAssertEqual(bounds["viewport"]!, geometry.width, accuracy: 1)
        XCTAssertEqual(bounds["radius"]!, geometry.cornerRadius, accuracy: 0.05)
        let metrics = try await textMetrics(in: web)
        XCTAssertEqual(
          metrics, initialMetrics, "Масштаб камеры сохраняет размер шрифта и переносы строк WebKit")
        let projected = web.convert(web.bounds, to: host.view)
        XCTAssertEqual(projected.width, target.width, accuracy: 1 / window.screen.scale)
        XCTAssertEqual(projected.height, target.height, accuracy: 1 / window.screen.scale)
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
  func testOneOfflineRenderCompletesMathAndInteractiveStateThenSerializesUpdates() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let document = DocumentDocument(id: UUID(), actor: UUID(), paperSize: .letter, blocks: [
      .latex(id: "formula", source: #"\mathfrak{A} + \sum_{k=1}^{n} k^2"#),
      .interactive(id: "interactive", html: "<p>Готово</p>", css: "",
        javaScript: "notebook.commit({ready:true})", initialState: .null, height: 100),
      .markdown(id: "body", source: (1...40).map {
        "## Раздел \($0)\n\nПоследовательное содержание физического листа."
      }.joined(separator: "\n\n")),
    ])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    let ready = expectation(description: "Один завершённый набор")
    let interactive = expectation(description: "Исполнен исходник интерактивного блока")
    var completed = false
    var committed = false
    let window = UIWindow(windowScene: scene)
    defer { window.isHidden = true }
    let host = UIHostingController(rootView: DocumentWebView(
      document: document, state: state, isInteractive: true, selectedPageIndex: 0,
      capturesSnapshot: false, onRenderReady: PageTurnReadiness { value in
        if value && !completed { completed = true; ready.fulfill() }
      }, onPageLayout: { _ in }, onSourceChange: { _, _ in },
      onStateChange: { id, value in
        if id == "interactive", value == .object(["ready": .bool(true)]), !committed {
          committed = true; interactive.fulfill()
        }
      }).ignoresSafeArea())
    window.rootViewController = host
    window.makeKeyAndVisible()
    await fulfillment(of: [ready, interactive], timeout: 8)
    let web = try XCTUnwrap(webView(in: host.view))
    let result = try await web.evaluateJavaScript("""
      (() => ({
        math: document.querySelectorAll('mjx-container svg').length,
        accessibleMath: document.querySelectorAll('mjx-assistive-mml math').length,
        remoteScripts: [...document.scripts].filter(s => /^https?:/.test(s.src)).length,
        diagnostics: window.notebookRenderer.pageReceipt().diagnostics.length
      }))()
      """)
    let proof = try XCTUnwrap(result as? [String: Int])
    XCTAssertEqual(proof["math"], 1)
    XCTAssertEqual(proof["accessibleMath"], 1)
    XCTAssertEqual(proof["remoteScripts"], 0)
    XCTAssertEqual(proof["diagnostics"], 0)

    let updated: String = try await withCheckedThrowingContinuation { continuation in
      web.callAsyncJavaScript("""
      const renderer = window.notebookRenderer;
      const originalTypeset = MathJax.typesetPromise;
      let release, entered, count = 0;
      const started = new Promise(resolve => { entered = resolve; });
      const gate = new Promise(resolve => { release = resolve; });
      MathJax.typesetPromise = async nodes => {
        count++;
        if (count === 1) { entered(); await gate; }
        else { renderer.setPageIndex(1); }
        return originalTypeset(nodes);
      };
      const makePayload = token => ({
        documentID: documentID, renderToken: token, editable: true, states: {},
        paper: {kind:'letter',widthPoints:612,heightPoints:792,marginPoints:72,cornerRadiusRatio:0.004},
        blocks: [{id:'body',kind:'markdown',source:Array.from({length:40},(_,i)=>
          '# ' + token + ' ' + i + '\\n\\nСодержание конечного листа.').join('\\n\\n')}]
      });
      try {
        const finished = renderer.apply(makePayload('first'));
        await started;
        renderer.apply(makePayload('superseded'));
        renderer.apply(makePayload('latest'));
        release();
        await finished;
        await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
        return JSON.stringify({count, ...renderer.pageReceipt(),
          heading:document.querySelector('h1').textContent,
          offset:new DOMMatrix(getComputedStyle(document.querySelector('#page-track')).transform).m41});
      } finally { MathJax.typesetPromise = originalTypeset; }
      """, arguments: ["documentID": document.id.uuidString], in: nil, in: .page) { result in
        switch result {
        case .success(let value): continuation.resume(returning: value as? String ?? "{}")
        case .failure(let error): continuation.resume(throwing: error)
        }
      }
    }
    let receipt = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(updated.utf8)) as? [String: Any])
    XCTAssertEqual(receipt["count"] as? Int, 2, "Ожидающие правки объединяются до последней")
    XCTAssertEqual(receipt["renderToken"] as? String, "latest")
    XCTAssertEqual(receipt["heading"] as? String, "latest 0")
    XCTAssertEqual(receipt["pageIndex"] as? Int, 1, "Завершение набора сохраняет выбранный лист")
    XCTAssertLessThan(try XCTUnwrap(receipt["offset"] as? Double), -100)
  }

  @MainActor
  private func textMetrics(in web: WKWebView) async throws -> String {
    let value = try await web.evaluateJavaScript(
      """
      (() => {
        const paragraph = document.querySelector('#document p');
        const range = document.createRange();
        range.selectNodeContents(paragraph);
        return JSON.stringify({
          font: getComputedStyle(paragraph).fontSize,
          lines: Array.from(range.getClientRects(), r => [r.x, r.y, r.width, r.height]),
          width: innerWidth, height: innerHeight
        });
      })()
      """)
    return try XCTUnwrap(value as? String)
  }

  @MainActor
  private func webView(in view: UIView) -> WKWebView? {
    if let web = view as? WKWebView { return web }
    return view.subviews.lazy.compactMap { self.webView(in: $0) }.first
  }
}

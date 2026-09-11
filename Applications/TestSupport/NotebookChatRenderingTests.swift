import XCTest
import WebKit
@testable import Notebook

@MainActor
final class NotebookChatRenderingTests: XCTestCase {
  func testOfflineMarkdownMathAndUntrustedTextShareOneDocument() async throws {
    let root = try XCTUnwrap(Bundle.main.url(forResource: "WebResources", withExtension: nil))
    let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
    let web = WKWebView(frame: .init(x: 0, y: 0, width: 350, height: 400), configuration: configuration)
    web.loadFileURL(root.appendingPathComponent("chat-shell.html"), allowingReadAccessTo: root)
    defer { web.stopLoading() }
    let deadline = ContinuousClock.now + .seconds(15)
    var ready = false
    while !ready, .now < deadline {
      ready = (try? await web.evaluateJavaScript("typeof window.showMessages === 'function'")) as? Bool == true
      if !ready { try await Task.sleep(for: .milliseconds(50)) }
    }
    XCTAssertTrue(ready)
    let source = #"**Формула** \(x^2 + y^2 = 1\), $\frac{1}{2}$"# + "\n\n" + #"\[\int_0^1 x\,dx = \frac12\]"#
      + "\n\n<script>window.notebookInjected=true</script><img src='https://example.invalid/leak'>"
    let data = try JSONSerialization.data(withJSONObject: [["role":"assistant","text":source]])
    _ = try await web.callAsyncJavaScript("await window.showMessages(json)", arguments: ["json":String(decoding:data,as:UTF8.self)], in:nil, contentWorld:.page)
    let count = try await web.evaluateJavaScript("document.querySelectorAll('mjx-container').length") as? Int
    XCTAssertEqual(count, 3)
    let unsafe = try await web.evaluateJavaScript("Boolean(window.notebookInjected) || document.querySelectorAll('img,main script').length > 0") as? Bool
    XCTAssertEqual(unsafe, false)
    let errors = try await web.evaluateJavaScript("document.querySelectorAll('[data-mml-node=merror]').length") as? Int
    XCTAssertEqual(errors, 0)
    let update = #"[{"role":"user","text":"Покажи формулу"},{"role":"assistant","text":"Готово: $2+2=4$"}]"#
    _ = try await web.callAsyncJavaScript("await window.showMessages(json)", arguments: ["json":update], in:nil, contentWorld:.page)
    let articles = try await web.evaluateJavaScript("document.querySelectorAll('article').length") as? Int
    XCTAssertEqual(articles, 2, "Updates replace the bounded display, not the canonical conversation")
    let style = try await web.evaluateJavaScript("""
      (() => {
        const user=document.querySelector('article[data-role=user] .content');
        const assistant=document.querySelector('article[data-role=assistant] .content');
        return {font:getComputedStyle(document.body).fontSize,
          userBackground:getComputedStyle(user).backgroundColor,
          userRadius:getComputedStyle(user).borderRadius,
          assistantBackground:getComputedStyle(assistant).backgroundColor,
          labels:[...document.querySelectorAll('.role')].map(x=>x.textContent),
          overflow:document.documentElement.scrollWidth>innerWidth};
      })()
      """) as? [String: Any]
    XCTAssertEqual(style?["font"] as? String, "15px")
    XCTAssertEqual(style?["userBackground"] as? String, "rgb(243, 243, 243)")
    XCTAssertEqual(style?["userRadius"] as? String, "20px")
    XCTAssertEqual(style?["assistantBackground"] as? String, "rgba(0, 0, 0, 0)")
    XCTAssertEqual(style?["labels"] as? [String], ["Вы", "Codex"], "Quiet styling retains accessible speaker names")
    XCTAssertEqual(style?["overflow"] as? Bool, false)
  }
}

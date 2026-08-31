import SwiftUI
import NotebookCore
import WebKit

#if os(iOS)
struct AgentWebElementView: UIViewRepresentable {
  let element: AgentElement
  let onState: (JSONValue) -> Void

  func makeCoordinator() -> AgentWebCoordinator {
    AgentWebCoordinator(onState: onState)
  }

  func makeUIView(context: Context) -> WKWebView {
    AgentWebCoordinator.makeWebView(coordinator: context.coordinator)
  }

  func updateUIView(_ webView: WKWebView, context: Context) {
    context.coordinator.onState = onState
    context.coordinator.load(element, in: webView)
  }
}
#else
struct AgentWebElementView: NSViewRepresentable {
  let element: AgentElement
  let onState: (JSONValue) -> Void

  func makeCoordinator() -> AgentWebCoordinator {
    AgentWebCoordinator(onState: onState)
  }

  func makeNSView(context: Context) -> WKWebView {
    AgentWebCoordinator.makeWebView(coordinator: context.coordinator)
  }

  func updateNSView(_ webView: WKWebView, context: Context) {
    context.coordinator.onState = onState
    context.coordinator.load(element, in: webView)
  }
}
#endif

@MainActor
final class AgentWebCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
  private struct DocumentSignature: Equatable {
    let html: String
    let css: String
    let javaScript: String
    let state: JSONValue
  }

  var onState: (JSONValue) -> Void
  var onNavigationCompletion: ((WKWebView, Bool) -> Void)?
  private var loadedSignature: DocumentSignature?

  init(onState: @escaping (JSONValue) -> Void) {
    self.onState = onState
  }

  func load(_ element: AgentElement, in webView: WKWebView) {
    let signature = DocumentSignature(
      html: element.html,
      css: element.css,
      javaScript: element.javaScript,
      state: element.state
    )
    guard signature != loadedSignature else { return }
    loadedSignature = signature
    webView.loadHTMLString(Self.document(for: element), baseURL: nil)
  }

  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    guard message.name == "notebook",
          let object = message.body as? [String: Any],
          object["kind"] as? String == "state",
          let state = object["value"],
          let value = Self.decodeState(state)
    else { return }
    onState(value)
  }

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    let scheme = navigationAction.request.url?.scheme
    decisionHandler(scheme == nil || scheme == "about" ? .allow : .cancel)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    let completion = onNavigationCompletion
    onNavigationCompletion = nil
    completion?(webView, true)
  }

  func webView(
    _ webView: WKWebView,
    didFail navigation: WKNavigation!,
    withError error: any Error
  ) {
    let completion = onNavigationCompletion
    onNavigationCompletion = nil
    completion?(webView, false)
  }

  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: any Error
  ) {
    let completion = onNavigationCompletion
    onNavigationCompletion = nil
    completion?(webView, false)
  }

  static func makeWebView(coordinator: AgentWebCoordinator) -> WKWebView {
    let controller = WKUserContentController()
    controller.add(coordinator, name: "notebook")
    let configuration = WKWebViewConfiguration()
    configuration.userContentController = controller
    configuration.websiteDataStore = .nonPersistent()
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = coordinator
    #if os(iOS)
      webView.isOpaque = false
      webView.backgroundColor = .clear
      webView.scrollView.backgroundColor = .clear
      webView.scrollView.isScrollEnabled = false
      webView.scrollView.minimumZoomScale = 1
      webView.scrollView.maximumZoomScale = 1
      webView.scrollView.pinchGestureRecognizer?.isEnabled = false
    #else
      webView.setValue(false, forKey: "drawsBackground")
      webView.allowsMagnification = false
    #endif
    return webView
  }

  private static func document(for element: AgentElement) -> String {
    let state = json(element.state).replacingOccurrences(
      of: "</script>",
      with: "<\\/script>",
      options: [.caseInsensitive]
    )
    return """
    <!doctype html>
    <html><head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: blob:; media-src data: blob:; font-src data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'none';">
    <style>
      :root { color-scheme: light; }
      html, body { width: 100%; height: 100%; margin: 0; overflow: hidden; background: transparent; }
      body { box-sizing: border-box; color: #171714; font: 17px/1.42 -apple-system, BlinkMacSystemFont, sans-serif; }
      *, *::before, *::after { box-sizing: border-box; }
      \(element.css)
    </style>
    <script>
      window.notebook = Object.freeze({
        state: \(state),
        commit(value) {
          window.webkit.messageHandlers.notebook.postMessage({ kind: 'state', value });
        }
      });
    </script>
    </head><body>
    \(element.html)
    <script>\(element.javaScript)</script>
    </body></html>
    """
  }

  private static func json(_ value: JSONValue) -> String {
    guard let data = try? JSONEncoder().encode(value) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
  }

  static func decodeState(_ object: Any) -> JSONValue? {
    guard let data = try? JSONSerialization.data(
      withJSONObject: object,
      options: [.fragmentsAllowed]
    ) else { return nil }
    return try? JSONDecoder().decode(JSONValue.self, from: data)
  }
}

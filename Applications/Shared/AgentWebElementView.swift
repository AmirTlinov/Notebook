import NotebookCore
import Observation
import SwiftUI
import WebKit

#if os(iOS)
  struct AgentWebElementView: UIViewRepresentable {
    let element: AgentElement
    let onRenderReady: (Bool) -> Void
    let onState: (JSONValue) -> Void

    func makeCoordinator() -> AgentWebCoordinator {
      AgentWebCoordinator(
        onRenderReady: onRenderReady,
        onState: onState
      )
    }

    func makeUIView(context: Context) -> WKWebView {
      AgentWebCoordinator.makeWebView(coordinator: context.coordinator)
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
      context.coordinator.use(onRenderReady: onRenderReady)
      context.coordinator.onState = onState
      context.coordinator.load(element, in: webView)
    }
  }
#else
  struct AgentWebElementView: NSViewRepresentable {
    let element: AgentElement
    let onRenderReady: (Bool) -> Void
    let onState: (JSONValue) -> Void

    func makeCoordinator() -> AgentWebCoordinator {
      AgentWebCoordinator(
        onRenderReady: onRenderReady,
        onState: onState
      )
    }

    func makeNSView(context: Context) -> WKWebView {
      AgentWebCoordinator.makeWebView(coordinator: context.coordinator)
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
      context.coordinator.use(onRenderReady: onRenderReady)
      context.coordinator.onState = onState
      context.coordinator.load(element, in: webView)
    }
  }
#endif

#if os(iOS)
typealias AgentSnapshotImage = UIImage
#else
typealias AgentSnapshotImage = NSImage
#endif

@MainActor
@Observable
final class AgentElementSnapshotCache {
    static let shared = AgentElementSnapshotCache()
    static let didChange = Notification.Name("NotebookAgentElementSnapshotDidChange")

    private struct Entry {
      let element: AgentElement
      let image: AgentSnapshotImage
    }

    private var diagnosticEntries: [String: (AgentElement, [RenderDiagnostic])] = [:]
    func record(_ diagnostic: RenderDiagnostic, for element: AgentElement) {
      var values = diagnosticEntries[element.id].flatMap { $0.0 == element ? $0.1 : nil } ?? []
      if !values.contains(diagnostic) { values.append(diagnostic) }
      diagnosticEntries[element.id] = (element, Array(values.suffix(32)))
    }
    func diagnostics(for elements: [AgentElement]) -> [RenderDiagnostic] {
      elements.flatMap { element in diagnosticEntries[element.id].flatMap { $0.0 == element ? $0.1 : nil } ?? [] }
    }

    private var entries: [String: [Entry]] = [:]

    func image(for element: AgentElement) -> AgentSnapshotImage? {
      entries[element.id]?.last(where: { $0.element == element })?.image
    }

    #if os(macOS)
    /// The publisher owns this temporary, window-backed WebKit render. It uses
    /// the same coordinator as the live element and accepts only its exact raster.
    func prepare(_ elements: [AgentElement]) async throws {
      for element in elements where image(for: element) == nil {
        try Task.checkCancellation()
        let coordinator = AgentWebCoordinator(onState: { _ in })
        let webView = AgentWebCoordinator.makeWebView(coordinator: coordinator)
        let size = NSSize(width: element.frame.width, height: element.frame.height)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
          styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.orderBack(nil)
        defer {
          webView.stopLoading()
          webView.configuration.userContentController.removeScriptMessageHandler(forName: "notebook")
          window.orderOut(nil)
          window.close()
        }
        coordinator.load(element, in: webView)
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(8)
        while image(for: element) == nil {
          try await Task.sleep(for: .milliseconds(20))
          guard clock.now < deadline else { throw SnapshotError.pending(element.id) }
        }
      }
    }

    enum SnapshotError: Error { case pending(String) }

    #endif

    func store(_ image: AgentSnapshotImage, for element: AgentElement) {
      var matchingID = entries[element.id] ?? []
      matchingID.removeAll { $0.element == element }
      matchingID.append(Entry(element: element, image: image))
      entries[element.id] = Array(matchingID.suffix(8))
      NotificationCenter.default.post(
        name: Self.didChange,
        object: element.id
      )
    }
  }


@MainActor
final class AgentWebCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
  var onState: (JSONValue) -> Void
  private var onRenderReady: (Bool) -> Void
  private var renderIsReady = false
  private var activeNavigation: WKNavigation?
  private var renderRevision: UInt64 = 0
  private var loadedElement: AgentElement?

  init(
    onRenderReady: @escaping (Bool) -> Void = { _ in },
    onState: @escaping (JSONValue) -> Void
  ) {
    self.onRenderReady = onRenderReady
    self.onState = onState
  }

  func use(onRenderReady: @escaping (Bool) -> Void) {
    self.onRenderReady = onRenderReady
  }

  func load(_ element: AgentElement, in webView: WKWebView) {
    guard loadedElement != element else {
      publishRenderReadiness(renderIsReady)
      return
    }
    loadedElement = element
    renderRevision &+= 1
    setRenderReady(false)
    activeNavigation = webView.loadHTMLString(
      Self.document(for: element),
      baseURL: nil
    )
  }

  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    guard message.name == "notebook", let object = message.body as? [String: Any] else { return }
    if object["kind"] as? String == "diagnostic", let element = loadedElement,
      let kind = object["category"] as? String, let message = object["message"] as? String {
      AgentElementSnapshotCache.shared.record(.init(kind: kind, elementID: element.id, message: String(message.prefix(2000))), for: element)
    } else if object["kind"] as? String == "state", let state = object["value"], let value = Self.decodeState(state) {
      onState(value)
    }
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
    guard navigation === activeNavigation else { return }
    let revision = renderRevision
    #if os(iOS)
      let frameReadiness = """
        await new Promise(resolve => requestAnimationFrame(
          () => requestAnimationFrame(resolve)
        ));
        """
    #else
      // WKSnapshotConfiguration.afterScreenUpdates supplies the finished Mac
      // frame, including an occluded publication window where RAF is suspended.
      let frameReadiness = ""
    #endif
    webView.callAsyncJavaScript(
      """
      await document.fonts.ready;
      await Promise.all([...document.images].map(image => image.decode().catch(() => {})));
      \(frameReadiness)
      for (const image of document.images) if (!image.naturalWidth) window.notebookDiagnostic('load_error', 'Image failed to load');
      if (Math.max(document.body.scrollHeight, document.documentElement.scrollHeight) > innerHeight + 1 || Math.max(document.body.scrollWidth, document.documentElement.scrollWidth) > innerWidth + 1) window.notebookDiagnostic('overflow', 'Content exceeds its frame');
      return true;
      """,
      arguments: [:],
      in: nil,
      in: .page,
      completionHandler: { [weak self] _ in
        guard let self, renderRevision == revision else { return }
        #if os(iOS)
          setRenderReady(true)
        #endif
        captureSnapshot(of: webView, revision: revision)
      }
    )
  }

  private func captureSnapshot(of webView: WKWebView, revision: UInt64) {
      guard let element = loadedElement else { return }
      let configuration = WKSnapshotConfiguration()
      configuration.afterScreenUpdates = true
      webView.takeSnapshot(with: configuration) { [weak self] image, _ in
        guard let self,
          renderRevision == revision,
          loadedElement == element,
          let image
        else { return }
        AgentElementSnapshotCache.shared.store(image, for: element)
        setRenderReady(true)
      }
    }

  func webView(
    _ webView: WKWebView,
    didFail navigation: WKNavigation!,
    withError error: any Error
  ) {
    guard navigation === activeNavigation else { return }
    if let element = loadedElement { AgentElementSnapshotCache.shared.record(.init(kind: "load_error", elementID: element.id, message: error.localizedDescription), for: element) }
    setRenderReady(false)
  }

  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: any Error
  ) {
    guard navigation === activeNavigation else { return }
    if let element = loadedElement { AgentElementSnapshotCache.shared.record(.init(kind: "load_error", elementID: element.id, message: error.localizedDescription), for: element) }
    setRenderReady(false)
  }

  private func setRenderReady(_ ready: Bool) {
    guard renderIsReady != ready else { return }
    renderIsReady = ready
    publishRenderReadiness(ready)
  }

  private func publishRenderReadiness(_ ready: Bool) {
    let handler = onRenderReady
    Task { @MainActor in handler(ready) }
  }

  static func makeWebView(
    coordinator: AgentWebCoordinator
  ) -> WKWebView {
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
        window.notebookDiagnostic = (category, message) => window.webkit.messageHandlers.notebook.postMessage({kind:'diagnostic',category,message:String(message)});
        addEventListener('error', event => window.notebookDiagnostic('javascript_error', event.message || 'Resource load error'));
        addEventListener('unhandledrejection', event => window.notebookDiagnostic('javascript_error', event.reason));
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
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: object,
        options: [.fragmentsAllowed]
      )
    else { return nil }
    return try? JSONDecoder().decode(JSONValue.self, from: data)
  }
}

import NotebookCore
import SwiftUI
import WebKit

/// A single viewport-sized, noninteractive vector surface, leased from the
/// existing WebKit budget. No snapshot, saved artifact, script bridge or input owner.
struct NotebookPresentationOverlay: View {
  let player: NotebookPresentationPlayer
  let presence: SessionPresence
  let cameraIsActive: Bool
  @State private var lease: WebSurfaceLease?

  var body: some View {
    Group {
      if let stage = player.stage, stage.step.svg != nil {
        SceneCameraPlane(presence: presence, revision: "\(stage.id)-\(lease?.id.uuidString ?? "waiting")", isCameraActive: cameraIsActive) { anchor in
          if let lease {
            NotebookPresentationSVGView(stage: stage, presence: anchor, lease: lease,
              ready: { player.rendered(stage.id,material:.svg) }, failed: { player.failed(stage.id) })
              .frame(width: anchor.viewport.x, height: anchor.viewport.y)
          }
        }
        .opacity(player.isFading ? 0 : 1)
        .animation(.easeOut(duration: 0.25), value: player.isFading)
        .task(id: stage.requestID) {
          guard lease == nil else { return }
          do {
            let acquired = try await SceneRenderResources.shared.acquireWebSurface(priority: .visible)
            guard !Task.isCancelled, player.stage?.requestID == stage.requestID else { acquired.release(); return }
            lease = acquired
          } catch { if !Task.isCancelled { player.failed(stage.id) } }
        }
      }
    }
    .allowsHitTesting(false).accessibilityHidden(true)
    .onChange(of: player.stage?.step.svg == nil) { _, empty in if empty { lease?.release(); lease = nil } }
    .onDisappear { lease?.release(); lease = nil }
  }
}

struct NotebookPresentationSVGView: UIViewRepresentable {
  let stage: NotebookPresentationPlayer.Stage
  let presence: SessionPresence
  let lease: WebSurfaceLease
  let ready: () -> Void
  let failed: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator(lease: lease) }
  func makeUIView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    let web = WKWebView(frame: .zero, configuration: configuration)
    web.navigationDelegate = context.coordinator
    web.isOpaque = false; web.backgroundColor = .clear
    web.scrollView.backgroundColor = .clear; web.scrollView.isScrollEnabled = false
    web.isUserInteractionEnabled = false
    return web
  }
  func updateUIView(_ web: WKWebView, context: Context) {
    guard context.coordinator.borrower != nil else { failed(); return }
    context.coordinator.ready = ready; context.coordinator.failed = failed
    let html = Self.html(step: stage.step, presence: presence)
    guard html != context.coordinator.source else { return }
    context.coordinator.source = html
    context.coordinator.navigation = web.loadHTMLString(html, baseURL: nil)
  }
  static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
    coordinator.ready = {}; coordinator.failed = {}; coordinator.navigation = nil
    web.stopLoading(); web.navigationDelegate = nil
    coordinator.borrower?.release()
  }

  static func html(step: NotebookPresentationStep, presence: SessionPresence) -> String {
    guard let svg = step.svg, let bounds = step.bounds else { return "" }
    let point = presence.camera.worldToScreen(bounds.origin, viewport: presence.viewport)
    return """
    <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'none'; base-uri 'none'; form-action 'none'">
    <style>html,body{margin:0;width:100%;height:100%;overflow:hidden;background:transparent;pointer-events:none}body>svg{width:100%;height:100%}.placement>svg{width:100%;height:100%}</style></head>
    <body><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(presence.viewport.x) \(presence.viewport.y)"><svg class="placement" x="\(point.x)" y="\(point.y)" width="\(bounds.width * presence.camera.scale)" height="\(bounds.height * presence.camera.scale)">\(svg)</svg></svg></body></html>
    """
  }

  final class Coordinator: NSObject, WKNavigationDelegate {
    let borrower: WebSurfaceBorrow?
    var source: String?
    var navigation: WKNavigation?
    var ready: () -> Void = {}
    var failed: () -> Void = {}
    init(lease: WebSurfaceLease) { borrower = try? lease.borrow() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      if navigation === self.navigation { ready() }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
      if navigation === self.navigation { failed() }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
      if navigation === self.navigation { failed() }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failed() }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
      navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel
    }
  }
}

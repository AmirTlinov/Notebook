import UIKit
import WebKit

/// WebKit lays out at its owner's physical size. UIKit projects
/// the completed surface into the scene; fractional camera rounding only changes
/// this outer transform, keeping font metrics and line breaks stable.
@MainActor
final class PhysicalWebViewport: UIView, NotebookSceneFingerInputOwner {
  private(set) weak var webView: WKWebView?
  var onInstalled: (() -> Void)?
  private var contentSize: CGSize
  private let holdsFingerInput: Bool
  var ownsSceneFingerInput: Bool {
    holdsFingerInput && webView?.superview === self
      && (webView?.navigationDelegate as? AgentWebCoordinator)?.yieldsFingerMotionToScene != true
  }

  init(webView: WKWebView, contentSize: CGSize, holdsFingerInput: Bool = false) {
    self.webView = webView
    self.contentSize = contentSize
    self.holdsFingerInput = holdsFingerInput
    super.init(frame: .zero)
    backgroundColor = .clear
    isOpaque = false
    addSubview(webView)
    applyContentSize()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("Use init(webView:contentSize:)") }

  func setContentSize(_ size: CGSize) {
    guard contentSize != size else { return }
    contentSize = size
    applyContentSize()
    setNeedsLayout()
  }

  /// Canonical browser layout belongs to content size, including before this
  /// viewport has any screen area. The outer projection never owns typography.
  private func applyContentSize() {
    guard let webView, webView.superview === self,
      contentSize.width.isFinite, contentSize.height.isFinite,
      contentSize.width > 0, contentSize.height > 0,
      webView.bounds.size != contentSize else { return }
    webView.bounds = CGRect(origin: .zero, size: contentSize)
  }

  /// The native subtree owns the attached runtime. A retired shell may outlive
  /// SwiftUI's dismantle callback, but it must not retain or move that runtime.
  func retire() {
    onInstalled = nil
    if let webView, webView.superview === self { webView.removeFromSuperview() }
    webView = nil
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard let webView, webView.superview === self else { return }
    applyContentSize()
    let size = contentSize
    guard size.width > 0, size.height > 0 else { return }
    let scale = min(bounds.width / size.width, bounds.height / size.height)
    guard scale.isFinite, scale > 0 else { return }
    webView.center = CGPoint(x: bounds.midX, y: bounds.midY)
    webView.transform = CGAffineTransform(scaleX: scale, y: scale)
    if window != nil { onInstalled?() }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil, webView?.superview === self { onInstalled?() }
  }
}

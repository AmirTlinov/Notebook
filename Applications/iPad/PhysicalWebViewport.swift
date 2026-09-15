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
  func sceneFingerOwner(at point: CGPoint) -> NotebookInputGate.FingerContactOwner? {
    guard holdsFingerInput, let webView, webView.superview === self else { return nil }
    guard let coordinator = webView.navigationDelegate as? AgentWebCoordinator else { return .nativeInput(ObjectIdentifier(self)) }
    switch coordinator.fingerInput(at: webView.convert(point, from: self), in: webView.bounds.size) {
    case .scene: return .scene
    case .link: return .webLink(ObjectIdentifier(self))
    case .input: return .nativeInput(ObjectIdentifier(self))
    }
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

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard let hit = super.hitTest(point, with: event) else { return nil }
    // A scene-owned background must not enter WKContentView at all: WebKit
    // can otherwise blur another program's editor before camera motion wins.
    // Controls and links keep their original native delivery; no event replay.
    if sceneFingerOwner(at: point) == .scene { return self }
    return hit
  }

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

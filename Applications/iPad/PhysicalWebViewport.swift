import UIKit
import WebKit

/// WebKit lays out at its owner's physical size. UIKit projects
/// the completed surface into the scene; fractional camera rounding only changes
/// this outer transform, keeping font metrics and line breaks stable.
@MainActor
final class PhysicalWebViewport: UIView {
  let webView: WKWebView
  private var contentSize: CGSize

  init(webView: WKWebView, contentSize: CGSize) {
    self.webView = webView
    self.contentSize = contentSize
    super.init(frame: .zero)
    backgroundColor = .clear
    isOpaque = false
    addSubview(webView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("Use init(webView:contentSize:)") }

  func setContentSize(_ size: CGSize) {
    guard contentSize != size else { return }
    contentSize = size
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let size = contentSize
    let scale = min(bounds.width / size.width, bounds.height / size.height)
    guard scale > 0 else { return }
    if webView.bounds.size != size { webView.bounds = CGRect(origin: .zero, size: size) }
    webView.center = CGPoint(x: bounds.midX, y: bounds.midY)
    webView.transform = CGAffineTransform(scaleX: scale, y: scale)
  }
}

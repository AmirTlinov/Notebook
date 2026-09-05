import NotebookCore
import UIKit
import WebKit

/// WebKit typesets at the document's canonical physical size. UIKit projects
/// the completed sheet into the scene; fractional camera rounding only changes
/// this outer transform, keeping font metrics and line breaks stable.
@MainActor
final class DocumentPaperViewport: UIView {
  let webView: WKWebView
  private var paperSize: DocumentPaperSize

  init(webView: WKWebView, paperSize: DocumentPaperSize) {
    self.webView = webView
    self.paperSize = paperSize
    super.init(frame: .zero)
    backgroundColor = .clear
    isOpaque = false
    addSubview(webView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("Use init(webView:paperSize:)") }

  func setPaperSize(_ size: DocumentPaperSize) {
    guard paperSize != size else { return }
    paperSize = size
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let paper = WorkspaceItemGeometry.document(paperSize)
    let size = CGSize(width: paper.width, height: paper.height)
    let scale = min(bounds.width / size.width, bounds.height / size.height)
    guard scale > 0 else { return }
    if webView.bounds.size != size { webView.bounds = CGRect(origin: .zero, size: size) }
    webView.center = CGPoint(x: bounds.midX, y: bounds.midY)
    webView.transform = CGAffineTransform(scaleX: scale, y: scale)
  }
}

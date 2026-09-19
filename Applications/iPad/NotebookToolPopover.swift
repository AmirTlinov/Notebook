import SwiftUI
import UIKit

/// One anchored panel for tool options and color. This presentation owns only
/// layout and outside-tap dismissal; preferences stay in the application model.
struct NotebookToolPopover<Content: View>: UIViewControllerRepresentable {
  let isPresented: Bool
  let anchor: UnitPoint
  let content: Content
  let onDismiss: () -> Void

  func makeUIViewController(context: Context) -> Presenter { Presenter() }
  func updateUIViewController(_ controller: Presenter, context: Context) {
    controller.configure(isPresented:isPresented,anchor:anchor,content:content,onDismiss:onDismiss)
  }
  static func dismantleUIViewController(_ controller: Presenter, coordinator: ()) {
    controller.dismiss(animated:false)
  }

  final class Presenter: UIViewController, UIViewControllerTransitioningDelegate {
    private var host: UIHostingController<Content>?
    private var anchor = UnitPoint.bottom
    private var onDismiss: (() -> Void)?
    override func loadView() { view = UIView(); view.backgroundColor = .clear; view.isUserInteractionEnabled = false }

    func configure(isPresented: Bool, anchor: UnitPoint, content: Content, onDismiss: @escaping () -> Void) {
      self.anchor = anchor; self.onDismiss = onDismiss
      guard isPresented else {
        if host != nil { dismiss(animated:false); host = nil }
        return
      }
      if let host { host.rootView = content }
      else {
        let host = UIHostingController(rootView:content)
        host.sizingOptions = .preferredContentSize
        host.modalPresentationStyle = .custom; host.transitioningDelegate = self
        host.view.backgroundColor = UIColor(NotebookChrome.surface)
        host.view.layer.cornerRadius = 10
        host.view.layer.borderWidth = 0.5; host.view.layer.borderColor = UIColor.label.withAlphaComponent(0.14).cgColor
        host.view.layer.shadowColor = UIColor.black.cgColor; host.view.layer.shadowOpacity = 0.12
        host.view.layer.shadowRadius = 8; host.view.layer.shadowOffset = .init(width:0,height:3)
        self.host = host; present(host,animated:false)
      }
      (host?.presentationController as? NotebookToolPanelPresentation)?.anchor = anchor
      host?.presentationController?.containerView?.setNeedsLayout()
    }
    func presentationController(forPresented presented: UIViewController, presenting: UIViewController?, source: UIViewController) -> UIPresentationController? {
      let panel = NotebookToolPanelPresentation(presentedViewController:presented,presenting:presenting)
      panel.sourceView = view; panel.anchor = anchor
      panel.onDismiss = { [weak self] in self?.onDismiss?() }
      return panel
    }
  }
}

/// No system popover chrome or view-hierarchy probing. UIKit retains normal
/// presentation/accessibility lifecycle; the panel has a literal 10-point rim.
private final class NotebookToolPanelPresentation: UIPresentationController {
  weak var sourceView: UIView?
  var anchor = UnitPoint.bottom
  var onDismiss: (() -> Void)?
  private let outside = UIControl()

  override var frameOfPresentedViewInContainerView: CGRect {
    guard let containerView, let sourceView else { return .zero }
    let point = sourceView.convert(.init(x:sourceView.bounds.width*anchor.x,y:sourceView.bounds.height*anchor.y),to:containerView)
    let limits = containerView.bounds.inset(by:containerView.safeAreaInsets).insetBy(dx:8,dy:8)
    let size = presentedViewController.preferredContentSize
    let width = min(size.width,limits.width), height = min(size.height,limits.height)
    let x = min(max(limits.minX,point.x-width/2),limits.maxX-width)
    let y = point.y+6+height <= limits.maxY ? point.y+6 : max(limits.minY,point.y-height-6)
    return .init(x:x,y:y,width:width,height:height)
  }
  override func presentationTransitionWillBegin() {
    guard let containerView else { return }
    outside.addAction(UIAction { [weak self] _ in self?.onDismiss?() },for:.touchUpInside)
    containerView.insertSubview(outside,at:0)
  }
  override func containerViewWillLayoutSubviews() {
    super.containerViewWillLayoutSubviews()
    outside.frame = containerView?.bounds ?? .zero
    presentedView?.frame = frameOfPresentedViewInContainerView
    if let view = presentedView { view.layer.shadowPath = UIBezierPath(roundedRect:view.bounds,cornerRadius:10).cgPath }
  }
  override func preferredContentSizeDidChange(forChildContentContainer container: UIContentContainer) {
    super.preferredContentSizeDidChange(forChildContentContainer:container)
    containerView?.setNeedsLayout()
  }
  override func dismissalTransitionDidEnd(_ completed: Bool) {
    if completed { outside.removeFromSuperview() }
  }
}

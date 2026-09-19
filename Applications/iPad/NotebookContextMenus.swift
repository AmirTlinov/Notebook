import SwiftUI
import UIKit

/// One workspace presentation owner. Features supply actions and their anchor;
/// this owner supplies the surface, placement, native-menu lifetime and input boundary.
@MainActor
final class NotebookContextMenus: NSObject, UIPopoverPresentationControllerDelegate {
  let view = HostView()
  private let surface = UIVisualEffectView(effect:UIGlassEffect(style:.regular))
  private let stack = UIStackView()
  private var source: UUID?
  private weak var anchorView: UIView?
  private var anchor = CGRect.zero
  private var exclusions: [CGRect] = []
  private var buttons: [UIButton] = []
  private var popover: UIViewController?
  private weak var gate: NotebookInputGate?
  private let controlSource = UUID()

  override init() {
    super.init()
    view.backgroundColor = .clear; view.isOpaque = false
    surface.accessibilityIdentifier = "notebook-context-menu"
    surface.cornerConfiguration = .capsule(); surface.isHidden = true
    stack.axis = .horizontal; stack.alignment = .center; stack.distribution = .fillEqually
    stack.translatesAutoresizingMaskIntoConstraints = false
    surface.contentView.addSubview(stack); view.addSubview(surface)
    NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:surface.contentView.leadingAnchor,constant:4),
      stack.trailingAnchor.constraint(equalTo:surface.contentView.trailingAnchor,constant:-4),
      stack.topAnchor.constraint(equalTo:surface.contentView.topAnchor),
      stack.bottomAnchor.constraint(equalTo:surface.contentView.bottomAnchor)])
    view.onLayout = { [weak self] in self?.place() }
  }
  func use(_ gate: NotebookInputGate) {
    guard self.gate !== gate else { return }
    self.gate?.unregisterControlRegion(source:controlSource); self.gate = gate
    gate.registerControlRegion(source:controlSource) { [weak self] point, _ in
      guard let self, view.window != nil else { return false }
      // The dismissal contact belongs to UIKit, never to the paper underneath.
      if hasPresentedMenu { return true }
      return !surface.isHidden && surface.bounds.contains(surface.convert(point,from:view.window))
    }
  }
  static func configure(_ button: UIButton, symbol: String, title: String, id: String, destructive: Bool = false) {
    var configuration = UIButton.Configuration.plain()
    configuration.image = UIImage(systemName:symbol)
    configuration.preferredSymbolConfigurationForImage = .init(pointSize:NotebookChrome.iconSize,weight:.regular)
    configuration.baseForegroundColor = destructive ? .systemRed : .label
    configuration.contentInsets = .zero
    configuration.background.cornerRadius = 8
    configuration.background.backgroundInsets = .init(top:6,leading:6,bottom:6,trailing:6)
    button.configuration = configuration; button.tintColor = destructive ? .systemRed : .label
    button.accessibilityLabel = title; button.accessibilityIdentifier = id
    button.widthAnchor.constraint(equalToConstant:NotebookChrome.controlSize).isActive = true
    button.heightAnchor.constraint(equalToConstant:NotebookChrome.controlSize).isActive = true
  }
  func show(source: UUID, anchor: CGRect, in anchorView: UIView, buttons: [UIButton],
    avoiding exclusions: [CGRect] = [], enabled: Bool = true) {
    guard anchorView.window != nil, view.window == nil || anchorView.window === view.window else { return }
    if self.source != source { dismissCurrent(); self.source = source }
    self.anchorView = anchorView; self.anchor = anchor; self.exclusions = exclusions
    if self.buttons != buttons {
      for child in stack.arrangedSubviews { stack.removeArrangedSubview(child); child.removeFromSuperview() }
      for button in buttons { stack.addArrangedSubview(button) }
      self.buttons = buttons
    }
    surface.isUserInteractionEnabled = enabled; surface.alpha = enabled ? 1 : 0.45
    place(); view.setNeedsLayout()
  }
  func hide(source: UUID) {
    guard self.source == source else { return }
    dismissCurrent(); self.source = nil; anchorView = nil
  }
  func uninstall() {
    dismissCurrent(); source = nil; anchorView = nil
    gate?.unregisterControlRegion(source:controlSource); gate = nil
  }
  private func dismissCurrent() {
    dismissPopover()
    for button in buttons { (button as? NotebookContextMenuButton)?.contextMenuInteraction?.dismissMenu() }
    for child in stack.arrangedSubviews { stack.removeArrangedSubview(child); child.removeFromSuperview() }
    buttons = []; surface.isHidden = true
  }
  var hasPresentedMenu: Bool { popover != nil || buttons.contains { ($0 as? NotebookContextMenuButton)?.isMenuPresented == true } }
  func presentedPopover(for source: UUID) -> UIViewController? { self.source == source ? popover : nil }
  func dismissPopover(source: UUID) { if self.source == source { dismissPopover() } }
  private func dismissPopover() { let old = popover; popover = nil; old?.dismiss(animated:false) }
  func presentPopover(_ controller: UIViewController, source: UUID, from anchor: UIView, rect: CGRect? = nil) {
    guard self.source == source, popover == nil else { return }
    var responder: UIResponder? = view
    while responder != nil && !(responder is UIViewController) { responder = responder?.next }
    guard let owner = responder as? UIViewController else { return }
    controller.popoverPresentationController?.delegate = self
    controller.popoverPresentationController?.sourceView = anchor
    controller.popoverPresentationController?.sourceRect = rect ?? anchor.bounds
    controller.popoverPresentationController?.permittedArrowDirections = .any
    popover = controller; owner.present(controller,animated:true)
  }
  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    if popover === presentationController.presentedViewController { popover = nil }
  }
  func popoverPresentationControllerDidDismissPopover(_ controller: UIPopoverPresentationController) { presentationControllerDidDismiss(controller) }
  func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle { .none }
  func frame(for source: UUID, in view: UIView) -> CGRect {
    self.source == source && !surface.isHidden ? surface.convert(surface.bounds,to:view) : .null
  }
  private func place() {
    guard source != nil, !buttons.isEmpty, let anchorView, let window = view.window,
      anchorView.window === window, !view.bounds.isEmpty else { surface.isHidden = true; return }
    let selected = anchorView.convert(anchor,to:view)
    guard selected.intersects(view.bounds) else { surface.isHidden = true; return }
    let obstacles = exclusions.map { anchorView.convert($0,to:view) }
    let clearance = obstacles.reduce(selected) { $0.union($1) }
    let safe = view.bounds.inset(by:.init(top:max(12,view.safeAreaInsets.top+76),left:12,
      bottom:max(12,view.safeAreaInsets.bottom+76),right:12))
    let width = CGFloat(buttons.count)*NotebookChrome.controlSize+8, height = NotebookChrome.controlSize
    let x = min(max(selected.midX-width/2,safe.minX),max(safe.minX,safe.maxX-width))
    let candidates = [clearance.minY-height-12,clearance.maxY+12,safe.minY,safe.maxY-height].map {
      CGRect(x:x,y:min(max($0,safe.minY),max(safe.minY,safe.maxY-height)),width:width,height:height)
    }
    surface.frame = candidates.first { !$0.intersects(selected) && !obstacles.contains(where:$0.intersects) }
      ?? candidates.first { candidate in !obstacles.contains(where:candidate.intersects) } ?? candidates[0]
    surface.isHidden = false
  }
  final class HostView: UIView {
    var onLayout: (() -> Void)?
    override func layoutSubviews() { super.layoutSubviews(); onLayout?() }
    override func didMoveToWindow() { super.didMoveToWindow(); onLayout?() }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
      let hit = super.hitTest(point,with:event)
      return hit === self ? nil : hit
    }
  }
}

struct NotebookContextMenuHost: UIViewRepresentable {
  let owner: NotebookContextMenus
  let gate: NotebookInputGate
  func makeUIView(context: Context) -> NotebookContextMenus.HostView { owner.use(gate); return owner.view }
  func updateUIView(_ view: NotebookContextMenus.HostView, context: Context) { owner.use(gate) }
  func makeCoordinator() -> NotebookContextMenus { owner }
  static func dismantleUIView(_ view: NotebookContextMenus.HostView, coordinator: NotebookContextMenus) { coordinator.uninstall() }
}

/// UIKit owns one immutable menu during presentation. SwiftUI can update the
/// next menu's contents without replacing the menu beneath an active touch.
final class NotebookContextMenuButton: UIButton {
  var contents: [UIMenuElement] = []
  private var presentedConfiguration: UIContextMenuConfiguration?
  var isMenuPresented: Bool { presentedConfiguration != nil }
  override init(frame: CGRect) {
    super.init(frame:frame)
    menu = UIMenu(children:[UIDeferredMenuElement.uncached { [weak self] completion in
      completion(self?.contents ?? [])
    }])
    showsMenuAsPrimaryAction = true
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
    willDisplayMenuFor configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
    presentedConfiguration = configuration
    super.contextMenuInteraction(interaction,willDisplayMenuFor:configuration,animator:animator)
  }
  override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
    willEndFor configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
    super.contextMenuInteraction(interaction,willEndFor:configuration,animator:animator)
    let finish = { [weak self] in
      guard self?.presentedConfiguration === configuration else { return }
      self?.presentedConfiguration = nil
    }
    if let animator { animator.addCompletion(finish) } else { finish() }
  }
}


import SwiftUI
import UIKit
import NotebookCore

/// One workspace presentation owner. Features supply actions and their anchor;
/// this owner supplies the surface, placement, native-menu lifetime and input boundary.
@MainActor
final class NotebookContextMenus: NSObject, UIPopoverPresentationControllerDelegate {
  let view = HostView()
  // This small control surface must not filter the entire live ink backdrop
  // whenever selection changes. Keep the same native buttons and geometry.
  private let surface = UIView()
  private let stack = UIStackView()
  private var source: UUID?
  private weak var anchorView: UIView?
  private var anchor = CGRect.zero
  private var exclusions: [CGRect] = []
  private var buttons: [UIButton] = []
  // UIKit owns the presented controller. SwiftUI dismiss() does not call the
  // adaptive-presentation delegate; retaining it here would leave an invisible
  // full-canvas input exclusion after the menu has gone.
  private weak var popover: UIViewController?
  private weak var gate: NotebookInputGate?
  private let controlSource = UUID()
  private let selectionMore = NotebookContextMenuButton(type:.system)
  private var selectionCommands: (primary:[UIMenuElement],secondary:[UIMenuElement],destructive:[UIMenuElement])?
  private var selectionActionsEnabled=false
  private var selectionAnchor = CGRect.zero
  private var selectionPopover: (selection:UUID,reference:EditableElementReference,isCurrent:()->Bool)?
  private weak var selectionModel: NotebookAppModel?
  private var inlineControls = false
  private var selectionActionsVisible = false
  private var registeredSelection: UUID?
  private var pendingSelection: (id:UUID,point:CGPoint)?
  var selectionActions: ((UUID,CGPoint) -> [UIMenuElement])?
  private(set) var clipboardTask:Task<Void,Never>?
  private var clipboardCommand:UUID?
  // The system clipboard is shared by all Notebook windows. A menu owns its
  // presentation, but only the latest explicit export owns publication.
  private static weak var clipboardOwner:NotebookContextMenus?

  private func cancelClipboard() {
    clipboardTask?.cancel();clipboardTask=nil;clipboardCommand=nil
    if Self.clipboardOwner === self { Self.clipboardOwner=nil }
  }

  func copySelection(_ model:NotebookAppModel,selection:UUID,cut:Bool) {
    guard model.selectionSession.id == selection else { return }
    Self.clipboardOwner?.cancelClipboard()
    Self.clipboardOwner=self
    let command=UUID();clipboardCommand=command
    let clipboardVersion=UIPasteboard.general.changeCount
    do {
      let snapshot=try model.clipboardSelectionSnapshot()
      clipboardTask=Task { [weak self,weak model] in
        defer {
          if let self, clipboardCommand == command {
            clipboardTask=nil;clipboardCommand=nil
            if Self.clipboardOwner === self { Self.clipboardOwner=nil }
          }
        }
        guard !Task.isCancelled else { return }
        let worker=Task.detached(priority:.userInitiated) {
          try NotebookClipboard.prepareExport(snapshot.prepare().fragment)
        }
        do {
          let exported=try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
          guard !Task.isCancelled,let self,let model,clipboardCommand == command else { return }
          guard Self.clipboardOwner === self, UIPasteboard.general.changeCount == clipboardVersion else { return }
          if cut && !model.selectionStillMatches(snapshot) {
            model.showCue("Выделение изменилось. Повторите вырезание.");return
          }
          UIPasteboard.general.setItems([exported.representations],options:[:])
          if cut { model.deleteSelectedContent() }
        } catch is CancellationError {} catch {
          if self?.clipboardCommand == command { model?.showCue(error.localizedDescription) }
        }
      }
    } catch {
      cancelClipboard();model.showCue(error.localizedDescription)
    }
  }


  override init() {
    super.init()
    view.backgroundColor = .clear; view.isOpaque = false
    view.owner = self
    surface.accessibilityIdentifier = "notebook-context-menu"
    surface.cornerConfiguration = .capsule(); surface.isHidden = true
    surface.backgroundColor = .secondarySystemGroupedBackground
    surface.layer.shadowColor = UIColor.black.cgColor
    surface.layer.shadowOpacity = 0.12; surface.layer.shadowRadius = 6
    surface.layer.shadowOffset = .init(width:0,height:2)
    stack.axis = .horizontal; stack.alignment = .center; stack.distribution = .fillEqually
    stack.translatesAutoresizingMaskIntoConstraints = false
    surface.addSubview(stack); view.addSubview(surface)
    Self.configure(selectionMore,symbol:"ellipsis",title:"Ещё",id:"selection-more-actions")
    selectionMore.preferredMenuElementOrder = .fixed
    selectionMore.onMenuDismiss = { [weak self] in
      // A finished secondary command ends this request as well. Reopening
      // actions reads fresh modes and identities from the current selection.
      self?.hideSelectionActions()
      self?.presentRegisteredSelectionIfReady()
    }
    NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:surface.leadingAnchor,constant:4),
      stack.trailingAnchor.constraint(equalTo:surface.trailingAnchor,constant:-4),
      stack.topAnchor.constraint(equalTo:surface.topAnchor),
      stack.bottomAnchor.constraint(equalTo:surface.bottomAnchor)])
    view.onLayout = { [weak self] in self?.place() }
  }
  func use(_ gate: NotebookInputGate) {
    guard self.gate !== gate else { return }
    self.gate?.unregisterControlRegion(source:controlSource); self.gate = gate
    gate.registerControlRegion(source:controlSource) { [weak self] point, _ in
      guard let self, view.window != nil else { return false }
      // The dismissal contact belongs to UIKit, never to the paper underneath.
      if blocksCanvasInput { return true }
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
  static func clipboardActions(cut: (() -> Void)?, copy: (() -> Void)?, paste: (() -> Void)?) -> [UIMenuElement] {
    [("Вырезать","scissors","selection-cut",cut),("Копировать","doc.on.doc","selection-copy",copy),
      ("Вставить","doc.on.clipboard","selection-paste",paste)].map { title,symbol,id,action in
      UIAction(title:title,image:UIImage(systemName:symbol),identifier:.init(id),attributes:action == nil ? .disabled : []) { _ in action?() }
    }
  }
  func show(source: UUID, anchor: CGRect, in anchorView: UIView, buttons: [UIButton],
    avoiding exclusions: [CGRect] = [], enabled: Bool = true) {
    guard anchorView.window != nil, view.window == nil || anchorView.window === view.window else { return }
    if self.source != source { dismissCurrent(); self.source = source }
    inlineControls = true
    self.anchorView = anchorView; self.anchor = anchor; self.exclusions = exclusions
    installButtons(buttons)
    surface.isUserInteractionEnabled = enabled; surface.alpha = enabled ? 1 : 0.45
    place(); view.setNeedsLayout()
  }
  private func installButtons(_ buttons:[UIButton]) {
    if self.buttons != buttons {
      for child in stack.arrangedSubviews { stack.removeArrangedSubview(child); child.removeFromSuperview() }
      for button in buttons { stack.addArrangedSubview(button) }
      self.buttons = buttons
    }
  }
  func hide(source: UUID) {
    guard self.source == source else { return }
    let next=pendingSelection.flatMap { $0.id == registeredSelection ? nil : $0.id }
    dismissCurrent(preservingPending:next); self.source = nil; anchorView = nil
  }
  // A frame is only an installed geometry lease. Repainting the same selected
  // object may remove it while the user's parameter editor remains open.
  func detachSelectionActions(source: UUID) {
    guard self.source == source,!inlineControls else { return }
    self.source=nil;anchorView=nil;selectionCommands=nil;selectionActionsEnabled=false
    surface.isHidden=true;surface.isUserInteractionEnabled=false
  }
  func updateSelection(_ model: NotebookAppModel) {
    selectionModel=model
    let reference=model.selectionSession.editingElement
    let graphic=reference.flatMap { model.graphicElement($0) }
    // The Host observes the selected material before an action opens its
    // palette. A pending draft may mask graphicElement's canonical source.
    if let reference {
      switch reference {
      case .page(let page,_): _ = model.pages[page]
      case .spatial: _ = model.boardHierarchy
      }
    }
    if let pending=pendingSelection,!permitsSelectionMenu(pending.id) { pendingSelection=nil }
    if let registeredSelection,!permitsSelectionMenu(registeredSelection) {
      dismissCurrent(preservingPending:pendingSelection?.id);source=nil;anchorView=nil
      return
    }
    guard let binding=selectionPopover else { return }
    guard model.selectionSession.id == binding.selection,
      reference == binding.reference,
      binding.isCurrent(),
      let popover,configureSelectionPopover(popover,reference:binding.reference,graphic:graphic,model:model) else {
      dismissPopover();return
    }
  }
  private func configureSelectionPopover(_ controller:UIViewController,reference:EditableElementReference,graphic:NotebookGraphic?,model:NotebookAppModel) -> Bool {
    guard model.elementGeometry(reference) != nil,let graphic,graphic.visible != false else { return false }
    if let style=controller as? NotebookElementStyleController {
      guard graphic.freehand == nil else { return false }
      style.configure(style:graphic.style)
    } else if let line=controller as? NotebookConnectionController {
      guard let connection=graphic.connection else { return false }
      line.configure(connection)
    }
    return true
  }
  func uninstall() {
    cancelClipboard()
    dismissCurrent(); source = nil; anchorView = nil; selectionActions = nil; pendingSelection = nil
    selectionModel=nil
    gate?.unregisterControlRegion(source:controlSource); gate = nil
  }
  private func dismissCurrent(preservingPending selection:UUID? = nil) {
    if pendingSelection?.id != selection { pendingSelection=nil }
    dismissPopover()
    selectionMore.dismissMenu();selectionMore.contents=[]
    selectionCommands=nil;selectionActionsEnabled=false
    registeredSelection=nil; inlineControls=false;selectionActionsVisible=false
    for button in buttons { (button as? NotebookContextMenuButton)?.contextMenuInteraction?.dismissMenu() }
    for child in stack.arrangedSubviews { stack.removeArrangedSubview(child); child.removeFromSuperview() }
    buttons = []; surface.isHidden = true
  }
  var hasPresentedMenu: Bool { selectionActionsVisible || blocksCanvasInput }
  var blocksCanvasInput: Bool { selectionMore.isMenuPresented || popover?.presentingViewController != nil || buttons.contains { ($0 as? NotebookContextMenuButton)?.isMenuPresented == true } }
  private func permitsSelectionMenu(_ selection:UUID) -> Bool {
    guard let model=selectionModel else { return true }
    return model.selectionSession.id == selection && model.selectionSession.count > 0
      && !model.selectionSession.isInteractive && model.selectionSession.manipulation == nil
  }
  func requestSelectionMenu(_ selection: UUID, at point: CGPoint) {
    guard permitsSelectionMenu(selection),popover?.presentingViewController == nil else { return }
    pendingSelection = (selection,point)
    presentRegisteredSelectionIfReady()
  }
  func registerSelectionActions(source: UUID, selection: UUID, anchor: CGRect, in anchorView: UIView,
    primary: [UIMenuElement], secondary: [UIMenuElement], destructive: [UIMenuElement], enabled: Bool) {
    guard permitsSelectionMenu(selection) else {
      if registeredSelection == selection { dismissCurrent() }
      return
    }
    guard anchorView.window != nil,view.window == nil || anchorView.window === view.window else { return }
    if registeredSelection != selection || inlineControls { dismissCurrent(preservingPending:selection) }
    self.source=source;self.anchorView=anchorView;self.anchor=anchor
    selectionAnchor=anchorView.convert(anchor,to:view)
    selectionCommands=(primary,secondary,destructive)
    selectionActionsEnabled=enabled
    registeredSelection=selection; inlineControls=false
    surface.isUserInteractionEnabled=enabled
    surface.alpha=enabled ? 1 : 0.45
    place()
    if selectionPopover?.selection == selection {
      popover?.popoverPresentationController?.sourceRect=selectionAnchor
    }
    if enabled { presentRegisteredSelectionIfReady() }
  }
  private func presentRegisteredSelectionIfReady() {
    if let pending=pendingSelection,!permitsSelectionMenu(pending.id) || popover?.presentingViewController != nil {
      pendingSelection=nil
    }
    guard let pending=pendingSelection, registeredSelection == pending.id,
      let commands=selectionCommands,selectionActionsEnabled,view.window != nil,!selectionMore.isMenuPresented else { return }
    pendingSelection=nil
    // The contact chooses a command's destination. Placement belongs to the
    // current selected geometry, including camera projection and remounts.
    let clipboard=selectionActions?(pending.id,pending.point) ?? []
    func flattened(_ elements:[UIMenuElement])->[UIMenuElement] {
      elements.flatMap { element in
        if let menu=element as? UIMenu,menu.options.contains(.displayInline) { return flattened(menu.children) }
        return [element]
      }
    }
    let clipboardActions=flattened(clipboard).compactMap { $0 as? UIAction }
    var quick:[UIAction]=[]
    if let primary=commands.primary.first as? UIAction,!primary.attributes.contains(.disabled) { quick.append(primary) }
    quick += clipboardActions.filter { ["selection-copy","selection-duplicate"].contains($0.identifier.rawValue) }
    quick += commands.destructive.compactMap { $0 as? UIAction }.prefix(1)
    let quickIDs=Set(quick.map(\.identifier))
    func group(_ elements:[UIMenuElement])->[UIMenuElement] {
      let remaining=flattened(elements).filter { element in
        guard let action=element as? UIAction else { return true }
        return !quickIDs.contains(action.identifier)
      }
      return remaining.isEmpty ? [] : [UIMenu(options:.displayInline,children:remaining)]
    }
    selectionMore.contents=group(commands.primary)+group(clipboard)+group(commands.secondary)+group(commands.destructive)
    var controls=quick.map { action in
      let button=UIButton(type:.system)
      Self.configure(button,symbol:"circle",title:action.title,id:action.identifier.rawValue,destructive:action.attributes.contains(.destructive))
      button.configuration?.image=action.image
      button.toolTip=action.title
      button.isEnabled = !action.attributes.contains(.disabled)
      button.addAction(UIAction { [weak self,weak button] _ in
        guard let self,let button,registeredSelection == pending.id,permitsSelectionMenu(pending.id) else { return }
        hideSelectionActions()
        button.sendAction(action)
      },for:.touchUpInside)
      return button
    }
    if !selectionMore.contents.isEmpty { controls.append(selectionMore) }
    guard !controls.isEmpty else { return }
    installButtons(controls)
    selectionActionsVisible=true
    place()
  }
  private func hideSelectionActions() {
    guard selectionActionsVisible,!inlineControls else { return }
    selectionActionsVisible=false;surface.isHidden=true
    installButtons([])
  }
  func performAfterSelectionMenuDismiss(selection:UUID,_ action:@escaping()->Void) {
    if pendingSelection?.id == selection { pendingSelection=nil }
    selectionMore.performAfterDismiss { [weak self] in
      guard let self,registeredSelection == selection,
        permitsSelectionMenu(selection) else { return }
      hideSelectionActions()
      action()
    }
  }
  func presentSelectionPopover(_ controller:UIViewController,selection:UUID,reference:EditableElementReference,isCurrent:@escaping()->Bool) {
    performAfterSelectionMenuDismiss(selection:selection) { [weak self] in
      guard let self,let model=selectionModel,model.selectionSession.editingElement == reference,isCurrent(),
        configureSelectionPopover(controller,reference:reference,graphic:model.graphicElement(reference),model:model) else { return }
      dismissPopover()
      selectionPopover=(selection,reference,isCurrent)
      presentPopover(controller,from:view,rect:selectionAnchor)
    }
  }
  func presentContent<Content: View>(_ content: Content, at point: CGPoint) {
    dismissCurrent()
    source=nil;anchorView=nil
    let controller=UIHostingController(rootView:content)
    controller.modalPresentationStyle = .popover
    controller.sizingOptions = [.preferredContentSize]
    presentPopover(controller,from:view,rect:.init(x:point.x,y:point.y,width:1,height:1))
  }
  func dismissPresentedContent() { dismissCurrent(); pendingSelection=nil }
  private func dismissPopover() { let old = popover; popover = nil; selectionPopover=nil; old?.dismiss(animated:false) }
  private func presentPopover(_ controller:UIViewController,from anchor:UIView,rect:CGRect) {
    var responder: UIResponder? = view
    while responder != nil && !(responder is UIViewController) { responder = responder?.next }
    guard let owner = responder as? UIViewController else { return }
    controller.popoverPresentationController?.delegate = self
    controller.popoverPresentationController?.sourceView = view
    controller.popoverPresentationController?.sourceRect = anchor.convert(rect,to:view)
    controller.popoverPresentationController?.permittedArrowDirections = .any
    popover = controller; owner.present(controller,animated:true)
  }
  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    if popover === presentationController.presentedViewController { popover = nil;selectionPopover=nil }
  }
  func popoverPresentationControllerDidDismissPopover(_ controller: UIPopoverPresentationController) { presentationControllerDidDismiss(controller) }
  func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle { .none }
  private func place() {
    guard (inlineControls || (selectionActionsVisible && selectionActionsEnabled)), !buttons.isEmpty,view.window != nil,
      !view.bounds.isEmpty else { surface.isHidden = true; return }
    let selected:CGRect
    let obstacles:[CGRect]
    if inlineControls,let anchorView,anchorView.window === view.window {
      selected=anchorView.convert(anchor,to:view)
      obstacles=exclusions.map { anchorView.convert($0,to:view) }
    } else if selectionActionsVisible { selected=selectionAnchor;obstacles=[] }
    else { surface.isHidden=true;return }
    guard selected.intersects(view.bounds) else { surface.isHidden = true; return }
    let clearance = obstacles.reduce(selected) { $0.union($1) }
    let safe = view.bounds.inset(by:.init(top:max(12,view.safeAreaInsets.top+76),left:12,
      bottom:max(12,view.safeAreaInsets.bottom+76),right:12))
    let width = CGFloat(buttons.count)*NotebookChrome.controlSize+8, height = NotebookChrome.controlSize
    let visible=selected.intersection(safe)
    let center=visible.isNull ? selected.midX : visible.midX
    let x = min(max(center-width/2,safe.minX),max(safe.minX,safe.maxX-width))
    var candidates = [clearance.minY-height-14,clearance.maxY+14].map {
      CGRect(x:x,y:min(max($0,safe.minY),max(safe.minY,safe.maxY-height)),width:width,height:height)
    }
    let y=min(max(selected.midY-height/2,safe.minY),max(safe.minY,safe.maxY-height))
    candidates += [clearance.minX-width-14,clearance.maxX+14].map {
      CGRect(x:min(max($0,safe.minX),max(safe.minX,safe.maxX-width)),y:y,width:width,height:height)
    }
    surface.frame = candidates.first { !$0.intersects(selected) && !obstacles.contains(where:$0.intersects) }
      ?? candidates.first { candidate in !obstacles.contains(where:candidate.intersects) } ?? candidates[0]
    surface.layer.shadowPath = UIBezierPath(roundedRect:surface.bounds,cornerRadius:height/2).cgPath
    surface.isHidden = false
  }
  final class HostView: UIView {
    weak var owner: NotebookContextMenus?
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
  @Environment(NotebookAppModel.self) private var model
  let owner: NotebookContextMenus
  let gate: NotebookInputGate
  func makeUIView(context: Context) -> NotebookContextMenus.HostView { owner.use(gate); return owner.view }
  func updateUIView(_ view: NotebookContextMenus.HostView, context: Context) { owner.use(gate);owner.updateSelection(model) }
  func makeCoordinator() -> NotebookContextMenus { owner }
  static func dismantleUIView(_ view: NotebookContextMenus.HostView, coordinator: NotebookContextMenus) { coordinator.uninstall() }
}

/// UIKit owns one immutable menu during presentation. SwiftUI can update the
/// next menu's contents without replacing the menu beneath an active touch.
final class NotebookContextMenuButton: UIButton {
  var contents: [UIMenuElement] = []
  private var presentedConfiguration: UIContextMenuConfiguration?
  private var afterDismiss: (UIContextMenuConfiguration,()->Void)?
  var onMenuDismiss: (() -> Void)?
  var isMenuPresented: Bool { presentedConfiguration != nil }
  override init(frame: CGRect) {
    super.init(frame:frame)
    menu = UIMenu(children:[UIDeferredMenuElement.uncached { [weak self] completion in
      completion(self?.contents ?? [])
    }])
    showsMenuAsPrimaryAction = true
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func dismissMenu() {
    afterDismiss=nil
    contextMenuInteraction?.dismissMenu()
  }
  func performAfterDismiss(_ action:@escaping()->Void) {
    guard let configuration=presentedConfiguration else { action();return }
    afterDismiss=(configuration,action)
    contextMenuInteraction?.dismissMenu()
  }
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
      let action=self?.afterDismiss
      self?.afterDismiss=nil
      self?.presentedConfiguration = nil
      if action?.0 === configuration { action?.1() }
      self?.onMenuDismiss?()
    }
    if let animator { animator.addCompletion(finish) } else { finish() }
  }
}


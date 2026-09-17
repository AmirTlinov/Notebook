import NotebookCore
import SwiftUI
import UIKit

/// Feedback exists only while a terminal is being dragged onto this target.
/// It is neither a stored decoration nor a transaction/highlight animation.
struct NotebookGraphicBindingHint: View {
  @Environment(NotebookAppModel.self) private var model
  let presence: SessionPresence
  var body: some View {
    if let target = model.manipulatedBindingTarget?.reference,
      let graphic = model.graphicElement(target),
      let frame = NotebookAttentionProjection.editingFrame(target,model:model,presence:presence) {
      NotebookGraphicView(graphic:.init(shape:graphic.shape,
        style:.init(stroke:.init(red:0.15,green:0.4,blue:0.85),strokeWidth:2),
        vertices:graphic.vertices,cornerRadius:graphic.cornerRadius))
        .frame(width:frame.width,height:frame.height).position(x:frame.midX,y:frame.midY)
        .allowsHitTesting(false).accessibilityHidden(true)
    }
  }
}

/// One screen-space frame for the selected physical element. Its corners and sides
/// retain 44-point touch targets; neither paper zoom nor a portal duplicates them.
struct NotebookElementControls: UIViewRepresentable {
  @Environment(NotebookAppModel.self) private var model
  let reference: EditableElementReference
  let selectionID: UUID
  let frame: CGRect
  let scale: Double

  func makeUIView(context: Context) -> NotebookElementControlsView { .init(gate: model.inputGate) }
  func updateUIView(_ view: NotebookElementControlsView, context: Context) {
    var graphic = model.graphicElement(reference)
    if let contact = model.selectionSession.manipulation, contact.reference == reference {
      if contact.vertices != contact.originalVertices { graphic?.vertices = contact.vertices }
      if contact.cornerRadius != contact.originalCornerRadius { graphic?.cornerRadius = contact.cornerRadius }
    }
    view.graphic = graphic
    view.configure(selectionID: selectionID, frame: frame, layout: model.graphicElement(reference)?.connection == nil ? nil : model.graphicLayout(reference), scale:scale,
      hasLabel: !(graphic?.label.isEmpty ?? true), mode:model.selectionSession.geometryMode, manipulating: model.selectionSession.manipulation != nil)
    view.beginManipulation = { kind in
      guard model.selectionSession.id == selectionID,
        let contact = model.beginElementManipulation(reference, kind: kind) else { return nil }
      let scale = max(scale, 0.001)
      return .init(begin: {}, change: { point in
        model.updateElementManipulation(contact, translation: .init(x: point.x / scale, y: point.y / scale))
      }, end: { point in
        model.finishElementManipulation(contact, translation: .init(x: point.x / scale, y: point.y / scale))
      }, cancel: { model.cancelElementManipulation(contact) })
    }
    view.deleteElement = {
      guard model.selectionSession.id == selectionID else { return }
      model.deleteElement(reference)
    }
    view.updateStyle = { update in
      guard model.selectionSession.id == selectionID else { return }
      model.setGraphicStyle(reference: reference, update: update)
    }
    view.editElement = {
      guard model.selectionSession.id == selectionID else { return }
      model.editSelectedElement(reference)
    }
    let id: String
    switch reference { case .page(_, let value), .spatial(_, let value): id = value }
    let order = model.completeElementOrder(reference)
    var menus: [UIMenuElement] = [UIMenu(options: .displayInline, children: [
      UIAction(title: "На задний план", image: UIImage(systemName:"square.3.layers.3d.bottom.filled"),
        attributes: order?.first == id ? .disabled : []) { _ in
          guard model.selectionSession.id == selectionID else { return }
          model.arrangeElement(reference, front: false)
        },
      UIAction(title: "На передний план", image: UIImage(systemName:"square.3.layers.3d.top.filled"),
        attributes: order?.last == id ? .disabled : []) { _ in
          guard model.selectionSession.id == selectionID else { return }
          model.arrangeElement(reference, front: true)
        }
    ])]
    if graphic.flatMap(NotebookGraphicGeometry.polygon) != nil {
      let titles = ["Размер и положение", "Изменить вершины", "Скруглить углы"]
      let symbols = ["arrow.up.left.and.arrow.down.right", "point.topleft.down.to.point.bottomright.curvepath", "rectangle.roundedtop"]
      menus.insert(UIMenu(title:"Геометрия",options:.displayInline,children:NotebookSelectionSession.GeometryMode.allCases.enumerated().map { index, mode in
        UIAction(title:titles[index],image:UIImage(systemName:symbols[index]),state:model.selectionSession.geometryMode == mode ? .on : .off) { _ in
          guard model.selectionSession.id == selectionID else { return }
          model.setElementGeometryMode(mode,reference:reference)
        }
      }),at:0)
    }
    if let connection = model.graphicElement(reference)?.connection {
      for terminal in NotebookGraphicConnection.Terminal.allCases {
        menus.append(UIMenu(title: terminal == .start ? "Начало линии" : "Конец линии", image:UIImage(systemName:"arrow.up.right"),
          children: NotebookGraphicConnection.Arrowhead.allCases.map { head in
            let labels: [NotebookGraphicConnection.Arrowhead:String] = [.none:"Нет",.arrow:"Стрелка",.triangle:"Треугольник",.square:"Квадрат",.dot:"Круг",.pipe:"Черта",.diamond:"Ромб",.inverted:"Обратная стрелка",.bar:"Полоса"]
            let current = terminal == .start ? connection.startArrowhead : connection.endArrowhead
            return UIAction(title:labels[head]!,state:current == head ? .on : .off) { _ in
              guard model.selectionSession.id == selectionID else { return }
              model.setGraphicArrowhead(head,terminal:terminal,reference:reference)
            }
          }))
      }
    }
    menus.append(UIMenu(options:.displayInline,children:[UIAction(title:"Удалить",image:UIImage(systemName:"trash"),attributes:.destructive) { _ in
      guard model.selectionSession.id == selectionID else { return }; model.deleteElement(reference)
    }]))
    view.moreMenu = UIMenu(children: menus)
  }

  static func dismantleUIView(_ view: NotebookElementControlsView, coordinator: ()) { view.uninstall() }
}

private enum ElementHandle: Hashable {
  case corner(NotebookElementResizeHandle), start, end, bend, vertex(Int), rounding
  var kind: NotebookElementManipulation.Kind {
    switch self { case .corner(let value): .resize(value); case .start: .endpoint(.start); case .end: .endpoint(.end); case .bend: .bend; case .vertex(let index): .vertex(index); case .rounding: .roundCorners }
  }
  var label: String {
    switch self {
    case .corner(let value): "Изменить размер за " + value.label
    case .start: "Начало связи"
    case .end: "Конец связи"
    case .bend: "Изгиб связи"
    case .vertex(let index): "Вершина \(index+1)"
    case .rounding: "Радиус углов"
    }
  }
  var identifier: String {
    switch self { case .corner(let value): "resize-agent-element-" + value.rawValue
    case .start: "graphic-start-handle"; case .end: "graphic-end-handle"; case .bend: "graphic-bend-handle"
    case .vertex(let index): "graphic-vertex-\(index)"; case .rounding: "graphic-corner-radius-handle" }
  }
}

final class NotebookElementControlsView: UIControl, UIGestureRecognizerDelegate {
  private let gate: NotebookInputGate
  private let source = UUID()
  private let pan = ElementHandlePan()
  private weak var installedWindow: UIWindow?
  private var selectionID: UUID?
  private var frameRect = CGRect.zero
  private var contact: SceneSelectionLift?
  private var pointingHandle: ElementHandle?
  private var pencilRevision: UInt64?
  private var contactOrigin = CGPoint.zero
  private let toolbar = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
  private let toolbarStack = UIStackView()
  private let divider = UIView()
  private let deleteButton = UIButton(type: .system)
  private let styleButton = UIButton(type: .system)
  private let editButton = UIButton(type: .system)
  private let moreButton = UIButton(type: .system)
  private var palette: NotebookElementStyleController?
  var graphic: NotebookGraphic? {
    didSet {
      styleButton.isHidden = graphic == nil; divider.isHidden = graphic == nil
      editButton.accessibilityLabel = graphic == nil ? "Редактировать элемент" : "Подпись фигуры"
      if let graphic { palette?.configure(style: graphic.style) }
      setNeedsLayout()
    }
  }
  var moreMenu: UIMenu? { didSet { moreButton.menu = moreMenu } }
  var updateStyle: ((inout NotebookGraphic.Style) -> Void) -> Void = { _ in }
  var editElement: (() -> Void)?
  private var handleAccessibility: [ElementHandleAccessibility] = []
  private var handles = NotebookElementResizeHandle.allCases.map(ElementHandle.corner)
  private var connectionLayout: NotebookGraphicLayout?
  private var projectionScale = 1.0
  private var hasLabel = false
  private var geometryMode: NotebookSelectionSession.GeometryMode = .transform
  var beginManipulation: ((NotebookElementManipulation.Kind) -> SceneSelectionLift?)?
  var deleteElement: (() -> Void)?

  init(gate: NotebookInputGate) {
    self.gate = gate
    super.init(frame: .zero)
    backgroundColor = .clear; isOpaque = false
    toolbar.cornerConfiguration = .capsule()
    toolbarStack.axis = .horizontal; toolbarStack.alignment = .center; toolbarStack.spacing = 2
    toolbarStack.translatesAutoresizingMaskIntoConstraints = false
    toolbar.contentView.addSubview(toolbarStack); addSubview(toolbar)
    NSLayoutConstraint.activate([toolbarStack.leadingAnchor.constraint(equalTo:toolbar.contentView.leadingAnchor,constant:8),
      toolbarStack.trailingAnchor.constraint(equalTo:toolbar.contentView.trailingAnchor,constant:-8),
      toolbarStack.topAnchor.constraint(equalTo:toolbar.contentView.topAnchor,constant:4),
      toolbarStack.bottomAnchor.constraint(equalTo:toolbar.contentView.bottomAnchor,constant:-4)])
    let buttons: [(UIButton,String,String,String)] = [
      (styleButton,"paintbrush.pointed","Оформление фигуры","graphic-style-menu"),
      (editButton,"character.cursor.ibeam","Подпись фигуры","edit-agent-element"),
      (deleteButton,"trash","Удалить элемент","delete-agent-element"),
      (moreButton,"ellipsis","Действия с элементом","element-actions-menu")]
    for (button, symbol, label, identifier) in buttons {
      button.setImage(UIImage(systemName:symbol,withConfiguration:UIImage.SymbolConfiguration(pointSize:20,weight:.regular)),for:.normal)
      button.tintColor = button === deleteButton ? .systemRed : .label
      button.accessibilityLabel = label; button.accessibilityIdentifier = identifier
      button.widthAnchor.constraint(equalToConstant:44).isActive = true; button.heightAnchor.constraint(equalToConstant:44).isActive = true
      toolbarStack.addArrangedSubview(button)
      if button === styleButton {
        divider.backgroundColor = .separator; divider.widthAnchor.constraint(equalToConstant:0.5).isActive = true
        divider.heightAnchor.constraint(equalToConstant:24).isActive = true; toolbarStack.addArrangedSubview(divider)
      }
    }
    deleteButton.addTarget(self,action:#selector(removeElement),for:.touchUpInside)
    editButton.addTarget(self,action:#selector(edit),for:.touchUpInside)
    styleButton.addTarget(self,action:#selector(showStyle),for:.touchUpInside)
    moreButton.showsMenuAsPrimaryAction = true
    rebuildAccessibility()
    pan.minimumNumberOfTouches = 1; pan.maximumNumberOfTouches = 1
    pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
    pan.delegate = self; pan.addTarget(self, action: #selector(resizeChanged))
    pan.onReset = { [weak self] in self?.cancel() }
  }
  private func rebuildAccessibility() {
    handleAccessibility = handles.map { handle in
      let item = ElementHandleAccessibility(accessibilityContainer: self)
      item.accessibilityLabel = handle.label
      item.accessibilityIdentifier = handle.identifier
      item.accessibilityTraits = .adjustable
      item.adjust = { [weak self] increase in
        guard let self, let contact = beginManipulation?(handle.kind) else { return }
        let amount: CGFloat = increase ? 20 : -20
        if case .corner(let corner) = handle {
          contact.end(.init(x: corner.changesWidth ? (corner.leading ? -amount : amount) : 0, y: corner.changesHeight ? (corner.top ? -amount : amount) : 0))
        } else { contact.end(.init(x:handle == .bend ? 0 : amount,y:amount)) }
      }
      return item
    }
    accessibilityElements = [styleButton,editButton,deleteButton,moreButton] + handleAccessibility
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(selectionID: UUID, frame: CGRect, layout: NotebookGraphicLayout? = nil, scale: Double = 1, hasLabel: Bool = false, mode: NotebookSelectionSession.GeometryMode = .transform, manipulating: Bool = false) {
    if self.selectionID != selectionID { cancel(); dismissPalette(); self.selectionID = selectionID }
    let vertices = graphic.flatMap(NotebookGraphicGeometry.polygon)
    geometryMode = vertices == nil ? .transform : mode
    let next: [ElementHandle]
    if layout != nil { next = [.start,.end,.bend] }
    else if geometryMode == .vertices, let vertices { next = vertices.indices.map(ElementHandle.vertex) }
    else if geometryMode == .rounding { next = [.rounding] }
    else { next = NotebookElementResizeHandle.visible(in: frame.size).map(ElementHandle.corner) }
    if handles != next { handles = next; rebuildAccessibility() }
    connectionLayout = layout; projectionScale = scale; self.hasLabel = hasLabel
    frameRect = frame; toolbar.isHidden = manipulating
    setNeedsLayout(); setNeedsDisplay()
  }
  override func didMoveToWindow() {
    super.didMoveToWindow(); uninstall()
    guard let window else { return }
    installedWindow = window; window.addGestureRecognizer(pan)
    gate.registerControlRegion(source: source) { [weak self] point, kind in
      guard let self, let window = installedWindow, !isHidden else { return false }
      let local = convert(point, from: window)
      // Dismissing a modal palette is native UI input too. The window's scene
      // recognizer must not also select the paper beneath that same contact.
      if palette != nil { return true }
      return (!toolbar.isHidden && toolbar.frame.contains(local)) || (kind == .finger && handle(at: local) != nil)
    }
    gate.registerFingerCancellation(source: source) { [weak self] in
      self?.cancel(); self?.pan.isEnabled = false; self?.pan.isEnabled = true
    }
  }
  func uninstall() {
    cancel(); dismissPalette(); installedWindow?.removeGestureRecognizer(pan); installedWindow = nil
    gate.unregisterControlRegion(source: source); gate.unregisterFingerCancellation(source: source)
  }
  override func layoutSubviews() {
    super.layoutSubviews()
    let width = min(bounds.width - 24, graphic == nil ? 152 : 200.5), height = 52.0
    let usable = bounds.inset(by: .init(top:max(12,safeAreaInsets.top + 76),left:12,
      bottom:max(12,safeAreaInsets.bottom + 76),right:12))
    let x = min(max(usable.minX,frameRect.midX-width/2),max(usable.minX,usable.maxX-width))
    let candidates = [frameRect.minY - height - 30, frameRect.maxY + 30, usable.minY, usable.maxY-height]
      .map { CGRect(x:x,y:min(max(usable.minY,$0),max(usable.minY,usable.maxY-height)),width:width,height:height) }
    toolbar.frame = candidates.first { candidate in
      !candidate.intersects(frameRect) && handles.allSatisfy { !hitFrame($0).intersects(candidate) }
    } ?? candidates.first { candidate in handles.allSatisfy { !hitFrame($0).intersects(candidate) } } ?? candidates[0]
    for (index, handle) in handles.enumerated() {
      handleAccessibility[index].accessibilityFrameInContainerSpace = hitFrame(handle)
    }
  }
  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    guard bounds.contains(point) else { return false }
    let control = !toolbar.isHidden && toolbar.frame.contains(point)
    if event?.allTouches?.contains(where: { $0.type == .pencil }) == true { return control }
    return control || handle(at: point) != nil
  }
  private func point(_ handle: ElementHandle) -> CGPoint {
    if case .corner(let corner) = handle { return corner.point(in:frameRect) }
    if case .vertex(let index) = handle, let vertices = graphic.flatMap(NotebookGraphicGeometry.polygon), vertices.indices.contains(index) {
      return .init(x:frameRect.minX+vertices[index].x*frameRect.width,y:frameRect.minY+vertices[index].y*frameRect.height)
    }
    if handle == .rounding, let graphic {
      let width = frameRect.width/projectionScale, height = frameRect.height/projectionScale
      if let corner = NotebookGraphicGeometry.corners(graphic,width:width,height:height).first {
        let radius = min(graphic.cornerRadius ?? 0,NotebookGraphicGeometry.maximumCornerRadius(graphic,width:width,height:height))
        let distance = 18 + radius/corner.sine*projectionScale
        return .init(x:frameRect.minX+corner.vertex.x*projectionScale+corner.bisector.x*distance,
          y:frameRect.minY+corner.vertex.y*projectionScale+corner.bisector.y*distance)
      }
    }
    guard let layout = connectionLayout else { return .zero }
    let point = handle == .start ? layout.start : handle == .end ? layout.end : layout.bend
    let dx = layout.end.x-layout.start.x, dy = layout.end.y-layout.start.y, length = max(0.001,hypot(dx,dy))
    let offset = handle == .bend && hasLabel ? 30.0 : 0
    return .init(x:frameRect.minX+point.x*projectionScale+dy/length*offset,
      y:frameRect.minY+point.y*projectionScale-dx/length*offset)
  }
  private func hitFrame(_ handle: ElementHandle) -> CGRect {
    let point = point(handle)
    return .init(x: point.x - 22, y: point.y - 22, width: 44, height: 44)
  }
  private func handle(at point: CGPoint) -> ElementHandle? {
    // Small objects can have overlapping touch targets. The nearest handle
    // stays reachable instead of always picking the first one.
    guard let handle = handles.filter({ hitFrame($0).contains(point) }).min(by: {
      let a = self.point($0), b = self.point($1)
      return hypot(a.x - point.x, a.y - point.y) < hypot(b.x - point.x, b.y - point.y)
    }) else { return nil }
    // An overlapping 44-point target must not consume the whole small figure.
    // Its center competes with handles so the ordinary body-drag owner remains
    // reachable; the visible handle and its outward touch area still resize.
    if connectionLayout == nil, frameRect.contains(point) {
      let position = self.point(handle)
      if hypot(point.x-frameRect.midX,point.y-frameRect.midY) < hypot(point.x-position.x,point.y-position.y) { return nil }
    }
    return handle
  }
  override func draw(_ rect: CGRect) {
    tintColor.withAlphaComponent(0.7).setStroke()
    if connectionLayout == nil {
      let outline: UIBezierPath
      if geometryMode != .transform, let vertices = graphic.flatMap(NotebookGraphicGeometry.polygon) {
        outline = UIBezierPath()
        for (index,p) in vertices.enumerated() {
          let point = CGPoint(x:frameRect.minX+p.x*frameRect.width,y:frameRect.minY+p.y*frameRect.height)
          if index == 0 { outline.move(to:point) } else { outline.addLine(to:point) }
        }
        outline.close(); outline.setLineDash([3,3],count:2,phase:0)
      } else { outline = UIBezierPath(rect:frameRect) }
      outline.lineWidth = 1; outline.stroke()
    }
    for handle in handles {
      guard case .corner(let corner) = handle else {
        let point = point(handle)
        UIColor.systemBackground.setFill()
        let circle = UIBezierPath(ovalIn:.init(x:point.x-6,y:point.y-6,width:12,height:12))
        circle.lineWidth = 2; circle.fill(); circle.stroke(); continue
      }
      let point = corner.point(in: frameRect)
      let rect: CGRect
      if corner.isCorner { rect = .init(x:point.x-5,y:point.y-5,width:10,height:10) }
      else if corner.changesWidth { rect = .init(x:point.x-3,y:point.y-9,width:6,height:18) }
      else { rect = .init(x:point.x-9,y:point.y-3,width:18,height:6) }
      let path = UIBezierPath(roundedRect:rect,cornerRadius:corner.isCorner ? 5 : 3)
      tintColor.setFill(); UIColor.systemBackground.setStroke()
      path.lineWidth = 1.5; path.fill(); path.stroke()

    }
  }
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    guard touch.type == .direct else { return false }
    if pointingHandle != nil { return true }
    guard installedWindow != nil, gate.permitsNewContact,
      let revision = gate.beginFingerSequence(),
      touch.view === self, let handle = handle(at: touch.location(in: self)) else { return false }
    pencilRevision = revision
    contactOrigin = touch.location(in: installedWindow)
    pointingHandle = handle
    return true
  }
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
  @objc private func resizeChanged() {
    guard let revision = pencilRevision, gate.acceptsFingerSequence(revision) else { cancel(); return }
    if pan.state == .began, let handle = pointingHandle { contact = beginManipulation?(handle.kind) }
    guard let contact else { if pan.state != .possible { cancel() }; return }
    let point = pan.location(in: installedWindow)
    let delta = CGPoint(x: point.x - contactOrigin.x, y: point.y - contactOrigin.y)
    switch pan.state {
    case .began, .changed: contact.change(.init(x: delta.x, y: delta.y))
    case .ended:
      self.contact = nil; pencilRevision = nil; pointingHandle = nil
      contact.end(.init(x: delta.x, y: delta.y))
    case .cancelled, .failed: cancel()
    default: break
    }
  }
  private func cancel() { let old = contact; contact = nil; pencilRevision = nil; pointingHandle = nil; old?.cancel() }
  @objc private func removeElement() { dismissPalette(); deleteElement?() }
  @objc private func edit() { dismissPalette(); editElement?() }
  private func dismissPalette() { palette?.dismiss(animated:false); palette = nil }
  @objc private func showStyle() {
    guard let graphic, palette == nil else { return }
    var responder: UIResponder? = self
    while responder != nil && !(responder is UIViewController) { responder = responder?.next }
    guard let owner = responder as? UIViewController else { return }
    let controller = NotebookElementStyleController(graphic:graphic)
    controller.updateStyle = { [weak self] update in self?.updateStyle(update) }
    controller.onDismiss = { [weak self, weak controller] in
      if self?.palette === controller { self?.palette = nil }
    }
    // Anchor around the selection, not just the small button: the system must
    // leave the edited geometry visible while the person chooses its colour.
    controller.popoverPresentationController?.sourceView = self
    controller.popoverPresentationController?.sourceRect = frameRect.union(toolbar.frame)
    controller.popoverPresentationController?.permittedArrowDirections = .any
    palette = controller; owner.present(controller,animated:true)
  }
}

private final class ElementHandlePan: UIPanGestureRecognizer {
  var onReset: (() -> Void)?
  override func reset() { super.reset(); onReset?() }
}

private final class ElementHandleAccessibility: UIAccessibilityElement {
  var adjust: ((Bool) -> Void)?
  override func accessibilityIncrement() { adjust?(true) }
  override func accessibilityDecrement() { adjust?(false) }
}

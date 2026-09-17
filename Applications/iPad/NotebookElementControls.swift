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
        vertices:graphic.vertices))
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
    view.configure(selectionID: selectionID, frame: frame, layout: model.graphicElement(reference)?.connection == nil ? nil : model.graphicLayout(reference), scale:scale,
      hasLabel: !(model.graphicElement(reference)?.label.isEmpty ?? true))
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
    if let graphic = model.graphicElement(reference) {
      var menus: [UIMenuElement] = []
      let colors: [(String,SpatialInkColor)] = [("Чёрный",.black),("Синий",.init(red:0.1,green:0.3,blue:0.85)),
        ("Красный",.init(red:0.85,green:0.15,blue:0.15)),("Зелёный",.init(red:0.1,green:0.6,blue:0.35))]
      menus.append(UIMenu(title:"Цвет",children:colors.map { name,color in
        UIAction(title:name,state:graphic.style.stroke == color ? .on : .off) { _ in
          guard model.selectionSession.id == selectionID else { return }
          model.setGraphicStyle(reference:reference) { $0.stroke = color }
        }
      }))
      menus.append(UIMenu(title:"Толщина",children:[1.0,2.0,4.0,8.0].map { width in
        UIAction(title:String(Int(width)),state:graphic.style.strokeWidth == width ? .on : .off) { _ in
          guard model.selectionSession.id == selectionID else { return }
          model.setGraphicStyle(reference:reference) { $0.strokeWidth = width }
        }
      }))
      let dashes: [(String,NotebookGraphic.Style.Dash)] = [("Сплошная",.solid),("Пунктир",.dashed),("Точки",.dotted)]
      menus.append(UIMenu(title:"Линия",children:dashes.map { name,dash in
        UIAction(title:name,state:(graphic.style.dash ?? .solid) == dash ? .on : .off) { _ in
          guard model.selectionSession.id == selectionID else { return }
          model.setGraphicStyle(reference:reference) { $0.dash = dash }
        }
      }))
      if let connection = graphic.connection {
        for terminal in NotebookGraphicConnection.Terminal.allCases {
          menus.append(UIMenu(title:terminal == .start ? "Начало" : "Конец",children:NotebookGraphicConnection.Arrowhead.allCases.map { head in
            let labels: [NotebookGraphicConnection.Arrowhead:String] = [.none:"Нет",.arrow:"Стрелка",.triangle:"Треугольник",.square:"Квадрат",.dot:"Круг",.pipe:"Черта",.diamond:"Ромб",.inverted:"Обратная стрелка",.bar:"Полоса"]
            let current = terminal == .start ? connection.startArrowhead : connection.endArrowhead
            return UIAction(title:labels[head]!,state:current == head ? .on : .off) { _ in
              guard model.selectionSession.id == selectionID else { return }
              model.setGraphicArrowhead(head,terminal:terminal,reference:reference)
            }
          }))
        }
      }
      view.styleMenu = UIMenu(children:menus)
    } else { view.styleMenu = nil }
  }
  static func dismantleUIView(_ view: NotebookElementControlsView, coordinator: ()) { view.uninstall() }
}

private enum ElementHandle: Hashable {
  case corner(NotebookElementResizeHandle), start, end, bend
  var kind: NotebookElementManipulation.Kind {
    switch self { case .corner(let value): .resize(value); case .start: .endpoint(.start); case .end: .endpoint(.end); case .bend: .bend }
  }
  var label: String {
    switch self {
    case .corner(let value): "Изменить размер за " + value.label
    case .start: "Начало связи"
    case .end: "Конец связи"
    case .bend: "Изгиб связи"
    }
  }
  var identifier: String {
    switch self { case .corner(let value): "resize-agent-element-" + value.rawValue
    case .start: "graphic-start-handle"; case .end: "graphic-end-handle"; case .bend: "graphic-bend-handle" }
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
  private var pencilRevision: UInt64?
  private var contactOrigin = CGPoint.zero
  private let deleteButton = UIButton(type: .system)
  private let styleButton = UIButton(type: .system)
  var styleMenu: UIMenu? { didSet { styleButton.menu = styleMenu; setNeedsLayout() } }
  private var handleAccessibility: [ElementHandleAccessibility] = []
  private var handles = NotebookElementResizeHandle.allCases.map(ElementHandle.corner)
  private var connectionLayout: NotebookGraphicLayout?
  private var projectionScale = 1.0
  private var hasLabel = false
  var beginManipulation: ((NotebookElementManipulation.Kind) -> SceneSelectionLift?)?
  var deleteElement: (() -> Void)?

  init(gate: NotebookInputGate) {
    self.gate = gate
    super.init(frame: .zero)
    backgroundColor = .clear; isOpaque = false
    deleteButton.setImage(UIImage(systemName: "trash"), for: .normal)
    deleteButton.tintColor = .label
    deleteButton.backgroundColor = .secondarySystemBackground.withAlphaComponent(0.9)
    deleteButton.layer.cornerRadius = 22
    deleteButton.accessibilityLabel = "Удалить элемент"
    deleteButton.accessibilityIdentifier = "delete-agent-element"
    deleteButton.addTarget(self, action: #selector(removeElement), for: .touchUpInside)
    addSubview(deleteButton)
    styleButton.setImage(UIImage(systemName:"slider.horizontal.3"),for:.normal)
    styleButton.tintColor = .label; styleButton.backgroundColor = .secondarySystemBackground.withAlphaComponent(0.9)
    styleButton.layer.cornerRadius = 22; styleButton.showsMenuAsPrimaryAction = true
    styleButton.accessibilityLabel = "Оформление фигуры"; styleButton.accessibilityIdentifier = "graphic-style-menu"
    addSubview(styleButton)
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
    accessibilityElements = [deleteButton,styleButton] + handleAccessibility
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(selectionID: UUID, frame: CGRect, layout: NotebookGraphicLayout? = nil, scale: Double = 1, hasLabel: Bool = false) {
    if self.selectionID != selectionID { cancel(); self.selectionID = selectionID }
    let next: [ElementHandle] = layout == nil ? NotebookElementResizeHandle.allCases.map(ElementHandle.corner) : [.start,.end,.bend]
    if handles != next { handles = next; rebuildAccessibility() }
    connectionLayout = layout; projectionScale = scale; self.hasLabel = hasLabel
    frameRect = frame; setNeedsLayout(); setNeedsDisplay()
  }
  override func didMoveToWindow() {
    super.didMoveToWindow(); uninstall()
    guard let window else { return }
    installedWindow = window; window.addGestureRecognizer(pan)
    gate.registerControlRegion(source: source) { [weak self] point, kind in
      guard let self, let window = installedWindow, !isHidden else { return false }
      let local = convert(point, from: window)
      return (!deleteButton.isHidden && deleteButton.frame.contains(local)) || (!styleButton.isHidden && styleButton.frame.contains(local))
        || (kind == .finger && handle(at: local) != nil)
    }
    gate.registerFingerCancellation(source: source) { [weak self] in
      self?.cancel(); self?.pan.isEnabled = false; self?.pan.isEnabled = true
    }
  }
  func uninstall() {
    cancel(); installedWindow?.removeGestureRecognizer(pan); installedWindow = nil
    gate.unregisterControlRegion(source: source); gate.unregisterFingerCancellation(source: source)
  }
  override func layoutSubviews() {
    super.layoutSubviews()
    let candidates = [
      CGPoint(x: frameRect.maxX - 22, y: frameRect.minY - 72),
      CGPoint(x: frameRect.maxX - 22, y: frameRect.maxY + 28),
      CGPoint(x: frameRect.midX - 22, y: frameRect.minY + 28),
      CGPoint(x: frameRect.maxX + 28, y: frameRect.midY - 22),
      CGPoint(x: frameRect.minX - 72, y: frameRect.midY - 22)
    ].map { point in
      CGRect(x: min(max(0, point.x), max(0, bounds.width - 44)),
        y: min(max(0, point.y), max(0, bounds.height - 44)), width: 44, height: 44)
    }
    // Near a screen edge the delete action must not cover a resize corner.
    let available = candidates.first { candidate in
      handles.allSatisfy { !hitFrame($0).intersects(candidate) }
    }
    deleteButton.isHidden = available == nil
    deleteButton.frame = available ?? .zero
    let styleFrame = styleMenu == nil ? nil : candidates.first { candidate in
      !candidate.intersects(deleteButton.frame) && handles.allSatisfy { !hitFrame($0).intersects(candidate) }
    }
    styleButton.isHidden = styleFrame == nil; styleButton.frame = styleFrame ?? .zero
    for (index, handle) in handles.enumerated() {
      handleAccessibility[index].accessibilityFrameInContainerSpace = hitFrame(handle)
    }
  }
  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    guard bounds.contains(point) else { return false }
    let control = (!deleteButton.isHidden && deleteButton.frame.contains(point)) || (!styleButton.isHidden && styleButton.frame.contains(point))
    if event?.allTouches?.contains(where: { $0.type == .pencil }) == true { return control }
    return control || handle(at: point) != nil
  }
  private func point(_ handle: ElementHandle) -> CGPoint {
    if case .corner(let corner) = handle { return corner.point(in:frameRect) }
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
      let outline = UIBezierPath(rect: frameRect); outline.lineWidth = 1; outline.stroke()
    }
    for handle in handles {
      guard case .corner(let corner) = handle else {
        let point = point(handle)
        UIColor.systemBackground.setFill()
        let circle = UIBezierPath(ovalIn:.init(x:point.x-6,y:point.y-6,width:12,height:12))
        circle.lineWidth = 2; circle.fill(); circle.stroke(); continue
      }
      let point = corner.point(in: frameRect)
      UIColor.systemBackground.setFill()
      let path = UIBezierPath(roundedRect:.init(x:point.x-4,y:point.y-4,width:8,height:8),cornerRadius:1)
      path.lineWidth = 1.5; path.fill(); path.stroke()
    }
  }
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    guard touch.type == .direct else { return false }
    if contact != nil { return true }
    guard installedWindow != nil, gate.permitsNewContact,
      let revision = gate.beginFingerSequence(),
      touch.view === self, let handle = handle(at: touch.location(in: self)) else { return false }
    pencilRevision = revision
    contactOrigin = touch.location(in: installedWindow)
    contact = beginManipulation?(handle.kind)
    return contact != nil
  }
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
  @objc private func resizeChanged() {
    guard let contact, let revision = pencilRevision, gate.acceptsFingerSequence(revision) else { cancel(); return }
    let point = pan.location(in: installedWindow)
    let delta = CGPoint(x: point.x - contactOrigin.x, y: point.y - contactOrigin.y)
    switch pan.state {
    case .began, .changed: contact.change(.init(x: delta.x, y: delta.y))
    case .ended:
      self.contact = nil; pencilRevision = nil
      contact.end(.init(x: delta.x, y: delta.y))
    case .cancelled, .failed: cancel()
    default: break
    }
  }
  private func cancel() { let old = contact; contact = nil; pencilRevision = nil; old?.cancel() }
  @objc private func removeElement() { deleteElement?() }
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

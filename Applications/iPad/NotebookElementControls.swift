import NotebookCore
import SwiftUI
import UIKit

/// One screen-space frame for the selected physical element. Its four corners
/// retain 44-point touch targets; neither paper zoom nor a portal duplicates them.
struct NotebookElementControls: UIViewRepresentable {
  @Environment(NotebookAppModel.self) private var model
  let reference: EditableElementReference
  let selectionID: UUID
  let frame: CGRect
  let scale: Double

  func makeUIView(context: Context) -> NotebookElementControlsView { .init(gate: model.inputGate) }
  func updateUIView(_ view: NotebookElementControlsView, context: Context) {
    view.configure(selectionID: selectionID, frame: frame)
    view.beginResize = { corner in
      guard model.selectionSession.id == selectionID,
        let contact = model.beginElementManipulation(reference, kind: .resize(corner)) else { return nil }
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
  }
  static func dismantleUIView(_ view: NotebookElementControlsView, coordinator: ()) { view.uninstall() }
}

final class NotebookElementControlsView: UIControl, UIGestureRecognizerDelegate {
  private let gate: NotebookInputGate
  private let source = UUID()
  private let pan = ElementCornerPan()
  private weak var installedWindow: UIWindow?
  private var selectionID: UUID?
  private var frameRect = CGRect.zero
  private var contact: SceneSelectionLift?
  private var pencilRevision: UInt64?
  private var contactOrigin = CGPoint.zero
  private let deleteButton = UIButton(type: .system)
  private var corners: [ElementCornerAccessibility] = []
  var beginResize: ((NotebookElementCorner) -> SceneSelectionLift?)?
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
    corners = NotebookElementCorner.allCases.map { corner in
      let item = ElementCornerAccessibility(accessibilityContainer: self)
      item.accessibilityLabel = "Изменить размер за " + corner.label + " угол"
      item.accessibilityIdentifier = "resize-agent-element-" + corner.rawValue
      item.accessibilityTraits = .adjustable
      item.adjust = { [weak self] increase in
        guard let self, let contact = beginResize?(corner) else { return }
        let amount: CGFloat = increase ? 20 : -20
        contact.end(.init(x: corner.leading ? -amount : amount, y: corner.top ? -amount : amount))
      }
      return item
    }
    accessibilityElements = [deleteButton] + corners
    pan.minimumNumberOfTouches = 1; pan.maximumNumberOfTouches = 1
    pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
    pan.delegate = self; pan.addTarget(self, action: #selector(resizeChanged))
    pan.onReset = { [weak self] in self?.cancel() }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(selectionID: UUID, frame: CGRect) {
    if self.selectionID != selectionID { cancel(); self.selectionID = selectionID }
    frameRect = frame; setNeedsLayout(); setNeedsDisplay()
  }
  override func didMoveToWindow() {
    super.didMoveToWindow(); uninstall()
    guard let window else { return }
    installedWindow = window; window.addGestureRecognizer(pan)
    gate.registerControlRegion(source: source) { [weak self] point, kind in
      guard let self, let window = installedWindow, !isHidden else { return false }
      let local = convert(point, from: window)
      return (!deleteButton.isHidden && deleteButton.frame.contains(local)) || (kind == .finger && corner(at: local) != nil)
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
      NotebookElementCorner.allCases.allSatisfy { !hitFrame($0).intersects(candidate) }
    }
    deleteButton.isHidden = available == nil
    deleteButton.frame = available ?? .zero
    for (index, corner) in NotebookElementCorner.allCases.enumerated() {
      corners[index].accessibilityFrameInContainerSpace = hitFrame(corner)
    }
  }
  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    guard bounds.contains(point) else { return false }
    if event?.allTouches?.contains(where: { $0.type == .pencil }) == true { return deleteButton.frame.contains(point) }
    return deleteButton.frame.contains(point) || corner(at: point) != nil
  }
  private func hitFrame(_ corner: NotebookElementCorner) -> CGRect {
    let point = corner.point(in: frameRect)
    return .init(x: point.x - 22, y: point.y - 22, width: 44, height: 44)
  }
  private func corner(at point: CGPoint) -> NotebookElementCorner? {
    // Very small objects can have overlapping touch targets. Nearest corner
    // keeps all four directions reachable instead of picking the first one.
    NotebookElementCorner.allCases.filter { hitFrame($0).contains(point) }.min {
      let a = $0.point(in: frameRect), b = $1.point(in: frameRect)
      return hypot(a.x - point.x, a.y - point.y) < hypot(b.x - point.x, b.y - point.y)
    }
  }
  override func draw(_ rect: CGRect) {
    tintColor.withAlphaComponent(0.7).setStroke()
    let outline = UIBezierPath(rect: frameRect); outline.lineWidth = 1; outline.stroke()
    for corner in NotebookElementCorner.allCases {
      let point = corner.point(in: frameRect), length: CGFloat = min(10, frameRect.width / 3, frameRect.height / 3)
      let path = UIBezierPath()
      path.move(to: .init(x: point.x + (corner.leading ? length : -length), y: point.y))
      path.addLine(to: point)
      path.addLine(to: .init(x: point.x, y: point.y + (corner.top ? length : -length)))
      path.lineWidth = 3; path.lineCapStyle = .round; path.lineJoinStyle = .round; path.stroke()
    }
  }
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    guard touch.type == .direct else { return false }
    if contact != nil { return true }
    guard installedWindow != nil, gate.permitsNewContact,
      let revision = gate.beginFingerSequence(),
      touch.view === self, let corner = corner(at: touch.location(in: self)) else { return false }
    pencilRevision = revision
    contactOrigin = touch.location(in: installedWindow)
    contact = beginResize?(corner)
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

private final class ElementCornerPan: UIPanGestureRecognizer {
  var onReset: (() -> Void)?
  override func reset() { super.reset(); onReset?() }
}

private final class ElementCornerAccessibility: UIAccessibilityElement {
  var adjust: ((Bool) -> Void)?
  override func accessibilityIncrement() { adjust?(true) }
  override func accessibilityDecrement() { adjust?(false) }
}

import AppKit
import NotebookCore
import SwiftUI

struct MacPageInkView: NSViewRepresentable {
  @Environment(NotebookAppModel.self) private var model
  @Environment(\.scenePlaneProjection) private var projection
  let page: PageDocument
  let isInteractive: Bool
  let onReady: (Bool) -> Void
  func makeNSView(context: Context) -> MacPageInkCanvas { .init(model: model, pageID: page.id) }
  func updateNSView(_ view: MacPageInkCanvas, context: Context) {
    view.inkProjection.observe(projection)
    view.update(page: page, enabled: isInteractive && model.macInputTool != .pointer,
      current: isInteractive, onReady: onReady)
  }
  static func dismantleNSView(_ view: MacPageInkCanvas, coordinator: ()) { view.uninstall() }
}

/// Mouse/tablet samples enter the same measured-ink and accepted-write owners
/// as Pencil. This view owns only the active contact and its Metal presentation.
final class MacPageInkCanvas: NSView {
  let ink = InkCanvasView(frame: .zero)
  lazy var inkProjection = PageInkProjection(host: self, canvas: ink)
  private let model: NotebookAppModel
  private let pageID: UUID
  private let source = UUID()
  private var inputEnabled = false
  private var retired = false
  private var sourceData: Data?
  private var suppressed = Set<UUID>()
  private var unpublished = Set<UUID>()
  private var load: Task<Void, Never>?
  private var pendingDeliveries = 0
  private var deliveryOrdinal = 0
  private var latestDelivery: (ordinal: Int, change: PreparedPageInkChange)?
  private var stamp: VersionStamp?
  private var pen: ActiveInkStroke?
  private var eraser: ActiveEraserStroke?
  private var measured: InkSampleRelations.Contact? { pen?.measured ?? eraser?.measured }
  private var actionTool = DrawingTool.pen
  private var actionStyle = PenStyle.standard
  private var elementContact = InkElementContact([])
  private var actionEraserStyle = EraserStyle.standard
  private var startedAt = 0.0
  private var waiters: [NotebookInputCompletion] = []
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { inputEnabled }

  init(model: NotebookAppModel, pageID: UUID) {
    self.model = model; self.pageID = pageID
    super.init(frame: .zero)
    addSubview(ink)
    setAccessibilityIdentifier("paper-input")
    setAccessibilityLabel("Лист")
    model.inputGate.registerPageFinisher(source: source) { [weak self] waits, done in
      guard let self else { done(); return }
      finishStroke()
      if waits && pendingDeliveries > 0 { waiters.append(done) } else { done() }
    }
  }
  required init?(coder: NSCoder) { fatalError("Use init(model:pageID:)") }
  override func layout() { super.layout(); inkProjection.refresh() }
  override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); inkProjection.refresh() }
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard inputEnabled, !retired, load == nil, bounds.contains(convert(point, from: superview)) else { return nil }
    return self
  }

  func update(page: PageDocument, enabled: Bool, current: Bool, onReady: @escaping (Bool) -> Void) {
    guard !retired, page.id == pageID else { return }
    inputEnabled = enabled
    model.inputGate.setCurrentPageSource(source, isCurrent: current)
    ink.onRenderReadinessChange = onReady
    let cuts = model.pageSuppressedInkIDs(page)
    guard stamp == nil, pendingDeliveries == 0, page.drawingData != sourceData || cuts != suppressed else { return }
    sourceData = page.drawingData; suppressed = cuts
    load?.cancel()
    if unpublished.isEmpty { ink.prepareForDrawing() }
    let data = page.drawingData
    load = Task { [weak self] in
      let decoded = await Task.detached(priority: .userInitiated) { try? PageInkDrawing.decode(data) }.value
      guard !Task.isCancelled, let self, !retired, sourceData == data, stamp == nil, pendingDeliveries == 0, let decoded else { return }
      load = nil
      guard unpublished.isSubset(of: Set(decoded.actions.map(\.id))) else { return }
      unpublished.removeAll()
      ink.apply(decoded.presenting(excluding: cuts))
    }
  }

  override func mouseDown(with event: NSEvent) {
    guard inputEnabled, !retired, stamp == nil, load == nil,
      let reserved = model.reserveDrawingAction(pageID: pageID) else { return }
    guard model.inputGate.beginPencilAction(source: source) else {
      model.releaseDrawingReservation(pageID: pageID, stamp: reserved); return
    }
    window?.makeFirstResponder(self)
    stamp = reserved; actionTool = model.drawingTool; actionStyle = model.penStyle
    actionEraserStyle = model.eraserStyle
    elementContact = InkElementContact(actionTool == .eraser ? model.eraserTargets(pageID: pageID) : [])
    startedAt = event.timestamp
    if actionTool == .pen { pen = .init(style:actionStyle) }
    else { let c=actionStyle.color.components;eraser = .init(color:.init(red:c.red,green:c.green,blue:c.blue)) }
    sample(event)
  }
  override func mouseDragged(with event: NSEvent) { if stamp != nil { sample(event) } }
  override func mouseUp(with event: NSEvent) { if stamp != nil { sample(event); finishStroke() } }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 { finishStroke(); model.selectMacInputTool(.pointer) }
    else { super.keyDown(with: event) }
  }
  @objc func undo(_ sender: Any?) { finishStroke(); model.afterPageInput { self.model.undoLastSurfaceAction() } }

  private func sample(_ event: NSEvent) {
    let location = convert(event.locationInWindow, from: nil)
    let clamped = CGPoint(x: min(max(0, location.x), bounds.width), y: min(max(0, location.y), bounds.height))
    if let measured, measured.count > 0 {
      let last=measured.sample(at:measured.count-1).point
      if hypot(last.x-clamped.x,last.y-clamped.y) < 0.2 { return }
    }
    let width = actionTool == .pen ? actionStyle.width : actionEraserStyle.maximumWidth
    let sample=SpatialInkSample(point:.init(x:clamped.x,y:clamped.y),timeOffset:max(0,event.timestamp-startedAt),
      width:width,opacity:1,force:1,azimuth:0,altitude:.pi/2)
    if let pen { pen.replaceMeasuredTail(from:pen.measured.count,with:[sample]);ink.displayActiveStroke(pen) }
    if let eraser {
      let start = eraser.measured.count
      eraser.replaceMeasuredTail(from:start,with:[sample])
      elementContact.update(eraser.measured, from:start)
      ink.displayActiveEraser(eraser)
      let targets = elementContact.selected
      model.updateElementErasing(targets.isEmpty ? [] : [.init(id:eraser.measured.sourceID,
        surface:.page(pageID), samples:eraser.measured.frozen().measurements, targets:targets)], id:eraser.measured.sourceID)
    }
  }

  private func finishStroke() {
    guard let stamp else { return }
    self.stamp = nil
    defer { elementContact = InkElementContact([]); pen = nil; eraser = nil }
    guard let measured, measured.count > 0 else {
      model.releaseDrawingReservation(pageID: pageID, stamp: stamp)
      model.inputGate.endPencilAction(source: source); return
    }
    let measuredAction = measured.frozen().restoredAction()
    let action = PageInkAction(id:measuredAction.id, tool:measuredAction.tool, color:measuredAction.color,
      measurements:measuredAction.samples, elementTargets:elementContact.selected)
    if actionTool == .pen { ink.commitActiveStroke(action) } else { ink.commitActiveEraser(action) }
    unpublished.insert(action.id)
    let accepted = model.acceptDrawingAction(action, pageID: pageID, stamp: stamp)
    pen = nil; eraser = nil
    pendingDeliveries += 1
    deliveryOrdinal += 1
    let ordinal = deliveryOrdinal
    Task { [self] in
      let prepared = await accepted.value
      if let prepared {
        unpublished.remove(action.id)
        if ordinal > (latestDelivery?.ordinal ?? 0) { latestDelivery = (ordinal, prepared) }
      }
      pendingDeliveries -= 1
      guard pendingDeliveries == 0 else { return }
      // A following contact already owns its measured mesh. Delivery installs
      // only the accepted baseline and never gates or discards that contact.
      if let change = latestDelivery?.change, unpublished.isEmpty, !retired {
        sourceData = change.data
        ink.settle(change.drawing.presenting(excluding: suppressed))
      }
      latestDelivery = nil
      let completions = waiters; waiters = []
      for completion in completions { completion() }
    }
    model.inputGate.endPencilAction(source: source)
  }

  func uninstall() {
    guard !retired else { return }
    finishStroke(); retired = true; inputEnabled = false
    inkProjection.stop()
    load?.cancel(); load = nil; ink.onRenderReadinessChange = nil
    model.inputGate.unregisterPageFinisher(source: source)
  }
}

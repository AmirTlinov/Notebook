import AppKit
import NotebookCore
import PencilKit
import SwiftUI

struct MacPageInkView: NSViewRepresentable {
  @Environment(NotebookAppModel.self) private var model
  let page: PageDocument
  let isInteractive: Bool
  let onReady: (Bool) -> Void
  func makeNSView(context: Context) -> MacPageInkCanvas { .init(model: model, pageID: page.id) }
  func updateNSView(_ view: MacPageInkCanvas, context: Context) {
    view.update(page: page, enabled: isInteractive && model.macInputTool != .pointer,
      current: isInteractive, onReady: onReady)
  }
  static func dismantleNSView(_ view: MacPageInkCanvas, coordinator: ()) { view.uninstall() }
}

/// Mouse/tablet samples enter the same measured-ink and accepted-write owners
/// as Pencil. This view owns only the active contact and its Metal presentation.
final class MacPageInkCanvas: NSView {
  let ink = InkCanvasView(frame: .zero)
  private let model: NotebookAppModel
  private let pageID: UUID
  private let source = UUID()
  private var inputEnabled = false
  private var retired = false
  private var sourceData: Data?
  private var suppressed = Set<UUID>()
  private var unpublished = Set<UUID>()
  private var load: Task<Void, Never>?
  private var delivery: Task<Void, Never>?
  private var stamp: VersionStamp?
  private var pen: ActiveInkStroke?
  private var eraser: ActiveEraserStroke?
  private var points: [PKStrokePoint] = []
  private var actionTool = DrawingTool.pen
  private var actionStyle = PenStyle.standard
  private var actionTargets: [InkElementTarget] = []
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
      if waits && delivery != nil { waiters.append(done) } else { done() }
    }
  }
  required init?(coder: NSCoder) { fatalError("Use init(model:pageID:)") }
  override func layout() { super.layout(); ink.frame = bounds }
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard inputEnabled, !retired, delivery == nil, bounds.contains(convert(point, from: superview)) else { return nil }
    return self
  }

  func update(page: PageDocument, enabled: Bool, current: Bool, onReady: @escaping (Bool) -> Void) {
    guard !retired, page.id == pageID else { return }
    inputEnabled = enabled
    model.inputGate.setCurrentPageSource(source, isCurrent: current)
    ink.onRenderReadinessChange = onReady
    let cuts = model.pageSuppressedInkIDs(page)
    guard stamp == nil, delivery == nil, page.drawingData != sourceData || cuts != suppressed else { return }
    sourceData = page.drawingData; suppressed = cuts
    load?.cancel()
    if unpublished.isEmpty { ink.prepareForDrawing() }
    let data = page.drawingData
    load = Task { [weak self] in
      let decoded = await Task.detached(priority: .userInitiated) { try? PageInkDrawing.decode(data) }.value
      guard !Task.isCancelled, let self, !retired, sourceData == data, stamp == nil, delivery == nil, let decoded else { return }
      load = nil
      guard unpublished.isSubset(of: Set(decoded.actions.map(\.id))) else { return }
      unpublished.removeAll()
      ink.apply(decoded.presenting(excluding: cuts))
    }
  }

  override func mouseDown(with event: NSEvent) {
    guard inputEnabled, !retired, stamp == nil, delivery == nil, load == nil,
      let reserved = model.reserveDrawingAction(pageID: pageID) else { return }
    guard model.inputGate.beginPencilAction(source: source) else {
      model.releaseDrawingReservation(pageID: pageID, stamp: reserved); return
    }
    window?.makeFirstResponder(self)
    stamp = reserved; actionTool = model.drawingTool; actionStyle = model.penStyle
    actionTargets = actionTool == .eraser ? model.eraserTargets(pageID: pageID) : []
    startedAt = event.timestamp; points = []
    if actionTool == .pen { pen = .init(style: actionStyle) } else { eraser = .init() }
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
    if let last = points.last, hypot(last.location.x - clamped.x, last.location.y - clamped.y) < 0.2 { return }
    let width = actionTool == .pen ? actionStyle.width : model.eraserStyle.maximumWidth
    let point = PKStrokePoint(location: clamped, timeOffset: max(0, event.timestamp - startedAt),
      size: .init(width: width, height: width), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
    points.append(point)
    if let pen { pen.replaceMeasuredTail(from: points.count - 1, with: [point]); ink.displayActiveStroke(pen) }
    if let eraser { eraser.replaceMeasuredTail(from: points.count - 1, with: [point]); ink.displayActiveEraser(eraser) }
  }

  private func finishStroke() {
    guard let stamp else { return }
    self.stamp = nil
    guard !points.isEmpty else {
      model.releaseDrawingReservation(pageID: pageID, stamp: stamp)
      model.inputGate.endPencilAction(source: source); return
    }
    let color = actionStyle.color.components
    let action = PageInkAction(tool: actionTool == .pen ? .pen : .eraser,
      color: .init(red: color.red, green: color.green, blue: color.blue), points: points).erasingElements(actionTargets)
    if actionTool == .pen { ink.commitActiveStroke() } else { ink.commitActiveEraser() }
    unpublished.insert(action.id)
    let accepted = model.acceptDrawingAction(action, pageID: pageID, stamp: stamp)
    pen = nil; eraser = nil; points = []
    delivery = Task { [self] in
      let prepared = await accepted.value
      if let prepared, !retired {
        unpublished.remove(action.id)
        sourceData = prepared.data
        ink.settle(prepared.drawing.presenting(excluding: suppressed))
      }
      delivery = nil
      let completions = waiters; waiters = []
      for completion in completions { completion() }
    }
    model.inputGate.endPencilAction(source: source)
  }

  func uninstall() {
    guard !retired else { return }
    finishStroke(); retired = true; inputEnabled = false
    load?.cancel(); load = nil; ink.onRenderReadinessChange = nil
    model.inputGate.unregisterPageFinisher(source: source)
  }
}

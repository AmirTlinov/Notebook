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
  private var sourceStamp: VersionStamp?
  private var suppressed = Set<UUID>()
  private var load: Task<Void, Never>?
  private var stamp: VersionStamp?
  private var pen: ActiveInkStroke?
  private var eraser: ActiveEraserStroke?
  private var measured: InkSampleRelations.Contact? { pen?.measured ?? eraser?.measured }
  private var actionTool = DrawingTool.pen
  private var actionStyle = PenStyle.standard
  private var elementContact = InkElementContact([])
  private var pageEraserSource: NotebookPageEraserSource?
  private var elementEraserFailed = false
  private var actionEraserStyle = EraserStyle.standard
  private var startedAt = 0.0
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { inputEnabled }

  init(model: NotebookAppModel, pageID: UUID) {
    self.model = model; self.pageID = pageID
    super.init(frame: .zero)
    addSubview(ink)
    setAccessibilityIdentifier("paper-input")
    setAccessibilityLabel("Лист")
    model.inputGate.registerPageFinisher(source: source) { [weak self] _, done in
      guard let self else { done(); return }
      finishStroke();done()
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
    if let sourceStamp, page.drawingStamp < sourceStamp {
      if cuts != suppressed { suppressed = cuts; ink.setSuppressedPageActions(cuts) }
      return
    }
    guard stamp == nil,page.drawingStamp != sourceStamp || cuts != suppressed else { return }
    sourceStamp=page.drawingStamp;suppressed=cuts
    load?.cancel()
    ink.prepareForDrawing()
    let source=page.inkSource
    load = Task { [weak self] in
      let decoded=await Task.detached(priority:.userInitiated) { try? source.drawing() }.value
      guard !Task.isCancelled,let self,!retired,sourceStamp == source.stamp,stamp == nil,let decoded else { return }
      load = nil
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
    elementContact = InkElementContact([])
    pageEraserSource = actionTool == .eraser ? model.pageEraserSource(pageID:pageID) : nil
    elementEraserFailed = false
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
      if !elementEraserFailed,let source=pageEraserSource,
        let bounds=eraserBounds(eraser.measured,from:start) {
        do {
          let query=try source.query(bounds:bounds)
          elementContact.update(eraser.measured,from:start,
            queried:query.targets,visitedNodes:query.visitedNodes)
        } catch {
          elementEraserFailed=true;elementContact=InkElementContact([])
          model.showCue(error.localizedDescription)
        }
      }
      ink.displayActiveEraser(eraser)
      let targets = elementContact.selected
      model.updateElementErasing(targets.isEmpty ? [] : [.init(id:eraser.measured.sourceID,
        surface:.page(pageID), samples:eraser.measured.frozen().measurements, targets:targets)], id:eraser.measured.sourceID)
    }
  }

  private func eraserBounds(_ source:InkSampleRelations.Contact,from changedIndex:Int)->CGRect? {
    guard source.count>changedIndex else { return nil }
    var bounds=CGRect.null
    let start=max(0,changedIndex-1)
    source.forEach(in:start..<source.count) { sample in
      let radius=sample.width/2
      bounds=bounds.union(.init(x:sample.point.x-radius,y:sample.point.y-radius,
        width:radius*2,height:radius*2))
    }
    return bounds.isNull ? nil : bounds
  }

  private func finishStroke() {
    guard let stamp else { return }
    self.stamp = nil
    defer {
      elementContact=InkElementContact([]);pageEraserSource=nil;elementEraserFailed=false
      pen=nil;eraser=nil
    }
    guard let measured, measured.count > 0 else {
      model.releaseDrawingReservation(pageID: pageID, stamp: stamp)
      model.inputGate.endPencilAction(source: source); return
    }
    let measuredAction = measured.frozen().restoredAction()
    let action = PageInkAction(id:measuredAction.id, tool:measuredAction.tool, color:measuredAction.color,
      measurements:measuredAction.samples, elementTargets:elementContact.selected)
    if actionTool == .pen { ink.commitActiveStroke(action) } else { ink.commitActiveEraser(action) }
    let accepted = model.acceptDrawingAction(action, pageID: pageID, stamp: stamp)
    pen = nil; eraser = nil
    if let accepted,!retired {
      sourceStamp=accepted.stamp
      ink.settle(accepted,suppressedInkIDs:suppressed)
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

import AppKit
import NotebookCore
import SwiftUI
import WebKit

/// A scoped AppKit edge for trackpad/wheel events. It neither watches other
/// windows nor replaces the text responder chain of an active editor.
struct MacCanvasNavigation: NSViewRepresentable {
  let model: NotebookAppModel
  func makeNSView(context: Context) -> MacCanvasNavigationView { .init(model: model) }
  func updateNSView(_ view: MacCanvasNavigationView, context: Context) { view.model = model }
  static func dismantleNSView(_ view: MacCanvasNavigationView, coordinator: ()) { view.uninstall() }
}

final class MacCanvasNavigationView: NSView {
  weak var model: NotebookAppModel?
  private var monitor: Any?
  private var settle: Task<Void, Never>?
  private var drag: (point: CGPoint, presence: SessionPresence)?
  private let source = UUID()
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  init(model: NotebookAppModel) { self.model = model; super.init(frame: .zero) }
  required init?(coder: NSCoder) { fatalError("Use init(model:)") }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    guard window != nil else { finishCamera(); return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
      let consumed = MainActor.assumeIsolated { self?.receive(event) == nil }
      return consumed ? nil : event
    }
  }

  private func receive(_ event: NSEvent) -> NSEvent? {
    guard event.window === window, let window, let model, model.inputGate.permitsNewContact,
      !model.inputGate.hasActivePencil, let p = model.presence else { return event }
    let point = convert(event.locationInWindow, from: nil)
    guard bounds.contains(point) else { return event }
    if event.type == .scrollWheel, !event.modifierFlags.contains(.command) {
      var hit = window.contentView?.hitTest(window.contentView!.convert(event.locationInWindow, from: nil))
      while let view = hit {
        if view is NSTextView || view is NSControl { return event }
        // Explicit editing owns its wheel as well as keyboard input.
        if model.interactiveElementFocus != nil && view is WKWebView { return event }
        hit = view.superview
      }
    }
    settle?.cancel()
    var camera = p.camera
    if event.type == .magnify || event.modifierFlags.contains(.command) {
      let factor = event.type == .magnify ? 1 + event.magnification : exp(event.scrollingDeltaY * 0.006)
      camera = camera.pinched(by: factor, from: .init(x: point.x, y: point.y),
        to: .init(x: point.x, y: point.y), viewport: p.viewport)
    } else {
      let factor = event.hasPreciseScrollingDeltas ? 1.0 : 12.0
      camera.pan(screenX: event.scrollingDeltaX * factor, screenY: event.scrollingDeltaY * factor)
    }
    model.updatePresence(p.replacingCamera(model.macConstrainReading(camera, presence: p)), settled: false)
    settle = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
      self?.finishCamera()
    }
    return nil
  }

  override func mouseDown(with event: NSEvent) {
    guard let model, model.inputGate.permitsNewContact, let presence = model.presence else { return }
    window?.makeFirstResponder(self)
    model.inputGate.notifyAcceptedContact(); model.inputGate.beginContact(source: source)
    drag = (convert(event.locationInWindow, from: nil), presence)
  }
  override func mouseDragged(with event: NSEvent) {
    guard let drag = admittedDrag(), let model else { return }
    let point = convert(event.locationInWindow, from: nil)
    var camera = drag.presence.camera
    camera.pan(screenX: point.x - drag.point.x, screenY: point.y - drag.point.y)
    model.updatePresence(drag.presence.replacingCamera(model.macConstrainReading(camera, presence: drag.presence)), settled: false)
  }
  override func mouseUp(with event: NSEvent) {
    guard let drag = admittedDrag() else { return }
    if hypot(convert(event.locationInWindow, from: nil).x - drag.point.x,
      convert(event.locationInWindow, from: nil).y - drag.point.y) < 3 { model?.clearSelection() }
    self.drag = nil; finishCamera(); model?.inputGate.endContact(source: source)
  }
  private func admittedDrag() -> (point: CGPoint, presence: SessionPresence)? {
    guard let drag else { return nil }
    guard let current = model?.presence,
      drag.presence.replacingCamera(current.camera) == current else {
      // A committed retirement or navigation replaced the semantic owner.
      // Revoke this mouse sequence, not the replacement owner's camera phase.
      self.drag = nil; settle?.cancel(); settle = nil
      model?.inputGate.endContact(source: source)
      return nil
    }
    return drag
  }
  override func keyDown(with event: NSEvent) {
    guard let model else { return }
    switch event.keyCode {
    case 51, 117:
      if let element = model.selectionSession.element { model.deleteElement(element) }
      else if let p = model.presence, let id = model.selectionSession.itemID(on: p.boardID) { Task { await model.deleteItem(id) } }
    case 53: model.clearSelection()
    default: super.keyDown(with: event)
    }
  }
  @objc func undo(_ sender: Any?) { model?.undoLastSurfaceAction() }
  @objc func redo(_ sender: Any?) { model?.redoLastSurfaceAction() }
  private func finishCamera() {
    settle?.cancel(); settle = nil
    if let p = model?.presence, model?.presencePhase == .active { model?.updatePresence(p, settled: true) }
  }
  func uninstall() {
    if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    finishCamera(); model?.inputGate.endContact(source: source); drag = nil; model = nil
  }
  isolated deinit { if let monitor { NSEvent.removeMonitor(monitor) }; settle?.cancel() }
}

extension NotebookAppModel {
  func macReveal(_ location: NotebookReferenceLocation, pageResolution: NotebookReferencePageResolution) {
    guard let reference = requestedReference, let p = presence else { return }
    switch location {
    case .board(let boardID, let center, let region):
      let scale = min(1.5, max(SpatialCamera.minimumScale, min(p.viewport.x / (region.width + 100), p.viewport.y / (region.height + 100))))
      updatePresence(.init(boardID: boardID, mode: .board, camera: .init(center: center, scale: scale), viewport: p.viewport), settled: true)
      completeShow(reference)
    case .item(let boardID, let itemID, let center, let geometry):
      if reference.target.kind != .page { selectItem(itemID) }
      let mode: WorkspaceSemanticMode = reference.target.kind == .page ? .page : reference.target.kind == .document ? .document : .cover
      if mode == .document { prepareDocumentOpening(itemID, pageIndex: reference.pageIndex ?? 0, boardID: boardID, restoreReading: false) }
      updatePresence(.init(boardID: boardID, mode: mode,
        camera: .init(center: center, scale: mode == .cover ? geometry.coverScale(viewport: p.viewport) : geometry.fitScale(viewport: p.viewport)),
        viewport: p.viewport, focusedItemID: itemID, openProgress: mode == .cover ? 0 : 1,
        selectedItemID: itemID, notebookPageID: presence?.notebookPageID), settled: true)
      completeShow(reference)
      if mode == .document {
        let generation = navigationGeneration
        pageResolution.start(requestID: reference.id, documentID: itemID, isCurrent: { [weak self] in
          guard let self else { return false }
          return navigationGeneration == generation && presence?.focusedItemID == itemID && requestedReturn == nil
        }, resolve: { [weak self] in
          guard let document = self?.documents[itemID] else { return nil }
          if let id = reference.elementID {
            return DocumentRenderRegistry.shared.regions(document: document).first(where: { $0.id == id })?.pageIndex
          }
          return reference.pageIndex ?? 0
        }, apply: { [weak self] index in _ = self?.selectDocumentPage(index, documentID: itemID) })
      }
    }
  }
}

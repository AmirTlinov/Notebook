import AppKit
import NotebookCore
import SwiftUI

/// One desktop contact edge above passive material and below explicit controls.
/// Geometry, selection and mutations remain with the shared material owners.
struct MacMaterialInput: NSViewRepresentable {
  let model: NotebookAppModel
  let presence: SessionPresence
  let cohort: SceneCompositionCohort?
  func makeNSView(context: Context) -> MacMaterialInputView { .init(model:model,presence:presence,cohort:cohort) }
  func updateNSView(_ view: MacMaterialInputView, context: Context) {
    view.presence = presence; view.cohort = cohort
  }
  static func dismantleNSView(_ view: MacMaterialInputView, coordinator: ()) { view.cancel() }
}

final class MacMaterialInputView: NSView {
  private let model: NotebookAppModel
  var presence: SessionPresence
  var cohort: SceneCompositionCohort?
  private let source = UUID()
  private var down: (contact:Contact,selectionID:UUID,point:CGPoint,scale:Double)?
  private var manipulation: UUID?
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }

  init(model:NotebookAppModel,presence:SessionPresence,cohort:SceneCompositionCohort?) {
    self.model = model; self.presence = presence; self.cohort = cohort
    super.init(frame:.zero)
    setAccessibilityElement(false)
  }
  required init?(coder: NSCoder) { fatalError("Use init(model:presence:cohort:)") }

  private enum Contact { case element(EditableElementReference), selectedInk(NotebookSelectedInk.Key), pending }
  private func contact(at point:CGPoint) -> Contact? {
    guard bounds.contains(point), model.macInputTool == .pointer,
      model.inputGate.beginFingerSequence() != nil else { return nil }
    if let raw=NotebookAttentionProjection.selectedInk(at:point,model:model,presence:presence,cohort:cohort) {
      return .selectedInk(raw)
    }
    if model.selectionSession.count > 0, let selected = NotebookAttentionProjection.selectedElement(at:point,model:model,presence:presence,cohort:cohort) {
      return .element(selected)
    }
    switch NotebookAttentionProjection.pointResolution(at:point,model:model,presence:presence,cohort:cohort) {
    case .pending: return .pending
    case .hit(let hit):
      guard let id = hit.elementID else { return nil }
      let reference: EditableElementReference
      switch hit.target.kind {
      case .page: reference = .page(pageID:hit.target.id,elementID:id)
      case .board,.cover: reference = .spatial(boardID:presence.boardID,elementID:id)
      default: return nil
      }
      // An explicitly opened editor owns its mouse and keyboard, not this edge.
      guard !model.selectionSession.isInteractive || model.selectionSession.element != reference else { return nil }
      return .element(reference)
    case nil: return nil
    }
  }

  override func hitTest(_ point:NSPoint) -> NSView? {
    contact(at:convert(point,from:superview)) == nil ? nil : self
  }
  override func mouseDown(with event:NSEvent) {
    guard let contact=contact(at:convert(event.locationInWindow,from:nil)) else { return }
    if case .pending=contact { return }
    window?.makeFirstResponder(self)
    model.inputGate.notifyAcceptedContact()
    switch contact {
    case .element(let reference):
      if model.selectionSession.addingElements { model.toggleGraphicSelection(reference);return }
      if !model.selectionSession.contains(reference) { model.selectElement(reference) }
      if event.clickCount > 1 { model.editSelectedElement(reference);return }
    case .selectedInk(let raw):
      if model.selectionSession.addingElements {
        model.removeInkFromMultipleSelection(raw);return
      }
    case .pending: return
    }
    // The window is stationary when the object and its camera carrier move.
    down = (contact,model.selectionSession.id,event.locationInWindow,presence.camera.scale)
    model.inputGate.beginContact(source:source)
    model.inputGate.registerFingerCancellation(source:source) { [weak self] in self?.cancel() }
  }
  private func translation(_ event:NSEvent) -> SpatialPoint? {
    guard let down else { return nil }
    return .init(x:(event.locationInWindow.x-down.point.x)/down.scale,
      y:(down.point.y-event.locationInWindow.y)/down.scale)
  }
  override func mouseDragged(with event:NSEvent) {
    guard let down, let delta = translation(event) else { return }
    if manipulation == nil, hypot(delta.x,delta.y)*down.scale >= 3 {
      switch down.contact {
      case .element(let reference): manipulation=model.beginElementManipulation(reference,kind:.move)
      case .selectedInk(let raw):
        guard model.selectionSession.id == down.selectionID,
          model.selectionSession.ink.contains(where:{ $0.key == raw }) else { endContact();return }
        manipulation=model.beginSelectionManipulation(kind:.move)
      case .pending: return
      }
    }
    if let manipulation { model.updateElementManipulation(manipulation,translation:delta) }
  }
  override func mouseUp(with event:NSEvent) {
    if let manipulation, let delta = translation(event) { model.finishElementManipulation(manipulation,translation:delta) }
    manipulation = nil; endContact()
  }
  private func endContact() {
    down = nil
    model.inputGate.unregisterFingerCancellation(source:source)
    model.inputGate.endContact(source:source)
  }
  func cancel() {
    if let manipulation { model.cancelElementManipulation(manipulation) }
    manipulation = nil; endContact()
  }
  override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { cancel() } }

  override func menu(for event:NSEvent) -> NSMenu? {
    guard let contact=contact(at:convert(event.locationInWindow,from:nil)) else { return nil }
    let menu=NSMenu();menu.autoenablesItems=false
    func add(_ title:String,_ action:Selector,enabled:Bool = true) {
      let item=NSMenuItem(title:title,action:action,keyEquivalent:"")
      item.target=self;item.isEnabled=enabled;menu.addItem(item)
    }
    func addSelectionActions() {
      add("Дублировать",#selector(duplicateSelection),enabled:model.canExportSelection)
      add("Удалить",#selector(deleteElement),enabled:model.canDeleteSelection)
      add("Снять выделение",#selector(clearSelection))
    }
    switch contact {
    case .element(let reference):
      if !model.selectionSession.contains(reference) { model.selectElement(reference) }
      if model.selectionSession.count>1 || !model.selectionSession.ink.isEmpty { addSelectionActions() }
      else {
        add("Редактировать",#selector(editElement));add("Удалить",#selector(deleteElement))
        if model.parentGroup(reference) != nil { add("Выбрать группу",#selector(selectParent)) }
        if model.graphicElement(reference) != nil { add("Выбрать несколько",#selector(selectMultiple)) }
      }
    case .selectedInk: addSelectionActions()
    case .pending: return nil
    }
    return menu
  }
  @objc private func editElement() { if let reference = model.selectionSession.element { model.editSelectedElement(reference) } }
  @objc private func deleteElement() { if model.canDeleteSelection { model.deleteSelectedContent() } }
  @objc private func duplicateSelection() { if model.canExportSelection { model.duplicateSelectedContent() } }
  @objc private func clearSelection() { model.clearSelection() }
  @objc private func selectParent() {
    if let reference = model.selectionSession.element, let parent = model.parentGroup(reference) { model.selectElement(parent) }
  }
  @objc private func selectMultiple() { model.beginMultipleSelection() }
  @objc func undo(_ sender:Any?) { model.undoLastSurfaceAction() }
  @objc func redo(_ sender:Any?) { model.redoLastSurfaceAction() }
  override func keyDown(with event:NSEvent) {
    switch event.keyCode {
    case 51,117: deleteElement()
    case 53: cancel(); model.clearSelection()
    default: super.keyDown(with:event)
    }
  }
}

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
/// retain accessible targets, with compact physical grips; neither paper zoom
/// nor a portal duplicates their touch regions.
struct NotebookElementControls: UIViewRepresentable {
  @Environment(NotebookAppModel.self) private var model
  let contextMenus: NotebookContextMenus
  let reference: EditableElementReference
  let selectionID: UUID
  let frame: CGRect
  let scale: Double
  var camera: SessionPresence? = nil

  func makeUIView(context: Context) -> NotebookSelectionControlsView { .init(gate: model.inputGate,contextMenus:contextMenus) }
  func updateUIView(_ view: NotebookSelectionControlsView, context: Context) {
    let model = self.model, reference = self.reference, selectionID = self.selectionID
    view.beginActionsUpdate()
    defer { view.finishActionsUpdate() }
    let suppressActions = model.selectionSession.manipulation != nil
      || (model.inputIsActive && !model.inputGate.permitsObjectPickup)
    let isRegion=model.selectionSession.region?.reference == reference
    var graphic = isRegion ? nil : model.graphicElement(reference)
    if let contact = model.selectionSession.manipulation, contact.reference == reference {
      if contact.vertices != contact.originalVertices { graphic?.vertices = contact.vertices }
      if contact.cornerRadius != contact.originalCornerRadius { graphic?.cornerRadius = contact.cornerRadius }
    }
    let isGroup=model.isElementGroup(reference)
    view.graphic = graphic
    view.configure(selectionID: selectionID, frame: frame, textWidth:model.textWidthControls(reference,screenFrame:frame,scale:scale), layout: graphic?.connection == nil ? nil : model.graphicLayout(reference), scale:scale,
      hasLabel: !(graphic?.label.isEmpty ?? true), mode:model.selectionSession.geometryMode, manipulating: suppressActions,subject:isGroup ? .group : .element,
      camera:camera, cameraProjection:model.nativeCameraProjection)
    view.beginManipulation = { [weak view] kind in
      guard model.selectionSession.id == selectionID,
        let contact = model.beginElementManipulation(reference, kind: kind) else { return nil }
      let scale = max(view?.projectionScale ?? scale, 0.001)
      return .init(begin: {}, change: { point in
        model.updateElementManipulation(contact, translation: .init(x: point.x / scale, y: point.y / scale))
      }, end: { point in
        model.finishElementManipulation(contact, translation: .init(x: point.x / scale, y: point.y / scale))
      }, cancel: { model.cancelElementManipulation(contact) })
    }
    // configure updates the moving handles and hides the context actions. Its actions
    // and whole-page paint order do not depend on the current contact pose.
    // Cancelling a pickup into a pinch does not finish the physical contact.
    // Keep its context actions out of that navigation until all fingers lift.
    guard !suppressActions else { return }
    let menus = contextMenus
    var materialIdentity = isRegion ? nil : selectionMaterialIdentity(model:model,reference:reference)
    let tracksMaterial = graphic != nil || materialIdentity != nil
    let acceptsFirstPublication = tracksMaterial && materialIdentity == nil
      && model.acceptedWorkingGraphic(reference) != nil && model.elementCommandSources[reference] != nil
    func isCurrent() -> Bool {
      guard model.selectionSession.id == selectionID, model.selectionSession.editingElement == reference,
        model.elementGeometry(reference) != nil, model.graphicElement(reference)?.visible != false else { return false }
      guard tracksMaterial else { return true }
      let current = selectionMaterialIdentity(model:model,reference:reference)
      if let materialIdentity { return current == materialIdentity }
      guard acceptsFirstPublication else { return false }
      // A freshly accepted shape already belongs to the existing creation
      // command. Bind its first durable identity once; later same-ID material
      // cannot inherit either the visible menu or the open palette's actions.
      if let current { materialIdentity=current;return true }
      return model.acceptedWorkingGraphic(reference) != nil && model.elementCommandSources[reference] != nil
    }
    var primary: [UIMenuElement] = [], secondary: [UIMenuElement] = []
    if let graphic, graphic.freehand == nil {
      primary.append(UIAction(title:"Оформление фигуры",image:UIImage(systemName:"paintbrush.pointed"),
        identifier:.init("graphic-style-menu")) { [weak menus] _ in
        guard isCurrent(), let menus, let graphic = model.graphicElement(reference),
          graphic.freehand == nil, graphic.visible != false, model.elementGeometry(reference) != nil else { return }
        let controller = NotebookElementStyleController(graphic:graphic)
        controller.updateStyle = { update in
          guard isCurrent() else { return }
          model.setGraphicStyle(reference:reference,update:update)
        }
        menus.presentSelectionPopover(controller,selection:selectionID,reference:reference,isCurrent:isCurrent)
      })
    }
    let text = model.nativeTextTarget(reference)
    if !isGroup && !isRegion {
      primary.append(UIAction(title:graphic != nil ? "Подпись фигуры" : text != nil ? "Редактировать текст" : "Редактировать элемент",
        image:UIImage(systemName:"character.cursor.ibeam"),identifier:.init("edit-agent-element")) { _ in
        guard isCurrent() else { return }
        model.editSelectedElement(reference)
      })
    }
    if graphic?.connection != nil {
      for (mode,title,symbol,id) in [(NotebookConnectionController.Mode.routing,"Стиль соединения","line.diagonal","graphic-routing-menu"),
        (.ends,"Концы линии","line.diagonal.arrow","graphic-ends-menu")] {
        primary.append(UIAction(title:title,image:UIImage(systemName:symbol),identifier:.init(id)) { [weak menus] _ in
          guard isCurrent(), let menus, let connection = model.graphicElement(reference)?.connection,
            model.elementGeometry(reference) != nil else { return }
          let controller = NotebookConnectionController(mode:mode,connection:connection)
          controller.setRouting = { routing in
            guard isCurrent() else { return }
            model.setGraphicRouting(routing,reference:reference)
          }
          controller.setHead = { head,terminal in
            guard isCurrent() else { return }
            model.setGraphicArrowhead(head,terminal:terminal,reference:reference)
          }
          menus.presentSelectionPopover(controller,selection:selectionID,reference:reference,isCurrent:isCurrent)
        })
      }
    }
    if let text {
      let format = text.style.runs?.first?.format ?? text.style.format ?? .init()
      let formatting = NotebookTextFormattingMenu.make(format,apply:{ change in
        guard isCurrent() else { return }
        model.formatNativeText(reference,change:change)
      },link:{ [weak menus] in
        guard isCurrent(), let menus else { return }
        menus.performAfterSelectionMenuDismiss(selection:selectionID) { [weak menus] in
          guard isCurrent(), let menus else { return }
          NotebookTextFormattingMenu.editLink(format.link,from:menus.view,apply:{ link in
            guard isCurrent() else { return }
            model.formatNativeText(reference) { $0.link = link }
          })
        }
      })
      secondary.append(UIMenu(title:"Формат текста",image:UIImage(systemName:"textformat"),children:formatting.children))
    }
    if let graphic, graphic.transform == nil, NotebookGraphicGeometry.polygon(graphic) != nil {
      secondary.append(UIMenu(title:"Режим геометрии",image:UIImage(systemName:model.selectionSession.geometryMode.controlSymbol),
        children:NotebookSelectionSession.GeometryMode.allCases.map { mode in
          UIAction(title:mode.controlTitle,image:UIImage(systemName:mode.controlSymbol),identifier:.init("graphic-geometry-"+mode.rawValue),
            state:model.selectionSession.geometryMode == mode ? .on : .off) { _ in
            guard isCurrent() else { return }
            model.setElementGeometryMode(mode,reference:reference)
          }
        }))
    }
    if graphic != nil || isRegion {
      secondary.append(UIAction(title:model.selectionSession.addingElements ? "Не добавлять касанием" : "Выбрать несколько",
        image:UIImage(systemName:"plus.circle"),attributes:isRegion ? .disabled : [],state:model.selectionSession.addingElements ? .on : .off) { _ in
        guard isCurrent() else { return }
        if model.selectionSession.addingElements { model.setMultipleSelectionAdding(false) } else { model.beginMultipleSelection() }
      })
    }
    if graphic != nil || isRegion || isGroup { secondary.append(selectionTransformMenu(model:model,selectionID:selectionID,isCurrent:isCurrent)) }
    if !isGroup && !isRegion { secondary.append(selectionLayerMenu(model:model,selectionID:selectionID,isCurrent:isCurrent)) }
    if let parent=model.parentGroup(reference) {
      secondary.append(UIAction(title:"Выбрать группу",image:UIImage(systemName:"square.on.square")) { _ in
        guard isCurrent() else { return };model.selectElement(parent)
      })
    }
    if isGroup {
      primary.append(UIAction(title:"Выбрать участника",image:UIImage(systemName:"cursorarrow")) { _ in
        guard isCurrent() else { return };model.clearSelection()
      })
    }
    let remove = UIAction(title:"Удалить элемент",image:UIImage(systemName:"trash"),identifier:.init("delete-agent-element"),attributes:.destructive) { _ in
      guard isCurrent() else { return }
      model.deleteElement(reference)
    }
    view.setActions(primary:primary,secondary:secondary,destructive:[remove])
  }

  static func dismantleUIView(_ view: NotebookSelectionControlsView, coordinator: ()) { view.uninstall() }
}

/// The same control owner owns context actions and the installed member frames.
struct NotebookMultipleElementControls: UIViewRepresentable {
  @Environment(NotebookAppModel.self) private var model
  let contextMenus: NotebookContextMenus
  let selectionID: UUID
  let frames: [CGRect]
  let scale: Double
  var camera: SessionPresence? = nil
  func makeUIView(context: Context) -> NotebookSelectionControlsView {
    let view=NotebookSelectionControlsView(gate:model.inputGate,contextMenus:contextMenus)
    model.selectedGraphicHosts.registerControls(view,selectionID:selectionID)
    return view
  }
  func updateUIView(_ view: NotebookSelectionControlsView, context: Context) {
    model.selectedGraphicHosts.registerControls(view,selectionID:selectionID)
    view.beginActionsUpdate()
    defer { view.finishActionsUpdate() }
    let suppressActions = model.selectionSession.manipulation != nil
      || (model.inputIsActive && !model.inputGate.permitsObjectPickup)
    view.graphic = nil
    let frame = frames.reduce(CGRect.null) { $0.union($1) }
    let transforms=model.canTransformSelection
    view.configure(selectionID:selectionID,frame:frame,scale:scale,manipulating:suppressActions,
      subject:.elements(frames.count),transformsSelection:transforms,memberFrames:frames,
      camera:camera,cameraProjection:model.nativeCameraProjection)
    view.beginManipulation = { [weak view] kind in
      guard transforms,model.selectionSession.id == selectionID,
        let contact=model.beginSelectionManipulation(kind:kind) else { return nil }
      let scale=max(view?.projectionScale ?? scale,0.001)
      return .init(begin:{},change:{ point in
        model.updateElementManipulation(contact,translation:.init(x:point.x/scale,y:point.y/scale))
      },end:{ point in
        model.finishElementManipulation(contact,translation:.init(x:point.x/scale,y:point.y/scale))
      },cancel:{ model.cancelElementManipulation(contact) })
    }
    guard !suppressActions else { return }
    var primary: [UIMenuElement] = [], secondary: [UIMenuElement] = [], destructive: [UIMenuElement] = []
    if model.canDeleteSelection {
      destructive.append(UIAction(title:model.selectionSession.items.isEmpty ? "Удалить выбранные фигуры" : "Удалить выбранное",
        image:UIImage(systemName:"trash"),identifier:.init("delete-graphic-selection"),attributes:.destructive) { _ in
        guard model.selectionSession.id == selectionID else { return }
        model.deleteSelectedContent()
      })
    }
    if model.selectionSession.items.isEmpty { secondary.append(selectionLayerMenu(model:model,selectionID:selectionID)) }
    guard transforms else {
      secondary.append(UIAction(title:"Снять выделение",image:UIImage(systemName:"xmark")) { _ in
        guard model.selectionSession.id == selectionID else { return }; model.clearSelection()
      })
      view.setActions(primary:primary,secondary:secondary,destructive:destructive)
      return
    }
    let alignments: [(NotebookGraphicSelection.Alignment,String)] = [(.left,"По левому краю"),(.center,"По центру горизонтально"),
      (.right,"По правому краю"),(.top,"По верхнему краю"),(.middle,"По центру вертикально"),(.bottom,"По нижнему краю")]
    primary.append(UIAction(title:"Сгруппировать",image:UIImage(systemName:"square.on.square"),attributes:model.canGroupSelectedElements ? [] : .disabled) { _ in
        guard model.selectionSession.id == selectionID else { return };model.groupSelectedElements()
      })
    secondary += [
      selectionTransformMenu(model:model,selectionID:selectionID),
      UIAction(title:model.selectionSession.addingElements ? "Не добавлять касанием" : "Добавлять касанием",image:UIImage(systemName:"plus.circle"),
        state:model.selectionSession.addingElements ? .on : .off) { _ in
        guard model.selectionSession.id == selectionID else { return }; model.setMultipleSelectionAdding(!model.selectionSession.addingElements)
      },
      UIMenu(title:"Выровнять",image:UIImage(systemName:"align.horizontal.left"),children:alignments.map { alignment,title in
        UIAction(title:title) { _ in guard model.selectionSession.id == selectionID else { return }; model.alignGraphicSelection(alignment) }
      })
    ]
    view.setActions(primary:primary,secondary:secondary,destructive:destructive)
  }
  static func dismantleUIView(_ view: NotebookSelectionControlsView, coordinator: ()) { view.uninstall() }
}

/// Workspace cards use the same screen-space controls as page/board elements.
/// Only supported actions are exposed; card movement remains with WorkspaceItemPose.
struct NotebookItemControls: UIViewRepresentable {
  @Environment(NotebookAppModel.self) private var model
  let contextMenus: NotebookContextMenus
  let item: WorkspaceItem
  let boardID: UUID
  let selectionID: UUID
  let frame: CGRect
  let open: () -> Void
  let camera: SessionPresence
  let cornerRadius: Double

  func makeUIView(context: Context) -> NotebookSelectionControlsView { .init(gate:model.inputGate,contextMenus:contextMenus) }
  func updateUIView(_ view: NotebookSelectionControlsView, context: Context) {
    view.beginActionsUpdate()
    defer { view.finishActionsUpdate() }
    view.graphic = nil
    view.configure(selectionID:selectionID,frame:frame,scale:camera.camera.scale,subject:.item(item.kind),
      camera:camera,cameraProjection:model.nativeCameraProjection,cornerRadius:cornerRadius * camera.camera.scale)
    view.isEnabled = !model.isItemBeingDeleted(item.id)
    let title = switch item.kind {
      case .notebook: "Открыть тетрадь"; case .document: "Открыть документ"; case .board: "Открыть доску"
    }
    let openAction = UIAction(title:title,image:UIImage(systemName:"arrow.up.forward.app"),identifier:.init("open-workspace-item")) { _ in
      guard model.selectionSession.id == selectionID,
        model.selectionSession.itemID(on:boardID) == item.id,
        !model.isItemBeingDeleted(item.id) else { return }
      model.interactiveElementFocus = nil
      model.endSurfaceEditing()
      open()
    }
    let remove = UIAction(title:"Удалить",image:UIImage(systemName:"trash"),identifier:.init("delete-workspace-item"),attributes:.destructive) { _ in
      guard model.selectionSession.id == selectionID,
        model.selectionSession.itemID(on:boardID) == item.id else { return }
      Task {
        guard await model.deleteItem(item.id), model.selectionSession.id == selectionID else { return }
        model.clearSelection()
      }
    }
    view.setActions(primary:[openAction],secondary:[],destructive:[remove])
  }
  static func dismantleUIView(_ view: NotebookSelectionControlsView, coordinator: ()) { view.uninstall() }
}

private enum ElementHandle: Hashable {
  case corner(NotebookElementResizeHandle), move, start, end, bend, vertex(Int), rounding
  var kind: NotebookElementManipulation.Kind {
    switch self { case .move: .move; case .corner(let value): .resize(value); case .start: .endpoint(.start); case .end: .endpoint(.end); case .bend: .bend; case .vertex(let index): .vertex(index); case .rounding: .roundCorners }
  }
  var label: String {
    switch self {
    case .move: "Переместить группу"
    case .corner(let value): "Изменить размер за " + value.label
    case .start: "Начало стрелки"
    case .end: "Конец стрелки"
    case .bend: "Изгиб стрелки"
    case .vertex(let index): "Вершина \(index+1)"
    case .rounding: "Радиус углов"
    }
  }
  var identifier: String {
    switch self { case .move: "move-element-group"; case .corner(let value): "resize-agent-element-" + value.rawValue
    case .start: "graphic-start-handle"; case .end: "graphic-end-handle"; case .bend: "graphic-bend-handle"
    case .vertex(let index): "graphic-vertex-\(index)"; case .rounding: "graphic-corner-radius-handle" }
  }
}

/// Element geometry and actions only. Context presentation belongs to the workspace.
final class NotebookSelectionControlsView: UIControl, UIGestureRecognizerDelegate, SceneNativeCameraOwner {
  enum Subject { case element, group, elements(Int), item(WorkspaceItemKind) }
  private var subject: Subject = .element
  private var memberFrames: [CGRect] = []
  override var isEnabled: Bool {
    didSet { setNeedsLayout() }
  }
  private let contextMenus: NotebookContextMenus
  private var manipulating = false
  private let gate: NotebookInputGate
  private let source = UUID()
  private let gesture = SceneSelectionRecognizer()
  private weak var installedWindow: UIWindow?
  private var selectionID: UUID?
  private var frameRect = CGRect.zero
  private var textWidth:NotebookTextWidthControls?
  private(set) var primaryActions: [UIMenuElement] = []
  private(set) var secondaryActions: [UIMenuElement] = []
  private(set) var destructiveActions: [UIMenuElement] = []
  var graphic: NotebookGraphic? {
    didSet {
      updateAccessibilityElements()
      setNeedsLayout()
    }
  }
  func setActions(primary: [UIMenuElement], secondary: [UIMenuElement], destructive: [UIMenuElement]) {
    primaryActions = primary; secondaryActions = secondary; destructiveActions = destructive
    setNeedsLayout()
  }
  private var handleAccessibility: [ElementHandleAccessibility] = []
  private var handles = NotebookElementResizeHandle.allCases.map(ElementHandle.corner)
  private var connectionLayout: NotebookGraphicLayout?
  private(set) var projectionScale = 1.0
  private weak var cameraProjection: SceneNativeCameraProjection?
  private var cameraAnchor: SessionPresence?
  private var anchorFrame = CGRect.zero
  private var anchorMembers: [CGRect] = []
  private var anchorTextWidth: NotebookTextWidthControls?
  private var anchorScale = 1.0
  private var anchorCornerRadius = 0.0
  private let itemOutline = UIView()
  private var hasLabel = false
  private var geometryMode: NotebookSelectionSession.GeometryMode = .transform
  var beginManipulation: ((NotebookElementManipulation.Kind) -> SceneSelectionLift?)?

  init(gate: NotebookInputGate, contextMenus: NotebookContextMenus) {
    self.gate = gate; self.contextMenus = contextMenus
    super.init(frame: .zero)
    backgroundColor = .clear; isOpaque = false
    itemOutline.isUserInteractionEnabled = false
    itemOutline.accessibilityElementsHidden = true
    itemOutline.layer.cornerCurve = .continuous
    itemOutline.layer.borderWidth = 2
    itemOutline.isHidden = true
    addSubview(itemOutline)
    rebuildAccessibility()
    gesture.coordinateView = self; gesture.gate = gate; gesture.delegate = self
    gesture.onLift = { [weak self] point in
      guard let self,let handle=handle(at:point),let selectionID else { return nil }
      var contact:SceneSelectionLift?
      return .init(begin: { [weak self] in
        guard let self,self.selectionID == selectionID else { return }
        contact=beginManipulation?(handle.kind)
      },change: { contact?.change($0) },end: { contact?.end($0);contact=nil },cancel: { contact?.cancel();contact=nil })
    }
    gesture.onHold = { [weak self] point in
      guard let self,let selectionID else { return }
      contextMenus.requestSelectionMenu(selectionID,at:convert(point,to:contextMenus.view))
    }
  }
  private func rebuildAccessibility() {
    handleAccessibility = handles.map { handle in
      let item = ElementHandleAccessibility(accessibilityContainer: self)
      if case .corner(let corner)=handle,textWidth != nil {
        item.accessibilityLabel="Ширина текста: \(corner.leading ? "начало" : "конец") строки"
      } else { item.accessibilityLabel = handle.label }
      item.accessibilityIdentifier = handle.identifier
      item.accessibilityTraits = .adjustable
      item.adjust = { [weak self] increase in
        guard let self, let contact = beginManipulation?(handle.kind) else { return }
        let amount: CGFloat = increase ? 20 : -20
        if case .corner(let corner) = handle {
          let delta=textWidth?.translation(leading:corner.leading,amount:amount)
            ?? .init(x: corner.changesWidth ? (corner.leading ? -amount : amount) : 0, y: corner.changesHeight ? (corner.top ? -amount : amount) : 0)
          contact.end(.init(x:delta.x,y:delta.y))
        } else { contact.end(.init(x:handle == .bend ? 0 : amount,y:amount)) }
      }
      return item
    }
    updateAccessibilityElements()
  }
  private func updateAccessibilityElements() {
    accessibilityElements = handleAccessibility
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(selectionID: UUID, frame: CGRect, textWidth:NotebookTextWidthControls? = nil, layout: NotebookGraphicLayout? = nil, scale: Double = 1, hasLabel: Bool = false, mode: NotebookSelectionSession.GeometryMode = .transform, manipulating: Bool = false, subject: Subject = .element, transformsSelection:Bool = false, memberFrames:[CGRect] = [], camera:SessionPresence? = nil, cameraProjection:SceneNativeCameraProjection? = nil, cornerRadius:Double = 0) {
    if self.selectionID != selectionID { gesture.cancelSelection(); contextMenus.hide(source:source); self.selectionID = selectionID }
    self.subject = subject
    self.textWidth=textWidth
    let vertices = graphic.flatMap({ $0.transform == nil ? NotebookGraphicGeometry.polygon($0) : nil })
    geometryMode = vertices == nil ? .transform : mode
    let next: [ElementHandle]
    if case .item = subject { next = [] }
    else if case .elements = subject { next = transformsSelection ? NotebookElementResizeHandle.visible(in:frame.size).map(ElementHandle.corner) : [] }
    else if case .group = subject { next = NotebookElementResizeHandle.visible(in:frame.size).map(ElementHandle.corner)+[.move] }
    else if textWidth != nil { next = NotebookElementResizeHandle.textWidth.map(ElementHandle.corner) }
    else if layout != nil { next = [.start,.end,.bend] }
    else if geometryMode == .vertices, let vertices { next = vertices.indices.map(ElementHandle.vertex) }
    else if geometryMode == .rounding { next = [.rounding] }
    else { next = NotebookElementResizeHandle.visible(in: frame.size).map(ElementHandle.corner) }
    if handles != next { handles = next; rebuildAccessibility() }
    else { updateAccessibilityElements() }
    connectionLayout = layout; projectionScale = scale; self.hasLabel = hasLabel
    self.manipulating = manipulating
    anchorFrame = frame; anchorMembers = memberFrames; anchorTextWidth = textWidth
    anchorScale = scale; anchorCornerRadius = cornerRadius; cameraAnchor = camera
    if self.cameraProjection !== cameraProjection {
      self.cameraProjection?.remove(self); self.cameraProjection = cameraProjection
    }
    if let camera {
      projectSceneCamera(cameraProjection?.current(for:camera.boardID) ?? camera)
      if window != nil { cameraProjection?.register(self) }
    } else {
      frameRect = frame; self.memberFrames = memberFrames
      updateProjectedControls(cornerRadius:cornerRadius)
    }
  }
  override func didMoveToWindow() {
    super.didMoveToWindow(); uninstall()
    guard let window else { return }
    installedWindow = window; window.addGestureRecognizer(gesture)
    cameraProjection?.register(self)
    gate.registerControlRegion(source: source) { [weak self] point, kind in
      guard let self, let window = installedWindow, !isHidden else { return false }
      let local = convert(point, from: window)
      return kind == .finger && handle(at:local) != nil
    }
    gate.registerFingerCancellation(source: source) { [weak self] in
      self?.gesture.cancelSelection()
    }
  }
  func uninstall() {
    cameraProjection?.remove(self)
    gesture.cancelSelection(); contextMenus.detachSelectionActions(source:source); installedWindow?.removeGestureRecognizer(gesture); installedWindow = nil
    gate.unregisterControlRegion(source: source); gate.unregisterFingerCancellation(source: source)
  }
  /// Project the original geometry, never a previously rounded screen frame.
  /// This runs in the same native transaction as the physical scene planes.
  func projectSceneCamera(_ presence: SessionPresence) {
    guard let anchor = cameraAnchor, anchor.boardID == presence.boardID else { return }
    let projection = SceneCameraProjection(anchor:anchor,current:presence)
    let transform = CGAffineTransform(scaleX:projection.scale,y:projection.scale)
      .concatenating(.init(translationX:projection.translation.x,y:projection.translation.y))
    frameRect = anchorFrame.applying(transform)
    memberFrames = anchorMembers.map { $0.applying(transform) }
    textWidth = anchorTextWidth?.projected(by:transform)
    projectionScale = anchorScale * projection.scale
    updateProjectedControls(cornerRadius:anchorCornerRadius * projection.scale)
  }
  private func updateProjectedControls(cornerRadius:Double) {
    if case .item = subject {
      itemOutline.isHidden = false
      itemOutline.frame = frameRect
      itemOutline.layer.cornerRadius = cornerRadius
      itemOutline.layer.borderColor = tintColor.withAlphaComponent(0.72).cgColor
    } else { itemOutline.isHidden = true }
    setNeedsDisplay(); setNeedsLayout()
    // Context action position and hit regions must not wait for a SwiftUI publication.
    if window != nil { layoutIfNeeded() }
  }
  private var updatingActions = false
  func beginActionsUpdate() { updatingActions=true }
  func finishActionsUpdate() { updatingActions=false;setNeedsLayout() }
  override func layoutSubviews() {
    super.layoutSubviews()
    if manipulating { contextMenus.hide(source:source) }
    else if !updatingActions { contextMenus.registerSelectionActions(source:source,selection:selectionID ?? source,anchor:frameRect,in:self,
      primary:primaryActions,secondary:secondaryActions,destructive:destructiveActions,enabled:isEnabled) }
    for (index, handle) in handles.enumerated() {
      handleAccessibility[index].accessibilityFrameInContainerSpace = handleAccessibilityFrame(handle)
    }
  }
  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    guard bounds.contains(point) else { return false }
    if event?.allTouches?.contains(where: { $0.type == .pencil }) == true { return false }
    return handle(at:point) != nil
  }
  private func point(_ handle: ElementHandle) -> CGPoint {
    if handle == .move { return .init(x:frameRect.midX,y:frameRect.midY) }
    if case .corner(let corner) = handle { return textWidth?.point(corner) ?? corner.point(in:frameRect) }
    if case .vertex(let index) = handle, let vertices = graphic.flatMap({ $0.transform == nil ? NotebookGraphicGeometry.polygon($0) : nil }), vertices.indices.contains(index) {
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
    let point = layout.displayedPoint(handle == .start ? layout.start : handle == .end ? layout.end : layout.bend)
    let start=layout.displayedPoint(layout.start),end=layout.displayedPoint(layout.end)
    let dx = end.x-start.x, dy = end.y-start.y, length = max(0.001,hypot(dx,dy))
    let offset = handle == .bend && hasLabel ? 30.0 : 0
    return .init(x:frameRect.minX+point.x*projectionScale+dy/length*offset,
      y:frameRect.minY+point.y*projectionScale-dx/length*offset)
  }
  private func handleAccessibilityFrame(_ handle: ElementHandle) -> CGRect {
    let point = point(handle)
    return .init(x: point.x - 22, y: point.y - 22, width: 44, height: 44)
  }
  private func handle(at point: CGPoint) -> ElementHandle? {
    // Small objects can have overlapping touch targets. The nearest handle
    // stays reachable instead of always picking the first one.
    // A physical grip is the visible handle plus a little finger tolerance.
    // The 44pt VoiceOver frame must not silently consume a nearby blank tap.
    guard let handle = handles.filter({
      let center = self.point($0)
      return hypot(center.x-point.x,center.y-point.y) <= 12
    }).min(by: {
      let a = self.point($0), b = self.point($1)
      return hypot(a.x - point.x, a.y - point.y) < hypot(b.x - point.x, b.y - point.y)
    }) else { return nil }
    // Overlapping grips must not consume the whole small figure.
    // Its center competes with handles so the ordinary body-drag owner remains
    // reachable; the visible handle and its outward touch area still resize.
    if connectionLayout == nil, frameRect.contains(point) {
      let position = self.point(handle)
      if hypot(point.x-frameRect.midX,point.y-frameRect.midY) < hypot(point.x-position.x,point.y-position.y) { return nil }
    }
    return handle
  }
  override func draw(_ rect: CGRect) {
    if case .item = subject { return }
    if case .elements = subject {
      tintColor.withAlphaComponent(0.7).setStroke()
      for frame in memberFrames { let p = UIBezierPath(rect:frame); p.lineWidth = 1; p.stroke() }
      let union = UIBezierPath(rect:frameRect.insetBy(dx:-4,dy:-4)); union.setLineDash([4,4],count:2,phase:0); union.stroke()
    }
    tintColor.withAlphaComponent(0.7).setStroke()
    if connectionLayout == nil,memberFrames.isEmpty {
      let outline: UIBezierPath
      if let textWidth {
        outline=UIBezierPath();outline.move(to:textWidth.corners[0])
        for point in textWidth.corners.dropFirst() { outline.addLine(to:point) };outline.close()
      } else if geometryMode != .transform, let vertices = graphic.flatMap({ $0.transform == nil ? NotebookGraphicGeometry.polygon($0) : nil }) {
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
      let point = point(handle)
      let rect: CGRect
      if corner.isCorner { rect = .init(x:point.x-5,y:point.y-5,width:10,height:10) }
      else if corner.changesWidth { rect = .init(x:point.x-3,y:point.y-9,width:6,height:18) }
      else { rect = .init(x:point.x-9,y:point.y-3,width:18,height:6) }
      let path = UIBezierPath(roundedRect:rect,cornerRadius:corner.isCorner ? 5 : 3)
      if let textWidth {
        path.apply(CGAffineTransform(translationX:-point.x,y:-point.y)
          .concatenating(.init(rotationAngle:textWidth.angle)).concatenating(.init(translationX:point.x,y:point.y)))
      }
      tintColor.setFill(); UIColor.systemBackground.setStroke()
      path.lineWidth = 1.5; path.fill(); path.stroke()

    }
    if let selectionID,let window {
      NotebookNavigationObservation.onSelectionControlsPaint?(selectionID,convert(frameRect,to:window))
    }
  }
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    guard touch.type == .direct else { return false }
    // A second finger belongs to the accepted sequence even outside the grip;
    // its existing owner must see it immediately and cancel into navigation.
    if gesture.numberOfTouches > 0 { return true }
    // SwiftUI can report its hosting view as touch.view even over this drawn
    // handle. The window-space control registry owns admission, not that
    // implementation-specific hit-view identity; other chrome still wins.
    guard let window = installedWindow, touch.view?.window === window, !isHidden, isEnabled, gate.permitsObjectPickup,
      !contextMenus.hasPresentedMenu,
      gate.permitsSceneContact(at:touch.location(in:window),kind:.finger,excludingControl:source),
      handle(at: touch.location(in: self)) != nil else { return false }
    return true
  }
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
    !gesture.canPrevent(other)
  }
}

private extension NotebookSelectionSession.GeometryMode {
  var controlTitle: String {
    switch self { case .transform: "Размер и положение"; case .vertices: "Изменить вершины"; case .rounding: "Скруглить углы" }
  }
  var controlSymbol: String {
    switch self { case .transform: "arrow.up.left.and.arrow.down.right"; case .vertices: "point.topleft.down.to.point.bottomright.curvepath"; case .rounding: "rectangle.roundedtop" }
  }
}

extension NotebookGraphicConnection.Arrowhead {
  var controlTitle: String {
    switch self {
    case .none: "Нет"; case .arrow: "Стрелка"; case .triangle: "Треугольник"; case .square: "Квадрат"; case .dot: "Круг"
    case .pipe: "Черта"; case .diamond: "Ромб"; case .inverted: "Обратная стрелка"; case .bar: "Полоса"
    }
  }
}

private final class ElementHandleAccessibility: UIAccessibilityElement {
  var adjust: ((Bool) -> Void)?
  override func accessibilityIncrement() { adjust?(true) }
  override func accessibilityDecrement() { adjust?(false) }
}

@MainActor private func selectionMaterialIdentity(model:NotebookAppModel,reference:EditableElementReference) -> VersionStamp? {
  // Working geometry deliberately has no persisted stamp. Read the existing
  // authored identity directly, independently of an accepted style preview.
  switch reference {
  case .page(let page,let id): model.pages[page]?.elementIdentityStamp(id)
  case .spatial(let board,let id): model.boardHierarchy?.board(board)?.elementIdentityStamp(id)
  }
}

@MainActor private func selectionTransformMenu(model: NotebookAppModel, selectionID: UUID, isCurrent:(()->Bool)? = nil) -> UIMenu {
  let turns: [UIMenuElement] = [-90.0,-15,15,90].map { angle in
    UIAction(title:"На \(abs(Int(angle)))° \(angle < 0 ? "влево" : "вправо")",image:UIImage(systemName:angle < 0 ? "rotate.left" : "rotate.right")) { _ in
      guard model.selectionSession.id == selectionID, model.selectionSession.count > 0,
        !model.selectionSession.isInteractive, isCurrent?() ?? true else { return }
      model.transformGraphicSelection(radians:angle * .pi/180)
    }
  }
  return UIMenu(title:"Поворот и масштаб",image:UIImage(systemName:"rotate.right"),children:turns + [UIMenu(options:.displayInline,children:[
    UIAction(title:"Увеличить на 25%",image:UIImage(systemName:"plus.magnifyingglass")) { _ in
      guard model.selectionSession.id == selectionID, model.selectionSession.count > 0,
        !model.selectionSession.isInteractive, isCurrent?() ?? true else { return }; model.transformGraphicSelection(scale:1.25)
    },
    UIAction(title:"Уменьшить на 20%",image:UIImage(systemName:"minus.magnifyingglass")) { _ in
      guard model.selectionSession.id == selectionID, model.selectionSession.count > 0,
        !model.selectionSession.isInteractive, isCurrent?() ?? true else { return }; model.transformGraphicSelection(scale:0.8)
    }
  ])])
}

@MainActor private func selectionLayerMenu(model: NotebookAppModel, selectionID: UUID, isCurrent:(()->Bool)? = nil) -> UIMenu {
  let available = model.availableLayerMoves
  return UIMenu(title:"Порядок слоёв",image:UIImage(systemName:"square.3.layers.3d"),children:NotebookElementLayerMove.allCases.map { direction in
    UIAction(title:direction.title,attributes:available.contains(direction) ? [] : .disabled) { _ in
      guard model.selectionSession.id == selectionID, model.selectionSession.count > 0,
        !model.selectionSession.isInteractive, isCurrent?() ?? true else { return }
      model.arrangeSelection(direction)
    }
  })
}

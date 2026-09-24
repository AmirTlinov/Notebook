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
    view.changeGeometryMode = { mode in
      guard model.selectionSession.id == selectionID else { return }
      model.setElementGeometryMode(mode,reference:reference)
    }
    var menus: [UIMenuElement] = []
    if graphic != nil || isRegion {
      menus.append(UIMenu(options:.displayInline,children:[
        UIAction(title:model.selectionSession.addingElements ? "Не добавлять касанием" : "Выбрать несколько",image:UIImage(systemName:"plus.circle"),attributes:isRegion ? .disabled : []) { _ in
          guard model.selectionSession.id == selectionID else { return }
          if model.selectionSession.addingElements { model.setMultipleSelectionAdding(false) } else { model.beginMultipleSelection() }
        }
      ]))
    }
    if graphic != nil || isRegion || isGroup { menus.append(selectionTransformMenu(model:model,selectionID:selectionID)) }
    if let parent=model.parentGroup(reference) {
      menus.append(UIAction(title:"Выбрать группу",image:UIImage(systemName:"square.on.square")) { _ in
        guard model.selectionSession.id == selectionID else { return };model.selectElement(parent)
      })
    }
    if isGroup {
      menus.append(UIAction(title:"Выбрать участника",image:UIImage(systemName:"cursorarrow")) { _ in
        guard model.selectionSession.id == selectionID else { return };model.clearSelection()
      })
    }
    if !isGroup {
      view.setLayerActions(available:model.availableLayerMoves) { move in
        guard model.selectionSession.id == selectionID else { return }
        model.arrangeSelection(move)
      }
    }
    view.changeRouting = { routing in
      guard model.selectionSession.id == selectionID else { return }
      model.setGraphicRouting(routing,reference:reference)
    }
    view.changeArrowhead = { head,terminal in
      guard model.selectionSession.id == selectionID else { return }
      model.setGraphicArrowhead(head,terminal:terminal,reference:reference)
    }
    if let text = model.nativeTextTarget(reference) {
      let format = text.style.runs?.first?.format ?? text.style.format ?? .init()
      view.setTextActions(NotebookTextFormattingMenu.make(format,apply:{ change in
        guard model.selectionSession.id == selectionID else { return }
        model.formatNativeText(reference,change:change)
      },link:{ [weak view] in
        guard let view, model.selectionSession.id == selectionID else { return }
        NotebookTextFormattingMenu.editLink(format.link,from:view,apply:{ link in
          guard model.selectionSession.id == selectionID else { return }
          model.formatNativeText(reference) { $0.link = link }
        })
      }).children)
    } else { view.setTextActions(nil) }
    if isGroup { view.setLayerActions();view.setGroupActions() }
    if isRegion { view.setRegionActions() }
    view.setActionsMenu(menus)
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
  func makeUIView(context: Context) -> NotebookSelectionControlsView { .init(gate:model.inputGate,contextMenus:contextMenus) }
  func updateUIView(_ view: NotebookSelectionControlsView, context: Context) {
    view.beginActionsUpdate()
    defer { view.finishActionsUpdate() }
    let suppressActions = model.selectionSession.manipulation != nil
      || (model.inputIsActive && !model.inputGate.permitsObjectPickup)
    view.graphic = nil
    let frame = frames.reduce(CGRect.null) { $0.union($1) }
    let transforms=model.selectionSession.items.isEmpty && model.selectionSession.elements.allSatisfy { model.graphicElement($0) != nil }
    view.configure(selectionID:selectionID,frame:frame,scale:scale,manipulating:suppressActions,
      subject:.elements(frames.count),transformsSelection:transforms,memberFrames:frames,
      camera:camera,cameraProjection:model.nativeCameraProjection)
    view.beginManipulation = { [weak view] kind in
      guard transforms,model.selectionSession.id == selectionID,let reference=model.selectionSession.elements.first,
        let contact=model.beginElementManipulation(reference,kind:kind) else { return nil }
      let scale=max(view?.projectionScale ?? scale,0.001)
      return .init(begin:{},change:{ point in
        model.updateElementManipulation(contact,translation:.init(x:point.x/scale,y:point.y/scale))
      },end:{ point in
        model.finishElementManipulation(contact,translation:.init(x:point.x/scale,y:point.y/scale))
      },cancel:{ model.cancelElementManipulation(contact) })
    }
    guard !suppressActions else { return }
    view.editElement = nil
    view.deleteElement = { if model.selectionSession.id == selectionID { model.deleteGraphicSelection() } }
    if model.selectionSession.items.isEmpty {
      view.setLayerActions(available:model.availableLayerMoves) { move in
        guard model.selectionSession.id == selectionID else { return }
        model.arrangeSelection(move)
      }
    }
    guard model.selectionSession.items.isEmpty,
      model.selectionSession.elements.allSatisfy({ model.graphicElement($0) != nil }) else {
      view.setActionsMenu([UIAction(title:"Снять выделение",image:UIImage(systemName:"xmark")) { _ in
        guard model.selectionSession.id == selectionID else { return }; model.clearSelection()
      }])
      view.deleteElement = { if model.selectionSession.id == selectionID { model.deleteSelectedContent() } }
      return
    }
    let alignments: [(NotebookGraphicSelection.Alignment,String)] = [(.left,"По левому краю"),(.center,"По центру горизонтально"),
      (.right,"По правому краю"),(.top,"По верхнему краю"),(.middle,"По центру вертикально"),(.bottom,"По нижнему краю")]
    view.setActionsMenu([
      UIAction(title:"Сгруппировать",image:UIImage(systemName:"square.on.square"),attributes:model.canGroupSelectedElements ? [] : .disabled) { _ in
        guard model.selectionSession.id == selectionID else { return };model.groupSelectedElements()
      },
      selectionTransformMenu(model:model,selectionID:selectionID),
      UIAction(title:model.selectionSession.addingElements ? "Не добавлять касанием" : "Добавлять касанием",image:UIImage(systemName:"plus.circle")) { _ in
        guard model.selectionSession.id == selectionID else { return }; model.setMultipleSelectionAdding(!model.selectionSession.addingElements)
      },
      UIMenu(title:"Выровнять",image:UIImage(systemName:"align.horizontal.left"),children:alignments.map { alignment,title in
        UIAction(title:title) { _ in guard model.selectionSession.id == selectionID else { return }; model.alignGraphicSelection(alignment) }
      })
    ])
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
    view.editElement = {
      guard model.selectionSession.id == selectionID,
        model.selectionSession.itemID(on:boardID) == item.id,
        !model.isItemBeingDeleted(item.id) else { return }
      model.interactiveElementFocus = nil
      model.endSurfaceEditing()
      open()
    }
    view.deleteElement = {
      guard model.selectionSession.id == selectionID,
        model.selectionSession.itemID(on:boardID) == item.id else { return }
      Task {
        guard await model.deleteItem(item.id), model.selectionSession.id == selectionID else { return }
        model.clearSelection()
      }
    }
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
  private let pan = ElementHandlePan()
  private weak var installedWindow: UIWindow?
  private var selectionID: UUID?
  private var frameRect = CGRect.zero
  private var textWidth:NotebookTextWidthControls?
  private var contact: SceneSelectionLift?
  private var pointingHandle: ElementHandle?
  private var pencilRevision: UInt64?
  private var contactOrigin = CGPoint.zero
  private let deleteButton = UIButton(type: .system)
  private let styleButton = UIButton(type: .system)
  private let editButton = UIButton(type: .system)
  private let modeButton = UIButton(type: .system)
  private let routingButton = UIButton(type: .system)
  private let endsButton = UIButton(type: .system)
  private let textFormatButton = NotebookContextMenuButton(type:.system)
  private let layerButton = NotebookContextMenuButton(type:.system)
  private let moreButton = NotebookContextMenuButton(type: .system)
  private var toolbarButtons: [UIButton] { [textFormatButton,styleButton,editButton,modeButton,routingButton,endsButton,layerButton,deleteButton,moreButton] }
  private var palette: NotebookElementStyleController? { contextMenus.presentedPopover(for:source) as? NotebookElementStyleController }
  private var connectionPalette: NotebookConnectionController? { contextMenus.presentedPopover(for:source) as? NotebookConnectionController }
  var changeRouting: ((NotebookGraphicConnection.Routing) -> Void)?
  var changeArrowhead: ((NotebookGraphicConnection.Arrowhead,NotebookGraphicConnection.Terminal) -> Void)?
  var graphic: NotebookGraphic? {
    didSet {
      styleButton.isHidden = graphic == nil || graphic?.freehand != nil
      modeButton.isHidden = graphic?.transform != nil || graphic.flatMap(NotebookGraphicGeometry.polygon) == nil
      routingButton.isHidden = graphic?.connection == nil; endsButton.isHidden = graphic?.connection == nil
      if let connection = graphic?.connection {
        routingButton.setImage(NotebookConnectionGlyph.image(routing:connection.resolvedRouting),for:.normal)
        endsButton.setImage(NotebookConnectionGlyph.image(start:connection.startArrowhead,end:connection.endArrowhead),for:.normal)
        routingButton.accessibilityValue = connection.resolvedRouting.controlTitle
        endsButton.accessibilityValue = connection.startArrowhead.controlTitle + ", " + connection.endArrowhead.controlTitle
        connectionPalette?.configure(connection)
      }
      editButton.accessibilityLabel = graphic == nil ? "Редактировать элемент" : "Подпись фигуры"
      if let graphic { palette?.configure(style: graphic.style) }
      updateAccessibilityElements()
      setNeedsLayout()
    }
  }
  func setTextActions(_ menu: [UIMenuElement]?) {
    textFormatButton.isHidden = menu == nil
    if case .element = subject { editButton.isHidden = menu != nil }
    textFormatButton.contents = menu ?? []
    setNeedsLayout()
  }
  func setLayerActions(available: Set<NotebookElementLayerMove> = [], move: ((NotebookElementLayerMove) -> Void)? = nil) {
    layerButton.isHidden = move == nil
    layerButton.contents = NotebookElementLayerMove.allCases.map { direction in
      UIAction(title:direction.title,attributes:available.contains(direction) ? [] : .disabled) { _ in move?(direction) }
    }
    setNeedsLayout()
  }
  func setRegionActions() {
    editButton.isHidden=true;setLayerActions();setNeedsLayout()
  }
  func setGroupActions() {
    editButton.isHidden=true;deleteButton.isHidden=true
    setNeedsLayout()
  }
  func setActionsMenu(_ children: [UIMenuElement]) {
    moreButton.contents = children; moreButton.isHidden = children.isEmpty
    setNeedsLayout()
  }
  var changeGeometryMode: ((NotebookSelectionSession.GeometryMode) -> Void)?
  var updateStyle: ((inout NotebookGraphic.Style) -> Void) -> Void = { _ in }
  var editElement: (() -> Void)?
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
  var deleteElement: (() -> Void)?

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
    let buttons: [(UIButton,String,String,String)] = [
      (textFormatButton,"textformat","Формат текста","native-text-format"),
      (layerButton,"square.3.layers.3d","Порядок слоёв","element-layer-menu"),
      (styleButton,"paintbrush.pointed","Оформление фигуры","graphic-style-menu"),
      (editButton,"character.cursor.ibeam","Подпись фигуры","edit-agent-element"),
      (modeButton,"arrow.up.left.and.arrow.down.right","Режим геометрии","graphic-geometry-mode"),
      (routingButton,"line.diagonal","Стиль соединения","graphic-routing-menu"),
      (endsButton,"line.diagonal.arrow","Концы линии","graphic-ends-menu"),
      (deleteButton,"trash","Удалить элемент","delete-agent-element"),
      (moreButton,"ellipsis","Действия с элементом","element-actions-menu")]
    for (button, symbol, label, identifier) in buttons {
      NotebookContextMenus.configure(button,symbol:symbol,title:label,id:identifier,destructive:button === deleteButton)
    }
    setTextActions(nil)
    setLayerActions()
    styleButton.isHidden = true
    modeButton.isHidden = true; routingButton.isHidden = true; endsButton.isHidden = true
    routingButton.addTarget(self,action:#selector(showRouting),for:.touchUpInside)
    endsButton.addTarget(self,action:#selector(showEnds),for:.touchUpInside)
    deleteButton.addTarget(self,action:#selector(removeElement),for:.touchUpInside)
    editButton.addTarget(self,action:#selector(edit),for:.touchUpInside)
    styleButton.addTarget(self,action:#selector(showStyle),for:.touchUpInside)
    modeButton.addTarget(self,action:#selector(cycleGeometryMode),for:.touchUpInside)
    rebuildAccessibility()
    pan.minimumNumberOfTouches = 1; pan.maximumNumberOfTouches = 1
    pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
    pan.delegate = self; pan.addTarget(self, action: #selector(resizeChanged))
    pan.onReset = { [weak self] in self?.cancel() }
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
    if self.selectionID != selectionID { cancel(); contextMenus.hide(source:source); self.selectionID = selectionID }
    self.subject = subject
    self.textWidth=textWidth
    editButton.isHidden = false; deleteButton.isHidden = false; setTextActions(nil); setLayerActions()
    var primary = editButton.configuration!
    switch subject {
    case .element, .group:
      primary.image = UIImage(systemName:"character.cursor.ibeam")
      editButton.accessibilityLabel = graphic == nil ? "Редактировать элемент" : "Подпись фигуры"
      editButton.accessibilityIdentifier = "edit-agent-element"
      deleteButton.accessibilityLabel = "Удалить элемент"
      deleteButton.accessibilityIdentifier = "delete-agent-element"
      moreButton.isHidden = false
    case .elements:
      // Selection is focus, never an uncommitted transaction to confirm.
      editButton.isHidden = true
      deleteButton.accessibilityLabel = "Удалить выбранные фигуры"
      deleteButton.accessibilityIdentifier = "delete-graphic-selection"
      moreButton.isHidden = false
    case .item(let kind):
      primary.image = UIImage(systemName:"arrow.up.forward.app")
      editButton.accessibilityLabel = switch kind {
        case .notebook: "Открыть тетрадь"; case .document: "Открыть документ"; case .board: "Открыть доску"
      }
      editButton.accessibilityIdentifier = "open-workspace-item"
      deleteButton.accessibilityLabel = "Удалить"
      deleteButton.accessibilityIdentifier = "delete-workspace-item"
      moreButton.isHidden = true
    }
    editButton.configuration = primary
    let vertices = graphic.flatMap({ $0.transform == nil ? NotebookGraphicGeometry.polygon($0) : nil })
    geometryMode = vertices == nil ? .transform : mode
    var modeConfiguration = modeButton.configuration!
    modeConfiguration.image = UIImage(systemName:geometryMode.controlSymbol)
    modeConfiguration.baseForegroundColor = geometryMode == .transform ? .label : tintColor
    modeConfiguration.background.backgroundColor = geometryMode == .transform ? .clear : UIColor(NotebookChrome.selectionSurface)
    modeConfiguration.background.cornerRadius = 8
    modeConfiguration.background.backgroundInsets = .init(top:6,leading:6,bottom:6,trailing:6)
    modeButton.configuration = modeConfiguration
    modeButton.accessibilityValue = geometryMode.controlTitle
    modeButton.accessibilityHint = "Переключить: " + geometryMode.next.controlTitle
    modeButton.toolTip = geometryMode.controlTitle
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
    installedWindow = window; window.addGestureRecognizer(pan)
    cameraProjection?.register(self)
    gate.registerControlRegion(source: source) { [weak self] point, kind in
      guard let self, let window = installedWindow, !isHidden else { return false }
      let local = convert(point, from: window)
      return kind == .finger && handle(at:local) != nil
    }
    gate.registerFingerCancellation(source: source) { [weak self] in
      self?.cancel(); self?.pan.isEnabled = false; self?.pan.isEnabled = true
    }
  }
  func uninstall() {
    cameraProjection?.remove(self)
    cancel(); contextMenus.hide(source:source); installedWindow?.removeGestureRecognizer(pan); installedWindow = nil
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
      buttons:toolbarButtons.filter { !$0.isHidden },enabled:isEnabled) }
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
  }
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    guard touch.type == .direct else { return false }
    if pointingHandle != nil { return true }
    // SwiftUI can report its hosting view as touch.view even over this drawn
    // handle. The window-space control registry owns admission, not that
    // implementation-specific hit-view identity; other chrome still wins.
    guard let window = installedWindow, touch.view?.window === window, !isHidden, isEnabled, gate.permitsObjectPickup,
      !contextMenus.hasPresentedMenu,
      gate.permitsSceneContact(at:touch.location(in:window),kind:.finger,excludingControl:source),
      let revision = gate.beginFingerSequence(),
      let handle = handle(at: touch.location(in: self)) else { return false }
    pencilRevision = revision
    contactOrigin = touch.location(in: installedWindow)
    pointingHandle = handle
    return true
  }
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
  @objc private func resizeChanged() {
    guard let revision = pencilRevision, gate.acceptsFingerSequence(revision), gate.permitsObjectPickup else { cancel(); return }
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
  @objc private func cycleGeometryMode() { dismissPalette(); changeGeometryMode?(geometryMode.next) }
  private func dismissPalette() { contextMenus.dismissPopover(source:source) }
  @objc private func showRouting() { showConnection(.routing,anchor:routingButton) }
  @objc private func showEnds() { showConnection(.ends,anchor:endsButton) }
  private func showConnection(_ mode: NotebookConnectionController.Mode, anchor: UIView) {
    guard let connection = graphic?.connection, palette == nil, connectionPalette == nil else { return }
    let controller = NotebookConnectionController(mode:mode,connection:connection)
    controller.setRouting = { [weak self] in self?.changeRouting?($0) }
    controller.setHead = { [weak self] in self?.changeArrowhead?($0,$1) }
    contextMenus.presentPopover(controller,source:source,from:anchor)
  }

  @objc private func showStyle() {
    guard let graphic, palette == nil, connectionPalette == nil else { return }
    let controller = NotebookElementStyleController(graphic:graphic)
    controller.updateStyle = { [weak self] update in self?.updateStyle(update) }
    // Keep the edited geometry visible, not just the small button.
    contextMenus.presentPopover(controller,source:source,from:self,
      rect:frameRect.union(contextMenus.frame(for:source,in:self)))
  }
}

private extension NotebookSelectionSession.GeometryMode {
  var next: Self { switch self { case .transform: .vertices; case .vertices: .rounding; case .rounding: .transform } }
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

private final class ElementHandlePan: UIPanGestureRecognizer {
  var onReset: (() -> Void)?
  override func reset() { super.reset(); onReset?() }
}

private final class ElementHandleAccessibility: UIAccessibilityElement {
  var adjust: ((Bool) -> Void)?
  override func accessibilityIncrement() { adjust?(true) }
  override func accessibilityDecrement() { adjust?(false) }
}

@MainActor private func selectionTransformMenu(model: NotebookAppModel, selectionID: UUID) -> UIMenu {
  UIMenu(title:"Поворот и масштаб",image:UIImage(systemName:"rotate.right"),children:[
    UIMenu(title:"Повернуть",children:[-90.0,-15,15,90].map { angle in
      UIAction(title:"\(angle > 0 ? "+" : "")\(Int(angle))°") { _ in
        guard model.selectionSession.id == selectionID else { return }
        model.transformGraphicSelection(radians:angle * .pi/180)
      }
    }),
    UIAction(title:"Увеличить на 25%",image:UIImage(systemName:"plus.magnifyingglass")) { _ in
      guard model.selectionSession.id == selectionID else { return }; model.transformGraphicSelection(scale:1.25)
    },
    UIAction(title:"Уменьшить на 20%",image:UIImage(systemName:"minus.magnifyingglass")) { _ in
      guard model.selectionSession.id == selectionID else { return }; model.transformGraphicSelection(scale:0.8)
    }
  ])
}

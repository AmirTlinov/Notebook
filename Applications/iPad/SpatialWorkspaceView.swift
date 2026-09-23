import NotebookCore
import SwiftUI
import UIKit

private struct CameraGestureSnapshot {
  let presence: SessionPresence
  let trajectory: CameraGestureTrajectory
}

/// The board background follows the same synchronous native camera sample as
/// ink and scene planes. It is deliberately outside SwiftUI's per-sample
/// invalidation path; drawing a dot field is its only frame work.
private struct LiveSpatialBoardGrid: UIViewRepresentable {
  @Environment(NotebookAppModel.self) private var model
  let presence: SessionPresence

  func makeUIView(context: Context) -> NativeSpatialBoardGrid {
    let view = NativeSpatialBoardGrid()
    view.update(presence)
    view.bind(to: model.nativeCameraProjection)
    return view
  }

  func updateUIView(_ view: NativeSpatialBoardGrid, context: Context) {
    view.update(presence)
    view.bind(to: model.nativeCameraProjection)
  }

  static func dismantleUIView(_ view: NativeSpatialBoardGrid, coordinator: ()) {
    view.unbind()
  }
}

@MainActor
private final class NativeSpatialBoardGrid: UIView, SceneNativeCameraOwner {
  private weak var projection: SceneNativeCameraProjection?
  private var presence: SessionPresence?

  override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = true
    backgroundColor = UIColor(BoardAppearance.background)
    contentMode = .redraw
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func bind(to projection: SceneNativeCameraProjection) {
    guard self.projection !== projection else { return }
    self.projection?.remove(self)
    self.projection = projection
    projection.register(self)
  }

  func unbind() {
    projection?.remove(self)
    projection = nil
  }

  func update(_ presence: SessionPresence) {
    guard self.presence != presence else { return }
    self.presence = presence
    setNeedsDisplay()
  }

  func projectSceneCamera(_ presence: SessionPresence) {
    guard self.presence?.boardID == presence.boardID else { return }
    update(presence)
  }

  override func draw(_ rect: CGRect) {
    guard let presence, let context = UIGraphicsGetCurrentContext() else { return }
    context.setFillColor(UIColor(BoardAppearance.background).cgColor)
    context.fill(bounds)
    var worldStep = PhysicalPaper.gridSpacing
    while worldStep * presence.camera.scale < BoardAppearance.minimumDotSpacing { worldStep *= 2 }
    let step = worldStep * presence.camera.scale
    guard step.isFinite, step > 0 else { return }
    let phaseX = presence.camera.center.localX.truncatingRemainder(dividingBy: worldStep) * presence.camera.scale
    let phaseY = presence.camera.center.localY.truncatingRemainder(dividingBy: worldStep) * presence.camera.scale
    let startX = (bounds.width / 2 - phaseX).truncatingRemainder(dividingBy: step)
    let startY = (bounds.height / 2 - phaseY).truncatingRemainder(dividingBy: step)
    let radius = max(0.65, 0.9 / max(window?.screen.scale ?? traitCollection.displayScale, 1))
    let dots = CGMutablePath()
    var x = startX < 0 ? startX + step : startX
    while x <= bounds.width {
      var y = startY < 0 ? startY + step : startY
      while y <= bounds.height {
        dots.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
        y += step
      }
      x += step
    }
    context.addPath(dots)
    context.setFillColor(UIColor(BoardAppearance.dot).cgColor)
    context.fillPath()
  }
}

struct SpatialWorkspaceView: View {
  var backRequest: UInt64 = 0
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.displayScale) private var displayScale
  @Environment(NotebookAppModel.self) private var model

  @State private var contextMenus = NotebookContextMenus()
  @State private var cameraGesture: CameraGestureSnapshot?
  @State private var panStart: SessionPresence?
  private var selectedItemID: UUID? { model.presence.flatMap { model.selectionSession.itemID(on: $0.boardID) } }
  @State private var liftedItemIDs: [UUID] = []
  @State private var deletionObserverID = UUID()
  private var editingSpatialText: EditableElementReference? {
    guard model.selectionSession.isInteractive,
      case .spatial(let boardID, let id) = model.selectionSession.element,
      model.boardHierarchy?.board(boardID)?.element(id:id)?.kind == .nativeText else { return nil }
    return .spatial(boardID: boardID, elementID: id)
  }
  private func editingTextID(on boardID: UUID) -> String? {
    guard case .spatial(let owner, let id) = editingSpatialText, owner == boardID else { return nil }; return id
  }
  @State private var contentGestureActive = false
  @State private var pageTurnIsActive = false
  @State private var pageInputGestureID: UUID?
  @State private var bufferedCameraPhases: [WorkspaceMagnificationPhase] = []
  @State private var documentPageLayouts: [UUID: DocumentPageLayout] = [:]
  @State private var settling = false
  @State private var cameraSettlement = SceneCameraSettlement()
  @State private var referencePageResolution = NotebookReferencePageResolution()
  private var spatialInkSurfaces: SpatialInkSurfaceRegistry { model.compositionTiles.surfaceRegistry }
  @State private var openingFeedback = UIImpactFeedbackGenerator(style: .soft)

  var body: some View {
    if model.shutdownPhase != .stopped {
      mountedScene.allowsHitTesting(model.shutdownPhase != .draining)
    }
  }

  private var mountedScene: some View {
    GeometryReader { geometry in
      let viewport = SpatialPoint(
        x: geometry.size.width,
        y: geometry.size.height
      )
      let presence = normalizedPresence(for: viewport)
      let requestedFrame = model.sceneIndex.map {
        WorkspaceSceneFrame(index: $0, presence: presence, portalCamera: model.scenePortalCamera,
          pinned: scenePins(presence: presence))
      }
      let cohort = model.compositionTiles.published.flatMap {
        $0.plan.presentations[.board(presence.boardID)] != nil ? $0 : nil
      }
      let frame = cohort?.frame
      let compositionRequest = CompositionRequest(presence: presence, generation: model.sceneIndex?.generationID,
        publication: model.scenePublicationGeneration,
        revision: model.workspaceHeader?.cursor, pinned: scenePins(presence: presence),
        itemOwners: sceneItemOwners(presence: presence, cohort: cohort),
        permitsPreparation: model.permitsScenePreparation, refinesDetails: model.presencePhase == .settled,groupPoses:model.compositionGroupPoses)
      let workset = cohort.map { model.presentedWorkset(cohort: $0, boardID: presence.boardID, presence: presence) } ?? .empty
      let rendered = workset.items

      ZStack {
        NotebookWorkspacePresentation(presence: presence, cohort: cohort) { [weak cohort] in
        ZStack {
        LiveSpatialBoardGrid(presence: presence)
        if cohort == nil {
          ProgressView(model.compositionTiles.failure == nil ? "Подготовка пространства" : "Ожидание ресурсов изображения")
            .padding(12).notebookPanel(radius:NotebookChrome.cardRadius)
            .zIndex(9_000)
        }

          WorkspacePanView(
            isEnabled: (presence.mode == .board || presence.mode == .cover
              || ((presence.mode == .page || presence.mode == .document)
                && presence.camera.scale > model.itemGeometry(presence.focusedItemID).fitScale(viewport:viewport) * 1.001))
              && cameraGesture == nil && !model.isPointing,
            inputGate: model.inputGate,
            onBegan: {
              referencePageResolution.cancel()
              interruptSettlementForInput()
              model.cancelElementManipulation()
              panStart = model.presence.map { presenceForNewContact($0) }
            },
            onChanged: { translation in
              updateWorkspacePan(translation, viewport: viewport)
            },
            onEnded: { translation in
              finishWorkspacePan(translation, viewport: viewport)
            },
            onCancelled: {
              finishWorkspacePan(nil, viewport: viewport)
            }
          )
          .frame(width: viewport.x, height: viewport.y)

        boardElements(workset.elements, presence: presence, viewport: viewport, cohort: cohort)


          SpatialInkCanvas(
            cohort: cohort,
            boardID: presence.boardID,
            camera: presence.camera,
            viewport: viewport,
            items: rendered.map {
              SpatialWorkspaceItemSurface(
                itemID: $0.id,
                geometry: $0.geometry,
                center: $0.center,
                zIndex: $0.zIndex
              )
            },
            journal: model.spatialInk,
            penStyle: model.activePenStyle,
            eraserStyle: model.eraserStyle,
            drawingTool: model.drawingTool,
            surfaceRegistry: spatialInkSurfaces,
            inputGate: model.inputGate,
            isItemBeingDeleted: model.isItemBeingDeleted,
            // Admission is proved by this installed cohort and its native
            // surface registrations, never by the newer pending scene index.
            admitsNewContact: { [weak cohort] in cohort != nil },
            onCommit: model.appendSpatialInk,
            isEnabled: (presence.mode == .board || presence.mode == .cover)
              && !contentGestureActive,
            onQuickShape: { model.acceptQuickShape($0, boardID: $1, origin: $2, stroke: $3) }

          )
          .allowsHitTesting(false)

        sceneItems(rendered, presence: presence, viewport: viewport, frame: frame, cohort: cohort)
          .zIndex(liftedItemIDs.isEmpty ? 0 : 9_000)
        }
        .frame(width: viewport.x, height: viewport.y)
        }
        .frame(width: viewport.x, height: viewport.y)

          WorkspaceGestureLayer(
            isEnabled: true,
            defersHorizontalMotionToPageTurn: (presence.mode == .page
              || presence.mode == .document)
              && presence.openProgress >= 0.999 && !model.isPointing
              && presence.camera.scale <= model.itemGeometry(presence.focusedItemID).fitScale(viewport: viewport) * 1.001,
            inputGate: model.inputGate,
            onCamera: handleWorkspaceMagnification,
            onUndo: model.undoLastSurfaceAction
          )
          .allowsHitTesting(false)

          itemSelectionControl(presence: presence, viewport: viewport)

        NotebookAgentFeedbackOverlay(presence:presence)
        NotebookAttentionMarks(presence:presence)
        NotebookGraphicBindingHint(presence:presence)
        NotebookTransientToolsOverlay(presence:presence)
        NotebookNativeTextEditingOverlay(presence:presence,contextMenus:contextMenus)
        NotebookPresentationOverlay(player: model.presentationPlayer, presence: presence,
          cameraIsActive: model.presencePhase == .active)
        if let reference = model.selectionSession.editingElement,
          let rect = NotebookAttentionProjection.editingFrame(reference, model: model, presence: presence) {
          NotebookElementControls(contextMenus:contextMenus,reference: reference, selectionID: model.selectionSession.id,
            frame: rect,
            scale: presence.camera.scale)
            .frame(width: viewport.x, height: viewport.y)
        }
        if model.selectionSession.count > 1 {
          let frames = model.selectionSession.elements.compactMap { reference in
            NotebookAttentionProjection.editingFrame(reference,model:model,presence:presence)
          } + model.selectionSession.items.compactMap { selected -> CGRect? in
            guard selected.boardID == presence.boardID, let cohort,
              let item = model.presentedItem(id:selected.itemID,cohort:cohort,presence:presence)
                ?? cohort.frame.index.renderedItem(id:selected.itemID,presence:presence) else { return nil }
            let rect = item.geometry.screenFrame(center:item.center,camera:presence.camera,viewport:presence.viewport)
            return .init(x:rect.x,y:rect.y,width:rect.width,height:rect.height)
          }
          if frames.count == model.selectionSession.count {
            NotebookMultipleElementControls(contextMenus:contextMenus,selectionID:model.selectionSession.id,frames:frames,scale:presence.camera.scale)
              .frame(width:viewport.x,height:viewport.y)
          }
        }
        NotebookContextMenuHost(owner:contextMenus,gate:model.inputGate).zIndex(9_600)
        NotebookSelectionGesture(inputGate: model.inputGate,
          onPoint: { end, tapCount in
          guard cameraGesture == nil, !settling, let cohort else { return }
          if model.consumeNativeTextCanvasTap(at:end) { return }
          if model.drawingTool == .text {
            guard let fragment = NotebookAttentionProjection.pointContact(at:end,model:model,presence:presence,
              cohort:cohort) else { return }
            if let reference = editableReference(fragment,boardID:presence.boardID) {
              let isText: Bool
              switch reference {
              case .page(let page,let id): isText = model.pages[page]?.element(id:id)?.kind == .nativeText
              case .spatial: isText = model.presentedElement(reference,cohort:cohort)?.kind == .nativeText
              }
              if isText {
                model.selectElement(reference)
                if tapCount > 1 { model.editSelectedElement(reference) }
                return
              }
            }
            guard let contact = NotebookAttentionProjection.toolAddress(at:end,fragment:fragment,model:model,presence:presence) else { return }
            model.beginToolText(at:contact.point,address:contact.address,screenScale:presence.camera.scale)
            return
          }
          if let selected = selectedElement(at: end, presence: presence) {
            if model.selectionSession.addingElements { model.toggleGraphicSelection(selected); return }
            if tapCount > 1 { model.selectElement(selected); model.editSelectedElement(selected) }; return
          }
          let fragment:NotebookAttentionSelection.Fragment
          switch NotebookAttentionProjection.pointResolution(at:end,model:model,presence:presence,cohort:cohort) {
          case .pending: return
          case .hit(let hit): fragment=hit
          case nil: model.clearSelection();return
          }
          if let reference=editableReference(fragment,boardID:presence.boardID) {
            if model.selectionSession.addingElements { model.toggleGraphicSelection(reference);return }
            model.selectElement(reference)
            if tapCount > 1 { model.editSelectedElement(reference) }
          } else if fragment.target.kind == .cover {
            model.selectWorkspaceItem(fragment.target.id,boardID:presence.boardID)
          } else if let contact=NotebookAttentionProjection.toolAddress(at:end,fragment:fragment,model:model,presence:presence) {
            model.drawingTools.selectInk(at:contact.point,address:contact.address,screenScale:presence.camera.scale)
          } else { model.clearSelection() }
        }, onLift: { point in
          guard cameraGesture == nil, !settling, !model.selectionSession.isInteractive, let cohort else { return nil }
          let selected = selectedElement(at: point, presence: presence)
          let hit=selected == nil ? NotebookAttentionProjection.pointContact(at:point,model:model,presence:presence,cohort:cohort) : nil
          guard let reference=selected ?? hit.flatMap({ editableReference($0,boardID:presence.boardID) }) else { return nil }
          if model.selectionSession.addingElements, !model.selectionSession.contains(reference) {
            return SceneSelectionLift(begin:{},change:{ _ in },end:{ _ in },cancel:{})
          }
          let scale = max(presence.camera.scale, 0.001)
          var contactID: UUID?
          func translation(_ delta: CGPoint) -> SpatialPoint { .init(x: delta.x / scale, y: delta.y / scale) }
          return SceneSelectionLift( begin: {
            if !model.selectionSession.contains(reference) { model.selectElement(reference) }
            contactID = model.beginElementManipulation(reference, kind: .move)
            if contactID != nil { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
          }, change: {
            if let contactID { model.updateElementManipulation(contactID, translation: translation($0)) }
          }, end: { delta in
            if let contactID { model.finishElementManipulation(contactID, translation: translation(delta)) }
          }, cancel: {
            if let contactID { model.cancelElementManipulation(contactID) }
          })
        }).allowsHitTesting(false)
        if let rect = model.selectionSession.preview {
          RoundedRectangle(cornerRadius: 4).stroke(.indigo, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY).allowsHitTesting(false)
        }
          NotebookDisplayConfirmation {
            guard cameraGesture == nil, !settling, !pageTurnIsActive, !contentGestureActive else { return }
            model.prepareCommonDocumentShellIfIdle(presence: presence, cohort: cohort)
            model.confirmVisibleActions(presence: presence, scene: workset, cohort: cohort)
          }.allowsHitTesting(false)

        controls(presence: presence, viewport: viewport)
      }
      .clipped()
      .environment(\.sceneComposition, .init(cohort))
      .task(id: compositionRequest) {
        model.prepareComposition(presence: presence, frame: requestedFrame,
          pinned: compositionRequest.pinned, displayScale: displayScale, installedItemOwners: compositionRequest.itemOwners)
      }
      .onAppear {
        model.stopNavigationPresentation = { requestID in
          referencePageResolution.cancel()
          guard cameraSettlement.navigationID == requestID else { return }
          interruptSettlementForInput()
          if model.presencePhase == .active, let current = model.presence {
            model.updatePresence(current, settled: true)
          }
        }
        model.presentationPlayer.moveCamera = { camera, duration in
          guard let current = model.presence, !model.inputGate.isActive, cameraGesture == nil,
            !pageTurnIsActive, !contentGestureActive, model.requestedReference == nil,
            model.requestedReturn == nil, model.loadState == .ready else { return false }
          animateSettlement(to: current.replacingCamera(camera), duration: duration, bounce: 0)
          return true
        }
        model.presentationPlayer.stopCamera = {
          cameraSettlement.cancel(); settling = false
          if model.presencePhase == .active, let current = model.presence {
            model.updatePresence(current, settled: true)
          }
        }
        let registry = spatialInkSurfaces, owner = model
        model.bindItemOwnerObserver(owner: deletionObserverID) { [weak registry, weak owner] id, boardID, revision in
          guard let shown = owner?.compositionTiles.published, shown.plan.revision <= revision,
            shown.frame.index.ownerBoard(itemID: id) == boardID else { return }
          registry?.retirePhysicalOwner(id, on: boardID, through: revision)
          if owner?.selectionSession.itemID(on: boardID) == id { owner?.clearSelection() }
        }
        publishViewportIfNeeded(viewport)
      }
      .task(id: model.navigationGeneration) {
        guard let reference = model.requestedReference else { return }
        model.observeNavigation("view_task_enter", reference: reference, fields: ["cameraGesture": .bool(cameraGesture != nil), "settling": .bool(settling), "pageTurn": .bool(pageTurnIsActive), "contentGesture": .bool(contentGestureActive)])
        defer { model.observeNavigation("view_task_exit", reference: reference) }
        model.presentationPlayer.interrupt("navigation")
        referencePageResolution.cancel()
        while cameraGesture != nil || settling || pageTurnIsActive || contentGestureActive || model.presencePhase != .settled {
          do { try await Task.sleep(for:.milliseconds(40)) } catch { return }
        }
        model.observeNavigation("view_ready_to_resolve", reference: reference)
        await model.resolveReferenceLocation(reference) { location in
          showReference(reference, location: location, viewport: model.presence?.viewport ?? viewport)
        }
      }
      .task(id: model.navigationGeneration) {
        guard let place = model.requestedReturn else { return }
        model.presentationPlayer.interrupt("navigation")
        referencePageResolution.cancel()
        while cameraGesture != nil || settling || pageTurnIsActive || contentGestureActive || model.presencePhase != .settled {
          do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
        }
        await model.resolveReturnToPlace(place, viewport: model.presence?.viewport ?? viewport) { destination, completed in
          guard destination.mode == .document, let documentID = destination.focusedItemID else {
            animateSettlement(to: destination, duration: 0.3, navigationID: place.id, completion: completed)
            return
          }
          let targetPage = destination.documentPageIndex
          let generation = model.navigationGeneration
          model.prepareDocumentOpening(documentID, pageIndex: targetPage, boardID: destination.boardID)
          let actualPage = documentPageIndex(for: documentID, from: model.presence)
          let cameraDestination = SessionPresence(boardID: destination.boardID, mode: destination.mode,
            camera: destination.camera, viewport: destination.viewport, focusedItemID: documentID,
            openProgress: destination.openProgress, documentPageIndex: actualPage,
            selectedItemID: destination.selectedItemID, notebookPageID: destination.notebookPageID)
          animateSettlement(to: cameraDestination, duration: 0.3, navigationID: place.id, completion: completed)
          referencePageResolution.start(requestID: place.id, documentID: documentID, isCurrent: {
            model.navigationGeneration == generation
              && (settling || model.presence?.focusedItemID == documentID)
              && model.requestedReference == nil
          }, resolve: {
            guard !settling, model.documents[documentID] != nil else { return nil }
            return targetPage
          }, apply: { page in
            _ = model.selectDocumentPage(page, documentID: documentID)
          })
        }
      }
      .onChange(of: backRequest) { _, _ in
        model.cancelRequestedNavigation()
        referencePageResolution.cancel()
        if !model.returnPlaces.isEmpty { model.requestReturnToPlace() }
        else if presence.mode == .board { leaveBoard(viewport: viewport) }
        else {
          animateSettlement(to: .init(boardID: presence.boardID, mode: .board,
            camera: .init(center: presence.camera.center, scale: model.itemGeometry(presence.focusedItemID).coverScale(viewport: viewport)), viewport: viewport), duration: 0.3)
        }
      }
      .onChange(of: scenePhase) { _, phase in
        if phase != .active {
          model.cancelRequestedNavigation(reason: "scene_phase_not_active")
          referencePageResolution.cancel()
          interruptSettlementForInput()
        }
      }
      .onChange(of: geometry.size) { old, new in
        model.observeNavigation("view_geometry_change", fields: ["oldWidth": .number(old.width), "oldHeight": .number(old.height), "newWidth": .number(new.width), "newHeight": .number(new.height)])
        model.cancelRequestedNavigation(reason: "geometry_size_changed")
        interruptSettlementForInput()
        publishViewportIfNeeded(viewport)
      }
      .onChange(of: model.chat?.files.window.isOpen) { _, open in
        if open == true { model.presentationPlayer.interrupt("code_document_opened") }
      }
      .onChange(of: presence.mode) { _, mode in
        model.endSurfaceEditing()
        if mode != .cover { model.interactiveElementFocus = nil }
        if mode != .page && mode != .document {
          pageTurnIsActive = false
        }
      }
      .onChange(of: presence.focusedItemID) { _, itemID in
        if referencePageResolution.documentID != itemID { referencePageResolution.cancel() }
        model.endSurfaceEditing()
        if itemID == nil { model.interactiveElementFocus = nil }
        pageTurnIsActive = false
      }
      .onDisappear {
        model.cancelRequestedNavigation()
        model.stopNavigationPresentation = nil
        model.presentationPlayer.interrupt("scene_not_visible")
        model.presentationPlayer.moveCamera = nil; model.presentationPlayer.stopCamera = nil
        model.unbindItemOwnerObserver(owner: deletionObserverID)
        model.compositionTiles.cancelPreparation()
        referencePageResolution.cancel()
        cameraSettlement.cancel()
        cameraGesture = nil
        contentGestureActive = false
        pageTurnIsActive = false
        pageInputGestureID = nil
        bufferedCameraPhases = []
        settling = false
        model.interactiveElementFocus = nil
        model.endSurfaceEditing()
      }
    }
  }

  private func editableReference(_ fragment: NotebookAttentionSelection.Fragment, boardID: UUID) -> EditableElementReference? {
    guard let id = fragment.elementID else { return nil }
    switch fragment.target.kind {
    case .page: return .page(pageID: fragment.target.id, elementID: id)
    case .board, .cover: return .spatial(boardID: boardID, elementID: id)
    default: return nil
    }
  }

  private struct CompositionRequest: Equatable {
    let presence: SessionPresence
    let generation: UUID?
    let publication: UInt64
    let revision: UInt64?
    let pinned: Set<WorkspaceSpatialID>
    let itemOwners: [UUID: UUID]
    let permitsPreparation: Bool
    let refinesDetails: Bool
    let groupPoses: [SceneCompositionPlane:[String:NotebookElementPlacement.Source]]
  }

  @ViewBuilder
  private func itemSelectionControl(
    presence: SessionPresence,
    viewport: SpatialPoint
  ) -> some View {
    if model.selectionSession.element == nil,
      presence.mode == .board || presence.mode == .cover,
      !liftedItemIDs.contains(where: { spatialInkSurfaces.pose(for: .cover($0))?.isManipulating == true }),
      let selectedItemID,
      let cohort = model.compositionTiles.published,
      let rendered = model.presentedItem(id: selectedItemID, cohort: cohort, presence: presence)
    {
      let box = rendered.geometry.screenFrame(center:rendered.center, camera:presence.camera, viewport:viewport)
      NotebookItemControls(contextMenus:contextMenus,item:rendered.item,boardID:presence.boardID,selectionID:model.selectionSession.id,
        frame:.init(x:box.x,y:box.y,width:box.width,height:box.height),
        open:{ openItem(selectedItemID,viewport:viewport) })
        .frame(width:viewport.x,height:viewport.y)
        .zIndex(9_500)
    }
  }

  @ViewBuilder
  private func controls(
    presence: SessionPresence,
    viewport: SpatialPoint
  ) -> some View {
      if presence.mode == .board && !settling {
        Menu {
          Button {
            createItem(
              kind: .board,
              presence: presence,
              viewport: viewport
            )
          } label: {
            Label("Доска", systemImage: "rectangle.3.group")
          }
          .accessibilityIdentifier("create-nested-board")
          Button {
            createItem(
              kind: .notebook,
              presence: presence,
              viewport: viewport
            )
          } label: {
            Label("Тетрадь", systemImage: "book.closed")
          }
          Menu {
            Button {
              createItem(
                kind: .document,
                paperSize: .a4,
                presence: presence,
                viewport: viewport
              )
            } label: {
              Label("A4", systemImage: "doc")
            }
            .accessibilityIdentifier("create-document-a4")
            Button {
              createItem(
                kind: .document,
                paperSize: .letter,
                presence: presence,
                viewport: viewport
              )
            } label: {
              Label("Letter", systemImage: "doc")
            }
            .accessibilityIdentifier("create-document-letter")
          } label: {
            Label("Документ", systemImage: "doc.text")
          }
        } label: {
          Image(systemName: "plus")
            .font(NotebookChrome.iconFont)
            .frame(width: 44, height: 44)
            .background { NotebookSurface().padding(2) }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Создать")
        .accessibilityIdentifier("create-workspace-item")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, 22)
        .padding(.bottom, 20)
        .zIndex(10_000)
      }

    NotebookNavigationView(presence: presence,
      documentPageCount: presence.focusedItemID.flatMap { id in
        model.documents[id].flatMap { documentPageLayouts[id]?.pageCount(for: NotebookAppModel.documentPageSourceRevision($0)) }
      })
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(.leading, 18).padding(.top, 18).zIndex(10_000)
  }

  private struct ItemPlaneRevision: Equatable {
    let cohortID: UUID?
    let generation: UUID?
    let contents: UInt64
    let items: [RenderedWorkspaceItem]
    let covers: [UUID: [SpatialElement]]
    let mode: WorkspaceSemanticMode
    let focused: UUID?
    let open: Double
    let selected: UUID?
    let lifted: [UUID]
    let editingText: EditableElementReference?
    let contentGesture: Bool
    let pageTurn: Bool
    let isCameraGesture: Bool
    let settling: Bool
    let pointing: Bool
    let prepares: [Bool]
    let page: Int
    let layout: [UUID: DocumentPageLayout]
    let dependentCamera: SpatialCamera?
  }

  private func sceneItems(_ rendered: [RenderedWorkspaceItem], presence: SessionPresence,
    viewport: SpatialPoint, frame: WorkspaceSceneFrame?, cohort: SceneCompositionCohort?) -> some View {
    let covers = Dictionary(uniqueKeysWithValues: rendered.map { item in
      (item.id, cohort.map { model.presentedCoverElements(cohort: $0, boardID: presence.boardID, itemID: item.id) } ?? [])
    })
    let revision = ItemPlaneRevision(cohortID: cohort?.paintID, generation: model.sceneIndex?.generationID,
      contents: model.collaborationReadEpoch, items: rendered, covers: covers, mode: presence.mode,
      focused: presence.focusedItemID, open: presence.openProgress,
      selected: selectedItemID, lifted: liftedItemIDs,
      editingText: editingSpatialText, contentGesture: contentGestureActive,
      pageTurn: pageTurnIsActive, isCameraGesture: cameraGesture != nil, settling: settling,
      pointing: model.isPointing, prepares: rendered.map { preparesContent($0.id, presence: presence) },
      page: presence.documentPageIndex, layout: documentPageLayouts,
      dependentCamera: rendered.contains { $0.stackID != nil || $0.item.kind == .board }
        || selectedItemID != nil ? presence.camera : nil)
    return SceneCameraPlane(presence: presence, revision: revision, reanchorsOnRevision: false,
      isCameraActive: model.presencePhase == .active || cameraGesture != nil || panStart != nil || settling,
      installation: cohort?.installation(for: .covers)) { anchor in
      ZStack {
        if let cohort {
          ForEach(SceneCompositionTileBandView.bands(in: cohort, plane: .board(presence.boardID), layer: .covers, presence: anchor)) { band in
            band.zIndex(Double(band.rank))
          }
        }
        sceneItemContents(rendered, presence: presence, viewport: viewport, anchorCamera: anchor.camera,
          covers: covers, frame: frame, cohort: cohort)
      }
        .environment(model).environment(\.workspaceSceneFrame, frame).environment(\.sceneComposition, .init(cohort))
    }
  }

  private func sceneItemContents(_ rendered: [RenderedWorkspaceItem], presence: SessionPresence,
    viewport: SpatialPoint, anchorCamera: SpatialCamera, covers: [UUID: [SpatialElement]], frame: WorkspaceSceneFrame?, cohort: SceneCompositionCohort?) -> some View {
    ForEach(rendered.filter {
          cohort?.plan.allowsLive(.item($0.id), in: .board(presence.boardID)) == true && (
          WorkspaceSceneProjection.mountsContent(of: $0, in: presence)
            || $0.id == selectedItemID || liftedItemIDs.contains($0.id))
        }) { rendered in
          WorkspaceSceneItem(
            rendered: rendered,
            document: presence.focusedItemID == rendered.id ? model.documents[rendered.id] : cohort?.liveData.documents[rendered.id],
            documentState: presence.focusedItemID == rendered.id ? model.documentStates[rendered.id] : cohort?.liveData.states[rendered.id],
            documentPageIndex: presence.focusedItemID == rendered.id
              ? presence.documentPageIndex
              : 0,
            documentPageLayout: documentPageLayouts[rendered.id],
            camera: anchorCamera,
            projectedScale: presence.camera.scale,
            boardID: presence.boardID,
            coverElements: covers[rendered.id] ?? [],
            viewport: viewport,
            isFocused: presence.focusedItemID == rendered.id,
            preparesCoverMotion: presence.focusedItemID == rendered.id
              || selectedItemID == rendered.id
              || model.workspace?.selectedItemID == rendered.id,
            preparesContent: preparesContent(
              rendered.id,
              presence: presence
            ),
            openProgress: presence.focusedItemID == rendered.id
              ? presence.openProgress
              : 0,
            contentIsInteractive: presence.focusedItemID == rendered.id
              && !model.isItemBeingDeleted(rendered.id)
              && (presence.mode == .page || presence.mode == .document)
              && !contentGestureActive
              && !pageTurnIsActive
              && cameraGesture == nil
              && !settling
              && presence.openProgress >= 0.999,
            pageNavigationIsEnabled: !model.isPointing && presence.focusedItemID == rendered.id
              && !model.isItemBeingDeleted(rendered.id)
              && (presence.mode == .page || presence.mode == .document)
              && presence.openProgress >= 0.999
              && cameraGesture == nil
              && !settling,
            isSelected: selectedItemID == rendered.id,
            liftRank: liftRank(of: rendered.id),
            editingTextID: editingTextID(on: presence.boardID),
            spatialInkSurfaces: spatialInkSurfaces,
            onDrop: { itemID, center in
              dropItem(itemID, at: center, presence: presence)
            },
            onSelect: { itemID in
              guard !model.isItemBeingDeleted(itemID) else { return }
              withAnimation(.easeOut(duration: 0.12)) {
                model.selectWorkspaceItem(itemID,boardID:presence.boardID)
              }
            },
            onLiftChanged: { itemID, lifted in
              if lifted { model.interactiveElementFocus = nil }
              liftedItemIDs.removeAll { $0 == itemID }
              if lifted { liftedItemIDs.append(itemID); model.selectWorkspaceItem(itemID,boardID:presence.boardID) }
            },
            onOpen: { itemID in
              guard !model.isItemBeingDeleted(itemID), model.presence?.boardID == presence.boardID else { return }
              model.interactiveElementFocus = nil
              model.endSurfaceEditing()
              openItem(itemID, viewport: viewport)
            },
            onTextEditingEnded: { [selectionID = model.selectionSession.id] elementID in
              model.finishInteractiveElementInput(.spatial(boardID: presence.boardID, elementID: elementID), selectionID: selectionID)
            },
            onPageTurnStateChange: { active in
              if active { model.cancelRequestedNavigation(); referencePageResolution.cancel() }
              pageTurnIsActive = active
            },
            onDocumentPageLayout: { layout in
              acceptDocumentPageLayout(
                layout,
                documentID: rendered.id
              )
            }
          )
          .zIndex(WorkspaceSceneProjection.presentationRank(of: rendered, in: presence, liftRank: liftRank(of: rendered.id))
            ?? cohort?.plan.rank(id: .item(rendered.id), in: .board(presence.boardID)) ?? 0)
        }

  }

  private func selectedElement(at point:CGPoint,presence:SessionPresence)->EditableElementReference? {
    guard let cohort=model.compositionTiles.published else { return nil }
    return NotebookAttentionProjection.selectedElement(at:point,model:model,presence:presence,cohort:cohort)
  }

  private struct ElementPlaneRevision: Equatable {
    let cohortID: UUID?
    let generation: UUID?
    let focus: InteractiveElementReference?
    let elements: [SpatialElement]
    let selection: EditableElementReference?
    let selectionID: UUID
    let manipulation: NotebookElementManipulation?
    let elementCommandDrafts: [EditableElementReference: NotebookElementCommandDraft]
    let workingGraphicsRevision:UInt64
  }

  private func boardElements(_ elements: [SpatialElement], presence: SessionPresence,
    viewport: SpatialPoint, cohort: SceneCompositionCohort?) -> some View {
    let selection = model.selectionSession.editingElement
    let revision = ElementPlaneRevision(cohortID: cohort?.paintID, generation: model.sceneIndex?.generationID,
      focus: model.interactiveElementFocus, elements: elements,
      selection: selection, selectionID: model.selectionSession.id, manipulation: model.selectionSession.manipulation,
      elementCommandDrafts: model.elementCommandDrafts,
      workingGraphicsRevision:model.workingGraphicRevision(on:.board(presence.boardID)))
    return SceneCameraPlane(presence: presence, revision: revision, reanchorsOnRevision: false,
      isCameraActive: model.presencePhase == .active || cameraGesture != nil || panStart != nil || settling,
      installation: cohort?.installation(for: .elements),
      observation: NotebookSceneObservation.context(cohort: cohort, elements: elements)) { anchor in
      ZStack {
        if let cohort {
          ForEach(SceneCompositionTileBandView.bands(in: cohort, plane: .board(presence.boardID), layer: .elements, presence: anchor)) { band in
            band.zIndex(Double(band.rank))
          }
        }
        boardElementContents(elements, presence: anchor, viewport: anchor.viewport, cohort: cohort)
      }
        .environment(model).environment(\.sceneComposition, .init(cohort))
    }
  }

  @ViewBuilder
  private func boardElementContents(
    _ elements: [SpatialElement],
    presence: SessionPresence,
    viewport: SpatialPoint,
    cohort: SceneCompositionCohort?
  ) -> some View {
    let graph = cohort.map { model.presentedGraphicGraph(boardID:presence.boardID,cohort:$0) }
    if let cohort, let graph {
      ForEach(cohort.plan.vectorRuns.filter { $0.plane == .board(presence.boardID) }) { run in
        NotebookGraphicBatchView(run: run, elements: elements, graph: graph,
          scale: presence.camera.scale, size: .init(width: viewport.x, height: viewport.y),
          projectOrigin: { presence.camera.worldToScreen($0, viewport: viewport).cgPoint })
          .zIndex(cohort.plan.rank(id: run.id.id, in: run.plane) ?? 0)
      }
      if let run = model.workingGraphicRun(plane: .board(presence.boardID), cohort: cohort) {
        NotebookGraphicBatchView(run: run,
          elements: model.workingGraphics(on: .board(presence.boardID), cohort: cohort)
            .map { $0.spatialElement(stamp: .init(counter: 0, actor: model.actorID)) },
          graph: graph, scale: presence.camera.scale, size: .init(width: viewport.x, height: viewport.y),
          projectOrigin: { presence.camera.worldToScreen($0, viewport: viewport).cgPoint }, commitsState: false)
          .zIndex(Double((cohort.plan.bands.map(\.rank).max() ?? 0) + 2))
      }
    }
    ForEach(elements.filter { $0.graphic == nil && cohort?.plan.allowsLive(.element($0.id), in: .board(presence.boardID)) == true }) { element in
        if let placement=graph?.placement(element.id) {
          let presentation=NotebookElementPresentation(element,placement:placement)
          let worldOrigin=placement.origin
          let reference = EditableElementReference.spatial(boardID: presence.boardID, elementID: element.id)
          let local=presentation.frame
          let base = presence.camera.worldToScreen(
            worldOrigin,
            viewport: viewport
          )
          let origin = CGPoint(
            x: base.x + local.x * presence.camera.scale,
            y: base.y + local.y * presence.camera.scale
          )
          SceneElementPose(frame: .init(origin: origin,
            size: .init(width: local.width * presence.camera.scale,
              height: local.height * presence.camera.scale)),
            contentSize: .init(width: local.width, height: local.height),
            observationElementID: element.id, observationElementStamp: element.stamp) {
            EditableElementContainer(reference: reference) {
              NotebookPlacedElement(presentation:presentation) {
                SpatialElementContent(element: element, boardID: presence.boardID,
                  isTextEditing: editingSpatialText == reference,
                  onTextEditingEnded: { [selectionID = model.selectionSession.id] in model.finishInteractiveElementInput(reference, selectionID: selectionID) })
              }
            }
          }
            .frame(width: viewport.x, height: viewport.y)
            .zIndex(cohort?.plan.rank(id: .element(element.id), in: .board(presence.boardID)) ?? 0)
        }
      }
  }


  private func normalizedPresence(for viewport: SpatialPoint) -> SessionPresence {
    guard let presence = model.presence else {
      return SessionPresence(
        boardID: model.workspace?.rootBoardID ?? WorkspaceRoot.boardID,
        mode: .board,
        camera: SpatialCamera(),
        viewport: viewport
      )
    }
    return presence.adapted(to: viewport, geometry: model.itemGeometry(presence.focusedItemID))
  }

  private func publishViewportIfNeeded(_ viewport: SpatialPoint) {
      guard let presence = model.presence,
        presence.viewport != viewport
      else { return }
      model.updatePresence(normalizedPresence(for: viewport), settled: true)
  }

  private func sceneItemOwners(presence: SessionPresence, cohort: SceneCompositionCohort?) -> [UUID: UUID] {
    var owners: [UUID: UUID] = [:]
    for pin in scenePins(presence: presence) {
      guard case .item(let id) = pin else { continue }
      if let owner = spatialInkSurfaces.pose(for: .cover(id))?.boardID
        ?? cohort?.frame.index.ownerBoard(itemID: id) { owners[id] = owner }
    }
    return owners
  }

  private func scenePins(presence: SessionPresence) -> Set<WorkspaceSpatialID> {
    var pins = Set<WorkspaceSpatialID>()
    for id in [presence.focusedItemID, selectedItemID] + liftedItemIDs.map(Optional.some) {
      if let id, !spatialInkSurfaces.isRetired(.cover(id)) { pins.insert(.item(id)) }
    }
    for reference in model.selectionSession.elements {
      if case .spatial(let boardID,let id) = reference, boardID == presence.boardID { pins.insert(.element(id)) }
    }
    for reference in model.elementCommandDrafts.keys {
      if case .spatial(let boardID, let id) = reference, boardID == presence.boardID { pins.insert(.element(id)) }
    }
    if let id = editingTextID(on: presence.boardID) { pins.insert(.element(id)) }
    if case .board(let boardID, let elementID) = model.interactiveElementFocus {
      pins.insert(.element(elementID))
      if let cohort = model.compositionTiles.published,
        let element = model.presentedElement(.spatial(boardID: boardID, elementID: elementID), cohort: cohort),
        element.surface.kind == .cover, let carrier = element.surface.ownerID { pins.insert(.item(carrier)) }
    }
    return pins
  }

  private func sceneWorkset(presence: SessionPresence) -> WorkspaceSceneWorkset {
    if let cohort = model.compositionTiles.published,
      cohort.plan.presentations[.board(presence.boardID)] != nil {
      return model.presentedWorkset(cohort: cohort, boardID: presence.boardID, presence: presence)
    }
    return model.sceneWorkset(presence: presence, pinned: scenePins(presence: presence))
  }

  /// Opening and docking use the same accepted physical placement as the live
  /// paper. A retained, out-of-window owner still belongs to its admitted cohort.
  private func focusedCenter(itemID: UUID, boardID: UUID) -> WorldPoint? {
    if let board = model.boardHierarchy?.board(boardID),
      board.placement(of: itemID) != nil || board.stack(containing: itemID) != nil {
      return board.focusedCenter(of: itemID)
    }
    guard let cohort = model.compositionTiles.published,
      let presence = cohort.frame.presences[boardID],
      model.presentedItem(id: itemID, cohort: cohort, presence: presence) != nil else { return nil }
    return cohort.frame.index.focusedCenter(itemID: itemID, boardID: boardID)
  }

  private func acceptDocumentPageLayout(
    _ layout: DocumentPageLayout,
    documentID: UUID
  ) {
    guard let document = model.documents[documentID],
      layout.pageCount(for: NotebookAppModel.documentPageSourceRevision(document)) != nil else { return }
    model.acceptDocumentReadingLayout(layout, documentID: documentID)
    let summary = DocumentPageLayout(pageCount: layout.pageCount, sourceRevision: layout.sourceRevision, isComplete: layout.isComplete)
    if documentPageLayouts[documentID] != summary { documentPageLayouts[documentID] = summary }
    guard layout.isComplete, let presence = model.presence,
      presence.mode == .document,
      presence.focusedItemID == documentID,
      model.documentPageSelection == nil,
      presence.documentPageIndex >= layout.pageCount
    else { return }
    _ = model.selectDocumentPage(
      layout.pageCount - 1,
      documentID: documentID
    )
  }

  private func preparesContent(
    _ itemID: UUID,
    presence: SessionPresence
  ) -> Bool {
    if let focusedItemID = presence.focusedItemID {
      return focusedItemID == itemID
        && (presence.openProgress > 0 || presence.mode == .page || presence.mode == .document)
    }
    // Selection keeps the cover address, not an invisible WebKit/page pool.
    // Only explicit navigation prepares paper content; zoom never acquires it.
    return false
  }

  private func handleBoardMagnification(_ phase: WorkspaceMagnificationPhase) {
    switch phase {
    case .began(let centroid):
      // A short explicit navigation owns its complete opening/closing curve.
      // A contact during it must not strand the scene on a half-open cover.
      guard !settling else { return }
      interruptSettlementForInput()
      model.cancelElementManipulation()
      guard let currentPresence = model.presence else { return }
      let presence = presenceForNewContact(currentPresence)
      contentGestureActive = presence.mode == .page || presence.mode == .document
      cameraGesture = CameraGestureSnapshot(
        presence: presence,
        trajectory: CameraGestureTrajectory(startingCamera: presence.camera,
          startingCentroid: centroid, viewport: presence.viewport)
      )
    case .changed(let scale, _, _, let centroid):
      updateMagnification(
        scale: scale,
        centroid: centroid
      )
    case .ended(let scale, _, _, let centroid):
      updateMagnification(
        scale: scale,
        centroid: centroid
      )
      settleMagnification()
    case .cancelled:
      contentGestureActive = false
      cancelMagnification()
    }
  }

  private func handleWorkspaceMagnification(
    _ phase: WorkspaceMagnificationPhase
  ) {
    if case .began = phase { referencePageResolution.cancel() }
    if pageInputGestureID != nil {
      bufferCameraPhase(phase)
      return
    }
    if case .began = phase, model.presence?.mode == .page {
      let gestureID = UUID()
      pageInputGestureID = gestureID
      bufferedCameraPhases = [phase]
      model.inputGate.performAfterPageContact {
        guard pageInputGestureID == gestureID else { return }
        let phases = bufferedCameraPhases
        pageInputGestureID = nil
        bufferedCameraPhases = []
        for buffered in phases {
          handleBoardMagnification(buffered)
        }
      }
      return
    }
    handleBoardMagnification(phase)
  }

  /// While the page finishes a Pencil action, the two-finger recognizer keeps
  /// measuring. Its newest complete state is enough to resume the same closed
  /// camera formula without inventing a second gesture.
  private func bufferCameraPhase(_ phase: WorkspaceMagnificationPhase) {
    switch phase {
    case .began:
      bufferedCameraPhases = [phase]
    case .changed:
      if bufferedCameraPhases.count > 1 {
        bufferedCameraPhases.removeSubrange(1...)
      }
      bufferedCameraPhases.append(phase)
    case .ended, .cancelled:
      if bufferedCameraPhases.count > 1 {
        bufferedCameraPhases.removeSubrange(1...)
      }
      bufferedCameraPhases.append(phase)
    }
  }

  /// A pinch owns only the camera. Opening and Back are explicit navigation,
  /// including nested boards; no threshold may change the gesture's surface.
  private func updateMagnification(scale: CGFloat, centroid: CGPoint) {
    guard let snapshot = cameraGesture else { return }
    let camera = snapshot.trajectory.camera(at: scale, centroid: centroid,
      maximumScale: SpatialCamera.maximumScale)
    model.updatePresence(snapshot.presence.replacingCamera(camera), settled: false)
  }

  private func settleMagnification() {
    guard cameraGesture != nil, let presence = model.presence else { return }
    cameraGesture = nil
    contentGestureActive = false
    model.updatePresence(presence, settled: true)
  }

  private func cancelMagnification() {
    guard let snapshot = cameraGesture else { return }
    cameraGesture = nil
    animateSettlement(to: snapshot.presence, duration: 0.26)
  }

  private func interruptSettlementForInput() {
    model.presentationPlayer.interrupt()
    cameraSettlement.cancel()
    if settling { contentGestureActive = false }
    settling = false
  }

  private func updateWorkspacePan(
    _ translation: CGPoint,
    viewport: SpatialPoint
  ) {
    guard let start = panStart else { return }
    var camera = start.camera
    camera.pan(screenX: translation.x, screenY: translation.y)
    if start.mode == .page || start.mode == .document, let item = start.focusedItemID,
      let center = model.boardHierarchy?.focusedCenter(of:item,in:start.boardID) {
      camera = model.itemGeometry(item).readingCamera(camera,centeredOn:center,viewport:viewport)
    }
    model.updatePresence(
      SessionPresence(
        boardID: start.boardID,
        mode: start.mode,
        camera: camera,
        viewport: viewport,
        focusedItemID: start.focusedItemID,
        openProgress: start.openProgress,
        documentPageIndex: start.documentPageIndex
      ),
      settled: false
    )
  }

  private func presenceForNewContact(_ presence: SessionPresence) -> SessionPresence {
    guard let itemID = presence.focusedItemID, model.isItemBeingDeleted(itemID) else { return presence }
    return SessionPresence(boardID: presence.boardID, mode: .board,
      camera: presence.camera, viewport: presence.viewport)
  }

  private func finishWorkspacePan(
    _ translation: CGPoint?,
    viewport: SpatialPoint
  ) {
    guard panStart != nil else { return }
    if let translation { updateWorkspacePan(translation, viewport: viewport) }
    panStart = nil
    // A pinch may already own the camera when its preceding one-finger pan
    // publishes cancellation. Only the current camera owner may settle it.
    if cameraGesture == nil, let presence = model.presence {
      model.updatePresence(presence, settled: true)
    }
  }

  private func showReference(_ reference: CollaborationReference, location: NotebookReferenceLocation, viewport: SpatialPoint) {
    model.observeNavigation("view_apply", reference: reference)
    let target = reference.target
    switch location {
    case .board(let boardID, let center, let region):
      let scale = min(1.5,max(SpatialCamera.minimumScale,min(viewport.x/(region.width+100),viewport.y/(region.height+100))))
      animateSettlement(to:.init(boardID:boardID,mode:.board,camera:.init(center:center,scale:scale),viewport:viewport),duration:0.3,
        navigationID: reference.id) { model.completeShow(reference) }
    case .item(let boardID, let itemID, let center, let geometry):
      if target.kind != .page { model.selectItem(itemID) }
      var pageIndex = reference.pageIndex ?? 0
      if target.kind == .document, let id = reference.elementID, let document = model.documents[itemID],
        let region = DocumentRenderRegistry.shared.regions(document: document).first(where: { $0.id == id }) { pageIndex = region.pageIndex }
      let mode: WorkspaceSemanticMode = target.kind == .page ? .page : target.kind == .document ? .document : .cover
      if mode == .document { model.prepareDocumentOpening(itemID, pageIndex: pageIndex, boardID: boardID, restoreReading: false) }
      // The reference is a requested destination. A camera settlement cannot
      // publish it as the native page before its physical landing.
      let actualPage = model.presence?.focusedItemID == itemID ? model.presence?.documentPageIndex ?? 0 : 0
      animateSettlement(to:.init(boardID:boardID,mode:mode,camera:.init(center:center,scale:mode == .cover ? geometry.coverScale(viewport:viewport) : geometry.fitScale(viewport:viewport)),
        viewport:viewport,focusedItemID:itemID,openProgress:mode == .cover ? 0 : 1,documentPageIndex:mode == .document ? actualPage : pageIndex),duration:0.3,
        navigationID: reference.id) { model.completeShow(reference) }
      if target.kind == .document {
        let navigationGeneration = model.navigationGeneration
        referencePageResolution.start(requestID: reference.id, documentID: itemID, isCurrent: {
          model.navigationGeneration == navigationGeneration
            && (settling || model.presence?.focusedItemID == itemID)
            && model.requestedReturn == nil
            && (model.requestedReference == nil || model.requestedReference?.id == reference.id)
        }, resolve: {
          guard !settling, let document = model.documents[itemID]
          else { return nil }
          if let blockID = reference.elementID {
            return DocumentRenderRegistry.shared.regions(document: document)
              .first(where: { $0.id == blockID })?.pageIndex
          }
          return pageIndex
        }, apply: { resolvedPage in
          _ = model.selectDocumentPage(resolvedPage, documentID: itemID)
        })
      }
    }
  }

  private func openItem(
    _ itemID: UUID,
    viewport: SpatialPoint
  ) {
    guard !settling, !model.isItemBeingDeleted(itemID),
      cameraGesture == nil,
      let presence = model.presence,
      let center = focusedCenter(itemID: itemID, boardID: presence.boardID)
    else { return }
    model.cancelRequestedNavigation()
    referencePageResolution.cancel()
    if itemKind(itemID) == .board {
      enterBoard(itemID, center: center, viewport: viewport)
      return
    }
    let previousPresence = model.presence
    model.selectItem(itemID)
    if itemKind(itemID) == .document {
      model.prepareDocumentOpening(itemID, pageIndex: documentPageIndex(for: itemID, from: previousPresence))
    }
    let target = SessionPresence(
      boardID: previousPresence?.boardID ?? WorkspaceRoot.boardID,
      mode: openMode(for: itemID),
      camera: itemKind(itemID) == .document ? model.documentReadingCamera(itemID, center: center, viewport: viewport)
        : SpatialCamera(center: center, scale: model.itemGeometry(itemID).fitScale(viewport: viewport)),
      viewport: viewport,
      focusedItemID: itemID,
      openProgress: 1,
      documentPageIndex: documentPageIndex(
        for: itemID,
        from: previousPresence
      )
    )
    openingFeedback.prepare()
    performOpeningFeedback()
    animateSettlement(to: target, duration: 0.3, bounce: 0.025)
  }

  private func enterBoard(
    _ itemID: UUID,
    center: WorldPoint,
    viewport: SpatialPoint,
    duration: TimeInterval = 0.24
  ) {
    guard !model.isItemBeingDeleted(itemID), let presence = model.presence else { return }
    model.selectItem(itemID)
    animateSettlement(to: SessionPresence(boardID: presence.boardID, mode: .cover,
      camera: BoardPortalProjection.parentBoundaryCamera(portalCenter: center, viewport: viewport),
      viewport: viewport, focusedItemID: itemID, openProgress: 1), duration: duration, bounce: 0.025) {
      model.enterBoard(itemID)
    }
  }

  private func leaveBoard(viewport: SpatialPoint) {
    cameraSettlement.cancel()
    guard model.leaveBoard(), let boundary = model.presence else { return }
    animateSettlement(to: SessionPresence(boardID: boundary.boardID, mode: .board,
      camera: SpatialCamera(center: boundary.camera.center,
        scale: WorkspaceItemGeometry.notebook.coverScale(viewport: viewport)),
      viewport: viewport), duration: 0.34, bounce: 0.025)
  }

  private func itemKind(_ itemID: UUID) -> WorkspaceItemKind? {
    model.workspace?.item(id: itemID)?.kind ?? model.compositionTiles.published?.frame.index.item(id: itemID)?.kind
  }

  private func animateSettlement(
    to target: SessionPresence,
    duration: TimeInterval,
    bounce: Double = 0.08,
    navigationID: UUID? = nil,
    completion: @escaping () -> Void = {}
  ) {
    guard let start = model.presence else { return }
    let wasSettling = settling
    cameraGesture = nil
    panStart = nil
    pageInputGestureID = nil
    bufferedCameraPhases = []
    settling = true
    let accepted = cameraSettlement.start(from: start, to: target, duration: duration, bounce: bounce, navigationID: navigationID) { presence, settled in
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) { model.updatePresence(presence, settled: settled) }
    } completion: {
      contentGestureActive = false
      settling = false
      completion()
    }
    if !accepted { settling = wasSettling }
  }

  private func performOpeningFeedback() {
      openingFeedback.impactOccurred(intensity: 0.6)
      openingFeedback.prepare()
  }

  private func createItem(
    kind: WorkspaceItemKind,
    paperSize: DocumentPaperSize = .a4,
    presence: SessionPresence,
    viewport: SpatialPoint
  ) {
    let offset = Double(model.workspace?.items.count ?? 0) * 28
    guard let center = presence.camera.center.addressOffset(x: offset, y: offset) else { return }
    model.cancelRequestedNavigation()
    referencePageResolution.cancel()
    let itemID: UUID?
    switch kind {
    case .notebook:
      itemID = model.createNotebook(at: center)
    case .document:
      itemID = model.createDocument(at: center, paperSize: paperSize)
    case .board:
      itemID = model.createBoard(at: center)
    }
    guard let itemID else { return }
    model.endSurfaceEditing()
    let target = SessionPresence(
      boardID: presence.boardID,
      mode: .cover,
      camera: SpatialCamera(
        center: center,
        scale: model.itemGeometry(itemID).coverScale(viewport: viewport)
      ),
      viewport: viewport,
      focusedItemID: itemID,
      openProgress: 0
    )
    animateSettlement(to: target, duration: 0.42)
  }

  private func openMode(for itemID: UUID) -> WorkspaceSemanticMode {
    switch itemKind(itemID) {
    case .document: return .document
    case .notebook: return .page
    case .board, nil: return .board
    }
  }

  private func documentPageIndex(
    for itemID: UUID?,
    from presence: SessionPresence?
  ) -> Int {
    guard let itemID,
      itemKind(itemID) == .document,
      presence?.focusedItemID == itemID
    else { return 0 }
    return presence?.documentPageIndex ?? 0
  }

  private func liftRank(of itemID: UUID) -> Double? {
    liftedItemIDs.firstIndex(of: itemID).map { 9_000 + Double($0) }
  }

  private func dropItem(
    _ itemID: UUID,
    at center: WorldPoint,
    presence: SessionPresence
  ) -> WorkspaceItemPoseDestination? {
    guard model.presence?.boardID == presence.boardID,
      !model.isItemBeingDeleted(itemID), let before = model.boardHierarchy?.board(presence.boardID),
      let cohort = model.compositionTiles.published,
      let moving = model.presentedItem(id: itemID, cohort: cohort, presence: presence)
    else { return nil }
    let target = model.presentedWorkset(cohort: cohort, boardID: presence.boardID, presence: presence).items
      .reversed()
      .first { candidate in
        guard candidate.id != itemID else { return false }
        let delta = center.delta(to: candidate.center)
        return abs(delta.x) <= (moving.geometry.width + candidate.geometry.width) * 0.3
          && abs(delta.y) <= (moving.geometry.height + candidate.geometry.height) * 0.3
      }
    if model.board?.stack(containing: itemID) != nil {
      model.unstackItem(itemID, at: center)
    } else {
      model.moveItem(itemID, to: center)
    }

    if let target {
      _ = model.stackItem(moving.id, onto: target.id)
    }
    guard let board = model.board else { return nil }
    return .init(itemID: itemID, before: before, after: board)
  }

}

private struct WorkspaceSceneItem: View {
  @Environment(NotebookAppModel.self) private var model
  let rendered: RenderedWorkspaceItem
  let document: DocumentDocument?
  let documentState: DocumentStateJournal?
  let documentPageIndex: Int
  let documentPageLayout: DocumentPageLayout?
  private var documentPageCount: Int {
    guard let document else { return 1 }
    return documentPageLayout?.pageCount(for: NotebookAppModel.documentPageSourceRevision(document)) ?? 1
  }
  let camera: SpatialCamera
  let projectedScale: Double
  let boardID: UUID
  let coverElements: [SpatialElement]
  let viewport: SpatialPoint
  let isFocused: Bool
  let preparesCoverMotion: Bool
  let preparesContent: Bool
  let openProgress: Double
  let contentIsInteractive: Bool
  let pageNavigationIsEnabled: Bool
  let isSelected: Bool
  let liftRank: Double?
  private var isLifted: Bool { liftRank != nil }
  let editingTextID: String?
  let spatialInkSurfaces: SpatialInkSurfaceRegistry
  let onDrop: (UUID, WorldPoint) -> WorkspaceItemPoseDestination?
  let onSelect: (UUID) -> Void
  let onLiftChanged: (UUID, Bool) -> Void
  let onOpen: (UUID) -> Void
  let onTextEditingEnded: (String) -> Void
  let onPageTurnStateChange: @MainActor @Sendable (Bool) -> Void
  let onDocumentPageLayout: (DocumentPageLayout) -> Void

  var body: some View {
    let contentIsLive = openProgress > 0.001 || contentIsInteractive
    let restingShadowVisibility =
      CoverOpeningPhysics.restingShadowVisibility(openProgress)
    WorkspaceItemPose(rendered: rendered, camera: camera, viewport: viewport, boardID: boardID,
      liftRank: liftRank, registry: spatialInkSurfaces,
      onLiftChanged: { lifted in
        if lifted { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
        onLiftChanged(rendered.id, lifted)
      }, onDrop: { onDrop(rendered.id, $0) }) {
      ZStack {
      WorkspaceItemShadow(geometry: rendered.geometry,
        lifted: isLifted, visibility: restingShadowVisibility)
      WorkspaceItemDepthView(kind: rendered.item.kind, geometry: rendered.geometry)
        .opacity(max(0, 1 - openProgress * 2))
      if rendered.item.kind == .board {
        itemCover
      } else if rendered.item.kind == .notebook {
        notebookContents(isLive: contentIsLive)
      } else {
        documentContents(isLive: contentIsLive)
      }
    }
    .frame(
      width: rendered.geometry.width,
      height: rendered.geometry.height
    )
    // Accessibility follows the same physical body as camera and Pencil;
    // exposed page edges retain their purely visual depth.
    .contentShape(.accessibility, RoundedRectangle(
      cornerRadius: rendered.geometry.cornerRadius, style: .continuous
    ))
    .overlay {
      if openProgress < 0.12, isSelected {
        RoundedRectangle(
          cornerRadius: rendered.geometry.cornerRadius,
          style: .continuous
        )
        .stroke(
          Color.accentColor.opacity(0.72),
          lineWidth: 2 / max(projectedScale, 0.0125)
        )
        .allowsHitTesting(false)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(rendered.item.title.isEmpty
      ? (rendered.item.kind == .notebook ? "Тетрадь" : rendered.item.kind == .document ? "Документ" : "Доска")
      : rendered.item.title)
    .accessibilityIdentifier(
      "workspace-item-\(rendered.id.uuidString.lowercased())"
    )
    .accessibilityAddTraits(.isButton)
    .accessibilityValue(
      isLifted ? "Готова к перемещению" : (isSelected ? "Выбрана" : "")
    )
    }
    .frame(width: viewport.x, height: viewport.y)
  }

  @ViewBuilder
  private func notebookContents(isLive: Bool) -> some View {
    if preparesContent, let root = model.notebookPageRoot(notebookItem.id) {
      PageTurnSurface(
        ownerID: rendered.id,
        sequenceRevision: root,
        pageCount: model.notebookPageCount(notebookItem.id) + 1,
        selectedIndex: notebookSelectedPageIndex,
        allowsTrailingPageCreation: true,
        navigationIsEnabled: pageNavigationIsEnabled,
        pageIsInteractive: contentIsInteractive,
        canBeginNavigation: {
          model.inputGate.permitsPageNavigation && !model.selectionSession.isInteractive && paperFitsViewport
        },
        page: { index, isCurrent, readiness in
          notebookPage(
            at: index,
            isCurrent: isCurrent,
            isLive: isLive,
            onRenderReady: readiness
          )
        },
        onCommit: commitNotebookPage,
        onTransitioningChange: onPageTurnStateChange
      )
      .clipShape(
        RoundedRectangle(
          cornerRadius: rendered.geometry.cornerRadius,
          style: .continuous
        )
      )
    }

    CoverOpeningSurface(
      ownerID: rendered.id,
      progress: openProgress,
      revision: coverRenderingRevision,
      backsideColor: WorkspaceCoverMaterial(item: rendered.item).backside,
      preparesCoverMotion: preparesCoverMotion
    ) {
      itemCover
    }
  }

  @ViewBuilder
  private func documentContents(isLive: Bool) -> some View {
    if preparesContent, let document, let documentState {
      PageTurnSurface(
        ownerID: rendered.id,
        sequenceRevision: "\(document.contentStamp.actor):\(document.contentStamp.counter)",
        pageCount: max(documentPageCount, documentPageIndex + 1),
        selectedIndex: documentPageIndex,
        allowsTrailingPageCreation: false,
        navigationIsEnabled: pageNavigationIsEnabled,
        pageIsInteractive: contentIsInteractive,
        canBeginNavigation: {
          model.inputGate.permitsPageNavigation && !model.selectionSession.isInteractive && paperFitsViewport
        },
        page: { index, isCurrent, readiness in
          documentPage(
            document: document,
            state: documentState,
            index: index,
            isCurrent: isCurrent,
            isVisible: isLive,
            onRenderReady: readiness
          )
        },
        onCommit: { _, _ in },
        onTransitioningChange: onPageTurnStateChange,
        canonicalDocumentLayout: documentPageLayout,
        documentSelection: model.documentPageSelection,
        documentNavigation: .init(
          bind: { model.bindDocumentPageController($0, documentID: $1, source: $2) },
          unbind: model.unbindDocumentPageController,
          landed: { landing in
            if model.acceptDocumentPageLanding(landing) { announcePage(landing.pageIndex + 1) }
          },
          status: model.acceptDocumentPageNavigationStatus)
      )
      .background(Color(red: 0.985, green: 0.98, blue: 0.955))
      .clipShape(
        RoundedRectangle(
          cornerRadius: rendered.geometry.cornerRadius,
          style: .continuous
        )
      )
      .opacity(isLive ? 1 : 0)
    }
    CoverOpeningSurface(
      ownerID: rendered.id,
      progress: openProgress,
      revision: coverRenderingRevision,
      backsideColor: WorkspaceCoverMaterial(item: rendered.item).backside,
      preparesCoverMotion: preparesCoverMotion
    ) {
      itemCover
    }
  }

  private var notebookItem: WorkspaceItem {
    model.itemForDisplay(id: rendered.id) ?? rendered.item
  }

  /// A zoomed sheet gives horizontal finger motion to its camera. Explicit
  /// folio commands still use the page controller's external-selection path.
  private var paperFitsViewport: Bool {
    guard let presence = model.presence, presence.focusedItemID == rendered.id else { return false }
    return presence.camera.scale <= rendered.geometry.fitScale(viewport: presence.viewport) * 1.001
  }

  private var notebookSelectedPageIndex: Int {
    guard let selectedPageID = model.workspace?.selectedPageID,
      let index = model.notebookPageIndex(selectedPageID, in: notebookItem.id)
    else { return 0 }
    return index
  }

  private func notebookPage(
    at index: Int,
    isCurrent: Bool,
    isLive: Bool,
    onRenderReady: PageTurnReadiness
  ) -> AnyView {
    guard index >= 0, index < model.notebookPageCount(notebookItem.id) else {
      return AnyView(
        BlankPageSurface(fallbackSize: model.notebookPageSize)
          .onAppear { onRenderReady(index == model.notebookPageCount(notebookItem.id)) }
      )
    }
    guard let page = model.notebookPage(at: index, in: notebookItem.id) else {
      return AnyView(
        BlankPageSurface(fallbackSize: model.notebookPageSize)
          .overlay { ProgressView().allowsHitTesting(false) }
          .onAppear { onRenderReady(false) }
          .task { await model.prepareNotebookPage(at: index, in: notebookItem.id) }
          .accessibilityLabel("Загружается лист \(index + 1)")
      )
    }
    return AnyView(
      PageSurface(
        page: page,
        isCurrent: isCurrent,
        isInteractive: isCurrent && contentIsInteractive,
        isVisible: isLive,
        onRenderReady: onRenderReady,
        displayProjection: rendered.geometry.fitScale(viewport: viewport)
      )
    )
  }

  private func documentPage(
    document: DocumentDocument,
    state: DocumentStateJournal,
    index: Int,
    isCurrent: Bool,
    isVisible: Bool,
    onRenderReady: PageTurnReadiness
  ) -> AnyView {
    AnyView(
      DocumentWebView(
        document: document,
        state: state,
        isInteractive: isCurrent && contentIsInteractive,
        selectedPageIndex: index,
        capturesSnapshot: isCurrent,
        onRenderReady: onRenderReady,
        onPageLayout: onDocumentPageLayout,
        onLinkActivation: { activation in
          model.activateDocumentLink(activation)
        },
        onStateChange: { blockID, value in
          model.commitDocumentState(
            documentID: document.id,
            blockID: blockID,
            value: value,
            sourceVersion: document.sourceVersion(blockID: blockID)
          )
        },
        isCurrent: isCurrent,
        isVisible: isVisible,
        onStateCheckpoint: { blockID, value, sourceVersion, stateVersion in
          try await model.checkpointDocumentState(documentID: document.id, blockID: blockID,
            value: value, sourceVersion: sourceVersion, stateVersion: stateVersion)
        }, measurements: model.documentMeasurements
      )
    )
  }

  private func commitNotebookPage(_ targetIndex: Int, _ root: String) {
    guard model.selectNotebookPage(
      targetIndex,
      notebookID: rendered.id, expectedRoot: root
    ) != nil else { return }
    announcePage(targetIndex + 1)
  }


  private func announcePage(_ number: Int) {
      UISelectionFeedbackGenerator().selectionChanged()
      UIAccessibility.post(
        notification: .pageScrolled,
        argument: "Страница \(number)"
      )
  }

  private var itemCover: some View {
    WorkspaceItemCoverView(
      item: rendered.item,
      boardID: boardID,
      geometry: rendered.geometry,
      spatialInkSurfaces: spatialInkSurfaces,
      elements: coverElements,
      editingTextID: editingTextID,
      portalOpenProgress: openProgress,
      portalViewport: viewport,
      onTap: handleTap,
      onTextEditingEnded: onTextEditingEnded,
      showsDepth: false,
      portalPixelScale: projectedScale
    )
  }


  private var coverRenderingRevision: CoverRenderingRevision {
    CoverRenderingRevision(
      item: rendered.item,
      geometry: rendered.geometry,
      elements: coverElements,
      journal: model.spatialInk
    )
  }

  private func handleTap(_ point: CGPoint, tapCount: Int) {
    guard openProgress < 0.999, !model.isItemBeingDeleted(rendered.id) else { return }
    if model.drawingTool == .text {
      model.beginToolText(at:.init(x:point.x,y:point.y),address:.init(surface:.cover(rendered.id),
        boardID:boardID,worldOrigin:nil,bounds:.init(x:0,y:0,width:rendered.geometry.width,height:rendered.geometry.height)),
        screenScale:projectedScale)
      return
    }
    onSelect(rendered.id)
    if let editingTextID {
      onTextEditingEnded(editingTextID)
    }
    guard tapCount >= 2 else { return }
    onOpen(rendered.id)
  }

}


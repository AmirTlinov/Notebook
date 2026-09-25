import NotebookCore
import SwiftUI
import UIKit

@MainActor @Observable
private final class CameraGestureSnapshot {
  let id=UUID()
  let presence: SessionPresence
  let trajectory: CameraGestureTrajectory
  let entry: NotebookZoomPassage?
  let exit: NotebookZoomPassage?
  var passage: NotebookZoomPassage?
  @ObservationIgnored var choseDirection = false
  @ObservationIgnored var latestCamera: SpatialCamera
  @ObservationIgnored var preparedItem = false
  @ObservationIgnored var magnification:CGFloat = 1
  @ObservationIgnored var centroid:CGPoint
  @ObservationIgnored var paperReadiness: (@MainActor () -> Bool)?
  var passageCamera:SpatialCamera? { passage.map { $0.camera(from:trajectory,magnification:magnification,centroid:centroid) } }
  init(presence:SessionPresence,trajectory:CameraGestureTrajectory,entry:NotebookZoomPassage?,exit:NotebookZoomPassage?) {
    self.presence=presence;self.trajectory=trajectory;self.entry=entry;self.exit=exit;latestCamera=presence.camera;centroid=trajectory.startingCentroid
  }
  var preparation: SessionPresence? {
    guard let passage,let camera=passageCamera else { return nil }
    return passage.presentation(camera:camera,viewport:presence.viewport,page:presence.documentPageIndex)
  }
}

@MainActor
private final class WorkspaceSettlement {
  let id=UUID()
  let origin:SessionPresence
  let target:SessionPresence
  let handoff:SessionPresence?
  var preparation:SessionPresence { handoff ?? target }
  var paperReadiness: (@MainActor () -> Bool)?
  let duration:TimeInterval
  let bounce:Double
  let navigationID:UUID?
  let portal:(UUID,BoardPortalCamera)?
  let completion:()->Void
  var started=false
  init(origin:SessionPresence,target:SessionPresence,handoff:SessionPresence?,duration:TimeInterval,bounce:Double,navigationID:UUID?,
    portal:(UUID,BoardPortalCamera)?,completion:@escaping ()->Void) {
    self.origin=origin;self.target=target;self.handoff=handoff;self.duration=duration;self.bounce=bounce;self.navigationID=navigationID
    self.portal=portal;self.completion=completion
  }
}

private enum WorkspaceNavigationState {
  case idle, interacting(CameraGestureSnapshot), settling(WorkspaceSettlement)
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
  @Binding private var chromeHidden: Bool
  @Binding private var documentMode: DocumentViewMode
  init(backRequest: UInt64 = 0, chromeHidden: Binding<Bool> = .constant(false), documentMode: Binding<DocumentViewMode> = .constant(.paper)) {
    self.backRequest=backRequest; self._chromeHidden=chromeHidden; self._documentMode=documentMode
  }
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.displayScale) private var displayScale
  @Environment(NotebookAppModel.self) private var model

  @State private var contextMenus = NotebookContextMenus()
  @State private var navigation = WorkspaceNavigationState.idle
  private var cameraGesture: CameraGestureSnapshot? { if case .interacting(let value)=navigation { value } else { nil } }
  private var settling: Bool { if case .settling=navigation { true } else { false } }
  private var preparationPresence: SessionPresence? {
    switch navigation { case .idle: nil;case .interacting(let value):value.preparation;case .settling(let value):value.preparation }
  }
  private var transitionPortalOverride: SceneCompositionReference.Portal? {
    switch navigation {
    case .interacting(let value):
      if let passage=value.passage,let camera=passage.returningPortal { return .init(boardID:passage.itemID,camera:camera) }
    case .settling(let value): if let portal=value.portal { return .init(boardID:portal.0,camera:portal.1) }
    case .idle: break
    }
    return nil
  }
  private func transitionPortal(_ boardID:UUID) -> BoardPortalCamera? {
    if let override=transitionPortalOverride,override.boardID == boardID { return override.camera }
    return model.scenePortalCamera(boardID:boardID)
  }
  private var navigationID:UUID? {
    switch navigation { case .idle:nil;case .interacting(let value):value.id;case .settling(let value):value.id }
  }
  private func bindPaperReadiness(itemID:UUID,transitionID:UUID?,probe:@escaping @MainActor ()->Bool) {
    guard transitionID == navigationID else { return }
    switch navigation {
    case .interacting(let snapshot): if snapshot.passage?.itemID == itemID { snapshot.paperReadiness=probe }
    case .settling(let pending): if pending.target.focusedItemID == itemID { pending.paperReadiness=probe }
    case .idle: break
    }
  }
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
      let preparing = preparationPresence ?? presence
      let requestedFrame = model.sceneIndex.map {
        WorkspaceSceneFrame(index:$0,presence:preparing,portalCamera:transitionPortal,
          pinned:scenePins(presence:preparing))
      }
      let cohort = model.compositionTiles.published.flatMap {
        $0.plan.presentations[.board(presence.boardID)] != nil ? $0 : nil
      }
      let frame = cohort?.frame
      let compositionRequest = CompositionRequest(presence: preparing, generation: model.sceneIndex?.generationID,
        publication: model.scenePublicationGeneration,
        revision:model.workspaceHeader?.cursor,pinned:scenePins(presence:preparing),
        itemOwners:sceneItemOwners(presence:preparing,cohort:cohort),
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
              && cameraGesture == nil && !settling && !model.isPointing,
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
            onUndo: model.undoLastSurfaceAction,
            onRedo: model.redoLastSurfaceAction
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
            scale: presence.camera.scale, camera:presence)
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
            NotebookMultipleElementControls(contextMenus:contextMenus,selectionID:model.selectionSession.id,frames:frames,scale:presence.camera.scale,camera:presence)
              .frame(width:viewport.x,height:viewport.y)
          }
        }
        NotebookContextMenuHost(owner:contextMenus,gate:model.inputGate).zIndex(9_600)
        NotebookSelectionGesture(inputGate: model.inputGate,
          onPoint: { end, tapCount in
          guard cameraGesture == nil, !settling, let cohort else { return }
          let contactGeneration=model.inputGate.acceptedContactGeneration
          let hadSelection=model.selectionSession.target != nil
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
          case nil:
            model.clearSelection()
            if tapCount == 1,!hadSelection { confirmBlankTap(generation:contactGeneration,presence:presence) }
            return
          }
          if let reference=editableReference(fragment,boardID:presence.boardID) {
            if model.selectionSession.addingElements { model.toggleGraphicSelection(reference);return }
            model.selectElement(reference)
            if tapCount > 1 { model.editSelectedElement(reference) }
          } else if fragment.target.kind == .cover {
            model.selectWorkspaceItem(fragment.target.id,boardID:presence.boardID)
          } else if let contact=NotebookAttentionProjection.toolAddress(at:end,fragment:fragment,model:model,presence:presence) {
            model.drawingTools.selectInk(at:contact.point,address:contact.address,screenScale:presence.camera.scale) { found in
              if !found,tapCount == 1,!hadSelection { confirmBlankTap(generation:contactGeneration,presence:presence) }
            }
          } else { model.clearSelection() }
        }, onLift: { point in
          guard cameraGesture == nil, !settling, !model.selectionSession.isInteractive, let cohort else { return nil }
          let selected = selectedElement(at: point, presence: presence)
          let hit=selected == nil ? NotebookAttentionProjection.pointContact(at:point,model:model,presence:presence,cohort:cohort) : nil
          guard let reference=selected ?? hit.flatMap({ editableReference($0,boardID:presence.boardID) }) else { return nil }
          if model.selectionSession.addingElements, !model.selectionSession.contains(reference) {
            return nil
          }
          let scale = max(presence.camera.scale, 0.001)
          var contactID: UUID?
          func translation(_ delta: CGPoint) -> SpatialPoint { .init(x: delta.x / scale, y: delta.y / scale) }
          return SceneSelectionLift(requiresHold: selected == nil, begin: {
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
        }, onHold: { point in showContextMenu(at:point,presence:presence,cohort:cohort) }).allowsHitTesting(false)
        if let rect = model.selectionSession.preview {
          RoundedRectangle(cornerRadius: 4).stroke(.indigo, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY).allowsHitTesting(false)
        }
          NotebookDisplayConfirmation(preparedSource:model.preparedCollaborationVersion) {
            advancePreparedNavigation()
            guard cameraGesture == nil, !settling, !pageTurnIsActive, !contentGestureActive else { return false }
            model.prepareCommonDocumentShellIfIdle(presence: presence, cohort: cohort)
            return model.confirmVisibleActions(presence: presence, scene: workset, cohort: cohort)
          }.allowsHitTesting(false)

        controls(presence:presence,viewport:viewport)
          .opacity(chromeHidden && !navigationNeedsAttention ? 0 : 1)
          .allowsHitTesting(!chromeHidden || navigationNeedsAttention)
          .accessibilityHidden(chromeHidden && !navigationNeedsAttention)
          .environment(\.notebookChromeVisible,!chromeHidden || navigationNeedsAttention)
      }
      .clipped()
      .accessibilityAction(named:"Параметры и действия") {
        showCanvasContext(at:.init(x:viewport.x/2,y:viewport.y/2),presence:presence)
      }
      .accessibilityAction(named:"Назад") { returnToParent() }
      .environment(\.sceneComposition, .init(cohort,portal:transitionPortalOverride))
      .task(id: compositionRequest) {
        model.prepareComposition(presence:preparing,frame:requestedFrame,
          pinned: compositionRequest.pinned, displayScale: displayScale, installedItemOwners: compositionRequest.itemOwners)
      }
      .onAppear {
        contextMenus.selectionActions = { id,point in selectionContextActions(id,at:point) }
        model.stopNavigationPresentation = { requestID in
          referencePageResolution.cancel()
          guard case .settling(let pending)=navigation,pending.navigationID == requestID else { return }
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
          interruptSettlementForInput(interruptPresentation:false)
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
        replaceWaitingNavigation()
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
        replaceWaitingNavigation()
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
        returnToParent()
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
        contextMenus.dismissPresentedContent()
        model.endSurfaceEditing()
        if mode != .cover { model.interactiveElementFocus = nil }
        if mode != .page && mode != .document {
          pageTurnIsActive = false
        }
      }
      .onChange(of: presence.boardID) { _,_ in contextMenus.dismissPresentedContent() }
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
        navigation = .idle
        contentGestureActive = false
        pageTurnIsActive = false
        pageInputGestureID = nil
        bufferedCameraPhases = []
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
        open:{ openItem(selectedItemID,viewport:viewport) },camera:presence,cornerRadius:rendered.geometry.cornerRadius)
        .frame(width:viewport.x,height:viewport.y)
        .zIndex(9_500)
    }
  }

  private var navigationNeedsAttention: Bool {
    model.documentPageNavigationStatus?.phase == .failed
      || model.notebookPageNavigation.status?.failure != nil
      || model.documentSavePresentation?.phase == .saved
  }

  private func controls(
    presence: SessionPresence,
    viewport: SpatialPoint
  ) -> some View {
    NotebookNavigationView(presence: presence,
      documentPageCount: presence.focusedItemID.flatMap { id in
        model.documents[id].flatMap { documentPageLayouts[id]?.pageCount(for: NotebookAppModel.documentPageSourceRevision($0)) }
      })
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(.leading, 18).padding(.top, 18).zIndex(10_000)
  }

  private func contextDestination(at point:CGPoint,presence:SessionPresence) -> NotebookPasteDestination? {
    guard let destination=model.pasteDestination else { return nil }
    if destination.target.kind == .board {
      let origin=presence.camera.screenToWorld(.init(x:point.x,y:point.y),viewport:presence.viewport)
      return .init(target:destination.target,title:destination.title,center:.zero,
        availableSize:destination.availableSize,worldOrigin:origin)
    }
    guard let frame=NotebookAttentionProjection.frame(.init(target:destination.target,revision:""),model:model,presence:presence) else { return destination }
    return .init(target:destination.target,title:destination.title,
      center:.init(x:(point.x-frame.minX)/presence.camera.scale,y:(point.y-frame.minY)/presence.camera.scale),
      availableSize:destination.availableSize,worldOrigin:nil)
  }

  private func confirmBlankTap(generation:UInt64,presence:SessionPresence) {
    Task { @MainActor in
      try? await Task.sleep(for:.milliseconds(300))
      guard model.inputGate.acceptedContactGeneration == generation,
        !model.inputGate.isActive, model.presence?.boardID == presence.boardID,
        model.presence?.focusedItemID == presence.focusedItemID,
        model.selectionSession.target == nil, cameraGesture == nil, !settling,
        !contextMenus.hasPresentedMenu, scenePhase == .active else { return }
      chromeHidden.toggle()
    }
  }

  private func showContextMenu(at point:CGPoint,presence:SessionPresence,cohort:SceneCompositionCohort?) {
    guard cameraGesture == nil,!settling,!model.inputGate.hasActivePencil else { return }
    chromeHidden=false
    if let selected=selectedElement(at:point,presence:presence) {
      if !model.selectionSession.contains(selected) { model.selectElement(selected) }
      contextMenus.requestSelectionMenu(model.selectionSession.id,at:point);return
    }
    let hit:NotebookAttentionSelection.Fragment?
    switch NotebookAttentionProjection.pointResolution(at:point,model:model,presence:presence,cohort:cohort) {
    case .pending: return
    case .hit(let value): hit=value
    case nil: hit=nil
    }
    if let hit,let reference=editableReference(hit,boardID:presence.boardID) {
      model.selectElement(reference);contextMenus.requestSelectionMenu(model.selectionSession.id,at:point);return
    }
    if let hit,hit.target.kind == .cover {
      model.selectWorkspaceItem(hit.target.id,boardID:presence.boardID)
      contextMenus.requestSelectionMenu(model.selectionSession.id,at:point);return
    }
    if let hit,let contact=NotebookAttentionProjection.toolAddress(at:point,fragment:hit,model:model,presence:presence) {
      let generation=model.inputGate.acceptedContactGeneration
      model.drawingTools.selectInk(at:contact.point,address:contact.address,screenScale:presence.camera.scale) { found in
        guard model.inputGate.acceptedContactGeneration == generation else { return }
        if found { contextMenus.requestSelectionMenu(model.selectionSession.id,at:point) }
        else { showCanvasContext(at:point,presence:presence) }
      }
    } else { showCanvasContext(at:point,presence:presence) }
  }

  private func showCanvasContext(at point:CGPoint,presence:SessionPresence) {
    model.clearSelection()
    let center=presence.camera.screenToWorld(.init(x:point.x,y:point.y),viewport:presence.viewport)
    let canBack = !model.returnPlaces.isEmpty || presence.mode != .board || presence.boardID != model.workspace?.rootBoardID
    contextMenus.presentContent(NotebookCanvasContextContent(dismiss:{ contextMenus.dismissPresentedContent() },destination:contextDestination(at:point,presence:presence),
      documentMode:$documentMode,allowsBeside:presence.viewport.x > presence.viewport.y,
      create:presence.mode == .board ? { kind,paper in
        guard model.presence?.boardID == presence.boardID,model.presence?.mode == presence.mode else { return }
        createItem(kind:kind,paperSize:paper,presence:presence,viewport:presence.viewport,at:center)
      } : nil,
      back:canBack ? {
        guard model.presence?.boardID == presence.boardID,model.presence?.focusedItemID == presence.focusedItemID else { return }
        returnToParent()
      } : nil).environment(model),at:point)
  }

  private func selectionContextActions(_ selection:UUID,at point:CGPoint) -> [UIMenuElement] {
    guard model.selectionSession.id == selection else { return [] }
    let canCopy=(try? model.clipboardSelectionFragment()) != nil
    let destination=model.presence.flatMap { contextDestination(at:point,presence:$0) }
    func copy(cut:Bool) {
      guard model.selectionSession.id == selection else { return }
      do {
        let fragment=try model.clipboardSelectionFragment()
        UIPasteboard.general.setItems([try NotebookClipboard.representations(fragment)],options:[:])
        if cut,model.selectionSession.id == selection { model.deleteSelectedContent() }
      } catch { model.showCue(error.localizedDescription) }
    }
    var actions=NotebookContextMenus.clipboardActions(cut:canCopy ? { copy(cut:true) } : nil,
      copy:canCopy ? { copy(cut:false) } : nil,paste:destination.map { captured in {
        guard model.selectionSession.id == selection else { return };pasteContext(at:captured,point:point)
      } })
    actions.append(UIAction(title:"Дублировать",image:UIImage(systemName:"plus.square.on.square"),attributes:canCopy ? [] : .disabled) { _ in
      guard model.selectionSession.id == selection else { return }
      model.duplicateSelectedContent()
    })
    return [UIMenu(options:.displayInline,children:actions)]
  }

  private func pasteContext(at destination:NotebookPasteDestination,point:CGPoint) {
    let providers=UIPasteboard.general.itemProviders
    Task {
      do {
        switch try await NotebookClipboard.read(providers,availableSize:destination.availableSize) {
        case .fragment(let fragment): _ = await model.insertClipboardFragment(fragment,at:destination)
        case .composition(let source):
          contextMenus.presentContent(NotebookTldrawCompositionView(destinations:[destination],initialSource:source,
            onClose:{ contextMenus.dismissPresentedContent() }).environment(model).frame(width:600,height:600),at:point)
        }
      } catch { model.showCue(error.localizedDescription) }
    }
  }

  private func returnToParent() {
    guard let presence=model.presence else { return }
    model.cancelRequestedNavigation();referencePageResolution.cancel()
    if !model.returnPlaces.isEmpty { model.requestReturnToPlace() }
    else if presence.mode == .board { leaveBoard(viewport:presence.viewport) }
    else {
      animateSettlement(to:.init(boardID:presence.boardID,mode:.board,
        camera:.init(center:presence.camera.center,scale:model.itemGeometry(presence.focusedItemID).coverScale(viewport:presence.viewport)),
        viewport:presence.viewport),duration:0.3)
    }
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
    let navigationID:UUID?
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
      pageTurn: pageTurnIsActive, navigationID:navigationID, isCameraGesture: cameraGesture != nil, settling: settling,
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
              && cameraGesture == nil
              && !settling
              && presence.openProgress >= 0.999,
            pageNavigationIsEnabled: !model.isPointing && presence.focusedItemID == rendered.id
              && !model.isItemBeingDeleted(rendered.id)
              && (presence.mode == .page || presence.mode == .document)
              && presence.openProgress >= 0.999,
            isSelected: selectedItemID == rendered.id,
            liftRank: liftRank(of: rendered.id),
            editingTextID: editingTextID(on: presence.boardID),
            spatialInkSurfaces: spatialInkSurfaces,
            onDrop: { itemID, center, source in
              dropItem(itemID, at: center, presence: presence, source: source)
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
            onContext: { itemID,point in
              model.selectWorkspaceItem(itemID,boardID:presence.boardID)
              contextMenus.requestSelectionMenu(model.selectionSession.id,at:point)
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
            },
            onPaperReadiness: { [transitionID=navigationID] probe in
              bindPaperReadiness(itemID:rendered.id,transitionID:transitionID,probe:probe)
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
    if preparationPresence?.focusedItemID == itemID { return true }
    if let focusedItemID = presence.focusedItemID {
      return focusedItemID == itemID
        && (presence.openProgress > 0 || presence.mode == .page || presence.mode == .document)
    }
    // Selection keeps the cover address, not an invisible WebKit/page pool.
    // Only the one admitted navigation target prepares paper content.
    return false
  }

  private func handleBoardMagnification(_ phase: WorkspaceMagnificationPhase) {
    switch phase {
    case .began(let centroid):
      // A short explicit navigation owns its complete opening/closing curve.
      // A contact during it must not strand the scene on a half-open cover.
      if case .settling(let pending)=navigation {
        guard !pending.started else { return }
        model.updatePresence(pending.origin,settled:true)
      }
      interruptSettlementForInput()
      model.cancelElementManipulation()
      guard let currentPresence = model.presence else { return }
      let presence = presenceForNewContact(currentPresence)
      contentGestureActive = presence.mode == .page || presence.mode == .document
      navigation = .interacting(CameraGestureSnapshot(presence:presence,
        trajectory:.init(startingCamera:presence.camera,startingCentroid:centroid,viewport:presence.viewport),
        entry:entryPassage(at:centroid,presence:presence),exit:exitPassage(presence:presence)))
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

  private func entryPassage(at point:CGPoint,presence:SessionPresence) -> NotebookZoomPassage? {
    guard presence.mode == .board || presence.mode == .cover,
      let cohort=model.compositionTiles.published else { return nil }
    let candidates=model.presentedWorkset(cohort:cohort,boardID:presence.boardID,presence:presence).items
    guard let item=candidates.filter({ value in
      let box=value.geometry.screenFrame(center:value.center,camera:presence.camera,viewport:presence.viewport)
      return !model.isItemBeingDeleted(value.id) && CGRect(x:box.x,y:box.y,width:box.width,height:box.height).contains(point)
    }).max(by:{ $0.zIndex == $1.zIndex ? $0.id.uuidString < $1.id.uuidString : $0.zIndex < $1.zIndex }) else { return nil }
    let closed=item.geometry.coverScale(viewport:presence.viewport)
    let open=item.item.kind == .board ? BoardPortalProjection.fillScale(viewport:presence.viewport) : item.geometry.fitScale(viewport:presence.viewport)
    return .init(itemID:item.id,parentID:presence.boardID,kind:item.item.kind,center:item.center,geometry:item.geometry,
      opening:true,closedScale:closed,openScale:open,returningPortal:nil)
  }

  private func exitPassage(presence:SessionPresence) -> NotebookZoomPassage? {
    if let id=presence.focusedItemID,(presence.mode == .page || presence.mode == .document),
      let kind=itemKind(id),let center=focusedCenter(itemID:id,boardID:presence.boardID) {
      let geometry=model.itemGeometry(id)
      return .init(itemID:id,parentID:presence.boardID,kind:kind,center:center,geometry:geometry,opening:false,
        closedScale:geometry.coverScale(viewport:presence.viewport),openScale:geometry.fitScale(viewport:presence.viewport),returningPortal:nil)
    }
    guard presence.mode == .board,let hierarchy=model.boardHierarchy,
      let parent=hierarchy.parentBoardID(of:presence.boardID),let center=hierarchy.focusedCenter(of:presence.boardID,in:parent) else { return nil }
    let fill=BoardPortalProjection.fillScale(viewport:presence.viewport),geometry=WorkspaceItemGeometry.notebook
    let entry=BoardPortalProjection.entryCamera(portalCamera:hierarchy.portalCamera(presence.boardID) ?? .init(),viewport:presence.viewport)
    let boundary=min(presence.camera.scale,entry.scale)
    let portal=BoardPortalCamera(center:presence.camera.center,scale:boundary/fill)
    return .init(itemID:presence.boardID,parentID:parent,kind:.board,center:center,geometry:geometry,opening:false,
      closedScale:boundary*geometry.coverScale(viewport:presence.viewport)/fill,
      openScale:boundary,returningPortal:portal)
  }

  private func openSurfaceCamera(_ camera:SpatialCamera,for presence:SessionPresence) -> SpatialCamera {
    guard presence.mode == .page || presence.mode == .document,let item=presence.focusedItemID,
      let center=focusedCenter(itemID:item,boardID:presence.boardID) else { return camera }
    return model.itemGeometry(item).readingCamera(camera,centeredOn:center,viewport:presence.viewport)
  }

  private func updateMagnification(scale: CGFloat, centroid: CGPoint) {
    guard let snapshot=cameraGesture else { return }
    let camera=snapshot.trajectory.camera(at:scale,centroid:centroid,maximumScale:SpatialCamera.maximumScale)
    snapshot.latestCamera=openSurfaceCamera(camera,for:snapshot.presence); snapshot.magnification=scale; snapshot.centroid=centroid
    if !snapshot.choseDirection,abs(log(max(0.001,Double(scale)))) > 0.005 {
      snapshot.choseDirection=true
      snapshot.passage = snapshot.entry == nil ? snapshot.exit : snapshot.exit == nil ? snapshot.entry : scale > 1 ? snapshot.entry : snapshot.exit
    }
    guard let passage=snapshot.passage else {
      model.updatePresence(snapshot.presence.replacingCamera(snapshot.latestCamera),settled:false);return
    }
    let passageCamera=passage.camera(from:snapshot.trajectory,magnification:scale,centroid:centroid)
    let progress=passage.progress(camera:passageCamera)
    if passage.opening && progress <= 0 || !passage.opening && progress >= 1 {
      model.updatePresence(snapshot.presence.replacingCamera(snapshot.latestCamera),settled:false);return
    }
    if passage.opening && !snapshot.preparedItem {
      snapshot.preparedItem=true;model.selectItem(passage.itemID)
      if passage.kind == .document { model.prepareDocumentOpening(passage.itemID,pageIndex:documentPageIndex(for:passage.itemID,from:snapshot.presence)) }
    }
    let shown=passage.presentation(camera:passageCamera,viewport:snapshot.presence.viewport,page:documentPageIndex(for:passage.itemID,from:snapshot.presence))
    // The outgoing surface stays mounted until the bounded target cohort is
    // available. Its camera still follows the same raw gesture while loading.
    if shown.boardID == model.presence?.boardID || navigationHasPreparedSurface(shown) {
      model.updatePresence(shown,settled:false)
    } else { model.updatePresence(snapshot.presence.replacingCamera(camera),settled:false) }
  }

  private func settleMagnification() {
    guard let snapshot=cameraGesture else { return }
    guard let passage=snapshot.passage,let camera=snapshot.passageCamera else {
      navigation = .idle;contentGestureActive=false
      model.updatePresence(snapshot.presence.replacingCamera(snapshot.latestCamera),settled:true);return
    }
    let progress=passage.progress(camera:camera)
    // A zoom which never reaches a hierarchy boundary remains an ordinary zoom.
    if passage.opening && progress == 0 || !passage.opening && progress == 1 {
      navigation = .idle;contentGestureActive=false
      model.updatePresence(snapshot.presence.replacingCamera(snapshot.latestCamera),settled:true);return
    }
    if passage.opening && progress < 0.5 || !passage.opening && progress >= 0.5 {
      let restored:SessionPresence
      if passage.opening { restored=passage.closed(viewport:snapshot.presence.viewport,camera:camera) }
      else { restored=snapshot.presence.replacingCamera(.init(center:snapshot.latestCamera.center,scale:passage.openScale)) }
      restoreMagnification(snapshot,to:restored);return
    }
    if passage.opening {
      navigation = .idle;contentGestureActive=false
      openItem(passage.itemID,viewport:snapshot.presence.viewport,rollback:snapshot.presence)
    } else {
      let target=passage.closed(viewport:snapshot.presence.viewport,camera:camera)
      let handoff=passage.returningPortal.map { _ in
        passage.presentation(camera:camera,viewport:snapshot.presence.viewport)
      }
      animateSettlement(to:target,duration:0.24,bounce:0,portal:passage.returningPortal.map { (passage.itemID,$0) },
        handoff:handoff,rollback:snapshot.presence) {
        if let portal=passage.returningPortal { model.rememberBoardReturn(snapshot.presence,portal:portal) }
      }
    }
  }

  private func navigationHasPreparedSurface(_ target:SessionPresence) -> Bool {
    guard let cohort=model.compositionTiles.published,cohort.plan.presentations[.board(target.boardID)] != nil else { return false }
    if let id=target.focusedItemID {
      guard cohort.plan.allowsLive(.item(id),in:.board(target.boardID)) else { return false }
      if itemKind(id) == .board,target.openProgress > 0 {
        return cohort.plan.presentations[.board(id)] != nil
      }
      if target.mode == .page || target.mode == .document {
        if case .settling(let pending)=navigation { return pending.paperReadiness?() == true }
        if let snapshot=cameraGesture { return snapshot.paperReadiness?() == true }
      }
    }
    return true
  }

  private func advancePreparedNavigation() {
    if case .settling(let pending)=navigation,!pending.started {
      if let item=pending.preparation.focusedItemID,model.isItemBeingDeleted(item) || itemKind(item) == nil {
        interruptSettlementForInput()
        model.showCue("Переход отменён: объект больше недоступен.")
      } else if navigationHasPreparedSurface(pending.preparation),navigationHasPreparedSurface(pending.target) { startSettlement(pending) }
      else if model.compositionTiles.failure != nil || model.persistenceFailure != nil {
        navigation = .idle;contentGestureActive=false
        model.updatePresence(pending.origin,settled:true)
        model.showCue("Не удалось подготовить переход. Исходное место сохранено; попробуйте ещё раз.")
      }
    } else if let snapshot=cameraGesture,let passage=snapshot.passage,let camera=snapshot.passageCamera,
      passage.returningPortal != nil,passage.progress(camera:camera) < 1 {
      let shown=passage.presentation(camera:camera,viewport:snapshot.presence.viewport)
      if navigationHasPreparedSurface(shown),model.presence?.boardID != shown.boardID { model.updatePresence(shown,settled:false) }
    }
  }

  /// Return through the same portal projection before accepting child coordinates.
  /// Jumping straight from a partially visible parent to the child would skip
  /// the remaining part of the gesture and expose a different camera in one frame.
  private func restoreMagnification(_ snapshot:CameraGestureSnapshot,to target:SessionPresence) {
    if let passage=snapshot.passage,let portal=passage.returningPortal,
      model.presence?.boardID == passage.parentID {
      let boundary=passage.presentation(camera:passage.parentCamera(from:target.camera),viewport:target.viewport)
      animateSettlement(to:boundary,duration:0.26,bounce:0,portal:(passage.itemID,portal),rollback:snapshot.presence) {
        model.updatePresence(target,settled:true)
      }
    } else { animateSettlement(to:target,duration:0.26,bounce:0,rollback:snapshot.presence) }
  }

  private func cancelMagnification() {
    guard let snapshot=cameraGesture else { return }
    restoreMagnification(snapshot,to:snapshot.presence)
  }

  private func interruptSettlementForInput(interruptPresentation:Bool = true) {
    if interruptPresentation { model.presentationPlayer.interrupt() }
    cameraSettlement.cancel()
    let origin:SessionPresence?
    switch navigation {
    case .idle: origin=nil
    case .interacting(let gesture): origin=gesture.presence
    case .settling(let pending): origin=pending.origin
    }
    navigation = .idle;contentGestureActive=false
    if let origin { model.updatePresence(origin,settled:true) }
  }

  private func replaceWaitingNavigation() {
    guard case .settling(let pending)=navigation,!pending.started else { return }
    interruptSettlementForInput()
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
    viewport: SpatialPoint,
    rollback: SessionPresence? = nil
  ) {
    guard !settling, !model.isItemBeingDeleted(itemID),
      cameraGesture == nil,
      let presence = model.presence,
      let center = focusedCenter(itemID: itemID, boardID: presence.boardID)
    else { return }
    model.cancelRequestedNavigation()
    referencePageResolution.cancel()
    if itemKind(itemID) == .board {
      enterBoard(itemID, center: center, viewport: viewport,rollback:rollback)
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
    animateSettlement(to: target, duration: 0.3, bounce: 0.025,rollback:rollback)
  }

  private func enterBoard(
    _ itemID: UUID,
    center: WorldPoint,
    viewport: SpatialPoint,
    duration: TimeInterval = 0.24,
    rollback:SessionPresence? = nil
  ) {
    guard !model.isItemBeingDeleted(itemID), let presence = model.presence else { return }
    model.selectItem(itemID)
    animateSettlement(to: SessionPresence(boardID: presence.boardID, mode: .cover,
      camera: BoardPortalProjection.parentBoundaryCamera(portalCenter: center, viewport: viewport),
      viewport: viewport, focusedItemID: itemID, openProgress: 1), duration: duration, bounce: 0.025,rollback:rollback) {
      model.enterBoard(itemID)
    }
  }

  private func leaveBoard(viewport: SpatialPoint) {
    guard let child=model.presence,let passage=exitPassage(presence:child),let portal=passage.returningPortal else { return }
    let target=passage.closed(viewport:viewport,camera:.init(center:passage.center,scale:passage.geometry.coverScale(viewport:viewport)))
    let handoff=passage.presentation(camera:passage.parentCamera(from:child.camera),viewport:viewport)
    animateSettlement(to:target,duration:0.34,bounce:0,portal:(passage.itemID,portal),handoff:handoff) {
      model.rememberBoardReturn(child,portal:portal)
    }
  }

  private func itemKind(_ itemID: UUID) -> WorkspaceItemKind? {
    model.workspace?.item(id: itemID)?.kind ?? model.compositionTiles.published?.frame.index.item(id: itemID)?.kind
  }

  private func animateSettlement(
    to target: SessionPresence,
    duration: TimeInterval,
    bounce: Double = 0.08,
    navigationID: UUID? = nil,
    portal: (UUID,BoardPortalCamera)? = nil,
    handoff:SessionPresence? = nil,
    rollback:SessionPresence? = nil,
    completion: @escaping () -> Void = {}
  ) {
    guard let origin=model.presence else { return }
    cameraSettlement.cancel();panStart=nil;pageInputGestureID=nil;bufferedCameraPhases=[]
    let pending=WorkspaceSettlement(origin:rollback ?? origin,target:target,handoff:handoff,duration:duration,bounce:bounce,navigationID:navigationID,portal:portal,completion:completion)
    navigation = .settling(pending);contentGestureActive=true
    if navigationHasPreparedSurface(pending.preparation),navigationHasPreparedSurface(target) { startSettlement(pending) }
  }

  private func startSettlement(_ pending:WorkspaceSettlement) {
    guard case .settling(let current)=navigation,current === pending,!pending.started,let currentPresence=model.presence else { return }
    pending.started=true
    let start=currentPresence.boardID == pending.target.boardID ? currentPresence : pending.handoff ?? currentPresence
    if start != currentPresence { model.updatePresence(start,settled:false) }
    let target=pending.target
    let retainsNotebook=start.mode == .page && target.mode == .page && start.focusedItemID == target.focusedItemID
    let destination=retainsNotebook ? target.selecting(itemID:start.selectedItemID,pageID:start.notebookPageID) : target
    let accepted=cameraSettlement.start(from:start,to:destination,duration:pending.duration,bounce:pending.bounce,navigationID:pending.navigationID) { presence,settled in
      guard case .settling(let active)=navigation,active === pending else { return }
      var transaction=Transaction();transaction.disablesAnimations=true
      withTransaction(transaction) {
        let sample=retainsNotebook ? presence.selecting(itemID:model.presence?.selectedItemID,pageID:model.presence?.notebookPageID) : presence
        model.updatePresence(sample,settled:settled)
      }
    } completion: {
      guard case .settling(let active)=navigation,active === pending else { return }
      contentGestureActive=false;navigation = .idle;pending.completion()
    }
    if !accepted { contentGestureActive=false;navigation = .idle }
  }

  private func performOpeningFeedback() {
      openingFeedback.impactOccurred(intensity: 0.6)
      openingFeedback.prepare()
  }

  private func createItem(
    kind: WorkspaceItemKind,
    paperSize: DocumentPaperSize = .a4,
    presence: SessionPresence,
    viewport: SpatialPoint,
    at requestedCenter: WorldPoint? = nil
  ) {
    let offset = Double(model.workspace?.items.count ?? 0) * 28
    guard let center = requestedCenter ?? presence.camera.center.addressOffset(x: offset, y: offset) else { return }
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
    presence: SessionPresence,
    source: NotebookItemMoveSource?
  ) -> WorkspaceItemPoseDestination? {
    guard let source, model.presence?.boardID == presence.boardID,
      !model.isItemBeingDeleted(itemID), let cohort = model.compositionTiles.published,
      let moving = model.presentedItem(id: itemID, cohort: cohort, presence: presence)
    else { return nil }
    let target = model.presentedWorkset(cohort: cohort, boardID: presence.boardID, presence: presence).items
      .reversed()
      .first { candidate in
        guard candidate.id != itemID else { return false }
        if let stack = model.board?.stack(containing: candidate.id),
          stack.itemIDs.count >= WorkspaceItemStack.maximumItemCount, !stack.itemIDs.contains(itemID) { return false }
        let delta = center.delta(to: candidate.center)
        return abs(delta.x) <= (moving.geometry.width + candidate.geometry.width) * 0.3
          && abs(delta.y) <= (moving.geometry.height + candidate.geometry.height) * 0.3
      }
    guard let command = model.moveItem(itemID, to: center, onto: target?.id, source: source),
      let board = model.board else { return nil }
    return .init(itemID: itemID, board: board, command: command)
  }

}

private struct WorkspaceSceneItem: View {
  @Environment(\.sceneComposition) private var composition
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
  let onDrop: (UUID, WorldPoint, NotebookItemMoveSource?) -> WorkspaceItemPoseDestination?
  let onSelect: (UUID) -> Void
  let onLiftChanged: (UUID, Bool) -> Void
  let onOpen: (UUID) -> Void
  let onContext: (UUID,CGPoint) -> Void
  let onTextEditingEnded: (String) -> Void
  let onPageTurnStateChange: @MainActor @Sendable (Bool) -> Void
  let onDocumentPageLayout: (DocumentPageLayout) -> Void
  let onPaperReadiness: @MainActor (@escaping @MainActor () -> Bool) -> Void

  var body: some View {
    // The one admitted opening target must paint behind its opaque cover
    // before navigation can await its readiness. Hiding these elements until
    // the first opening sample would deadlock a filled page at the closed edge.
    let contentIsLive = preparesContent || openProgress > 0.001 || contentIsInteractive
    let restingShadowVisibility =
      CoverOpeningPhysics.restingShadowVisibility(openProgress)
    WorkspaceItemPose(rendered: rendered, camera: camera, viewport: viewport, boardID: boardID,
      liftRank: liftRank, registry: spatialInkSurfaces,
      onLiftChanged: { lifted in
        if lifted { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
        onLiftChanged(rendered.id, lifted)
      }, onDrop: { onDrop(rendered.id, $0, $1) }) {
      ZStack {
      WorkspaceItemShadow(geometry: rendered.geometry, kind: rendered.item.kind,
        hasContents: composition.cohort?.liveData.nonemptyBoardIDs.contains(rendered.id) == true,
        lifted: isLifted, visibility: restingShadowVisibility)
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
    // Accessibility follows the same physical body as camera and Pencil.
    .contentShape(.accessibility, RoundedRectangle(
      cornerRadius: rendered.geometry.cornerRadius, style: .continuous
    ))
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
          contentIsInteractive && model.inputGate.permitsPageNavigation
            && !model.selectionSession.isInteractive && paperFitsViewport
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
        onTransitioningChange: onPageTurnStateChange,
        onReadinessProbe:onPaperReadiness,
        notebookNavigation: model.notebookPageNavigation,
        onWindowChange: { indices, target, root in
          model.retainNotebookPageWindow(indices, in: rendered.id, root: root, target: target)
        }, inputGate: model.inputGate
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
          contentIsInteractive && model.inputGate.permitsPageNavigation
            && !model.selectionSession.isInteractive && paperFitsViewport
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
        onReadinessProbe:onPaperReadiness,
        canonicalDocumentLayout: documentPageLayout,
        documentSelection: model.documentPageSelection,
        documentNavigation: .init(
          bind: { model.bindDocumentPageController($0, documentID: $1, source: $2) },
          unbind: model.unbindDocumentPageController,
          landed: { landing in
            if model.acceptDocumentPageLanding(landing) { announcePage(landing.pageIndex + 1) }
          },
          status: model.acceptDocumentPageNavigationStatus), inputGate: model.inputGate
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
    AnyView(NotebookPageView(notebookID: notebookItem.id, index: index, isCurrent: isCurrent,
      isInteractive: isCurrent && contentIsInteractive, isVisible: isLive,
      onRenderReady: onRenderReady, displayProjection: rendered.geometry.fitScale(viewport: viewport)))
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
      onTap:handleTap,
      onHold: { point in
        let center=camera.worldToScreen(rendered.center,viewport:viewport)
        onContext(rendered.id,.init(x:center.x+(point.x-rendered.geometry.width/2)*camera.scale,
          y:center.y+(point.y-rendered.geometry.height/2)*camera.scale))
      },
      onTextEditingEnded: onTextEditingEnded,
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


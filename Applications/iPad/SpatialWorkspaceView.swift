import NotebookCore
import SwiftUI
import UIKit

private struct CameraGestureSnapshot {
  struct PaperEngagement {
    let itemID: UUID
    let openingScale: Double
    let rawOpeningScale: Double
    let dockingEntryProgress: Double
    let dockingEntryCorrection: NotebookDockingCorrection
  }

  let presence: SessionPresence
  let trajectory: CameraGestureTrajectory
  var lastMagnification: CGFloat
  var candidateItemID: UUID?
  var dockingStartStrength: Double
  var isApproaching: Bool
  var paperEngagement: PaperEngagement?
  var dockingCorrection: NotebookDockingCorrection
  var openingWasVisible: Bool
  var followsPortal = false
}

/// A Show command may outlive its camera animation while WebKit finds a block's
/// physical sheet. Only that command may finish the pending page adjustment.
@MainActor
final class NotebookReferencePageResolution {
  private var task: Task<Void, Never>?
  private var generation: UInt64 = 0
  private(set) var requestID: UUID?
  private(set) var documentID: UUID?

  func cancel() {
    generation &+= 1
    requestID = nil
    documentID = nil
    task?.cancel(); task = nil
  }

  func start(requestID: UUID, documentID: UUID, isCurrent: @escaping () -> Bool,
    resolve: @escaping () -> Int?, apply: @escaping (Int) -> Void) {
    cancel()
    self.requestID = requestID
    self.documentID = documentID
    let expectedGeneration = generation
    task = Task { @MainActor [weak self] in
      defer { self?.finish(requestID: requestID, generation: expectedGeneration) }
      let deadline = ContinuousClock.now + .seconds(8)
      while ContinuousClock.now < deadline {
        do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
        guard let self, !Task.isCancelled, generation == expectedGeneration,
          self.requestID == requestID, isCurrent() else { return }
        guard let page = resolve() else { continue }
        guard generation == expectedGeneration, self.requestID == requestID else { return }
        apply(page)
        return
      }
    }
  }

  private func finish(requestID: UUID, generation: UInt64) {
    guard self.generation == generation, self.requestID == requestID else { return }
    task = nil; self.requestID = nil; documentID = nil
  }

  isolated deinit { task?.cancel() }
}

struct SpatialWorkspaceView: View {
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.displayScale) private var displayScale
  @Environment(NotebookAppModel.self) private var model

  @State private var cameraGesture: CameraGestureSnapshot?
  @State private var panStart: SessionPresence?
  private var selectedItemID: UUID? { model.presence.flatMap { model.selectionSession.itemID(on: $0.boardID) } }
  @State private var liftedItemIDs: [UUID] = []
  @State private var deletionObserverID = UUID()
  private var editingSpatialText: EditableElementReference? {
    guard model.selectionSession.isInteractive,
      case .spatial(let boardID, let id) = model.selectionSession.element,
      model.boardHierarchy?.board(boardID)?.elements.first(where: { $0.id == id })?.kind == .nativeText else { return nil }
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
        permitsPreparation: model.permitsBackgroundPreparation)
      let workset = frame?.workset(boardID: presence.boardID) ?? .empty
      let rendered = workset.items

      ZStack {
        SpatialBoardGrid(camera: presence.camera)
        if cohort == nil {
          ProgressView(model.compositionTiles.failure == nil ? "Подготовка пространства" : "Ожидание ресурсов изображения")
            .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .zIndex(9_000)
        }

          BoardPanView(
            isEnabled: (presence.mode == .board || presence.mode == .cover)
              && cameraGesture == nil && !settling && !model.isPointing,
            itemFrames: rendered.map { item in
              let center = presence.camera.worldToScreen(
                item.center,
                viewport: viewport
              )
              let width = item.geometry.width * presence.camera.scale
              let height = item.geometry.height * presence.camera.scale
              return CGRect(
                x: center.x - width / 2,
                y: center.y - height / 2,
                width: width,
                height: height
              )
            } + workset.elements.compactMap { element in
              guard let origin = element.worldOrigin else { return nil }
              let screen = presence.camera.worldToScreen(origin, viewport: viewport)
              return CGRect(x: screen.x + element.frame.x * presence.camera.scale,
                y: screen.y + element.frame.y * presence.camera.scale,
                width: element.frame.width * presence.camera.scale,
                height: element.frame.height * presence.camera.scale).insetBy(dx: -16, dy: -16)
            },
            inputGate: model.inputGate,
            onTap: {
              withAnimation(.easeOut(duration: 0.12)) {
                model.clearSelection()
              }
              model.interactiveElementFocus = nil
            },
            onBegan: {
              referencePageResolution.cancel()
              model.endSurfaceEditing()
              model.interactiveElementFocus = nil
              panStart = presenceForNewContact(presence)
            },
            onChanged: { translation in
              updateBoardPan(translation, viewport: viewport)
            },
            onEnded: { translation in
              finishBoardPan(translation, viewport: viewport)
            },
            onCancelled: {
              finishBoardPan(nil, viewport: viewport)
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
            penStyle: model.penStyle,
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
              && !contentGestureActive

          )
          .allowsHitTesting(false)

        sceneItems(rendered, presence: presence, viewport: viewport, frame: frame, cohort: cohort)
          .zIndex(liftedItemIDs.isEmpty ? 0 : 9_000)

          WorkspaceGestureLayer(
            isEnabled: true,
            defersHorizontalMotionToPageTurn: (presence.mode == .page
              || presence.mode == .document)
              && presence.openProgress >= 0.999 && !model.isPointing,
            inputGate: model.inputGate,
            onCamera: handleWorkspaceMagnification,
            onUndo: model.undoLastSurfaceAction
          )
          .allowsHitTesting(false)

          itemSelectionControl(presence: presence, viewport: viewport)

        NotebookAttentionMarks(presence:presence)
        if let reference = model.selectionSession.editingElement,
          let rect = NotebookAttentionProjection.editingFrame(reference, model: model, presence: presence) {
          NotebookElementControls(reference: reference, selectionID: model.selectionSession.id,
            frame: model.selectionSession.manipulation?.projected(over: rect, scale: presence.camera.scale) ?? rect,
            scale: presence.camera.scale)
            .frame(width: viewport.x, height: viewport.y)
        }
        NotebookSelectionGesture(inputGate: model.inputGate, onPreview: model.updateSelectionPreview,
          onPoint: { start, end, held, tapCount in
          guard cameraGesture == nil, !settling, !model.scenePreparationPending, let cohort else { return }
          guard let capture = NotebookAttentionProjection.capture(start: start, end: end, model: model, presence: presence,
            cohort: cohort, installedInk: spatialInkSurfaces.installedSources()) else { return }
          if !held, capture.fragments.allSatisfy({ $0.elementID == nil && $0.target.kind != .cover }) {
            model.clearSelection(); return
          }
          var target = NotebookSelectionSession.Target.context
          if !held, let fragment = capture.fragments.first {
            if let reference = editableReference(fragment, boardID: presence.boardID) {
              let focus: InteractiveElementReference
              switch reference {
              case .page(let pageID, let id): focus = .page(pageID: pageID, elementID: id)
              case .spatial(let boardID, let id): focus = .board(boardID: boardID, elementID: id)
              }
              if model.interactiveElementFocus == focus { return }
              if tapCount > 1 {
                if case .spatial(let boardID, let id) = reference,
                  model.sceneIndex?.element(id: id, boardID: boardID)?.kind == .nativeText {
                  model.interactiveElementFocus = .board(boardID: boardID, elementID: id)
                } else { model.interactiveElementFocus = focus }
                return
              }
              target = .element(reference)
            } else if fragment.target.kind == .cover {
              target = .item(boardID: presence.boardID, itemID: fragment.target.id)
            }
          }
          model.publishHumanContext(capture, target: target)
        }, onLift: { point in
          guard cameraGesture == nil, !settling, let cohort,
            let capture = NotebookAttentionProjection.capture(start: point, end: point, model: model, presence: presence,
              cohort: cohort, installedInk: spatialInkSurfaces.installedSources()),
            let fragment = capture.fragments.first,
            let reference = editableReference(fragment, boardID: presence.boardID) else { return nil }
          let scale = max(presence.camera.scale, 0.001)
          var contactID: UUID?
          func translation(_ delta: CGPoint) -> SpatialPoint { .init(x: delta.x / scale, y: delta.y / scale) }
          return SceneSelectionLift(begin: {
            if model.selectionSession.element != reference || model.agentQuestion == nil {
              model.publishHumanContext(capture, target: .element(reference))
            }
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
            model.confirmVisibleActions(presence: presence, scene: workset)
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
        let registry = spatialInkSurfaces, owner = model
        model.bindItemOwnerObserver(owner: deletionObserverID) { [weak registry, weak owner] id, boardID, revision in
          guard let shown = owner?.compositionTiles.published, shown.plan.revision <= revision,
            shown.frame.index.ownerBoard(itemID: id) == boardID else { return }
          registry?.retirePhysicalOwner(id, on: boardID, through: revision)
          if owner?.selectionSession.itemID(on: boardID) == id { owner?.clearSelection() }
        }
        publishViewportIfNeeded(viewport)
      }
      .task(id:model.requestedReference?.id) {
        guard let reference = model.requestedReference else { return }
        referencePageResolution.cancel()
        while cameraGesture != nil || settling || pageTurnIsActive || contentGestureActive || model.presencePhase != .settled {
          do { try await Task.sleep(for:.milliseconds(40)) } catch { return }
        }
        if reference.target.kind == .page {
          guard await model.navigateToNotebookPage(id: reference.target.id,
            isCurrent: { model.requestedReference?.id == reference.id }) else { return }
        }
        model.afterPageInput {
          guard model.requestedReference?.id == reference.id else { return }
          showReference(reference,viewport:viewport)
        }
      }
      .task(id: model.requestedReturn?.id) {
        guard let place = model.requestedReturn else { return }
        referencePageResolution.cancel()
        while cameraGesture != nil || settling || pageTurnIsActive || contentGestureActive || model.presencePhase != .settled {
          do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
        }
        if let pageID = place.pageID {
          guard await model.navigateToNotebookPage(id: pageID,
            isCurrent: { model.requestedReturn?.id == place.id }) else { return }
        }
        model.afterPageInput {
          guard model.requestedReturn?.id == place.id else { return }
          defer { model.completeReturnToPlace() }
          guard model.boardHierarchy?.board(place.presence.boardID) != nil else { return }
          if let itemID = place.presence.focusedItemID {
            guard model.workspace?.item(id: itemID) != nil else { return }
            if place.pageID == nil { model.selectItem(itemID) }
          }
          animateSettlement(to: place.presence.adapted(to: viewport, geometry: model.itemGeometry(place.presence.focusedItemID)), duration: 0.3)
        }
      }
      .onChange(of: scenePhase) { _, phase in
        if phase != .active {
          referencePageResolution.cancel()
          interruptSettlementForInput()
        }
      }
      .onChange(of: geometry.size) { _, _ in
        interruptSettlementForInput()
        publishViewportIfNeeded(viewport)
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

  private func selectItemMaterial(_ itemID: UUID, presence: SessionPresence, cohort: SceneCompositionCohort?) {
    let target = NotebookSelectionSession.Target.item(boardID: presence.boardID, itemID: itemID)
    guard model.selectionSession.target != target else { return }
    if let cohort, let item = cohort.frame.index.renderedItem(id: itemID, presence: presence) {
      let box = item.geometry.screenFrame(center: item.center, camera: presence.camera, viewport: presence.viewport)
      if let capture = NotebookAttentionProjection.capture(start: .init(x: box.x, y: box.y),
        end: .init(x: box.x + box.width, y: box.y + box.height), model: model, presence: presence,
        cohort: cohort, installedInk: spatialInkSurfaces.installedSources(), itemID: itemID) {
        model.publishHumanContext(capture, target: target); return
      }
    }
    model.selectWorkspaceItem(itemID, boardID: presence.boardID)
  }

  private struct CompositionRequest: Equatable {
    let presence: SessionPresence
    let generation: UUID?
    let publication: UInt64
    let revision: UInt64?
    let pinned: Set<WorkspaceSpatialID>
    let itemOwners: [UUID: UUID]
    let permitsPreparation: Bool
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
      let rendered = model.sceneIndex?.renderedItem(id: selectedItemID, presence: presence)
    {
      let center = presence.camera.worldToScreen(
        rendered.center,
        viewport: viewport
      )
      let halfWidth = rendered.geometry.width * presence.camera.scale / 2
      let halfHeight = rendered.geometry.height * presence.camera.scale / 2
      Button(role: .destructive) {
        Task {
          guard await model.deleteItem(selectedItemID) else { return }
          if self.selectedItemID == selectedItemID { model.clearSelection() }
        }
      } label: {
        Image(systemName: "trash")
          .font(.system(size: 17, weight: .semibold))
          .frame(width: 44, height: 44)
          .background(.regularMaterial, in: Circle())
          .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
      }
      .buttonStyle(.plain)
      .disabled(model.isItemBeingDeleted(selectedItemID))
      .accessibilityLabel("Удалить")
      .accessibilityIdentifier("delete-workspace-item")
      .position(
        x: min(max(center.x + halfWidth + 8, 28), viewport.x - 28),
        y: min(max(center.y - halfHeight - 8, 28), viewport.y - 28)
      )
      .transition(.scale(scale: 0.82).combined(with: .opacity))
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
            .font(.system(size: 21, weight: .medium))
            .frame(width: 48, height: 48)
            .background(.ultraThinMaterial, in: Circle())
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
      documentPageCount: presence.focusedItemID.flatMap { documentPageLayouts[$0]?.pageCount } ?? 1,
      onBack: {
        referencePageResolution.cancel()
        if !model.returnPlaces.isEmpty { model.requestReturnToPlace() }
        else if presence.mode == .board { leaveBoard(viewport: viewport) }
        else {
          animateSettlement(to: .init(boardID: presence.boardID, mode: .board,
            camera: .init(center: presence.camera.center, scale: model.itemGeometry(presence.focusedItemID).coverScale(viewport: viewport)), viewport: viewport), duration: 0.3)
        }
      })
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(.leading, 18).padding(.top, 18).zIndex(10_000)
  }

  private struct ItemPlaneRevision: Equatable {
    let cohortID: UUID?
    let generation: UUID?
    let contents: UInt64
    let ids: [UUID]
    let coverIDs: [UUID: [String]]
    let mode: WorkspaceSemanticMode
    let focused: UUID?
    let open: Double
    let selected: UUID?
    let lifted: [UUID]
    let candidate: UUID?
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
    let revision = ItemPlaneRevision(cohortID: cohort?.id, generation: model.sceneIndex?.generationID,
      contents: model.collaborationReadEpoch, ids: rendered.map(\.id),
      coverIDs: frame?.covers.mapValues { $0.elements.map { "element:" + $0.id } + $0.aggregates.map { "aggregate:" + String($0.id) } } ?? [:], mode: presence.mode,
      focused: presence.focusedItemID, open: presence.openProgress,
      selected: selectedItemID, lifted: liftedItemIDs, candidate: cameraGesture?.candidateItemID,
      editingText: editingSpatialText, contentGesture: contentGestureActive,
      pageTurn: pageTurnIsActive, isCameraGesture: cameraGesture != nil, settling: settling,
      pointing: model.isPointing, prepares: rendered.map { preparesContent($0.id, presence: presence) },
      page: presence.documentPageIndex, layout: documentPageLayouts,
      dependentCamera: rendered.contains { $0.stackID != nil || $0.item.kind == .board }
        || selectedItemID != nil ? presence.camera : nil)
    return SceneCameraPlane(presence: presence, revision: revision, reanchorsOnRevision: false,
      isCameraActive: model.presencePhase == .active || cameraGesture != nil || panStart != nil || settling) { anchor in
      ZStack {
        if let cohort {
          ForEach(SceneCompositionTileBandView.bands(in: cohort, plane: .board(presence.boardID), layer: .covers, presence: anchor)) { band in
            band.zIndex(Double(band.rank))
          }
        }
        sceneItemContents(rendered, presence: presence, viewport: viewport, anchorCamera: anchor.camera,
          frame: frame, cohort: cohort)
      }
        .environment(model).environment(\.workspaceSceneFrame, frame).environment(\.sceneComposition, .init(cohort))
    }
  }

  private func sceneItemContents(_ rendered: [RenderedWorkspaceItem], presence: SessionPresence,
    viewport: SpatialPoint, anchorCamera: SpatialCamera, frame: WorkspaceSceneFrame?, cohort: SceneCompositionCohort?) -> some View {
    ForEach(rendered.filter {
          cohort?.plan.allowsLive(.item($0.id), in: .board(presence.boardID)) == true && (
          WorkspaceSceneProjection.mountsContent(of: $0, in: presence)
            || $0.id == selectedItemID || liftedItemIDs.contains($0.id)
            || $0.id == cameraGesture?.candidateItemID)
        }) { rendered in
          WorkspaceSceneItem(
            rendered: rendered,
            document: presence.focusedItemID == rendered.id ? model.documents[rendered.id] : cohort?.liveData.documents[rendered.id],
            documentState: presence.focusedItemID == rendered.id ? model.documentStates[rendered.id] : cohort?.liveData.states[rendered.id],
            documentPageIndex: presence.focusedItemID == rendered.id
              ? presence.documentPageIndex
              : 0,
            documentPageCount: documentPageLayouts[rendered.id]?.pageCount ?? 1,
            camera: anchorCamera,
            projectedScale: presence.camera.scale,
            boardID: presence.boardID,
            contentRevision: model.collaborationReadEpoch,
            coverElements: frame?.covers[rendered.id]?.elements ?? [],
            viewport: viewport,
            isFocused: presence.focusedItemID == rendered.id,
            preparesCoverMotion: presence.focusedItemID == rendered.id
              || cameraGesture?.candidateItemID == rendered.id
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
              guard !model.scenePreparationPending else { return nil }
              return dropItem(itemID, at: center, presence: model.presence ?? presence)
            },
            onSelect: { itemID in
              guard !model.isItemBeingDeleted(itemID) else { return }
              withAnimation(.easeOut(duration: 0.12)) {
                selectItemMaterial(itemID, presence: presence, cohort: cohort)
              }
            },
            onLiftChanged: { itemID, lifted in
              if lifted { model.interactiveElementFocus = nil }
              liftedItemIDs.removeAll { $0 == itemID }
              if lifted { liftedItemIDs.append(itemID); selectItemMaterial(itemID, presence: presence, cohort: cohort) }
            },
            onOpen: { itemID in
              guard !model.scenePreparationPending else { return }
              model.interactiveElementFocus = nil
              model.endSurfaceEditing()
              openItem(itemID, viewport: viewport)
            },
            onEditText: { itemID, point in
              guard !model.scenePreparationPending else { return }
              beginTextEditing(on: itemID, at: point)
            },
            onTextEditingEnded: { [selectionID = model.selectionSession.id] elementID in
              model.finishInteractiveElementInput(.spatial(boardID: presence.boardID, elementID: elementID), selectionID: selectionID)
            },
            onPageTurnStateChange: { active in
              pageTurnIsActive = active
            },
            onDocumentPageLayout: { layout in
              acceptDocumentPageLayout(
                layout,
                documentID: rendered.id
              )
            }
          )
          .equatable()
          .zIndex(liftRank(of: rendered.id) ?? (cohort?.plan.rank(id: .item(rendered.id), in: .board(presence.boardID)) ?? 0))
        }

  }

  private struct ElementPlaneRevision: Equatable {
    let cohortID: UUID?
    let generation: UUID?
    let focus: InteractiveElementReference?
    let elements: [String]
    let selection: EditableElementReference?
    let selectionID: UUID
    let manipulation: NotebookElementManipulation?
    let pending: Bool
  }

  private func boardElements(_ elements: [SpatialElement], presence: SessionPresence,
    viewport: SpatialPoint, cohort: SceneCompositionCohort?) -> some View {
    let selection = model.selectionSession.editingElement
    let revision = ElementPlaneRevision(cohortID: cohort?.id, generation: model.sceneIndex?.generationID,
      focus: model.interactiveElementFocus, elements: elements.map(\.id),
      selection: selection, selectionID: model.selectionSession.id, manipulation: model.selectionSession.manipulation,
      pending: model.scenePreparationPending)
    return SceneCameraPlane(presence: presence, revision: revision,
      isCameraActive: model.presencePhase == .active || cameraGesture != nil || panStart != nil || settling) { anchor in
      ZStack {
        if let cohort {
          ForEach(SceneCompositionTileBandView.bands(in: cohort, plane: .board(presence.boardID), layer: .elements, presence: anchor)) { band in
            band.zIndex(Double(band.rank))
          }
        }
        boardElementContents(elements, presence: anchor, viewport: anchor.viewport, cohort: cohort)
      }
        .environment(model)
    }
  }

  @ViewBuilder
  private func boardElementContents(
    _ elements: [SpatialElement],
    presence: SessionPresence,
    viewport: SpatialPoint,
    cohort: SceneCompositionCohort?
  ) -> some View {
    ForEach(elements.filter { cohort?.plan.allowsLive(.element($0.id), in: .board(presence.boardID)) == true }) { element in
        if let worldOrigin = element.worldOrigin {
          let reference = EditableElementReference.spatial(boardID: presence.boardID, elementID: element.id)
          let base = presence.camera.worldToScreen(
            worldOrigin,
            viewport: viewport
          )
          let origin = CGPoint(
            x: base.x + element.frame.x * presence.camera.scale,
            y: base.y + element.frame.y * presence.camera.scale
          )
          EditableElementContainer(reference: reference, coordinateScale: presence.camera.scale) {
            // The physical viewport belongs to the element. The camera transforms
            // its whole layer; WebKit layout must not trail the moving frame.
            SpatialElementContent(element: element, boardID: presence.boardID,
              isTextEditing: editingSpatialText == reference,
              onTextEditingEnded: { [selectionID = model.selectionSession.id] in model.finishInteractiveElementInput(reference, selectionID: selectionID) })
              .frame(width: element.frame.width, height: element.frame.height)
              .scaleEffect(presence.camera.scale)
              .frame(
                width: element.frame.width * presence.camera.scale,
                height: element.frame.height * presence.camera.scale
              )
          }
            .disabled(model.scenePreparationPending)
            .allowsHitTesting(!model.scenePreparationPending)
            .frame(
              width: element.frame.width * presence.camera.scale,
              height: element.frame.height * presence.camera.scale
            )
            .position(
              x: origin.x + element.frame.width * presence.camera.scale / 2,
              y: origin.y + element.frame.height * presence.camera.scale / 2
            )
            .zIndex(cohort?.plan.rank(id: .element(element.id), in: .board(presence.boardID)) ?? 0)
        }
      }
  }


  private func beginTextEditing(
    on itemID: UUID,
    at point: SpatialPoint
  ) {
    guard model.presence?.mode == .cover,
      model.presence?.focusedItemID == itemID,
      let boardID = model.presence?.boardID,
      let board = model.board
    else { return }
    let elements = board.elements.filter {
      $0.surface == .cover(itemID)
    }
    if let text = elements.reversed().first(where: {
      $0.kind == .nativeText && $0.frame.contains(point)
    }) {
      model.interactiveElementFocus = .board(boardID: boardID, elementID: text.id)
      return
    }
    guard !elements.contains(where: { $0.frame.contains(point) }),
      let elementID = model.addNativeText(boardID: boardID, on: itemID, at: point)
    else { return }
    model.interactiveElementFocus = .board(boardID: boardID, elementID: elementID)
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
    for id in [presence.focusedItemID, selectedItemID, cameraGesture?.candidateItemID] + liftedItemIDs.map(Optional.some) {
      if let id, !spatialInkSurfaces.isRetired(.cover(id)) { pins.insert(.item(id)) }
    }
    if case .spatial(let boardID, let id) = model.selectionSession.element, boardID == presence.boardID { pins.insert(.element(id)) }
    if let id = editingTextID(on: presence.boardID) { pins.insert(.element(id)) }
    if case .board(let boardID, let elementID) = model.interactiveElementFocus {
      pins.insert(.element(elementID))
      if let element = model.sceneIndex?.element(id: elementID, boardID: boardID),
        element.surface.kind == .cover, let carrier = element.surface.ownerID { pins.insert(.item(carrier)) }
    }
    return pins
  }

  private func sceneWorkset(presence: SessionPresence) -> WorkspaceSceneWorkset {
    model.sceneWorkset(presence: presence, pinned: scenePins(presence: presence))
  }

  private func acceptDocumentPageLayout(
    _ layout: DocumentPageLayout,
    documentID: UUID
  ) {
    if documentPageLayouts[documentID] != layout {
      documentPageLayouts[documentID] = layout
    }
    guard let presence = model.presence,
      presence.mode == .document,
      presence.focusedItemID == documentID,
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
    if let gesture = cameraGesture,
      let candidate = gesture.candidateItemID,
      presence.camera.scale >= model.itemGeometry(candidate).coverScale(viewport: presence.viewport)
        * NotebookOpeningIntent.pagePreparationScaleRatio
    {
      return candidate == itemID
    }
    if let focusedItemID = presence.focusedItemID {
      return focusedItemID == itemID
    }
      return model.workspace?.selectedItemID == itemID
  }

  private func handleBoardMagnification(_ phase: WorkspaceMagnificationPhase) {
    switch phase {
    case .began(let centroid, let isOpeningApproach):
      interruptSettlementForInput()
        openingFeedback.prepare()
      model.endSurfaceEditing()
      model.interactiveElementFocus = nil
      guard let currentPresence = model.presence else { return }
      let presence = presenceForNewContact(currentPresence)
      let focusedItemID =
        presence.mode == .board
        ? nil
        : presence.focusedItemID
      let candidate =
        focusedItemID
        ?? focusCandidate(at: centroid, presence: presence)
      contentGestureActive =
        presence.mode == .page || presence.mode == .document
      let dockingStartStrength: Double
      if let candidate, itemKind(candidate) != .board {
        dockingStartStrength = NotebookDockingField.strength(
          camera: presence.camera,
          viewport: presence.viewport,
          geometry: model.itemGeometry(candidate)
        )
      } else {
        dockingStartStrength = 0
      }
      let paperEngagement = focusedItemID.flatMap { itemID -> CameraGestureSnapshot.PaperEngagement? in
        guard itemKind(itemID) != .board else { return nil }
        let coverScale = model.itemGeometry(itemID).coverScale(viewport: presence.viewport)
        let targetScale = model.itemGeometry(itemID).fitScale(viewport: presence.viewport)
        let fallback =
          presence.mode == .cover
            && presence.openProgress <= 0
          ? presence.camera.scale
          : coverScale * NotebookOpeningIntent.entryScaleRatio
        let openingScale = NotebookOpeningTransition.openingScale(
          cameraScale: presence.camera.scale,
          pageScale: targetScale,
          progress: presence.openProgress,
          fallback: fallback
        )
        return CameraGestureSnapshot.PaperEngagement(
          itemID: itemID,
          openingScale: openingScale,
          rawOpeningScale: openingScale,
          dockingEntryProgress: presence.openProgress,
          dockingEntryCorrection: .zero
        )
      }
      cameraGesture = CameraGestureSnapshot(
        presence: presence,
        trajectory: CameraGestureTrajectory(
          startingCamera: presence.camera,
          startingCentroid: centroid,
          startingMagnification: 1,
          viewport: presence.viewport
        ),
        lastMagnification: 1,
        candidateItemID: candidate,
        dockingStartStrength: dockingStartStrength,
        isApproaching: isOpeningApproach,
        paperEngagement: paperEngagement,
        dockingCorrection: .zero,
        openingWasVisible:
          presence.openProgress > 0
      )
    case .changed(let scale, let velocity, _, let centroid):
      updateMagnification(
        scale: scale,
        velocity: velocity,
        centroid: centroid
      )
    case .ended(let scale, let velocity, _, let centroid):
      updateMagnification(
        scale: scale,
        velocity: velocity,
        centroid: centroid
      )
      settleMagnification(velocity: velocity)
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

  private func updateMagnification(
    scale: CGFloat,
    velocity _: CGFloat,
    centroid: CGPoint
  ) {
    guard var snapshot = cameraGesture else { return }
    let viewport = snapshot.presence.viewport
    let geometry = model.itemGeometry(snapshot.paperEngagement?.itemID ?? snapshot.candidateItemID)
    let pageScale = geometry.fitScale(viewport: viewport)
    let coverScale = geometry.coverScale(viewport: viewport)
    let directionThreshold: CGFloat = 0.000_5
    let directionDelta = scale - snapshot.lastMagnification
    if abs(directionDelta) > directionThreshold {
      snapshot.isApproaching = directionDelta > 0
    }

    let engagedItemID = snapshot.paperEngagement?.itemID
    let engagementScale = engagedItemID.map {
      model.itemGeometry($0).fitScale(viewport: viewport)
    } ?? pageScale
    let maximumScale = snapshot.paperEngagement == nil
      ? SpatialCamera.maximumScale
      : engagementScale
    let rawCamera = snapshot.trajectory.camera(
      at: scale,
      centroid: centroid,
      maximumScale: maximumScale
    )
    var camera = rawCamera

    if let paperEngagement = snapshot.paperEngagement {
      if NotebookOpeningIntent.shouldDisengage(
        cameraScale: rawCamera.scale,
        coverScale: coverScale
      ) {
        snapshot.paperEngagement = nil
        snapshot.dockingCorrection = .zero
      } else {
        snapshot.candidateItemID = paperEngagement.itemID
      }
    }

    if snapshot.paperEngagement == nil {
      let liveBoardPresence = SessionPresence(
        boardID: snapshot.presence.boardID,
        mode: .board,
        camera: camera,
        viewport: viewport
      )
      let retainedCandidate = snapshot.candidateItemID.flatMap {
        retained -> UUID? in
        let strength = selectionStrength(
          for: retained,
          at: centroid,
          presence: liveBoardPresence,
          halo: NotebookOpeningIntent.candidateRetentionHalo
        )
        return strength > 0 ? retained : nil
      }
      let nextCandidate =
        retainedCandidate
        ?? focusCandidate(
          at: centroid,
          presence: liveBoardPresence
        )
      if nextCandidate != snapshot.candidateItemID {
        snapshot.candidateItemID = nextCandidate
        if let nextCandidate, itemKind(nextCandidate) != .board {
          snapshot.dockingStartStrength = NotebookDockingField.strength(
            camera: camera,
            viewport: viewport,
            geometry: model.itemGeometry(nextCandidate)
          )
        } else {
          snapshot.dockingStartStrength = 0
        }
      }
    }

    if updatePortalMagnification(snapshot: &snapshot, camera: rawCamera,
      magnification: scale, centroid: centroid) { return }

    let attractionTarget =
      snapshot.paperEngagement?.itemID
      ?? snapshot.candidateItemID
    let dockingStrength = NotebookDockingField.strength(
      camera: rawCamera,
      viewport: viewport,
      geometry: model.itemGeometry(attractionTarget)
    )
    if let attractionTarget,
      let center = model.sceneIndex?.focusedCenter(itemID: attractionTarget, boardID: snapshot.presence.boardID)
    {
      let correction: NotebookDockingCorrection
      if let engagement = snapshot.paperEngagement,
        rawCamera.scale >= engagement.rawOpeningScale
      {
        let rawOpeningProgress = NotebookOpeningTransition.progress(
          cameraScale: rawCamera.scale,
          openingScale: engagement.rawOpeningScale,
          pageScale: model.itemGeometry(engagement.itemID).fitScale(viewport: viewport)
        )
        correction = NotebookDockingField.openingCorrection(
          currentProgress: rawOpeningProgress,
          startingProgress: engagement.dockingEntryProgress,
          continuingFrom: engagement.dockingEntryCorrection
        )
      } else {
        correction = NotebookDockingField.approachCorrection(
          currentStrength: dockingStrength,
          startingStrength: snapshot.dockingStartStrength
        )
      }
      snapshot.dockingCorrection = correction
      camera = NotebookDockingField.attractedCamera(
        camera,
        toward: center,
        viewport: viewport,
        geometry: model.itemGeometry(attractionTarget),
        correction: correction
      )
    } else {
      snapshot.dockingCorrection = .zero
    }

    if snapshot.paperEngagement == nil,
      let candidate = snapshot.candidateItemID,
      NotebookOpeningIntent.shouldEngage(
        isApproaching: snapshot.isApproaching,
        cameraScale: camera.scale,
        coverScale: model.itemGeometry(candidate).coverScale(viewport: viewport)
      )
    {
      snapshot.paperEngagement = CameraGestureSnapshot.PaperEngagement(
        itemID: candidate,
        openingScale: camera.scale,
        rawOpeningScale: rawCamera.scale,
        dockingEntryProgress: 0,
        dockingEntryCorrection: snapshot.dockingCorrection
      )
    }

    let engagement = snapshot.paperEngagement
    let candidate = engagement?.itemID
    let open: Double
    if let engagement {
      open = NotebookOpeningTransition.progress(
        cameraScale: camera.scale,
        openingScale: engagement.openingScale,
        pageScale: model.itemGeometry(engagement.itemID).fitScale(viewport: viewport)
      )
    } else {
      open = 0
    }
    let openingWasVisible = snapshot.openingWasVisible
    snapshot.openingWasVisible = open > 0
    if snapshot.openingWasVisible && !openingWasVisible {
      performOpeningFeedback()
    }
    let mode: WorkspaceSemanticMode = candidate == nil ? .board : .cover
    snapshot.lastMagnification = scale
    cameraGesture = snapshot
    model.updatePresence(
      SessionPresence(
        boardID: snapshot.presence.boardID,
        mode: mode,
        camera: camera,
        viewport: viewport,
        focusedItemID: candidate,
        openProgress: open,
        documentPageIndex: documentPageIndex(
          for: candidate,
          from: snapshot.presence
        )
      ),
      settled: false
    )
  }

  private func settleMagnification(velocity: CGFloat) {
    guard let snapshot = cameraGesture, let presence = model.presence else {
      return
    }
    cameraGesture = nil
    let viewport = presence.viewport
    let pageScale = model.itemGeometry(presence.focusedItemID).fitScale(viewport: viewport)
    if let engagement = snapshot.paperEngagement,
      let itemID = presence.focusedItemID,
      engagement.itemID == itemID,
      NotebookDockingField.shouldDock(
        openProgress: presence.openProgress,
        isApproaching: snapshot.isApproaching,
        releaseVelocity: Double(velocity)
      ),
      let center = model.sceneIndex?.focusedCenter(itemID: itemID, boardID: presence.boardID)
    {
      model.selectItem(itemID)
      let target = SessionPresence(
        boardID: presence.boardID,
        mode: openMode(for: itemID),
        camera: SpatialCamera(center: center, scale: pageScale),
        viewport: viewport,
        focusedItemID: itemID,
        openProgress: 1,
        documentPageIndex: documentPageIndex(
          for: itemID,
          from: snapshot.presence
        )
      )
      animateSettlement(
        to: target,
        duration: NotebookDockingField.settlementDuration(
          openProgress: presence.openProgress,
          releaseVelocity: Double(velocity)
        ),
        bounce: 0.025
      )
    } else {
      contentGestureActive = false
      model.updatePresence(presence, settled: true)
    }
  }

  private func cancelMagnification() {
    guard let snapshot = cameraGesture else { return }
    cameraGesture = nil
    if snapshot.followsPortal, let presence = model.presence {
      model.updatePresence(presence, settled: true)
      return
    }
    animateSettlement(to: snapshot.presence, duration: 0.26)
  }

  /// A portal changes the coordinates of the same live gesture. Paper docking
  /// never participates; releasing the fingers only saves their final frame.
  private func updatePortalMagnification(snapshot: inout CameraGestureSnapshot,
    camera: SpatialCamera, magnification: CGFloat, centroid: CGPoint) -> Bool {
    let start = snapshot.presence
    let viewport = start.viewport
    if snapshot.paperEngagement == nil,
      start.mode == .board || (start.mode == .cover && start.focusedItemID.flatMap(itemKind) == .board),
      let parentID = model.sceneIndex?.ownerBoard(itemID: start.boardID),
      let portal = model.scenePortalCamera(boardID: start.boardID),
      let center = model.sceneIndex?.focusedCenter(itemID: start.boardID, boardID: parentID) {
      let entryScale = BoardPortalProjection.entryCamera(portalCamera: portal, viewport: viewport).scale
      let boundaryScale = min(entryScale, snapshot.trajectory.startingCamera.scale)
      let rawScale = snapshot.trajectory.startingCamera.scale * Double(magnification / snapshot.trajectory.startingMagnification)
      if !snapshot.isApproaching, rawScale < boundaryScale {
        let boundaryMagnification = snapshot.trajectory.startingMagnification * boundaryScale / snapshot.trajectory.startingCamera.scale
        let boundary = snapshot.trajectory.camera(at: boundaryMagnification, centroid: centroid, maximumScale: SpatialCamera.maximumScale)
        let passage = BoardPortalProjection.exitingCamera(boundary: boundary,
          magnification: rawScale / boundaryScale, centroid: .init(x: centroid.x, y: centroid.y),
          portalCenter: center, viewport: viewport)
        if model.leaveBoard(through: passage, settled: false), let presence = model.presence {
          continuePortalGesture(presence: presence, magnification: magnification, centroid: centroid,
            candidate: start.boardID, isApproaching: false)
          return true
        }
      }
    }
    guard snapshot.paperEngagement == nil,
      let candidate = snapshot.candidateItemID, itemKind(candidate) == .board,
      let center = model.sceneIndex?.focusedCenter(itemID: candidate, boardID: start.boardID) else { return false }
    if model.enterBoard(candidate, through: camera, settled: false), let presence = model.presence {
      continuePortalGesture(presence: presence, magnification: magnification, centroid: centroid,
        candidate: nil, isApproaching: snapshot.isApproaching)
      return true
    }
    let progress = BoardPortalProjection.openingProgress(camera: camera, portalCenter: center, viewport: viewport)
    snapshot.lastMagnification = magnification
    snapshot.followsPortal = true
    cameraGesture = snapshot
    model.updatePresence(.init(boardID: start.boardID, mode: progress > 0 ? .cover : .board,
      camera: camera, viewport: viewport, focusedItemID: progress > 0 ? candidate : nil,
      openProgress: progress), settled: false)
    return true
  }

  private func continuePortalGesture(presence: SessionPresence, magnification: CGFloat,
    centroid: CGPoint, candidate: UUID?, isApproaching: Bool) {
    cameraGesture = CameraGestureSnapshot(presence: presence,
      trajectory: .init(startingCamera: presence.camera, startingCentroid: centroid,
        startingMagnification: magnification, viewport: presence.viewport),
      lastMagnification: magnification, candidateItemID: candidate, dockingStartStrength: 0,
      isApproaching: isApproaching, paperEngagement: nil, dockingCorrection: .zero,
      openingWasVisible: presence.openProgress > 0, followsPortal: true)
    contentGestureActive = false
  }

  private func interruptSettlementForInput() {
    cameraSettlement.cancel()
    settling = false
  }

  private func updateBoardPan(
    _ translation: CGPoint,
    viewport: SpatialPoint
  ) {
    guard let start = panStart else { return }
    var camera = start.camera
    camera.pan(screenX: translation.x, screenY: translation.y)
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

  private func finishBoardPan(
    _ translation: CGPoint?,
    viewport: SpatialPoint
  ) {
    guard panStart != nil else { return }
    if let translation { updateBoardPan(translation, viewport: viewport) }
    panStart = nil
    // A pinch may already own the camera when its preceding one-finger pan
    // publishes cancellation. Only the current camera owner may settle it.
    if cameraGesture == nil, let presence = model.presence {
      model.updatePresence(presence, settled: true)
    }
  }

  private func focusCandidate(
    at centroid: CGPoint,
    presence: SessionPresence
  ) -> UUID? {
    sceneWorkset(presence: presence).items
      .reversed()
      .compactMap { rendered -> (UUID, Double)? in
        let strength = selectionStrength(rendered: rendered, at: centroid, presence: presence,
          halo: NotebookOpeningIntent.selectionHalo)
        return strength > 0 ? (rendered.id, strength) : nil
      }
      .max { $0.1 < $1.1 }?.0
  }

  private func selectionStrength(
    for itemID: UUID,
    at centroid: CGPoint,
    presence: SessionPresence,
    halo: Double = NotebookOpeningIntent.selectionHalo
  ) -> Double {
    guard
      let rendered = model.sceneIndex?.renderedItem(id: itemID, presence: presence)
    else { return 0 }
    return selectionStrength(rendered: rendered, at: centroid, presence: presence, halo: halo)
  }

  private func selectionStrength(rendered: RenderedWorkspaceItem, at centroid: CGPoint,
    presence: SessionPresence, halo: Double) -> Double {
    guard !model.isItemBeingDeleted(rendered.id) else { return 0 }
    let screen = presence.camera.worldToScreen(
      rendered.center,
      viewport: presence.viewport
    )
    let width = rendered.geometry.width * presence.camera.scale
    let height = rendered.geometry.height * presence.camera.scale
    return NotebookSelectionField.influence(
      centroid: SpatialPoint(x: centroid.x, y: centroid.y),
      cover: SpatialRect(
        x: screen.x - width / 2,
        y: screen.y - height / 2,
        width: width,
        height: height
      ),
      halo: halo
    )
  }

  private func showReference(_ reference: CollaborationReference, viewport: SpatialPoint) {
    guard let hierarchy = model.boardHierarchy else { return }
    let target = reference.target
    let itemID = target.kind == .page ? model.notebookPageOwner(target.id) : target.id
    let boardID = target.kind == .board ? target.id : itemID.flatMap { hierarchy.ownerBoardID(of:$0) }
    guard let boardID, let board = hierarchy.board(boardID) else { return }
    if target.kind == .board {
      var center = reference.worldOrigin ?? .zero
      var region = reference.region ?? .init(x:-400,y:-300,width:800,height:600)
      if let id = reference.elementID, let element = board.elements.first(where: { $0.id == id }) {
        center = element.worldOrigin ?? .zero
        region = .init(x:element.frame.x,y:element.frame.y,width:element.frame.width,height:element.frame.height)
      }
      guard let addressedCenter = center.addressOffset(x: region.x + region.width / 2, y: region.y + region.height / 2) else { return }
      center = addressedCenter
      let scale = min(1.5,max(SpatialCamera.minimumScale,min(viewport.x/(region.width+100),viewport.y/(region.height+100))))
      animateSettlement(to:.init(boardID:boardID,mode:.board,camera:.init(center:center,scale:scale),viewport:viewport),duration:0.3)
    } else if let itemID, let center = board.focusedCenter(of:itemID), center.isValid {
      if target.kind != .page { model.selectItem(itemID) }
      var pageIndex = reference.pageIndex ?? 0
      if target.kind == .document, let id = reference.elementID, let document = model.documents[itemID], let state = model.documentStates[itemID],
        let region = DocumentRenderRegistry.shared.regions(document:document,state:state).first(where: { $0.id == id }) { pageIndex = region.pageIndex }
      let mode: WorkspaceSemanticMode = target.kind == .page ? .page : target.kind == .document ? .document : .cover
      let geometry = model.itemGeometry(itemID)
      animateSettlement(to:.init(boardID:boardID,mode:mode,camera:.init(center:center,scale:mode == .cover ? geometry.coverScale(viewport:viewport) : geometry.fitScale(viewport:viewport)),
        viewport:viewport,focusedItemID:itemID,openProgress:mode == .cover ? 0 : 1,documentPageIndex:pageIndex),duration:0.3)
      if target.kind == .document, let blockID = reference.elementID {
        referencePageResolution.start(requestID: reference.id, documentID: itemID, isCurrent: {
          (settling || model.presence?.focusedItemID == itemID)
            && (settling || model.presence?.documentPageIndex == pageIndex)
            && model.requestedReturn == nil
            && (model.requestedReference == nil || model.requestedReference?.id == reference.id)
        }, resolve: {
          guard !settling, let document = model.documents[itemID], let state = model.documentStates[itemID]
          else { return nil }
          return DocumentRenderRegistry.shared.regions(document: document, state: state)
            .first(where: { $0.id == blockID })?.pageIndex
        }, apply: { resolvedPage in
          _ = model.selectDocumentPage(resolvedPage, documentID: itemID)
        })
      }
    }
    model.completeShow(reference)
  }

  private func openItem(
    _ itemID: UUID,
    viewport: SpatialPoint
  ) {
    guard !settling, !model.isItemBeingDeleted(itemID),
      cameraGesture == nil,
      let presence = model.presence,
      let center = model.sceneIndex?.focusedCenter(itemID: itemID, boardID: presence.boardID)
    else { return }
    if model.sceneIndex?.item(id: itemID)?.kind == .board {
      enterBoard(itemID, center: center, viewport: viewport)
      return
    }
    let previousPresence = model.presence
    model.selectItem(itemID)
    let target = SessionPresence(
      boardID: previousPresence?.boardID ?? WorkspaceRoot.boardID,
      mode: openMode(for: itemID),
      camera: SpatialCamera(center: center, scale: model.itemGeometry(itemID).fitScale(viewport: viewport)),
      viewport: viewport,
      focusedItemID: itemID,
      openProgress: 1,
      documentPageIndex: documentPageIndex(
        for: itemID,
        from: previousPresence
      )
    )
    animateSettlement(to: target, duration: 0.3)
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
    model.sceneIndex?.item(id: itemID)?.kind
  }

  private func animateSettlement(
    to target: SessionPresence,
    duration: TimeInterval,
    bounce: Double = 0.08,
    completion: @escaping () -> Void = {}
  ) {
    guard let start = model.presence else { return }
    let wasSettling = settling
    settling = true
    let accepted = cameraSettlement.start(from: start, to: target, duration: duration, bounce: bounce) { presence, settled in
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
    switch model.sceneIndex?.item(id: itemID)?.kind {
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
      model.sceneIndex?.item(id: itemID)?.kind == .document,
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
    guard let before = model.board else { return nil }
    if model.board?.stack(containing: itemID) != nil {
      model.unstackItem(itemID, at: center)
    } else {
      model.moveItem(itemID, to: center)
    }

    guard
      let moving = model.sceneIndex?.renderedItem(id: itemID, presence: presence)
    else { return nil }
    let target = sceneWorkset(presence: presence).items
      .reversed()
      .first { candidate in
        guard candidate.id != itemID else { return false }
        let delta = center.delta(to: candidate.center)
        return abs(delta.x) <= (moving.geometry.width + candidate.geometry.width) * 0.3
          && abs(delta.y) <= (moving.geometry.height + candidate.geometry.height) * 0.3
      }
    if let target {
      _ = model.stackItem(moving.id, onto: target.id)
    }
    guard let board = model.board else { return nil }
    return .init(itemID: itemID, before: before, after: board)
  }

}

private struct WorkspaceSceneItem: View, Equatable {
  @Environment(NotebookAppModel.self) private var model
  let rendered: RenderedWorkspaceItem
  let document: DocumentDocument?
  let documentState: DocumentStateJournal?
  let documentPageIndex: Int
  let documentPageCount: Int
  let camera: SpatialCamera
  let projectedScale: Double
  let boardID: UUID
  let contentRevision: UInt64
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
  let onEditText: (UUID, SpatialPoint) -> Void
  let onTextEditingEnded: (String) -> Void
  let onPageTurnStateChange: @MainActor @Sendable (Bool) -> Void
  let onDocumentPageLayout: (DocumentPageLayout) -> Void

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.rendered.id == rhs.rendered.id && lhs.rendered.center == rhs.rendered.center
      && lhs.rendered.zIndex == rhs.rendered.zIndex && lhs.contentRevision == rhs.contentRevision
      && lhs.coverElements.map(\.id) == rhs.coverElements.map(\.id)
      && lhs.boardID == rhs.boardID && lhs.camera == rhs.camera && lhs.viewport == rhs.viewport
      && lhs.isFocused == rhs.isFocused && lhs.preparesCoverMotion == rhs.preparesCoverMotion
      && lhs.preparesContent == rhs.preparesContent && lhs.openProgress == rhs.openProgress
      && lhs.contentIsInteractive == rhs.contentIsInteractive
      && lhs.pageNavigationIsEnabled == rhs.pageNavigationIsEnabled
      && lhs.isSelected == rhs.isSelected && lhs.liftRank == rhs.liftRank
      && lhs.editingTextID == rhs.editingTextID && lhs.documentPageIndex == rhs.documentPageIndex
      && lhs.documentPageCount == rhs.documentPageCount
      && (!(lhs.isSelected || lhs.rendered.item.kind == .board) || lhs.projectedScale == rhs.projectedScale)
  }

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
          model.inputGate.beginFingerSequence() != nil
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
        canBeginNavigation: { true },
        page: { index, isCurrent, readiness in
          documentPage(
            document: document,
            state: documentState,
            index: index,
            isCurrent: isCurrent,
            onRenderReady: readiness
          )
        },
        onCommit: commitDocumentPage,
        onTransitioningChange: onPageTurnStateChange
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

  private var notebookSelectedPageIndex: Int {
    guard let selectedPageID = model.workspace?.selectedPageID,
      let index = model.notebookPageIndex(selectedPageID, in: notebookItem.id)
    else { return 0 }
    return index
  }

  private var notebookFallbackSize: PageSize {
    guard let firstID = notebookItem.pageIDs.first,
      let page = model.pages[firstID]
    else { return NotebookAppModel.defaultPageSize }
    return page.size
  }

  private func notebookPage(
    at index: Int,
    isCurrent: Bool,
    isLive: Bool,
    onRenderReady: PageTurnReadiness
  ) -> AnyView {
    guard index >= 0, index < model.notebookPageCount(notebookItem.id) else {
      return AnyView(
        BlankPageSurface(fallbackSize: notebookFallbackSize)
          .onAppear { onRenderReady(index == model.notebookPageCount(notebookItem.id)) }
      )
    }
    guard let page = model.notebookPage(at: index, in: notebookItem.id) else {
      return AnyView(
        BlankPageSurface(fallbackSize: notebookFallbackSize)
          .overlay { ProgressView().allowsHitTesting(false) }
          .onAppear { onRenderReady(false) }
          .task { await model.prepareNotebookPage(at: index, in: notebookItem.id) }
          .accessibilityLabel("Загружается лист \(index + 1)")
      )
    }
    return AnyView(
      PageSurface(
        page: page,
        isInteractive: isCurrent && contentIsInteractive,
        isVisible: isLive,
        onRenderReady: onRenderReady
      )
    )
  }

  private func documentPage(
    document: DocumentDocument,
    state: DocumentStateJournal,
    index: Int,
    isCurrent: Bool,
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
        onPageNavigation: { page in
          guard isCurrent, contentIsInteractive, model.documents[document.id] == document else { return }
          commitDocumentPage(page, "\(document.contentStamp.actor):\(document.contentStamp.counter)")
        },
        onSourceChange: { edit in try await model.commitDocumentSource(edit: edit) },
        onStateChange: { blockID, value in
          model.commitDocumentState(
            documentID: document.id,
            blockID: blockID,
            value: value
          )
        },
        drafts: model.documentEditingSessions.filter { $0.edit.documentID == document.id },
        onDraftChange: model.saveDocumentDraft,
        onDraftDiscard: model.discardDocumentDraft
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

  private func commitDocumentPage(_ targetIndex: Int, _ revision: String) {
    guard targetIndex >= 0, targetIndex < documentPageCount,
      model.selectDocumentPage(targetIndex, documentID: rendered.id) != nil
    else { return }
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

  private func handleTap(_ location: CGPoint, tapCount: Int) {
    guard openProgress < 0.12, !model.isItemBeingDeleted(rendered.id) else { return }
    onSelect(rendered.id)
    if let editingTextID {
      onTextEditingEnded(editingTextID)
    }
    guard tapCount >= 2 else { return }
    if rendered.item.kind == .notebook,
      isFocused,
      model.presence?.mode == .cover
    {
      onEditText(
        rendered.id,
        SpatialPoint(x: location.x, y: location.y)
      )
    } else {
      onOpen(rendered.id)
    }
  }

}


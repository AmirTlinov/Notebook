import NotebookCore
import PencilKit
import SwiftUI

#if os(iOS)
  import UIKit
#elseif os(macOS)
  import AppKit
#endif

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

struct RenderedWorkspaceItem: Identifiable, Sendable {
  let item: WorkspaceItem
  let geometry: WorkspaceItemGeometry
  let center: WorldPoint
  let zIndex: Double
  let stackID: UUID?

  var id: UUID { item.id }
}

enum WorkspaceSceneProjection {
  static let portalPasses = 32

  static func showsPortal(pixelScale: Double, remainingPasses: Int) -> Bool {
    remainingPasses > 0 && WorkspaceItemGeometry.notebook.width * pixelScale >= 8
  }

  /// Geometry and camera targeting still see every item. Only mounted content
  /// is bounded by the viewport, with room for shadows and preparation before
  /// an edge appears. A focused sheet keeps its input and page-turn owner.
  static func mountsContent(of item: RenderedWorkspaceItem, in presence: SessionPresence) -> Bool {
    if presence.focusedItemID == item.id { return true }
    let center = presence.camera.worldToScreen(item.center, viewport: presence.viewport)
    let halfWidth = item.geometry.width * presence.camera.scale / 2
    let halfHeight = item.geometry.height * presence.camera.scale / 2
    let margin = 96.0 + WorkspaceCoverRaster.shadowPadding * presence.camera.scale
    return center.x + halfWidth >= -margin && center.x - halfWidth <= presence.viewport.x + margin
      && center.y + halfHeight >= -margin && center.y - halfHeight <= presence.viewport.y + margin
  }

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
  @Environment(NotebookAppModel.self) private var model

  @State private var pointerPreview: CGRect?
  @State private var cameraGesture: CameraGestureSnapshot?
  @State private var panStart: SessionPresence?
  @State private var selectedItemID: UUID?
  @State private var liftedItemID: UUID?
  @State private var editingSpatialTextID: String?
  @State private var contentGestureActive = false
  @State private var pageTurnIsActive = false
  @State private var pageInputGestureID: UUID?
  @State private var bufferedCameraPhases: [WorkspaceMagnificationPhase] = []
  @State private var documentPageLayouts: [UUID: DocumentPageLayout] = [:]
  @State private var settling = false
  @State private var cameraSettlement = SceneCameraSettlement()
  @State private var referencePageResolution = NotebookReferencePageResolution()
  @State private var spatialInkSurfaces = SpatialInkSurfaceRegistry()
  #if os(iOS)
    @State private var openingFeedback = UIImpactFeedbackGenerator(style: .soft)
  #endif

  var body: some View {
    GeometryReader { geometry in
      let viewport = SpatialPoint(
        x: geometry.size.width,
        y: geometry.size.height
      )
      let presence = normalizedPresence(for: viewport)
      let frame = model.sceneIndex.map {
        WorkspaceSceneFrame(index: $0, presence: presence, portalCamera: model.scenePortalCamera,
          pinned: scenePins(presence: presence))
      }
      let workset = frame?.workset(boardID: presence.boardID) ?? .empty
      let rendered = workset.items

      ZStack {
        SpatialBoardGrid(camera: presence.camera)
        if model.sceneIndex == nil && model.scenePreparationPending {
          ProgressView("Подготовка пространства")
            .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .zIndex(9_000)
        }

        #if os(iOS)
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
            },
            onTap: {
              withAnimation(.easeOut(duration: 0.12)) {
                selectedItemID = nil
              }
              model.clearElementSelection()
              editingSpatialTextID = nil
            },
            onBegan: {
              referencePageResolution.cancel()
              selectedItemID = nil
              model.clearElementSelection()
              editingSpatialTextID = nil
              panStart = presence
            },
            onChanged: { translation in
              updateBoardPan(translation, viewport: viewport)
            },
            onEnded: { translation in
              finishBoardPan(translation, viewport: viewport)
            }
          )
          .frame(width: viewport.x, height: viewport.y)
        #endif

        WorkspaceSceneAggregates(aggregates: workset.aggregates, presence: presence)
        boardElements(workset.elements, presence: presence, viewport: viewport)
          .zIndex(model.isElementEditingEnabled ? 8_000 : 0)

        #if os(macOS)
          SpatialInkSurfaceView(
            surface: .board(presence.boardID), journal: model.spatialInk, camera: presence.camera, viewport: viewport
          )
          .frame(width: viewport.x, height: viewport.y)
          .allowsHitTesting(false)
        #endif

        #if os(iOS)
          SpatialInkCanvas(
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
            onCommit: model.appendSpatialInk,
            isEnabled: (presence.mode == .board || presence.mode == .cover)
              && !model.scenePreparationPending && !contentGestureActive
              && editingSpatialTextID == nil
              && !model.isElementEditingEnabled && !model.isPointing
          )
          .allowsHitTesting(false)
        #endif

        sceneItems(rendered, presence: presence, viewport: viewport, frame: frame)
          .zIndex(liftedItemID == nil ? 0 : 9_000)

        #if os(iOS)
          WorkspaceGestureLayer(
            isEnabled: true,
            defersHorizontalMotionToPageTurn: (presence.mode == .page
              || presence.mode == .document)
              && presence.openProgress >= 0.999 && !model.isPointing,
            inputGate: model.inputGate,
            onCamera: handleWorkspaceMagnification,
            onUndo: {
              model.afterPageInput { model.undoLastSurfaceAction() }
            }
          )
          .allowsHitTesting(false)

          itemSelectionControl(presence: presence, viewport: viewport)
        #endif

        NotebookAttentionMarks(presence:presence)
        #if os(iOS)
          if model.isPointing {
            NotebookPointerView(onPreview:{ pointerPreview = $0 },onPoint:{ start,end in
              guard cameraGesture == nil, !settling, !model.scenePreparationPending else { return }
              let references = NotebookAttentionProjection.references(start:start,end:end,model:model,presence:presence)
              if !references.isEmpty { model.publishHumanContext(references) }
            })
            if let rect = pointerPreview {
              RoundedRectangle(cornerRadius:4).stroke(.indigo,style:StrokeStyle(lineWidth:2,dash:[6,4]))
                .frame(width:rect.width,height:rect.height).position(x:rect.midX,y:rect.midY).allowsHitTesting(false)
            }
          }
          NotebookDisplayConfirmation {
            guard cameraGesture == nil, !settling, !pageTurnIsActive, !contentGestureActive else { return }
            model.confirmVisibleActions(presence: presence, scene: workset)
          }.allowsHitTesting(false)
        #else
          if model.isPointing {
            Color.clear.contentShape(Rectangle()).gesture(DragGesture(minimumDistance:0).onEnded { value in
              let references = NotebookAttentionProjection.references(start:value.startLocation,end:value.location,model:model,presence:presence)
              if !references.isEmpty { model.publishHumanContext(references) }
            })
          }
        #endif

        controls(presence: presence, viewport: viewport)
      }
      .clipped()
      .onAppear {
        publishViewportIfNeeded(viewport)
      }
      .task(id:model.requestedReference?.id) {
        guard let reference = model.requestedReference else { return }
        referencePageResolution.cancel()
        while cameraGesture != nil || settling || pageTurnIsActive || contentGestureActive || model.presencePhase != .settled {
          do { try await Task.sleep(for:.milliseconds(40)) } catch { return }
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
        model.afterPageInput {
          guard model.requestedReturn?.id == place.id else { return }
          defer { model.completeReturnToPlace() }
          guard model.boardHierarchy?.board(place.presence.boardID) != nil else { return }
          if let itemID = place.presence.focusedItemID {
            guard let item = model.workspace?.items.first(where: { $0.id == itemID }) else { return }
            model.selectItem(itemID)
            if let pageID = place.pageID, let index = item.pageIDs.firstIndex(of: pageID) {
              _ = model.selectNotebookPage(index, notebookID: itemID)
            }
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
        model.clearElementSelection()
        if mode != .cover { editingSpatialTextID = nil }
        if mode != .page && mode != .document {
          pageTurnIsActive = false
        }
      }
      .onChange(of: presence.focusedItemID) { _, itemID in
        if referencePageResolution.documentID != itemID { referencePageResolution.cancel() }
        model.clearElementSelection()
        if itemID == nil { editingSpatialTextID = nil }
        pageTurnIsActive = false
      }
      .onDisappear {
        referencePageResolution.cancel()
        cameraSettlement.cancel()
        cameraGesture = nil
        contentGestureActive = false
        pageTurnIsActive = false
        pageInputGestureID = nil
        bufferedCameraPhases = []
        settling = false
        editingSpatialTextID = nil
        model.clearElementSelection()
      }
    }
  }

  @ViewBuilder
  private func itemSelectionControl(
    presence: SessionPresence,
    viewport: SpatialPoint
  ) -> some View {
    if !model.isElementEditingEnabled,
      presence.mode == .board || presence.mode == .cover,
      liftedItemID == nil,
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
        guard model.deleteItem(selectedItemID) else { return }
        self.selectedItemID = nil
      } label: {
        Image(systemName: "trash")
          .font(.system(size: 17, weight: .semibold))
          .frame(width: 44, height: 44)
          .background(.regularMaterial, in: Circle())
          .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
      }
      .buttonStyle(.plain)
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
    #if os(iOS)
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

    #endif
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
    let generation: UUID?
    let contents: UInt64
    let ids: [UUID]
    let coverIDs: [UUID: [String]]
    let mode: WorkspaceSemanticMode
    let focused: UUID?
    let open: Double
    let selected: UUID?
    let lifted: UUID?
    let candidate: UUID?
    let editingText: String?
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
    viewport: SpatialPoint, frame: WorkspaceSceneFrame?) -> some View {
    let revision = ItemPlaneRevision(generation: model.sceneIndex?.generationID,
      contents: model.collaborationReadEpoch, ids: rendered.map(\.id),
      coverIDs: frame?.covers.mapValues { $0.elements.map { "element:" + $0.id } + $0.aggregates.map { "aggregate:" + String($0.id) } } ?? [:], mode: presence.mode,
      focused: presence.focusedItemID, open: presence.openProgress,
      selected: selectedItemID, lifted: liftedItemID, candidate: cameraGesture?.candidateItemID,
      editingText: editingSpatialTextID, contentGesture: contentGestureActive,
      pageTurn: pageTurnIsActive, isCameraGesture: cameraGesture != nil, settling: settling,
      pointing: model.isPointing, prepares: rendered.map { preparesContent($0.id, presence: presence) },
      page: presence.documentPageIndex, layout: documentPageLayouts,
      dependentCamera: rendered.contains { $0.stackID != nil || $0.item.kind == .board }
        || selectedItemID != nil ? presence.camera : nil)
    return SceneCameraPlane(presence: presence, revision: revision, reanchorsOnRevision: false,
      isCameraActive: cameraGesture != nil || panStart != nil || settling) { anchor in
      ZStack { sceneItemContents(rendered, presence: presence, viewport: viewport, anchorCamera: anchor.camera, frame: frame) }
        .environment(model).environment(\.workspaceSceneFrame, frame)
    }
  }

  private func sceneItemContents(_ rendered: [RenderedWorkspaceItem], presence: SessionPresence,
    viewport: SpatialPoint, anchorCamera: SpatialCamera, frame: WorkspaceSceneFrame?) -> some View {
    ForEach(rendered.filter {
          WorkspaceSceneProjection.mountsContent(of: $0, in: presence)
            || $0.id == selectedItemID || $0.id == liftedItemID
            || $0.id == cameraGesture?.candidateItemID
        }) { rendered in
          WorkspaceSceneItem(
            rendered: rendered,
            document: model.documents[rendered.id],
            documentState: model.documentStates[rendered.id],
            documentPageIndex: presence.focusedItemID == rendered.id
              ? presence.documentPageIndex
              : 0,
            documentPageCount: documentPageLayouts[rendered.id]?.pageCount ?? 1,
            camera: anchorCamera,
            projectedScale: presence.camera.scale,
            boardID: presence.boardID,
            contentRevision: model.collaborationReadEpoch,
            coverElements: frame?.covers[rendered.id]?.elements ?? [],
            coverAggregates: frame?.covers[rendered.id]?.aggregates ?? [],
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
            contentIsInteractive: !model.isPointing && presence.focusedItemID == rendered.id
              && (presence.mode == .page || presence.mode == .document)
              && !contentGestureActive
              && !pageTurnIsActive
              && cameraGesture == nil
              && !settling
              && presence.openProgress >= 0.999,
            pageNavigationIsEnabled: !model.isPointing && presence.focusedItemID == rendered.id
              && (presence.mode == .page || presence.mode == .document)
              && presence.openProgress >= 0.999
              && cameraGesture == nil
              && !settling
              && (!model.isElementEditingEnabled || presence.mode == .document),
            isSelected: selectedItemID == rendered.id,
            isLifted: liftedItemID == rendered.id,
            editingTextID: editingSpatialTextID,
            spatialInkSurfaces: spatialInkSurfaces,
            onDrop: { itemID, center in
              guard !model.scenePreparationPending else { return }
              dropItem(itemID, at: center, presence: model.presence ?? presence)
            },
            onSelect: { itemID in
              withAnimation(.easeOut(duration: 0.12)) {
                selectedItemID = itemID
              }
            },
            onLiftChanged: { itemID, lifted in
              if lifted { editingSpatialTextID = nil }
              withAnimation(.spring(duration: 0.18, bounce: 0.18)) {
                liftedItemID = lifted ? itemID : nil
                if lifted { selectedItemID = itemID }
              }
            },
            onOpen: { itemID in
              guard !model.scenePreparationPending else { return }
              editingSpatialTextID = nil
              selectedItemID = nil
              openItem(itemID, viewport: viewport)
            },
            onEditText: { itemID, point in
              guard !model.scenePreparationPending else { return }
              beginTextEditing(on: itemID, at: point)
            },
            onTextEditingEnded: { elementID in
              if editingSpatialTextID == elementID {
                editingSpatialTextID = nil
              }
            },
            onElementSelected: {
              selectedItemID = nil
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
          .zIndex(liftedItemID == rendered.id ? 9_000 : rendered.zIndex)
        }

  }

  private struct ElementPlaneRevision: Equatable {
    let generation: UUID?
    let elements: [String]
    let editing: Bool
    let selection: EditableElementReference?
    let translation: SpatialPoint
    let resize: SpatialPoint
    let pending: Bool
    // Frame handles remain screen-sized. Their small selected surface changes
    // presentation explicitly; passive content does not subscribe to the camera.
    let editingCamera: SpatialCamera?
  }

  private func boardElements(_ elements: [SpatialElement], presence: SessionPresence,
    viewport: SpatialPoint) -> some View {
    let selection = model.elementEditingSession.selection
    let revision = ElementPlaneRevision(generation: model.sceneIndex?.generationID,
      elements: elements.map(\.id), editing: model.isElementEditingEnabled,
      selection: selection, translation: model.elementEditingSession.translation,
      resize: selection.map { model.elementResizeDelta($0) } ?? .zero,
      pending: model.scenePreparationPending, editingCamera: selection == nil ? nil : presence.camera)
    return SceneCameraPlane(presence: presence, revision: revision,
      isCameraActive: cameraGesture != nil || panStart != nil || settling) { anchor in
      ZStack { boardElementContents(elements, presence: anchor, viewport: anchor.viewport) }
        .environment(model)
    }
  }

  @ViewBuilder
  private func boardElementContents(
    _ elements: [SpatialElement],
    presence: SessionPresence,
    viewport: SpatialPoint
  ) -> some View {
    ForEach(elements) { element in
        if let worldOrigin = element.worldOrigin {
          let reference = EditableElementReference.spatial(elementID: element.id)
          let base = presence.camera.worldToScreen(
            worldOrigin,
            viewport: viewport
          )
          let origin = CGPoint(
            x: base.x + element.frame.x * presence.camera.scale,
            y: base.y + element.frame.y * presence.camera.scale
          )
          EditableElementContainer(
            isEditingEnabled: model.isElementEditingEnabled && !model.scenePreparationPending,
            isSelected: model.elementEditingSession.selection == reference,
            coordinateScale: presence.camera.scale,
            translation: elementTranslation(for: reference),
            isContentInteractive: !model.scenePreparationPending && !element.javaScript.isEmpty,
            onSelect: {
              model.selectElement(reference)
              selectedItemID = nil
            },
            onDragChanged: { translation in
              model.updateElementDrag(reference, translation: translation)
            },
            onDragEnded: { translation in
              model.finishElementDrag(reference, translation: translation)
            },
            onResizeChanged: { model.updateElementResize(reference, delta: $0) },
            onResizeEnded: { model.finishElementResize(reference, delta: $0) },
            resizeDelta: model.elementResizeDelta(reference),
            onDelete: { model.deleteElement(reference) }
          ) {
            // The physical viewport belongs to the element. The camera transforms
            // its whole layer; WebKit layout must not trail the moving frame.
            SpatialElementContent(element: element, boardID: presence.boardID)
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
        }
      }
  }

  private func elementTranslation(
    for reference: EditableElementReference
  ) -> SpatialPoint {
    guard model.elementEditingSession.selection == reference else {
      return .zero
    }
    return model.elementEditingSession.translation
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
      editingSpatialTextID = text.id
      return
    }
    guard !elements.contains(where: { $0.frame.contains(point) }),
      let elementID = model.addNativeText(boardID: boardID, on: itemID, at: point)
    else { return }
    editingSpatialTextID = elementID
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
    #if os(iOS)
      guard let presence = model.presence,
        presence.viewport != viewport
      else { return }
      model.updatePresence(normalizedPresence(for: viewport), settled: true)
    #endif
  }

  private func scenePins(presence: SessionPresence) -> Set<WorkspaceSpatialID> {
    var pins = Set<WorkspaceSpatialID>()
    for id in [presence.focusedItemID, selectedItemID, liftedItemID, cameraGesture?.candidateItemID] {
      if let id { pins.insert(.item(id)) }
    }
    if case .spatial(let id) = model.elementEditingSession.selection { pins.insert(.element(id)) }
    if let editingSpatialTextID { pins.insert(.element(editingSpatialTextID)) }
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
    #if os(iOS)
      return model.workspace?.selectedItemID == itemID
    #else
      return false
    #endif
  }

  private func handleBoardMagnification(_ phase: WorkspaceMagnificationPhase) {
    switch phase {
    case .began(let centroid, let isOpeningApproach):
      interruptSettlementForInput()
      #if os(iOS)
        openingFeedback.prepare()
      #endif
      selectedItemID = nil
      editingSpatialTextID = nil
      guard let presence = model.presence else { return }
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

  private func finishBoardPan(
    _ translation: CGPoint,
    viewport: SpatialPoint
  ) {
    updateBoardPan(translation, viewport: viewport)
    panStart = nil
    if let presence = model.presence {
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
    guard let workspace = model.workspace, let hierarchy = model.boardHierarchy else { return }
    let target = reference.target
    let itemID = target.kind == .page ? workspace.items.first(where: { $0.pageIDs.contains(target.id) })?.id : target.id
    let boardID = target.kind == .board ? target.id : itemID.flatMap { hierarchy.ownerBoardID(of:$0) }
    guard let boardID, let board = hierarchy.board(boardID) else { return }
    if target.kind == .board {
      var center = reference.worldOrigin ?? .zero
      var region = reference.region ?? .init(x:-400,y:-300,width:800,height:600)
      if let id = reference.elementID, let element = board.elements.first(where: { $0.id == id }) {
        center = element.worldOrigin ?? .zero
        region = .init(x:element.frame.x,y:element.frame.y,width:element.frame.width,height:element.frame.height)
      }
      center = center.offsetBy(x:region.x + region.width / 2,y:region.y + region.height / 2)
      let scale = min(1.5,max(SpatialCamera.minimumScale,min(viewport.x/(region.width+100),viewport.y/(region.height+100))))
      animateSettlement(to:.init(boardID:boardID,mode:.board,camera:.init(center:center,scale:scale),viewport:viewport),duration:0.3)
    } else if let itemID, let center = board.focusedCenter(of:itemID) {
      model.selectItem(itemID)
      if target.kind == .page, let item = workspace.items.first(where: { $0.id == itemID }), let index = item.pageIDs.firstIndex(of:target.id) {
        _ = model.selectNotebookPage(index,notebookID:itemID)
      }
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
    guard !settling,
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
    guard let presence = model.presence else { return }
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
    settling = true
    cameraSettlement.start(from: start, to: target, duration: duration, bounce: bounce) { presence, settled in
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) { model.updatePresence(presence, settled: settled) }
    } completion: {
      contentGestureActive = false
      settling = false
      completion()
    }
  }

  private func performOpeningFeedback() {
    #if os(iOS)
      openingFeedback.impactOccurred(intensity: 0.6)
      openingFeedback.prepare()
    #elseif os(macOS)
      NSHapticFeedbackManager.defaultPerformer.perform(
        .alignment,
        performanceTime: .now
      )
    #endif
  }

  private func createItem(
    kind: WorkspaceItemKind,
    paperSize: DocumentPaperSize = .a4,
    presence: SessionPresence,
    viewport: SpatialPoint
  ) {
    selectedItemID = nil
    let offset = Double(model.workspace?.items.count ?? 0) * 28
    let center = presence.camera.center.offsetBy(x: offset, y: offset)
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

  private func dropItem(
    _ itemID: UUID,
    at center: WorldPoint,
    presence: SessionPresence
  ) {
    if model.board?.stack(containing: itemID) != nil {
      model.unstackItem(itemID, at: center)
    } else {
      model.moveItem(itemID, to: center)
    }

    guard
      let moving = model.sceneIndex?.renderedItem(id: itemID, presence: presence)
    else { return }
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
  }

}

private struct WorkspaceSceneItem: View, Equatable {
  @Environment(NotebookAppModel.self) private var model
  @Environment(\.scenePlaneProjection) private var planeProjection

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
  let coverAggregates: [WorkspaceSpatialAggregate]
  let viewport: SpatialPoint
  let isFocused: Bool
  let preparesCoverMotion: Bool
  let preparesContent: Bool
  let openProgress: Double
  let contentIsInteractive: Bool
  let pageNavigationIsEnabled: Bool
  let isSelected: Bool
  let isLifted: Bool
  let editingTextID: String?
  let spatialInkSurfaces: SpatialInkSurfaceRegistry
  let onDrop: (UUID, WorldPoint) -> Void
  let onSelect: (UUID) -> Void
  let onLiftChanged: (UUID, Bool) -> Void
  let onOpen: (UUID) -> Void
  let onEditText: (UUID, SpatialPoint) -> Void
  let onTextEditingEnded: (String) -> Void
  let onElementSelected: () -> Void
  let onPageTurnStateChange: @MainActor @Sendable (Bool) -> Void
  let onDocumentPageLayout: (DocumentPageLayout) -> Void

  @State private var dragTranslation = CGSize.zero
  @State private var pendingPlacement: WorldPoint?
  @State private var liftStarted = false

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.rendered.id == rhs.rendered.id && lhs.rendered.center == rhs.rendered.center
      && lhs.rendered.zIndex == rhs.rendered.zIndex && lhs.contentRevision == rhs.contentRevision
      && lhs.coverElements.map(\.id) == rhs.coverElements.map(\.id)
      && lhs.coverAggregates == rhs.coverAggregates
      && lhs.boardID == rhs.boardID && lhs.camera == rhs.camera && lhs.viewport == rhs.viewport
      && lhs.isFocused == rhs.isFocused && lhs.preparesCoverMotion == rhs.preparesCoverMotion
      && lhs.preparesContent == rhs.preparesContent && lhs.openProgress == rhs.openProgress
      && lhs.contentIsInteractive == rhs.contentIsInteractive
      && lhs.pageNavigationIsEnabled == rhs.pageNavigationIsEnabled
      && lhs.isSelected == rhs.isSelected && lhs.isLifted == rhs.isLifted
      && lhs.editingTextID == rhs.editingTextID && lhs.documentPageIndex == rhs.documentPageIndex
      && lhs.documentPageCount == rhs.documentPageCount
      && (!(lhs.isSelected || lhs.rendered.item.kind == .board) || lhs.projectedScale == rhs.projectedScale)
  }

  var body: some View {
    let screen = camera.worldToScreen(pendingPlacement ?? rendered.center, viewport: viewport)
    let scale = camera.scale
    let contentIsLive = openProgress > 0.001 || contentIsInteractive
    let restingShadowVisibility =
      CoverOpeningPhysics.restingShadowVisibility(openProgress)
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
    .scaleEffect(scale * (isLifted ? 1.035 : 1))
    .rotationEffect(.degrees(isLifted ? -0.6 : 0))
    .offset(dragTranslation)
    .offset(y: isLifted ? -8 : 0)
    .position(x: screen.x, y: screen.y)
    .animation(.spring(duration: 0.18, bounce: 0.18), value: isLifted)
    .onChange(of: model.sceneIndexGeneration) { _, _ in pendingPlacement = nil }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(
      "workspace-item-\(rendered.id.uuidString.lowercased())"
    )
    .accessibilityAddTraits(.isButton)
    .accessibilityValue(
      isLifted ? "Готова к перемещению" : (isSelected ? "Выбрана" : "")
    )
  }

  @ViewBuilder
  private func notebookContents(isLive: Bool) -> some View {
    if preparesContent, !notebookItem.pageIDs.isEmpty {
      PageTurnSurface(
        ownerID: rendered.id,
        pageCount: notebookItem.pageIDs.count + 1,
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
      let index = notebookItem.pageIDs.firstIndex(of: selectedPageID)
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
    guard index >= 0,
      index < notebookItem.pageIDs.count,
      let page = model.pages[notebookItem.pageIDs[index]]
    else {
      return AnyView(
        BlankPageSurface(fallbackSize: notebookFallbackSize)
          .onAppear { onRenderReady(true) }
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
        onSourceChange: { blockID, source in
          model.replaceDocumentBlockSource(
            documentID: document.id,
            blockID: blockID,
            source: source
          )
        },
        onStateChange: { blockID, value in
          model.commitDocumentState(
            documentID: document.id,
            blockID: blockID,
            value: value
          )
        }
      )
    )
  }

  private func commitNotebookPage(_ targetIndex: Int) {
    guard model.selectNotebookPage(
      targetIndex,
      notebookID: rendered.id
    ) != nil else { return }
    announcePage(targetIndex + 1)
  }

  private func commitDocumentPage(_ targetIndex: Int) {
    guard targetIndex >= 0, targetIndex < documentPageCount,
      model.selectDocumentPage(targetIndex, documentID: rendered.id) != nil
    else { return }
    announcePage(targetIndex + 1)
  }

  private func announcePage(_ number: Int) {
    #if os(iOS)
      UISelectionFeedbackGenerator().selectionChanged()
      UIAccessibility.post(
        notification: .pageScrolled,
        argument: "Страница \(number)"
      )
    #endif
  }

  private var itemCover: some View {
    WorkspaceItemCoverView(
      item: rendered.item,
      geometry: rendered.geometry,
      spatialInkSurfaces: spatialInkSurfaces,
      elements: coverElements,
      aggregates: coverAggregates,
      editingTextID: editingTextID,
      isElementEditingEnabled: model.isElementEditingEnabled && !model.scenePreparationPending,
      portalOpenProgress: openProgress,
      portalViewport: viewport,
      onTap: handleTap,
      onLiftChanged: { lifted in
        if lifted { beginLift() } else { endLift() }
      },
      onTranslationChanged: { translation in
        let ratio = camera.scale / (planeProjection?.current.camera.scale ?? camera.scale)
        dragTranslation = CGSize(width: translation.width * ratio, height: translation.height * ratio)
      },
      onTranslationEnded: { translation in
        finishMove(translation: translation, scale: planeProjection?.current.camera.scale ?? camera.scale)
      },
      onTextEditingEnded: onTextEditingEnded,
      onElementSelected: onElementSelected,
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
    guard openProgress < 0.12 else { return }
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

  private func finishMove(translation: CGSize, scale: Double) {
    dragTranslation = .zero
    guard !model.scenePreparationPending,
      hypot(translation.width, translation.height) >= 2 else { return }
    let center = rendered.center.offsetBy(
      x: translation.width / max(scale, 0.001),
      y: translation.height / max(scale, 0.001)
    )
    pendingPlacement = center
    onDrop(rendered.id, center)
    if !model.scenePreparationPending { pendingPlacement = nil }
  }

  private func beginLift() {
    guard !model.scenePreparationPending, !liftStarted else { return }
    liftStarted = true
    #if os(iOS)
      UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    #endif
    onLiftChanged(rendered.id, true)
  }

  private func endLift() {
    liftStarted = false
    onLiftChanged(rendered.id, false)
  }
}

/// A portal is a read-only projection of the child board, not a decorative
/// cover. It uses the same camera that becomes active at handoff. Recursive
/// drawing follows a pixel threshold and a finite frame budget; the durable
/// hierarchy itself has no depth bound.
struct BoardPortalPreview: View {
  @Environment(NotebookAppModel.self) private var model
  @Environment(\.workspaceSceneFrame) private var frame

  let boardID: UUID
  let pixelScale: Double
  let remainingPortalPasses: Int
  let transitionViewport: SpatialPoint

  var body: some View {
    if model.sceneIndex?.board(id: boardID) != nil {
      let camera = BoardPortalProjection.entryCamera(
        portalCamera: model.scenePortalCamera(boardID: boardID) ?? BoardPortalCamera(),
        viewport: transitionViewport
      )
      let viewport = BoardPortalProjection.renderViewport(viewport: transitionViewport)
      let fill = BoardPortalProjection.fillScale(viewport: transitionViewport)
      let presence = SessionPresence(
        boardID: boardID,
        mode: .board,
        camera: camera,
        viewport: viewport
      )
      let projectionFrame = frame ?? model.sceneIndex.map {
        WorkspaceSceneFrame(index: $0, presence: presence, portalCamera: model.scenePortalCamera)
      }
      let workset = projectionFrame?.workset(boardID: boardID) ?? .empty
      let rendered = workset.items
      let elements = workset.elements

      ZStack {
        SpatialBoardGrid(camera: camera, outputScale: pixelScale / fill)
        if workset.generationID == nil {
          Text("Подготовка области").font(.caption).foregroundStyle(.secondary)
            .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        WorkspaceSceneAggregates(aggregates: workset.aggregates, presence: presence)

        ForEach(elements) {
          element in
          if let origin = element.worldOrigin {
            let screen = camera.worldToScreen(origin, viewport: viewport)
            SpatialElementContent(element: element, commitsState: false)
              .frame(width: element.frame.width, height: element.frame.height)
              .scaleEffect(camera.scale)
              .frame(
                width: element.frame.width * camera.scale,
                height: element.frame.height * camera.scale
              )
              .position(
                x: screen.x
                  + (element.frame.x + element.frame.width / 2) * camera.scale,
                y: screen.y
                  + (element.frame.y + element.frame.height / 2) * camera.scale
              )
          }
        }

        #if os(iOS)
          PortalBoardInkView(
            boardID: boardID, journal: model.spatialInk,
            camera: camera, viewport: viewport
          )
        #else
          SpatialInkSurfaceView(surface: .board(boardID), journal: model.spatialInk, camera: camera, viewport: viewport)
        #endif

        ForEach(rendered.filter { WorkspaceSceneProjection.mountsContent(of: $0, in: presence) }) { item in
          let screen = camera.worldToScreen(item.center, viewport: viewport)
          WorkspaceItemCoverView(
            item: item.item,
            geometry: item.geometry,
            spatialInkSurfaces: SpatialInkSurfaceRegistry(),
            elements: projectionFrame?.covers[item.id]?.elements ?? [],
            aggregates: projectionFrame?.covers[item.id]?.aggregates ?? [],
            editingTextID: nil, isElementEditingEnabled: false,
            portalOpenProgress: 0, portalViewport: transitionViewport,
            onTap: { _, _ in }, onLiftChanged: { _ in },
            onTranslationChanged: { _ in }, onTranslationEnded: { _ in },
            onTextEditingEnded: { _ in }, onElementSelected: {},
            isPortalProjection: true,
            portalPixelScale: pixelScale * camera.scale / fill,
            remainingPortalPasses: remainingPortalPasses - 1
          )
          .frame(
            width: item.geometry.width,
            height: item.geometry.height
          )
          .background { WorkspaceItemShadow(geometry: item.geometry) }
          .scaleEffect(camera.scale)
          .position(x: screen.x, y: screen.y)
          .zIndex(item.zIndex)
        }
      }
      .environment(\.workspaceSceneFrame, projectionFrame)
      .frame(width: viewport.x, height: viewport.y)
      .scaleEffect(1 / fill)
      .frame(width: WorkspaceItemGeometry.notebook.width, height: WorkspaceItemGeometry.notebook.height)
      .clipped()
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    } else {
      Color(red: 0.94, green: 0.95, blue: 0.945)
    }
  }
}

struct WorkspaceCoverTitle: View {
  let item: WorkspaceItem
  let geometry: WorkspaceItemGeometry

  var body: some View {
    if item.kind != .board, !item.title.isEmpty {
      Text(item.title)
        .font(.system(size: geometry.width * (item.kind == .document ? 0.056 : 0.048),
          weight: .medium, design: item.kind == .document ? .serif : .default))
        .foregroundStyle(Color.black.opacity(0.76))
        .lineLimit(3)
        .frame(width: geometry.width * 0.72, alignment: .leading)
        .offset(x: geometry.width * (item.kind == .document ? 0.105 : 0.145),
          y: geometry.height * (item.kind == .document ? 0.145 : 0.148))
    }
  }
}

struct WorkspaceItemCoverView: View {
  @Environment(NotebookAppModel.self) private var model

  let item: WorkspaceItem
  let geometry: WorkspaceItemGeometry
  let spatialInkSurfaces: SpatialInkSurfaceRegistry
  let elements: [SpatialElement]
  var aggregates: [WorkspaceSpatialAggregate] = []
  let editingTextID: String?
  let isElementEditingEnabled: Bool
  let portalOpenProgress: Double
  let portalViewport: SpatialPoint
  let onTap: (CGPoint, Int) -> Void
  let onLiftChanged: (Bool) -> Void
  let onTranslationChanged: (CGSize) -> Void
  let onTranslationEnded: (CGSize) -> Void
  let onTextEditingEnded: (String) -> Void
  let onElementSelected: () -> Void
  var showsDepth = true
  var isPortalProjection = false
  var portalPixelScale: Double = 1
  var remainingPortalPasses = WorkspaceSceneProjection.portalPasses

  var body: some View {
    ZStack(alignment: .topLeading) {
      coverBackground

      WorkspaceCoverTitle(item: item, geometry: geometry)

      if !aggregates.isEmpty {
        WorkspaceSceneAggregates(aggregates: aggregates, presence: .init(mode: .board,
          camera: .init(center: .init(x: geometry.width / 2, y: geometry.height / 2), scale: 1),
          viewport: .init(x: geometry.width, y: geometry.height)))
      }

      ForEach(elements) { element in
        let reference = EditableElementReference.spatial(elementID: element.id)
        let retainsTextInput = !isPortalProjection
          && element.kind == .nativeText && editingTextID == element.id
        EditableElementContainer(
          isEditingEnabled: isElementEditingEnabled && !model.scenePreparationPending,
          isSelected: !model.scenePreparationPending && model.elementEditingSession.selection == reference,
          coordinateScale: 1,
          translation: model.scenePreparationPending ? .zero : elementTranslation(for: reference),
          isContentInteractive: retainsTextInput || (!model.scenePreparationPending && !element.javaScript.isEmpty),
          onSelect: {
            guard !model.scenePreparationPending else { return }
            model.selectElement(reference)
            onElementSelected()
          },
          onDragChanged: { translation in
            guard !model.scenePreparationPending else { return }
            model.updateElementDrag(reference, translation: translation)
          },
          onDragEnded: { translation in
            guard !model.scenePreparationPending else { return }
            model.finishElementDrag(reference, translation: translation)
          },
          onResizeChanged: {
            guard !model.scenePreparationPending else { return }
            model.updateElementResize(reference, delta: $0)
          },
          onResizeEnded: {
            guard !model.scenePreparationPending else { return }
            model.finishElementResize(reference, delta: $0)
          },
          resizeDelta: model.scenePreparationPending ? .zero : model.elementResizeDelta(reference),
          onDelete: {
            guard !model.scenePreparationPending else { return }
            model.deleteElement(reference)
          }
        ) {
          SpatialElementContent(
            element: element, commitsState: !isPortalProjection,
            boardID: model.sceneIndex?.ownerBoard(itemID: item.id),
            isTextEditing: retainsTextInput,
            onTextEditingEnded: { onTextEditingEnded(element.id) }
          )
        }
        .disabled(model.scenePreparationPending && !retainsTextInput)
        .allowsHitTesting(!model.scenePreparationPending || retainsTextInput)
        .frame(width: element.frame.width, height: element.frame.height)
        .offset(x: element.frame.x, y: element.frame.y)
        .opacity(portalOverlayOpacity)
      }

      #if os(iOS)
        if !isElementEditingEnabled && !isPortalProjection {
          NotebookInteractionView(
            permitsManipulation: !model.scenePreparationPending,
            passthroughFrames: interactionPassthroughFrames,
            onTap: { location, count in
              // Finishing a text session does not need the next geometry index.
              // Keep this input owner mounted while the saved text is prepared.
              if model.scenePreparationPending {
                if let editingTextID { onTextEditingEnded(editingTextID) }
                return
              }
              onTap(location, count)
            },
            onLiftChanged: { lifted in
              guard !lifted || !model.scenePreparationPending else { return }
              onLiftChanged(lifted)
            },
            onTranslationChanged: { translation in
              guard !model.scenePreparationPending else { return }
              onTranslationChanged(translation)
            },
            onTranslationEnded: { translation in
              onTranslationEnded(model.scenePreparationPending ? .zero : translation)
            }
          )
          .frame(
            width: geometry.width,
            height: geometry.height
          )
          .accessibilityHidden(true)
        }
      #endif

      #if os(iOS)
        SpatialInkSurfaceView(
          surface: .cover(item.id),
          journal: model.spatialInk,
          registry: spatialInkSurfaces
        )
        .allowsHitTesting(false)
        .opacity(portalOverlayOpacity)
      #elseif os(macOS)
        SpatialInkSurfaceView(surface: .cover(item.id), journal: model.spatialInk)
          .allowsHitTesting(false).opacity(portalOverlayOpacity)
      #endif
    }
    .frame(
      width: geometry.width,
      height: geometry.height
    )
    .clipShape(
      RoundedRectangle(
        cornerRadius: portalCornerRadius,
        style: .continuous
      )
    )
    .background {
      if showsDepth { WorkspaceItemDepthView(kind: item.kind, geometry: geometry) }
    }
    .contentShape(
      RoundedRectangle(
        cornerRadius: geometry.cornerRadius,
        style: .continuous
      )
    )
    .onChange(of: model.scenePreparationPending) { _, pending in
      guard pending, !isPortalProjection,
        let selection = model.elementEditingSession.selection,
        case .spatial(let selectedID) = selection,
        elements.contains(where: { $0.id == selectedID })
      else { return }
      // A removed frame handle must not revive its unfinished translation when
      // the next scene arrives. The native text session has a separate owner.
      model.updateElementDrag(.spatial(elementID: selectedID), translation: .zero)
    }
  }

  private var portalOverlayOpacity: Double {
    item.kind == .board ? max(0, 1 - portalOpenProgress) : 1
  }

  private var portalCornerRadius: Double {
    item.kind == .board
      ? geometry.cornerRadius * max(0, 1 - portalOpenProgress)
      : geometry.cornerRadius
  }

  private func elementTranslation(
    for reference: EditableElementReference
  ) -> SpatialPoint {
    guard model.elementEditingSession.selection == reference else {
      return .zero
    }
    return model.elementEditingSession.translation
  }

  @ViewBuilder
  private var coverBackground: some View {
    if item.kind == .board {
      if WorkspaceSceneProjection.showsPortal(
        pixelScale: portalPixelScale, remainingPasses: remainingPortalPasses
      ) {
        AnyView(BoardPortalPreview(
          boardID: item.id,
          pixelScale: portalPixelScale,
          remainingPortalPasses: remainingPortalPasses,
          transitionViewport: portalViewport
        ))
      } else {
        Color(red: 0.9, green: 0.93, blue: 0.925)
      }
      RoundedRectangle(
        cornerRadius: portalCornerRadius,
        style: .continuous
      )
      .stroke(
        Color.black.opacity(0.16 * max(0, 1 - portalOpenProgress)),
        lineWidth: 2
      )
    } else {
      WorkspaceCoverSurface(item: item, geometry: geometry)
    }
  }

  private var interactionPassthroughFrames: [CGRect] {
    Self.interactionPassthroughFrames(
      elements: elements,
      editingTextID: isPortalProjection ? nil : editingTextID,
      scenePreparationPending: model.scenePreparationPending
    )
  }

  static func interactionPassthroughFrames(
    elements: [SpatialElement],
    editingTextID: String?,
    scenePreparationPending: Bool
  ) -> [CGRect] {
    elements.compactMap { element in
      let isLiveEditor = element.kind == .nativeText && editingTextID == element.id
      guard isLiveEditor || (!scenePreparationPending && element.kind != .nativeText) else {
        return nil
      }
      return CGRect(
        x: element.frame.x,
        y: element.frame.y,
        width: element.frame.width,
        height: element.frame.height
      )
    }
  }
}

struct SpatialElementContent: View {
  @Environment(NotebookAppModel.self) private var model
  let element: SpatialElement
  let commitsState: Bool
  let boardID: UUID?
  let isTextEditing: Bool
  let onTextEditingEnded: () -> Void

  init(
    element: SpatialElement,
    commitsState: Bool = true,
    boardID: UUID? = nil,
    isTextEditing: Bool = false,
    onTextEditingEnded: @escaping () -> Void = {}
  ) {
    self.element = element
    self.commitsState = commitsState
    self.boardID = boardID
    self.isTextEditing = isTextEditing
    self.onTextEditingEnded = onTextEditingEnded
  }

  var body: some View {
    switch element.kind {
    case .nativeText:
      NativeTextElementView(
        element: element,
        boardID: sourceBoardID,
        isEditing: isTextEditing && commitsState && sourceBoardID != nil,
        onEditingEnded: onTextEditingEnded
      )
    case .markdown, .web:
      let sourceBoardID = self.sourceBoardID
      PreparedAgentElementView(element: agentElement,
        allowsInteraction: commitsState && sourceBoardID != nil,
        focus: .board(boardID: sourceBoardID ?? WorkspaceRoot.boardID, elementID: element.id), onRenderReady: { _ in },
        onState: { state in
          guard commitsState, let sourceBoardID else { return }
          model.commitSpatialElementState(boardID: sourceBoardID, rendered: element, state: state)
        })
    }
  }

  private var agentElement: AgentElement {
    agentElementSnapshotSource(element)
  }

  private var sourceBoardID: UUID? {
    boardID ?? (element.surface.kind == .cover
      ? element.surface.ownerID.flatMap { model.sceneIndex?.ownerBoard(itemID: $0) }
      : element.surface.ownerID)
  }

}

func agentElementSnapshotSource(_ element: SpatialElement) -> AgentElement {
  AgentElement(
    id: element.id,
    kind: element.kind == .markdown ? .markdown : .web,
    frame: PageRect(
      x: 0,
      y: 0,
      width: element.frame.width,
      height: element.frame.height
    ),
    source: element.source,
    html: element.html,
    css: element.css,
    javaScript: element.javaScript,
    state: element.state
  )
}

struct SpatialTextSnapshot: View {
  let element: SpatialElement

  var body: some View {
    Text(element.source)
      .font(.system(size: element.textStyle.fontSize, weight: fontWeight(element.textStyle.weight)))
      .foregroundStyle(Color(red: element.textStyle.red, green: element.textStyle.green,
        blue: element.textStyle.blue, opacity: element.textStyle.alpha))
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func fontWeight(_ value: Double) -> Font.Weight {
    switch value {
    case ..<0.2: .light
    case ..<0.4: .regular
    case ..<0.6: .medium
    case ..<0.8: .semibold
    default: .bold
    }
  }
}

private struct NativeTextElementView: View {
  @Environment(NotebookAppModel.self) private var model
  @FocusState private var focused: Bool
  @State private var text: String
  @State private var commitTask: Task<Void, Never>?
  @State private var focusTask: Task<Void, Never>?
  @State private var hasFinishedEditing = false
  @State private var hasOwnedEditing = false

  let element: SpatialElement
  let boardID: UUID?
  let isEditing: Bool
  let onEditingEnded: () -> Void

  init(
    element: SpatialElement,
    boardID: UUID?,
    isEditing: Bool,
    onEditingEnded: @escaping () -> Void
  ) {
    self.element = element
    self.boardID = boardID
    self.isEditing = isEditing
    self.onEditingEnded = onEditingEnded
    _text = State(initialValue: element.source)
  }

  var body: some View {
    TextEditor(text: $text)
      .scrollContentBackground(.hidden)
      .background(.clear)
      .font(
        .system(
          size: element.textStyle.fontSize,
          weight: fontWeight(element.textStyle.weight)
        )
      )
      .foregroundStyle(
        Color(
          red: element.textStyle.red,
          green: element.textStyle.green,
          blue: element.textStyle.blue,
          opacity: element.textStyle.alpha
        )
      )
      .focused($focused)
      .allowsHitTesting(isEditing)
      .accessibilityHidden(!isEditing)
      .accessibilityIdentifier("native-text-editor")
      .onAppear {
        synchronizeEditingState()
      }
      .onChange(of: element.source) { _, source in
        if !focused { text = source }
      }
      .onChange(of: text) { _, _ in
        if isEditing { scheduleCommit() }
      }
      .onChange(of: isEditing) { _, _ in
        synchronizeEditingState()
      }
      .onChange(of: focused) { _, isFocused in
        if !isFocused, isEditing { finishEditing() }
      }
      .onDisappear {
        focusTask?.cancel()
        focusTask = nil
        if isEditing { finishEditing() }
      }
  }

  private func synchronizeEditingState() {
    focusTask?.cancel()
    focusTask = nil
    if isEditing {
      hasOwnedEditing = true
      hasFinishedEditing = false
      focusTask = Task { @MainActor in
        await Task.yield()
        guard !Task.isCancelled else { return }
        focused = true
      }
    } else {
      if focused { focused = false }
      if hasOwnedEditing { finishEditing() }
    }
  }

  private func scheduleCommit() {
    commitTask?.cancel()
    commitTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(180))
      guard !Task.isCancelled else { return }
      commit()
    }
  }

  private func commit() {
    commitTask?.cancel()
    commitTask = nil
    guard text != element.source, let boardID else { return }
    model.updateNativeText(boardID: boardID, elementID: element.id, text: text)
  }

  private func finishEditing() {
    guard !hasFinishedEditing else { return }
    hasFinishedEditing = true
    commitTask?.cancel()
    commitTask = nil
    if let boardID { model.finishNativeTextEditing(boardID: boardID, elementID: element.id, text: text) }
    onEditingEnded()
  }

  private func fontWeight(_ value: Double) -> Font.Weight {
    switch value {
    case ..<0.2: .light
    case ..<0.4: .regular
    case ..<0.6: .medium
    case ..<0.8: .semibold
    default: .bold
    }
  }
}

struct SpatialBoardGrid: View {
  @Environment(\.displayScale) private var displayScale
  let camera: SpatialCamera
  var outputScale: Double = 1

  var body: some View {
    Canvas(opaque: true, colorMode: .nonLinear) { context, size in
      context.fill(
        Path(CGRect(origin: .zero, size: size)),
        with: .color(BoardAppearance.background)
      )

      var worldStep = PhysicalPaper.gridSpacing
      while worldStep * camera.scale * outputScale < BoardAppearance.minimumDotSpacing {
        worldStep *= 2
      }
      let step = worldStep * camera.scale
      let phaseX =
        camera.center.localX
        .truncatingRemainder(dividingBy: worldStep) * camera.scale
      let phaseY =
        camera.center.localY
        .truncatingRemainder(dividingBy: worldStep) * camera.scale
      let startX = (size.width / 2 - phaseX)
        .truncatingRemainder(dividingBy: step)
      let startY = (size.height / 2 - phaseY)
        .truncatingRemainder(dividingBy: step)
      let radius = max(0.65, 0.9 / displayScale) / outputScale
      var dots = Path()
      var x = startX < 0 ? startX + step : startX
      while x <= size.width {
        var y = startY < 0 ? startY + step : startY
        while y <= size.height {
          dots.addEllipse(
            in: CGRect(
              x: x - radius,
              y: y - radius,
              width: radius * 2,
              height: radius * 2
            )
          )
          y += step
        }
        x += step
      }
      context.fill(dots, with: .color(BoardAppearance.dot))
    }
    .ignoresSafeArea()
  }
}

/// An overview represents the whole indexed region, not an invented thumbnail
/// or an exact rendering of sources which have not been mounted.
private struct WorkspaceSceneAggregates: View {
  let aggregates: [WorkspaceSpatialAggregate]
  let presence: SessionPresence

  var body: some View {
    let viewportBounds = WorkspaceSpatialBounds(
      origin: presence.camera.screenToWorld(.init(x: -16, y: -16), viewport: presence.viewport),
      width: (presence.viewport.x + 32) / presence.camera.scale,
      height: (presence.viewport.y + 32) / presence.camera.scale)
    ForEach(aggregates) { aggregate in
      if let visible = aggregate.bounds.intersection(viewportBounds), visible.width > 0, visible.height > 0 {
        let topLeft = presence.camera.worldToScreen(visible.origin, viewport: presence.viewport)
        let left = topLeft.x, top = topLeft.y
        let right = left + visible.width * presence.camera.scale
        let bottom = top + visible.height * presence.camera.scale
        RoundedRectangle(cornerRadius: 5)
          .fill(Color.accentColor.opacity(0.08))
          .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor.opacity(0.4), style: .init(lineWidth: 1, dash: [3, 3])) }
          .overlay {
            if right - left > 52 && bottom - top > 24 {
              Text("Область · \(aggregate.count)")
                .font(.system(size: 11, weight: .medium))
                .padding(5)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                .lineLimit(1)
            }
          }
          .frame(width: max(2, right - left), height: max(2, bottom - top))
          .position(x: (left + right) / 2, y: (top + bottom) / 2)
          .accessibilityLabel("Область: \(aggregate.count) предметов. Приблизьте для подробностей.")
          .accessibilityIdentifier("workspace-aggregate-\(aggregate.id)")
          .allowsHitTesting(false)
      }
    }
  }
}

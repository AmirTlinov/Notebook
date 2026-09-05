import NotebookCore
import PencilKit
import SwiftUI

#if os(iOS)
  import UIKit
#elseif os(macOS)
  import AppKit
#endif

private struct CameraGestureSnapshot {
  struct BoardEngagement {
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
  var boardEngagement: BoardEngagement?
  var dockingCorrection: NotebookDockingCorrection
  var openingWasVisible: Bool
}

struct RenderedWorkspaceItem: Identifiable {
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

  /// The snapshot publisher walks the same finite portal projection as the view.
  /// Every visible web layer must have its exact source/state raster ready.
  static func snapshotElements(
    workspace: WorkspaceIndex, hierarchy: BoardHierarchy, presence: SessionPresence,
    documents: [UUID: DocumentDocument]
  ) -> [SpatialElement] {
    guard let board = hierarchy.board(presence.boardID) else { return [] }
    var result = board.elements
    var pending = items(workspace: workspace, board: board, presence: presence, documents: documents)
      .filter { $0.item.kind == .board }
      .map { ($0.id, 1.0, portalPasses) }
    while let (id, pixelScale, passes) = pending.popLast() {
      guard showsPortal(pixelScale: pixelScale, remainingPasses: passes),
        let child = hierarchy.board(id), let portal = hierarchy.portalCamera(id)
      else { continue }
      result.append(contentsOf: child.elements)
      let camera = BoardPortalProjection.entryCamera(
        portalCamera: portal, viewport: presence.viewport
      )
      let childPresence = SessionPresence(boardID: id, mode: .board,
        camera: camera,
        viewport: BoardPortalProjection.renderViewport(viewport: presence.viewport))
      let childScale = pixelScale * camera.scale
        / BoardPortalProjection.fillScale(viewport: presence.viewport)
      pending.append(contentsOf: items(workspace: workspace, board: child, presence: childPresence, documents: documents)
        .filter { $0.item.kind == .board }.map { ($0.id, childScale, passes - 1) })
    }
    return result
  }

  static func items(
    workspace: WorkspaceIndex,
    board: BoardDocument,
    presence: SessionPresence,
    documents: [UUID: DocumentDocument]
  ) -> [RenderedWorkspaceItem] {
    let items = Dictionary(
      uniqueKeysWithValues: workspace.items.map { ($0.id, $0) }
    )
    func geometry(of item: WorkspaceItem) -> WorkspaceItemGeometry? {
      guard item.kind == .document else { return .notebook }
      return documents[item.id].map { .document($0.paperSize) }
    }
    var result: [RenderedWorkspaceItem] = board.freeItems.compactMap { placement in
      guard let item = items[placement.itemID], let geometry = geometry(of: item) else { return nil }
      return RenderedWorkspaceItem(
          item: item,
          geometry: geometry,
          center: placement.center,
          zIndex: Double(placement.zIndex),
          stackID: nil
        )
    }

    for stack in board.stacks {
      let focusedMemberID = presence.mode == .board
        ? nil
        : presence.focusedItemID.flatMap { itemID in
          stack.itemIDs.contains(itemID) ? itemID : nil
        }
      for (index, itemID) in stack.itemIDs.enumerated() {
        guard focusedMemberID == nil || focusedMemberID == itemID,
          let item = items[itemID],
          let geometry = geometry(of: item),
          let center = WorkspaceItemStackPresentation.boardCenter(
            of: itemID,
            in: stack,
            cameraScale: presence.camera.scale,
            viewport: presence.viewport
          )
        else { continue }
        result.append(
          RenderedWorkspaceItem(
            item: item,
            geometry: geometry,
            center: center,
            zIndex: Double(stack.zIndex) + Double(index) / 100,
            stackID: stack.id
          )
        )
      }
    }
    return result.sorted { $0.zIndex < $1.zIndex }
  }
}

#if os(macOS)
  /// A settled read model. It contains no gesture surface, cover transition,
  /// page-turn controller, Metal drawable, or live WebKit view.
  struct SettledSpatialWorkspaceView: View {
    @Environment(NotebookAppModel.self) private var model

    let workspace: WorkspaceIndex
    let board: BoardDocument
    let spatialInk: SpatialInkJournal
    let presence: SessionPresence

    var body: some View {
      let rendered = WorkspaceSceneProjection.items(
        workspace: workspace,
        board: board,
        presence: presence,
        documents: model.documents
      )
      ZStack {
        SpatialBoardGrid(camera: presence.camera)
        settledBoardElements
        SpatialInkSurfaceView(
          surface: .board(presence.boardID), journal: spatialInk, camera: presence.camera, viewport: presence.viewport
        )
        .frame(width: presence.viewport.x, height: presence.viewport.y)
        .allowsHitTesting(false)

        ForEach(rendered) { rendered in
          let screen = presence.camera.worldToScreen(
            rendered.center,
            viewport: presence.viewport
          )
          WorkspaceItemCoverView(
            item: rendered.item,
            geometry: rendered.geometry,
            spatialInkSurfaces: SpatialInkSurfaceRegistry(),
            elements: board.elements.filter {
              $0.surface == .cover(rendered.id)
            },
            editingTextID: nil,
            isElementEditingEnabled: false,
            rendersSettledSnapshot: true,
            portalOpenProgress: 0,
            portalViewport: presence.viewport,
            onTap: { _, _ in },
            onLiftChanged: { _ in },
            onTranslationChanged: { _ in },
            onTranslationEnded: { _ in },
            onTextEditingEnded: { _ in },
            onElementSelected: {}
          )
          .background { WorkspaceItemShadow(geometry: rendered.geometry) }
          .scaleEffect(presence.camera.scale)
          .position(x: screen.x, y: screen.y)
          .zIndex(rendered.zIndex)
        }
      }
      .frame(width: presence.viewport.x, height: presence.viewport.y)
      .clipped()
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }

    @ViewBuilder
    private var settledBoardElements: some View {
      ForEach(board.elements.filter { $0.surface.kind == .board }) { element in
        if let worldOrigin = element.worldOrigin {
          let base = presence.camera.worldToScreen(
            worldOrigin,
            viewport: presence.viewport
          )
          let origin = CGPoint(
            x: base.x + element.frame.x * presence.camera.scale,
            y: base.y + element.frame.y * presence.camera.scale
          )
          SettledSpatialElementContent(element: element)
            .frame(width: element.frame.width, height: element.frame.height)
            .scaleEffect(presence.camera.scale)
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
  }
#endif

struct SpatialWorkspaceView: View {
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
  @State private var settlementTask: Task<Void, Never>?
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
      let rendered = renderedItems(presence: presence)

      ZStack {
        SpatialBoardGrid(camera: presence.camera)

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

        boardElements(presence: presence, viewport: viewport)
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
              && !contentGestureActive
              && editingSpatialTextID == nil
              && !model.isElementEditingEnabled && !model.isPointing
          )
          .allowsHitTesting(false)
        #endif

        ForEach(rendered) { rendered in
          WorkspaceSceneItem(
            rendered: rendered,
            document: model.documents[rendered.id],
            documentState: model.documentStates[rendered.id],
            documentPageIndex: presence.focusedItemID == rendered.id
              ? presence.documentPageIndex
              : 0,
            documentPageCount: documentPageLayouts[rendered.id]?.pageCount ?? 1,
            camera: presence.camera,
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
              dropItem(itemID, at: center, presence: presence)
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
              editingSpatialTextID = nil
              selectedItemID = nil
              openItem(itemID, viewport: viewport)
            },
            onEditText: { itemID, point in
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
          .zIndex(liftedItemID == rendered.id ? 9_000 : rendered.zIndex)
        }

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
              guard cameraGesture == nil, !settling else { return }
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
            model.confirmVisibleActions(presence:presence)
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
        while cameraGesture != nil || settling || pageTurnIsActive || contentGestureActive || model.presencePhase != .settled {
          do { try await Task.sleep(for:.milliseconds(40)) } catch { return }
        }
        model.afterPageInput {
          showReference(reference,viewport:viewport)
        }
      }
      .task(id: model.requestedReturn?.id) {
        guard let place = model.requestedReturn else { return }
        while cameraGesture != nil || settling || pageTurnIsActive || contentGestureActive || model.presencePhase != .settled {
          do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
        }
        model.afterPageInput {
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
      .onChange(of: geometry.size) { _, _ in
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
        model.clearElementSelection()
        if itemID == nil { editingSpatialTextID = nil }
        pageTurnIsActive = false
      }
      .onDisappear {
        settlementTask?.cancel()
        settlementTask = nil
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
      let rendered = renderedItems(presence: presence).first(where: {
        $0.id == selectedItemID
      })
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

  @ViewBuilder
  private func boardElements(
    presence: SessionPresence,
    viewport: SpatialPoint
  ) -> some View {
    if let board = model.board {
      ForEach(board.elements.filter {
        $0.surface == .board(presence.boardID)
      }) { element in
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
            isEditingEnabled: model.isElementEditingEnabled,
            isSelected: model.elementEditingSession.selection == reference,
            coordinateScale: presence.camera.scale,
            translation: elementTranslation(for: reference),
            isContentInteractive: !element.javaScript.isEmpty,
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
            SpatialElementContent(element: element)
          }
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
      let elementID = model.addNativeText(on: itemID, at: point)
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

  private func renderedItems(
    presence: SessionPresence
  ) -> [RenderedWorkspaceItem] {
    guard let board = model.board, let workspace = model.workspace else {
      return []
    }
    return WorkspaceSceneProjection.items(
      workspace: workspace,
      board: board,
      presence: presence,
      documents: model.documents
    )
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
      if candidate == nil {
        dockingStartStrength = 0
      } else {
        dockingStartStrength = NotebookDockingField.strength(
          camera: presence.camera,
          viewport: presence.viewport,
          geometry: model.itemGeometry(candidate)
        )
      }
      let boardEngagement = focusedItemID.map {
        let coverScale = model.itemGeometry($0).coverScale(viewport: presence.viewport)
        let targetScale = transitionScale(
          for: $0,
          viewport: presence.viewport
        )
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
        return CameraGestureSnapshot.BoardEngagement(
          itemID: $0,
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
        boardEngagement: boardEngagement,
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
    let geometry = model.itemGeometry(snapshot.boardEngagement?.itemID ?? snapshot.candidateItemID)
    let pageScale = geometry.fitScale(viewport: viewport)
    let coverScale = geometry.coverScale(viewport: viewport)
    let directionThreshold: CGFloat = 0.000_5
    let directionDelta = scale - snapshot.lastMagnification
    if abs(directionDelta) > directionThreshold {
      snapshot.isApproaching = directionDelta > 0
    }

    let engagedItemID = snapshot.boardEngagement?.itemID
    let engagementScale = engagedItemID.map {
      transitionScale(for: $0, viewport: viewport)
    } ?? pageScale
    let maximumScale = snapshot.boardEngagement == nil
      ? SpatialCamera.maximumScale
      : engagementScale
    let rawCamera = snapshot.trajectory.camera(
      at: scale,
      centroid: centroid,
      maximumScale: maximumScale
    )
    var camera = rawCamera

    if let boardEngagement = snapshot.boardEngagement {
      if NotebookOpeningIntent.shouldDisengage(
        cameraScale: rawCamera.scale,
        coverScale: coverScale
      ) {
        snapshot.boardEngagement = nil
        snapshot.dockingCorrection = .zero
      } else {
        snapshot.candidateItemID = boardEngagement.itemID
      }
    }

    if snapshot.boardEngagement == nil {
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
        if nextCandidate == nil {
          snapshot.dockingStartStrength = 0
        } else {
          snapshot.dockingStartStrength = NotebookDockingField.strength(
            camera: camera,
            viewport: viewport,
            geometry: model.itemGeometry(nextCandidate)
          )
        }
      }
    }

    let attractionTarget =
      snapshot.boardEngagement?.itemID
      ?? snapshot.candidateItemID
    let dockingStrength = NotebookDockingField.strength(
      camera: rawCamera,
      viewport: viewport,
      geometry: model.itemGeometry(attractionTarget)
    )
    if let attractionTarget,
      let center = model.board?.focusedCenter(of: attractionTarget)
    {
      let correction: NotebookDockingCorrection
      if let engagement = snapshot.boardEngagement,
        rawCamera.scale >= engagement.rawOpeningScale
      {
        let rawOpeningProgress = NotebookOpeningTransition.progress(
          cameraScale: rawCamera.scale,
          openingScale: engagement.rawOpeningScale,
          pageScale: transitionScale(
            for: engagement.itemID,
            viewport: viewport
          )
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

    if snapshot.boardEngagement == nil,
      let candidate = snapshot.candidateItemID,
      NotebookOpeningIntent.shouldEngage(
        isApproaching: snapshot.isApproaching,
        cameraScale: camera.scale,
        coverScale: model.itemGeometry(candidate).coverScale(viewport: viewport)
      )
    {
      snapshot.boardEngagement = CameraGestureSnapshot.BoardEngagement(
        itemID: candidate,
        openingScale: camera.scale,
        rawOpeningScale: rawCamera.scale,
        dockingEntryProgress: 0,
        dockingEntryCorrection: snapshot.dockingCorrection
      )
    }

    let engagement = snapshot.boardEngagement
    let candidate = engagement?.itemID
    let open: Double
    if let engagement {
      open = NotebookOpeningTransition.progress(
        cameraScale: camera.scale,
        openingScale: engagement.openingScale,
        pageScale: transitionScale(
          for: engagement.itemID,
          viewport: viewport
        )
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
    if let engagement = snapshot.boardEngagement,
      let itemID = presence.focusedItemID,
      engagement.itemID == itemID,
      NotebookDockingField.shouldDock(
        openProgress: presence.openProgress,
        isApproaching: snapshot.isApproaching,
        releaseVelocity: Double(velocity)
      ),
      let center = model.board?.focusedCenter(of: itemID)
    {
      if itemKind(itemID) == .board {
        enterBoard(
          itemID,
          center: center,
          viewport: viewport,
          duration: NotebookDockingField.settlementDuration(
            openProgress: presence.openProgress,
            releaseVelocity: Double(velocity)
          )
        )
        return
      }
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
    } else if shouldExitBoard(
      snapshot: snapshot,
      presence: presence,
      velocity: velocity
    ) {
      leaveBoard(viewport: viewport)
    } else {
      contentGestureActive = false
      model.updatePresence(presence, settled: true)
    }
  }

  private func cancelMagnification() {
    guard let snapshot = cameraGesture else { return }
    cameraGesture = nil
    animateSettlement(to: snapshot.presence, duration: 0.26)
  }

  private func interruptSettlementForInput() {
    settlementTask?.cancel()
    settlementTask = nil
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
    renderedItems(presence: presence)
      .reversed()
      .compactMap { rendered -> (UUID, Double)? in
        let strength = selectionStrength(
          for: rendered.id,
          at: centroid,
          presence: presence
        )
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
      let rendered = renderedItems(presence: presence)
        .first(where: { $0.id == itemID })
    else { return 0 }
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
        Task {
          let deadline = ContinuousClock.now + .seconds(8)
          while ContinuousClock.now < deadline {
            try? await Task.sleep(for:.milliseconds(60))
            guard model.presence?.focusedItemID == itemID else { return }
            if let document = model.documents[itemID], let state = model.documentStates[itemID],
              let region = DocumentRenderRegistry.shared.regions(document:document,state:state).first(where: { $0.id == blockID }), !settling {
              _ = model.selectDocumentPage(region.pageIndex,documentID:itemID)
              return
            }
          }
        }
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
      model.presence != nil,
      let center = model.board?.focusedCenter(of: itemID)
    else { return }
    if model.workspace?.items.first(where: { $0.id == itemID })?.kind == .board {
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
    settlementTask?.cancel()
    settling = true
    model.selectItem(itemID)
    withAnimation(.easeIn(duration: duration)) {
      model.updatePresence(
        SessionPresence(
          boardID: presence.boardID,
          mode: .cover,
          camera: BoardPortalProjection.parentBoundaryCamera(
            portalCenter: center,
            viewport: viewport
          ),
          viewport: viewport,
          focusedItemID: itemID,
          openProgress: 1
        ),
        settled: true
      )
    }
    settlementTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(duration + 0.01))
      guard !Task.isCancelled else { return }
      model.enterBoard(itemID)
      contentGestureActive = false
      settling = false
      settlementTask = nil
    }
  }

  private func leaveBoard(viewport: SpatialPoint) {
    settlementTask?.cancel()
    guard model.leaveBoard(), let boundary = model.presence else { return }
    settling = true
    settlementTask = Task { @MainActor in
      await Task.yield()
      guard !Task.isCancelled else { return }
      let target = SessionPresence(
        boardID: boundary.boardID,
        mode: .board,
        camera: SpatialCamera(
          center: boundary.camera.center,
          scale: WorkspaceItemGeometry.notebook.coverScale(viewport: viewport)
        ),
        viewport: viewport
      )
      withAnimation(.spring(duration: 0.34, bounce: 0.025)) {
        model.updatePresence(target, settled: true)
      }
      try? await Task.sleep(for: .milliseconds(360))
      guard !Task.isCancelled else { return }
      contentGestureActive = false
      settling = false
      settlementTask = nil
    }
  }

  private func shouldExitBoard(
    snapshot: CameraGestureSnapshot,
    presence: SessionPresence,
    velocity: CGFloat
  ) -> Bool {
    snapshot.presence.mode == .board
      && snapshot.presence.boardID != model.workspace?.rootBoardID
      && snapshot.boardEngagement == nil
      && snapshot.candidateItemID == nil
      && snapshot.lastMagnification <= 0.78
      && !snapshot.isApproaching
      && velocity <= 0
      && presence.mode == .board
  }

  private func itemKind(_ itemID: UUID) -> WorkspaceItemKind? {
    model.workspace?.items.first(where: { $0.id == itemID })?.kind
  }

  private func transitionScale(
    for itemID: UUID,
    viewport: SpatialPoint
  ) -> Double {
    itemKind(itemID) == .board
      ? BoardPortalProjection.fillScale(viewport: viewport)
      : model.itemGeometry(itemID).fitScale(viewport: viewport)
  }

  private func animateSettlement(
    to target: SessionPresence,
    duration: TimeInterval,
    bounce: Double = 0.08
  ) {
    settlementTask?.cancel()
    settling = true
    withAnimation(.spring(duration: duration, bounce: bounce)) {
      model.updatePresence(target, settled: true)
    }
    settlementTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(duration + 0.02))
      guard !Task.isCancelled else { return }
      contentGestureActive = false
      settling = false
      settlementTask = nil
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
    switch model.workspace?.items.first(where: { $0.id == itemID })?.kind {
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
      model.workspace?.items.first(where: { $0.id == itemID })?.kind == .document,
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
      let moving = renderedItems(presence: presence)
        .first(where: { $0.id == itemID })
    else { return }
    let target = renderedItems(presence: presence)
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

private struct WorkspaceSceneItem: View {
  @Environment(NotebookAppModel.self) private var model

  let rendered: RenderedWorkspaceItem
  let document: DocumentDocument?
  let documentState: DocumentStateJournal?
  let documentPageIndex: Int
  let documentPageCount: Int
  let camera: SpatialCamera
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
  @State private var liftStarted = false

  var body: some View {
    let screen = camera.worldToScreen(rendered.center, viewport: viewport)
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
          lineWidth: 2 / max(scale, 0.0125)
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
    if preparesContent, !rendered.item.pageIDs.isEmpty {
      PageTurnSurface(
        ownerID: rendered.id,
        pageCount: rendered.item.pageIDs.count + 1,
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

  private var notebookSelectedPageIndex: Int {
    guard let selectedPageID = model.workspace?.selectedPageID,
      let index = rendered.item.pageIDs.firstIndex(of: selectedPageID)
    else { return 0 }
    return index
  }

  private var notebookFallbackSize: PageSize {
    guard let firstID = rendered.item.pageIDs.first,
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
      index < rendered.item.pageIDs.count,
      let page = model.pages[rendered.item.pageIDs[index]]
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
      editingTextID: editingTextID,
      isElementEditingEnabled: model.isElementEditingEnabled,
      rendersSettledSnapshot: false,
      portalOpenProgress: openProgress,
      portalViewport: viewport,
      onTap: handleTap,
      onLiftChanged: { lifted in
        if lifted { beginLift() } else { endLift() }
      },
      onTranslationChanged: { translation in
        dragTranslation = translation
      },
      onTranslationEnded: { translation in
        finishMove(translation: translation, scale: camera.scale)
      },
      onTextEditingEnded: onTextEditingEnded,
      onElementSelected: onElementSelected,
      showsDepth: false
    )
  }

  private var coverElements: [SpatialElement] {
    model.board?.elements.filter {
      $0.surface == .cover(rendered.id)
    } ?? []
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
    guard hypot(translation.width, translation.height) >= 2 else { return }
    let center = rendered.center.offsetBy(
      x: translation.width / max(scale, 0.001),
      y: translation.height / max(scale, 0.001)
    )
    onDrop(rendered.id, center)
  }

  private func beginLift() {
    guard !liftStarted else { return }
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

  let boardID: UUID
  let pixelScale: Double
  let remainingPortalPasses: Int
  let transitionViewport: SpatialPoint
  var rendersSettledSnapshot = false

  var body: some View {
    if let workspace = model.workspace,
      let hierarchy = model.boardHierarchy,
      let board = hierarchy.board(boardID)
    {
      let camera = BoardPortalProjection.entryCamera(
        portalCamera: hierarchy.portalCamera(boardID) ?? BoardPortalCamera(),
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
      let rendered = WorkspaceSceneProjection.items(
        workspace: workspace,
        board: board,
        presence: presence,
        documents: model.documents
      )

      ZStack {
        SpatialBoardGrid(camera: camera)

        ForEach(board.elements.filter { $0.surface == .board(boardID) }) {
          element in
          if let origin = element.worldOrigin {
            let screen = camera.worldToScreen(origin, viewport: viewport)
            Group {
              #if os(macOS)
                if rendersSettledSnapshot {
                  SettledSpatialElementContent(element: element)
                } else {
                  SpatialElementContent(element: element, commitsState: false)
                }
              #else
                SpatialElementContent(element: element, commitsState: false)
              #endif
            }
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

        ForEach(rendered) { item in
          let screen = camera.worldToScreen(item.center, viewport: viewport)
          WorkspaceItemCoverView(
            item: item.item,
            geometry: item.geometry,
            spatialInkSurfaces: SpatialInkSurfaceRegistry(),
            elements: board.elements.filter { $0.surface == .cover(item.id) },
            editingTextID: nil, isElementEditingEnabled: false,
            rendersSettledSnapshot: rendersSettledSnapshot,
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

struct WorkspaceItemCoverView: View {
  @Environment(NotebookAppModel.self) private var model

  let item: WorkspaceItem
  let geometry: WorkspaceItemGeometry
  let spatialInkSurfaces: SpatialInkSurfaceRegistry
  let elements: [SpatialElement]
  let editingTextID: String?
  let isElementEditingEnabled: Bool
  let rendersSettledSnapshot: Bool
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

      if item.kind != .board, !item.title.isEmpty {
        Text(item.title)
          .font(
            .system(
              size: geometry.width * (item.kind == .document ? 0.056 : 0.048),
              weight: .medium,
              design: item.kind == .document ? .serif : .default
            )
          )
          .foregroundStyle(Color.black.opacity(0.76))
          .lineLimit(3)
          .frame(width: geometry.width * 0.72, alignment: .leading)
          .offset(
            x: geometry.width * (item.kind == .document ? 0.105 : 0.145),
            y: geometry.height * (item.kind == .document ? 0.145 : 0.148)
          )
      }

      ForEach(elements) { element in
        let reference = EditableElementReference.spatial(elementID: element.id)
        EditableElementContainer(
          isEditingEnabled: isElementEditingEnabled,
          isSelected: model.elementEditingSession.selection == reference,
          coordinateScale: 1,
          translation: elementTranslation(for: reference),
            isContentInteractive: !element.javaScript.isEmpty,
          onSelect: {
            model.selectElement(reference)
            onElementSelected()
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
          Group {
            #if os(macOS)
              if rendersSettledSnapshot {
                SettledSpatialElementContent(element: element)
              } else {
                SpatialElementContent(
                  element: element,
                  commitsState: !isPortalProjection,
                  isTextEditing: editingTextID == element.id,
                  onTextEditingEnded: { onTextEditingEnded(element.id) }
                )
              }
            #else
              SpatialElementContent(
                element: element,
                commitsState: !isPortalProjection,
                isTextEditing: editingTextID == element.id,
                onTextEditingEnded: { onTextEditingEnded(element.id) }
              )
            #endif
          }
        }
        .frame(width: element.frame.width, height: element.frame.height)
        .offset(x: element.frame.x, y: element.frame.y)
        .opacity(portalOverlayOpacity)
      }

      #if os(iOS)
        if !isElementEditingEnabled && !isPortalProjection {
          NotebookInteractionView(
            passthroughFrames: interactionPassthroughFrames,
            onTap: onTap,
            onLiftChanged: onLiftChanged,
            onTranslationChanged: onTranslationChanged,
            onTranslationEnded: onTranslationEnded
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
        SpatialInkSurfaceView(
          surface: .cover(item.id), journal: model.spatialInk
        )
        .allowsHitTesting(false)
        .opacity(portalOverlayOpacity)
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
          transitionViewport: portalViewport,
          rendersSettledSnapshot: rendersSettledSnapshot
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
    elements.compactMap { element in
      guard element.kind != .nativeText || editingTextID == element.id else {
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
  @State private var readyElement: AgentElement?
  let element: SpatialElement
  let commitsState: Bool
  let isTextEditing: Bool
  let onTextEditingEnded: () -> Void

  init(
    element: SpatialElement,
    commitsState: Bool = true,
    isTextEditing: Bool = false,
    onTextEditingEnded: @escaping () -> Void = {}
  ) {
    self.element = element
    self.commitsState = commitsState
    self.isTextEditing = isTextEditing
    self.onTextEditingEnded = onTextEditingEnded
  }

  var body: some View {
    switch element.kind {
    case .nativeText:
      NativeTextElementView(
        element: element,
        isEditing: isTextEditing,
        onEditingEnded: onTextEditingEnded
      )
    case .markdown, .web:
      let source = agentElement
      ZStack {
        if readyElement != source, let image = AgentElementSnapshotCache.shared.image(for: source) {
          #if os(iOS)
            Image(uiImage: image).resizable()
          #else
            Image(nsImage: image).resizable()
          #endif
        }
        AgentWebElementView(
          element: source,
          onRenderReady: { ready in
            let next = ready ? source : nil
            if readyElement != next { readyElement = next }
          },
          onState: { state in
            if commitsState { model.commitSpatialElementState(elementID: element.id, state: state) }
          }
        )
        .opacity(readyElement == source ? 1 : 0)
        .allowsHitTesting(readyElement == source && commitsState)
      }
    }
  }

  private var agentElement: AgentElement {
    agentElementSnapshotSource(element)
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

#if os(macOS)
  private struct SettledSpatialElementContent: View {
    let element: SpatialElement

    var body: some View {
      if element.kind == .nativeText {
        Text(element.source)
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
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      } else if let image = AgentElementSnapshotCache.shared.image(
        for: agentElementSnapshotSource(element)
      ) {
        Image(nsImage: image)
          .resizable()
      }
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
#endif

private struct NativeTextElementView: View {
  @Environment(NotebookAppModel.self) private var model
  @FocusState private var focused: Bool
  @State private var text: String
  @State private var commitTask: Task<Void, Never>?
  @State private var focusTask: Task<Void, Never>?
  @State private var hasFinishedEditing = false
  @State private var hasOwnedEditing = false

  let element: SpatialElement
  let isEditing: Bool
  let onEditingEnded: () -> Void

  init(
    element: SpatialElement,
    isEditing: Bool,
    onEditingEnded: @escaping () -> Void
  ) {
    self.element = element
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
    guard text != element.source else { return }
    model.updateNativeText(elementID: element.id, text: text)
  }

  private func finishEditing() {
    guard !hasFinishedEditing else { return }
    hasFinishedEditing = true
    commitTask?.cancel()
    commitTask = nil
    model.finishNativeTextEditing(elementID: element.id, text: text)
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

private struct SpatialBoardGrid: View {
  @Environment(\.displayScale) private var displayScale
  let camera: SpatialCamera

  var body: some View {
    Canvas(opaque: true, colorMode: .nonLinear) { context, size in
      context.fill(
        Path(CGRect(origin: .zero, size: size)),
        with: .color(BoardAppearance.background)
      )

      var worldStep = PhysicalPaper.gridSpacing
      while worldStep * camera.scale < BoardAppearance.minimumDotSpacing {
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
      let radius = max(0.65, 0.9 / displayScale)
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

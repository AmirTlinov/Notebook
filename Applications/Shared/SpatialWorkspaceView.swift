import SwiftUI
import NotebookCore

#if os(iOS)
  import UIKit
#endif

private struct CameraGestureSnapshot {
  struct BoardEngagement {
    let itemID: UUID
    let openingScale: Double
  }

  let presence: SessionPresence
  var baselineCamera: SpatialCamera
  var baselineCentroid: CGPoint
  var baselineMagnification: CGFloat
  var lastMagnification: CGFloat
  var lastCentroid: CGPoint
  var candidateItemID: UUID?
  var isApproaching: Bool
  var boardEngagement: BoardEngagement?
  var dockingStrength: Double
}

struct RenderedWorkspaceItem: Identifiable {
  let item: WorkspaceItem
  let center: WorldPoint
  let zIndex: Double
  let stackID: UUID?

  var id: UUID { item.id }
}

private struct NotebookPageSet {
  let current: PageDocument?
  let previous: PageDocument?
  let next: PageDocument?
}

private enum LocalPageSelection: Equatable {
  case notebook(UUID)
  case document(UUID, Int)
}

struct SpatialWorkspaceView: View {
  @Environment(NotebookAppModel.self) private var model
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var cameraGesture: CameraGestureSnapshot?
  @State private var panStart: SessionPresence?
  @State private var selectedItemID: UUID?
  @State private var liftedItemID: UUID?
  @State private var editingSpatialTextID: String?
  @State private var contentGestureActive = false
  @State private var pageInputGestureID: UUID?
  @State private var bufferedCameraPhases: [WorkspaceMagnificationPhase] = []
  @State private var pageNavigationGestureID: UUID?
  @State private var bufferedPageNavigationPhases: [PageNavigationPhase] = []
  @State private var pageMotion = PageMotionController()
  @State private var pageTransitionID: UUID?
  @State private var transitionItemID: UUID?
  @State private var departingNotebookPage: PageDocument?
  @State private var departingDocumentPageIndex: Int?
  @State private var expectedLocalSelection: LocalPageSelection?
  @State private var documentPageLayouts: [UUID: DocumentPageLayout] = [:]
  @State private var settling = false
  @State private var settlementTask: Task<Void, Never>?
  @State private var spatialInkSurfaces = SpatialInkSurfaceRegistry()

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
              && cameraGesture == nil && !settling,
            excludedFrames: rendered.map { item in
              let center = presence.camera.worldToScreen(
                item.center,
                viewport: viewport
              )
              let width = NotebookGeometry.width * presence.camera.scale
              let height = NotebookGeometry.height * presence.camera.scale
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
              editingSpatialTextID = nil
            },
            onBegan: {
              selectedItemID = nil
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

        #if os(macOS)
          SpatialInkSurfaceView(
            drawing: SpatialInkDrawingComposer.boardDrawing(
              in: model.spatialInk,
              camera: presence.camera,
              viewport: viewport
            )
          )
          .frame(width: viewport.x, height: viewport.y)
          .allowsHitTesting(false)
        #endif

        #if os(iOS)
          SpatialInkCanvas(
            camera: presence.camera,
            viewport: viewport,
            items: rendered.map {
              SpatialWorkspaceItemSurface(
                itemID: $0.id,
                center: $0.center,
                zIndex: $0.zIndex
              )
            },
            journal: model.spatialInk,
            penStyle: model.penStyle,
            eraserStyle: model.eraserStyle,
            drawingTool: model.drawingTool,
            surfaceRegistry: spatialInkSurfaces,
            pencilInputGate: model.pencilInputGate,
            onCommit: model.appendSpatialInk,
            isEnabled: (presence.mode == .board || presence.mode == .cover)
              && !contentGestureActive
              && editingSpatialTextID == nil
          )
          .allowsHitTesting(false)
        #endif

        ForEach(rendered) { rendered in
          let pages = notebookPages(for: rendered.item)
          WorkspaceSceneItem(
            rendered: rendered,
            page: pages.current,
            previousPage: pages.previous,
            nextPage: pages.next,
            document: model.documents[rendered.id],
            documentState: model.documentStates[rendered.id],
            documentPageIndex: presence.focusedItemID == rendered.id
              ? presence.documentPageIndex
              : 0,
            pageMotion: presence.focusedItemID == rendered.id
              && (presence.mode == .page || presence.mode == .document)
              ? pageMotion
              : nil,
            departingPage: transitionItemID == rendered.id
              ? departingNotebookPage
              : nil,
            departingDocumentPageIndex: transitionItemID == rendered.id
              ? departingDocumentPageIndex
              : nil,
            camera: presence.camera,
            viewport: viewport,
            isFocused: presence.focusedItemID == rendered.id,
            preparesContent: preparesContent(
              rendered.id,
              presence: presence
            ),
            openProgress: presence.focusedItemID == rendered.id
              ? presence.openProgress
              : 0,
            contentIsInteractive: presence.focusedItemID == rendered.id
              && (presence.mode == .page || presence.mode == .document)
              && !contentGestureActive
              && !settling
              && !pageMotion.isActive,
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
            allowsPageNavigation: (presence.mode == .page
              || presence.mode == .document)
              && presence.openProgress >= 0.999,
            pencilInputGate: model.pencilInputGate,
            onCamera: handleWorkspaceMagnification,
            onPageNavigation: { phase in
              handlePageNavigation(
                phase,
                presence: presence,
                viewport: viewport
              )
            },
            onUndo: {
              model.afterPageInput { model.undoLastSurfaceAction() }
            }
          )
          .allowsHitTesting(false)

          itemSelectionControl(presence: presence, viewport: viewport)
        #endif

        #if os(macOS)
          MacTrackpadPageGestureLayer(
            isEnabled: (presence.mode == .page || presence.mode == .document)
              && presence.openProgress >= 0.999 && !settling,
            onNavigation: { phase in
              handlePageNavigation(
                phase,
                presence: normalizedPresence(for: viewport),
                viewport: viewport
              )
            }
          )
          .frame(width: viewport.x, height: viewport.y)
        #endif

        controls(presence: presence, viewport: viewport)
      }
      .clipped()
      .onAppear {
        publishViewportIfNeeded(viewport)
      }
      .onChange(of: geometry.size) { _, _ in
        publishViewportIfNeeded(viewport)
      }
      .onChange(of: presence.mode) { _, mode in
        if mode != .cover { editingSpatialTextID = nil }
        if mode != .page && mode != .document {
          pageMotion.reset()
          clearPageTransition()
          expectedLocalSelection = nil
        }
      }
      .onChange(of: presence.focusedItemID) { _, itemID in
        if itemID == nil { editingSpatialTextID = nil }
        pageMotion.reset()
        clearPageTransition()
        expectedLocalSelection = nil
      }
      .onChange(of: model.workspace?.selectedPageID) { oldID, newID in
        handleNotebookSelectionChange(
          from: oldID,
          to: newID,
          presence: normalizedPresence(for: viewport)
        )
      }
      .onChange(of: presence.documentPageIndex) { oldIndex, newIndex in
        handleDocumentSelectionChange(
          from: oldIndex,
          to: newIndex,
          presence: normalizedPresence(for: viewport)
        )
      }
      .onDisappear {
        settlementTask?.cancel()
        settlementTask = nil
        cameraGesture = nil
        contentGestureActive = false
        pageInputGestureID = nil
        bufferedCameraPhases = []
        pageNavigationGestureID = nil
        bufferedPageNavigationPhases = []
        pageMotion.reset()
        clearPageTransition()
        settling = false
        editingSpatialTextID = nil
      }
    }
    #if os(macOS)
      .onMoveCommand { direction in
        switch direction {
        case .left:
          handlePageStep(-1)
        case .right:
          handlePageStep(1)
        case .up, .down:
          break
        @unknown default:
          break
        }
      }
    #endif
  }

  @ViewBuilder
  private func itemSelectionControl(
    presence: SessionPresence,
    viewport: SpatialPoint
  ) -> some View {
    if presence.mode == .board || presence.mode == .cover,
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
      let halfWidth = NotebookGeometry.width * presence.camera.scale / 2
      let halfHeight = NotebookGeometry.height * presence.camera.scale / 2
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
  }

  @ViewBuilder
  private func boardElements(
    presence: SessionPresence,
    viewport: SpatialPoint
  ) -> some View {
    if let board = model.board {
      ForEach(board.elements.filter { $0.surface.kind == .board }) { element in
        if let worldOrigin = element.worldOrigin {
          let base = presence.camera.worldToScreen(
            worldOrigin,
            viewport: viewport
          )
          let origin = CGPoint(
            x: base.x + element.frame.x * presence.camera.scale,
            y: base.y + element.frame.y * presence.camera.scale
          )
          SpatialElementContent(element: element)
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
        mode: .board,
        camera: SpatialCamera(),
        viewport: viewport
      )
    }
    return presence.adapted(to: viewport)
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
    let items = Dictionary(
      uniqueKeysWithValues: workspace.items.map { ($0.id, $0) }
    )
    var result: [RenderedWorkspaceItem] = board.freeItems.compactMap { placement in
      items[placement.itemID].map {
        RenderedWorkspaceItem(
          item: $0,
          center: placement.center,
          zIndex: Double(placement.zIndex),
          stackID: nil
        )
      }
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
            center: center,
            zIndex: Double(stack.zIndex) + Double(index) / 100,
            stackID: stack.id
          )
        )
      }
    }
    return result.sorted { $0.zIndex < $1.zIndex }
  }

  private func notebookPages(for item: WorkspaceItem) -> NotebookPageSet {
    guard item.kind == .notebook, let firstPageID = item.pageIDs.first else {
      return NotebookPageSet(current: nil, previous: nil, next: nil)
    }
    let currentID: UUID
    if item.id == model.workspace?.selectedItemID,
      let selectedPageID = model.workspace?.selectedPageID,
      item.pageIDs.contains(selectedPageID)
    {
      currentID = selectedPageID
    } else {
      currentID = firstPageID
    }
    guard let index = item.pageIDs.firstIndex(of: currentID) else {
      return NotebookPageSet(current: model.pages[currentID], previous: nil, next: nil)
    }
    let previous = index > 0 ? model.pages[item.pageIDs[index - 1]] : nil
    let next = index + 1 < item.pageIDs.count
      ? model.pages[item.pageIDs[index + 1]]
      : nil
    return NotebookPageSet(
      current: model.pages[currentID],
      previous: previous,
      next: next
    )
  }

  private func handleNotebookSelectionChange(
    from oldPageID: UUID?,
    to newPageID: UUID?,
    presence: SessionPresence
  ) {
    guard oldPageID != newPageID else { return }
    if let newPageID,
      expectedLocalSelection == .notebook(newPageID)
    {
      expectedLocalSelection = nil
      return
    }
    expectedLocalSelection = nil

    guard presence.mode == .page,
      let itemID = presence.focusedItemID,
      let item = model.workspace?.items.first(where: { $0.id == itemID }),
      item.kind == .notebook,
      let oldPageID,
      let newPageID,
      let oldIndex = item.pageIDs.firstIndex(of: oldPageID),
      let newIndex = item.pageIDs.firstIndex(of: newPageID)
    else {
      pageMotion.reset()
      clearPageTransition()
      return
    }

    beginCommittedPagePresentation(
      itemID: itemID,
      offset: newIndex - oldIndex,
      departingPage: model.pages[oldPageID],
      departingDocumentPageIndex: nil
    )
  }

  private func handleDocumentSelectionChange(
    from oldIndex: Int,
    to newIndex: Int,
    presence: SessionPresence
  ) {
    guard oldIndex != newIndex else { return }
    if let itemID = presence.focusedItemID,
      expectedLocalSelection == .document(itemID, newIndex)
    {
      expectedLocalSelection = nil
      return
    }
    expectedLocalSelection = nil

    guard presence.mode == .document,
      let itemID = presence.focusedItemID,
      model.documents[itemID] != nil
    else {
      pageMotion.reset()
      clearPageTransition()
      return
    }

    beginCommittedPagePresentation(
      itemID: itemID,
      offset: newIndex - oldIndex,
      departingPage: nil,
      departingDocumentPageIndex: oldIndex
    )
  }

  /// A durable change is already true before this presentation begins. One
  /// adjacent sheet has a real spatial path; a larger jump honestly fades
  /// through zero because no intermediate path was observed.
  private func beginCommittedPagePresentation(
    itemID: UUID,
    offset: Int,
    departingPage: PageDocument?,
    departingDocumentPageIndex: Int?
  ) {
    pageMotion.reset()
    clearPageTransition()
    let transitionID = UUID()
    pageTransitionID = transitionID
    transitionItemID = itemID

    if abs(offset) == 1, !reduceMotion {
      pageMotion.presentCommittedChange(
        from: CGFloat(offset),
        reduceMotion: false,
        onFinish: {
          finishPageTransition(transitionID)
        }
      )
    } else {
      self.departingNotebookPage = departingPage
      self.departingDocumentPageIndex = departingDocumentPageIndex
      pageMotion.presentDissolve {
        finishPageTransition(transitionID)
      }
    }
    contentGestureActive = true
  }

  private func finishPageTransition(_ transitionID: UUID) {
    guard pageTransitionID == transitionID else { return }
    contentGestureActive = false
    clearPageTransition()
  }

  private func clearPageTransition() {
    pageTransitionID = nil
    transitionItemID = nil
    departingNotebookPage = nil
    departingDocumentPageIndex = nil
  }

  private func handlePageStep(_ direction: Int) {
    guard direction == -1 || direction == 1 else { return }
    pageMotion.finishBeforeCompetingGesture()
    guard let presence = model.presence,
      presence.mode == .page || presence.mode == .document,
      presence.openProgress >= 0.999,
      let itemID = presence.focusedItemID
    else { return }
    let availability = pageAvailability(itemID: itemID, presence: presence)
    guard (direction < 0 && availability.previous)
      || (direction > 0 && availability.next)
    else { return }

    pageMotion.select(
      direction: direction,
      availability: availability,
      reduceMotion: reduceMotion,
      onCommit: { committedDirection in
        commitPageSelection(committedDirection, itemID: itemID)
      },
      onFinish: {
        contentGestureActive = false
      }
    )
    contentGestureActive = true
  }

  private func handlePageNavigation(
    _ phase: PageNavigationPhase,
    presence: SessionPresence,
    viewport: SpatialPoint
  ) {
    if pageNavigationGestureID != nil {
      bufferPageNavigationPhase(phase)
      return
    }

    if case .began = phase, presence.mode == .page {
      let gestureID = UUID()
      pageNavigationGestureID = gestureID
      bufferedPageNavigationPhases = [phase]
      model.afterPageInput {
        guard pageNavigationGestureID == gestureID else { return }
        let phases = bufferedPageNavigationPhases
        pageNavigationGestureID = nil
        bufferedPageNavigationPhases = []
        for buffered in phases {
          applyPageNavigation(
            buffered,
            presence: presence,
            viewport: viewport
          )
        }
      }
      return
    }

    applyPageNavigation(phase, presence: presence, viewport: viewport)
  }

  private func bufferPageNavigationPhase(_ phase: PageNavigationPhase) {
    switch phase {
    case .began:
      bufferedPageNavigationPhases = [phase]
    case .changed:
      if bufferedPageNavigationPhases.count > 1 {
        bufferedPageNavigationPhases.removeSubrange(1...)
      }
      bufferedPageNavigationPhases.append(phase)
    case .ended, .cancelled:
      if bufferedPageNavigationPhases.count > 1 {
        bufferedPageNavigationPhases.removeSubrange(1...)
      }
      bufferedPageNavigationPhases.append(phase)
    }
  }

  private func applyPageNavigation(
    _ phase: PageNavigationPhase,
    presence: SessionPresence,
    viewport _: SpatialPoint
  ) {
    guard presence.mode == .page || presence.mode == .document,
      presence.openProgress >= 0.999,
      let itemID = presence.focusedItemID,
      model.presence?.mode == presence.mode,
      model.presence?.focusedItemID == itemID
    else { return }

    let availability = pageAvailability(
      itemID: itemID,
      presence: presence
    )
    let extent = CGFloat(NotebookGeometry.width * presence.camera.scale)
    let begin: (PageNavigationSample) -> Void = { sample in
      // Direct input inherits the shown coordinate, but the old remote
      // presentation no longer needs its readout lease.
      if pageTransitionID != nil { clearPageTransition() }
      pageMotion.begin(
        sample,
        extent: extent,
        availability: availability,
        onCommit: { direction in
          commitPageSelection(direction, itemID: itemID)
        },
        onFinish: {
          contentGestureActive = false
        }
      )
      contentGestureActive = true
    }

    switch phase {
    case .began(let sample):
      begin(sample)
    case .changed(let sample):
      if pageMotion.phase != .tracking { begin(sample) }
      else { pageMotion.track(sample) }
    case .ended(let sample):
      if pageMotion.phase != .tracking { begin(sample) }
      pageMotion.end(sample, reduceMotion: reduceMotion)
    case .cancelled:
      pageMotion.cancel(reduceMotion: reduceMotion)
    }
  }

  private func pageAvailability(
    itemID: UUID,
    presence: SessionPresence
  ) -> PageMotionAvailability {
    if presence.mode == .document {
      let count = documentPageLayouts[itemID]?.pageCount ?? 1
      return PageMotionAvailability(
        previous: presence.documentPageIndex > 0,
        next: presence.documentPageIndex + 1 < count
      )
    }
    guard let item = model.workspace?.items.first(where: { $0.id == itemID }),
      let pageID = model.workspace?.selectedPageID,
      let index = item.pageIDs.firstIndex(of: pageID)
    else {
      return PageMotionAvailability(previous: false, next: false)
    }
    return PageMotionAvailability(
      previous: index > 0,
      next: true
    )
  }

  private func commitPageSelection(_ direction: Int, itemID: UUID) {
    guard let presence = model.presence,
      presence.focusedItemID == itemID
    else { return }

    let pageNumber: Int?
    switch presence.mode {
    case .page:
      if let pageIndex = model.turnPage(direction) {
        expectedLocalSelection = model.workspace?.selectedPageID.map {
          .notebook($0)
        }
        pageNumber = pageIndex + 1
      } else {
        pageNumber = nil
      }
    case .document:
      let count = documentPageLayouts[itemID]?.pageCount ?? 1
      let next = min(
        max(0, presence.documentPageIndex + direction),
        count - 1
      )
      guard next != presence.documentPageIndex else { return }
      expectedLocalSelection = .document(itemID, next)
      let selected = model.selectDocumentPage(
        next,
        documentID: itemID
      )
      if selected == nil { expectedLocalSelection = nil }
      pageNumber = selected.map { $0 + 1 }
    case .board, .cover:
      pageNumber = nil
    }

    guard let pageNumber else { return }
    #if os(iOS)
      UISelectionFeedbackGenerator().selectionChanged()
      UIAccessibility.post(
        notification: .pageScrolled,
        argument: "Страница \(pageNumber)"
      )
    #endif
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
    expectedLocalSelection = .document(documentID, layout.pageCount - 1)
    let selected = model.selectDocumentPage(
      layout.pageCount - 1,
      documentID: documentID
    )
    if selected == nil { expectedLocalSelection = nil }
  }

  private func preparesContent(
    _ itemID: UUID,
    presence: SessionPresence
  ) -> Bool {
    if let gesture = cameraGesture,
      let candidate = gesture.candidateItemID,
      presence.camera.scale >= coverFocusScale(viewport: presence.viewport)
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
      pageMotion.finishBeforeCompetingGesture()
      interruptSettlementForInput()
      selectedItemID = nil
      editingSpatialTextID = nil
      guard let presence = model.presence else { return }
      let focusedItemID = presence.mode == .board
        ? nil
        : presence.focusedItemID
      let candidate = focusedItemID
        ?? focusCandidate(at: centroid, presence: presence)
      contentGestureActive = presence.mode == .page || presence.mode == .document
      cameraGesture = CameraGestureSnapshot(
        presence: presence,
        baselineCamera: presence.camera,
        baselineCentroid: centroid,
        baselineMagnification: 1,
        lastMagnification: 1,
        lastCentroid: centroid,
        candidateItemID: candidate,
        isApproaching: isOpeningApproach,
        boardEngagement: focusedItemID.map {
          let coverScale = coverFocusScale(viewport: presence.viewport)
          let fallback = presence.mode == .cover
            && presence.openProgress <= 0.001
            ? presence.camera.scale
            : coverScale * NotebookOpeningIntent.entryScaleRatio
          return CameraGestureSnapshot.BoardEngagement(
            itemID: $0,
            openingScale: NotebookOpeningTransition.openingScale(
              cameraScale: presence.camera.scale,
              pageScale: fitScale(viewport: presence.viewport),
              progress: presence.openProgress,
              fallback: fallback
            )
          )
        },
        dockingStrength: 0
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
      model.afterPageInput {
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
    let pageScale = fitScale(viewport: viewport)
    let coverScale = coverFocusScale(viewport: viewport)
    let magnification = Double(scale)
    let directionThreshold: CGFloat = 0.000_5
    let directionDelta = scale - snapshot.lastMagnification
    let directionChanged: Bool
    if abs(directionDelta) > directionThreshold {
      let currentDirection = directionDelta > 0
      directionChanged = currentDirection != snapshot.isApproaching
      snapshot.isApproaching = currentDirection
    } else {
      directionChanged = false
    }

    let maximumScale = snapshot.boardEngagement == nil
      ? SpatialCamera.maximumScale
      : pageScale
    var camera: SpatialCamera
    if directionChanged, let displayedCamera = model.presence?.camera {
      camera = displayedCamera.pinched(
        by: magnification / max(Double(snapshot.lastMagnification), 0.001),
        from: SpatialPoint(
          x: snapshot.lastCentroid.x,
          y: snapshot.lastCentroid.y
        ),
        to: SpatialPoint(x: centroid.x, y: centroid.y),
        viewport: viewport,
        maximumScale: maximumScale
      )
      snapshot.baselineCamera = camera
      snapshot.baselineCentroid = centroid
      snapshot.baselineMagnification = scale
    } else {
      camera = snapshot.baselineCamera.pinched(
        by: magnification
          / max(Double(snapshot.baselineMagnification), 0.001),
        from: SpatialPoint(
          x: snapshot.baselineCentroid.x,
          y: snapshot.baselineCentroid.y
        ),
        to: SpatialPoint(x: centroid.x, y: centroid.y),
        viewport: viewport,
        maximumScale: maximumScale
      )
    }

    if let boardEngagement = snapshot.boardEngagement {
      if
        NotebookOpeningIntent.shouldDisengage(
          cameraScale: camera.scale,
          coverScale: coverScale
        )
      {
        snapshot.boardEngagement = nil
        snapshot.dockingStrength = 0
      } else {
        snapshot.candidateItemID = boardEngagement.itemID
      }
    }

    if snapshot.boardEngagement == nil {
      let liveBoardPresence = SessionPresence(
        mode: .board,
        camera: camera,
        viewport: viewport
      )
      if let detected = focusCandidate(
        at: centroid,
        presence: liveBoardPresence
      ) {
        snapshot.candidateItemID = detected
      } else if let retained = snapshot.candidateItemID,
        selectionStrength(
          for: retained,
          at: centroid,
          presence: liveBoardPresence,
          halo: NotebookOpeningIntent.candidateRetentionHalo
        ) <= 0
      {
        snapshot.candidateItemID = nil
      }
    }

    let attractionTarget = snapshot.boardEngagement?.itemID
      ?? snapshot.candidateItemID
    if let attractionTarget,
      let center = model.board?.focusedCenter(of: attractionTarget)
    {
      let dockingStrength = NotebookDockingField.strength(
        camera: camera,
        viewport: viewport
      )
      snapshot.dockingStrength = dockingStrength
      if snapshot.isApproaching {
        camera = NotebookDockingField.attractedCamera(
          camera,
          toward: center,
          viewport: viewport,
          strength: dockingStrength
        )
      }
    } else {
      snapshot.dockingStrength = 0
    }

    if snapshot.boardEngagement == nil,
      let candidate = snapshot.candidateItemID,
      NotebookOpeningIntent.shouldEngage(
        isApproaching: snapshot.isApproaching,
        cameraScale: camera.scale,
        coverScale: coverScale
      )
    {
      snapshot.boardEngagement = CameraGestureSnapshot.BoardEngagement(
        itemID: candidate,
        openingScale: camera.scale
      )
      model.selectItem(candidate)
    }

    let engagement = snapshot.boardEngagement
    let candidate = engagement?.itemID
    let open: Double
    if let engagement {
      open = NotebookOpeningTransition.progress(
        cameraScale: camera.scale,
        openingScale: engagement.openingScale,
        pageScale: pageScale
      )
    } else {
      open = 0
    }
    let mode: WorkspaceSemanticMode = candidate == nil ? .board : .cover
    snapshot.lastMagnification = scale
    snapshot.lastCentroid = centroid
    cameraGesture = snapshot
    model.updatePresence(
      SessionPresence(
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
    let pageScale = fitScale(viewport: viewport)
    if let itemID = presence.focusedItemID,
      NotebookDockingField.shouldDock(
        strength: snapshot.dockingStrength,
        isApproaching: snapshot.isApproaching,
        velocity: Double(velocity)
      ),
      let center = model.board?.focusedCenter(of: itemID)
    {
      let target = SessionPresence(
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
      animateSettlement(to: target, duration: 0.2)
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
    guard let rendered = renderedItems(presence: presence)
      .first(where: { $0.id == itemID })
    else { return 0 }
    let screen = presence.camera.worldToScreen(
      rendered.center,
      viewport: presence.viewport
    )
    let width = NotebookGeometry.width * presence.camera.scale
    let height = NotebookGeometry.height * presence.camera.scale
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

  private func openItem(
    _ itemID: UUID,
    viewport: SpatialPoint
  ) {
    guard !settling,
      cameraGesture == nil,
      model.presence != nil,
      let center = model.board?.focusedCenter(of: itemID)
    else { return }
    let previousPresence = model.presence
    model.selectItem(itemID)
    let target = SessionPresence(
      mode: openMode(for: itemID),
      camera: SpatialCamera(center: center, scale: fitScale(viewport: viewport)),
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

  private func animateSettlement(
    to target: SessionPresence,
    duration: TimeInterval
  ) {
    settlementTask?.cancel()
    settling = true
    withAnimation(.spring(duration: duration, bounce: 0.08)) {
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
    }
    guard let itemID else { return }
    let target = SessionPresence(
      mode: .cover,
      camera: SpatialCamera(
        center: center,
        scale: coverFocusScale(viewport: viewport)
      ),
      viewport: viewport,
      focusedItemID: itemID,
      openProgress: 0
    )
    animateSettlement(to: target, duration: 0.42)
  }

  private func openMode(for itemID: UUID) -> WorkspaceSemanticMode {
    model.workspace?.items.first(where: { $0.id == itemID })?.kind == .document
      ? .document
      : .page
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

    guard let moving = renderedItems(presence: presence)
      .first(where: { $0.id == itemID })
    else { return }
    let target = renderedItems(presence: presence)
      .reversed()
      .first { candidate in
        guard candidate.id != itemID else { return false }
        let delta = center.delta(to: candidate.center)
        return abs(delta.x) <= NotebookGeometry.width * 0.6
          && abs(delta.y) <= NotebookGeometry.height * 0.6
      }
    if let target {
      _ = model.stackItem(moving.id, onto: target.id)
    }
  }

  private func fitScale(viewport: SpatialPoint) -> Double {
    NotebookPresentation.fitScale(viewport: viewport)
  }

  private func coverFocusScale(viewport: SpatialPoint) -> Double {
    NotebookPresentation.coverScale(viewport: viewport)
  }
}

private struct WorkspaceSceneItem: View {
  @Environment(NotebookAppModel.self) private var model

  let rendered: RenderedWorkspaceItem
  let page: PageDocument?
  let previousPage: PageDocument?
  let nextPage: PageDocument?
  let document: DocumentDocument?
  let documentState: DocumentStateJournal?
  let documentPageIndex: Int
  let pageMotion: PageMotionController?
  let departingPage: PageDocument?
  let departingDocumentPageIndex: Int?
  let camera: SpatialCamera
  let viewport: SpatialPoint
  let isFocused: Bool
  let preparesContent: Bool
  let openProgress: Double
  let contentIsInteractive: Bool
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
  let onDocumentPageLayout: (DocumentPageLayout) -> Void

  @State private var dragTranslation = CGSize.zero
  @State private var liftStarted = false

  var body: some View {
    let screen = camera.worldToScreen(rendered.center, viewport: viewport)
    let scale = camera.scale
    let contentIsLive = openProgress > 0.001 || contentIsInteractive
    ZStack {
      if rendered.item.kind == .notebook {
        notebookContents(isLive: contentIsLive)
      } else {
        documentContents(isLive: contentIsLive)
      }
    }
    .frame(
      width: NotebookGeometry.width,
      height: NotebookGeometry.height
    )
    .overlay {
      if openProgress < 0.12, isSelected {
        RoundedRectangle(
          cornerRadius: NotebookGeometry.cornerRadius,
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
    .shadow(
      color: .black.opacity((isLifted ? 0.28 : 0.13) * (1 - openProgress)),
      radius: isLifted ? 24 : max(3, 18 * scale),
      y: isLifted ? 15 : max(2, 8 * scale)
    )
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
    if preparesContent, let page {
      if let pageMotion {
        NotebookPageTransitionSurface(
          page: page,
          previousPage: previousPage,
          nextPage: nextPage,
          departingPage: departingPage,
          pageMotion: pageMotion,
          isInteractive: contentIsInteractive,
          isVisible: isLive
        )
      } else {
        PageSurface(
          page: page,
          isInteractive: contentIsInteractive,
          isVisible: isLive
        )
        .allowsHitTesting(contentIsInteractive)
      }
    }

    ZStack {
      itemCover
        .opacity(openProgress <= 0.5 ? 1 : 0)
      NotebookCoverBackView()
        .opacity(openProgress > 0.5 ? 1 : 0)
    }
    .rotation3DEffect(
      .degrees(-178 * openProgress),
      axis: (x: 0, y: 1, z: 0),
      anchor: .leading,
      perspective: 0.62
    )
    .allowsHitTesting(openProgress < 0.12)
  }

  @ViewBuilder
  private func documentContents(isLive: Bool) -> some View {
    if preparesContent, let document, let documentState {
      DocumentWebView(
        document: document,
        state: documentState,
        isInteractive: contentIsInteractive || pageMotion?.isActive == true,
        selectedPageIndex: documentPageIndex,
        pagePosition: documentPagePosition,
        usesExternalPaging: usesExternalDocumentPaging,
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
      .background(Color(red: 0.985, green: 0.98, blue: 0.955))
      .clipShape(
        RoundedRectangle(
          cornerRadius: NotebookGeometry.cornerRadius,
          style: .continuous
        )
      )
      .opacity(isLive ? 1 : 0)
      .opacity(documentDissolveOpacity)
      .allowsHitTesting(contentIsInteractive)
    }
    itemCover
      .opacity(max(0, 1 - openProgress * 2.4))
      .scaleEffect(1 - openProgress * 0.015)
      .allowsHitTesting(openProgress < 0.12)
  }

  private var pageMotionPosition: CGFloat {
    pageMotion?.position ?? 0
  }

  private var dissolveProgress: CGFloat {
    pageMotion?.dissolveProgress ?? 1
  }

  private var documentDissolveOpacity: Double {
    guard pageMotion?.presentation == .dissolve,
      departingDocumentPageIndex != nil
    else { return 1 }
    if dissolveProgress < 0.5 {
      return Double(max(0, 1 - dissolveProgress / 0.35))
    }
    return Double(max(0, (dissolveProgress - 0.65) / 0.35))
  }

  private var documentPagePosition: Double {
    if pageMotion?.presentation == .dissolve,
      let departingDocumentPageIndex,
      dissolveProgress < 0.5
    {
      return Double(departingDocumentPageIndex)
    }
    return Double(documentPageIndex) - Double(pageMotionPosition)
  }

  private var usesExternalDocumentPaging: Bool {
    true
  }

  private var itemCover: some View {
    WorkspaceItemCoverView(
      item: rendered.item,
      spatialInkSurfaces: spatialInkSurfaces,
      elements: model.board?.elements.filter {
        $0.surface == .cover(rendered.id)
      } ?? [],
      editingTextID: editingTextID,
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
      onTextEditingEnded: onTextEditingEnded
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

private struct WorkspaceItemCoverView: View {
  @Environment(NotebookAppModel.self) private var model

  let item: WorkspaceItem
  let spatialInkSurfaces: SpatialInkSurfaceRegistry
  let elements: [SpatialElement]
  let editingTextID: String?
  let onTap: (CGPoint, Int) -> Void
  let onLiftChanged: (Bool) -> Void
  let onTranslationChanged: (CGSize) -> Void
  let onTranslationEnded: (CGSize) -> Void
  let onTextEditingEnded: (String) -> Void

  var body: some View {
    ZStack(alignment: .topLeading) {
      coverBackground

      if !item.title.isEmpty {
        Text(item.title)
          .font(
            .system(
              size: item.kind == .document ? 42 : 38,
              weight: .medium,
              design: item.kind == .document ? .serif : .rounded
            )
          )
          .foregroundStyle(Color.black.opacity(0.64))
          .lineLimit(3)
          .frame(width: 570, alignment: .leading)
          .offset(
            x: item.kind == .document ? 96 : 126,
            y: item.kind == .document ? 142 : 170
          )
      }

      ForEach(elements) { element in
        SpatialElementContent(
          element: element,
          isTextEditing: editingTextID == element.id,
          onTextEditingEnded: { onTextEditingEnded(element.id) }
        )
          .frame(width: element.frame.width, height: element.frame.height)
          .offset(x: element.frame.x, y: element.frame.y)
      }

      #if os(iOS)
        NotebookInteractionView(
          passthroughFrames: interactionPassthroughFrames,
          onTap: onTap,
          onLiftChanged: onLiftChanged,
          onTranslationChanged: onTranslationChanged,
          onTranslationEnded: onTranslationEnded
        )
        .frame(
          width: NotebookGeometry.width,
          height: NotebookGeometry.height
        )
        .accessibilityHidden(true)
      #endif

      #if os(iOS)
        SpatialInkSurfaceView(
          surface: .cover(item.id),
          journal: model.spatialInk,
          registry: spatialInkSurfaces
        )
        .allowsHitTesting(false)
      #elseif os(macOS)
        SpatialInkSurfaceView(
          drawing: SpatialInkDrawingComposer.drawing(
            for: .cover(item.id),
            in: model.spatialInk
          )
        )
        .allowsHitTesting(false)
      #endif
    }
    .frame(
      width: NotebookGeometry.width,
      height: NotebookGeometry.height
    )
    .clipShape(
      RoundedRectangle(
        cornerRadius: NotebookGeometry.cornerRadius,
        style: .continuous
      )
    )
    .contentShape(
      RoundedRectangle(
        cornerRadius: NotebookGeometry.cornerRadius,
        style: .continuous
      )
    )
  }

  @ViewBuilder
  private var coverBackground: some View {
    if item.kind == .notebook {
      RoundedRectangle(
        cornerRadius: NotebookGeometry.cornerRadius,
        style: .continuous
      )
      .fill(Color(red: 0.945, green: 0.93, blue: 0.875))
      RoundedRectangle(
        cornerRadius: NotebookGeometry.cornerRadius,
        style: .continuous
      )
      .stroke(Color.black.opacity(0.08), lineWidth: 2)
      Rectangle()
        .fill(Color.black.opacity(0.055))
        .frame(width: 18)
        .padding(.vertical, 2)
        .padding(.leading, 24)
    } else {
      RoundedRectangle(
        cornerRadius: NotebookGeometry.cornerRadius,
        style: .continuous
      )
      .fill(Color(red: 0.987, green: 0.982, blue: 0.958))
      RoundedRectangle(
        cornerRadius: NotebookGeometry.cornerRadius,
        style: .continuous
      )
      .stroke(Color.black.opacity(0.1), lineWidth: 1.5)
      VStack(alignment: .leading, spacing: 22) {
        Text("DOCUMENT")
          .font(.system(size: 18, weight: .semibold, design: .rounded))
          .tracking(4)
          .foregroundStyle(Color.black.opacity(0.28))
        ForEach(0..<7, id: \.self) { index in
          Capsule()
            .fill(Color.black.opacity(index == 0 ? 0.12 : 0.075))
            .frame(width: index == 6 ? 360 : 590, height: 3)
        }
      }
      .offset(x: 96, y: item.title.isEmpty ? 138 : 300)
      Path { path in
        path.move(to: CGPoint(x: 724, y: 0))
        path.addLine(to: CGPoint(x: 834, y: 110))
        path.addLine(to: CGPoint(x: 834, y: 0))
        path.closeSubpath()
      }
      .fill(Color.black.opacity(0.045))
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

private struct NotebookCoverBackView: View {
  var body: some View {
    RoundedRectangle(
      cornerRadius: NotebookGeometry.cornerRadius,
      style: .continuous
    )
    .fill(Color(red: 0.965, green: 0.955, blue: 0.915))
    .overlay {
      RoundedRectangle(
        cornerRadius: NotebookGeometry.cornerRadius,
        style: .continuous
      )
      .stroke(Color.black.opacity(0.07), lineWidth: 2)
    }
    .frame(
      width: NotebookGeometry.width,
      height: NotebookGeometry.height
    )
  }
}

private struct SpatialElementContent: View {
  @Environment(NotebookAppModel.self) private var model
  let element: SpatialElement
  let isTextEditing: Bool
  let onTextEditingEnded: () -> Void

  init(
    element: SpatialElement,
    isTextEditing: Bool = false,
    onTextEditingEnded: @escaping () -> Void = {}
  ) {
    self.element = element
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
      AgentWebElementView(element: agentElement) { state in
        model.commitSpatialElementState(elementID: element.id, state: state)
      }
    }
  }

  private var agentElement: AgentElement {
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
      let phaseX = camera.center.localX
        .truncatingRemainder(dividingBy: worldStep) * camera.scale
      let phaseY = camera.center.localY
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

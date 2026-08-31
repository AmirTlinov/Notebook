import SwiftUI
import NotebookCore

private struct CameraGestureSnapshot {
  struct BoardEngagement {
    let notebookID: UUID
    let openingScale: Double
  }

  let presence: SessionPresence
  var baselineCamera: SpatialCamera
  var baselineCentroid: CGPoint
  var baselineMagnification: CGFloat
  var lastMagnification: CGFloat
  var lastCentroid: CGPoint
  var candidateNotebookID: UUID?
  var isApproaching: Bool
  var boardEngagement: BoardEngagement?
  var dockingStrength: Double
}

struct RenderedNotebook: Identifiable {
  let notebook: Notebook
  let center: WorldPoint
  let zIndex: Double
  let stackID: UUID?

  var id: UUID { notebook.id }
}

struct SpatialWorkspaceView: View {
  @Environment(NotebookAppModel.self) private var model

  @State private var cameraGesture: CameraGestureSnapshot?
  @State private var panStart: SessionPresence?
  @State private var selectedNotebookID: UUID?
  @State private var liftedNotebookID: UUID?
  @State private var editingSpatialTextID: String?
  @State private var pageGestureActive = false
  @State private var pageInputGestureID: UUID?
  @State private var bufferedCameraPhases: [WorkspaceMagnificationPhase] = []
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
      let rendered = renderedNotebooks(presence: presence)

      ZStack {
        SpatialBoardGrid(camera: presence.camera)

        #if os(iOS)
          BoardPanView(
            isEnabled: presence.mode != .page && cameraGesture == nil
              && !settling,
            excludedFrames: rendered.map { notebook in
              let center = presence.camera.worldToScreen(
                notebook.center,
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
                selectedNotebookID = nil
              }
              editingSpatialTextID = nil
            },
            onBegan: {
              selectedNotebookID = nil
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
            notebooks: rendered.map {
              SpatialNotebookSurface(
                notebookID: $0.id,
                center: $0.center,
                zIndex: $0.zIndex
              )
            },
            journal: model.spatialInk,
            penStyle: model.penStyle,
            eraserStyle: model.eraserStyle,
            drawingTool: model.drawingTool,
            surfaceRegistry: spatialInkSurfaces,
            onCommit: model.appendSpatialInk,
            isEnabled: presence.mode != .page && !pageGestureActive
              && editingSpatialTextID == nil
          )
          .allowsHitTesting(false)
        #endif

        ForEach(rendered) { rendered in
          NotebookSceneItem(
            rendered: rendered,
            page: page(for: rendered.notebook),
            camera: presence.camera,
            viewport: viewport,
            isFocused: presence.focusedNotebookID == rendered.id,
            preparesPage: preparesPage(
              rendered.id,
              presence: presence
            ),
            openProgress: presence.focusedNotebookID == rendered.id
              ? presence.openProgress
              : 0,
            pageIsInteractive: presence.focusedNotebookID == rendered.id
              && (presence.mode == .page || pageGestureActive)
              && !settling,
            isSelected: selectedNotebookID == rendered.id,
            isLifted: liftedNotebookID == rendered.id,
            editingTextID: editingSpatialTextID,
            spatialInkSurfaces: spatialInkSurfaces,
            onDrop: { notebookID, center in
              dropNotebook(notebookID, at: center, presence: presence)
            },
            onSelect: { notebookID in
              withAnimation(.easeOut(duration: 0.12)) {
                selectedNotebookID = notebookID
              }
            },
            onLiftChanged: { notebookID, lifted in
              if lifted { editingSpatialTextID = nil }
              withAnimation(.spring(duration: 0.18, bounce: 0.18)) {
                liftedNotebookID = lifted ? notebookID : nil
                if lifted { selectedNotebookID = notebookID }
              }
            },
            onOpen: { notebookID in
              editingSpatialTextID = nil
              selectedNotebookID = nil
              openNotebook(notebookID, viewport: viewport)
            },
            onEditText: { notebookID, point in
              beginTextEditing(on: notebookID, at: point)
            },
            onTextEditingEnded: { elementID in
              if editingSpatialTextID == elementID {
                editingSpatialTextID = nil
              }
            }
          )
          .zIndex(liftedNotebookID == rendered.id ? 9_000 : rendered.zIndex)
        }

        #if os(iOS)
          WorkspaceGestureLayer(
            isEnabled: true,
            isPageOpen: presence.mode == .page,
            onCamera: handleWorkspaceMagnification,
            onNavigate: { direction in
              model.afterPageInput { model.turnPage(direction) }
            },
            onUndo: {
              model.afterPageInput { model.undoLastSurfaceAction() }
            }
          )
          .allowsHitTesting(false)

          notebookSelectionControl(presence: presence, viewport: viewport)
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
      }
      .onChange(of: presence.focusedNotebookID) { _, notebookID in
        if notebookID == nil { editingSpatialTextID = nil }
      }
      .onDisappear {
        settlementTask?.cancel()
        settlementTask = nil
        cameraGesture = nil
        pageGestureActive = false
        pageInputGestureID = nil
        bufferedCameraPhases = []
        settling = false
        editingSpatialTextID = nil
      }
    }
  }

  @ViewBuilder
  private func notebookSelectionControl(
    presence: SessionPresence,
    viewport: SpatialPoint
  ) -> some View {
    if presence.mode != .page,
      liftedNotebookID == nil,
      let selectedNotebookID,
      let rendered = renderedNotebooks(presence: presence).first(where: {
        $0.id == selectedNotebookID
      })
    {
      let center = presence.camera.worldToScreen(
        rendered.center,
        viewport: viewport
      )
      let halfWidth = NotebookGeometry.width * presence.camera.scale / 2
      let halfHeight = NotebookGeometry.height * presence.camera.scale / 2
      Button(role: .destructive) {
        guard model.deleteNotebook(selectedNotebookID) else { return }
        self.selectedNotebookID = nil
      } label: {
        Image(systemName: "trash")
          .font(.system(size: 17, weight: .semibold))
          .frame(width: 44, height: 44)
          .background(.regularMaterial, in: Circle())
          .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Удалить тетрадь")
      .accessibilityIdentifier("delete-notebook")
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
        Button {
          createNotebook(presence: presence, viewport: viewport)
        } label: {
          Image(systemName: "plus")
            .font(.system(size: 21, weight: .medium))
            .frame(width: 48, height: 48)
            .background(.ultraThinMaterial, in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Создать тетрадь")
        .accessibilityIdentifier("create-notebook")
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
    on notebookID: UUID,
    at point: SpatialPoint
  ) {
    guard model.presence?.mode == .cover,
      model.presence?.focusedNotebookID == notebookID,
      let board = model.board
    else { return }
    let elements = board.elements.filter {
      $0.surface == .cover(notebookID)
    }
    if let text = elements.reversed().first(where: {
      $0.kind == .nativeText && $0.frame.contains(point)
    }) {
      editingSpatialTextID = text.id
      return
    }
    guard !elements.contains(where: { $0.frame.contains(point) }),
      let elementID = model.addNativeText(on: notebookID, at: point)
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

  private func renderedNotebooks(
    presence: SessionPresence
  ) -> [RenderedNotebook] {
    guard let board = model.board, let workspace = model.workspace else {
      return []
    }
    let notebooks = Dictionary(
      uniqueKeysWithValues: workspace.notebooks.map { ($0.id, $0) }
    )
    var result: [RenderedNotebook] = board.freeNotebooks.compactMap { placement in
      notebooks[placement.notebookID].map {
        RenderedNotebook(
          notebook: $0,
          center: placement.center,
          zIndex: Double(placement.zIndex),
          stackID: nil
        )
      }
    }

    for stack in board.stacks {
      let focusedMemberID = presence.mode == .board
        ? nil
        : presence.focusedNotebookID.flatMap { notebookID in
          stack.notebookIDs.contains(notebookID) ? notebookID : nil
        }
      for (index, notebookID) in stack.notebookIDs.enumerated() {
        guard focusedMemberID == nil || focusedMemberID == notebookID,
          let notebook = notebooks[notebookID],
          let center = NotebookStackPresentation.boardCenter(
            of: notebookID,
            in: stack,
            cameraScale: presence.camera.scale,
            viewport: presence.viewport
          )
        else { continue }
        result.append(
          RenderedNotebook(
            notebook: notebook,
            center: center,
            zIndex: Double(stack.zIndex) + Double(index) / 100,
            stackID: stack.id
          )
        )
      }
    }
    return result.sorted { $0.zIndex < $1.zIndex }
  }

  private func page(for notebook: Notebook) -> PageDocument? {
    let pageID: UUID
    if notebook.id == model.workspace?.selectedNotebookID,
      notebook.pageIDs.contains(model.workspace?.selectedPageID ?? UUID())
    {
      pageID = model.workspace?.selectedPageID ?? notebook.pageIDs[0]
    } else {
      pageID = notebook.pageIDs[0]
    }
    return model.pages[pageID]
  }

  private func preparesPage(
    _ notebookID: UUID,
    presence: SessionPresence
  ) -> Bool {
    if let gesture = cameraGesture,
      let candidate = gesture.candidateNotebookID,
      presence.camera.scale >= coverFocusScale(viewport: presence.viewport)
        * NotebookOpeningIntent.pagePreparationScaleRatio
    {
      return candidate == notebookID
    }
    if let focusedNotebookID = presence.focusedNotebookID {
      return focusedNotebookID == notebookID
    }
    #if os(iOS)
      return model.workspace?.selectedNotebookID == notebookID
    #else
      return false
    #endif
  }

  private func handleBoardMagnification(_ phase: WorkspaceMagnificationPhase) {
    switch phase {
    case .began(let centroid, let isOpeningApproach):
      interruptSettlementForInput()
      selectedNotebookID = nil
      editingSpatialTextID = nil
      guard let presence = model.presence else { return }
      let focusedNotebookID = presence.mode == .board
        ? nil
        : presence.focusedNotebookID
      let candidate = focusedNotebookID
        ?? focusCandidate(at: centroid, presence: presence)
      pageGestureActive = presence.mode == .page
      cameraGesture = CameraGestureSnapshot(
        presence: presence,
        baselineCamera: presence.camera,
        baselineCentroid: centroid,
        baselineMagnification: 1,
        lastMagnification: 1,
        lastCentroid: centroid,
        candidateNotebookID: candidate,
        isApproaching: isOpeningApproach,
        boardEngagement: focusedNotebookID.map {
          let coverScale = coverFocusScale(viewport: presence.viewport)
          let fallback = presence.mode == .cover
            && presence.openProgress <= 0.001
            ? presence.camera.scale
            : coverScale * NotebookOpeningIntent.entryScaleRatio
          return CameraGestureSnapshot.BoardEngagement(
            notebookID: $0,
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
      pageGestureActive = false
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
        snapshot.candidateNotebookID = boardEngagement.notebookID
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
        snapshot.candidateNotebookID = detected
      } else if let retained = snapshot.candidateNotebookID,
        selectionStrength(
          for: retained,
          at: centroid,
          presence: liveBoardPresence,
          halo: NotebookOpeningIntent.candidateRetentionHalo
        ) <= 0
      {
        snapshot.candidateNotebookID = nil
      }
    }

    let attractionTarget = snapshot.boardEngagement?.notebookID
      ?? snapshot.candidateNotebookID
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
      let candidate = snapshot.candidateNotebookID,
      NotebookOpeningIntent.shouldEngage(
        isApproaching: snapshot.isApproaching,
        cameraScale: camera.scale,
        coverScale: coverScale
      )
    {
      snapshot.boardEngagement = CameraGestureSnapshot.BoardEngagement(
        notebookID: candidate,
        openingScale: camera.scale
      )
      model.selectNotebook(candidate)
    }

    let engagement = snapshot.boardEngagement
    let candidate = engagement?.notebookID
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
        focusedNotebookID: candidate,
        openProgress: open
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
    if let notebookID = presence.focusedNotebookID,
      NotebookDockingField.shouldDock(
        strength: snapshot.dockingStrength,
        isApproaching: snapshot.isApproaching,
        velocity: Double(velocity)
      ),
      let center = model.board?.focusedCenter(of: notebookID)
    {
      let target = SessionPresence(
        mode: .page,
        camera: SpatialCamera(center: center, scale: pageScale),
        viewport: viewport,
        focusedNotebookID: notebookID,
        openProgress: 1
      )
      animateSettlement(to: target, duration: 0.2)
    } else {
      pageGestureActive = false
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
        focusedNotebookID: start.focusedNotebookID,
        openProgress: start.openProgress
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
    renderedNotebooks(presence: presence)
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
    for notebookID: UUID,
    at centroid: CGPoint,
    presence: SessionPresence,
    halo: Double = NotebookOpeningIntent.selectionHalo
  ) -> Double {
    guard let rendered = renderedNotebooks(presence: presence)
      .first(where: { $0.id == notebookID })
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

  private func openNotebook(
    _ notebookID: UUID,
    viewport: SpatialPoint
  ) {
    guard !settling,
      cameraGesture == nil,
      model.presence != nil,
      let center = model.board?.focusedCenter(of: notebookID)
    else { return }
    model.selectNotebook(notebookID)
    let target = SessionPresence(
      mode: .page,
      camera: SpatialCamera(center: center, scale: fitScale(viewport: viewport)),
      viewport: viewport,
      focusedNotebookID: notebookID,
      openProgress: 1
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
      pageGestureActive = false
      settling = false
      settlementTask = nil
    }
  }

  private func createNotebook(
    presence: SessionPresence,
    viewport: SpatialPoint
  ) {
    selectedNotebookID = nil
    let offset = Double(model.workspace?.notebooks.count ?? 0) * 28
    let center = presence.camera.center.offsetBy(x: offset, y: offset)
    guard let notebookID = model.createNotebook(at: center) else { return }
    let target = SessionPresence(
      mode: .cover,
      camera: SpatialCamera(
        center: center,
        scale: coverFocusScale(viewport: viewport)
      ),
      viewport: viewport,
      focusedNotebookID: notebookID,
      openProgress: 0
    )
    animateSettlement(to: target, duration: 0.42)
  }

  private func dropNotebook(
    _ notebookID: UUID,
    at center: WorldPoint,
    presence: SessionPresence
  ) {
    if model.board?.stack(containing: notebookID) != nil {
      model.unstackNotebook(notebookID, at: center)
    } else {
      model.moveNotebook(notebookID, to: center)
    }

    guard let moving = renderedNotebooks(presence: presence)
      .first(where: { $0.id == notebookID })
    else { return }
    let target = renderedNotebooks(presence: presence)
      .reversed()
      .first { candidate in
        guard candidate.id != notebookID else { return false }
        let delta = center.delta(to: candidate.center)
        return abs(delta.x) <= NotebookGeometry.width * 0.6
          && abs(delta.y) <= NotebookGeometry.height * 0.6
      }
    if let target {
      _ = model.stackNotebook(moving.id, onto: target.id)
    }
  }

  private func fitScale(viewport: SpatialPoint) -> Double {
    NotebookPresentation.fitScale(viewport: viewport)
  }

  private func coverFocusScale(viewport: SpatialPoint) -> Double {
    NotebookPresentation.coverScale(viewport: viewport)
  }
}

private struct NotebookSceneItem: View {
  @Environment(NotebookAppModel.self) private var model

  let rendered: RenderedNotebook
  let page: PageDocument?
  let camera: SpatialCamera
  let viewport: SpatialPoint
  let isFocused: Bool
  let preparesPage: Bool
  let openProgress: Double
  let pageIsInteractive: Bool
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

  @State private var dragTranslation = CGSize.zero
  @State private var liftStarted = false

  var body: some View {
    let screen = camera.worldToScreen(rendered.center, viewport: viewport)
    let scale = camera.scale
    let pageContentIsLive = openProgress > 0.001 || pageIsInteractive
    ZStack {
      if preparesPage, let page {
        PageSurface(
          page: page,
          isInteractive: pageIsInteractive,
          isVisible: pageContentIsLive
        )
          .allowsHitTesting(pageIsInteractive)
      }

      ZStack {
        NotebookCoverView(
          notebook: rendered.notebook,
          spatialInkSurfaces: spatialInkSurfaces,
          elements: model.board?.elements.filter {
            $0.surface == .cover(rendered.id)
          } ?? [],
          editingTextID: editingTextID,
          onTap: handleTap,
          onLiftChanged: { lifted in
            if lifted {
              beginLift()
            } else {
              endLift()
            }
          },
          onTranslationChanged: { translation in
            dragTranslation = translation
          },
          onTranslationEnded: { translation in
            finishMove(translation: translation, scale: scale)
          },
          onTextEditingEnded: onTextEditingEnded
        )
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
    .accessibilityIdentifier("notebook-\(rendered.id.uuidString.lowercased())")
    .accessibilityAddTraits(.isButton)
    .accessibilityValue(
      isLifted ? "Готова к перемещению" : (isSelected ? "Выбрана" : "")
    )
  }

  private func handleTap(_ location: CGPoint, tapCount: Int) {
    guard openProgress < 0.12 else { return }
    onSelect(rendered.id)
    if let editingTextID {
      onTextEditingEnded(editingTextID)
    }
    guard tapCount >= 2 else { return }
    if isFocused, model.presence?.mode == .cover {
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

private struct NotebookCoverView: View {
  @Environment(NotebookAppModel.self) private var model

  let notebook: Notebook
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

      if !notebook.title.isEmpty {
        Text(notebook.title)
          .font(.system(size: 38, weight: .medium, design: .rounded))
          .foregroundStyle(Color.black.opacity(0.64))
          .lineLimit(3)
          .frame(width: 570, alignment: .leading)
          .offset(x: 126, y: 170)
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
          surface: .cover(notebook.id),
          journal: model.spatialInk,
          registry: spatialInkSurfaces
        )
        .allowsHitTesting(false)
      #elseif os(macOS)
        SpatialInkSurfaceView(
          drawing: SpatialInkDrawingComposer.drawing(
            for: .cover(notebook.id),
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

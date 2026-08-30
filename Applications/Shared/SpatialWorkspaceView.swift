import PencilKit
import SwiftUI
import TetradCore

private struct CameraGestureSnapshot {
  let presence: SessionPresence
  let startCentroid: CGPoint
  let candidateNotebookID: UUID?
}

struct RenderedNotebook: Identifiable {
  let notebook: Notebook
  let center: WorldPoint
  let zIndex: Double
  let stackID: UUID?

  var id: UUID { notebook.id }
}

struct SpatialWorkspaceView: View {
  @Environment(TetradAppModel.self) private var model

  @State private var cameraGesture: CameraGestureSnapshot?
  @State private var panStart: SessionPresence?
  @State private var pageGestureActive = false
  @State private var settling = false

  var body: some View {
    GeometryReader { geometry in
      let viewport = SpatialPoint(
        x: geometry.size.width,
        y: geometry.size.height
      )
      let presence = normalizedPresence(for: viewport)

      ZStack {
        SpatialBoardGrid(camera: presence.camera)

        #if os(iOS)
          BoardPanView(
            isEnabled: presence.mode != .page && cameraGesture == nil,
            onBegan: { panStart = presence },
            onChanged: { translation in
              updateBoardPan(translation, viewport: viewport)
            },
            onEnded: { translation in
              finishBoardPan(translation, viewport: viewport)
            }
          )
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

        ForEach(renderedNotebooks(presence: presence)) { rendered in
          NotebookSceneItem(
            rendered: rendered,
            page: page(for: rendered.notebook),
            camera: presence.camera,
            viewport: viewport,
            isFocused: presence.focusedNotebookID == rendered.id,
            openProgress: presence.focusedNotebookID == rendered.id
              ? presence.openProgress
              : 0,
            pageIsInteractive: presence.focusedNotebookID == rendered.id
              && (presence.mode == .page || pageGestureActive),
            onDrop: { notebookID, center in
              dropNotebook(notebookID, at: center, presence: presence)
            }
          )
          .zIndex(rendered.zIndex)
        }

        #if os(iOS)
          SpatialInkCanvas(
            camera: presence.camera,
            viewport: viewport,
            notebooks: renderedNotebooks(presence: presence).map {
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
            onCommit: model.appendSpatialInk,
            isEnabled: presence.mode != .page && !pageGestureActive
              && !model.isTextToolSelected
          )
          .opacity(globalInkOpacity(presence))
          .allowsHitTesting(false)

          WorkspaceGestureLayer(
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

  private func sceneAnchoredInkOpacity(
    _ presence: SessionPresence
  ) -> Double {
    #if os(iOS)
      min(max(presence.openProgress * 6, 0), 1)
    #else
      1
    #endif
  }

  private func globalInkOpacity(_ presence: SessionPresence) -> Double {
    #if os(iOS)
      1 - sceneAnchoredInkOpacity(presence)
    #else
      0
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
      let projectedHeight = NotebookGeometry.height * presence.camera.scale
      let fan = min(max((projectedHeight - 160) / 440, 0), 1)
      let count = stack.notebookIDs.count
      for (index, notebookID) in stack.notebookIDs.enumerated() {
        guard let notebook = notebooks[notebookID] else { continue }
        let centered = Double(index) - Double(count - 1) / 2
        let collapsedX = centered * 9 / max(presence.camera.scale, 0.001)
        let collapsedY = -Double(index) * 7 / max(presence.camera.scale, 0.001)
        let fannedX = centered * NotebookGeometry.width * 0.62
        let fannedY = abs(centered) * NotebookGeometry.height * 0.08
        result.append(
          RenderedNotebook(
            notebook: notebook,
            center: stack.center.offsetBy(
              x: collapsedX + (fannedX - collapsedX) * fan,
              y: collapsedY + (fannedY - collapsedY) * fan
            ),
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

  private func handleBoardMagnification(_ phase: WorkspaceMagnificationPhase) {
    guard let presence = model.presence else { return }
    switch phase {
    case .began(let centroid):
      let candidate = focusCandidate(at: centroid, presence: presence)
      cameraGesture = CameraGestureSnapshot(
        presence: presence,
        startCentroid: centroid,
        candidateNotebookID: candidate
      )
      if let candidate { model.selectNotebook(candidate) }
    case .changed(let scale, let centroid):
      updateMagnification(scale: scale, centroid: centroid)
    case .ended(let scale, let velocity, let centroid):
      updateMagnification(scale: scale, centroid: centroid)
      settleMagnification(velocity: velocity)
    case .cancelled:
      cancelMagnification()
    }
  }

  private func handleWorkspaceMagnification(
    _ phase: WorkspaceMagnificationPhase
  ) {
    switch phase {
    case .began:
      if model.presence?.mode == .page {
        handlePageMagnification(phase)
      } else {
        handleBoardMagnification(phase)
      }
    default:
      if cameraGesture?.presence.mode == .page {
        handlePageMagnification(phase)
      } else {
        handleBoardMagnification(phase)
      }
    }
  }

  private func handlePageMagnification(_ phase: WorkspaceMagnificationPhase) {
    switch phase {
    case .began(let centroid):
      guard let presence = model.presence else { return }
      pageGestureActive = true
      cameraGesture = CameraGestureSnapshot(
        presence: presence,
        startCentroid: centroid,
        candidateNotebookID: presence.focusedNotebookID
      )
    case .changed(let scale, let centroid):
      updateMagnification(scale: scale, centroid: centroid)
    case .ended(let scale, let velocity, let centroid):
      updateMagnification(scale: scale, centroid: centroid)
      settleMagnification(velocity: velocity)
    case .cancelled:
      pageGestureActive = false
      cancelMagnification()
    }
  }

  private func updateMagnification(scale: CGFloat, centroid: CGPoint) {
    guard let snapshot = cameraGesture else { return }
    let viewport = snapshot.presence.viewport
    let pageScale = fitScale(viewport: viewport)
    let camera = snapshot.presence.camera.pinched(
      by: Double(scale),
      from: SpatialPoint(
        x: snapshot.startCentroid.x,
        y: snapshot.startCentroid.y
      ),
      to: SpatialPoint(x: centroid.x, y: centroid.y),
      viewport: viewport,
      maximumScale: pageScale
    )

    let candidate = snapshot.candidateNotebookID
      ?? snapshot.presence.focusedNotebookID
    let coverScale = coverFocusScale(viewport: viewport)
    let open = candidate == nil ? 0 : NotebookOpeningTransition.progress(
      cameraScale: camera.scale,
      coverScale: coverScale,
      pageScale: pageScale
    )
    let mode: WorkspaceSemanticMode = open >= 0.999
      ? .page
      : (candidate == nil ? .board : .cover)
    model.updatePresence(
      SessionPresence(
        mode: mode,
        camera: camera,
        viewport: viewport,
        focusedNotebookID: candidate,
        focusedStackID: nil,
        openProgress: open
      ),
      settled: false
    )
  }

  private func settleMagnification(velocity: CGFloat) {
    guard let presence = model.presence else { return }
    cameraGesture = nil
    settling = true
    let viewport = presence.viewport
    let pageScale = fitScale(viewport: viewport)
    let coverScale = coverFocusScale(viewport: viewport)
    let wantsPage = presence.focusedNotebookID != nil
      && (presence.openProgress > 0.46 || velocity > 0.7)
    let wantsCover = presence.focusedNotebookID != nil
      && !wantsPage
      && presence.camera.scale >= coverScale * 0.62

    let target: SessionPresence
    if wantsPage,
      let notebookID = presence.focusedNotebookID,
      let center = renderedNotebooks(presence: presence)
        .first(where: { $0.id == notebookID })?.center
    {
      target = SessionPresence(
        mode: .page,
        camera: SpatialCamera(center: center, scale: pageScale),
        viewport: viewport,
        focusedNotebookID: notebookID,
        openProgress: 1
      )
    } else if wantsCover,
      let notebookID = presence.focusedNotebookID,
      let center = renderedNotebooks(presence: presence)
        .first(where: { $0.id == notebookID })?.center
    {
      target = SessionPresence(
        mode: .cover,
        camera: SpatialCamera(center: center, scale: coverScale),
        viewport: viewport,
        focusedNotebookID: notebookID,
        openProgress: 0
      )
    } else {
      target = SessionPresence(
        mode: .board,
        camera: SpatialCamera(
          center: presence.camera.center,
          scale: min(presence.camera.scale, coverScale * 0.48)
        ),
        viewport: viewport
      )
    }

    withAnimation(.spring(duration: 0.36, bounce: 0.1)) {
      model.updatePresence(target, settled: true)
    }
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(380))
      pageGestureActive = false
      settling = false
    }
  }

  private func cancelMagnification() {
    guard let snapshot = cameraGesture else { return }
    cameraGesture = nil
    withAnimation(.spring(duration: 0.28, bounce: 0.08)) {
      model.updatePresence(snapshot.presence, settled: true)
    }
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
        focusedStackID: start.focusedStackID,
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
    presence: SessionPresence
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
      )
    )
  }

  private func createNotebook(
    presence: SessionPresence,
    viewport: SpatialPoint
  ) {
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
    settling = true
    withAnimation(.spring(duration: 0.42, bounce: 0.08)) {
      model.updatePresence(target, settled: true)
    }
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(440))
      settling = false
    }
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
  @Environment(TetradAppModel.self) private var model

  let rendered: RenderedNotebook
  let page: PageDocument?
  let camera: SpatialCamera
  let viewport: SpatialPoint
  let isFocused: Bool
  let openProgress: Double
  let pageIsInteractive: Bool
  let onDrop: (UUID, WorldPoint) -> Void

  @State private var dragTranslation = CGSize.zero

  var body: some View {
    let screen = camera.worldToScreen(rendered.center, viewport: viewport)
    let scale = camera.scale
    ZStack {
      if isFocused, let page, openProgress > 0.001 || pageIsInteractive {
        if pageIsInteractive {
          PageSurface(page: page)
        } else {
          StaticPageSurface(page: page)
        }
      }

      NotebookCoverView(
        notebook: rendered.notebook,
        isFocused: isFocused,
        elements: model.board?.elements.filter {
          $0.surface == .cover(rendered.id)
        } ?? []
      )
      .rotation3DEffect(
        .degrees(-178 * openProgress),
        axis: (x: 0, y: 1, z: 0),
        anchor: .leading,
        perspective: 0.62
      )
      .opacity(openProgress < 0.54 ? 1 : max(0, 1 - (openProgress - 0.54) / 0.12))
      .allowsHitTesting(openProgress < 0.12)
    }
    .frame(
      width: NotebookGeometry.width,
      height: NotebookGeometry.height
    )
    .scaleEffect(scale)
    .offset(dragTranslation)
    .position(x: screen.x, y: screen.y)
    .shadow(
      color: .black.opacity(0.13 * (1 - openProgress)),
      radius: max(3, 18 * scale),
      y: max(2, 8 * scale)
    )
    #if os(iOS)
      .gesture(
        moveGesture(scale: scale),
        including: openProgress < 0.12 ? .all : .none
      )
    #endif
    .accessibilityIdentifier("notebook-\(rendered.id.uuidString.lowercased())")
  }

  #if os(iOS)
  private func moveGesture(scale: Double) -> some Gesture {
    LongPressGesture(minimumDuration: 0.18, maximumDistance: 18)
      .sequenced(before: DragGesture(minimumDistance: 0))
      .onChanged { value in
        guard openProgress < 0.12 else { return }
        if case .second(true, let drag?) = value {
          dragTranslation = drag.translation
        }
      }
      .onEnded { value in
        guard openProgress < 0.12 else {
          dragTranslation = .zero
          return
        }
        let translation: CGSize
        if case .second(true, let drag?) = value {
          translation = drag.translation
        } else {
          translation = dragTranslation
        }
        let center = rendered.center.offsetBy(
          x: translation.width / max(scale, 0.001),
          y: translation.height / max(scale, 0.001)
        )
        dragTranslation = .zero
        onDrop(rendered.id, center)
      }
  }
  #endif
}

private struct NotebookCoverView: View {
  @Environment(TetradAppModel.self) private var model
  @FocusState private var titleFocused: Bool
  @State private var title = ""

  let notebook: Notebook
  let isFocused: Bool
  let elements: [SpatialElement]

  var body: some View {
    ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: NotebookGeometry.cornerRadius)
        .fill(Color(red: 0.945, green: 0.93, blue: 0.875))
      RoundedRectangle(cornerRadius: NotebookGeometry.cornerRadius)
        .stroke(Color.black.opacity(0.08), lineWidth: 2)
      Rectangle()
        .fill(Color.black.opacity(0.055))
        .frame(width: 18)
        .padding(.vertical, 2)
        .padding(.leading, 24)

      if isFocused {
        TextField("Без названия", text: $title, axis: .vertical)
          .textFieldStyle(.plain)
          .font(.system(size: 38, weight: .medium, design: .rounded))
          .foregroundStyle(Color.black.opacity(0.74))
          .focused($titleFocused)
          .submitLabel(.done)
          .onSubmit(commitTitle)
          .onChange(of: titleFocused) { _, focused in
            if !focused { commitTitle() }
          }
          .frame(width: 570, alignment: .leading)
          .offset(x: 126, y: 170)
      } else {
        Text(notebook.title)
          .font(.system(size: 38, weight: .medium, design: .rounded))
          .foregroundStyle(Color.black.opacity(0.64))
          .lineLimit(3)
          .frame(width: 570, alignment: .leading)
          .offset(x: 126, y: 170)
      }

      ForEach(elements) { element in
        SpatialElementContent(element: element)
          .frame(width: element.frame.width, height: element.frame.height)
          .offset(x: element.frame.x, y: element.frame.y)
      }

      #if os(macOS)
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
    .contentShape(
      RoundedRectangle(cornerRadius: NotebookGeometry.cornerRadius)
    )
    .onAppear {
      title = notebook.title
      focusPendingTitleIfNeeded()
    }
    .onChange(of: notebook.title) { _, newTitle in
      if !titleFocused { title = newTitle }
    }
    .onChange(of: model.pendingTitleFocusID) { _, _ in
      focusPendingTitleIfNeeded()
    }
    #if os(iOS)
      .simultaneousGesture(
        SpatialTapGesture()
          .onEnded { value in
            guard isFocused, model.isTextToolSelected else { return }
            let point = SpatialPoint(
              x: value.location.x,
              y: value.location.y
            )
            guard !elements.contains(where: { $0.frame.contains(point) }) else {
              return
            }
            _ = model.addNativeText(
              on: notebook.id,
              at: SpatialPoint(
                x: min(
                  max(value.location.x, 0),
                  NotebookGeometry.width - 420
                ),
                y: min(
                  max(value.location.y, 0),
                  NotebookGeometry.height - 120
                )
              )
            )
          }
          )
    #endif
  }

  private func commitTitle() {
    let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized.isEmpty {
      title = notebook.title
    } else {
      model.renameNotebook(notebook.id, title: normalized)
    }
  }

  private func focusPendingTitleIfNeeded() {
    guard isFocused, model.pendingTitleFocusID == notebook.id else { return }
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(430))
      titleFocused = true
      model.consumePendingTitleFocus(notebook.id)
    }
  }
}

private struct SpatialElementContent: View {
  @Environment(TetradAppModel.self) private var model
  let element: SpatialElement

  var body: some View {
    switch element.kind {
    case .nativeText:
      NativeTextElementView(element: element)
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
  @Environment(TetradAppModel.self) private var model
  @FocusState private var focused: Bool
  @State private var text: String
  @State private var commitTask: Task<Void, Never>?

  let element: SpatialElement

  init(element: SpatialElement) {
    self.element = element
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
      .onAppear {
        if element.source.isEmpty {
          Task { @MainActor in
            await Task.yield()
            focused = true
          }
        }
      }
      .onChange(of: element.source) { _, source in
        if !focused { text = source }
      }
      .onChange(of: text) { _, _ in scheduleCommit() }
      .onChange(of: focused) { _, isFocused in
        if !isFocused { commit() }
      }
      .onDisappear { commit() }
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

private struct StaticPageSurface: View {
  let page: PageDocument

  var body: some View {
    ZStack(alignment: .topLeading) {
      GridPaperView()
      #if os(iOS)
        StaticPencilDrawingView(page: page)
      #else
        PencilDrawingView(page: page)
      #endif
      AgentOverlayView(elements: page.elements) { _, _ in }
    }
    .frame(width: page.size.width, height: page.size.height)
    .clipped()
  }
}

#if os(iOS)
private struct StaticPencilDrawingView: View {
  let page: PageDocument

  var body: some View {
    if !page.drawingData.isEmpty,
      let drawing = try? PKDrawing(data: page.drawingData)
    {
      Image(
        uiImage: drawing.image(
          from: CGRect(
            x: 0,
            y: 0,
            width: page.size.width,
            height: page.size.height
          ),
          scale: 2
        )
      )
      .resizable()
    }
  }
}
#endif

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

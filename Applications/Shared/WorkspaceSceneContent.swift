import NotebookCore
import SwiftUI

#if os(iOS)
  import UIKit
#elseif os(macOS)
  import AppKit
#endif

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

/// A portal is a read-only projection of the child board, not a decorative
/// cover. It uses the same camera that becomes active at handoff. Recursive
/// drawing follows a pixel threshold and a finite frame budget; the durable
/// hierarchy itself has no depth bound.
struct BoardPortalPreview: View {
  @Environment(NotebookAppModel.self) private var model
  @Environment(\.sceneCompositionCohort) private var cohort
  @State private var spatialInkSurfaces = SpatialInkSurfaceRegistry()

  let boardID: UUID
  let pixelScale: Double
  let remainingPortalPasses: Int
  let transitionViewport: SpatialPoint

  var body: some View {
    if let cohort, let prepared = cohort.plan.presentations[.board(boardID)] {
      // Passage changes the portal's coordinate projection without changing its
      // physical sources. Keep the prepared pixels, but use the same normalized
      // camera that the continuing contact has just handed back to the parent.
      let camera = model.scenePortalCamera(boardID: boardID).map {
        BoardPortalProjection.entryCamera(portalCamera: $0, viewport: transitionViewport)
      } ?? prepared.camera
      let viewport = prepared.viewport
      let presence = SessionPresence(boardID: boardID, mode: .board, camera: camera, viewport: viewport)
      let fill = BoardPortalProjection.fillScale(viewport: transitionViewport)
      let workset = cohort.frame.workset(boardID: boardID)
      let plane = SceneCompositionPlane.board(boardID)
      ZStack {
        SpatialBoardGrid(camera: camera, outputScale: pixelScale / fill)
        ZStack {
          ForEach(cohort.bands(in: plane, layer: .elements)) { band in
            SceneCompositionTileBandView(cohort: cohort, band: band, presence: presence).zIndex(Double(band.rank))
          }
          ForEach(workset.elements.filter { cohort.plan.allowsLive(.element($0.id), in: plane) }) { element in
            if let origin = element.worldOrigin {
              let screen = camera.worldToScreen(origin, viewport: viewport)
              SpatialElementContent(element: element, commitsState: false, boardID: boardID)
                .frame(width: element.frame.width, height: element.frame.height)
                .scaleEffect(camera.scale)
                .frame(width: element.frame.width * camera.scale, height: element.frame.height * camera.scale)
                .position(x: screen.x + (element.frame.x + element.frame.width / 2) * camera.scale,
                  y: screen.y + (element.frame.y + element.frame.height / 2) * camera.scale)
                .zIndex(cohort.plan.rank(id: .element(element.id), in: plane) ?? 0)
            }
          }
        }
        // Passive board ink belongs to the same completed tile cohort. A
        // second Metal owner here would both double-paint it and evade the cap.
        ForEach(cohort.bands(in: plane, layer: .ink)) { band in
          SceneCompositionTileBandView(cohort: cohort, band: band, presence: presence)
        }
        ZStack {
          ForEach(cohort.bands(in: plane, layer: .covers)) { band in
            SceneCompositionTileBandView(cohort: cohort, band: band, presence: presence).zIndex(Double(band.rank))
          }
          ForEach(workset.items.filter { cohort.plan.allowsLive(.item($0.id), in: plane) }) { item in
            let screen = camera.worldToScreen(item.center, viewport: viewport)
            WorkspaceItemCoverView(
              item: item.item, geometry: item.geometry, spatialInkSurfaces: spatialInkSurfaces,
              elements: cohort.frame.covers[item.id]?.elements ?? [],
              editingTextID: nil, isElementEditingEnabled: false,
              portalOpenProgress: 0, portalViewport: transitionViewport,
              onTap: { _, _ in }, onLiftChanged: { _ in },
              onTranslationChanged: { _ in }, onTranslationEnded: { _ in },
              onTextEditingEnded: { _ in }, onElementSelected: {},
              isPortalProjection: true, portalPixelScale: pixelScale * camera.scale / fill,
              remainingPortalPasses: remainingPortalPasses - 1)
              .frame(width: item.geometry.width, height: item.geometry.height)
              .background { WorkspaceItemShadow(geometry: item.geometry) }
              .scaleEffect(camera.scale).position(x: screen.x, y: screen.y)
              .zIndex(cohort.plan.rank(id: .item(item.id), in: plane) ?? 0)
          }
        }
      }
      .environment(\.workspaceSceneFrame, cohort.frame)
      .frame(width: viewport.x, height: viewport.y)
      .scaleEffect(1 / fill)
      .frame(width: WorkspaceItemGeometry.notebook.width, height: WorkspaceItemGeometry.notebook.height)
      .clipped().allowsHitTesting(false).accessibilityHidden(true)
    } else {
      Color(red: 0.94, green: 0.95, blue: 0.945)
        .overlay { ProgressView("Подготовка области").font(.caption) }
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
  @Environment(\.sceneCompositionCohort) private var cohort

  let item: WorkspaceItem
  let geometry: WorkspaceItemGeometry
  let spatialInkSurfaces: SpatialInkSurfaceRegistry
  let elements: [SpatialElement]
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
    let plane = cohort?.plan.liveOwners.first(where: { $0.id == .item(item.id) }).map {
      SceneCompositionPlane.cover(boardID: $0.plane.boardID, itemID: item.id)
    }
    ZStack(alignment: .topLeading) {
      coverBackground.zIndex(-2)
      WorkspaceCoverTitle(item: item, geometry: geometry).zIndex(-1)
      if let cohort, let plane, let presentation = cohort.plan.presentations[plane] {
        ForEach(cohort.bands(in: plane, layer: .elements)) { band in
          SceneCompositionTileBandView(cohort: cohort, band: band, presence: presentation)
            .zIndex(Double(band.rank)).opacity(portalOverlayOpacity)
        }
      }
      ForEach(elements.filter { element in
        guard let cohort, let plane else { return true }
        return cohort.plan.allowsLive(.element(element.id), in: plane)
      }) { element in
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
        .zIndex(plane.flatMap { cohort?.plan.rank(id: .element(element.id), in: $0) } ?? 0)
      }

      #if os(iOS)
        if (!isElementEditingEnabled || model.isItemBeingDeleted(item.id)) && !isPortalProjection {
          NotebookInteractionView(
            permitsManipulation: !model.scenePreparationPending && !model.isItemBeingDeleted(item.id),
            canBeginContact: { !model.isItemBeingDeleted(item.id) },
            passthroughFrames: model.isItemBeingDeleted(item.id) ? [] : interactionPassthroughFrames,
            onTap: { location, count in
              guard !model.isItemBeingDeleted(item.id) else { return }
              // Finishing a text session does not need the next geometry index.
              // Keep this input owner mounted while the saved text is prepared.
              if model.scenePreparationPending {
                if let editingTextID { onTextEditingEnded(editingTextID) }
                return
              }
              onTap(location, count)
            },
            onLiftChanged: { lifted in
              guard !lifted || (!model.scenePreparationPending && !model.isItemBeingDeleted(item.id)) else { return }
              onLiftChanged(lifted)
            },
            onTranslationChanged: { translation in
              guard !model.scenePreparationPending, !model.isItemBeingDeleted(item.id) else { return }
              onTranslationChanged(translation)
            },
            onTranslationEnded: { translation in
              guard !model.isItemBeingDeleted(item.id) else { return }
              onTranslationEnded(model.scenePreparationPending ? .zero : translation)
            }
          )
          .frame(
            width: geometry.width,
            height: geometry.height
          )
          .accessibilityHidden(true).zIndex(1_001)
        }
      #endif

      #if os(iOS)
        SpatialInkSurfaceView(
          surface: .cover(item.id),
          journal: model.renderingInk(on: .cover(item.id), fallback: cohort?.liveData.ink ?? model.spatialInk),
          registry: spatialInkSurfaces
        )
        .allowsHitTesting(false)
        .opacity(portalOverlayOpacity).zIndex(1_000)
      #elseif os(macOS)
        SpatialInkSurfaceView(surface: .cover(item.id), journal: model.renderingInk(on: .cover(item.id), fallback: cohort?.liveData.ink ?? model.spatialInk))
          .allowsHitTesting(false).opacity(portalOverlayOpacity).zIndex(1_000)
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
    .overlay {
      if model.isItemBeingDeleted(item.id), !isPortalProjection {
        ProgressView("Удаление")
          .padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
          .allowsHitTesting(false)
      }
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


private struct SceneCompositionCohortKey: EnvironmentKey {
  static let defaultValue: SceneCompositionCohort? = nil
}
extension EnvironmentValues {
  var sceneCompositionCohort: SceneCompositionCohort? {
    get { self[SceneCompositionCohortKey.self] }
    set { self[SceneCompositionCohortKey.self] = newValue }
  }
}

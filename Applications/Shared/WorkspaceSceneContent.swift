import NotebookCore
import SwiftUI

#if os(iOS)
  import UIKit
#elseif os(macOS)
  import AppKit
#endif

struct RenderedWorkspaceItem: Identifiable, Equatable, Sendable {
  let item: WorkspaceItem
  let geometry: WorkspaceItemGeometry
  let center: WorldPoint
  let zIndex: Double
  let stackID: UUID?

  var id: UUID { item.id }
}

enum WorkspaceSceneProjection {
  static let portalPasses = 32

  /// Opening is a local presentation, not a durable move or a finger lift.
  /// Keep its existing native body above every passive cover band, below an
  /// explicitly lifted body. Closing restores the unchanged source order.
  static func presentationRank(of item: RenderedWorkspaceItem, in presence: SessionPresence,
    liftRank: Double? = nil) -> Double? {
    if let liftRank { return liftRank }
    guard item.item.kind != .board, presence.focusedItemID == item.id,
      presence.openProgress > 0 else { return nil }
    return Double(SceneCompositionPlan.maximumLiveOwners * 2 + 1)
  }

  static func isPaintedBelow(_ left: RenderedWorkspaceItem, _ right: RenderedWorkspaceItem,
    in presence: SessionPresence) -> Bool {
    let a = presentationRank(of: left, in: presence), b = presentationRank(of: right, in: presence)
    if a != b { return (a ?? -1) < (b ?? -1) }
    return ScenePaintPosition(layer: .covers, zIndex: left.zIndex, key: left.id.uuidString)
      < ScenePaintPosition(layer: .covers, zIndex: right.zIndex, key: right.id.uuidString)
  }

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
  @Environment(\.sceneComposition) private var composition
  private var cohort: SceneCompositionCohort? { composition.cohort }

  let boardID: UUID
  let spatialInkSurfaces: SpatialInkSurfaceRegistry
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
      let graph=model.presentedGraphicGraph(boardID:boardID,cohort:cohort,preview:false)
      ZStack {
        SpatialBoardGrid(camera: camera, outputScale: pixelScale / fill)
        ZStack {
          ForEach(SceneCompositionTileBandView.bands(in: cohort, plane: plane, layer: .elements, presence: presence)) { band in
            band.zIndex(Double(band.rank))
          }
          ForEach(cohort.plan.vectorRuns.filter { $0.plane == plane }) { run in
            NotebookGraphicBatchView(run: run, elements: workset.elements,
              graph: graph,
              scale: camera.scale, size: .init(width: viewport.x, height: viewport.y),
              projectOrigin: { camera.worldToScreen($0, viewport: viewport).cgPoint }, commitsState: false)
              .zIndex(cohort.plan.rank(id: run.id.id, in: plane) ?? 0)
          }
          ForEach(workset.elements.filter { $0.kind != .group && $0.graphic == nil && cohort.plan.allowsLive(.element($0.id), in: plane) }) { element in
            if let placement=graph.placement(element.id) {
              let presentation=NotebookElementPresentation(element,placement:placement),local=presentation.frame
              let screen = camera.worldToScreen(placement.origin, viewport: viewport)
              NotebookPlacedElement(presentation:presentation) {
                SpatialElementContent(element: element, commitsState: false, boardID: boardID)
              }
                .frame(width: local.width, height: local.height)
                .scaleEffect(camera.scale)
                .frame(width: local.width * camera.scale, height: local.height * camera.scale)
                .position(x: screen.x + (local.x + local.width / 2) * camera.scale,
                  y: screen.y + (local.y + local.height / 2) * camera.scale)
                .zIndex(cohort.plan.rank(id: .element(element.id), in: plane) ?? 0)
            }
          }
        }
        #if os(iOS)
          SpatialBoardInkView(cohort: cohort, boardID: boardID, camera: camera)
        #else
          ForEach(SceneCompositionTileBandView.bands(in: cohort, plane: plane, layer: .ink, presence: presence)) { band in
            band
          }
        #endif
        ZStack {
          ForEach(SceneCompositionTileBandView.bands(in: cohort, plane: plane, layer: .covers, presence: presence)) { band in
            band.zIndex(Double(band.rank))
          }
          ForEach(workset.items.filter { cohort.plan.allowsLive(.item($0.id), in: plane) }) { item in
            let screen = camera.worldToScreen(item.center, viewport: viewport)
            WorkspaceItemCoverView(
              item: item.item, boardID: boardID, geometry: item.geometry, spatialInkSurfaces: spatialInkSurfaces,
              elements: cohort.frame.covers[item.id]?.elements ?? [],
              editingTextID: nil,
              portalOpenProgress: 0, portalViewport: transitionViewport,
              onTap: { _, _ in },
              onTextEditingEnded: { _ in },
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

struct WorkspaceItemCoverView: View {
  @Environment(NotebookAppModel.self) private var model
  @Environment(\.sceneComposition) private var composition
  private var cohort: SceneCompositionCohort? { composition.cohort }
  #if os(iOS)
    @Environment(\.workspaceItemPose) private var pose
  #endif

  let item: WorkspaceItem
  let boardID: UUID
  let geometry: WorkspaceItemGeometry
  let spatialInkSurfaces: SpatialInkSurfaceRegistry
  let elements: [SpatialElement]
  let editingTextID: String?
  let portalOpenProgress: Double
  let portalViewport: SpatialPoint
  let onTap: (CGPoint, Int) -> Void
  let onTextEditingEnded: (String) -> Void
  var showsDepth = true
  var isPortalProjection = false
  var portalPixelScale: Double = 1
  var remainingPortalPasses = WorkspaceSceneProjection.portalPasses

  var body: some View {
    let plane = cohort?.plan.liveOwners.first(where: { $0.id == .item(item.id) }).map {
      SceneCompositionPlane.cover(boardID: $0.plane.boardID, itemID: item.id)
    }
    let graph = cohort.map { model.presentedGraphicGraph(boardID:boardID,cohort:$0,preview:!isPortalProjection) }
      ?? model.boardHierarchy?.board(boardID)?.graphicGraph()
    ZStack(alignment: .topLeading) {
      coverBackground.zIndex(-2)
      WorkspaceCoverTitle(item: item, geometry: geometry).zIndex(-1)
      if let cohort, let plane, let presentation = cohort.plan.presentations[plane] {
        ForEach(SceneCompositionTileBandView.bands(in: cohort, plane: plane, layer: .elements, presence: presentation)) { band in
          band.zIndex(Double(band.rank)).opacity(portalOverlayOpacity)
        }
      }
      if let cohort, let plane, let graph {
        ForEach(cohort.plan.vectorRuns.filter { $0.plane == plane }) { run in
          NotebookGraphicBatchView(run: run, elements: elements, graph: graph, scale: 1,
            size: .init(width: geometry.width, height: geometry.height), projectOrigin: { _ in .zero },
            commitsState: !isPortalProjection)
            .opacity(portalOverlayOpacity)
            .zIndex(cohort.plan.rank(id: run.id.id, in: plane) ?? 0)
        }
      }
      if !isPortalProjection, let cohort, let plane, let graph,
        let run = model.workingGraphicRun(plane:plane,cohort:cohort) {
        NotebookGraphicBatchView(run:run,
          elements:model.workingGraphics(on:.cover(item.id),cohort:cohort).map { $0.spatialElement(stamp:.init(counter:0,actor:model.actorID)) },
          graph:graph,scale:1,size:.init(width:geometry.width,height:geometry.height),projectOrigin:{ _ in .zero },commitsState:false)
          .opacity(portalOverlayOpacity).zIndex(Double.greatestFiniteMagnitude)
      }
      ForEach(elements.filter { element in
        if element.graphic != nil || element.kind == .group { return false }
        guard let cohort, let plane else { return true }
        return cohort.plan.allowsLive(.element(element.id), in: plane)
      }) { element in
        let reference = EditableElementReference.spatial(boardID: boardID, elementID: element.id)
        if let placement=graph?.placement(element.id) {
        let presentation=(!isPortalProjection ? model.elementPresentation(reference,graph:graph) : nil) ?? NotebookElementPresentation(element,placement:placement),local=presentation.frame
        let retainsTextInput = !isPortalProjection
          && element.kind == .nativeText && editingTextID == element.id
        EditableElementContainer(reference: reference) {
          NotebookPlacedElement(presentation:presentation) {
          SpatialElementContent(
            element: element, commitsState: !isPortalProjection,
            boardID: boardID,
            isTextEditing: retainsTextInput,
            onTextEditingEnded: { onTextEditingEnded(element.id) }
          )
          }
        }
        .allowsHitTesting(ownerIsAvailable)
        .frame(width: local.width, height: local.height)
        .offset(x: local.x, y: local.y)
        .opacity(portalOverlayOpacity)
        .zIndex(plane.flatMap { cohort?.plan.rank(id: .element(element.id), in: $0) } ?? 0)
        }
      }

      #if os(iOS)
        if !isPortalProjection {
          NotebookInteractionView(
            inputGate: model.inputGate,
            ownerIsAvailable: { ownerIsAvailable },
            passesThrough: { point in
              guard !model.isItemBeingDeleted(item.id),let presence=model.presence,let cohort else { return false }
              if let selected=NotebookAttentionProjection.selectedElement(at:point,model:model,presence:presence,cohort:cohort),
                (model.selectionSession.region?.address.target ?? model.nativeElementSource(selected)?.target)
                  == CollaborationTarget(kind:.cover,id:item.id,boardID:boardID) { return true }
              switch NotebookAttentionProjection.pointResolution(at:point,model:model,presence:presence,cohort:cohort) {
              case .pending: return true
              case .hit(let hit):
                return hit.target == CollaborationTarget(kind:.cover,id:item.id,boardID:boardID) && hit.elementID != nil
              case nil: return false
              }
            },
            onTap: onTap,
            onLiftChanged: { lifted in
              if lifted { pose?.owner?.beginLift() }
            },
            onTranslationChanged: { translation in
              pose?.owner?.changeTranslation(translation)
            },
            onTranslationEnded: { translation in
              pose?.owner?.endTranslation(translation)
            },
            onCancelled: { pose?.owner?.cancelManipulation() }
          )
          .frame(
            width: geometry.width,
            height: geometry.height
          )
          .accessibilityHidden(true).zIndex(1_001)
        }
      #endif

      #if os(iOS)
        if let cohort {
          SpatialInkSurfaceView(surface: .cover(item.id), cohort: cohort,
            boardID: cohort.plan.liveOwners.first(where: { $0.id == .item(item.id) })?.plane.boardID ?? cohort.plan.rootBoardID,
            isActive: !isPortalProjection)
            .allowsHitTesting(false).opacity(portalOverlayOpacity).zIndex(1_000)
        }
      #elseif os(macOS)
        SpatialInkSurfaceView(surface: .cover(item.id), journal: model.renderingInk(on: .cover(item.id), fallback: cohort?.liveData.ink ?? model.spatialInk))
          .allowsHitTesting(false).opacity(portalOverlayOpacity).zIndex(1_000)
      #endif
    }
    .coordinateSpace(name: NotebookManipulationSpace.material)
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
  }

  private var portalOverlayOpacity: Double {
    item.kind == .board ? max(0, 1 - portalOpenProgress) : 1
  }

  private var portalCornerRadius: Double {
    item.kind == .board
      ? geometry.cornerRadius * max(0, 1 - portalOpenProgress)
      : geometry.cornerRadius
  }


  @ViewBuilder
  private var coverBackground: some View {
    if item.kind == .board {
      if WorkspaceSceneProjection.showsPortal(
        pixelScale: portalPixelScale, remainingPasses: remainingPortalPasses
      ) {
        AnyView(BoardPortalPreview(
          boardID: item.id,
          spatialInkSurfaces: spatialInkSurfaces,
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

  private var ownerIsAvailable: Bool {
    guard !isPortalProjection, !model.isItemBeingDeleted(item.id) else { return false }
    #if os(iOS)
      return !spatialInkSurfaces.isRetired(.cover(item.id))
    #else
      return true
    #endif
  }


}

struct SpatialElementContent: View {
  @Environment(NotebookAppModel.self) private var model
  @Environment(\.sceneComposition) private var composition
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
    precondition(element.kind != .graphic, "Native graphics belong to the scene's vector runs")
    self.element = element
    self.commitsState = commitsState
    self.boardID = boardID
    self.isTextEditing = isTextEditing
    self.onTextEditingEnded = onTextEditingEnded
  }

  var body: some View {
    let cuts = model.elementErasures(on:element.surface,fallback:composition.cohort?.liveData.ink)[element.id] ?? []
    let appearance = model.elementErasureCache.appearance(surface:element.surface,id:element.id,graphic:nil,layout:nil,
      size:.init(width:element.basis?.size.x ?? element.frame.width,height:element.basis?.size.y ?? element.frame.height),erasures:cuts,prepares:!model.isElementErasing(element.id,on:element.surface))
    let erased = appearance?.state == .erased
    content.erased(by:cuts,appearance:appearance)
      .environment(\.inkMaterialReadiness, materialReadiness)
      .accessibilityHidden(erased || (!cuts.isEmpty && appearance == nil))
      .allowsHitTesting(!erased && (cuts.isEmpty || appearance != nil))
  }

  private var materialReadiness: NotebookInkMaterialReceiver? {
    guard let boardID,let cohort=composition.cohort else { return nil }
    let plane:SceneCompositionPlane = element.surface.kind == .cover
      ? .cover(boardID:boardID,itemID:element.surface.ownerID!) : .board(boardID)
    return .init(id:cohort.paintID,report:{ id,content,ready in
      cohort.recordMaterial(.init(plane:plane,elementID:element.id),id:id,content:content,ready:ready)
    })
  }

  @ViewBuilder private var content: some View {
    switch element.kind {
    case .graphic, .group: EmptyView()
    case .nativeText:
      NotebookNativeTextView(source:element.source,style:element.textStyle,
        reference:.spatial(boardID:sourceBoardID ?? WorkspaceRoot.boardID,elementID:element.id),
        isEditing:isTextEditing && commitsState && sourceBoardID != nil,onEditingEnded:onTextEditingEnded,retainedSpatial:element,
        draftTarget:model.nativeTextTarget(.spatial(boardID:sourceBoardID ?? WorkspaceRoot.boardID,elementID:element.id)))
    case .markdown, .web:
      let sourceBoardID = self.sourceBoardID
      PreparedAgentElementView(element: agentElement,
        allowsInteraction: commitsState && sourceBoardID != nil,
        focus: .board(boardID: sourceBoardID ?? WorkspaceRoot.boardID, elementID: element.id), onRenderReady: { _ in },
        onState: { state in
          guard commitsState, let sourceBoardID else { return false }
          return model.commitSpatialElementState(boardID: sourceBoardID, rendered: element, state: state)
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

func agentElementSnapshotSource(_ element:AgentElement) -> AgentElement {
  .init(id:element.id,kind:element.kind,
    frame:.init(x:0,y:0,width:element.basis?.size.x ?? element.frame.width,height:element.basis?.size.y ?? element.frame.height),
    source:element.source,html:element.html,css:element.css,javaScript:element.javaScript,
    programPackage:element.programPackage,state:element.state,graphic:element.graphic,textStyle:element.textStyle)
}

func agentElementSnapshotSource(_ element: SpatialElement) -> AgentElement {
  AgentElement(
    id: element.id,
    kind: element.kind == .markdown ? .markdown : .web,
    frame: PageRect(
      x: 0,
      y: 0,
      width: element.basis?.size.x ?? element.frame.width,
      height: element.basis?.size.y ?? element.frame.height
    ),
    source: element.source,
    html: element.html,
    css: element.css,
    javaScript: element.javaScript,
    programPackage: element.programPackage,
    state: element.state
  )
}

struct SpatialTextSnapshot: View {
  let element: SpatialElement

  var body: some View {
    Self.text(element)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  static func text(_ element: SpatialElement, mask: Bool = false) -> Text {
    let attributed = NSMutableAttributedString(attributedString:NotebookTextTypography.attributed(element.source,style:element.textStyle))
    if mask {
      #if os(iOS)
      let white = UIColor.white.withAlphaComponent(element.textStyle.alpha)
      #else
      let white = NSColor.white.withAlphaComponent(element.textStyle.alpha)
      #endif
      attributed.addAttribute(.foregroundColor,value:white,range:.init(location:0,length:attributed.length))
    }
    return Text(AttributedString(attributed))
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


/// UIKit copies the SwiftUI environment into cached trait collections. Those
/// copies may outlive an unmounted view; they locate, but never own, its paint.
/// The published cohort and concrete tile/ink views retain their actual leases.
struct SceneCompositionReference: Equatable, Sendable {
  let id: UUID?
  private(set) weak var cohort: SceneCompositionCohort?

  init() { id = nil; cohort = nil }

  @MainActor
  init(_ cohort: SceneCompositionCohort?) {
    id = cohort?.paintID; self.cohort = cohort
  }

  static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

private struct SceneCompositionKey: EnvironmentKey {
  static let defaultValue = SceneCompositionReference()
}
extension EnvironmentValues {
  var sceneComposition: SceneCompositionReference {
    get { self[SceneCompositionKey.self] }
    set { self[SceneCompositionKey.self] = newValue }
  }
}

import Foundation
import NotebookCore

/// The object created by a Pencil hold. Its identity and geometry survive lift;
/// persistence acknowledges this object rather than creating a second picture.
struct NotebookWorkingGraphic: Equatable, Identifiable {
  let strokeID: UUID
  let surface: SurfaceID
  let frame: PageRect
  let worldOrigin: WorldPoint?
  let graphic: NotebookGraphic
  var accepted = false
  var publicationCursor: UInt64?
  var id: String { strokeID.uuidString.lowercased() }

  init(strokeID: UUID, fit: NotebookQuickShapeFit, surface: SurfaceID,
    worldOrigin: WorldPoint? = nil, color: SpatialInkColor, width: Double) {
    self.strokeID = strokeID; self.surface = surface; self.frame = fit.frame
    self.worldOrigin = worldOrigin
    graphic = .init(shape: fit.shape, style: .init(stroke: color, strokeWidth: width),
      sourceInkIDs: fit.precedingStrokeIDs + [strokeID], connection: fit.connection)
  }

  var pageElement: AgentElement {
    .init(id: id, kind: .graphic, frame: frame, source: "", html: "", graphic: graphic)
  }

  func spatialElement(stamp: VersionStamp) -> SpatialElement {
    .init(id: id, surface: surface, kind: .graphic,
      frame: .init(x: frame.x, y: frame.y, width: frame.width, height: frame.height),
      worldOrigin: worldOrigin, source: "", graphic: graphic, stamp: stamp)
  }

  var node: NotebookGraphicGraph.Node {
    .init(id: id, graphic: graphic, frame: frame, origin: worldOrigin ?? .zero,
      surface: surface, shown: true)
  }
}

extension NotebookAppModel {
  func updateWorkingGraphic(_ graphic: NotebookWorkingGraphic?, strokeID: UUID) {
    // Late cancellation belongs to the old contact, never to accepted input.
    guard workingGraphics.first(where: { $0.strokeID == strokeID })?.accepted != true else { return }
    if let index = workingGraphics.firstIndex(where: { $0.strokeID == strokeID }) {
      if let graphic { workingGraphics[index] = graphic }
      else { workingGraphics.remove(at: index) }
    } else if let graphic { workingGraphics.append(graphic) }
  }

  func pageElementsForDisplay(_ page: PageDocument) -> [AgentElement] {
    let working = workingGraphics.filter { $0.surface == .page(page.id) }
    guard !working.isEmpty else { return page.elements }
    let ids = Set(working.map(\.id))
    return page.elements.filter { !ids.contains($0.id) } + working.map(\.pageElement)
  }

  func pageSuppressedInkIDs(_ page: PageDocument) -> Set<UUID> {
    page.graphicPresentation.suppressedInkIDs.union(
      workingGraphics.filter { $0.surface == .page(page.id) }.flatMap { $0.graphic.sourceInkIDs })
  }

  func workingBoardGraphics(boardID: UUID, cohort: SceneCompositionCohort) -> [NotebookWorkingGraphic] {
    workingGraphics.filter { graphic in
      graphic.surface == .board(boardID)
        && (graphic.publicationCursor.map { cohort.plan.revision < $0 } ?? true)
    }
  }

  /// One temporary vector run in the existing element plane, below ink/covers.
  /// It uses the ordinary graphic painter, not an input-layer preview renderer.
  func workingGraphicRun(boardID: UUID, cohort: SceneCompositionCohort) -> SceneCompositionVectorRun? {
    let owners = workingBoardGraphics(boardID: boardID, cohort: cohort).map { graphic in
      SceneCompositionLiveOwner(plane: .board(boardID), id: .element(graphic.id),
        position: .init(layer: .elements, zIndex: Double.greatestFiniteMagnitude, key: graphic.id))
    }
    return owners.isEmpty ? nil : .init(plane: .board(boardID), owners: owners)
  }

  func retireWorkingGraphics(in cohort: SceneCompositionCohort) {
    guard cohort.isPaintInstalled else { return }
    workingGraphics.removeAll { graphic in
      graphic.surface.kind == .board
        && (graphic.publicationCursor.map { cohort.plan.revision >= $0 } ?? false)
    }
  }
}

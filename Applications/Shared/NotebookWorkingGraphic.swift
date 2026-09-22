import Foundation
import NotebookCore
import Observation

@MainActor @Observable
final class NotebookWorkingGraphicSignal { fileprivate(set) var revision:UInt64=0 }

/// The object created by a Pencil hold. Its identity and geometry survive lift;
/// persistence acknowledges this object rather than creating a second picture.
struct NotebookWorkingGraphic: Equatable, Identifiable, Sendable {
  let strokeID: UUID
  let surface: SurfaceID
  let frame: PageRect
  let worldOrigin: WorldPoint?
  let graphic: NotebookGraphic
  let basis: NotebookElementBasis?
  var accepted = false
  var publicationCursor: UInt64?
  var id: String { strokeID.uuidString.lowercased() }

  init(strokeID: UUID, fit: NotebookQuickShapeFit, surface: SurfaceID,
    worldOrigin: WorldPoint? = nil, color: SpatialInkColor, width: Double) {
    self.strokeID = strokeID; self.surface = surface; self.frame = fit.frame
    self.worldOrigin = worldOrigin; basis = nil
    graphic = .init(shape: fit.shape, style: .init(stroke: color, strokeWidth: width),
      sourceInkIDs: fit.precedingStrokeIDs + [strokeID], connection: fit.connection, vertices: fit.vertices)
  }

  init(id: UUID, surface: SurfaceID, frame: PageRect, worldOrigin: WorldPoint?, graphic: NotebookGraphic,
    basis:NotebookElementBasis? = nil) {
    strokeID = id; self.surface = surface; self.frame = frame; self.worldOrigin = worldOrigin
    self.graphic = graphic; self.basis = basis
  }

  var pageElement: AgentElement {
    .init(id: id, kind: .graphic, frame: frame, source: "", html: "", graphic: graphic,basis:basis)
  }

  func spatialElement(stamp: VersionStamp) -> SpatialElement {
    .init(id: id, surface: surface, kind: .graphic,
      frame: .init(x: frame.x, y: frame.y, width: frame.width, height: frame.height),
      worldOrigin: worldOrigin, source: "", graphic: graphic,basis:basis, stamp: stamp)
  }

  var node: NotebookGraphicGraph.Node {
    let raw=NotebookElementPlacement(id:id,frame:frame,origin:worldOrigin ?? .zero)
    let placement=(try? raw.updating(frame:frame,basis:basis)) ?? raw
    return .init(id: id, graphic: graphic, frame: frame, origin: worldOrigin ?? .zero,
      surface: surface, shown: true,placement:placement)
  }

  /// One durable representation for every accepted working graphic. The
  /// working object owns its placement; callers only choose the addressed
  /// command target and must not reconstruct a second origin or basis.
  func authoredValues() throws -> [String: JSONValue] {
    var values: [String: JSONValue] = [
      "kind": .string("graphic"),
      "source": .string(""),
      "frame": try .encode(frame),
      "graphic": try .encode(graphic)
    ]
    if let worldOrigin { values["worldOrigin"] = try .encode(worldOrigin) }
    if let basis { values["basis"] = try .encode(basis) }
    return values
  }
}

extension NotebookAppModel {
  func workingGraphicRevision(on surface:SurfaceID)->UInt64 {
    let signal=workingGraphicSignals[surface] ?? {
      let value=NotebookWorkingGraphicSignal();workingGraphicSignals[surface]=value;return value
    }()
    return signal.revision
  }

  func didChangeWorkingGraphics(on surfaces:Set<SurfaceID>) {
    for surface in surfaces {
      let signal=workingGraphicSignals[surface] ?? {
        let value=NotebookWorkingGraphicSignal();workingGraphicSignals[surface]=value;return value
      }()
      signal.revision &+= 1
      if surface.kind == .cover,let item=surface.ownerID,
        let board=boardHierarchy?.ownerBoardID(of:item) {
        let owner:SurfaceID = .board(board)
        let boardSignal=workingGraphicSignals[owner] ?? {
          let value=NotebookWorkingGraphicSignal();workingGraphicSignals[owner]=value;return value
        }()
        boardSignal.revision &+= 1
      }
    }
  }

  /// Rendering may retain an insertion until its raster is installed. Authoring
  /// stops overlaying that original as soon as the logical model admits it.
  var pendingModelGraphics: [NotebookWorkingGraphic] {
    workingGraphics.filter { $0.accepted && ($0.publicationCursor.map { sceneContentCursor < $0 } ?? true) }
  }

  func acceptedWorkingGraphic(_ reference: EditableElementReference) -> NotebookWorkingGraphic? {
    pendingModelGraphics.first { graphic in
      switch reference {
      case .page(let owner,let id): return graphic.surface == .page(owner) && graphic.id == id
      case .spatial(let board,let id): return graphic.id == id && (graphic.surface == .board(board) ||
        (graphic.surface.kind == .cover && graphic.surface.ownerID.flatMap { boardHierarchy?.ownerBoardID(of:$0) } == board))
      }
    }
  }

  func updateWorkingGraphic(_ graphic: NotebookWorkingGraphic?, strokeID: UUID) {
    // Late cancellation belongs to the old contact, never to accepted input.
    guard workingGraphics.first(where: { $0.strokeID == strokeID })?.accepted != true else { return }
    var changed=Set<SurfaceID>()
    if let index = workingGraphics.firstIndex(where: { $0.strokeID == strokeID }) {
      changed.insert(workingGraphics[index].surface)
      if let graphic { workingGraphics[index] = graphic }
      else { workingGraphics.remove(at: index) }
    } else if let graphic { workingGraphics.append(graphic);changed.insert(graphic.surface) }
    if let graphic { changed.insert(graphic.surface) }
    if !changed.isEmpty { didChangeWorkingGraphics(on:changed) }
  }

  func acceptWorkingGraphics(_ values:[NotebookWorkingGraphic]) {
    guard !values.isEmpty else { return }
    let ids=Set(values.map(\.strokeID))
    guard workingGraphics.allSatisfy({ !ids.contains($0.strokeID) || !$0.accepted }) else { return }
    var changed=Set(workingGraphics.filter { ids.contains($0.strokeID) }.map(\.surface))
    workingGraphics.removeAll { ids.contains($0.strokeID) }
    workingGraphics.append(contentsOf:values.map { value in var value=value;value.accepted=true;return value })
    changed.formUnion(values.map(\.surface))
    didChangeWorkingGraphics(on:changed)
  }

  @discardableResult
  func removeWorkingGraphics(where removes:(NotebookWorkingGraphic)->Bool)->Bool {
    let changed=Set(workingGraphics.filter(removes).map(\.surface))
    guard !changed.isEmpty else { return false }
    workingGraphics.removeAll(where:removes);didChangeWorkingGraphics(on:changed);return true
  }

  func pageElementsForDisplay(_ page: PageDocument) -> [AgentElement] {
    _ = workingGraphicRevision(on:.page(page.id))
    let working = workingGraphics.filter { $0.surface == .page(page.id) }
    guard !working.isEmpty else { return page.elements }
    let ids = Set(working.map(\.id))
    return page.elements.filter { !ids.contains($0.id) } + working.map(\.pageElement)
  }

  func pageSuppressedInkIDs(_ page: PageDocument) -> Set<UUID> {
    _ = workingGraphicRevision(on:.page(page.id))
    return page.graphicPresentation.suppressedInkIDs.union(
      workingGraphics.filter { $0.surface == .page(page.id) }.flatMap { $0.graphic.sourceInkIDs })
  }

  func workingGraphics(on surface: SurfaceID, cohort: SceneCompositionCohort) -> [NotebookWorkingGraphic] {
    _ = workingGraphicRevision(on:surface)
    return workingGraphics.filter { graphic in
      graphic.surface == surface
        && (graphic.publicationCursor.map { cohort.plan.revision < $0 } ?? true)
    }
  }

  /// One temporary vector run in the existing element plane, below ink/covers.
  /// It uses the ordinary graphic painter, not an input-layer preview renderer.
  func workingGraphicRun(plane: SceneCompositionPlane, cohort: SceneCompositionCohort) -> SceneCompositionVectorRun? {
    let surface = plane.coverID.map(SurfaceID.cover) ?? .board(plane.boardID)
    let owners = workingGraphics(on:surface, cohort: cohort).map { graphic in
      SceneCompositionLiveOwner(plane: plane, id: .element(graphic.id),
        position: .init(layer: .elements, zIndex: Double.greatestFiniteMagnitude, key: graphic.id))
    }
    return owners.isEmpty ? nil : .init(plane: plane, owners: owners)
  }

  func retireWorkingGraphics(in cohort: SceneCompositionCohort) {
    guard !workingGraphics.isEmpty, cohort.isPaintInstalled else { return }
    func installed(_ graphic: NotebookWorkingGraphic) -> Bool {
      graphic.surface.kind != .page
        && (graphic.publicationCursor.map { cohort.plan.revision >= $0 } ?? false)
    }
    // Display confirmation is a read unless an actual handoff completes.
    // Even a no-op removeAll mutates Observation and rebuilds the ink scene.
    guard workingGraphics.contains(where: installed) else { return }
    let changed=Set(workingGraphics.filter(installed).map(\.surface))
    workingGraphics.removeAll(where: installed)
    didChangeWorkingGraphics(on:changed)
  }
}

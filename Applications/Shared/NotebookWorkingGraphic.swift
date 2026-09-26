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
  var inkPresentation:NotebookSelectedInkPresentation?
  var accepted = false
  var publicationCursor: UInt64?
  private let authoredID:String?
  var id: String { authoredID ?? strokeID.uuidString.lowercased() }

  init(strokeID: UUID, fit: NotebookQuickShapeFit, surface: SurfaceID,
    worldOrigin: WorldPoint? = nil, color: SpatialInkColor, width: Double) {
    authoredID=nil
    self.strokeID = strokeID; self.surface = surface; self.frame = fit.frame
    self.worldOrigin = worldOrigin; basis = nil
    graphic = .init(shape: fit.shape, style: .init(stroke: color, strokeWidth: width),
      sourceInkIDs: fit.precedingStrokeIDs + [strokeID], connection: fit.connection, vertices: fit.vertices)
  }

  init(id: UUID, surface: SurfaceID, frame: PageRect, worldOrigin: WorldPoint?, graphic: NotebookGraphic,
    basis:NotebookElementBasis? = nil) {
    authoredID=nil
    strokeID = id; self.surface = surface; self.frame = frame; self.worldOrigin = worldOrigin
    self.graphic = graphic; self.basis = basis
  }

  /// Existing authored IDs need not be UUIDs. The measured contact remains the
  /// source identity, while the working representation retains its actual ID.
  init(elementID:String,sourceID:UUID,surface:SurfaceID,frame:PageRect,
    worldOrigin:WorldPoint?,graphic:NotebookGraphic,basis:NotebookElementBasis?) {
    authoredID=elementID;strokeID=UUID(uuidString:elementID) ?? sourceID;self.surface=surface;self.frame=frame
    self.worldOrigin=worldOrigin;self.graphic=graphic;self.basis=basis
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

  /// One coherent publication per surface, independent of fragment count.
  /// Unmoving remainders keep their original value and do not signal changes.
  func updateWorkingGraphics(_ values:[NotebookWorkingGraphic]) {
    var updates=Dictionary(uniqueKeysWithValues:values.map { ($0.strokeID,$0) })
    var changed=Set<SurfaceID>()
    for index in workingGraphics.indices {
      let old=workingGraphics[index]
      guard let value=updates.removeValue(forKey:old.strokeID),value != old,
        !old.accepted || (value.inkPresentation != nil && value.inkPresentation !== old.inkPresentation
          && old.inkPresentation?.holdsPresentation == false) else { continue }
      workingGraphics[index]=value;changed.insert(old.surface);changed.insert(value.surface)
    }
    for value in values where updates[value.strokeID] != nil {
      workingGraphics.append(value);changed.insert(value.surface)
    }
    if !changed.isEmpty { didChangeWorkingGraphics(on:changed) }
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
    let working=workingGraphics.filter { $0.surface == .page(page.id) }
    let held=Set(working.filter { value in
      guard let owner=value.inkPresentation else {return false}
      let canonical=owner.needsCanonicalSource && (value.publicationCursor.map { sceneContentCursor >= $0 } ?? false)
      return owner.retainsRawSource(value.id) && !canonical
    }.flatMap { $0.graphic.sourceInkIDs })
    return page.graphicPresentation.suppressedInkIDs.union(
      working.filter { $0.inkPresentation?.retainsRawSource($0.id) != true }.flatMap { $0.graphic.sourceInkIDs }).subtracting(held)
  }

  func workingGraphics(on surface: SurfaceID, cohort: SceneCompositionCohort) -> [NotebookWorkingGraphic] {
    _ = workingGraphicRevision(on:surface)
    return workingGraphics.filter { graphic in
      graphic.surface == surface
        && (graphic.inkPresentation?.holdsPresentation == true || (graphic.publicationCursor.map { cohort.plan.revision < $0 } ?? true))
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
    var delivered=Set<UUID>()
    for value in workingGraphics {
      guard let owner=value.inkPresentation,owner.needsCanonicalSource,delivered.insert(owner.id).inserted,
        value.surface.kind != .page,value.publicationCursor.map({cohort.plan.revision >= $0}) == true,
        let plan=cohort.liveData.orderedInk[value.surface],
        let canvas=compositionTiles.surfaceRegistry.canvas(for:value.surface) else {continue}
      owner.canonicalInstalled(plan,on:canvas,surface:value.surface)
    }
    func installed(_ graphic: NotebookWorkingGraphic) -> Bool {
      graphic.surface.kind != .page && graphic.inkPresentation?.holdsPresentation != true
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



extension NotebookAppModel {
  func selectedInkPresentationNeedsCanonical(_ owner:NotebookSelectedInkPresentation) {
    guard workingGraphics.contains(where:{$0.inkPresentation === owner}) else {return}
    didChangeWorkingGraphics(on:[owner.source.address.surface])
  }

  /// Raw identity alone does not change on conversion. The same captured
  /// immutable element source and input must own the installed ink plan.
  func canonicalPageInkInstalled(_ receipt:PageInkPresentation?,elementSource:ObjectIdentifier,input:NotebookPageOrderedInkInput) {
    guard let receipt,workingGraphics.contains(where:{
      $0.surface == .page(receipt.pageID) && $0.inkPresentation?.needsCanonicalSource == true
    }),let page=pages[receipt.pageID],page.drawingStamp == receipt.stamp,
      page.elementSourceIdentity == elementSource,
      let canvas=pageInkPublication.currentCanvas(on:receipt.pageID),canvas.isStableFramePresented,
      input.matches(canvas.orderedInkPlan) else {return}
    let surface=SurfaceID.page(receipt.pageID)
    var delivered=Set<UUID>()
    for value in workingGraphics {
      guard value.surface == surface,let owner=value.inkPresentation,owner.needsCanonicalSource,
        delivered.insert(owner.id).inserted,value.publicationCursor.map({sceneContentCursor >= $0}) == true else {continue}
      owner.canonicalInstalled(canvas.orderedInkPlan,on:canvas,surface:surface)
    }
  }

  func selectedInkPresentationInstalled(_ owner:NotebookSelectedInkPresentation) {
    let desired=Dictionary(uniqueKeysWithValues:owner.working.map { ($0.id,$0) })
    for index in workingGraphics.indices where workingGraphics[index].inkPresentation === owner {
      guard var value=desired[workingGraphics[index].id] else { continue }
      value.accepted=workingGraphics[index].accepted;value.publicationCursor=workingGraphics[index].publicationCursor
      workingGraphics[index]=value
    }
    // A deleted ordered member leaves the working projection in this same
    // installed frame; retaining its old working body would re-admit it on the
    // next model projection before the writer publishes canonical deletion.
    workingGraphics.removeAll { $0.inkPresentation === owner && desired[$0.id] == nil }
    // The contact keeps desired input, but only this native installation lets
    // its projected canonical members and selection controls advance.
    didChangeWorkingGraphics(on:[owner.source.address.surface])
    removeWorkingGraphics { $0.inkPresentation === owner && $0.surface.kind == .page
      && $0.inkPresentation?.holdsPresentation != true
      && ($0.publicationCursor.map { sceneContentCursor >= $0 } ?? false) }
  }
  func retireSelectedInkPresentation(_ owner:NotebookSelectedInkPresentation) {
    removeWorkingGraphics { $0.inkPresentation === owner }
  }
}

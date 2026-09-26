import Foundation
import CryptoKit
import NotebookCore

/// Painter positions have the same stable ID tie break as the SQL scene index.
/// A finite set of live positions divides static content without changing alpha
/// composition, even when many records share a z coordinate.
struct ScenePaintPosition: Hashable, Comparable, Codable, Sendable {
  enum Layer: Int, Hashable, Codable, Sendable { case elements, ink, covers }
  let layer: Layer
  let zIndex: Double
  let key: String
  init(layer: Layer, zIndex: Double, key: String) { self.layer = layer; self.zIndex = zIndex; self.key = key }
  init(entry: WorkspaceSpatialEntry) {
    switch entry.id {
    case .element(let id): layer = .elements; key = id
    case .item(let id): layer = .covers; key = id.uuidString
    }
    zIndex = entry.zIndex
  }
  static func < (a: Self, b: Self) -> Bool {
    if a.layer != b.layer { return a.layer.rawValue < b.layer.rawValue }
    if a.zIndex != b.zIndex { return a.zIndex < b.zIndex }
    return a.key < b.key
  }
}

struct ScenePaintRange: Hashable, Codable, Sendable {
  let layer: ScenePaintPosition.Layer
  let lower: ScenePaintPosition?
  let upper: ScenePaintPosition?
  func contains(_ entry: WorkspaceSpatialEntry) -> Bool {
    let position = ScenePaintPosition(entry: entry)
    return position.layer == layer && (lower == nil || lower! < position) && (upper == nil || position < upper!)
  }
  static func whole(_ layer: ScenePaintPosition.Layer) -> Self { .init(layer: layer, lower: nil, upper: nil) }
}

struct SceneCompositionReadPage: Sendable {
  let entries: [WorkspaceSpatialEntry]
  let next: SceneCompositionReadCursor?
}
enum SceneCompositionReadCursor: Sendable {
  case memory(WorkspaceSpatialReadCursor?, covers: Bool)
  case sql(NotebookScenePaintCursor)
}

/// Heavy passive sources travel with the exact tile cohort, not with the next
/// model publication. An already excluded human-input owner may continue from
/// the model; admitting a different owner requires a cohort that excludes it.
struct SceneCompositionLiveData: Sendable {
  let documents: [UUID: DocumentDocument]
  let states: [UUID: DocumentStateJournal]
  let pages: [UUID: PageDocument]
  let ink: SpatialInkJournal
  let suppressedInkIDs: Set<UUID>
  let orderedInk: [SurfaceID: NotebookOrderedInkPlan]
  let referenceIdentities: [NotebookReferenceIdentity]
  let referenceBasis: NotebookReferenceBasis?
  let documentPaperSizes: [UUID: DocumentPaperSize]
  let nonemptyBoardIDs: Set<UUID>
  let inkWindow: NotebookSpatialInkWindow?
  init(documents: [UUID: DocumentDocument], states: [UUID: DocumentStateJournal], pages: [UUID: PageDocument],
    ink: SpatialInkJournal, suppressedInkIDs: Set<UUID> = [], orderedInk: [SurfaceID: NotebookOrderedInkPlan] = [:], referenceIdentities: [NotebookReferenceIdentity] = [],
    referenceBasis: NotebookReferenceBasis? = nil, documentPaperSizes: [UUID: DocumentPaperSize] = [:],
    nonemptyBoardIDs: Set<UUID> = [], inkWindow: NotebookSpatialInkWindow? = nil) {
    self.documents = documents; self.states = states; self.pages = pages; self.ink = ink
    self.suppressedInkIDs = suppressedInkIDs
    self.orderedInk = orderedInk
    self.referenceIdentities = referenceIdentities
    self.referenceBasis = referenceBasis
    self.documentPaperSizes = documentPaperSizes
    self.nonemptyBoardIDs = nonemptyBoardIDs
    self.inkWindow = inkWindow
  }
}

/// One rendered scene owns its finite dependency witness. Validation repeats
/// only the admitted index pages and addressed identities, never rendering or
/// reading ink bodies. Camera is supplied by the publisher's presentation key.
struct ScenePixelDependencies: Sendable {
  struct Paint: Sendable {
    let boardID: UUID
    let coverID: UUID?
    let bounds: WorkspaceSpatialBounds
    let after: NotebookScenePaintPosition?
    let poses: [String: NotebookElementPlacement.Source]
    let entries: [WorkspaceSpatialEntry]
    let positions: [NotebookScenePaintPosition]
    let hasMore: Bool
  }
  struct Item: Sendable {
    let id: UUID
    let presence: SessionPresence
    let value: RenderedWorkspaceItem?
  }
  struct InkHeader: Equatable, Sendable {
    let stamp: VersionStamp
    let surfaces: Set<SurfaceID>
  }
  let workspaceID: UUID
  var records = NotebookSceneRecordDependencies()
  var paints: [Paint] = []
  var ink: [NotebookSpatialInkWindowRecords] = []
  var inkHeaders: [UUID: InkHeader] = [:]
  var boards: [UUID: Bool] = [:]
  var cameras: [UUID: BoardPortalCamera] = [:]
  var contents: [UUID: Bool] = [:]
  var items: [Item] = []

  func isCurrent(_ store: NotebookStore) throws -> Bool {
    try store.readTransaction { store in
      guard try store.workspaceHeader().workspaceID == workspaceID, try records.isCurrent(store) else { return false }
      for (id, exists) in boards where try (store.readBoardNodeHeader(id) != nil) != exists { return false }
      for (id, camera) in cameras where try (store.readBoardNodeHeader(id)?.portalCamera ?? .init()) != camera { return false }
      for (id, content) in contents where try store.boardHasContent(id) != content { return false }
      for item in items where try Self.readItem(store, id: item.id, presence: item.presence) != item.value { return false }
      for query in paints {
        let page = try store.readCurrentScenePaintOrder(boardID: query.boardID, coverID: query.coverID,
          bounds: query.bounds, after: query.after, groupPoses: query.poses)
        guard page.entries == query.entries, page.positions == query.positions, (page.next != nil) == query.hasMore else { return false }
      }
      for query in ink where try !query.isCurrent(store) { return false }
      if !inkHeaders.isEmpty {
        let current = try store.spatialInkHistoryStates(ids: Set(inkHeaders.keys))
        for (id, expected) in inkHeaders {
          guard let header = current[id], header.result.creationStamp == expected.stamp,
            header.surfaces == expected.surfaces else { return false }
        }
      }
      return true
    }
  }

  fileprivate static func readItem(_ store: NotebookStore, id: UUID, presence: SessionPresence) throws -> RenderedWorkspaceItem? {
    guard let header = try store.readItemHeader(id), let node = try store.readBoardItem(id), node.id == presence.boardID else { return nil }
    let geometry: WorkspaceItemGeometry
    if header.kind == .document {
      guard let paper = try store.readDocumentPaperSize(id) else { throw SceneRenderError.snapshotPending("document_paper") }
      geometry = .document(paper)
    } else { geometry = .notebook }
    if let placement = node.board.freeItems.first(where: { $0.itemID == id }) {
      return .init(item: header.item, geometry: geometry, center: placement.center, zIndex: Double(placement.zIndex), stackID: nil)
    }
    guard let stack = node.board.stacks.first(where: { $0.itemIDs.contains(id) }), let index = stack.itemIDs.firstIndex(of: id) else { return nil }
    if presence.mode != .board, let focused = presence.focusedItemID, stack.itemIDs.contains(focused), focused != id { return nil }
    let center = WorkspaceItemStackPresentation.focusedCenter(of: id, in: stack) ?? stack.center
    return .init(item: header.item, geometry: geometry, center: center,
      zIndex: Double(stack.zIndex) + Double(index) / 100, stackID: stack.id)
  }
}

/// An addressed reader borrows at most one heavy physical source at a time.
/// It never reconstructs the archive from the model's bounded display projection.
/// Each SQL read checks its source inside the transaction. Only proven delivery
/// receipt changes may cross the cut; changed material cancels the unpublished
/// cohort rather than mixing its tiles.
actor SceneCompositionSource {
  struct InkPaint: Sendable {
    let journal: SpatialInkJournal
    let plan: NotebookOrderedInkPlan
  }
  struct ElementPaint: Sendable {
    let element: SpatialElement
    let layout: NotebookGraphicLayout?
    let placement: NotebookElementPlacement?
    let erasures: [InkElementErasure]
  }

  let revision: UInt64
  private var validatedRevision: UInt64
  let workspaceID: UUID
  let groupPoses:[SceneCompositionPlane:[String:NotebookElementPlacement.Source]]
  private enum Origin: Sendable {
    case sql(NotebookStore)
    case values(WorkspaceSceneIndex, BoardHierarchy, SpatialInkJournal)
  }
  private let origin: Origin
  private let reader: NotebookReadSession?
  private let validationIdentities: [NotebookReferenceIdentity]?
  private var inkWindow: NotebookSpatialInkWindow?
  private var pixelWitness: ScenePixelDependencies?
  // Only the last painted erased element is retained. Adjacent tiles often
  // revisit it; a source reader must not accumulate an archive of derived paths.
  private var preparedAppearance: (NotebookElementErasureCache.Input, NotebookElementAppearance)?
  private var paintIdentities: [SceneCompositionPlane: String] = [:]
  private var posePaint: [SceneCompositionPlane:(identity:String,damage:[WorkspaceSpatialBounds])] = [:]
  private var nestedPoseIdentity: String?
  private var erasureProjection: [SurfaceID: [String: [InkElementErasure]]] = [:]
  private var folderContents: [UUID: Bool] = [:]

  init(store: NotebookStore, revision: UInt64, workspaceID: UUID,
    groupPoses:[SceneCompositionPlane:[String:NotebookElementPlacement.Source]] = [:],
    validationIdentities: [NotebookReferenceIdentity]? = nil, inkWindow: NotebookSpatialInkWindow? = nil,
    recordPixelDependencies: Bool = false) {
    origin = .sql(store); reader = NotebookReadSession(store: store); self.revision = revision; validatedRevision = revision; self.workspaceID = workspaceID;self.groupPoses=groupPoses.filter { !$0.value.isEmpty }
    self.validationIdentities = validationIdentities
    self.inkWindow = inkWindow?.cursor == revision ? inkWindow : nil
    pixelWitness = recordPixelDependencies ? .init(workspaceID: workspaceID) : nil
  }
  init(index: WorkspaceSceneIndex, hierarchy: BoardHierarchy, journal: SpatialInkJournal, revision: UInt64 = 0) {
    origin = .values(index, hierarchy, journal); reader = nil; self.revision = revision; validatedRevision = revision; workspaceID = index.generationID;groupPoses=[:]
    validationIdentities = nil; inkWindow = nil; pixelWitness = nil
  }

  func pixelDependencies() throws -> ScenePixelDependencies? {
    try validate()
    return pixelWitness
  }

  private func recorded<Value>(_ store: NotebookStore, _ read: () throws -> Value) throws -> Value {
    guard pixelWitness != nil else { return try read() }
    let result = try store.readRecordingSceneRecords(read)
    try pixelWitness!.records.merge(result.dependencies)
    return result.value
  }

  func programStore() -> NotebookStore? { if case .sql(let store) = origin { store } else { nil } }

  func validate() throws {
    try Task.checkCancellation()
    if case .sql(let store) = origin { try checked(store) { _ in () } }
  }
  private func checked<Value>(_ store: NotebookStore, _ read: (NotebookStore) throws -> Value) throws -> Value {
    try Task.checkCancellation()
    guard let reader else { preconditionFailure("SQL composition has one reader") }
    return try reader.read { store in
      let header = try store.workspaceHeader()
      guard header.workspaceID == workspaceID else { throw NotebookStorageError.transactionConflict }
      if header.cursor != validatedRevision {
        let unchanged = try pixelWitness.map { try $0.isCurrent(store) } ?? validationIdentities.map { identities in
          try store.referenceIdentities(targets: identities.map(\.target)) == identities
        } ?? store.sceneSourceIsUnchanged(from: validatedRevision, through: header.cursor)
        guard unchanged else { throw NotebookStorageError.transactionConflict }
        validatedRevision = header.cursor
      }
      return try read(store)
    }
  }

  func boardExists(_ id: UUID) throws -> Bool {
    switch origin {
    case .sql(let store): try checked(store) {
      let value = try $0.readBoardNodeHeader(id) != nil
      pixelWitness?.boards[id] = value
      return value
    }
    case .values(let index, _, _): index.board(id: id) != nil
    }
  }
  func portalCamera(_ id: UUID) throws -> BoardPortalCamera {
    switch origin {
    case .sql(let store): try checked(store) {
      let value = try $0.readBoardNodeHeader(id)?.portalCamera ?? .init()
      pixelWitness?.cameras[id] = value
      return value
    }
    case .values(_, let hierarchy, _): hierarchy.portalCamera(id) ?? .init()
    }
  }

  func boardHasContent(_ id: UUID) throws -> Bool {
    if let value = folderContents[id] { return value }
    let value: Bool
    switch origin {
    case .sql(let store): value = try checked(store) {
      let value = try $0.boardHasContent(id)
      pixelWitness?.contents[id] = value
      return value
    }
    case .values(_, let hierarchy, let journal):
      guard hierarchy.board(id) != nil else { throw SceneRenderError.snapshotPending("folder_source") }
      value = !hierarchy.isEmpty(id, spatialInk: journal)
    }
    folderContents[id] = value
    return value
  }

  private func window(_ store: NotebookStore, coverage: [SurfaceID: WorkspaceSpatialBounds],
    elements: [SurfaceID: [String]] = [:]) throws -> NotebookSpatialInkWindow {
    if let inkWindow, inkWindow.covers(coverage, elements: elements) {
      try retainInkWitness(inkWindow.records)
      return inkWindow
    }
    let result = try store.readSpatialInkWindow(coverage: coverage, elementIDs: elements)
    inkWindow = result
    try retainInkWitness(result.records)
    return result
  }

  private func retainInkWitness(_ value: NotebookSpatialInkWindowRecords) throws {
    guard pixelWitness != nil, !pixelWitness!.ink.contains(value) else { return }
    guard pixelWitness!.ink.count < 8192 else { throw SceneRenderError.resourceLimit }
    pixelWitness!.ink.append(value)
  }

  /// Ordered bodies have already passed the same addressed element read used
  /// by the painter. Resolving their claim component also includes offscreen
  /// winners; only the original headers are needed to recover painter order.
  private func orderedInkPlan(_ surface: SurfaceID, journal: SpatialInkJournal,
    elements: [ElementPaint]) throws -> NotebookOrderedInkPlan {
    var candidates: [String: ElementPaint] = [:]
    for read in elements where read.element.surface == surface && read.element.parentID == nil {
      guard let graphic = read.element.graphic, read.layout != nil,
        graphic.sourceInkContactID != nil else { continue }
      candidates[read.element.id] = read
    }
    guard candidates.count <= 8192 else { throw SceneRenderError.resourceLimit }
    let candidateIDs = Set(candidates.values.compactMap { $0.element.graphic?.sourceInkContactID })
    let sourceIDs = Set(journal.actions.lazy.filter { action in action.spans.contains { $0.surface == surface } }.map(\.id)).union(candidateIDs)
    let presentation: NotebookGraphicPresentation
    var keys: [UUID: NotebookInkPaintKey] = [:]
    switch origin {
    case .sql(let store):
      (presentation, keys) = try checked(store) { store in
        let presentation = try recorded(store) { try store.graphicPresentation(on: surface, sourceInkIDs: sourceIDs) }
        let needed = Set(candidates.values.compactMap { read -> UUID? in
          guard presentation.geometryIDs.contains(read.element.id),
            !read.erasures.contains(where: { $0.target.wholeElement }) else { return nil }
          return read.element.graphic?.sourceInkContactID
        })
        var keys: [UUID: NotebookInkPaintKey] = [:]
        guard !needed.isEmpty else { return (presentation, keys) }
        let headers = try store.spatialInkHistoryStates(ids: needed)
        for id in needed {
          guard let header = headers[id], header.surfaces.contains(surface) else {
            throw SceneRenderError.snapshotPending("ordered_ink_header")
          }
          if pixelWitness != nil {
            let witness = ScenePixelDependencies.InkHeader(stamp: header.result.creationStamp, surfaces: header.surfaces)
            guard pixelWitness!.inkHeaders[id] != nil || pixelWitness!.inkHeaders.count < 8192 else {
              throw SceneRenderError.resourceLimit
            }
            if let old = pixelWitness!.inkHeaders[id], old != witness { throw NotebookStorageError.transactionConflict }
            pixelWitness!.inkHeaders[id] = witness
          }
          keys[id] = .spatial(stamp: header.result.creationStamp, id: id)
        }
        return (presentation, keys)
      }
    case .values(_, let hierarchy, let source):
      let boardID = surface.kind == .board ? surface.ownerID : surface.ownerID.flatMap(hierarchy.ownerBoardID(of:))
      guard let boardID, let board = hierarchy.board(boardID) else { throw SceneRenderError.snapshotPending("ordered_ink_owner") }
      let ids = Set(board.elements.lazy.filter { $0.surface == surface }.map(\.id))
      presentation = .init(board.graphicPresentationCandidates.filter { ids.contains($0.id) })
      if !candidateIDs.isEmpty {
        for action in source.actions where candidateIDs.contains(action.id) && action.spans.contains(where: { $0.surface == surface }) {
          keys[action.id] = .spatial(stamp: action.stamp, id: action.id)
        }
      }
    }
    var bodies: [NotebookOrderedInkPlan.Body] = []
    for read in candidates.values where presentation.geometryIDs.contains(read.element.id) {
      guard !read.erasures.contains(where: { $0.target.wholeElement }), let graphic = read.element.graphic,
        let sourceID = graphic.sourceInkContactID, let layout = read.layout else { continue }
      guard let key = keys[sourceID] else { throw SceneRenderError.snapshotPending("ordered_ink_header") }
      bodies.append(.init(elementID: read.element.id, key: key, graphic: graphic, layout: layout, erasures: read.erasures))
    }
    return .init(bodies: bodies, suppressedInkIDs: presentation.suppressedInkIDs)
  }

  func ink(_ surface: SurfaceID, bounds: WorkspaceSpatialBounds,
    orderedElements: [ElementPaint]) throws -> InkPaint {
    switch origin {
    case .sql(let store): return try checked(store) {
      let journal = try window($0, coverage: [surface: bounds]).journal
      return .init(journal: journal, plan: try orderedInkPlan(surface, journal: journal, elements: orderedElements))
    }
    case .values(_, _, let journal):
      return .init(journal: journal, plan: try orderedInkPlan(surface, journal: journal, elements: orderedElements))
    }
  }

  /// The live cohort uses its existing finite worksets and the one admitted ink
  /// window. Target cuts are projected once per surface, not reread per body.
  private func liveOrderedInk(surfaces: [SurfaceID], frame: WorkspaceSceneFrame,
    journal: SpatialInkJournal) throws -> [SurfaceID: NotebookOrderedInkPlan] {
    var result: [SurfaceID: NotebookOrderedInkPlan] = [:]
    for surface in surfaces {
      guard let owner = surface.ownerID else { throw SceneRenderError.snapshotPending("ordered_ink_owner") }
      let boardID: UUID
      let elements: [SpatialElement]
      if surface.kind == .board {
        boardID = owner; elements = frame.worksets[owner]?.elements ?? []
      } else {
        guard let board = frame.index.ownerBoard(itemID: owner) else { throw SceneRenderError.snapshotPending("ordered_ink_owner") }
        boardID = board; elements = frame.covers[owner]?.elements ?? []
      }
      let candidates = elements.filter { element in
        element.surface == surface && element.parentID == nil
          && element.graphic?.sourceInkContactID != nil
      }
      let erasures = candidates.isEmpty ? [:] : journal.elementErasures(on: surface)
      var reads: [ElementPaint] = []
      for element in candidates {
        guard let layout = try graphicLayout(element, boardID: boardID) else { continue }
        reads.append(.init(element: element, layout: layout, placement: nil, erasures: erasures[element.id] ?? []))
      }
      result[surface] = try orderedInkPlan(surface, journal: journal, elements: reads)
    }
    return result
  }
  func liveData(plan: SceneCompositionPlan, presence: SessionPresence, frame: WorkspaceSceneFrame,
    previous: (plan: SceneCompositionPlan, data: SceneCompositionLiveData)? = nil) throws -> SceneCompositionLiveData {
    guard plan.revision == revision, plan.workspaceID == workspaceID,plan.groupPoses == groupPoses else { throw NotebookStorageError.transactionConflict }
    let itemIDs = Set(plan.liveOwners.compactMap { owner -> UUID? in
      if case .item(let id) = owner.id { return id }; return nil
    }).sorted { $0.uuidString < $1.uuidString }
    let surfaces = plan.inkSurfaces
    guard surfaces.count <= SceneCompositionPlan.maximumLiveOwners else { throw SceneRenderError.resourceLimit }
    let folders = Set(frame.worksets.values.flatMap { $0.items.filter { $0.item.kind == .board }.map(\.id) })
    let nonemptyBoardIDs = try Set(folders.filter { try boardHasContent($0) })
    switch origin {
    case .sql(let store):
      return try checked(store) { store in
        // Closed paper needs its indexed cover, authored cover elements and
        // ink. Its body belongs to the opened-page owner, not board admission.
        let opensPaper = presence.openProgress > 0 || presence.mode == .page || presence.mode == .document
        let openedID = opensPaper ? presence.focusedItemID : nil
        let documents = try itemIDs.filter { id in
          guard id == openedID else { return false }
          return try store.readItemHeader(id)?.kind == .document
        }
        let pageIDs = opensPaper && presence.selectedItemID.map(itemIDs.contains) == true
          ? (presence.notebookPageID.map { [$0] } ?? []) : []
        var inkCoverage: [SurfaceID: WorkspaceSpatialBounds] = [:]
        for surface in surfaces {
          if surface.kind == .board {
            guard let view = plan.presentations[.board(surface.ownerID!)] else { throw SceneRenderError.snapshotPending("ink_coverage") }
            inkCoverage[surface] = NotebookSceneState.bounds(for: view)
          } else {
            let geometry = frame.index.documentPaperSizes[surface.ownerID!].map(WorkspaceItemGeometry.document) ?? .notebook
            inkCoverage[surface] = .init(origin: .zero, width: geometry.width, height: geometry.height)
          }
        }
        var inkElements: [SurfaceID: [String]] = [:]
        for workset in Array(frame.worksets.values) + Array(frame.covers.values) {
          for element in workset.elements where inkCoverage[element.surface] != nil { inkElements[element.surface, default: []].append(element.id) }
        }
        if let old = previous?.data.inkWindow, previous?.plan.revision == revision,
          old.covers(inkCoverage, elements: inkElements) { inkWindow = old }
        let inkSource = try window(store, coverage: inkCoverage, elements: inkElements)
        let data = try store.readWorkingSet(itemIDs: documents, pageIDs: pageIDs, boardIDs: [], surfaces: [])
        let ink = inkSource.journal
        guard data.documents.count == documents.count, data.states.count == documents.count,
          data.pages.count == pageIDs.count else { throw SceneRenderError.snapshotPending("live_owner_payload") }
        var targets = Set(plan.presentations.keys.compactMap { plane -> CollaborationTarget? in
          guard case .board(let id) = plane else { return nil }
          return .init(kind: .board, id: id)
        })
        for (boardID, workset) in frame.worksets {
          for item in workset.items { targets.insert(.init(kind: .cover, id: item.id, boardID: boardID)) }
        }
        // A prepared child can become the active board without a new cohort.
        // Its compact complete ink basis travels too, not another sample copy.
        let replaceable = plan.presentations.keys.compactMap { plane -> SurfaceID? in
          switch plane {
          case .board(let id): return .board(id)
          case .cover(_, let id): return .cover(id)
          }
        }
        // Back is explicit navigation. Only the shown board and its visible
        // descendants own backing; no invisible ancestor competes for pixels.
        let referenceRoot = plan.rootBoardID
        let basis = try store.referenceBasis(rootBoardID: referenceRoot,
          targets: targets.sorted { $0.key < $1.key }, surfaces: replaceable, inkActionIDs: Set(ink.actions.map(\.id)),
          liveOwners: plan.presentedOwners.map { owner in
            switch owner.id {
            case .item(let id): return .item(boardID: owner.plane.boardID, id: id)
            case .element(let id): return .element(boardID: owner.plane.boardID, id: id)
            }
          })
        let ordered = try liveOrderedInk(surfaces: surfaces, frame: frame, journal: ink)
        let suppressed = ordered.values.reduce(into: Set<UUID>()) { $0.formUnion($1.suppressedInkIDs) }
        return .init(documents: data.documents, states: data.states, pages: data.pages, ink: ink, suppressedInkIDs: suppressed,
          orderedInk: ordered,
          referenceIdentities: basis.identities, referenceBasis: basis,
          documentPaperSizes: frame.index.documentPaperSizes.filter { itemIDs.contains($0.key) },
          nonemptyBoardIDs: nonemptyBoardIDs, inkWindow: inkSource)
      }
    case .values(_, _, let journal):
      let wanted = Set(surfaces)
      let ink = SpatialInkJournal(actions: journal.actions.filter { $0.spans.contains { wanted.contains($0.surface) } }, stamp: journal.stamp)
      let ordered = try liveOrderedInk(surfaces: surfaces, frame: frame, journal: ink)
      return .init(documents: [:], states: [:], pages: [:], ink: ink,
        suppressedInkIDs: ordered.values.reduce(into: Set<UUID>()) { $0.formUnion($1.suppressedInkIDs) }, orderedInk: ordered,
        documentPaperSizes: frame.index.documentPaperSizes.filter { itemIDs.contains($0.key) },
        nonemptyBoardIDs: nonemptyBoardIDs)
    }
  }

  /// Material and permission to carry earlier pixels are one source read.
  /// Returning between them to the UI executor adds a frame-sized scheduling
  /// gap and reopens SQLite without acquiring any additional evidence.
  func liveCandidate(plan: SceneCompositionPlan, presence: SessionPresence, frame: WorkspaceSceneFrame,
    previous: (plan: SceneCompositionPlan, data: SceneCompositionLiveData)?,
    reusing: (plan: SceneCompositionPlan, data: SceneCompositionLiveData)?) throws
    -> (data: SceneCompositionLiveData, canCarry: Bool) {
    func read() throws -> (SceneCompositionLiveData, Bool) {
      let data = try liveData(plan: plan, presence: presence, frame: frame, previous: reusing)
      let carry = try previous.map {
        try canCarryStaticPixels(from: $0.plan, liveData: $0.data, to: plan, liveData: data)
      } ?? false
      return (data, carry)
    }
    if case .sql(let store) = origin { return try checked(store) { _ in try read() } }
    return try read()
  }

  /// A global SQL commit does not invalidate pixels whose sources were not
  /// painted into them. Unknown or oversized changes always rebuild instead.
  func canCarryStaticPixels(from oldPlan: SceneCompositionPlan, liveData oldData: SceneCompositionLiveData,
    to plan: SceneCompositionPlan, liveData data: SceneCompositionLiveData) throws -> Bool {
    guard oldPlan.workspaceID == workspaceID, plan.workspaceID == workspaceID,
      plan.revision == revision, oldPlan.revision <= revision,
      oldPlan.rootBoardID == plan.rootBoardID,oldPlan.groupPoses == groupPoses,plan.groupPoses == groupPoses else { return false }
    if oldPlan.revision == revision { return true }
    guard case .sql(let store) = origin else { return false }
    return try checked(store) { store in
      let changes = try store.readChangedAddresses(after: oldPlan.revision, through: revision)
      guard !changes.hasMore else { return false }
      return Self.affectsOnlyExcludedOwners(changes.records, oldPlan: oldPlan, oldData: oldData, plan: plan, data: data)
    }
  }

  static func affectsOnlyExcludedOwners(_ records: [NotebookChangedRecord], oldPlan: SceneCompositionPlan,
    oldData: SceneCompositionLiveData, plan: SceneCompositionPlan, data: SceneCompositionLiveData) -> Bool {
    func covers(_ plan: SceneCompositionPlan) -> Set<UUID> {
      Set(plan.liveOwners.compactMap { if case .item(let id) = $0.id { return id }; return nil })
    }
    let liveItems = covers(oldPlan).intersection(covers(plan))
    let surfaces = Set(oldPlan.inkBoardIDs.intersection(plan.inkBoardIDs).map(SurfaceID.board)
      + liveItems.map(SurfaceID.cover))
    let oldActions = Dictionary(uniqueKeysWithValues: oldData.ink.actions.map { ($0.id, $0) })
    let actions = Dictionary(uniqueKeysWithValues: data.ink.actions.map { ($0.id, $0) })
    for record in records where record.beforeHash != record.afterHash {
      let address = record.address
      // Root ink carries only format and journal stamp. Every changed action
      // must independently pass the union-of-old-and-new surfaces check below.
      if address == "spatial-ink.json#" { continue }
      let inkPrefix = "spatial-ink.json#/actions/@"
      if address.hasPrefix(inkPrefix) {
        guard let component = address.dropFirst(inkPrefix.count).split(separator: "/").first,
          let id = UUID(uuidString: String(component)) else { return false }
        // Absence from a bounded payload does not prove that an action was
        // absent from the prior workspace. SQL history distinguishes creation,
        // removal and a change from/to another physical surface.
        guard record.beforeHash == nil || oldActions[id] != nil,
          record.afterHash == nil || actions[id] != nil else { return false }
        let versions = [oldActions[id], actions[id]].compactMap { $0 }
        guard !versions.isEmpty, versions.allSatisfy({ $0.spans.allSatisfy { surfaces.contains($0.surface) } }) else { return false }
        for action in versions where action.tool == .eraser {
          for span in action.spans {
            for target in span.elementTargets ?? [] {
              func excluded(_ candidate: SceneCompositionPlan) -> Bool {
                guard let plane = candidate.presentations.keys.first(where: {
                  span.surface.kind == .board ? $0 == .board(span.surface.ownerID!) : $0.coverID == span.surface.ownerID
                }) else { return false }
                return candidate.allowsLive(.element(target.elementID), in: plane)
              }
              guard excluded(oldPlan), excluded(plan) else { return false }
            }
          }
        }
        continue
      }
      let file = String(address.split(separator: "#", maxSplits: 1)[0])
      if let id = documentID(file, directory: "document-states"), liveItems.contains(id) { continue }
      if let id = documentID(file, directory: "documents"), liveItems.contains(id),
        let oldPaper = oldData.documentPaperSizes[id] ?? oldData.documents[id]?.paperSize,
        let newPaper = data.documentPaperSizes[id] ?? data.documents[id]?.paperSize, oldPaper == newPaper { continue }
      if let id = documentID(file, directory: "pages"), oldData.pages[id] != nil, data.pages[id] != nil { continue }
      return false
    }
    return true
  }

  private static func documentID(_ file: String, directory: String) -> UUID? {
    guard file.hasPrefix(directory + "/"), file.hasSuffix(".json") else { return nil }
    return UUID(uuidString: String(file.dropFirst(directory.count + 1).dropLast(5)))
  }
  func element(_ id: String, boardID: UUID) throws -> SpatialElement? {
    switch origin {
    case .sql(let store): try checked(store) { store in try recorded(store) { try store.readSpatialElement(boardID: boardID, elementID: id) } }
    case .values(let index, _, _): index.element(id: id, boardID: boardID)
    }
  }
  /// One borrowed body and its dependencies share a checked WAL snapshot. Do
  /// not hold that connection across painting/awaits or collect a page of heavy
  /// bodies. The renderer still validates the complete unpublished tile.
  func readElementForPaint(_ id: String, boardID: UUID) throws -> ElementPaint? {
    func read() throws -> ElementPaint? {
      guard let element = try element(id, boardID: boardID) else {
        throw SceneRenderError.snapshotPending("element_source")
      }
      guard element.kind != .group else { return nil }
      let layout = try graphicLayout(element, boardID: boardID)
      if element.graphic != nil && layout == nil { return nil }
      let placement = element.graphic == nil ? try elementPlacement(element, boardID: boardID) : nil
      guard layout != nil || placement != nil else { throw SceneRenderError.snapshotPending("element_placement") }
      let erasures = try cachedElementErasures(element)
      guard !erasures.contains(where: { $0.target.wholeElement }) else { return nil }
      return .init(element: element, layout: layout, placement: placement, erasures: erasures)
    }
    try Task.checkCancellation()
    if case .sql(let store) = origin { return try checked(store) { _ in try read() } }
    return try read()
  }

  /// Mask work stays after the exact visibility test and outside the SQL read.
  /// It uses only the borrowed source, never another revision's erase actions.
  func elementAppearance(_ read: ElementPaint) throws -> NotebookElementAppearance? {
    try Task.checkCancellation()
    let element = read.element, layout = read.layout, erasures = read.erasures
    guard !erasures.isEmpty else { return nil }
    let frame = layout?.frame ?? .init(x: 0, y: 0, width: element.basis?.size.x ?? element.frame.width, height: element.basis?.size.y ?? element.frame.height)
    let input = NotebookElementErasureCache.Input(graphic: element.graphic, layout: layout,
      size: .init(width: frame.width, height: frame.height), erasures: erasures)
    if let cached = preparedAppearance, cached.0 == input { return cached.1 }
    // This actor, not ImageRenderer/MainActor, owns boolean normalization.
    let value = input.prepare()
    try Task.checkCancellation()
    preparedAppearance = (input, value)
    return value
  }

  /// Planning must not reload the entire board ink for every camera window.
  /// The existing target index addresses only the actions that can erase these
  /// programs. One checked WAL read covers this bounded workset.
  func wholeErasedElements(_ elements: [SpatialElement]) throws -> Set<String> {
    let programs = elements.filter { $0.kind == .web }
    guard !programs.isEmpty else { return [] }
    func read() throws -> Set<String> {
      var erased = Set<String>()
      for element in programs where try cachedElementErasures(element).contains(where: { $0.target.wholeElement }) {
        erased.insert(element.id)
      }
      return erased
    }
    if case .sql(let store) = origin { return try checked(store) { _ in try read() } }
    return try read()
  }

  private func cachedElementErasures(_ element: SpatialElement) throws -> [InkElementErasure] {
    if let cached = erasureProjection[element.surface]?[element.id] { return cached }
    let value: [InkElementErasure]
    switch origin {
    case .sql(let store):
      let source = try store.readSpatialInkWindow(coverage: [:], elementIDs: [element.surface: [element.id]])
      try retainInkWitness(source.records)
      value = source.journal.elementErasures(on: element.surface)[element.id] ?? []
    case .values(_, _, let journal): value = journal.elementErasures(on: element.surface)[element.id] ?? []
    }
    erasureProjection[element.surface, default: [:]][element.id] = value
    return value
  }
  func elementPlacement(_ element: SpatialElement, boardID: UUID) throws -> NotebookElementPlacement? {
    switch origin {
    case .sql(let store): return try checked(store) {
      let target=element.surface.kind == .cover
        ? CollaborationTarget(kind:.cover,id:element.surface.ownerID!,boardID:boardID) : .init(kind:.board,id:boardID)
      let plane=element.surface.kind == .cover
        ? SceneCompositionPlane.cover(boardID:boardID,itemID:element.surface.ownerID!) : .board(boardID)
      let store = $0
      return try recorded(store) { try store.readElementPlacement(target:target,elementID:element.id,groupPoses:groupPoses[plane] ?? [:]) }
    }
    case .values(let index,_,_):
      let plane=element.surface.kind == .cover ? SceneCompositionPlane.cover(boardID:boardID,itemID:element.surface.ownerID!) : .board(boardID)
      return index.graphicGraph(boardID:boardID)?.projecting(placements:groupPoses[plane] ?? [:]).placement(element.id)
    }
  }
  private func graphicLayout(_ element: SpatialElement, boardID: UUID) throws -> NotebookGraphicLayout? {
    guard element.graphic != nil else { return nil }
    switch origin {
    case .sql(let store): return try checked(store) {
      let target = element.surface.kind == .cover
        ? CollaborationTarget(kind:.cover,id:element.surface.ownerID!,boardID:boardID)
        : CollaborationTarget(kind:.board,id:boardID)
      let plane=element.surface.kind == .cover ? SceneCompositionPlane.cover(boardID:boardID,itemID:element.surface.ownerID!) : .board(boardID)
      let store = $0
      return try recorded(store) { try store.readGraphicResolution(target:target,elementID:element.id,groupPoses:groupPoses[plane] ?? [:]).layout }
    }
    case .values(let index, _, _): return index.graphicLayout(id:element.id,boardID:boardID)
    }
  }
  func item(_ id: UUID, presence: SessionPresence) throws -> RenderedWorkspaceItem? {
    switch origin {
    case .values(let index, _, _): return index.renderedItem(id: id, presence: presence)
    case .sql(let store):
      return try checked(store) { store in
        let value = try ScenePixelDependencies.readItem(store, id: id, presence: presence)
        if pixelWitness != nil {
          guard pixelWitness!.items.count < 8192 else { throw SceneRenderError.resourceLimit }
          pixelWitness!.items.append(.init(id: id, presence: presence, value: value))
        }
        return value
      }
    }
  }
  func readPaintOrder(boardID: UUID, coverID: UUID? = nil, bounds: WorkspaceSpatialBounds,
    after: SceneCompositionReadCursor? = nil) throws -> SceneCompositionReadPage {
    switch origin {
    case .sql(let store):
      return try checked(store) { store in
        var cursor: NotebookScenePaintCursor?
        if let after { guard case .sql(let value) = after else { throw NotebookStorageError.transactionConflict }; cursor = value }
        let plane=coverID.map { SceneCompositionPlane.cover(boardID:boardID,itemID:$0) } ?? .board(boardID)
        let poses = groupPoses[plane] ?? [:]
        let page: NotebookScenePaintPage
        if pixelWitness != nil {
          page = try store.readCurrentScenePaintOrder(boardID: boardID, coverID: coverID, bounds: bounds, after: cursor?.position, groupPoses: poses)
          guard pixelWitness!.paints.count < 8192 else { throw SceneRenderError.resourceLimit }
          pixelWitness!.paints.append(.init(boardID: boardID, coverID: coverID, bounds: bounds, after: cursor?.position,
            poses: poses, entries: page.entries, positions: page.positions, hasMore: page.next != nil))
        } else {
          page = try store.readScenePaintOrder(boardID: boardID, coverID: coverID, bounds: bounds, after: cursor, limit: 32, groupPoses: poses)
        }
        return .init(entries: page.entries, next: page.next.map(SceneCompositionReadCursor.sql))
      }
    case .values(let index, _, _):
      var cursor: WorkspaceSpatialReadCursor?
      var covers = false
      if let after {
        guard case .memory(let value, let phase) = after else { throw NotebookStorageError.transactionConflict }
        cursor = value; covers = phase
      }
      guard let page = try index.readPaintOrder(boardID: boardID, coverID: coverID, bounds: bounds, after: cursor) else {
        if coverID != nil { return .init(entries: [], next: nil) }
        throw SceneRenderError.snapshotPending("board_source")
      }
      let entries = page.entries.filter {
        if coverID != nil { return true }
        if case .item = $0.id { return covers }; return !covers
      }
      let next = page.next.map { SceneCompositionReadCursor.memory($0, covers: covers) }
        ?? (coverID == nil && !covers ? .memory(nil, covers: true) : nil)
      return .init(entries: entries, next: next)
    }
  }

  /// A complete, same-revision addressed read can prove a painter range empty.
  /// An unfinished cursor is unknown, never absence. At most two 32-entry
  /// pages per tile are inspected; dense sources keep the ordinary painter.
  func tilesRequiringPaint(_ tiles: [SceneCompositionTileKey]) throws -> [SceneCompositionTileKey] {
    if case .sql(let store) = origin {
      // All cells belong to one source cut. Nested addressed reads borrow this
      // connection instead of reopening SQLite for each cell and painter band.
      return try checked(store) { store in
        try populatedTiles(tiles).map { key in
          if paintIdentities[key.plane] == nil {
            let target = key.plane.coverID.map { CollaborationTarget(kind: .cover, id: $0, boardID: key.plane.boardID) }
              ?? .init(kind: .board, id: key.plane.boardID)
            paintIdentities[key.plane] = try store.scenePaintRevision(target: target)
          }
          var identity=paintIdentities[key.plane]!
          if key.range.layer == .elements,let poses=groupPoses[key.plane] {
            if posePaint[key.plane] == nil {
              posePaint[key.plane] = (try Self.poseHash(poses),try store.readGroupPoseDamage(
                boardID:key.plane.boardID,coverID:key.plane.coverID,groupPoses:poses))
            }
            let paint=posePaint[key.plane]!
            let padding=key.tile.worldSize/Double(key.pixelSize)
            let bounds=WorkspaceSpatialBounds(origin:key.tile.origin.offsetBy(x:-padding,y:-padding),
              width:key.tile.worldSize+2*padding,height:key.tile.worldSize+2*padding)
            if paint.damage.contains(where:{ $0.intersects(bounds) }) { identity += ":pose:"+paint.identity }
          } else if key.range.layer == .covers,!groupPoses.isEmpty {
            // A cover or portal can embed another plane's posed graphics. Its
            // existing raster must not borrow an unchanged outer-plane hash.
            if nestedPoseIdentity == nil {
              let keyed=Dictionary(uniqueKeysWithValues:groupPoses.map { plane,poses in
                (plane.boardID.uuidString+":"+(plane.coverID?.uuidString ?? "board"),poses)
              })
              nestedPoseIdentity=try Self.poseHash(keyed)
            }
            identity += ":pose:"+nestedPoseIdentity!
          }
          return key.withContentRevision(identity)
        }
      }
    }
    return try populatedTiles(tiles)
  }

  private static func poseHash<T:Encodable>(_ value:T) throws -> String {
    let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
    return SHA256.hash(data:try encoder.encode(value)).map { String(format:"%02x",$0) }.joined()
  }

  private func populatedTiles(_ tiles: [SceneCompositionTileKey]) throws -> [SceneCompositionTileKey] {
    struct Probe: Hashable {
      let plane: SceneCompositionPlane
      let tile: CompositionTile
      let pixelSize: Int
    }
    struct Read {
      let entries: [WorkspaceSpatialEntry]
      let exhausted: Bool
    }
    var reads: [Probe: Read] = [:]
    var retained: [SceneCompositionTileKey] = []
    for tile in tiles {
      try Task.checkCancellation()
      if tile.range.layer == .ink { retained.append(tile); continue }
      // Board painting also reaches covers whose shadows cross the tile edge.
      // One output pixel conservatively includes projection rounding at edges.
      let padding = (tile.plane.coverID == nil ? WorkspaceCoverRaster.shadowPadding : 0)
        + tile.tile.worldSize / Double(tile.pixelSize)
      let bounds = WorkspaceSpatialBounds(origin: tile.tile.origin.offsetBy(x: -padding, y: -padding),
        width: tile.tile.worldSize + 2 * padding, height: tile.tile.worldSize + 2 * padding)
      let probe = Probe(plane: tile.plane, tile: tile.tile, pixelSize: tile.pixelSize)
      let read: Read
      if let existing = reads[probe] { read = existing }
      else {
        var cursor: SceneCompositionReadCursor?
        var entries: [WorkspaceSpatialEntry] = []
        for _ in 0..<2 {
          let page = try readPaintOrder(boardID: tile.plane.boardID, coverID: tile.plane.coverID,
            bounds: bounds, after: cursor)
          entries.append(contentsOf: page.entries)
          cursor = page.next
          if cursor == nil { break }
        }
        read = Read(entries: entries, exhausted: cursor == nil)
        reads[probe] = read
      }
      if !read.exhausted || read.entries.contains(where: tile.range.contains) { retained.append(tile) }
    }
    try validate()
    return retained
  }

  func vectorRuns(_ owners: [SceneCompositionLiveOwner]) throws -> [SceneCompositionVectorRun] {
    func identity(_ id: String) -> String { UUID(uuidString: id)?.uuidString.lowercased() ?? id }
    var successors: [SceneCompositionPlane: [String: String]] = [:]
    for (plane, group) in Dictionary(grouping: owners, by: \.plane) {
      let ids = group.compactMap { if case .element(let id) = $0.id { return id }; return nil }
      switch origin {
      case .sql(let store):
        successors[plane] = try checked(store) { try $0.readSceneElementSuccessors(boardID: plane.boardID, elementIDs: ids) }
      case .values(_, let hierarchy, _):
        let surface = plane.coverID.map(SurfaceID.cover) ?? .board(plane.boardID)
        let elements = hierarchy.board(plane.boardID)?.elements.filter { $0.surface == surface } ?? []
        let wanted = Set(ids)
        successors[plane] = Dictionary(uniqueKeysWithValues: zip(elements, elements.dropFirst()).compactMap { a, b in
          wanted.contains(a.id) ? (a.id, identity(b.id)) : nil
        })
      }
    }
    var result: [SceneCompositionVectorRun] = []
    for owner in owners.sorted(by: {
      $0.plane == $1.plane ? $0.position < $1.position : String(describing: $0.plane) < String(describing: $1.plane)
    }) {
      if let last = result.last, last.plane == owner.plane,
        case .element(let previousID) = last.owners.last!.id, case .element(let id) = owner.id,
        successors[owner.plane]?[previousID] == identity(id) {
        result[result.count - 1].owners.append(owner)
      } else { result.append(.init(plane: owner.plane, owners: [owner])) }
    }
    return result
  }

  /// The whole bounded admission borrows one WAL cut. A vector run can contain
  /// dozens of shapes without opening one SQLite connection per shape.
  func positionedOwners(_ candidates: [(plane: SceneCompositionPlane, id: WorkspaceSpatialID)]) throws -> [SceneCompositionLiveOwner] {
    guard candidates.count <= WorkspaceSceneIndex.detailLimit else { throw SceneRenderError.resourceLimit }
    switch origin {
    case .sql(let store):
      return try checked(store) { store in
        try candidates.map { candidate in
          guard let value = try store.readScenePaintPosition(boardID: candidate.plane.boardID,
            coverID: candidate.plane.coverID, id: candidate.id) else { throw SceneRenderError.snapshotPending("live_owner_source") }
          return .init(plane: candidate.plane, id: candidate.id,
            position: .init(layer: value.layer == 0 ? .elements : .covers, zIndex: value.zIndex, key: value.key))
        }
      }
    case .values(let index, _, _):
      return try candidates.map { candidate in
        guard let entry = index.paintEntry(id: candidate.id, boardID: candidate.plane.boardID,
          coverID: candidate.plane.coverID) else { throw SceneRenderError.snapshotPending("live_owner_source") }
        return .init(plane: candidate.plane, id: candidate.id, position: .init(entry: entry))
      }
    }
  }
}

import Foundation
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
  let referenceIdentities: [NotebookReferenceIdentity]
  let referenceInkBasis: NotebookReferenceInkBasis?
  init(documents: [UUID: DocumentDocument], states: [UUID: DocumentStateJournal], pages: [UUID: PageDocument],
    ink: SpatialInkJournal, referenceIdentities: [NotebookReferenceIdentity] = [],
    referenceInkBasis: NotebookReferenceInkBasis? = nil) {
    self.documents = documents; self.states = states; self.pages = pages; self.ink = ink
    self.referenceIdentities = referenceIdentities
    self.referenceInkBasis = referenceInkBasis
  }
}

/// An addressed reader borrows at most one heavy physical source at a time.
/// It never reconstructs the archive from the model's bounded display projection.
/// Each SQL read checks the content cursor inside its read transaction; a changed
/// revision cancels the entire unpublished cohort rather than mixing its tiles.
actor SceneCompositionSource {
  let revision: UInt64
  let workspaceID: UUID
  private enum Origin: Sendable {
    case sql(NotebookStore)
    case values(WorkspaceSceneIndex, BoardHierarchy, SpatialInkJournal)
  }
  private let origin: Origin

  init(store: NotebookStore, revision: UInt64, workspaceID: UUID) {
    origin = .sql(store); self.revision = revision; self.workspaceID = workspaceID
  }
  init(index: WorkspaceSceneIndex, hierarchy: BoardHierarchy, journal: SpatialInkJournal, revision: UInt64 = 0) {
    origin = .values(index, hierarchy, journal); self.revision = revision; workspaceID = index.generationID
  }

  func validate() throws {
    try Task.checkCancellation()
    if case .sql(let store) = origin { try checked(store) { _ in () } }
  }
  private func checked<Value>(_ store: NotebookStore, _ read: (NotebookStore) throws -> Value) throws -> Value {
    try Task.checkCancellation()
    return try store.readTransaction { store in
      let header = try store.workspaceHeader()
      guard header.cursor == revision, header.workspaceID == workspaceID else { throw NotebookStorageError.transactionConflict }
      return try read(store)
    }
  }

  func boardExists(_ id: UUID) throws -> Bool {
    switch origin {
    case .sql(let store): try checked(store) { try $0.readBoardNodeHeader(id) != nil }
    case .values(let index, _, _): index.board(id: id) != nil
    }
  }
  func portalCamera(_ id: UUID) throws -> BoardPortalCamera {
    switch origin {
    case .sql(let store): try checked(store) { try $0.readBoardNodeHeader(id)?.portalCamera ?? .init() }
    case .values(_, let hierarchy, _): hierarchy.portalCamera(id) ?? .init()
    }
  }
  func ink(_ surface: SurfaceID) throws -> SpatialInkJournal {
    switch origin {
    case .sql(let store): try checked(store) { try $0.readSpatialInk(surfaces: [surface]) }
    case .values(_, _, let journal): journal
    }
  }
  func liveData(plan: SceneCompositionPlan, presence: SessionPresence, frame: WorkspaceSceneFrame) throws -> SceneCompositionLiveData {
    guard plan.revision == revision, plan.workspaceID == workspaceID else { throw NotebookStorageError.transactionConflict }
    let itemIDs = Set(plan.liveOwners.compactMap { owner -> UUID? in
      if case .item(let id) = owner.id { return id }; return nil
    }).sorted { $0.uuidString < $1.uuidString }
    let surfaces = [SurfaceID.board(plan.rootBoardID)] + itemIDs.map(SurfaceID.cover)
    guard surfaces.count <= SceneCompositionPlan.maximumLiveOwners else { throw SceneRenderError.resourceLimit }
    switch origin {
    case .sql(let store):
      return try checked(store) { store in
        // Only a selected notebook opens pages. Passive covers need no page
        // archive, while documents retain their same-cursor program and state.
        let documents = try itemIDs.filter { try store.readItemHeader($0)?.kind == .document }
        let pageIDs = presence.selectedItemID.map(itemIDs.contains) == true
          ? (presence.notebookPageID.map { [$0] } ?? []) : []
        let data = try store.readWorkingSet(itemIDs: documents, pageIDs: pageIDs, boardIDs: [], surfaces: surfaces)
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
        let basis = try store.referenceInkBasis(rootBoardID: plan.rootBoardID,
          targets: targets.sorted { $0.key < $1.key }, surfaces: replaceable)
        return .init(documents: data.documents, states: data.states, pages: data.pages, ink: data.ink,
          referenceIdentities: basis.identities, referenceInkBasis: basis)
      }
    case .values(_, _, let journal):
      let wanted = Set(surfaces)
      let ink = SpatialInkJournal(actions: journal.actions.filter { $0.spans.contains { wanted.contains($0.surface) } }, stamp: journal.stamp)
      return .init(documents: [:], states: [:], pages: [:], ink: ink)
    }
  }

  /// A global SQL commit does not invalidate pixels whose sources were not
  /// painted into them. Unknown or oversized changes always rebuild instead.
  func canCarryStaticPixels(from oldPlan: SceneCompositionPlan, liveData oldData: SceneCompositionLiveData,
    to plan: SceneCompositionPlan, liveData data: SceneCompositionLiveData) throws -> Bool {
    guard oldPlan.workspaceID == workspaceID, plan.workspaceID == workspaceID,
      plan.revision == revision, oldPlan.revision <= revision,
      oldPlan.rootBoardID == plan.rootBoardID else { return false }
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
    let surfaces = Set([SurfaceID.board(plan.rootBoardID)] + liveItems.map(SurfaceID.cover))
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
        continue
      }
      let file = String(address.split(separator: "#", maxSplits: 1)[0])
      if let id = documentID(file, directory: "document-states"), liveItems.contains(id),
        oldData.states[id] != nil, data.states[id] != nil { continue }
      if let id = documentID(file, directory: "documents"), liveItems.contains(id),
        let old = oldData.documents[id], let new = data.documents[id], old.paperSize == new.paperSize { continue }
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
    case .sql(let store): try checked(store) { try $0.readSpatialElement(boardID: boardID, elementID: id) }
    case .values(let index, _, _): index.element(id: id, boardID: boardID)
    }
  }
  func item(_ id: UUID, presence: SessionPresence) throws -> RenderedWorkspaceItem? {
    switch origin {
    case .values(let index, _, _): return index.renderedItem(id: id, presence: presence)
    case .sql(let store):
      return try checked(store) { store in
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
        let center = WorkspaceItemStackPresentation.boardCenter(of: id, in: stack, cameraScale: presence.camera.scale, viewport: presence.viewport) ?? stack.center
        return .init(item: header.item, geometry: geometry, center: center,
          zIndex: Double(stack.zIndex) + Double(index) / 100, stackID: stack.id)
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
        let page = try store.readScenePaintOrder(boardID: boardID, coverID: coverID, bounds: bounds, after: cursor, limit: 32)
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

  func position(id: WorkspaceSpatialID, boardID: UUID, coverID: UUID? = nil) throws -> ScenePaintPosition? {
    switch origin {
    case .sql(let store):
      return try checked(store) { store in
        guard let value = try store.readScenePaintPosition(boardID: boardID, coverID: coverID, id: id) else { return nil }
        return .init(layer: value.layer == 0 ? .elements : .covers, zIndex: value.zIndex, key: value.key)
      }
    case .values(let index, _, _):
      return index.paintEntry(id: id, boardID: boardID, coverID: coverID).map(ScenePaintPosition.init)
    }
  }
}

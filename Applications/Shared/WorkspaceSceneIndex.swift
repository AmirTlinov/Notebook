import Foundation
import NotebookCore

/// A derived, immutable view of physical geometry. Sources remain value-shared
/// with their BoardDocument; camera queries neither copy nor inspect their text.
struct WorkspaceSceneIndex: Sendable {
  static let detailLimit = 96

  /// Prepare before a pinch exposes the source, not 32 points before its
  /// boundary crosses the viewport. This only enlarges the bounded spatial
  /// query; entry, live-runtime and raster quotas remain unchanged.
  static func preparationMargin(for presence: SessionPresence) -> Double {
    max(192, max(presence.viewport.x, presence.viewport.y) * 0.75)
  }
  let generationID = UUID()
  // Value-shared sources of this exact projection, retained with a shown
  // cohort so a later model publication cannot redirect a pointing contact.
  let capturedWorkspace: WorkspaceIndex
  let capturedHierarchy: BoardHierarchy

  private struct Item: Sendable {
    let value: WorkspaceItem
    let geometry: WorkspaceItemGeometry
    let center: WorldPoint
    let zIndex: Double
    let stack: WorkspaceItemStack?
  }

  private struct Board: Sendable {
    let source: BoardDocument
    let items: [UUID: Item]
    let elements: [String: SpatialElement]
    let covers: [UUID: [SpatialElement]]
    let coverIndices: [UUID: WorkspaceSpatialIndex]
    let index: WorkspaceSpatialIndex
    let graphics: NotebookGraphicGraph
    let inkClaims: InkClaims
  }

  private struct InkClaims: Sendable {
    let candidates:[NotebookGraphicPresentation.Candidate]
    let indicesByID:[String:Int]
    let indicesBySource:[UUID:[Int]]
    let suppressed:Set<UUID>
    init(_ all:[NotebookGraphicPresentation.Candidate]) {
      candidates=all.filter { !$0.graphic.sourceInkIDs.isEmpty }
      indicesByID=Dictionary(uniqueKeysWithValues:candidates.enumerated().map {
        (collaborationIdentity($0.element.id),$0.offset)
      })
      var sources:[UUID:[Int]]=[:]
      for (index,candidate) in candidates.enumerated() {
        for source in Set(candidate.graphic.sourceInkIDs) { sources[source,default:[]].append(index) }
      }
      indicesBySource=sources
      suppressed=NotebookGraphicPresentation(candidates).suppressedInkIDs
    }
  }

  private let itemValues: [UUID: WorkspaceItem]
  private let pageOwners: [UUID: UUID]
  private let itemOwners: [UUID: UUID]
  private let catalog: [WorkspaceItem]
  private let paperSizes: [UUID: DocumentPaperSize]
  private let boards: [UUID: Board]

  /// A return-boundary projection extends this bounded scene with one addressed
  /// parent window. Paper geometry travels unchanged with its existing owners.
  var documentPaperSizes: [UUID: DocumentPaperSize] { paperSizes }

  init(workspace: WorkspaceIndex, hierarchy: BoardHierarchy, paperSizes: [UUID: DocumentPaperSize]) {
    capturedWorkspace = workspace; capturedHierarchy = hierarchy
    catalog = workspace.items
    self.paperSizes = paperSizes
    let values = Dictionary(uniqueKeysWithValues: workspace.items.map { ($0.id, $0) })
    itemValues = values
    pageOwners = Dictionary(uniqueKeysWithValues: workspace.items.flatMap { item in item.pageIDs.map { ($0, item.id) } })
    itemOwners = Dictionary(uniqueKeysWithValues: hierarchy.boards.flatMap { node in node.board.itemIDs.map { ($0, node.id) } })
    var prepared: [UUID: Board] = [:]
    for node in hierarchy.boards {
      var entries: [WorkspaceSpatialEntry] = []
      var items: [UUID: Item] = [:]
      var elements: [String: SpatialElement] = [:]
      var covers: [UUID: [SpatialElement]] = [:]
      func geometry(_ value: WorkspaceItem) -> WorkspaceItemGeometry? {
        value.kind == .document ? paperSizes[value.id].map(WorkspaceItemGeometry.document) : .notebook
      }
      for placement in node.board.freeItems {
        guard let value = values[placement.itemID], let size = geometry(value) else { continue }
        let item = Item(value: value, geometry: size, center: placement.center,
          zIndex: Double(placement.zIndex), stack: nil)
        items[value.id] = item
        entries.append(.init(id: .item(value.id), bounds: .init(
          origin: placement.center.offsetBy(x: -size.width / 2, y: -size.height / 2),
          width: size.width, height: size.height), zIndex: item.zIndex))
      }
      for stack in node.board.stacks {
        for (position, id) in stack.itemIDs.enumerated() {
          guard let value = values[id], let size = geometry(value) else { continue }
          let item = Item(value: value, geometry: size, center: stack.center,
            zIndex: Double(stack.zIndex) + Double(position) / 100, stack: stack)
          items[id] = item
          let center = WorkspaceItemStackPresentation.focusedCenter(of: id, in: stack) ?? stack.center
          let offset = stack.center.delta(to: center)
          let left = min(0, offset.x) - size.width / 2
          let top = min(0, offset.y) - size.height / 2
          entries.append(.init(id: .item(id), bounds: .init(
            origin: stack.center.offsetBy(x: left, y: top),
            width: max(0, offset.x) + size.width / 2 - left,
            height: max(0, offset.y) + size.height / 2 - top), zIndex: item.zIndex))
        }
      }
      let graphicCandidates=node.board.graphicPresentationCandidates
      let inkClaims=InkClaims(graphicCandidates)
      let graphicPresentation = NotebookGraphicPresentation(graphicCandidates)
      let graphicGraph = node.board.graphicGraph()
      // Whole-pose interaction borrows this local-frame tree. Build it with
      // the immutable scene cut, never on the first Pencil contact.
      for surface in Set(node.board.elements.lazy.filter { $0.kind == .group }.map(\.surface)) {
        graphicGraph.prepareVisibility(on:surface)
      }
      for (position, element) in node.board.elements.enumerated() {
        // The descriptor is addressable for selection, but is not a painter.
        if element.kind == .group { elements[element.id]=element;continue }
        guard element.graphic == nil || graphicPresentation.geometryIDs.contains(element.id) else { continue }
        let layout = element.graphic == nil ? nil : graphicGraph.resolve(element.id).layout
        guard element.graphic == nil || layout != nil else { continue }
        let placement=element.graphic == nil ? graphicGraph.placement(element.id) : nil
        guard let bounds=layout.map({ CGRect(x:$0.frame.x,y:$0.frame.y,width:$0.frame.width,height:$0.frame.height) }) ?? placement.map({ NotebookElementPresentation(element,placement:$0).bounds }) else { continue }
        let frame=PageRect(x:bounds.minX,y:bounds.minY,width:bounds.width,height:bounds.height)
        elements[element.id] = element
        if element.surface == .board(node.id), let origin = layout?.origin ?? placement?.origin {
          entries.append(.init(id: .element(element.id), bounds: .init(
            origin: origin.offsetBy(x: frame.x, y: frame.y),
            width: frame.width, height: frame.height), zIndex: Double(position)))
        } else if element.surface.kind == .cover, let owner = element.surface.ownerID {
          covers[owner, default: []].append(element)
        }
      }
      prepared[node.id] = Board(source: node.board, items: items, elements: elements,
        covers: covers, coverIndices: covers.mapValues { elements in
          WorkspaceSpatialIndex(entries: elements.enumerated().compactMap { offset, element in
            guard let bounds=graphicGraph.resolve(element.id).layout.map({ CGRect(x:$0.frame.x,y:$0.frame.y,width:$0.frame.width,height:$0.frame.height) })
              ?? graphicGraph.placement(element.id).map({ NotebookElementPresentation(element,placement:$0).bounds }) else { return nil }
            let frame=PageRect(x:bounds.minX,y:bounds.minY,width:bounds.width,height:bounds.height)
            return .init(id: .element(element.id), bounds: .init(origin: .init(x: frame.x, y: frame.y),
              width: frame.width, height: frame.height), zIndex: Double(offset))
          })
        }, index: WorkspaceSpatialIndex(entries: entries), graphics: graphicGraph,
        inkClaims:inkClaims)
    }
    boards = prepared
  }

  /// Exact exports borrow a coherent existing generation, or prepare the same
  /// derived index off the UI actor when its publication has not caught up yet.
  static func prepare(workspace: WorkspaceIndex, hierarchy: BoardHierarchy,
    paperSizes: [UUID: DocumentPaperSize], reusing previous: Self?) async throws -> Self {
    let worker = Task.detached(priority: .utility) {
      try Task.checkCancellation()
      if let previous, previous.represents(workspace: workspace, hierarchy: hierarchy, paperSizes: paperSizes) { return previous }
      let index = Self(workspace: workspace, hierarchy: hierarchy, paperSizes: paperSizes)
      try Task.checkCancellation()
      return index
    }
    return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
  }

  /// Comparison runs on the preparation task, never on a camera frame. A
  /// selected page and portal camera are not geometry or source changes.
  func represents(workspace: WorkspaceIndex, hierarchy: BoardHierarchy,
    paperSizes: [UUID: DocumentPaperSize]) -> Bool {
    guard catalog == workspace.items, self.paperSizes == paperSizes,
      boards.count == hierarchy.boards.count else { return false }
    return hierarchy.boards.allSatisfy { boards[$0.id]?.source == $0.board }
  }

  func board(id: UUID) -> BoardDocument? { boards[id]?.source }
  func item(id: UUID) -> WorkspaceItem? { itemValues[id] }
  func pageOwner(pageID: UUID) -> UUID? { pageOwners[pageID] }
  func ownerBoard(itemID: UUID) -> UUID? { itemOwners[itemID] }
  func element(id: String, boardID: UUID) -> SpatialElement? { boards[boardID]?.elements[id] }
  func graphicGraph(boardID: UUID) -> NotebookGraphicGraph? { boards[boardID]?.graphics }

  struct InkSuppressionResult:Sendable {
    let ids:Set<UUID>
    let examinedCandidates:Int
  }

  /// Ink visibility comes from the same immutable claim arbitration as the
  /// renderer. An optimistic edit recomputes only its connected source-claim
  /// component; Pencil-down never walks every graphic on the board.
  func inkSuppression(boardID:UUID,delta:NotebookSpatialInteractionDelta,
    graph:NotebookGraphicGraph)->InkSuppressionResult? {
    guard let board=boards[boardID] else { return nil }
    let changed=Set(delta.presentationIDs.map(collaborationIdentity))
    guard !changed.isEmpty else { return .init(ids:board.inkClaims.suppressed,examinedCandidates:0) }
    var pending=Set<UUID>(),component=Set<Int>()
    for id in changed {
      if let index=board.inkClaims.indicesByID[id] {
        pending.formUnion(board.inkClaims.candidates[index].graphic.sourceInkIDs)
      }
      if !delta.excluded.contains(where:{ collaborationIdentity($0) == id }),let current=graph.node(id) {
        pending.formUnion(current.graphic.sourceInkIDs)
      }
    }
    var visited=Set<UUID>()
    while let source=pending.popFirst() {
      guard visited.insert(source).inserted else { continue }
      for index in board.inkClaims.indicesBySource[source] ?? [] where component.insert(index).inserted {
        pending.formUnion(board.inkClaims.candidates[index].graphic.sourceInkIDs)
      }
    }
    let durable=component.map { board.inkClaims.candidates[$0] }
    let before=NotebookGraphicPresentation(durable).suppressedInkIDs
    let local=changed.sorted().compactMap { id -> NotebookGraphicPresentation.PrioritizedCandidate? in
      guard !delta.excluded.contains(where:{ collaborationIdentity($0) == id }),
        let node=graph.node(id),!node.graphic.sourceInkIDs.isEmpty else { return nil }
      return .init(id:node.id,graphic:node.graphic)
    }
    let remaining=durable.filter { !changed.contains(collaborationIdentity($0.id)) }
    let after=NotebookGraphicPresentation(prioritizing:local,then:remaining).suppressedInkIDs
    return .init(ids:board.inkClaims.suppressed.subtracting(before).union(after),
      examinedCandidates:durable.count+local.count)
  }

  func graphicLayout(id: String, boardID: UUID) -> NotebookGraphicLayout? { boards[boardID]?.graphics.resolve(id).layout }
  func paintEntry(id: WorkspaceSpatialID, boardID: UUID, coverID: UUID? = nil) -> WorkspaceSpatialEntry? {
    guard let board = boards[boardID] else { return nil }
    return coverID.flatMap { board.coverIndices[$0] }?.entry(id: id)
      ?? (coverID == nil ? board.index.entry(id: id) : nil)
  }

  /// Interaction borrows the renderer's immutable spatial generation instead
  /// of walking every retained element. Exact geometry remains in the graph;
  /// this method only narrows the owners which may intersect the gesture.
  func interactionCandidates(boardID: UUID, coverID: UUID? = nil,
    bounds: WorkspaceSpatialBounds, kinds: WorkspaceSpatialKinds,
    limit: Int = 4_096) throws -> WorkspaceSpatialIntersectionQuery? {
    guard let board = boards[boardID] else { return nil }
    let index = coverID.flatMap { board.coverIndices[$0] } ?? (coverID == nil ? board.index : nil)
    guard let index else { return nil }
    let result = index.intersections(in: bounds, kinds: kinds, limit: limit)
    guard !result.overflow else {
      throw CollaborationError("selection_limit",
        "В этой области слишком много объектов.")
    }
    return result
  }

  func renderedItem(id: UUID, presence: SessionPresence) -> RenderedWorkspaceItem? {
    guard let item = boards[presence.boardID]?.items[id] else { return nil }
    return WorkspaceSceneProjection.renderedItem(item.value, geometry: item.geometry,
      center: item.center, zIndex: item.zIndex, stack: item.stack, presence: presence)
  }

  func focusedCenter(itemID: UUID, boardID: UUID) -> WorldPoint? {
    guard let item = boards[boardID]?.items[itemID] else { return nil }
    let center: WorldPoint
    if let stack = item.stack {
      guard let projected = WorkspaceItemStackPresentation.focusedCenter(of: itemID, in: stack) else { return nil }
      center = projected
    } else { center = item.center }
    // The fan remains indexed and rendered outside the address boundary;
    // opening it cannot substitute a different, persistable camera center.
    return center.isValid ? center : nil
  }

  func coverElements(itemID: UUID, boardID: UUID) -> [SpatialElement] {
    boards[boardID]?.covers[itemID] ?? []
  }

  func hasCoverElements(itemID: UUID, boardID: UUID) -> Bool {
    boards[boardID]?.covers[itemID]?.isEmpty == false
  }

  func coverWorkset(item: RenderedWorkspaceItem, presence: SessionPresence,
    pixelScale: Double, limit: Int, pinned: Set<WorkspaceSpatialID> = []) -> WorkspaceSceneWorkset {
    guard let board = boards[presence.boardID], let index = board.coverIndices[item.id] else { return .empty }
    let center = presence.camera.worldToScreen(item.center, viewport: presence.viewport)
    let margin = Self.preparationMargin(for: presence)
    let left = max(0, item.geometry.width / 2 - (center.x + margin) / presence.camera.scale)
    let top = max(0, item.geometry.height / 2 - (center.y + margin) / presence.camera.scale)
    let right = min(item.geometry.width, item.geometry.width / 2 + (presence.viewport.x + margin - center.x) / presence.camera.scale)
    let bottom = min(item.geometry.height, item.geometry.height / 2 + (presence.viewport.y + margin - center.y) / presence.camera.scale)
    let query = index.query(bounds: .init(origin: .init(x: left, y: top),
      width: max(0, right - left), height: max(0, bottom - top)), limit: limit,
      minimumProjectedExtent: 12, scale: pixelScale, pinned: pinned)
    return .init(items: [], elements: query.entries.compactMap {
      if case .element(let id) = $0.id { return board.elements[id] }
      return nil
    }, query: query, generationID: generationID)
  }

  /// Exact preparation reads a bounded painter-order page from the same index
  /// as the live camera. A page may be empty while its cursor still advances.
  func readPaintOrder(boardID: UUID, coverID: UUID? = nil, bounds: WorkspaceSpatialBounds,
    after cursor: WorkspaceSpatialReadCursor? = nil) throws -> WorkspaceSpatialReadPage? {
    guard let board = boards[boardID] else { return nil }
    let index = coverID.flatMap { board.coverIndices[$0] } ?? (coverID == nil ? board.index : nil)
    return try index?.readPaintOrder(in: bounds, after: cursor, limit: 32, maximumVisits: 256)
  }

  func workset(presence: SessionPresence, pinned: Set<WorkspaceSpatialID> = [],
    limit: Int = detailLimit, pixelScale: Double? = nil) -> WorkspaceSceneWorkset {
    guard let board = boards[presence.boardID] else { return .empty }
    let margin = Self.preparationMargin(for: presence) + WorkspaceCoverRaster.shadowPadding * presence.camera.scale
    let origin = presence.camera.screenToWorld(.init(x: -margin, y: -margin), viewport: presence.viewport)
    let bounds = WorkspaceSpatialBounds(origin: origin,
      width: (presence.viewport.x + 2 * margin) / presence.camera.scale,
      height: (presence.viewport.y + 2 * margin) / presence.camera.scale)
    var pins = pinned
    if let focused = presence.focusedItemID { pins.insert(.item(focused)) }
    // A selected cover element pins its physical owner, not a second surface.
    for pin in pinned {
      if case .element(let id) = pin, let element = board.elements[id],
        element.surface.kind == .cover, let owner = element.surface.ownerID {
        pins.insert(.item(owner))
      }
    }
    let query = board.index.query(bounds: bounds, limit: limit, minimumProjectedExtent: 12,
      scale: pixelScale ?? presence.camera.scale, pinned: pins)
    var items: [RenderedWorkspaceItem] = []
    var elements: [SpatialElement] = []
    for entry in query.entries {
      switch entry.id {
      case .item(let id):
        if let item = renderedItem(id: id, presence: presence) { items.append(item) }
      case .element(let id):
        if let element = board.elements[id] { elements.append(element) }
      }
    }
    return .init(items: items, elements: elements, query: query, generationID: generationID)
  }
}

struct WorkspaceSceneWorkset {
  let items: [RenderedWorkspaceItem]
  let elements: [SpatialElement]
  let query: WorkspaceSpatialQuery?
  let generationID: UUID?
  var aggregates: [WorkspaceSpatialAggregate] { query?.aggregates ?? [] }
  var examinedEntries: Int { query?.statistics.examinedEntries ?? 0 }
  var visitedNodes: Int { query?.statistics.visitedNodes ?? 0 }
  static var empty: Self { .init(items: [], elements: [], query: nil, generationID: nil) }
}

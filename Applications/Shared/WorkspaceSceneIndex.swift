import Foundation
import NotebookCore

/// A derived, immutable view of physical geometry. Sources remain value-shared
/// with their BoardDocument; camera queries neither copy nor inspect their text.
struct WorkspaceSceneIndex: Sendable {
  static let detailLimit = 96
  let generationID = UUID()

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
  }

  private let itemValues: [UUID: WorkspaceItem]
  private let pageOwners: [UUID: UUID]
  private let itemOwners: [UUID: UUID]
  private let catalog: [WorkspaceItem]
  private let paperSizes: [UUID: DocumentPaperSize]
  private let boards: [UUID: Board]

  init(workspace: WorkspaceIndex, hierarchy: BoardHierarchy, documents: [UUID: DocumentDocument]) {
    catalog = workspace.items
    let sizes = documents.mapValues(\.paperSize)
    paperSizes = sizes
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
        value.kind == .document ? sizes[value.id].map(WorkspaceItemGeometry.document) : .notebook
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
          // The collapsed stack uses screen-point spacing. Its minimum-scale
          // endpoint and fully fanned endpoint enclose every interpolated anchor.
          let collapsed = WorkspaceItemStackPresentation.boardCenter(of: id, in: stack,
            cameraScale: SpatialCamera.minimumScale, viewport: .init(x: 834, y: 1194)) ?? stack.center
          let fanned = WorkspaceItemStackPresentation.focusedCenter(of: id, in: stack) ?? stack.center
          let a = stack.center.delta(to: collapsed), b = stack.center.delta(to: fanned)
          let left = min(0, a.x, b.x) - size.width / 2
          let top = min(0, a.y, b.y) - size.height / 2
          entries.append(.init(id: .item(id), bounds: .init(
            origin: stack.center.offsetBy(x: left, y: top),
            width: max(0, a.x, b.x) + size.width / 2 - left,
            height: max(0, a.y, b.y) + size.height / 2 - top), zIndex: item.zIndex))
        }
      }
      for (position, element) in node.board.elements.enumerated() {
        elements[element.id] = element
        if element.surface == .board(node.id), let origin = element.worldOrigin {
          entries.append(.init(id: .element(element.id), bounds: .init(
            origin: origin.offsetBy(x: element.frame.x, y: element.frame.y),
            width: element.frame.width, height: element.frame.height), zIndex: Double(position)))
        } else if element.surface.kind == .cover, let owner = element.surface.ownerID {
          covers[owner, default: []].append(element)
        }
      }
      prepared[node.id] = Board(source: node.board, items: items, elements: elements,
        covers: covers, coverIndices: covers.mapValues { elements in
          WorkspaceSpatialIndex(entries: elements.enumerated().map { offset, element in
            .init(id: .element(element.id), bounds: .init(origin: .init(x: element.frame.x, y: element.frame.y),
              width: element.frame.width, height: element.frame.height), zIndex: Double(offset))
          })
        }, index: WorkspaceSpatialIndex(entries: entries))
    }
    boards = prepared
  }

  /// Exact exports borrow a coherent existing generation, or prepare the same
  /// derived index off the UI actor when its publication has not caught up yet.
  static func prepare(workspace: WorkspaceIndex, hierarchy: BoardHierarchy,
    documents: [UUID: DocumentDocument], reusing previous: Self?) async throws -> Self {
    let worker = Task.detached(priority: .utility) {
      try Task.checkCancellation()
      if let previous, previous.represents(workspace: workspace, hierarchy: hierarchy, documents: documents) { return previous }
      let index = Self(workspace: workspace, hierarchy: hierarchy, documents: documents)
      try Task.checkCancellation()
      return index
    }
    return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
  }

  /// Comparison runs on the preparation task, never on a camera frame. A
  /// selected page and portal camera are not geometry or source changes.
  func represents(workspace: WorkspaceIndex, hierarchy: BoardHierarchy,
    documents: [UUID: DocumentDocument]) -> Bool {
    guard catalog == workspace.items, paperSizes == documents.mapValues(\.paperSize),
      boards.count == hierarchy.boards.count else { return false }
    return hierarchy.boards.allSatisfy { boards[$0.id]?.source == $0.board }
  }

  func board(id: UUID) -> BoardDocument? { boards[id]?.source }
  func item(id: UUID) -> WorkspaceItem? { itemValues[id] }
  func pageOwner(pageID: UUID) -> UUID? { pageOwners[pageID] }
  func ownerBoard(itemID: UUID) -> UUID? { itemOwners[itemID] }
  func element(id: String, boardID: UUID) -> SpatialElement? { boards[boardID]?.elements[id] }

  func renderedItem(id: UUID, presence: SessionPresence) -> RenderedWorkspaceItem? {
    guard let item = boards[presence.boardID]?.items[id] else { return nil }
    var center = item.center
    if let stack = item.stack {
      if presence.mode != .board, let focused = presence.focusedItemID,
        stack.itemIDs.contains(focused), focused != id { return nil }
      center = WorkspaceItemStackPresentation.boardCenter(of: id, in: stack,
        cameraScale: presence.camera.scale, viewport: presence.viewport) ?? center
    }
    return .init(item: item.value, geometry: item.geometry, center: center,
      zIndex: item.zIndex, stackID: item.stack?.id)
  }

  func focusedCenter(itemID: UUID, boardID: UUID) -> WorldPoint? {
    guard let item = boards[boardID]?.items[itemID] else { return nil }
    return item.stack.flatMap { WorkspaceItemStackPresentation.focusedCenter(of: itemID, in: $0) } ?? item.center
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
    let left = max(0, item.geometry.width / 2 - (center.x + 96) / presence.camera.scale)
    let top = max(0, item.geometry.height / 2 - (center.y + 96) / presence.camera.scale)
    let right = min(item.geometry.width, item.geometry.width / 2 + (presence.viewport.x + 96 - center.x) / presence.camera.scale)
    let bottom = min(item.geometry.height, item.geometry.height / 2 + (presence.viewport.y + 96 - center.y) / presence.camera.scale)
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
    let margin = 96 + WorkspaceCoverRaster.shadowPadding * presence.camera.scale
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

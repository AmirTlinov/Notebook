import Foundation
import NotebookCore

/// One WAL snapshot supplies a bounded scene projection. A missing item outside
/// its coverage is not a deletion; native commands name their before/after scope.
struct NotebookSceneState: Sendable {
  let header: NotebookWorkspaceHeader
  let workspace: WorkspaceIndex
  let pages: [UUID: PageDocument]
  let pagePositions: [NotebookPagePosition]
  let documents: [UUID: DocumentDocument]
  let states: [UUID: DocumentStateJournal]
  let drafts: [DocumentEditingSession]
  let hierarchy: BoardHierarchy
  let ink: SpatialInkJournal
  let inkSurfaces: Set<SurfaceID>
  let presence: SessionPresence
  let paperSizes: [UUID: DocumentPaperSize]
  let coverage: [UUID: WorkspaceSpatialBounds]
  let truncatedBoards: Set<UUID>
  let missingPinnedElements: Set<String>
  let missingPinnedItems: Set<UUID>
  let transferredPinnedItems: [UUID: UUID]

  static func start(store: NotebookStore, actor: UUID, pageSize: PageSize,
    notebookID: UUID, pageID: UUID) throws -> Self {
    _ = try store.initializeWorkspace(actor: actor, pageSize: pageSize,
      initialNotebookID: notebookID, initialPageID: pageID)
    try store.resetInputActivities()
    return try read(store: store, presence: nil, viewport: .init(x: pageSize.width, y: pageSize.height))
  }

  static func bounds(for presence: SessionPresence, margin: Double = 192) -> WorkspaceSpatialBounds {
    .init(origin: presence.camera.screenToWorld(.init(x: -margin, y: -margin), viewport: presence.viewport),
      width: (presence.viewport.x + margin * 2) / presence.camera.scale,
      height: (presence.viewport.y + margin * 2) / presence.camera.scale)
  }

  static func read(store: NotebookStore, presence requested: SessionPresence?, viewport: SpatialPoint, loadsLiveContent: Bool = true, pinnedElements: [UUID: [String]] = [:], pinnedItems: [UUID: [UUID]] = [:], preparedPages: [UUID] = []) throws -> Self {
    guard preparedPages.count <= 4, Set(preparedPages).count == preparedPages.count else {
      throw NotebookStorageError.limitExceeded("scene_page_pins")
    }
    let requestedItems = pinnedItems.values.flatMap { $0 }
    guard requestedItems.count <= 7, Set(requestedItems).count == requestedItems.count else {
      throw NotebookStorageError.limitExceeded("scene_item_pins")
    }
    return try store.readTransaction { store in
      let header = try store.workspaceHeader()
      var missingPinnedItems = Set<UUID>(), transferredPinnedItems: [UUID: UUID] = [:]
      var presentItemPins: [UUID: [UUID]] = [:]
      for (expectedBoard, ids) in pinnedItems {
        for id in ids {
          guard try store.readItemHeader(id) != nil else { missingPinnedItems.insert(id); continue }
          guard let owner = try store.ownerBoardID(of: id) else { throw NotebookStorageError.corruptRecord("item owner") }
          if owner == expectedBoard { presentItemPins[owner, default: []].append(id) }
          else { transferredPinnedItems[id] = owner }
        }
      }
      let storedPresence: SessionPresence?
      do { storedPresence = try store.loadPresence() }
      catch CocoaError.fileReadNoSuchFile { storedPresence = nil }
      catch CocoaError.fileNoSuchFile { storedPresence = nil }
      let considered = requested ?? storedPresence
      let selectedID = considered?.selectedItemID ?? header.selectedItemID
      let selectedHeader = try selectedID.flatMap { try store.readItemHeader($0) }
        ?? store.readItemHeaders(limit: 1).first
      guard let selectedHeader else { throw NotebookStorageError.corruptRecord("empty workspace") }
      var selected = selectedHeader.item
      var pagePositions: [NotebookPagePosition] = [], pages: [UUID: PageDocument] = [:]
      var pageID: UUID?
      if selected.kind == .notebook {
        let notebook = try store.readNotebookPageWindow(itemID: selected.id, pages: []).header
        let requestedID = considered?.notebookPageID ?? notebook.selectedPageID
        let position = try requestedID.flatMap { try store.resolveNotebookPage($0, in: selected.id, expectedVisibleRoot: notebook.visibleRoot) }
          ?? store.resolveNotebookPage(selectedHeader.firstPageID!, in: selected.id, expectedVisibleRoot: notebook.visibleRoot)
        guard let position else { throw NotebookStorageError.corruptRecord("selected notebook page") }
        pageID = position.pageID
        if !preparedPages.isEmpty {
          let requested = [position.pageID] + preparedPages.filter { $0 != position.pageID }
          pagePositions = try requested.prefix(4).compactMap {
            try store.resolveNotebookPage($0, in: selected.id, expectedVisibleRoot: notebook.visibleRoot)
          }
        } else {
          let first = max(0, min(position.index - 1, selectedHeader.pageCount - 4))
          let directory = try store.readNotebookPageDirectory(itemID: selected.id, from: first, limit: 4,
            expectedVisibleRoot: notebook.visibleRoot)
          pagePositions = directory.pages.map(\.position)
        }
        if loadsLiveContent {
          let window = try store.readNotebookPageWindow(itemID: selected.id,
            pages: pagePositions.map { .page($0.pageID) }, expectedVisibleRoot: notebook.visibleRoot)
          pages = Dictionary(uniqueKeysWithValues: window.pages.map { ($0.document.id, $0.document) })
        }
        selected = .notebook(id: selected.id, title: selected.title,
          pageIDs: [selectedHeader.firstPageID!] + pagePositions.map(\.pageID).filter { $0 != selectedHeader.firstPageID })
      }
      let owner = try store.ownerBoardID(of: selected.id) ?? header.rootBoardID
      let desiredBoard = considered?.boardID ?? owner
      let boardID = try store.readBoardNodeHeader(desiredBoard) == nil ? header.rootBoardID : desiredBoard
      let selectedPaper = selected.kind == .document ? try store.readDocumentPaperSize(selected.id) : nil
      let geometry = selectedPaper.map(WorkspaceItemGeometry.document) ?? .notebook
      let presence: SessionPresence
      if let considered, considered.boardID == boardID,
        considered.focusedItemID == nil || (considered.focusedItemID == selected.id && owner == boardID) {
        presence = considered.adapted(to: viewport, geometry: geometry).selecting(itemID: selected.id, pageID: pageID)
      } else {
        let placement = try store.readBoardItem(selected.id)
        let center = placement?.board.focusedCenter(of: selected.id) ?? .zero
        let opensInitialPaper = considered == nil && selected.kind != .board
        presence = .init(boardID: boardID,
          mode: opensInitialPaper ? (selected.kind == .document ? .document : .page) : .board,
          camera: .init(center: center, scale: opensInitialPaper ? geometry.fitScale(viewport: viewport) : 0.22),
          viewport: viewport, focusedItemID: opensInitialPaper ? selected.id : nil,
          openProgress: opensInitialPaper ? 1 : 0,
          selectedItemID: selected.id, notebookPageID: pageID)
      }
      var items: [UUID: WorkspaceItem] = [selected.id: selected]
      var nodes: [UUID: BoardNode] = [:]
      var paper: [UUID: DocumentPaperSize] = [:]
      var coverage: [UUID: WorkspaceSpatialBounds] = [:], truncated = Set<UUID>()
      var pending: [SessionPresence] = [presence]
      var remainingEntries = 96
      var missingPinnedElements = Set<String>()
      while !pending.isEmpty, coverage.count < 4, remainingEntries > 0 {
        let view = pending.removeFirst()
        guard coverage[view.boardID] == nil else { continue }
        let bounds = bounds(for: view)
        var pins = view.focusedItemID.map { [$0] } ?? []
        for id in presentItemPins[view.boardID] ?? [] where !pins.contains(id) { pins.append(id) }
        // Selection is an addressed owner even outside the camera. Its placement
        // must survive a bounded query so the next reveal can keep the same page.
        if view.boardID == owner, !pins.contains(selected.id) { pins.append(selected.id) }
        let elementPins = try (pinnedElements[view.boardID] ?? []).filter { id in
          if try store.readSpatialElement(boardID: view.boardID, elementID: id) != nil { return true }
          missingPinnedElements.insert(id); return false
        }
        let window = try store.readSceneWindow(boardID: view.boardID, bounds: bounds,
          limit: remainingEntries, pinnedIDs: pins, pinnedElementIDs: elementPins)
        for item in window.items where item.id != selected.id { items[item.id] = item }
        for node in window.boards { nodes[node.id] = node }
        paper.merge(window.documentPaper) { _, next in next }
        coverage[view.boardID] = bounds
        if window.truncated { truncated.insert(view.boardID) }
        remainingEntries -= min(remainingEntries, window.totalMatches)
        for item in window.items where item.kind == .board && coverage[item.id] == nil {
          guard pending.count + coverage.count < 4,
            let node = try store.readBoardNodeHeader(item.id) else { continue }
          nodes[node.id] = node
          pending.append(.init(boardID: item.id, mode: .board,
            camera: BoardPortalProjection.entryCamera(portalCamera: node.portalCamera,
              viewport: BoardPortalProjection.viewport), viewport: BoardPortalProjection.viewport))
        }
      }
      // The next portal exit needs only its parent's placement and camera, not
      // an archive-sized parent BoardDocument.
      if boardID != header.rootBoardID, let parent = try store.readBoardItem(boardID) {
        if nodes[parent.id] == nil { nodes[parent.id] = parent }
        if let portal = try store.readItemHeader(boardID) { items[portal.id] = portal.item }
      }
      if nodes[header.rootBoardID] == nil, let root = try store.readBoardNodeHeader(header.rootBoardID) {
        nodes[root.id] = root
      }
      if nodes[owner] == nil, let placement = try store.readBoardItem(selected.id) { nodes[owner] = placement }
      let boardIDs = [boardID] + nodes.keys.filter { $0 != boardID }.sorted { $0.uuidString < $1.uuidString }.prefix(6)
      var heavyIDs = selected.kind == .document ? [selected.id] : []
      let candidates = items.values.filter { $0.id != selected.id && $0.kind == .document }
        .sorted { $0.id.uuidString < $1.id.uuidString }
      heavyIDs += candidates.prefix(max(0, 8 - boardIDs.count - 1)).map(\.id)
      let coverIDs = [selected.id] + heavyIDs.filter { $0 != selected.id }
      let surfaces = (boardIDs.map(SurfaceID.board) + coverIDs.map(SurfaceID.cover)).prefix(8)
      let live = try store.readWorkingSet(itemIDs: loadsLiveContent ? heavyIDs : [], pageIDs: [],
        boardIDs: boardIDs, surfaces: Array(surfaces))
      for item in live.items where item.id != selected.id { items[item.id] = item.item }
      paper.merge(live.documents.mapValues(\.paperSize)) { _, next in next }
      let workspace = try store.workspaceProjection(items: items.values.sorted { $0.id.uuidString < $1.id.uuidString },
        selectedItemID: selected.id, selectedPageID: pageID)
      let hierarchy = BoardHierarchy(rootBoardID: header.rootBoardID,
        boards: nodes.values.sorted { $0.id.uuidString < $1.id.uuidString },
        stamp: header.boardStamp ?? nodes.values.map { max($0.board.stamp, $0.portalStamp) }.max() ?? header.stamp)
      return try Self(header: header, workspace: workspace, pages: pages, pagePositions: pagePositions,
        documents: live.documents, states: live.states,
        drafts: loadsLiveContent && selected.kind == .document ? store.documentEditingSessions(documentID: selected.id) : [],
        hierarchy: hierarchy, ink: live.ink, inkSurfaces: Set(surfaces), presence: presence, paperSizes: paper,
        coverage: coverage, truncatedBoards: truncated, missingPinnedElements: missingPinnedElements,
        missingPinnedItems: missingPinnedItems, transferredPinnedItems: transferredPinnedItems)
    }
  }
}

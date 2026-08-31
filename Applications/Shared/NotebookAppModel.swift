import Foundation
import Observation
import NotebookCore

typealias PencilInputCompletion = @MainActor @Sendable () -> Void
typealias PencilInputFinisher = (@escaping PencilInputCompletion) -> Void

@MainActor
final class PencilInputGate {
  private var pageFinisher: PencilInputFinisher?
  private var activePencilSources: Set<UUID> = []
  private var fingerSequenceRevision: UInt64 = 0

  func registerPageFinisher(_ finisher: @escaping PencilInputFinisher) {
    pageFinisher = finisher
  }

  func performAfterPageInput(_ action: @escaping PencilInputCompletion) {
    if let pageFinisher {
      pageFinisher(action)
    } else {
      action()
    }
  }

  /// Pencil owns the surface from contact to lift. A later finger command may
  /// wait for the page finisher, while any pair overlapping this contact stays
  /// part of the hand movement rather than becoming a second command.
  func beginPencilAction(source: UUID) {
    guard activePencilSources.insert(source).inserted else { return }
    fingerSequenceRevision &+= 1
  }

  func endPencilAction(source: UUID) {
    activePencilSources.remove(source)
  }

  func beginFingerSequence() -> UInt64? {
    activePencilSources.isEmpty ? fingerSequenceRevision : nil
  }

  func acceptsFingerSequence(_ revision: UInt64) -> Bool {
    activePencilSources.isEmpty && revision == fingerSequenceRevision
  }
}

@MainActor
@Observable
final class NotebookAppModel {
  enum LoadState: Equatable {
    case loading
    case ready
    case failed(String)
  }

  static let initialNotebookID = UUID(
    uuidString: "7E7A0000-0000-4000-8000-000000000001"
  )!
  static let initialPageID = UUID(
    uuidString: "7E7A0000-0000-4000-8000-000000000002"
  )!
  static let defaultPageSize = PageSize(width: 834, height: 1_194)

  private(set) var loadState: LoadState = .loading
  private(set) var workspace: WorkspaceIndex?
  private(set) var pages: [UUID: PageDocument] = [:]
  private(set) var documents: [UUID: DocumentDocument] = [:]
  private(set) var documentStates: [UUID: DocumentStateJournal] = [:]
  private(set) var board: BoardDocument?
  private(set) var spatialInk: SpatialInkJournal?
  private(set) var presence: SessionPresence?
  private(set) var presencePhase = PresencePhase.settled
  private(set) var actionCue: String?
  private(set) var penStyle: PenStyle
  private(set) var eraserStyle: EraserStyle
  private(set) var drawingTool: DrawingTool = .pen

  let store: NotebookStore
  let actorID: UUID
  let pencilInputGate = PencilInputGate()

  private var pageSize = defaultPageSize
  private var started = false
  private var saveTasks: [UUID: Task<Void, Never>] = [:]
  /// A peer sends a new page before publishing the catalog that owns it. Keep
  /// that page out of the durable and visible page set until the newer index
  /// arrives; the same boundary also makes a late page for a deleted notebook
  /// harmless.
  private var stagedRemotePages: [UUID: PageDocument] = [:]
  private var stagedRemoteDocuments: [UUID: DocumentDocument] = [:]
  private var stagedRemoteDocumentStates: [UUID: DocumentStateJournal] = [:]
  private var stagedRemoteIndex: WorkspaceIndex?
  private var stagedRemoteBoard: BoardDocument?
  private var spatialInkSaveTask: Task<Void, Never>?
  private var cueTask: Task<Void, Never>?
  private var pencilUndoHistory = PencilUndoHistory()
  private var reservedDrawingCounters: [UUID: UInt64] = [:]
  private let presenceSessionID = UUID()
  private var presenceSequence: UInt64 = 0
  private var lastSettledPresenceEnvelope: PresenceEnvelope?
  private var presenceSequenceTracker = PresenceSequenceTracker()
  private let startsNearbySync: Bool
  private let sync: NearbySync
  #if os(macOS)
    /// MCP writes the same files as the app. This observer belongs to the
    /// long-lived model, so closing the mirror window cannot stop delivery to
    /// the iPad while the Mac app is still running.
    private var externalChangeWatcher: DirectoryWatcher?
    private var externalReloadRetry: Task<Void, Never>?
  #endif

  init(
    store: NotebookStore = NotebookStore(root: NotebookStore.defaultRoot),
    startsNearbySync: Bool = true
  ) {
    self.store = store
    self.startsNearbySync = startsNearbySync
    penStyle = Self.loadPenStyle()
    eraserStyle = Self.loadEraserStyle()
    actorID = Self.loadActorID()
    #if os(iOS)
      let syncRole = NearbySync.Role.iPadConnector
    #else
      let syncRole = NearbySync.Role.macListener
    #endif
    sync = NearbySync(
      role: syncRole,
      peerName: actorID.uuidString.lowercased()
    )
    sync.onMessage = { [weak self] message in
      self?.receivePeerMessage(message)
    }
    sync.onConnect = { [weak self] in
      self?.sendSnapshot()
    }
    sync.onDisconnect = { [weak self] in
      self?.restoreSettledPresenceAfterDisconnect()
    }
  }

  var activePage: PageDocument? {
    guard let pageID = workspace?.selectedPageID else { return nil }
    return pages[pageID]
  }

  var activeItem: WorkspaceItem? {
    workspace?.selectedItem
  }

  var activeDocument: DocumentDocument? {
    guard let item = activeItem, item.kind == .document else { return nil }
    return documents[item.id]
  }

  var activeDocumentState: DocumentStateJournal? {
    guard let item = activeItem, item.kind == .document else { return nil }
    return documentStates[item.id]
  }

  var isPageOpen: Bool {
    presence?.mode == .page && (presence?.openProgress ?? 0) >= 0.999
  }

  func start(pageSize: PageSize) {
    guard !started else { return }
    started = true
    self.pageSize = pageSize
    do {
      let stored = try store.loadOrCreate(
        actor: actorID,
        pageSize: pageSize,
        initialNotebookID: Self.initialNotebookID,
        initialPageID: Self.initialPageID
      )
      workspace = stored.0
      pages = stored.1
      let storedDocuments = try store.loadAvailableDocuments(
        workspace: stored.0
      )
      documents = storedDocuments.documents
      documentStates = storedDocuments.states
      board = try store.loadOrCreateBoard(
        workspace: stored.0,
        actor: actorID
      )
      spatialInk = try store.loadOrCreateSpatialInk(actor: actorID)
      presence = initialPresence(
        workspace: stored.0,
        board: board,
        viewport: pageSize
      )
      if let diskPresence = try? store.loadPresence(),
        presenceIsUsable(diskPresence, workspace: stored.0)
      {
        presence = settledPresence(
          from: diskPresence,
          workspace: stored.0,
          board: board,
          viewport: SpatialPoint(x: pageSize.width, y: pageSize.height)
        )
      }
      if let presence {
        try? store.savePresence(presence)
        lastSettledPresenceEnvelope = makePresenceEnvelope(
          presence,
          phase: .settled
        )
      }
      loadState = .ready
      #if os(macOS)
        startExternalChangeObservation()
      #endif
      if startsNearbySync {
        sync.start()
      }
    } catch {
      loadState = .failed(error.localizedDescription)
    }
  }

  func turnPage(_ direction: Int) {
    guard var workspace else { return }
    let created = workspace.turnPage(
      by: direction,
      actor: actorID,
      pageSize: pageSize
    )
    guard workspace != self.workspace else { return }
    if let created {
      pages[created.id] = created
      try? store.savePage(created)
      sync.send(.page(created))
    }
    self.workspace = workspace
    try? store.saveIndex(workspace)
    sync.send(.index(workspace))
    if let selectedPageIndex = workspace.selectedPageIndex {
      showCue("Страница \(selectedPageIndex + 1)")
    }
  }

  @discardableResult
  func createNotebook(at center: WorldPoint) -> UUID? {
    guard var workspace, var board else { return nil }
    guard let created = workspace.createNotebook(
      title: "",
      actor: actorID,
      pageSize: pageSize
    ), board.addItem(created.item.id, near: center, actor: actorID)
    else { return nil }

    do {
      try store.saveWorkspaceBundle(
        index: workspace,
        page: created.page,
        board: board
      )
    } catch {
      showCue("Не удалось создать тетрадь")
      return nil
    }

    self.workspace = workspace
    self.board = board
    pages[created.page.id] = created.page
    sync.send(.page(created.page))
    sync.send(.board(board))
    sync.send(.index(workspace))
    showCue("Новая тетрадь")
    return created.item.id
  }

  @discardableResult
  func createDocument(at center: WorldPoint) -> UUID? {
    guard var workspace, var board,
      let item = workspace.createDocument(title: "", actor: actorID),
      board.addItem(item.id, near: center, actor: actorID)
    else { return nil }

    let document = DocumentDocument(id: item.id, actor: actorID)
    let state = DocumentStateJournal(id: item.id, actor: actorID)
    do {
      try store.saveDocumentWorkspaceBundle(
        index: workspace,
        document: document,
        state: state,
        board: board
      )
    } catch {
      showCue("Не удалось создать документ")
      return nil
    }

    self.workspace = workspace
    self.board = board
    documents[item.id] = document
    documentStates[item.id] = state
    sync.send(.document(document))
    sync.send(.documentState(state))
    sync.send(.board(board))
    sync.send(.index(workspace))
    showCue("Новый документ")
    return item.id
  }

  func selectItem(_ itemID: UUID) {
    guard var workspace,
      workspace.selectItem(itemID, actor: actorID)
    else { return }
    self.workspace = workspace
    try? store.saveIndex(workspace)
    sync.send(.index(workspace))
  }

  @discardableResult
  func deleteItem(_ itemID: UUID) -> Bool {
    guard var workspace, var board else { return false }
    guard let removed = workspace.deleteItem(itemID, actor: actorID) else {
      showCue("Один рабочий элемент должен остаться")
      return false
    }
    guard board.deleteItem(itemID, actor: actorID) else { return false }

    do {
      try store.deleteWorkspaceBundle(
        index: workspace,
        board: board,
        pageIDs: removed.pageIDs,
        documentIDs: removed.kind == .document ? [removed.id] : []
      )
    } catch {
      showCue("Не удалось удалить элемент")
      return false
    }

    for pageID in removed.pageIDs {
      saveTasks[pageID]?.cancel()
      saveTasks[pageID] = nil
      pages[pageID] = nil
      stagedRemotePages[pageID] = nil
      reservedDrawingCounters[pageID] = nil
      pencilUndoHistory.discardChanges(for: pageID)
    }
    documents[removed.id] = nil
    documentStates[removed.id] = nil
    stagedRemoteDocuments[removed.id] = nil
    stagedRemoteDocumentStates[removed.id] = nil
    self.workspace = workspace
    self.board = board
    sync.send(.board(board))
    sync.send(.index(workspace))

    if let presence, presence.focusedItemID == itemID {
      updatePresence(
        SessionPresence(
          mode: .board,
          camera: presence.camera,
          viewport: presence.viewport
        ),
        settled: true
      )
    }
    showCue(removed.kind == .document ? "Документ удалён" : "Тетрадь удалена")
    return true
  }

  func moveItem(_ itemID: UUID, to center: WorldPoint) {
    guard var board,
      board.moveItem(itemID, to: center, actor: actorID),
      let workspace
    else { return }
    self.board = board
    let itemIDs = Set(workspace.items.map(\.id))
    try? store.saveBoard(board, itemIDs: itemIDs)
    sync.send(.board(board))
  }

  @discardableResult
  func stackItem(_ movingID: UUID, onto targetID: UUID) -> UUID? {
    guard var board,
      let stackID = board.createStack(
        moving: movingID,
        onto: targetID,
        actor: actorID
      ), let workspace
    else { return nil }
    self.board = board
    try? store.saveBoard(
      board,
      itemIDs: Set(workspace.items.map(\.id))
    )
    sync.send(.board(board))
    showCue("Стопка")
    return stackID
  }

  func unstackItem(_ itemID: UUID, at center: WorldPoint) {
    guard var board,
      board.unstackItem(itemID, at: center, actor: actorID),
      let workspace
    else { return }
    self.board = board
    try? store.saveBoard(
      board,
      itemIDs: Set(workspace.items.map(\.id))
    )
    sync.send(.board(board))
  }

  func updatePresence(_ presence: SessionPresence, settled: Bool) {
    guard presence.isValid else { return }
    let resolved: SessionPresence
    if settled, let workspace {
      resolved = settledPresence(
        from: presence,
        workspace: workspace,
        board: board,
        viewport: presence.viewport
      )
    } else {
      resolved = presence
    }
    self.presence = resolved
    let phase = settled ? PresencePhase.settled : .active
    presencePhase = phase
    #if os(iOS)
      guard let envelope = makePresenceEnvelope(resolved, phase: phase) else {
        return
      }
      sync.send(.presence(envelope))
      if settled {
        lastSettledPresenceEnvelope = envelope
        try? store.savePresence(resolved)
      }
    #else
      if settled { try? store.savePresence(resolved) }
    #endif
  }

  func appendSpatialInk(
    tool: SpatialInkTool,
    color: SpatialInkColor,
    spans: [SpatialInkSpan]
  ) {
    guard var journal = spatialInk,
      journal.append(
        tool: tool,
        color: color,
        spans: spans,
        actor: actorID
      ) != nil
    else { return }
    spatialInk = journal
    sync.send(.spatialInk(journal))
    scheduleSpatialInkSave()
  }

  func undoLastSurfaceAction() {
    guard presence?.mode != .document else { return }
    if isPageOpen {
      undoLastDrawingAction()
      return
    }
    guard var journal = spatialInk else { return }
    let surface: SurfaceID? = presence?.focusedItemID.map(SurfaceID.cover)
    guard journal.undoLast(actor: actorID, touching: surface) != nil
      || (surface != nil && journal.undoLast(actor: actorID) != nil)
    else { return }
    spatialInk = journal
    sync.send(.spatialInk(journal))
    scheduleSpatialInkSave()
    showCue("Отменено")
  }

  func afterPageInput(_ action: @escaping PencilInputCompletion) {
    pencilInputGate.performAfterPageInput(action)
  }

  func addNativeText(on itemID: UUID, at point: SpatialPoint) -> String? {
    guard var board, board.itemIDs.contains(itemID) else { return nil }
    let width = 420.0
    let height = 120.0
    let origin = SpatialPoint(
      x: min(max(point.x, 0), NotebookGeometry.width - width),
      y: min(max(point.y, 0), NotebookGeometry.height - height)
    )
    let id = "text-\(UUID().uuidString.lowercased())"
    let element = SpatialElement(
      id: id,
      surface: .cover(itemID),
      kind: .nativeText,
      frame: SpatialRect(
        x: origin.x,
        y: origin.y,
        width: width,
        height: height
      ),
      source: "",
      stamp: VersionStamp(counter: 0, actor: actorID)
    )
    guard board.upsertElement(element, expected: nil, actor: actorID) else {
      return nil
    }
    persistBoard(board)
    return id
  }

  func updateNativeText(elementID: String, text: String) {
    guard var board,
      let index = board.elements.firstIndex(where: {
        $0.id == elementID && $0.kind == .nativeText
      })
    else { return }
    var element = board.elements[index]
    guard element.source != text else { return }
    let expected = element.stamp
    guard element.update(source: text, actor: actorID),
      board.upsertElement(element, expected: expected, actor: actorID)
    else { return }
    persistBoard(board)
  }

  /// Ends the editor's ownership of one native text element. A blank draft has
  /// no visible meaning, so ending its edit removes it from the cover and from
  /// the durable board in the same mutation.
  func finishNativeTextEditing(elementID: String, text: String) {
    guard var board,
      let element = board.elements.first(where: {
        $0.id == elementID && $0.kind == .nativeText
      })
    else { return }
    if text.isEmpty {
      guard board.removeElements(ids: [elementID], actor: actorID) == 1 else {
        return
      }
      persistBoard(board)
      return
    }
    guard element.source != text else { return }
    updateNativeText(elementID: elementID, text: text)
  }

  func commitSpatialElementState(elementID: String, state: JSONValue) {
    guard var board,
      let index = board.elements.firstIndex(where: { $0.id == elementID })
    else { return }
    var element = board.elements[index]
    let expected = element.stamp
    guard element.update(state: state, actor: actorID),
      board.upsertElement(element, expected: expected, actor: actorID)
    else { return }
    persistBoard(board)
  }

  func reserveDrawingAction(pageID: UUID) -> VersionStamp? {
    guard let page = pages[pageID] else { return nil }
    let latestCounter = max(
      page.drawingStamp.counter,
      reservedDrawingCounters[pageID] ?? 0
    )
    guard latestCounter < VersionStamp.maximumCounter else { return nil }
    let stamp = VersionStamp(counter: latestCounter + 1, actor: actorID)
    reservedDrawingCounters[pageID] = stamp.counter
    return stamp
  }

  @discardableResult
  func commitDrawingAction(
    _ data: Data,
    replacing previousData: Data,
    pageID: UUID,
    stamp: VersionStamp
  ) -> Data? {
    guard var page = pages[pageID] else { return nil }
    guard stamp.actor == actorID,
      stamp.counter <= reservedDrawingCounters[pageID, default: 0],
      page.drawingStamp < stamp
    else { return page.drawingData }
    guard data != page.drawingData else { return page.drawingData }
    guard page.replaceDrawing(data, stamp: stamp) else {
      return page.drawingData
    }

    pencilUndoHistory.recordAction(
      pageID: page.id,
      before: previousData,
      after: data
    )
    pages[page.id] = page
    sync.send(
      .drawing(
        pageID: page.id,
        data: page.drawingData,
        stamp: page.drawingStamp
      )
    )
    scheduleSave(page.id)
    return page.drawingData
  }

  func undoLastDrawingAction() {
    guard var page = activePage,
          page.drawingStamp.counter < VersionStamp.maximumCounter,
          let previousDrawing = pencilUndoHistory.removeLastChange(for: page.id)
    else { return }
    guard page.replaceDrawing(previousDrawing, actor: actorID) else { return }
    pages[page.id] = page
    scheduleSave(page.id)
    sync.send(
      .drawing(
        pageID: page.id,
        data: page.drawingData,
        stamp: page.drawingStamp
      )
    )
    showCue("Отменено")
  }

  func selectPenColor(_ color: PenColor) {
    drawingTool = .pen
    guard color != penStyle.color else { return }
    penStyle = PenStyle(
      color: color,
      width: penStyle.width,
      minimumOpacity: penStyle.minimumOpacity
    )
    savePenStyle()
  }

  func selectPenWidth(_ width: Double) {
    drawingTool = .pen
    let next = PenStyle(
      color: penStyle.color,
      width: width,
      minimumOpacity: penStyle.minimumOpacity
    )
    guard next != penStyle else { return }
    penStyle = next
    savePenStyle()
  }

  func selectPenMinimumOpacity(_ minimumOpacity: Double) {
    drawingTool = .pen
    let next = PenStyle(
      color: penStyle.color,
      width: penStyle.width,
      minimumOpacity: minimumOpacity
    )
    guard next != penStyle else { return }
    penStyle = next
    savePenStyle()
  }

  func selectEraserWidth(_ maximumWidth: Double) {
    drawingTool = .eraser
    let next = EraserStyle(maximumWidth: maximumWidth)
    guard next != eraserStyle else { return }
    eraserStyle = next
    saveEraserStyle()
  }

  func selectDrawingTool(_ tool: DrawingTool) {
    drawingTool = tool
  }

  func commitElementState(elementID: String, state: JSONValue) {
    guard var page = activePage else { return }
    if let disk = try? store.loadPage(page.id) {
      _ = page.merge(disk)
    }
    guard let index = page.elements.firstIndex(where: { $0.id == elementID }) else {
      return
    }
    var elements = page.elements
    elements[index] = elements[index].updating(state: state)
    let previous = page.agentStamp
    page.replaceElements(elements, actor: actorID)
    guard previous != page.agentStamp else { return }
    page = persistMerged(page)
    sync.send(
      .elements(
        pageID: page.id,
        elements: page.elements,
        stamp: page.agentStamp
      )
    )
  }

  func replaceDocumentBlockSource(
    documentID: UUID,
    blockID: String,
    source: String
  ) {
    guard var document = documents[documentID],
      document.replaceBlockSource(
        id: blockID,
        source: source,
        actor: actorID
      )
    else { return }
    let resolved = (try? store.saveMergedDocument(document)) ?? document
    documents[documentID] = resolved
    sync.send(.document(resolved))
  }

  func commitDocumentState(
    documentID: UUID,
    blockID: String,
    value: JSONValue
  ) {
    guard var journal = documentStates[documentID],
      journal.commit(blockID: blockID, value: value, actor: actorID)
    else { return }
    let resolved = (try? store.saveMergedDocumentState(journal)) ?? journal
    documentStates[documentID] = resolved
    sync.send(.documentState(resolved))
  }

  func reloadExternalChanges() {
    reloadExternalChanges(remainingAttempts: 2)
  }

  private func reloadExternalChanges(remainingAttempts: Int) {
    guard loadState == .ready else { return }
    do {
      let diskIndex = try store.loadIndex()
      let indexChanged = workspace?.merge(diskIndex) == true
      if indexChanged {
        workspace = diskIndex
        reconcileWorkspace(with: diskIndex)
      }
      let itemIDs = Set(diskIndex.items.map(\.id))
      let diskBoard = try store.loadBoard(itemIDs: itemIDs)
      if var currentBoard = board {
        if currentBoard.merge(diskBoard, itemIDs: itemIDs) {
          board = currentBoard
          reconcilePresence(with: diskIndex, board: currentBoard)
          sync.send(.board(currentBoard))
        }
      } else {
        board = diskBoard
        reconcilePresence(with: diskIndex, board: diskBoard)
        sync.send(.board(diskBoard))
      }
      let diskInk = try store.loadSpatialInk()
      if var currentInk = spatialInk {
        if currentInk.merge(diskInk) {
          spatialInk = currentInk
          sync.send(.spatialInk(currentInk))
        }
      } else {
        spatialInk = diskInk
        sync.send(.spatialInk(diskInk))
      }
      for item in diskIndex.items where item.kind == .notebook {
        for pageID in item.pageIDs {
          let diskPage = try store.loadPage(pageID)
          if var current = pages[pageID] {
            let oldDrawing = current.drawingStamp
            let oldAgent = current.agentStamp
            guard current.merge(diskPage) else { continue }
            pages[pageID] = current
            if oldDrawing < current.drawingStamp {
              pencilUndoHistory.discardChanges(for: pageID)
              sync.send(
                .drawing(
                  pageID: pageID,
                  data: current.drawingData,
                  stamp: current.drawingStamp
                )
              )
            }
            if oldAgent < current.agentStamp {
              sync.send(
                .elements(
                  pageID: pageID,
                  elements: current.elements,
                  stamp: current.agentStamp
                )
              )
            }
          } else {
            pages[pageID] = diskPage
            sync.send(.page(diskPage))
          }
        }
      }
      for item in diskIndex.items where item.kind == .document {
        let diskDocument = try store.loadDocument(item.id)
        if var current = documents[item.id] {
          if current.merge(diskDocument) {
            documents[item.id] = current
            sync.send(.document(current))
          }
        } else {
          documents[item.id] = diskDocument
          sync.send(.document(diskDocument))
        }

        let diskState = try store.loadDocumentState(item.id)
        if var current = documentStates[item.id] {
          if current.merge(diskState) {
            documentStates[item.id] = current
            sync.send(.documentState(current))
          }
        } else {
          documentStates[item.id] = diskState
          sync.send(.documentState(diskState))
        }
      }
      if indexChanged { sync.send(.index(diskIndex)) }
      #if os(macOS)
        externalReloadRetry?.cancel()
        externalReloadRetry = nil
      #endif
    } catch {
      #if os(macOS)
        guard remainingAttempts > 0 else { return }
        externalReloadRetry?.cancel()
        externalReloadRetry = Task { [weak self] in
          try? await Task.sleep(for: .milliseconds(60))
          guard !Task.isCancelled else { return }
          self?.reloadExternalChanges(
            remainingAttempts: remainingAttempts - 1
          )
        }
      #endif
    }
  }

  #if os(macOS)
    private func startExternalChangeObservation() {
      guard externalChangeWatcher == nil else { return }
      let watcher = DirectoryWatcher(urls: [
        store.root,
        store.pagesURL,
        store.documentsURL,
        store.documentStatesURL,
      ]) {
        [weak self] in
        self?.reloadExternalChanges()
      }
      watcher.start()
      externalChangeWatcher = watcher

      // Close the only race that a file watcher cannot observe: an MCP write
      // may finish after the initial load but just before the descriptors are
      // installed. A post-install read covers that interval.
      reloadExternalChanges()
    }
  #endif

  func receivePeerMessage(_ message: WireMessage) {
    switch message {
    case .index(let incoming):
      stageRemoteIndex(incoming)
    case .page(let incoming):
      guard workspaceContainsPage(incoming.id) else {
        stageRemotePage(incoming)
        return
      }
      if var current = pages[incoming.id] {
        guard current.merge(incoming) else { return }
        acceptRemotePage(current)
      } else {
        acceptRemotePage(incoming)
      }
    case .drawing(let pageID, let data, let stamp):
      guard var page = pages[pageID],
        page.replaceDrawing(data, stamp: stamp)
      else { return }
      acceptRemotePage(page)
    case .elements(let pageID, let elements, let stamp):
      guard var page = pages[pageID],
        page.replaceElements(elements, stamp: stamp)
      else { return }
      acceptRemotePage(page)
    case .document(let incoming):
      guard workspaceContainsDocument(incoming.id) else {
        stageRemoteDocument(incoming)
        return
      }
      if var current = documents[incoming.id] {
        guard current.merge(incoming) else { return }
        documents[incoming.id] = (try? store.saveMergedDocument(current))
          ?? current
      } else {
        documents[incoming.id] = incoming
        try? store.saveDocument(incoming)
      }
    case .documentState(let incoming):
      guard workspaceContainsDocument(incoming.id) else {
        stageRemoteDocumentState(incoming)
        return
      }
      if var current = documentStates[incoming.id] {
        guard current.merge(incoming) else { return }
        documentStates[incoming.id] = (
          try? store.saveMergedDocumentState(current)
        ) ?? current
      } else {
        documentStates[incoming.id] = incoming
        try? store.saveDocumentState(incoming)
      }
    case .board(let incoming):
      guard let workspace else { return }
      let itemIDs = Set(workspace.items.map(\.id))
      if var current = board {
        if current.merge(incoming, itemIDs: itemIDs) {
          board = (try? store.saveMergedBoard(
            current,
            itemIDs: itemIDs
          )) ?? current
          reconcilePresence(with: workspace, board: board)
        } else {
          stageRemoteBoard(incoming)
        }
      } else {
        if incoming.isValid(itemIDs: itemIDs) {
          board = incoming
          try? store.saveBoard(incoming, itemIDs: itemIDs)
          reconcilePresence(with: workspace, board: incoming)
        } else {
          stageRemoteBoard(incoming)
        }
      }
      publishStagedWorkspaceIfReady()
    case .spatialInk(let incoming):
      if var current = spatialInk {
        guard current.merge(incoming) else { return }
        spatialInk = (try? store.saveMergedSpatialInk(current)) ?? current
      } else {
        guard incoming.isValid else { return }
        spatialInk = incoming
        try? store.saveSpatialInk(incoming)
      }
    case .presence(let envelope):
      #if os(macOS)
        guard presenceSequenceTracker.accepts(envelope), let workspace
        else { return }
        let incoming = envelope.phase == .settled
          ? settledPresence(
            from: envelope.presence,
            workspace: workspace,
            board: board,
            viewport: envelope.presence.viewport
          )
          : envelope.presence
        guard presenceIsUsable(incoming, workspace: workspace) else { return }
        presence = incoming
        presencePhase = envelope.phase
        if envelope.phase == .settled {
          try? store.savePresence(incoming)
        }
      #endif
    }
  }

  private func sendSnapshot() {
    guard let workspace else { return }
    let publishedPageIDs = Set(workspace.items.flatMap(\.pageIDs))
    let selectedPageID = workspace.selectedPageID
    if let selectedPageID, let selectedPage = pages[selectedPageID] {
      sync.send(.page(selectedPage))
    }
    if workspace.selectedItem.kind == .document {
      let id = workspace.selectedItemID
      if let document = documents[id] { sync.send(.document(document)) }
      if let state = documentStates[id] { sync.send(.documentState(state)) }
    }
    if let spatialInk { sync.send(.spatialInk(spatialInk)) }
    for page in pages.values
    where page.id != selectedPageID && publishedPageIDs.contains(page.id) {
      sync.send(.page(page))
    }
    for item in workspace.items where item.kind == .document
      && item.id != workspace.selectedItemID
    {
      if let document = documents[item.id] { sync.send(.document(document)) }
      if let state = documentStates[item.id] {
        sync.send(.documentState(state))
      }
    }
    if let board { sync.send(.board(board)) }
    sync.send(.index(workspace))
    #if os(iOS)
      if let lastSettledPresenceEnvelope {
        sync.send(.presence(lastSettledPresenceEnvelope))
      }
    #endif
  }

  private func scheduleSave(_ pageID: UUID) {
    saveTasks[pageID]?.cancel()
    let store = store
    saveTasks[pageID] = Task { [weak self] in
      guard !Task.isCancelled, let self, let page = pages[pageID] else { return }
      let resolved = await Task.detached(priority: .utility) {
        try? store.saveMergedPage(page)
      }.value
      guard !Task.isCancelled, let resolved else { return }
      if var current = pages[pageID] {
        let previousDrawingStamp = current.drawingStamp
        _ = current.merge(resolved)
        pages[pageID] = current
        if previousDrawingStamp < current.drawingStamp {
          pencilUndoHistory.discardChanges(for: pageID)
        }
      } else {
        pages[pageID] = resolved
      }
      saveTasks[pageID] = nil
    }
  }

  private func scheduleSpatialInkSave() {
    spatialInkSaveTask?.cancel()
    let store = store
    spatialInkSaveTask = Task { [weak self] in
      guard !Task.isCancelled, let self, let journal = spatialInk else {
        return
      }
      let resolved = await Task.detached(priority: .utility) {
        try? store.saveMergedSpatialInk(journal)
      }.value
      guard !Task.isCancelled, let resolved else { return }
      if var current = spatialInk {
        _ = current.merge(resolved)
        spatialInk = current
      } else {
        spatialInk = resolved
      }
      spatialInkSaveTask = nil
    }
  }

  private func persistBoard(_ board: BoardDocument) {
    guard let workspace else { return }
    let itemIDs = Set(workspace.items.map(\.id))
    let resolved = (try? store.saveMergedBoard(
      board,
      itemIDs: itemIDs
    )) ?? board
    self.board = resolved
    sync.send(.board(resolved))
  }

  @discardableResult
  private func persistMerged(_ page: PageDocument) -> PageDocument {
    let previousDrawingStamp = pages[page.id]?.drawingStamp
    let resolved = (try? store.saveMergedPage(page)) ?? page
    pages[page.id] = resolved
    if let previousDrawingStamp,
      previousDrawingStamp < resolved.drawingStamp
    {
      pencilUndoHistory.discardChanges(for: page.id)
    }
    return resolved
  }

  private func showCue(_ text: String) {
    cueTask?.cancel()
    actionCue = text
    cueTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(700))
      guard !Task.isCancelled else { return }
      self?.actionCue = nil
    }
  }

  private func initialPresence(
    workspace: WorkspaceIndex,
    board: BoardDocument?,
    viewport: PageSize
  ) -> SessionPresence {
    let item = workspace.selectedItem
    let itemID = item.id
    let center = board?.focusedCenter(of: itemID) ?? .zero
    let viewportPoint = SpatialPoint(x: viewport.width, y: viewport.height)
    let fit = NotebookPresentation.fitScale(
      viewport: viewportPoint
    )
    return SessionPresence(
      mode: item.kind == .document ? .document : .page,
      camera: SpatialCamera(center: center, scale: fit),
      viewport: viewportPoint,
      focusedItemID: itemID,
      openProgress: 1
    )
  }

  private func settledPresence(
    from presence: SessionPresence,
    workspace: WorkspaceIndex,
    board: BoardDocument?,
    viewport: SpatialPoint
  ) -> SessionPresence {
    let adapted = presence.adapted(to: viewport)
    let itemID = presence.focusedItemID
    let itemCenter = itemID.flatMap { id in
      board?.focusedCenter(of: id)
    }

    if presence.mode == .page || presence.mode == .document,
      let itemID,
      let itemCenter,
      let item = workspace.items.first(where: { $0.id == itemID }),
      (presence.mode == .page) == (item.kind == .notebook)
    {
      return SessionPresence(
        mode: presence.mode,
        camera: SpatialCamera(
          center: itemCenter,
          scale: NotebookPresentation.fitScale(viewport: viewport)
        ),
        viewport: viewport,
        focusedItemID: itemID,
        openProgress: 1
      )
    }

    if presence.mode == .cover,
      let itemID,
      workspace.items.contains(where: { $0.id == itemID })
    {
      return adapted
    }

    return SessionPresence(
      mode: .board,
      camera: adapted.camera,
      viewport: viewport
    )
  }

  private func makePresenceEnvelope(
    _ presence: SessionPresence,
    phase: PresencePhase
  ) -> PresenceEnvelope? {
    guard presenceSequence < VersionStamp.maximumCounter else { return nil }
    presenceSequence += 1
    return PresenceEnvelope(
      sessionID: presenceSessionID,
      sequence: presenceSequence,
      phase: phase,
      presence: presence
    )
  }

  private func acceptRemotePage(_ page: PageDocument) {
    let previousDrawingStamp = pages[page.id]?.drawingStamp
    pages[page.id] = page
    if let previousDrawingStamp, previousDrawingStamp < page.drawingStamp {
      pencilUndoHistory.discardChanges(for: page.id)
    }
    scheduleSave(page.id)
  }

  private func workspaceContainsPage(_ pageID: UUID) -> Bool {
    workspace?.items.contains(where: { $0.pageIDs.contains(pageID) }) == true
  }

  private func stageRemotePage(_ incoming: PageDocument) {
    if var staged = stagedRemotePages[incoming.id] {
      _ = staged.merge(incoming)
      stagedRemotePages[incoming.id] = staged
    } else {
      stagedRemotePages[incoming.id] = incoming
    }
    publishStagedWorkspaceIfReady()
  }

  /// WorkspaceIndex is the publication boundary for pages. It promotes pages
  /// sent ahead of a creation and evicts pages removed by a deletion before a
  /// delayed serializer or peer can expose them again.
  private func reconcileWorkspace(with workspace: WorkspaceIndex) {
    let publishedPageIDs = Set(workspace.items.flatMap(\.pageIDs))
    let obsoletePageIDs = pages.keys.filter { !publishedPageIDs.contains($0) }
    for pageID in obsoletePageIDs {
      saveTasks[pageID]?.cancel()
      saveTasks[pageID] = nil
      pages[pageID] = nil
      reservedDrawingCounters[pageID] = nil
      pencilUndoHistory.discardChanges(for: pageID)
    }

    let promoted = stagedRemotePages.values.filter {
      publishedPageIDs.contains($0.id)
    }
    stagedRemotePages.removeAll(keepingCapacity: true)
    for page in promoted {
      if var current = pages[page.id] {
        _ = current.merge(page)
        acceptRemotePage(current)
      } else {
        acceptRemotePage(page)
      }
    }

    let publishedDocumentIDs = Set(
      workspace.items.lazy.filter { $0.kind == .document }.map(\.id)
    )
    for id in documents.keys where !publishedDocumentIDs.contains(id) {
      documents[id] = nil
      documentStates[id] = nil
    }

    let promotedDocuments = stagedRemoteDocuments.values.filter {
      publishedDocumentIDs.contains($0.id)
    }
    let promotedStates = stagedRemoteDocumentStates.values.filter {
      publishedDocumentIDs.contains($0.id)
    }
    stagedRemoteDocuments.removeAll(keepingCapacity: true)
    stagedRemoteDocumentStates.removeAll(keepingCapacity: true)
    for incoming in promotedDocuments {
      if var current = documents[incoming.id] {
        _ = current.merge(incoming)
        documents[incoming.id] = current
        try? store.saveDocument(current)
      } else {
        documents[incoming.id] = incoming
        try? store.saveDocument(incoming)
      }
    }
    for incoming in promotedStates {
      if var current = documentStates[incoming.id] {
        _ = current.merge(incoming)
        documentStates[incoming.id] = current
        try? store.saveDocumentState(current)
      } else {
        documentStates[incoming.id] = incoming
        try? store.saveDocumentState(incoming)
      }
    }

    reconcilePresence(with: workspace, board: board)
  }

  /// Selection lives in the catalog while its screen anchor lives on the
  /// board. A newer catalog or board therefore settles the camera from both
  /// owners together. This keeps a deleted focus from leaving an empty view.
  private func reconcilePresence(
    with workspace: WorkspaceIndex,
    board: BoardDocument?
  ) {
    guard let current = presence else { return }
    let resolved: SessionPresence
    if presenceIsUsable(current, workspace: workspace) {
      resolved = settledPresence(
        from: current,
        workspace: workspace,
        board: board,
        viewport: current.viewport
      )
    } else {
      resolved = initialPresence(
        workspace: workspace,
        board: board,
        viewport: PageSize(
          width: current.viewport.x,
          height: current.viewport.y
        )
      )
    }
    guard resolved != current || presencePhase != .settled else { return }
    presence = resolved
    presencePhase = .settled
    try? store.savePresence(resolved)
    #if os(iOS)
      lastSettledPresenceEnvelope = makePresenceEnvelope(
        resolved,
        phase: .settled
      )
    #endif
  }

  private func workspaceContainsDocument(_ id: UUID) -> Bool {
    workspace?.items.contains(where: {
      $0.id == id && $0.kind == .document
    }) == true
  }

  private func stageRemoteDocument(_ incoming: DocumentDocument) {
    if var staged = stagedRemoteDocuments[incoming.id] {
      _ = staged.merge(incoming)
      stagedRemoteDocuments[incoming.id] = staged
    } else {
      stagedRemoteDocuments[incoming.id] = incoming
    }
    publishStagedWorkspaceIfReady()
  }

  private func stageRemoteDocumentState(_ incoming: DocumentStateJournal) {
    if var staged = stagedRemoteDocumentStates[incoming.id] {
      _ = staged.merge(incoming)
      stagedRemoteDocumentStates[incoming.id] = staged
    } else {
      stagedRemoteDocumentStates[incoming.id] = incoming
    }
    publishStagedWorkspaceIfReady()
  }

  /// A catalog is the moment new content becomes discoverable. Keep a newer
  /// catalog private until every page, document state and board placement it
  /// names has arrived, then write those dependencies before the catalog.
  private func stageRemoteIndex(_ incoming: WorkspaceIndex) {
    guard workspace.map({ $0.stamp < incoming.stamp }) ?? true
    else { return }
    if var stagedRemoteIndex {
      _ = stagedRemoteIndex.merge(incoming)
      self.stagedRemoteIndex = stagedRemoteIndex
    } else {
      stagedRemoteIndex = incoming
    }
    publishStagedWorkspaceIfReady()
  }

  private func stageRemoteBoard(_ incoming: BoardDocument) {
    if let stagedRemoteBoard,
      stagedRemoteBoard.stamp >= incoming.stamp
    {
      return
    }
    stagedRemoteBoard = incoming
  }

  private func publishStagedWorkspaceIfReady() {
    guard let incoming = stagedRemoteIndex,
      workspace.map({ $0.stamp < incoming.stamp }) ?? true
    else {
      stagedRemoteIndex = nil
      return
    }

    let pageIDs = incoming.items.flatMap(\.pageIDs)
    guard pageIDs.allSatisfy({
      pages[$0] != nil || stagedRemotePages[$0] != nil
    }) else { return }

    let documentIDs = incoming.items.compactMap { item in
      item.kind == .document ? item.id : nil
    }
    guard documentIDs.allSatisfy({
      (documents[$0] != nil || stagedRemoteDocuments[$0] != nil)
        && (documentStates[$0] != nil
          || stagedRemoteDocumentStates[$0] != nil)
    }) else { return }

    let expectedItemIDs = Set(incoming.items.map(\.id))
    var boardCandidates = [BoardDocument]()
    if let board, board.isValid(itemIDs: expectedItemIDs) {
      boardCandidates.append(board)
    }
    if let stagedRemoteBoard,
      stagedRemoteBoard.isValid(itemIDs: expectedItemIDs)
    {
      boardCandidates.append(stagedRemoteBoard)
    }
    let exactBoards = boardCandidates.filter {
      Set($0.itemIDs) == expectedItemIDs
    }
    guard let candidateBoard = (exactBoards.isEmpty
      ? boardCandidates
      : exactBoards
    ).max(by: { $0.stamp < $1.stamp }) else { return }

    var resolvedPages: [UUID: PageDocument] = [:]
    for id in pageIDs {
      guard var page = pages[id] ?? stagedRemotePages[id] else { return }
      if let staged = stagedRemotePages[id] { _ = page.merge(staged) }
      resolvedPages[id] = page
    }
    var resolvedDocuments: [UUID: DocumentDocument] = [:]
    var resolvedStates: [UUID: DocumentStateJournal] = [:]
    for id in documentIDs {
      guard var document = documents[id] ?? stagedRemoteDocuments[id],
        var state = documentStates[id] ?? stagedRemoteDocumentStates[id]
      else { return }
      if let staged = stagedRemoteDocuments[id] {
        _ = document.merge(staged)
      }
      if let staged = stagedRemoteDocumentStates[id] {
        _ = state.merge(staged)
      }
      resolvedDocuments[id] = document
      resolvedStates[id] = state
    }

    do {
      let currentPageIDs = Set(workspace?.items.flatMap(\.pageIDs) ?? [])
      let currentDocumentIDs = Set(workspace?.items.compactMap { item in
        item.kind == .document ? item.id : nil
      } ?? [])
      var durablePages: [UUID: PageDocument] = [:]
      for (id, page) in resolvedPages {
        if currentPageIDs.contains(id) {
          durablePages[id] = try store.saveMergedPage(page)
        } else {
          try store.savePage(page)
          durablePages[id] = page
        }
      }
      resolvedPages = durablePages
      var durableDocuments: [UUID: DocumentDocument] = [:]
      for (id, document) in resolvedDocuments {
        if currentDocumentIDs.contains(id) {
          durableDocuments[id] = try store.saveMergedDocument(document)
        } else {
          try store.saveDocument(document)
          durableDocuments[id] = document
        }
      }
      resolvedDocuments = durableDocuments
      var durableStates: [UUID: DocumentStateJournal] = [:]
      for (id, state) in resolvedStates {
        if currentDocumentIDs.contains(id) {
          durableStates[id] = try store.saveMergedDocumentState(state)
        } else {
          try store.saveDocumentState(state)
          durableStates[id] = state
        }
      }
      resolvedStates = durableStates
      try store.publishRemoteWorkspace(
        index: incoming,
        board: candidateBoard,
        actor: actorID
      )
    } catch {
      return
    }

    workspace = incoming
    board = candidateBoard
    for (id, page) in resolvedPages { pages[id] = page }
    for (id, document) in resolvedDocuments { documents[id] = document }
    for (id, state) in resolvedStates { documentStates[id] = state }
    stagedRemoteIndex = nil
    stagedRemoteBoard = nil
    reconcileWorkspace(with: incoming)
    reconcilePresence(with: incoming, board: candidateBoard)
  }

  private func restoreSettledPresenceAfterDisconnect() {
    #if os(macOS)
      guard presencePhase == .active,
        let workspace,
        let stored = try? store.loadPresence(),
        presenceIsUsable(stored, workspace: workspace)
      else { return }
      presence = settledPresence(
        from: stored,
        workspace: workspace,
        board: board,
        viewport: stored.viewport
      )
      presencePhase = .settled
    #endif
  }

  private func presenceIsUsable(
    _ presence: SessionPresence,
    workspace: WorkspaceIndex
  ) -> Bool {
    guard presence.isValid else { return false }
    if let itemID = presence.focusedItemID,
      !workspace.items.contains(where: { $0.id == itemID })
    {
      return false
    }
    if presence.mode != .board,
      presence.focusedItemID != workspace.selectedItemID
    { return false }
    if let itemID = presence.focusedItemID,
      let item = workspace.items.first(where: { $0.id == itemID })
    {
      if presence.mode == .page && item.kind != .notebook { return false }
      if presence.mode == .document && item.kind != .document { return false }
    }
    return true
  }

  private static func loadActorID() -> UUID {
    let key = "notebook.actor-id"
    if let raw = UserDefaults.standard.string(forKey: key),
       let id = UUID(uuidString: raw) {
      return id
    }
    let id = UUID()
    UserDefaults.standard.set(id.uuidString, forKey: key)
    return id
  }

  private static func loadPenStyle() -> PenStyle {
    let defaults = UserDefaults.standard
    let color = defaults.string(forKey: "notebook.pen-color")
      .flatMap(PenColor.init(rawValue:)) ?? PenStyle.standard.color
    let width = defaults.object(forKey: "notebook.pen-width") as? Double
      ?? PenStyle.standard.width
    let minimumOpacity = defaults.object(
      forKey: "notebook.pen-minimum-opacity"
    ) as? Double ?? PenStyle.standard.minimumOpacity
    let style = PenStyle(
      color: color,
      width: width,
      minimumOpacity: minimumOpacity
    )
    if style.minimumOpacity != minimumOpacity {
      defaults.set(
        style.minimumOpacity,
        forKey: "notebook.pen-minimum-opacity"
      )
    }
    return style
  }

  private static func loadEraserStyle() -> EraserStyle {
    let defaults = UserDefaults.standard
    let storedWidth =
      defaults.object(forKey: "notebook.eraser-width") as? Double
      ?? EraserStyle.standard.maximumWidth
    let style = EraserStyle(maximumWidth: storedWidth)
    if style.maximumWidth != storedWidth {
      defaults.set(style.maximumWidth, forKey: "notebook.eraser-width")
    }
    return style
  }

  private func savePenStyle() {
    UserDefaults.standard.set(penStyle.color.rawValue, forKey: "notebook.pen-color")
    UserDefaults.standard.set(penStyle.width, forKey: "notebook.pen-width")
    UserDefaults.standard.set(
      penStyle.minimumOpacity,
      forKey: "notebook.pen-minimum-opacity"
    )
  }

  private func saveEraserStyle() {
    UserDefaults.standard.set(
      eraserStyle.maximumWidth,
      forKey: "notebook.eraser-width"
    )
  }
}

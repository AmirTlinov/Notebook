import Foundation
import CoreGraphics
import Observation
import NotebookCore

@MainActor
@Observable
final class NotebookAppModel {
  enum LoadState: Equatable {
    case loading
    case ready
    case failed(String)
  }

  private enum PresencePersistence {
    case immediate
    case deferred
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
  private(set) var boardHierarchy: BoardHierarchy?
  private(set) var spatialInk: SpatialInkJournal?
  private(set) var presence: SessionPresence?
  private(set) var presencePhase = PresencePhase.settled
  var isPointing = false
  struct ReturnPlace: Identifiable {
    let id = UUID()
    let presence: SessionPresence
    let pageID: UUID?
  }
  private(set) var returnPlaces: [ReturnPlace] = []
  private(set) var requestedReturn: ReturnPlace?
  private(set) var requestedReference: CollaborationReference?
  private(set) var highlightedReference: CollaborationReference?
  private(set) var showsCollaborationNotice = false
  private var collaborationNoticeKey: String?
  private var collaborationNoticeTask: Task<Void, Never>?
  private var referenceHighlightTask: Task<Void, Never>?
  private var collaborationUndoTask: Task<Void, Never>?
  @ObservationIgnored private var resultCache: [UUID: [CollaborationReference]] = [:]
  @ObservationIgnored private var referenceStatusCache: [UUID: (String, Bool)] = [:]
  @ObservationIgnored private var continuationCache: [UUID: (String, [CollaborationContinuation])] = [:]
  private var deviceActionReceipts: [DeviceActionReceipt] = []
  private var readyPages: [UUID: String] = [:]
  private(set) var isPeerConnected = false
  private(set) var collaborationActions: [CollaborationReceipt] = []
  private(set) var regionalReferenceStatuses: [UUID: ReferenceStatus] = [:]
  private(set) var sharedContexts: [SharedContext] = []
  private(set) var contextSelection: SharedContextSelection?
  var activeSharedContext: SharedContext? {
    sharedContexts.first { $0.id == contextSelection?.contextID }
  }
  var presentedSharedContext: SharedContext? {
    guard showsCollaborationNotice else { return activeSharedContext }
    let newest = sharedContexts.max { ($0.entries.last?.createdAt ?? .distantPast) < ($1.entries.last?.createdAt ?? .distantPast) }
    if let action = collaborationActions.first,
      (action.undo?.completedAt ?? action.createdAt) >= (newest?.entries.last?.createdAt ?? .distantPast) {
      return sharedContexts.first { $0.id == action.action.resolvedContextID }
    }
    return newest ?? activeSharedContext
  }
  var contextEntries: [SharedContextEntry] { presentedSharedContext?.entries ?? [] }
  private(set) var actionCue: String?
  private(set) var penStyle: PenStyle
  private(set) var eraserStyle: EraserStyle
  private(set) var drawingTool: DrawingTool = .pen
  private(set) var isElementEditingEnabled = false
  private(set) var elementEditingSession = ElementEditingSession()

  /// The document bundle supplies its physical size. A notebook or an
  /// unselected board uses the canonical notebook/portal rectangle.
  func itemGeometry(_ itemID: UUID?) -> WorkspaceItemGeometry {
    if let itemID, let document = documents[itemID] {
      return .document(document.paperSize)
    }
    return .notebook
  }

  let store: NotebookStore
  let actorID: UUID
  let inputGate = NotebookInputGate()

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
  private var stagedRemoteBoard: BoardHierarchy?
  private var spatialInkSaveTask: Task<Void, Never>?
  private var workspaceSelectionSaveTail: Task<Void, Never>?
  private var presenceSaveTail: Task<Void, Never>?
  private var cueTask: Task<Void, Never>?
  private var pencilUndoHistory = PencilUndoHistory()
  private var reservedDrawingCounters: [UUID: UInt64] = [:]
  private let presenceSessionID = UUID()
  private var presenceSequence: UInt64 = 0
  private var lastSettledPresenceEnvelope: PresenceEnvelope?
  private var presenceSequenceTracker = PresenceSequenceTracker()
  private let startsNearbySync: Bool
  private let sync: NearbySync
  #if os(iOS)
    @ObservationIgnored private let inputFrameMonitor: InputFrameMonitor
  #endif
  @ObservationIgnored private var deferredCollaboration: CollaborationEnvelope?
  @ObservationIgnored private var externalReloadPending = false
  @ObservationIgnored private var inputSequence: UInt64 = 0
  @ObservationIgnored private var inputWriteTask: Task<Void, Never>?
  @ObservationIgnored private var pendingInputActivity: NotebookInputActivity?
  private(set) var inputIsActive = false
  private(set) var peerInputIsActive = false
  var permitsBackgroundPreparation: Bool { !inputIsActive && !peerInputIsActive && presencePhase == .settled }
  #if os(macOS)
    /// MCP writes the same files as the app. This observer belongs to the
    /// long-lived model, so closing the mirror window cannot stop delivery to
    /// the iPad while the Mac app is still running.
    private var externalChangeWatcher: DirectoryWatcher?
    private var externalReloadRetry: Task<Void, Never>?
    /// Agent vision follows the process-level mirror, not a disposable window.
    private var previewPublisher: MacPreviewPublisher?
  #endif

  init(
    store: NotebookStore = NotebookStore(root: NotebookStore.defaultRoot),
    startsNearbySync: Bool = true
  ) {
    self.store = store
    #if os(iOS)
      inputFrameMonitor = InputFrameMonitor(root: store.root)
    #endif
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
      self?.isPeerConnected = true
      self?.publishInputActivity()
      self?.sendSnapshot()
    }
    sync.onDisconnect = { [weak self] in
      self?.isPeerConnected = false
      self?.peerInputIsActive = false
      if let self { try? store.resetInputActivities(keeping: actorID) }
      self?.restoreSettledPresenceAfterDisconnect()
    }
    inputGate.onActivityChange = { [weak self] active in
      guard let self else { return }
      inputIsActive = active
      #if os(macOS)
        if active { previewPublisher?.suspendForInput() }
      #else
        if active { inputFrameMonitor.begin(mode: presence?.mode.rawValue ?? "unknown") }
        else { inputFrameMonitor.end() }
      #endif
      publishInputActivity()
      if !active {
        if let pending = deferredCollaboration {
          deferredCollaboration = nil
          receivePeerMessage(.collaboration(pending))
        }
        if externalReloadPending { externalReloadPending = false; reloadExternalChanges() }
      }
    }
  }

  private func publishInputActivity() {
    guard loadState == .ready else { return }
    inputSequence &+= 1
    var targets: [CollaborationTarget] = []
    if inputIsActive, let presence {
      let board = CollaborationTarget(kind: .board, id: presence.boardID)
      if presence.mode == .board { targets = [board] }
      else if let id = presence.focusedItemID {
        targets = [.init(kind: .cover, id: id, boardID: presence.boardID)]
        if presence.mode == .page, let page = activePage { targets.append(.init(kind: .page, id: page.id)) }
        if presence.mode == .document { targets.append(.init(kind: .document, id: id)) }
      } else { targets = [board] }
    }
    let activity = NotebookInputActivity(deviceID: actorID, sessionID: presenceSessionID, sequence: inputSequence, targets: targets)
    sync.send(.inputActivity(activity))
    pendingInputActivity = activity
    guard inputWriteTask == nil else { return }
    inputWriteTask = Task { [weak self] in
      guard let self else { return }
      while let next = pendingInputActivity {
        pendingInputActivity = nil
        let store = store
        await Task.detached(priority: .userInitiated) { try? store.saveInputActivity(next) }.value
      }
      inputWriteTask = nil
    }
  }

  var activePage: PageDocument? {
    guard let pageID = workspace?.selectedPageID else { return nil }
    return pages[pageID]
  }

  var board: BoardDocument? {
    guard let boardHierarchy else { return nil }
    return boardHierarchy.board(
      presence?.boardID ?? workspace?.rootBoardID ?? WorkspaceRoot.boardID
    )
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
      pages = try PageInkMigration.migrate(stored.1,store:store)
      let storedDocuments = try store.loadAvailableDocuments(
        workspace: stored.0
      )
      documents = storedDocuments.documents
      documentStates = storedDocuments.states
      boardHierarchy = try store.loadOrCreateBoard(
        workspace: stored.0,
        actor: actorID
      )
      spatialInk = try store.loadOrCreateSpatialInk(actor: actorID)
      presence = initialPresence(
        workspace: stored.0,
        board: boardHierarchy,
        viewport: pageSize
      )
      if let diskPresence = try? store.loadPresence(),
        presenceIsUsable(diskPresence, workspace: stored.0)
      {
        presence = settledPresence(
          from: diskPresence,
          workspace: stored.0,
          board: boardHierarchy,
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
      try store.migrateCollaborationStorage()
      try store.resetInputActivities()
      loadState = .ready
      reloadCollaborationMetadata()
      reloadExternalChanges()
      #if os(macOS)
        startExternalChangeObservation()
        startPreviewPublication()
      #endif
      if startsNearbySync {
        sync.start()
      }
    } catch {
      loadState = .failed(error.localizedDescription)
    }
  }

  @discardableResult
  func selectNotebookPage(
    _ pageIndex: Int,
    notebookID: UUID
  ) -> Int? {
    guard var workspace,
      let selection = workspace.selectPage(
        at: pageIndex,
        in: notebookID,
        actor: actorID,
        pageSize: pageSize
      )
    else { return nil }
    if let createdPage = selection.createdPage {
      pages[createdPage.id] = createdPage
    }
    self.workspace = workspace
    if let createdPage = selection.createdPage {
      sync.send(.page(createdPage))
    }
    sync.send(.index(workspace))
    scheduleWorkspaceSelectionSave(
      workspace,
      createdPage: selection.createdPage
    )
    return selection.pageIndex
  }

  @discardableResult
  func createNotebook(at center: WorldPoint) -> UUID? {
    guard var workspace, var board = boardHierarchy, let presence else {
      return nil
    }
    guard let created = workspace.createNotebook(
      title: "",
      actor: actorID,
      pageSize: pageSize
    ), board.addItem(
      created.item.id,
      to: presence.boardID,
      near: center,
      actor: actorID
    )
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
    boardHierarchy = board
    pages[created.page.id] = created.page
    sync.send(.page(created.page))
    sync.send(.board(board))
    sync.send(.index(workspace))
    showCue("Новая тетрадь")
    return created.item.id
  }

  @discardableResult
  func createDocument(
    at center: WorldPoint,
    paperSize: DocumentPaperSize
  ) -> UUID? {
    guard var workspace, var board = boardHierarchy, let presence,
      let item = workspace.createDocument(title: "", actor: actorID),
      board.addItem(
        item.id,
        to: presence.boardID,
        near: center,
        actor: actorID
      )
    else { return nil }

    let document = DocumentDocument(
      id: item.id,
      actor: actorID,
      paperSize: paperSize
    )
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
    boardHierarchy = board
    documents[item.id] = document
    documentStates[item.id] = state
    sync.send(.document(document))
    sync.send(.documentState(state))
    sync.send(.board(board))
    sync.send(.index(workspace))
    showCue("Новый документ")
    return item.id
  }

  @discardableResult
  func createBoard(at center: WorldPoint) -> UUID? {
    guard var workspace, var hierarchy = boardHierarchy, let presence,
      let item = workspace.createBoard(title: "", actor: actorID),
      hierarchy.createBoard(
        item.id,
        in: presence.boardID,
        near: center,
        actor: actorID
      )
    else { return nil }

    do {
      try store.saveBoardWorkspaceBundle(
        index: workspace,
        board: hierarchy,
        boardID: item.id
      )
    } catch {
      showCue("Не удалось создать доску")
      return nil
    }

    self.workspace = workspace
    boardHierarchy = hierarchy
    sync.send(.board(hierarchy))
    sync.send(.index(workspace))
    showCue("Новая доска")
    return item.id
  }

  func selectItem(_ itemID: UUID) {
    guard var workspace,
      workspace.selectItem(itemID, actor: actorID)
    else { return }
    self.workspace = workspace
    sync.send(.index(workspace))
    scheduleWorkspaceSelectionSave(workspace, createdPage: nil)
  }

  @discardableResult
  func deleteItem(_ itemID: UUID) -> Bool {
    guard var workspace, var board = boardHierarchy, let presence, let spatialInk else {
      return false
    }
    let expectedIndex = workspace
    guard let removed = workspace.deleteItem(itemID, actor: actorID) else {
      showCue("Один рабочий элемент должен остаться")
      return false
    }
    guard board.deleteItem(
      itemID,
      from: presence.boardID,
      kind: removed.kind,
      spatialInk: spatialInk,
      actor: actorID
    ) else {
      if removed.kind == .board { showCue("Сначала очистите вложенную доску") }
      return false
    }

    do {
      board = try store.deleteWorkspaceBundle(
        expectedIndex: expectedIndex,
        index: workspace,
        board: board,
        pageIDs: removed.pageIDs,
        documentIDs: removed.kind == .document ? [removed.id] : []
      )
    } catch NotebookStoreError.workspaceChanged {
      reloadExternalChanges()
      showCue("Каталог обновился. Повторите удаление")
      return false
    } catch NotebookStoreError.boardContainsContent {
      reloadExternalChanges()
      showCue("Сначала очистите вложенную доску")
      return false
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
    boardHierarchy = board
    sync.send(.board(board))
    sync.send(.index(workspace))

    if presence.focusedItemID == itemID {
      updatePresence(
        SessionPresence(
          boardID: presence.boardID,
          mode: .board,
          camera: presence.camera,
          viewport: presence.viewport
        ),
        settled: true
      )
    }
    switch removed.kind {
    case .notebook: showCue("Тетрадь удалена")
    case .document: showCue("Документ удалён")
    case .board: showCue("Доска удалена")
    }
    return true
  }

  func moveItem(_ itemID: UUID, to center: WorldPoint) {
    guard var board = boardHierarchy, let presence,
      board.moveItem(
        itemID,
        in: presence.boardID,
        to: center,
        actor: actorID
      )
    else { return }
    persistBoard(board)
  }

  @discardableResult
  func stackItem(_ movingID: UUID, onto targetID: UUID) -> UUID? {
    guard var board = boardHierarchy, let presence,
      let stackID = board.createStack(
        moving: movingID,
        onto: targetID,
        in: presence.boardID,
        actor: actorID
      )
    else { return nil }
    persistBoard(board)
    showCue("Стопка")
    return stackID
  }

  func unstackItem(_ itemID: UUID, at center: WorldPoint) {
    guard var board = boardHierarchy, let presence,
      board.unstackItem(
        itemID,
        in: presence.boardID,
        at: center,
        actor: actorID
      )
    else { return }
    persistBoard(board)
  }

  func updatePresence(_ presence: SessionPresence, settled: Bool) {
    applyPresence(
      presence,
      settled: settled,
      persistence: .immediate
    )
  }

  func enterBoard(_ boardID: UUID) {
    guard let workspace, let hierarchy = boardHierarchy,
      workspace.items.contains(where: {
        $0.id == boardID && $0.kind == .board
      }),
      hierarchy.board(boardID) != nil,
      let presence
    else { return }
    selectItem(boardID)
    updatePresence(
      SessionPresence(
        boardID: boardID,
        mode: .board,
        camera: BoardPortalProjection.entryCamera(
          portalCamera: hierarchy.portalCamera(boardID) ?? BoardPortalCamera(),
          viewport: presence.viewport
        ),
        viewport: presence.viewport
      ),
      settled: true
    )
  }

  /// Moves ownership to the parent at the one frame where the child and its
  /// portal are the same projection. The view can then continue zooming out
  /// without a visual cut.
  @discardableResult
  func leaveBoard() -> Bool {
    guard var hierarchy = boardHierarchy, let presence,
      let parentID = hierarchy.parentBoardID(of: presence.boardID),
      let center = hierarchy.focusedCenter(of: presence.boardID, in: parentID)
    else { return false }
    let portalCamera = BoardPortalProjection.portalCamera(
      from: presence.camera,
      viewport: presence.viewport
    )
    if hierarchy.updatePortalCamera(
      portalCamera,
      for: presence.boardID,
      actor: actorID
    ) {
      persistBoard(hierarchy)
    }
    selectItem(presence.boardID)
    updatePresence(
      SessionPresence(
        boardID: parentID,
        mode: .cover,
        camera: BoardPortalProjection.parentBoundaryCamera(
          portalCenter: center,
          viewport: presence.viewport
        ),
        viewport: presence.viewport,
        focusedItemID: presence.boardID,
        openProgress: 1
      ),
      settled: true
    )
    return true
  }

  private func applyPresence(
    _ presence: SessionPresence,
    settled: Bool,
    persistence: PresencePersistence
  ) {
    guard presence.isValid else { return }
    let resolved: SessionPresence
    if settled, let workspace {
      resolved = settledPresence(
        from: presence,
        workspace: workspace,
        board: boardHierarchy,
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
        persistPresence(resolved, using: persistence)
      }
    #else
      if settled { persistPresence(resolved, using: persistence) }
    #endif
  }

  /// Document pagination is session presence. The iPad remains its durable
  /// owner; a Mac interaction is an explicit command which the iPad confirms
  /// by publishing the resulting presence back to the mirror.
  @discardableResult
  func selectDocumentPage(
    _ pageIndex: Int,
    documentID: UUID,
    publishesRequest: Bool = true
  ) -> Int? {
    guard pageIndex >= 0,
      pageIndex <= DocumentPageSelectionRequest.maximumPageIndex,
      documents[documentID] != nil,
      let presence,
      presence.mode == .document,
      presence.focusedItemID == documentID,
      presence.openProgress >= 0.999,
      presence.documentPageIndex != pageIndex
    else { return nil }

    applyPresence(
      SessionPresence(
        boardID: presence.boardID,
        mode: presence.mode,
        camera: presence.camera,
        viewport: presence.viewport,
        focusedItemID: documentID,
        openProgress: presence.openProgress,
        documentPageIndex: pageIndex
      ),
      settled: true,
      persistence: .deferred
    )
    #if os(macOS)
      if publishesRequest {
        sync.send(
          .documentPageSelection(
            DocumentPageSelectionRequest(
              documentID: documentID,
              pageIndex: pageIndex
            )
          )
        )
      }
    #endif
    return pageIndex
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
    let surface: SurfaceID? = presence.flatMap { presence in
      presence.focusedItemID.map(SurfaceID.cover)
        ?? .board(presence.boardID)
    }
    guard journal.undoLast(actor: actorID, touching: surface) != nil
      || (surface != nil && journal.undoLast(actor: actorID) != nil)
    else { return }
    spatialInk = journal
    sync.send(.spatialInk(journal))
    scheduleSpatialInkSave()
    showCue("Отменено")
  }

  func afterPageInput(_ action: @escaping NotebookInputCompletion) {
    inputGate.performAfterPageInput(action)
  }

  func addNativeText(on itemID: UUID, at point: SpatialPoint) -> String? {
    guard var hierarchy = boardHierarchy, let presence,
      let board = hierarchy.board(presence.boardID),
      board.itemIDs.contains(itemID)
    else { return nil }
    let width = 420.0
    let height = 120.0
    let geometry = itemGeometry(itemID)
    let origin = SpatialPoint(
      x: min(max(point.x, 0), geometry.width - width),
      y: min(max(point.y, 0), geometry.height - height)
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
    guard hierarchy.upsertElement(
      element,
      in: presence.boardID,
      expected: nil,
      actor: actorID
    ) else {
      return nil
    }
    persistBoard(hierarchy)
    return id
  }

  func updateNativeText(elementID: String, text: String) {
    guard var hierarchy = boardHierarchy, let presence,
      let board = hierarchy.board(presence.boardID),
      let index = board.elements.firstIndex(where: {
        $0.id == elementID && $0.kind == .nativeText
      })
    else { return }
    var element = board.elements[index]
    guard element.source != text else { return }
    let expected = element.stamp
    guard element.update(source: text, actor: actorID),
      hierarchy.upsertElement(
        element,
        in: presence.boardID,
        expected: expected,
        actor: actorID
      )
    else { return }
    persistBoard(hierarchy)
  }

  /// Ends the editor's ownership of one native text element. A blank draft has
  /// no visible meaning, so ending its edit removes it from the cover and from
  /// the durable board in the same mutation.
  func finishNativeTextEditing(elementID: String, text: String) {
    guard var hierarchy = boardHierarchy, let presence,
      let board = hierarchy.board(presence.boardID),
      let element = board.elements.first(where: {
        $0.id == elementID && $0.kind == .nativeText
      })
    else { return }
    if text.isEmpty {
      guard hierarchy.removeElements(
        ids: [elementID],
        from: presence.boardID,
        actor: actorID
      ) == 1 else {
        return
      }
      persistBoard(hierarchy)
      return
    }
    guard element.source != text else { return }
    updateNativeText(elementID: elementID, text: text)
  }

  func commitSpatialElementState(elementID: String, state: JSONValue) {
    guard var hierarchy = boardHierarchy, let presence,
      let board = hierarchy.board(presence.boardID),
      let index = board.elements.firstIndex(where: { $0.id == elementID })
    else { return }
    var element = board.elements[index]
    let expected = element.stamp
    guard element.update(state: state, actor: actorID),
      hierarchy.upsertElement(
        element,
        in: presence.boardID,
        expected: expected,
        actor: actorID
      )
    else { return }
    persistBoard(hierarchy)
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
      stamp.counter <= reservedDrawingCounters[pageID, default: 0]
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
          let previousDrawing = pencilUndoHistory.removeLastChange(for: page.id, from: page.drawingData)
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
    endElementEditing()
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
    endElementEditing()
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
    endElementEditing()
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
    endElementEditing()
    drawingTool = .eraser
    let next = EraserStyle(maximumWidth: maximumWidth)
    guard next != eraserStyle else { return }
    eraserStyle = next
    saveEraserStyle()
  }

  func selectDrawingTool(_ tool: DrawingTool) {
    isPointing = false
    endElementEditing()
    drawingTool = tool
  }

  func selectElementTool() {
    isPointing = false
    isElementEditingEnabled = true
    elementEditingSession = ElementEditingSession()
  }

  func selectElement(_ reference: EditableElementReference) {
    if !isElementEditingEnabled { selectElementTool() }
    guard elementEditingSession.selection != reference else { return }
    elementEditingSession = ElementEditingSession(selection: reference)
  }

  func updateElementDrag(
    _ reference: EditableElementReference,
    translation: SpatialPoint
  ) {
    guard isElementEditingEnabled,
      elementEditingSession.selection == reference
    else { return }
    elementEditingSession = ElementEditingSession(
      selection: reference,
      translation: translation
    )
  }

  func finishElementDrag(
    _ reference: EditableElementReference,
    translation: SpatialPoint
  ) {
    guard isElementEditingEnabled,
      elementEditingSession.selection == reference
    else { return }
    elementEditingSession = ElementEditingSession(selection: reference)
    switch reference {
    case .page(let pageID, let elementID):
      _ = transformPageElement(
        pageID: pageID,
        elementID: elementID,
        by: translation
      )
    case .spatial(let elementID):
      _ = transformSpatialElement(elementID: elementID, by: translation)
    }
  }

  func updateElementResize(_ reference: EditableElementReference, delta: SpatialPoint) {
    guard isElementEditingEnabled, elementEditingSession.selection == reference else { return }
    elementEditingSession = .init(selection: reference, resizeDelta: delta)
  }

  func finishElementResize(_ reference: EditableElementReference, delta: SpatialPoint) {
    guard isElementEditingEnabled, elementEditingSession.selection == reference else { return }
    elementEditingSession = .init(selection: reference)
    switch reference {
    case .page(let pageID, let elementID): _ = transformPageElement(pageID: pageID, elementID: elementID, by: .zero, resizeBy: delta)
    case .spatial(let elementID): _ = transformSpatialElement(elementID: elementID, by: .zero, resizeBy: delta)
    }
  }

  func elementResizeDelta(_ reference: EditableElementReference) -> SpatialPoint {
    elementEditingSession.selection == reference ? elementEditingSession.resizeDelta : .zero
  }

  func deleteElement(_ reference: EditableElementReference) {
    guard isElementEditingEnabled,
      elementEditingSession.selection == reference
    else { return }
    endElementEditing()
    switch reference {
    case .page(let pageID, let elementID):
      _ = removePageElement(pageID: pageID, elementID: elementID)
    case .spatial(let elementID):
      _ = removeSpatialElement(elementID: elementID)
    }
  }

  func clearElementSelection() {
    endElementEditing()
  }

  private func endElementEditing() {
    isElementEditingEnabled = false
    elementEditingSession = ElementEditingSession()
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
        stamp: page.agentStamp,
        collaboration: page.collaboration
      )
    )
  }

  @discardableResult
  func transformPageElement(
    pageID: UUID,
    elementID: String,
    by translation: SpatialPoint,
    resizeBy delta: SpatialPoint = .zero
  ) -> Bool {
    let moved = mutatePageElements(pageID: pageID) { page, elements in
      guard let index = elements.firstIndex(where: { $0.id == elementID }) else {
        return false
      }
      let element = elements[index]
      let width = delta == .zero ? element.frame.width : min(max(44, element.frame.width + delta.x), page.size.width - element.frame.x)
      let height = delta == .zero ? element.frame.height : min(max(44, element.frame.height + delta.y), page.size.height - element.frame.y)
      let x = min(
        max(element.frame.x + translation.x, 0),
        page.size.width - width
      )
      let y = min(
        max(element.frame.y + translation.y, 0),
        page.size.height - height
      )
      let frame = PageRect(
        x: x,
        y: y,
        width: width,
        height: height
      )
      guard frame != element.frame else { return false }
      elements[index] = element.updating(frame: frame)
      return true
    }
    if moved { showCue(delta == .zero ? "Элемент перемещён" : "Размер элемента изменён") }
    return moved
  }

  @discardableResult
  func removePageElement(pageID: UUID, elementID: String) -> Bool {
    let removed = mutatePageElements(pageID: pageID) { _, elements in
      let count = elements.count
      elements.removeAll { $0.id == elementID }
      return elements.count != count
    }
    if removed { showCue("Элемент удалён") }
    return removed
  }

  @discardableResult
  func transformSpatialElement(
    elementID: String,
    by translation: SpatialPoint,
    resizeBy delta: SpatialPoint = .zero
  ) -> Bool {
    guard var hierarchy = boardHierarchy, let workspace, let presence else {
      return false
    }
    if let disk = try? store.loadBoard(items: workspace.items) {
      _ = hierarchy.merge(disk, items: workspace.items)
    }
    guard let board = hierarchy.board(presence.boardID) else { return false }
    guard let index = board.elements.firstIndex(where: { $0.id == elementID }) else {
      return false
    }
    var element = board.elements[index]
    let expected = element.stamp
    let geometry = itemGeometry(element.surface.ownerID)
    let width = delta == .zero ? element.frame.width : min(max(44, element.frame.width + delta.x), element.surface.kind == .cover ? geometry.width - element.frame.x : 2048)
    let height = delta == .zero ? element.frame.height : min(max(44, element.frame.height + delta.y), element.surface.kind == .cover ? geometry.height - element.frame.y : 2048)
    let proposedX = element.frame.x + translation.x
    let proposedY = element.frame.y + translation.y
    let x: Double
    let y: Double
    if element.surface.kind == .cover {
      x = min(max(proposedX, 0), geometry.width - width)
      y = min(max(proposedY, 0), geometry.height - height)
    } else {
      x = proposedX
      y = proposedY
    }
    let frame = SpatialRect(
      x: x,
      y: y,
      width: width,
      height: height
    )
    guard frame != element.frame,
      element.update(frame: frame, actor: actorID),
      hierarchy.upsertElement(
        element,
        in: presence.boardID,
        expected: expected,
        actor: actorID
      )
    else { return false }
    persistBoard(hierarchy)
    showCue(delta == .zero ? "Элемент перемещён" : "Размер элемента изменён")
    return true
  }

  @discardableResult
  func removeSpatialElement(elementID: String) -> Bool {
    guard var hierarchy = boardHierarchy, let workspace, let presence else {
      return false
    }
    if let disk = try? store.loadBoard(items: workspace.items) {
      _ = hierarchy.merge(disk, items: workspace.items)
    }
    guard hierarchy.removeElements(
      ids: [elementID],
      from: presence.boardID,
      actor: actorID
    ) == 1 else {
      return false
    }
    persistBoard(hierarchy)
    showCue("Элемент удалён")
    return true
  }

  private func mutatePageElements(
    pageID: UUID,
    mutation: (PageDocument, inout [AgentElement]) -> Bool
  ) -> Bool {
    guard var page = pages[pageID] else { return false }
    if let disk = try? store.loadPage(pageID) {
      _ = page.merge(disk)
    }
    var elements = page.elements
    guard mutation(page, &elements),
      page.replaceElements(elements, actor: actorID)
    else { return false }
    let resolved = persistMerged(page)
    sync.send(
      .elements(
        pageID: resolved.id,
        elements: resolved.elements,
        stamp: resolved.agentStamp,
        collaboration: resolved.collaboration
      )
    )
    return true
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
    guard !inputGate.isActive else { externalReloadPending = true; return }
    do {
      let disk = try store.collaborationContent()
      let previous = collaborationContent
      let oldActions = collaborationActions
      let oldContexts = SharedContextSnapshot(contexts: sharedContexts, selection: contextSelection)
      let resolved = try store.mergeCollaborationContent(disk, local: previous)
      acceptCollaborationContent(resolved)
      reloadCollaborationMetadata()
      if previous != resolved || oldActions != collaborationActions || oldContexts != SharedContextSnapshot(contexts: sharedContexts, selection: contextSelection) {
        sendCollaboration(content: resolved.publication(since:previous))
      }
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
    private func startPreviewPublication() {
      guard previewPublisher == nil else { return }
      let publisher = MacPreviewPublisher(model: self)
      publisher.start()
      previewPublisher = publisher
    }

    private func startExternalChangeObservation() {
      guard externalChangeWatcher == nil else { return }
      let watcher = DirectoryWatcher(urls: [
        store.root,
        store.pagesURL,
        store.documentsURL,
        store.documentStatesURL,
        store.collaborationURL,
        store.collaborationActionsURL,
        store.deviceReceiptsURL,
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
    case .inputActivity(let activity):
      guard activity.isValid else { return }
      do {
        try store.saveInputActivity(activity)
        peerInputIsActive = try store.inputActivities().contains { $0.deviceID != actorID && $0.isActive }
        #if os(macOS)
          if peerInputIsActive { previewPublisher?.suspendForInput() }
        #endif
      } catch { showCue(error.localizedDescription) }
    case .collaboration(let envelope):
      if inputGate.isActive {
        do { deferredCollaboration = try (deferredCollaboration ?? .init()).merging(envelope) }
        catch { showCue(error.localizedDescription) }
        return
      }
      do {
        if let resolved = try store.receiveCollaboration(envelope,local:collaborationContent) {
          acceptCollaborationContent(resolved)
        }
        reloadCollaborationMetadata()
        #if os(iOS)
          acknowledgeReceivedActions()
        #endif
      } catch { showCue(error.localizedDescription) }
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
    case .elements(let pageID, let elements, let stamp, let collaboration):
      guard var page = pages[pageID],
        page.mergeElements(elements, stamp: stamp, collaboration: collaboration)
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
      if var current = boardHierarchy {
        if current.merge(incoming, items: workspace.items) {
          boardHierarchy = (try? store.saveMergedBoard(
            current,
            items: workspace.items
          )) ?? current
          reconcilePresence(with: workspace, board: boardHierarchy)
        } else {
          stageRemoteBoard(incoming)
        }
      } else {
        if incoming.isValid(items: workspace.items) {
          boardHierarchy = incoming
          try? store.saveBoard(incoming, items: workspace.items)
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
            board: boardHierarchy,
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
    case .documentPageSelection(let request):
      #if os(iOS)
        guard request.isValid else { return }
        _ = selectDocumentPage(
          request.pageIndex,
          documentID: request.documentID,
          publishesRequest: false
        )
      #endif
    }
  }

  private func sendSnapshot() {
    guard let workspace else { return }
    _ = workspace
    sendCollaboration(content: collaborationContent)
    #if os(iOS)
      if let lastSettledPresenceEnvelope {
        sync.send(.presence(lastSettledPresenceEnvelope))
      }
    #endif
  }

  func publishHumanContext(_ references: [CollaborationReference]) {
    do {
      _ = try store.appendContext(references: references, author: .human, actor: actorID, select: true)
      reloadCollaborationMetadata(); isPointing = false
      sync.send(.collaboration(.init(contexts: sharedContexts, selection: contextSelection)))
    } catch { showCue(error.localizedDescription) }
  }

  func selectSharedContext(_ id: UUID?) {
    do {
      try store.selectSharedContext(id, actor: actorID)
      reloadCollaborationMetadata()
      sync.send(.collaboration(.init(contexts: sharedContexts, selection: contextSelection)))
    } catch { showCue(error.localizedDescription) }
  }

  func results(for action: CollaborationReceipt) -> [CollaborationReference] {
    if let result = resultCache[action.id] { return result }
    let result = collaborationContent.map { action.resultReferences(in:$0) } ?? []
    resultCache[action.id] = result
    return result
  }

  func continuations(for action: CollaborationReceipt) -> [CollaborationContinuation] {
    guard action.undo == nil else { return [] }
    let signature = action.revisions.map { expectation in
      (collaborationRevision(expectation.target) ?? "missing") + "|" + (documentStates[expectation.target.id]?.stamp.revision ?? "")
    }.joined(separator:";")
    if let cached = continuationCache[action.id], cached.0 == signature { return cached.1 }
    guard let files = try? collaborationContent?.sourceFiles() else { return [] }
    let result = action.continuations(in:files)
    continuationCache[action.id] = (signature,result)
    return result
  }

  func referenceChanged(_ reference: CollaborationReference) -> Bool {
    if reference.region != nil && reference.elementID == nil {
      let status = regionalReferenceStatuses[reference.id]?.status ?? .checking
      return status == .changed || status == .targetMissing || status == .reviewRequired
    }
    let target = reference.target
    let signature: String
    switch target.kind {
    case .page: signature = pages[target.id].map { "\($0.drawingStamp.revision)|\($0.agentStamp.revision)" } ?? "missing"
    case .document: signature = (documents[target.id]?.contentStamp.revision ?? "missing") + "|" + (documentStates[target.id]?.stamp.revision ?? "missing")
    case .cover,.board: signature = (boardHierarchy?.revision ?? "missing") + "|" + (spatialInk?.stamp.revision ?? "missing")
    case .workspace: signature = workspace?.stamp.revision ?? "missing"
    }
    if let entry = referenceStatusCache[reference.id], entry.0 == signature { return entry.1 }
    guard let files = try? collaborationContent?.sourceFiles() else { return true }
    let changed = (try? NotebookStore.referenceRevision(target:reference.target,elementID:reference.elementID,files:files)) != reference.revision
    referenceStatusCache[reference.id] = (signature,changed)
    return changed
  }

  func refreshReferenceStatuses() async {
    guard presencePhase == .settled else { return }
    let references = Array(contextEntries.flatMap(\.references).filter { $0.region != nil && $0.elementID == nil }.prefix(32))
    let store = store
    let values = await Task.detached(priority: .utility) {
      references.map { ($0.id, (try? store.referenceStatus($0, prepareRender: false)) ?? .init(.checking)) }
    }.value
    guard !Task.isCancelled else { return }
    regionalReferenceStatuses = Dictionary(values, uniquingKeysWith: { _, new in new })
  }

  func referenceStatusLabel(_ reference: CollaborationReference) -> String? {
    if reference.region != nil && reference.elementID == nil {
      switch regionalReferenceStatuses[reference.id]?.status ?? .checking {
      case .checking: return "Проверяется область"
      case .reviewRequired: return "Нужно рассмотреть заново"
      case .targetMissing: return "Исходник удалён"
      case .changed: return "Фрагмент изменился"
      case .current: return nil
      }
    }
    return referenceChanged(reference) ? "Фрагмент изменился" : nil
  }

  func referenceTitle(_ reference: CollaborationReference) -> String {
    switch reference.target.kind {
    case .page: return "Лист"
    case .document: return "Документ"
    case .cover: return "Обложка"
    case .board: return "Доска"
    case .workspace: return "Рабочее место"
    }
  }

  func requestShow(_ reference: CollaborationReference) {
    if requestedReference == nil, let presence {
      returnPlaces.append(.init(presence: presence, pageID: workspace?.selectedPageID))
      returnPlaces = Array(returnPlaces.suffix(32))
    }
    requestedReference = .init(target:reference.target,elementID:reference.elementID,region:reference.region,
      worldOrigin:reference.worldOrigin,pageIndex:reference.pageIndex,revision:reference.revision,label:reference.label)
  }

  func requestReturnToPlace() {
    guard requestedReturn == nil, let place = returnPlaces.popLast() else { return }
    requestedReference = nil
    requestedReturn = place
  }

  func completeReturnToPlace() { requestedReturn = nil; highlightedReference = nil }

  func locationTitle(for reference: CollaborationReference) -> String {
    let item = workspace?.items.first { $0.id == reference.target.id || $0.pageIDs.contains(reference.target.id) }
    if reference.target.kind == .page, let item, let index = item.pageIDs.firstIndex(of: reference.target.id) {
      return "\(item.title) · лист \(index + 1)"
    }
    return item?.title ?? referenceTitle(reference)
  }

  func completeShow(_ reference: CollaborationReference) {
    if requestedReference?.id == reference.id { requestedReference = nil }
    highlightedReference = reference
    referenceHighlightTask?.cancel()
    referenceHighlightTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled else { return }
      self?.highlightedReference = nil
    }
  }

  func dismissCollaborationNotice() {
    collaborationNoticeTask?.cancel()
    showsCollaborationNotice = false
  }

  func undoCollaboration(_ id: UUID) {
    guard collaborationUndoTask == nil else { return }
    afterPageInput { [weak self] in
      guard let self else { return }
      let store = store, actor = actorID, local = collaborationContent
      collaborationUndoTask = Task { [weak self] in
        let result = await Task.detached(priority:.userInitiated) { () -> Result<CollaborationReceipt, Error> in
          do {
            if let local { _ = try store.mergeCollaborationContent(local) }
            return .success(try store.undoCollaborationAction(id,actor:actor,waitForInput:4))
          } catch { return .failure(error) }
        }.value
        guard let self else { return }
        collaborationUndoTask = nil
        switch result {
        case .success(let receipt):
          reloadExternalChanges()
          showCue(receipt.undo?.preserved.isEmpty == false ? "Ход отменён. Ваши доработки сохранены" : "Ход отменён")
        case .failure(let error): showCue(error.localizedDescription)
        }
      }
    }
  }

  func pagePresented(_ page: PageDocument, ready: Bool) {
    readyPages[page.id] = ready ? "\(page.drawingStamp.revision)|\(page.agentStamp.revision)" : nil
  }

  private func collaborationRevision(_ target: CollaborationTarget) -> String? {
    switch target.kind {
    case .page: return pages[target.id]?.agentStamp.revision
    case .document: return documents[target.id]?.contentStamp.revision
    case .board,.cover: return boardHierarchy?.board(target.boardID ?? target.id)?.stamp.revision
    case .workspace: return workspace?.stamp.revision
    }
  }

  func confirmVisibleActions(presence visible: SessionPresence) {
    #if os(iOS)
      guard collaborationActions.contains(where: { action in !deviceActionReceipts.contains(where: { $0.id == action.id && $0.revisions == action.revisions && $0.displayComplete }) }),
        presencePhase == .settled, presence == visible, !isPointing,
        collaborationContent != nil else { return }
      acknowledgeReceivedActions()
      let receipts = deviceActionReceipts
      var changed: [DeviceActionReceipt] = []
      for action in collaborationActions.prefix(50) {
        guard var receipt = receipts.first(where: { $0.id == action.id && $0.revisions == action.revisions }), !receipt.displayComplete else { continue }
        let references = results(for:action)
        let viewport = CGRect(x:0,y:0,width:visible.viewport.x,height:visible.viewport.y)
        for reference in references where !receipt.visibleRegions.contains(where: { $0.id == reference.id }) {
          let owner = reference.target.kind == .cover ? CollaborationTarget(kind:.board,id:reference.target.boardID!) : reference.target
          guard let expected = action.revisions.first(where: { $0.target == owner || $0.target == reference.target }),
            collaborationRevision(expected.target) == expected.revision,
            expected.stateRevision == nil || documentStates[expected.target.id]?.stamp.revision == expected.stateRevision,
            expected.inkRevision == nil || (expected.target.kind == .page
              ? pages[expected.target.id]?.drawingStamp.revision : spatialInk?.stamp.revision) == expected.inkRevision,
            let rect = NotebookAttentionProjection.frame(reference,model:self,presence:visible), viewport.contains(rect) else { continue }
          let ready: Bool
          switch reference.target.kind {
          case .page:
            if let page = pages[reference.target.id] { ready = readyPages[page.id] == "\(page.drawingStamp.revision)|\(page.agentStamp.revision)" }
            else { ready = false }
          case .document:
            if let document = documents[reference.target.id], let state = documentStates[document.id] {
              ready = DocumentRenderRegistry.shared.entry(document:document,state:state,pageIndex:visible.documentPageIndex) != nil
            } else { ready = false }
          case .board,.cover:
            if let board = boardHierarchy?.board(reference.target.boardID ?? reference.target.id) {
              ready = board.elements.filter { $0.kind != .nativeText && (reference.elementID == nil || $0.id == reference.elementID) }
                .allSatisfy { AgentElementSnapshotCache.shared.image(for:agentElementSnapshotSource($0)) != nil }
            } else { ready = false }
          case .workspace: ready = false
          }
          guard ready else { continue }
          if !receipt.shown.contains(expected) { receipt.shown.append(expected) }
          receipt.visibleRegions.append(reference)
        }
        receipt.displayComplete = !references.isEmpty && references.allSatisfy { ref in receipt.visibleRegions.contains { $0.id == ref.id } }
        if receipt != receipts.first(where: { $0.id == action.id }) {
          try? store.saveDeviceActionReceipt(receipt); changed.append(receipt)
        }
      }
      for receipt in changed {
        deviceActionReceipts.removeAll { $0.id == receipt.id }; deviceActionReceipts.append(receipt)
      }
      if !changed.isEmpty { sync.send(.collaboration(.init(delivery:changed))) }
    #endif
  }

  var collaborationContent: CollaborationContent? {
    guard let workspace, let boardHierarchy, let spatialInk else { return nil }
    return CollaborationContent(workspace: workspace, hierarchy: boardHierarchy, ink: spatialInk,
      pages: Array(pages.values), documents: Array(documents.values), states: Array(documentStates.values))
  }

  private func acceptCollaborationContent(_ content: CollaborationContent) {
    guard collaborationContent != content else { return }
    #if os(iOS)
      let humanSelection = workspace
    #endif
    workspace = content.workspace; boardHierarchy = content.hierarchy; spatialInk = content.ink
    pages = Dictionary(uniqueKeysWithValues: content.pages.map { ($0.id, $0) })
    documents = Dictionary(uniqueKeysWithValues: content.documents.map { ($0.id, $0) })
    documentStates = Dictionary(uniqueKeysWithValues: content.states.map { ($0.id, $0) })
    #if os(iOS)
      if let focus = presence?.focusedItemID, focus == humanSelection?.selectedItemID,
        let item = content.workspace.items.first(where: { $0.id == focus }) {
        selectItem(focus)
        if item.kind == .notebook, let pageID = humanSelection?.selectedPageID, let index = item.pageIDs.firstIndex(of:pageID) {
          _ = selectNotebookPage(index,notebookID:focus)
        }
      }
    #endif
    reconcilePresence(with: workspace ?? content.workspace, board: content.hierarchy)
  }

  private func reloadCollaborationMetadata() {
    collaborationActions = (try? store.collaborationActions()) ?? []
    let contexts = try? store.sharedContexts()
    sharedContexts = contexts?.contexts ?? []
    contextSelection = contexts?.selection
    deviceActionReceipts = (try? store.deviceActionReceipts()) ?? []
    let latest = collaborationActions.first
    let attention = sharedContexts.flatMap(\.entries).filter { $0.author == .agent }.max { $0.createdAt < $1.createdAt }
    let key = "\(latest?.id.uuidString ?? "")|\(latest?.undo?.completedAt.timeIntervalSince1970 ?? 0)|\(attention?.id.uuidString ?? "")"
    guard key != collaborationNoticeKey else { return }
    let firstLoad = collaborationNoticeKey == nil
    collaborationNoticeKey = key
    let recentlyCreated = latest.map { Date().timeIntervalSince($0.undo?.completedAt ?? $0.createdAt) < 6 } ?? false
    guard !firstLoad || recentlyCreated else { return }
    showsCollaborationNotice = latest != nil || attention != nil
    collaborationNoticeTask?.cancel()
    collaborationNoticeTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(6))
      guard !Task.isCancelled else { return }
      self?.showsCollaborationNotice = false
    }
  }

  private func sendCollaboration(content: CollaborationContent? = nil) {
    sync.send(.collaboration(.init(content: content,
      actions: Array(collaborationActions.prefix(50)), contexts: sharedContexts, selection: contextSelection,
      delivery: (try? store.deviceActionReceipts()) ?? [])))
  }

  private func acknowledgeReceivedActions() {
    let previous = deviceActionReceipts
    var added: [DeviceActionReceipt] = []
    for action in collaborationActions where !previous.contains(where: { $0.id == action.id && $0.revisions == action.revisions }) {
      let receipt = DeviceActionReceipt(id: action.id, deviceID: actorID, revisions: action.revisions)
      try? store.saveDeviceActionReceipt(receipt); added.append(receipt)
      deviceActionReceipts.removeAll { $0.id == action.id }; deviceActionReceipts.append(receipt)
    }
    if !added.isEmpty { sync.send(.collaboration(.init(delivery: added))) }
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
        if previousDrawingStamp < current.drawingStamp, PageInkDrawing.needsMigration(current.drawingData) {
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

  private func scheduleWorkspaceSelectionSave(
    _ workspace: WorkspaceIndex,
    createdPage: PageDocument?
  ) {
    let previous = workspaceSelectionSaveTail
    let store = store
    workspaceSelectionSaveTail = Task.detached(priority: .utility) {
      if let previous { await previous.value }
      guard !Task.isCancelled else { return }
      _ = try? store.saveWorkspaceSelection(
        index: workspace,
        createdPage: createdPage
      )
    }
  }

  private func schedulePresenceSave(_ presence: SessionPresence) {
    let previous = presenceSaveTail
    let store = store
    presenceSaveTail = Task.detached(priority: .utility) {
      if let previous { await previous.value }
      guard !Task.isCancelled else { return }
      try? store.savePresence(presence)
    }
  }

  private func persistPresence(
    _ presence: SessionPresence,
    using persistence: PresencePersistence
  ) {
    switch persistence {
    case .immediate:
      try? store.savePresence(presence)
    case .deferred:
      schedulePresenceSave(presence)
    }
  }

  private func persistBoard(_ board: BoardHierarchy) {
    guard let workspace else { return }
    let resolved = (try? store.saveMergedBoard(
      board,
      items: workspace.items
    )) ?? board
    boardHierarchy = resolved
    sync.send(.board(resolved))
  }

  @discardableResult
  private func persistMerged(_ page: PageDocument) -> PageDocument {
    let previousDrawingStamp = pages[page.id]?.drawingStamp
    let resolved = (try? store.saveMergedPage(page)) ?? page
    pages[page.id] = resolved
    if let previousDrawingStamp,
      previousDrawingStamp < resolved.drawingStamp, PageInkDrawing.needsMigration(resolved.drawingData)
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
    board: BoardHierarchy?,
    viewport: PageSize
  ) -> SessionPresence {
    let item = workspace.selectedItem
    let itemID = item.id
    let viewportPoint = SpatialPoint(x: viewport.width, y: viewport.height)
    if item.kind == .board, board?.board(itemID) != nil {
      return SessionPresence(
        boardID: itemID,
        mode: .board,
        camera: SpatialCamera(),
        viewport: viewportPoint
      )
    }
    let ownerBoardID = board?.ownerBoardID(of: itemID)
      ?? workspace.rootBoardID
    let center = board?.focusedCenter(of: itemID, in: ownerBoardID) ?? .zero
    let fit = itemGeometry(itemID).fitScale(
      viewport: viewportPoint
    )
    return SessionPresence(
      boardID: ownerBoardID,
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
    board: BoardHierarchy?,
    viewport: SpatialPoint
  ) -> SessionPresence {
    let adapted = presence.adapted(to: viewport, geometry: itemGeometry(presence.focusedItemID))
    guard board?.board(presence.boardID) != nil else {
      return SessionPresence(
        boardID: workspace.rootBoardID,
        mode: .board,
        camera: SpatialCamera(),
        viewport: viewport
      )
    }
    let itemID = presence.focusedItemID
    let itemCenter = itemID.flatMap { id in
      board?.focusedCenter(of: id, in: presence.boardID)
    }
    let focusedItem = itemID.flatMap { id in
      workspace.items.first(where: { $0.id == id })
    }
    let modeMatchesFocusedItem =
      (presence.mode == .page && focusedItem?.kind == .notebook)
      || (presence.mode == .document && focusedItem?.kind == .document)

    if presence.mode == .page || presence.mode == .document,
      let itemID,
      let itemCenter,
      modeMatchesFocusedItem
    {
      return SessionPresence(
        boardID: presence.boardID,
        mode: presence.mode,
        camera: SpatialCamera(
          center: itemCenter,
          scale: itemGeometry(itemID).fitScale(viewport: viewport)
        ),
        viewport: viewport,
        focusedItemID: itemID,
        openProgress: 1,
        documentPageIndex: presence.mode == .document
          ? presence.documentPageIndex
          : 0
      )
    }

    if presence.mode == .cover,
      let itemID,
      workspace.items.contains(where: { $0.id == itemID }),
      board?.ownerBoardID(of: itemID) == presence.boardID
    {
      return adapted
    }

    return SessionPresence(
      boardID: presence.boardID,
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
    if let previousDrawingStamp, previousDrawingStamp < page.drawingStamp, PageInkDrawing.needsMigration(page.drawingData) {
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

    reconcilePresence(with: workspace, board: boardHierarchy)
  }

  /// Selection lives in the catalog while its screen anchor lives on the
  /// board. A newer catalog or board therefore settles the camera from both
  /// owners together. This keeps a deleted focus from leaving an empty view.
  private func reconcilePresence(
    with workspace: WorkspaceIndex,
    board: BoardHierarchy?
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

  private func stageRemoteBoard(_ incoming: BoardHierarchy) {
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
    var boardCandidates = [BoardHierarchy]()
    if let boardHierarchy, boardHierarchy.isValid(items: incoming.items) {
      boardCandidates.append(boardHierarchy)
    }
    if let stagedRemoteBoard,
      stagedRemoteBoard.isValid(items: incoming.items)
    {
      boardCandidates.append(stagedRemoteBoard)
    }
    let exactBoards = boardCandidates.filter {
      Set($0.itemIDs) == expectedItemIDs
    }
    guard var candidateBoard = (exactBoards.isEmpty
      ? boardCandidates
      : exactBoards
    ).max(by: { $0.stamp < $1.stamp }) else { return }
    if var current = boardHierarchy {
      _ = current.merge(candidateBoard, items: incoming.items)
      guard current.isValid(items: incoming.items) else { return }
      candidateBoard = current
    }

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
    boardHierarchy = candidateBoard
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
        board: boardHierarchy,
        viewport: stored.viewport
      )
      presencePhase = .settled
    #endif
  }

  private func presenceIsUsable(
    _ presence: SessionPresence,
    workspace: WorkspaceIndex
  ) -> Bool {
    guard presence.isValid,
      let hierarchy = boardHierarchy,
      hierarchy.board(presence.boardID) != nil
    else { return false }
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
      guard hierarchy.ownerBoardID(of: itemID) == presence.boardID else {
        return false
      }
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

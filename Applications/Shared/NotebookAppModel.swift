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

  static let initialNotebookID = UUID(
    uuidString: "7E7A0000-0000-4000-8000-000000000001"
  )!
  static let initialPageID = UUID(
    uuidString: "7E7A0000-0000-4000-8000-000000000002"
  )!
  static let defaultPageSize = PageSize(width: 834, height: 1_194)

  private(set) var loadState: LoadState = .loading
  private(set) var workspace: WorkspaceIndex? { didSet { collaborationReadEpoch &+= 1; scheduleScenePreparation() } }
  private(set) var pages: [UUID: PageDocument] = [:] { didSet { collaborationReadEpoch &+= 1 } }
  private(set) var documents: [UUID: DocumentDocument] = [:] { didSet { collaborationReadEpoch &+= 1; scheduleScenePreparation() } }
  private(set) var documentStates: [UUID: DocumentStateJournal] = [:] { didSet { collaborationReadEpoch &+= 1 } }
  private(set) var boardHierarchy: BoardHierarchy? { didSet { collaborationReadEpoch &+= 1; scheduleScenePreparation() } }
  private(set) var spatialInk: SpatialInkJournal? { didSet { collaborationReadEpoch &+= 1 } }
  private(set) var sceneIndex: WorkspaceSceneIndex?
  private(set) var scenePreparationPending = false
  private(set) var sceneIndexGeneration: UInt64 = 0
  @ObservationIgnored private var scenePreparationTask: Task<Void, Never>?
  @ObservationIgnored private var scenePreparationRequest: UInt64 = 0
  @ObservationIgnored private var preparedScene: (index: WorkspaceSceneIndex?, changed: Bool, portals: [UUID: BoardPortalCamera], request: UInt64)?
  private var scenePortalCameras: [UUID: BoardPortalCamera] = [:]
  @ObservationIgnored private(set) var sceneQueryCount: UInt64 = 0

  /// Coalesce a completed content publication before deriving the spatial
  /// read model. The old generation remains visible until the next is whole.
  private func scheduleScenePreparation() {
    scenePreparationRequest &+= 1
    scenePreparationPending = true
    preparedScene = nil
    guard scenePreparationTask == nil else { return }
    scenePreparationTask = Task { [weak self] in
      await Task.yield()
      guard let self else { return }
      while !Task.isCancelled, let workspace, let boardHierarchy {
        let request = scenePreparationRequest
        let documents = documents
        let previous = sceneIndex
        let result = await Task.detached(priority: .utility) {
          let portals = Dictionary(uniqueKeysWithValues: boardHierarchy.boards.map { ($0.id, $0.portalCamera) })
          let changed = previous?.represents(workspace: workspace, hierarchy: boardHierarchy, documents: documents) != true
          let index = changed ? WorkspaceSceneIndex(workspace: workspace, hierarchy: boardHierarchy, documents: documents) : previous
          return (index, changed, portals)
        }.value
        // At most one builder exists. Obsolete work cannot publish or enqueue
        // a second expensive build in parallel with the latest publication.
        guard request == scenePreparationRequest else { continue }
        preparedScene = (result.0, result.1, result.2, request)
        scenePreparationTask = nil
        publishPreparedSceneIfPossible()
        return
      }
      scenePreparationTask = nil
    }
  }

  private func publishPreparedSceneIfPossible() {
    guard let prepared = preparedScene, prepared.request == scenePreparationRequest,
      !prepared.changed || (!inputIsActive && !peerInputIsActive) else { return }
    scenePortalCameras = prepared.portals
    if prepared.changed { sceneIndex = prepared.index; sceneIndexGeneration &+= 1 }
    preparedScene = nil
    scenePreparationPending = false
  }

  /// Pages are read from their current catalog owner, independently of the
  /// background geometry generation and any preceding membership changes.
  func itemForDisplay(id: UUID) -> WorkspaceItem? {
    workspace?.item(id: id)
  }

  func scenePortalCamera(boardID: UUID) -> BoardPortalCamera? { scenePortalCameras[boardID] }

  func sceneWorkset(presence: SessionPresence, pinned: Set<WorkspaceSpatialID> = [],
    limit: Int = WorkspaceSceneIndex.detailLimit, pixelScale: Double? = nil) -> WorkspaceSceneWorkset {
    sceneQueryCount &+= 1
    return sceneIndex?.workset(presence: presence, pinned: pinned, limit: limit, pixelScale: pixelScale) ?? .empty
  }

  private(set) var presence: SessionPresence?
  private(set) var presencePhase = PresencePhase.settled
  var interactiveElementFocus: InteractiveElementReference?
  var isPointing = false
  struct ReturnPlace: Identifiable {
    let id = UUID()
    let presence: SessionPresence
    let pageID: UUID?
  }
  private(set) var returnPlaces: [ReturnPlace] = []
  private(set) var requestedReturn: ReturnPlace?
  private(set) var requestedReference: CollaborationReference?
  private(set) var highlightedReference: CollaborationReference? { didSet { collaborationReadEpoch &+= 1 } }
  private(set) var showsCollaborationNotice = false
  private var collaborationNoticeKey: String?
  private var collaborationNoticeTask: Task<Void, Never>?
  private var referenceHighlightTask: Task<Void, Never>?
  private var collaborationUndoTask: Task<Void, Never>?
  private var collaborationReadSnapshot: CollaborationReadSnapshot?
  private(set) var collaborationReadEpoch: UInt64 = 0
  private var preparedCollaborationVersion: UInt64?
  @ObservationIgnored private var collaborationReadTask: Task<CollaborationReadSnapshot, Error>?
  @ObservationIgnored private var collaborationReadGeneration = 0
  private var deviceActionReceipts: [DeviceActionReceipt] = []
  private var readyPages: [UUID: String] = [:]
  private(set) var isPeerConnected = false
  private(set) var collaborationActions: [CollaborationReceipt] = [] { didSet { collaborationReadEpoch &+= 1 } }
  private(set) var regionalReferenceStatuses: [UUID: ReferenceStatus] = [:]
  private(set) var sharedContexts: [SharedContext] = [] { didSet { collaborationReadEpoch &+= 1 } }
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
  private var pendingPageSaves: Set<UUID> = []
  private var peerPageTail: Task<Void, Never>?
  private var peerPageGeneration: UInt64 = 0
  private var spatialInkSavePending = false
  private var boardSaveTask: Task<Void, Never>?
  private var boardSavePending = false
  private var pendingStoreWrites: [(reload: Bool, operation: @Sendable (NotebookStore) throws -> Void)] = []
  private var storeWriteTask: Task<Void, Never>?
  private var peerActivities: [UUID: NotebookInputActivity] = [:]
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
  private var presenceSaveTail: Task<Void, Never>?
  private var pendingPresenceToSave: SessionPresence?
  private var cueTask: Task<Void, Never>?
  private var pencilUndoHistory = PencilUndoHistory()
  private var inkUndoInProgress = false
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
  @ObservationIgnored private var incomingCollaboration: [CollaborationEnvelope] = []
  @ObservationIgnored private var diskRefreshTask: Task<Void, Never>?
  @ObservationIgnored private var diskRefreshRequested = false
  @ObservationIgnored private var externalReloadPending = false
  @ObservationIgnored private var inputSequence: UInt64 = 0
  @ObservationIgnored private var inputWriteTask: Task<Void, Never>?
  @ObservationIgnored private var pendingInputActivity: NotebookInputActivity?
  private(set) var inputIsActive = false
  private(set) var peerInputIsActive = false { didSet { if !peerInputIsActive { publishPreparedSceneIfPossible() } } }
  var permitsBackgroundPreparation: Bool { !inputIsActive && !peerInputIsActive && presencePhase == .settled }
  #if os(macOS)
    /// MCP writes the same files as the app. This observer belongs to the
    /// long-lived model, so closing the mirror window cannot stop delivery to
    /// the iPad while the Mac app is still running.
    private var externalChangeWatcher: DirectoryWatcher?
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
      self?.peerActivities.removeAll()
      if let self { let actor = actorID; Task.detached(priority: .utility) { try? store.resetInputActivities(keeping: actor) } }
      self?.restoreSettledPresenceAfterDisconnect()
    }
    inputGate.onActivityChange = { [weak self] active in
      guard let self else { return }
      inputIsActive = active
      if active { collaborationReadTask?.cancel() }
      #if os(macOS)
        if active { previewPublisher?.suspendForInput() }
      #else
        if active { inputFrameMonitor.begin(mode: presence?.mode.rawValue ?? "unknown") }
        else { inputFrameMonitor.end() }
      #endif
      publishInputActivity()
      if !active {
        publishPreparedSceneIfPossible()
        if externalReloadPending || !incomingCollaboration.isEmpty {
          externalReloadPending = false
          reloadExternalChanges()
        }
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
      settled: settled
    )
  }

  @discardableResult
  func enterBoard(_ boardID: UUID, through parentCamera: SpatialCamera? = nil, settled: Bool = true) -> Bool {
    guard let workspace, let hierarchy = boardHierarchy, let presence else { return false }
    let item = sceneIndex?.item(id: boardID)
      ?? (sceneIndex == nil ? workspace.items.first { $0.id == boardID } : nil)
    let boardExists = sceneIndex.map { $0.board(id: boardID) != nil } ?? (hierarchy.board(boardID) != nil)
    guard item?.kind == .board, boardExists else { return false }
    let portal = scenePortalCamera(boardID: boardID) ?? hierarchy.portalCamera(boardID) ?? BoardPortalCamera()
    let camera: SpatialCamera
    if let parentCamera {
      guard let center = sceneIndex?.focusedCenter(itemID: boardID, boardID: presence.boardID)
        ?? (sceneIndex == nil ? hierarchy.focusedCenter(of: boardID, in: presence.boardID) : nil),
        let entered = BoardPortalProjection.enteringCamera(from: parentCamera,
          portalCamera: portal,
          portalCenter: center, viewport: presence.viewport) else { return false }
      camera = entered
    } else {
      camera = BoardPortalProjection.entryCamera(
        portalCamera: portal, viewport: presence.viewport)
    }
    selectItem(boardID)
    updatePresence(
      SessionPresence(
        boardID: boardID,
        mode: .board,
        camera: camera,
        viewport: presence.viewport
      ),
      settled: settled
    )
    return true
  }

  /// Moves ownership to the parent at the one frame where the child and its
  /// portal are the same projection. The view can then continue zooming out
  /// without a visual cut.
  @discardableResult
  func leaveBoard(through passage: BoardPortalProjection.ExitProjection? = nil, settled: Bool = true) -> Bool {
    guard var hierarchy = boardHierarchy, let presence,
      let parentID = hierarchy.parentBoardID(of: presence.boardID),
      let center = hierarchy.focusedCenter(of: presence.boardID, in: parentID)
    else { return false }
    let projection = passage ?? BoardPortalProjection.exitingCamera(
      boundary: presence.camera, centroid: .init(x: presence.viewport.x / 2, y: presence.viewport.y / 2),
      portalCenter: center, viewport: presence.viewport)
    // A local passage changes only coordinates. When both physical owners are
    // already represented, its normalized camera must reach the very first
    // parent frame, rather than wait for a background metadata comparison.
    let carriesPreparedGeometry = sceneIndex?.board(id: presence.boardID)?.stamp == hierarchy.board(presence.boardID)?.stamp
      && sceneIndex?.board(id: parentID)?.stamp == hierarchy.board(parentID)?.stamp
    if hierarchy.updatePortalCamera(
      projection.portalCamera,
      for: presence.boardID,
      actor: actorID
    ) {
      persistBoard(hierarchy)
    }
    if carriesPreparedGeometry {
      scenePortalCameras[presence.boardID] = projection.portalCamera
    }
    selectItem(presence.boardID)
    updatePresence(
      SessionPresence(
        boardID: parentID,
        mode: .cover,
        camera: projection.parentCamera,
        viewport: presence.viewport,
        focusedItemID: presence.boardID,
        openProgress: BoardPortalProjection.openingProgress(camera: projection.parentCamera,
          portalCenter: center, viewport: presence.viewport)
      ),
      settled: settled
    )
    return true
  }

  private func applyPresence(
    _ presence: SessionPresence,
    settled: Bool
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
    let inputOwnerChanged = self.presence?.boardID != resolved.boardID
      || self.presence?.mode != resolved.mode
      || self.presence?.focusedItemID != resolved.focusedItemID
    if inputOwnerChanged { interactiveElementFocus = nil }
    self.presence = resolved
    // A continuous contact can cross a portal without ending. Transfer its
    // publication barrier with the physical owner, not with each camera frame.
    if inputIsActive && inputOwnerChanged { publishInputActivity() }
    let phase = settled ? PresencePhase.settled : .active
    presencePhase = phase
    #if os(iOS)
      guard let envelope = makePresenceEnvelope(resolved, phase: phase) else {
        return
      }
      sync.send(.presence(envelope))
      if settled {
        lastSettledPresenceEnvelope = envelope
        schedulePresenceSave(resolved)
      }
    #else
      if settled { schedulePresenceSave(resolved) }
    #endif
    if settled && externalReloadPending { externalReloadPending = false; reloadExternalChanges() }
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
      settled: true
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
      Task { [weak self] in await self?.undoLastDrawingAction() }
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

  func commitSpatialElementState(boardID: UUID, elementID: String, state: JSONValue) {
    guard var hierarchy = boardHierarchy, presence?.boardID == boardID,
      let board = hierarchy.board(boardID),
      let index = board.elements.firstIndex(where: { $0.id == elementID })
    else { return }
    var element = board.elements[index]
    let expected = element.stamp
    guard element.update(state: state, actor: actorID),
      hierarchy.upsertElement(
        element,
        in: boardID,
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

  func commitDrawingAction(
    _ action: PageInkAction,
    pageID: UUID,
    stamp: VersionStamp
  ) async -> PreparedPageInkChange? {
    guard stamp.actor == actorID,
      stamp.counter <= reservedDrawingCounters[pageID, default: 0] else { return nil }
    guard let change = await publishInkMutation(.append(action), pageID: pageID, stamp: stamp) else { return nil }
    pencilUndoHistory.recordAction(pageID: pageID, actionID: action.id)
    return change
  }

  /// Only a prepared, still-current drawing crosses back to MainActor. A peer
  /// that advanced this page during preparation is included in the retry.
  private func publishInkMutation(
    _ mutation: PageInkMutation, pageID: UUID, stamp: VersionStamp
  ) async -> PreparedPageInkChange? {
    while !Task.isCancelled, let snapshot = pages[pageID] {
      let prepared = await Task.detached(priority: .userInitiated) {
        try? snapshot.prepareInkChange(mutation, stamp: stamp)
      }.value
      guard !Task.isCancelled, let change = prepared, var current = pages[pageID] else { return nil }
      guard current.publishInkChange(change) else { continue }
      if change.stamp == change.baseStamp { return change }
      pages[pageID] = current
      sync.send(.drawing(pageID: pageID, data: change.data, stamp: change.stamp))
      scheduleSave(pageID)
      return change
    }
    return nil
  }

  func undoLastDrawingAction() async {
    guard !inkUndoInProgress, let page = activePage,
      let ids = pencilUndoHistory.lastContribution(for: page.id),
      let stamp = reserveDrawingAction(pageID: page.id) else { return }
    inkUndoInProgress = true
    defer { inkUndoInProgress = false }
    guard await publishInkMutation(.remove(ids), pageID: page.id, stamp: stamp) != nil else { return }
    pencilUndoHistory.didRemoveContribution(ids, for: page.id)
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

  func commitElementState(pageID: UUID, elementID: String, state: JSONValue) {
    guard var page = pages[pageID] else { return }
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
    guard var hierarchy = boardHierarchy, workspace != nil, let presence else {
      return false
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
    guard var hierarchy = boardHierarchy, workspace != nil, let presence else {
      return false
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
    documents[documentID] = document
    sync.send(.document(document))
    receiveContent(documents: [document])
  }

  func commitDocumentState(
    documentID: UUID,
    blockID: String,
    value: JSONValue
  ) {
    guard var journal = documentStates[documentID],
      journal.commit(blockID: blockID, value: value, actor: actorID)
    else { return }
    documentStates[documentID] = journal
    sync.send(.documentState(journal))
    receiveContent(states: [journal])
  }

  @discardableResult
  func reloadExternalChanges() -> Task<Void, Never>? {
    guard loadState == .ready else { return nil }
    guard !inputGate.isActive, presencePhase != .active else { externalReloadPending = true; return nil }
    diskRefreshRequested = true
    if let diskRefreshTask { return diskRefreshTask }
    let task = Task { [weak self] in
      guard let self else { return }
      defer { diskRefreshTask = nil }
      var attempts = 2
      while diskRefreshRequested && !Task.isCancelled {
        guard !inputGate.isActive, presencePhase != .active else { externalReloadPending = true; return }
        diskRefreshRequested = false
        let local = collaborationContent
        let epoch = collaborationReadEpoch
        let incoming = incomingCollaboration
        incomingCollaboration.removeAll(keepingCapacity: true)
        let store = store
        #if os(iOS)
        let receivingDeviceID: UUID? = actorID
        #else
        let receivingDeviceID: UUID? = nil
        #endif
        let result = await Task.detached(priority: .utility) {
          Result { try NotebookDiskRefresh.prepare(store: store, local: local, incoming: incoming, receivingDeviceID: receivingDeviceID) }
        }.value
        switch result {
        case .success(let prepared):
          guard !inputGate.isActive, presencePhase != .active else { externalReloadPending = true; return }
          guard epoch == collaborationReadEpoch else { diskRefreshRequested = true; continue }
          let metadataChanged = collaborationActions != prepared.actions
            || sharedContexts != prepared.contexts.contexts || contextSelection != prepared.contexts.selection
            || deviceActionReceipts != prepared.delivery
          if prepared.contentChanged { acceptCollaborationContent(prepared.content) }
          acceptCollaborationMetadata(actions: prepared.actions, contexts: prepared.contexts, delivery: prepared.delivery)
          if prepared.contentChanged || metadataChanged { sendCollaboration(content: prepared.publication) }

        case .failure(let error):
          incomingCollaboration.insert(contentsOf: incoming, at: 0)
          guard attempts > 0 else { showCue(error.localizedDescription); return }
          attempts -= 1
          try? await Task.sleep(for: .milliseconds(60))
          diskRefreshRequested = true
        }
      }
    }
    diskRefreshTask = task
    return task
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
      // Stop optional preparation before the disk acknowledges the peer contact.
      if let previous = peerActivities[activity.deviceID], previous.sessionID == activity.sessionID,
        previous.sequence >= activity.sequence { return }
      peerActivities[activity.deviceID] = activity
      peerInputIsActive = peerActivities.values.contains { $0.deviceID != actorID && $0.isActive }
      #if os(macOS)
      if peerInputIsActive { previewPublisher?.suspendForInput() }
      #endif
      let store = store
      Task.detached(priority: .utility) { try? store.saveInputActivity(activity) }
    case .collaboration(let envelope):
      incomingCollaboration.append(envelope)
      reloadExternalChanges()
    case .index(let incoming):
      stageRemoteIndex(incoming)
    case .page(let incoming):
      guard workspaceContainsPage(incoming.id) else {
        stageRemotePage(incoming)
        return
      }
      receivePageChange(pageID: incoming.id) { page in _ = page.merge(incoming) }
    case .drawing(let pageID, let data, let stamp):
      receivePageChange(pageID: pageID) { page in _ = page.replaceDrawing(data, stamp: stamp) }
    case .elements(let pageID, let elements, let stamp, let collaboration):
      receivePageChange(pageID: pageID) { page in _ = page.mergeElements(elements, stamp: stamp, collaboration: collaboration) }
    case .document(let incoming):
      guard workspaceContainsDocument(incoming.id) else { stageRemoteDocument(incoming); return }
      receiveContent(documents: [incoming])
    case .documentState(let incoming):
      guard workspaceContainsDocument(incoming.id) else { stageRemoteDocumentState(incoming); return }
      receiveContent(states: [incoming])
    case .board(let incoming):
      guard let workspace else { return }
      if incoming.isValid(items: workspace.items) { receiveContent(hierarchy: incoming) }
      else { stageRemoteBoard(incoming); publishStagedWorkspaceIfReady() }
    case .spatialInk(let incoming):
      receiveContent(ink: incoming)
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
          schedulePresenceSave(incoming)
          if externalReloadPending { externalReloadPending = false; reloadExternalChanges() }
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

  private func receiveContent(hierarchy: BoardHierarchy? = nil, ink: SpatialInkJournal? = nil,
    documents: [DocumentDocument] = [], states: [DocumentStateJournal] = []) {
    guard let workspace, let boardHierarchy, let spatialInk else { return }
    incomingCollaboration.append(.init(content: .init(workspace: workspace, hierarchy: hierarchy ?? boardHierarchy,
      ink: ink ?? .init(stamp: .init(counter: 0, actor: spatialInk.stamp.actor)), pages: [], documents: documents, states: states)))
    reloadExternalChanges()
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
    let actor = actorID
    isPointing = false
    enqueueStoreWrite(reload: true) { store in
      _ = try store.appendContext(references: references, author: .human, actor: actor, select: true)
    }
  }

  func selectSharedContext(_ id: UUID?) {
    let actor = actorID
    enqueueStoreWrite(reload: true) { try $0.selectSharedContext(id, actor: actor) }
  }

  func results(for action: CollaborationReceipt) -> [CollaborationReference] {
    guard collaborationDetailsAreCurrent else { return [] }
    return collaborationReadSnapshot?.results[action.id] ?? []
  }

  func continuations(for action: CollaborationReceipt) -> [CollaborationContinuation] {
    guard action.undo == nil, collaborationDetailsAreCurrent else { return [] }
    return collaborationReadSnapshot?.continuations[action.id] ?? []
  }

  func referenceChanged(_ reference: CollaborationReference) -> Bool {
    let status = referenceStatus(reference).status
    return status == .changed || status == .targetMissing || status == .reviewRequired
  }

  struct CollaborationPreparationKey: Hashable {
    let epoch: UInt64
    let permitsPreparation: Bool
  }

  // Every source owner and immutable receipt/context input invalidates this
  // disposable projection on assignment. Camera frames do not. Rows compare
  // one generation instead of re-hashing content or scanning all owner stamps.
  var collaborationPreparationKey: CollaborationPreparationKey {
    .init(epoch: collaborationReadEpoch, permitsPreparation: permitsBackgroundPreparation)
  }

  var collaborationDetailsAreCurrent: Bool {
    collaborationReadSnapshot != nil && preparedCollaborationVersion == collaborationReadEpoch
  }

  func collaborationHistoryMounted(after duration: Duration) {
    #if os(iOS)
      let parts = duration.components
      inputFrameMonitor.recordHistoryMount(durationMS: Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15)
    #endif
  }

  func refreshCollaborationDetails() async {
    guard !collaborationDetailsAreCurrent else { return }
    collaborationReadGeneration += 1
    let generation = collaborationReadGeneration
    // Join the cancelled worker before starting another: a changing source
    // retains at most one preparation, never a queue of workspace snapshots.
    let previous = collaborationReadTask
    previous?.cancel()
    if let previous { _ = try? await previous.value }
    guard !Task.isCancelled, generation == collaborationReadGeneration,
      permitsBackgroundPreparation, let content = collaborationContent else { return }
    let version = collaborationReadEpoch, actions = collaborationActions
    var references = sharedContexts.flatMap { $0.entries.flatMap(\.references) }
    if let highlightedReference { references.append(highlightedReference) }
    let considered = references
    let worker = Task.detached(priority: .utility) {
      try CollaborationReadSnapshot(content: content, actions: actions, references: considered)
    }
    collaborationReadTask = worker
    let result = try? await withTaskCancellationHandler {
      try await worker.value
    } onCancel: { worker.cancel() }
    guard generation == collaborationReadGeneration else { return }
    collaborationReadTask = nil
    guard !Task.isCancelled, permitsBackgroundPreparation, version == collaborationReadEpoch, let result else { return }
    collaborationReadSnapshot = result
    preparedCollaborationVersion = version
    regionalReferenceStatuses = [:]
    await refreshReferenceStatuses()
  }

  private func referenceStatus(_ reference: CollaborationReference) -> ReferenceStatus {
    guard collaborationDetailsAreCurrent else { return .init(.checking) }
    return regionalReferenceStatuses[reference.id] ?? collaborationReadSnapshot?.references[reference.id] ?? .init(.checking)
  }

  func refreshReferenceStatuses() async {
    guard permitsBackgroundPreparation, collaborationDetailsAreCurrent, let snapshot = collaborationReadSnapshot else { return }
    let version = collaborationReadEpoch
    let references = sharedContexts.flatMap { $0.entries.flatMap(\.references) }.filter { $0.region != nil && $0.elementID == nil }
    let store = store
    let values = await Task.detached(priority: .utility) {
      references.compactMap { reference -> (UUID, ReferenceStatus)? in
        guard let revision = snapshot.references[reference.id]?.currentRevision else { return nil }
        return (reference.id, (try? store.referenceStatus(reference, currentRevision: revision)) ?? .init(.checking))
      }
    }.value
    guard !Task.isCancelled, permitsBackgroundPreparation, version == collaborationReadEpoch else { return }
    let statuses = Dictionary(values, uniquingKeysWith: { _, new in new })
    if regionalReferenceStatuses != statuses { regionalReferenceStatuses = statuses }
  }

  func referenceStatusLabel(_ reference: CollaborationReference) -> String? {
    switch referenceStatus(reference).status {
    case .checking: return reference.region != nil && reference.elementID == nil ? "Проверяется область" : "Проверяется исходник"
    case .reviewRequired: return "Нужно рассмотреть заново"
    case .targetMissing: return "Исходник удалён"
    case .changed: return "Фрагмент изменился"
    case .current: return nil
    }
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

  func confirmVisibleActions(presence visible: SessionPresence, scene: WorkspaceSceneWorkset? = nil) {
    #if os(iOS)
      guard collaborationActions.contains(where: { action in !deviceActionReceipts.contains(where: { $0.id == action.id && $0.revisions == action.revisions && $0.displayComplete }) }),
        presencePhase == .settled, presence == visible, !isPointing,
        collaborationDetailsAreCurrent, !scenePreparationPending else { return }
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
          case .board, .cover:
            ready = scene.map { sceneRepresents(reference, in: $0, presence: visible) } ?? false
          case .workspace: ready = false
          }
          guard ready else { continue }
          if !receipt.shown.contains(expected) { receipt.shown.append(expected) }
          receipt.visibleRegions.append(reference)
        }
        receipt.displayComplete = !references.isEmpty && references.allSatisfy { ref in receipt.visibleRegions.contains { $0.id == ref.id } }
        if receipt != receipts.first(where: { $0.id == action.id }) {
          changed.append(receipt)
        }
      }
      for receipt in changed {
        deviceActionReceipts.removeAll { $0.id == receipt.id }; deviceActionReceipts.append(receipt)
      }
      if !changed.isEmpty {
        let receipts = changed
        enqueueStoreWrite { store in for receipt in receipts { try store.saveDeviceActionReceipt(receipt) } }
        sync.send(.collaboration(.init(delivery: changed)))
      }
    #endif
  }

  /// A cached image proves preparation, not mounting. The completed display
  /// callback supplies the actual admitted generation; an overview region
  /// cannot acknowledge that its detailed sources were shown.
  private func sceneRepresents(_ reference: CollaborationReference,
    in scene: WorkspaceSceneWorkset, presence: SessionPresence) -> Bool {
    guard let sceneIndex, scene.generationID == sceneIndex.generationID else { return false }
    let elements: [SpatialElement]
    switch reference.target.kind {
    case .board:
      guard reference.target.id == presence.boardID else { return false }
      if let id = reference.elementID {
        guard let element = scene.elements.first(where: { $0.id == id }) else { return false }
        elements = [element]
      } else {
        guard scene.aggregates.isEmpty else { return false }
        elements = scene.elements
      }
    case .cover:
      guard reference.target.boardID == presence.boardID,
        scene.items.contains(where: { $0.id == reference.target.id }) else { return false }
      let source = sceneIndex.coverElements(itemID: reference.target.id, boardID: presence.boardID)
      if let id = reference.elementID {
        guard let element = source.first(where: { $0.id == id }) else { return false }
        elements = [element]
      } else { elements = source }
    default: return false
    }
    return elements.allSatisfy {
      $0.kind == .nativeText || SceneRenderResources.shared.image(for: agentElementSnapshotSource($0)) != nil
    }
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

  private func reloadCollaborationMetadata() { reloadExternalChanges() }

  private func acceptCollaborationMetadata(actions: [CollaborationReceipt], contexts: SharedContextSnapshot,
    delivery: [DeviceActionReceipt]) {
    if collaborationActions != actions { collaborationActions = actions }
    if sharedContexts != contexts.contexts { sharedContexts = contexts.contexts }
    contextSelection = contexts.selection
    deviceActionReceipts = delivery
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
      delivery: deviceActionReceipts)))
  }

  private func receivePageChange(pageID: UUID, mutation: @escaping @Sendable (inout PageDocument) -> Void) {
    let previous = peerPageTail
    peerPageGeneration &+= 1
    let generation = peerPageGeneration
    collaborationReadEpoch &+= 1
    peerPageTail = Task { [weak self] in
      if let previous { await previous.value }
      guard let self else { return }
      defer { if peerPageGeneration == generation { peerPageTail = nil } }
      while let page = pages[pageID], !Task.isCancelled {
        let resolved = await Task.detached(priority: .userInitiated) {
          var copy = page; mutation(&copy); return copy
        }.value
        guard pages[pageID] == page else { continue }
        if resolved != page { acceptRemotePage(resolved) }
        return
      }
    }
  }

  private func scheduleSave(_ pageID: UUID) {
    pendingPageSaves.insert(pageID)
    guard saveTasks[pageID] == nil else { return }
    saveTasks[pageID] = Task { [weak self] in
      guard let self else { return }
      defer { saveTasks[pageID] = nil }
      while pendingPageSaves.remove(pageID) != nil, let page = pages[pageID], !Task.isCancelled {
        let store = store
        let result = await Task.detached(priority: .utility) {
          Result { try store.saveMergedPage(page) != page }
        }.value
        switch result {
        case .success(let changed): if changed { reloadExternalChanges() }
        case .failure(let error): showCue(error.localizedDescription)
        }
      }
    }
  }

  private func scheduleSpatialInkSave() {
    spatialInkSavePending = true
    guard spatialInkSaveTask == nil else { return }
    spatialInkSaveTask = Task { [weak self] in
      guard let self else { return }
      defer { spatialInkSaveTask = nil }
      while spatialInkSavePending, let journal = spatialInk, !Task.isCancelled {
        spatialInkSavePending = false
        let store = store
        let result = await Task.detached(priority: .utility) {
          Result { try store.saveMergedSpatialInk(journal) != journal }
        }.value
        switch result {
        case .success(let changed): if changed { reloadExternalChanges() }
        case .failure(let error): showCue(error.localizedDescription)
        }
      }
    }
  }

  private func scheduleWorkspaceSelectionSave(
    _ workspace: WorkspaceIndex,
    createdPage: PageDocument?
  ) {
    enqueueStoreWrite(reload: false) { store in
      _ = try store.saveWorkspaceSelection(
        index: workspace,
        createdPage: createdPage
      )
    }
  }

  private func schedulePresenceSave(_ presence: SessionPresence) {
    pendingPresenceToSave = presence
    guard presenceSaveTail == nil else { return }
    presenceSaveTail = Task { [weak self] in
      guard let self else { return }
      while let next = pendingPresenceToSave {
        pendingPresenceToSave = nil
        let store = store
        await Task.detached(priority: .utility) { try? store.savePresence(next) }.value
      }
      presenceSaveTail = nil
    }
  }

  private func persistBoard(_ board: BoardHierarchy) {
    boardHierarchy = board
    sync.send(.board(board))
    boardSavePending = true
    guard boardSaveTask == nil else { return }
    boardSaveTask = Task { [weak self] in
      guard let self else { return }
      defer { boardSaveTask = nil }
      while boardSavePending, let board = boardHierarchy, let workspace {
        boardSavePending = false
        let store = store
        let result = await Task.detached(priority: .utility) {
          Result { try store.saveMergedBoard(board, items: workspace.items) != board }
        }.value
        switch result {
        case .success(let changed): if changed { reloadExternalChanges() }
        case .failure(let error): showCue(error.localizedDescription)
        }
      }
    }
  }

  @discardableResult
  private func persistMerged(_ page: PageDocument) -> PageDocument {
    pages[page.id] = page
    scheduleSave(page.id)
    return page
  }

  private func enqueueStoreWrite(reload: Bool = false, _ operation: @escaping @Sendable (NotebookStore) throws -> Void) {
    pendingStoreWrites.append((reload, operation))
    guard storeWriteTask == nil else { return }
    storeWriteTask = Task { [weak self] in
      guard let self else { return }
      defer { storeWriteTask = nil }
      while !pendingStoreWrites.isEmpty {
        let next = pendingStoreWrites.removeFirst(), store = store
        let result = await Task.detached(priority: .utility) { Result { try next.operation(store) } }.value
        if case .failure(let error) = result { showCue(error.localizedDescription) }
        if next.reload { await reloadExternalChanges()?.value }
      }
    }
  }

  func finishPendingInteraction() async {
    await withCheckedContinuation { continuation in
      inputGate.performAfterPageInput { continuation.resume() }
    }
    if presencePhase == .active, let presence { updatePresence(presence, settled: true) }
    await finishPendingPersistence()
  }

  /// Tests and shutdown coordination wait for persistence explicitly; gestures
  /// only publish memory and never await this barrier.
  func finishPendingPersistence() async {
    while storeWriteTask != nil || peerPageTail != nil || diskRefreshTask != nil || !saveTasks.isEmpty || spatialInkSaveTask != nil
      || presenceSaveTail != nil || boardSaveTask != nil || inputWriteTask != nil {
      if let task = storeWriteTask { await task.value }
      if let task = peerPageTail { await task.value }
      if let task = diskRefreshTask { await task.value }
      for task in Array(saveTasks.values) { await task.value }
      if let task = spatialInkSaveTask { await task.value }
      if let task = presenceSaveTail { await task.value }
      if let task = boardSaveTask { await task.value }
      if let task = inputWriteTask { await task.value }
    }
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
    schedulePresenceSave(resolved)
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

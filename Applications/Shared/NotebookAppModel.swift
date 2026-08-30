import Foundation
import Observation
import NotebookCore

typealias PageInputCompletion = @MainActor @Sendable () -> Void
typealias PageInputFinisher = (@escaping PageInputCompletion) -> Void

@MainActor
final class PageInputGate {
  private var finisher: PageInputFinisher?

  func register(_ finisher: @escaping PageInputFinisher) {
    self.finisher = finisher
  }

  func perform(_ action: @escaping PageInputCompletion) {
    if let finisher {
      finisher(action)
    } else {
      action()
    }
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
  private(set) var board: BoardDocument?
  private(set) var spatialInk: SpatialInkJournal?
  private(set) var presence: SessionPresence?
  private(set) var presencePhase = PresencePhase.settled
  private(set) var actionCue: String?
  private(set) var penStyle: PenStyle
  private(set) var eraserStyle: EraserStyle
  private(set) var drawingTool: DrawingTool = .pen
  private(set) var isTextToolSelected = false
  private(set) var pendingTitleFocusID: UUID?

  let store: NotebookStore
  let actorID: UUID
  let pageInputGate = PageInputGate()

  private var pageSize = defaultPageSize
  private var started = false
  private var saveTasks: [UUID: Task<Void, Never>] = [:]
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
      self?.receive(message)
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

  var activeNotebook: Notebook? {
    workspace?.selectedNotebook
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
    showCue("Страница \(workspace.selectedPageIndex + 1)")
  }

  @discardableResult
  func createNotebook(at center: WorldPoint) -> UUID? {
    guard var workspace, var board else { return nil }
    let number = workspace.notebooks.count + 1
    guard let created = workspace.createNotebook(
      title: "Notebook \(number)",
      actor: actorID,
      pageSize: pageSize
    ), board.addNotebook(created.notebook.id, near: center, actor: actorID)
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
    pendingTitleFocusID = created.notebook.id
    sync.send(.page(created.page))
    sync.send(.board(board))
    sync.send(.index(workspace))
    showCue("Новая тетрадь")
    return created.notebook.id
  }

  func consumePendingTitleFocus(_ notebookID: UUID) {
    guard pendingTitleFocusID == notebookID else { return }
    pendingTitleFocusID = nil
  }

  func renameNotebook(_ notebookID: UUID, title: String) {
    guard var workspace,
      workspace.renameNotebook(notebookID, title: title, actor: actorID)
    else { return }
    self.workspace = workspace
    try? store.saveIndex(workspace)
    sync.send(.index(workspace))
  }

  func selectNotebook(_ notebookID: UUID) {
    guard var workspace,
      workspace.selectNotebook(notebookID, actor: actorID)
    else { return }
    self.workspace = workspace
    try? store.saveIndex(workspace)
    sync.send(.index(workspace))
  }

  func moveNotebook(_ notebookID: UUID, to center: WorldPoint) {
    guard var board,
      board.moveNotebook(notebookID, to: center, actor: actorID),
      let workspace
    else { return }
    self.board = board
    let notebookIDs = Set(workspace.notebooks.map(\.id))
    try? store.saveBoard(board, notebookIDs: notebookIDs)
    sync.send(.board(board))
  }

  @discardableResult
  func stackNotebook(_ movingID: UUID, onto targetID: UUID) -> UUID? {
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
      notebookIDs: Set(workspace.notebooks.map(\.id))
    )
    sync.send(.board(board))
    showCue("Стопка")
    return stackID
  }

  func unstackNotebook(_ notebookID: UUID, at center: WorldPoint) {
    guard var board,
      board.unstackNotebook(notebookID, at: center, actor: actorID),
      let workspace
    else { return }
    self.board = board
    try? store.saveBoard(
      board,
      notebookIDs: Set(workspace.notebooks.map(\.id))
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
    if isPageOpen {
      undoLastDrawingAction()
      return
    }
    guard var journal = spatialInk else { return }
    let surface: SurfaceID? = presence?.focusedNotebookID.map(SurfaceID.cover)
    guard journal.undoLast(actor: actorID, touching: surface) != nil
      || (surface != nil && journal.undoLast(actor: actorID) != nil)
    else { return }
    spatialInk = journal
    sync.send(.spatialInk(journal))
    scheduleSpatialInkSave()
    showCue("Отменено")
  }

  func afterPageInput(_ action: @escaping PageInputCompletion) {
    pageInputGate.perform(action)
  }

  func addNativeText(on notebookID: UUID, at point: SpatialPoint) -> String? {
    guard var board else { return nil }
    let id = "text-\(UUID().uuidString.lowercased())"
    let element = SpatialElement(
      id: id,
      surface: .cover(notebookID),
      kind: .nativeText,
      frame: SpatialRect(
        x: point.x,
        y: point.y,
        width: 420,
        height: 120
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
      let index = board.elements.firstIndex(where: { $0.id == elementID })
    else { return }
    var element = board.elements[index]
    let expected = element.stamp
    guard element.update(source: text, actor: actorID),
      board.upsertElement(element, expected: expected, actor: actorID)
    else { return }
    persistBoard(board)
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
    isTextToolSelected = false
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
    isTextToolSelected = false
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
    isTextToolSelected = false
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
    isTextToolSelected = false
    drawingTool = .eraser
    let next = EraserStyle(maximumWidth: maximumWidth)
    guard next != eraserStyle else { return }
    eraserStyle = next
    saveEraserStyle()
  }

  func selectDrawingTool(_ tool: DrawingTool) {
    isTextToolSelected = false
    drawingTool = tool
  }

  func selectTextTool() {
    isTextToolSelected = true
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

  func reloadExternalChanges() {
    guard loadState == .ready else { return }
    do {
      let diskIndex = try store.loadIndex()
      if workspace?.merge(diskIndex) == true {
        workspace = diskIndex
        sync.send(.index(diskIndex))
      }
      let notebookIDs = Set(diskIndex.notebooks.map(\.id))
      let diskBoard = try store.loadBoard(notebookIDs: notebookIDs)
      if var currentBoard = board {
        if currentBoard.merge(diskBoard, notebookIDs: notebookIDs) {
          board = currentBoard
          sync.send(.board(currentBoard))
        }
      } else {
        board = diskBoard
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
      for notebook in diskIndex.notebooks {
        for pageID in notebook.pageIDs {
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
    } catch {
      // An atomic writer may be between rename notifications. The next event retries.
    }
  }

  private func receive(_ message: WireMessage) {
    switch message {
    case .index(let incoming):
      if workspace?.merge(incoming) == true {
        workspace = incoming
        try? store.saveIndex(incoming)
      }
    case .page(let incoming):
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
    case .board(let incoming):
      guard let workspace else { return }
      let notebookIDs = Set(workspace.notebooks.map(\.id))
      if var current = board {
        guard current.merge(incoming, notebookIDs: notebookIDs) else { return }
        board = (try? store.saveMergedBoard(
          current,
          notebookIDs: notebookIDs
        )) ?? current
      } else {
        guard incoming.isValid(notebookIDs: notebookIDs) else { return }
        board = incoming
        try? store.saveBoard(incoming, notebookIDs: notebookIDs)
      }
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
    sync.send(.index(workspace))
    if let board { sync.send(.board(board)) }
    #if os(iOS)
      if let lastSettledPresenceEnvelope {
        sync.send(.presence(lastSettledPresenceEnvelope))
      }
    #endif
    let selectedPageID = workspace.selectedPageID
    if let selectedPage = pages[selectedPageID] {
      sync.send(.page(selectedPage))
    }
    if let spatialInk { sync.send(.spatialInk(spatialInk)) }
    for page in pages.values where page.id != selectedPageID {
      sync.send(.page(page))
    }
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
    let notebookIDs = Set(workspace.notebooks.map(\.id))
    let resolved = (try? store.saveMergedBoard(
      board,
      notebookIDs: notebookIDs
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
    let notebookID = workspace.selectedNotebookID
    let center = board?.placement(of: notebookID)?.center
      ?? board?.stack(containing: notebookID)?.center
      ?? .zero
    let viewportPoint = SpatialPoint(x: viewport.width, y: viewport.height)
    let fit = NotebookPresentation.fitScale(
      viewport: viewportPoint
    )
    return SessionPresence(
      mode: .page,
      camera: SpatialCamera(center: center, scale: fit),
      viewport: viewportPoint,
      focusedNotebookID: notebookID,
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
    let notebookID = presence.focusedNotebookID
    let notebookCenter = notebookID.flatMap { id in
      board?.placement(of: id)?.center
        ?? board?.stack(containing: id)?.center
    }

    if presence.mode == .page,
      let notebookID,
      let notebookCenter,
      workspace.notebooks.contains(where: { $0.id == notebookID })
    {
      return SessionPresence(
        mode: .page,
        camera: SpatialCamera(
          center: notebookCenter,
          scale: NotebookPresentation.fitScale(viewport: viewport)
        ),
        viewport: viewport,
        focusedNotebookID: notebookID,
        openProgress: 1
      )
    }

    if presence.mode == .cover,
      let notebookID,
      let notebookCenter,
      workspace.notebooks.contains(where: { $0.id == notebookID })
    {
      return SessionPresence(
        mode: .cover,
        camera: SpatialCamera(
          center: notebookCenter,
          scale: NotebookPresentation.coverScale(viewport: viewport)
        ),
        viewport: viewport,
        focusedNotebookID: notebookID,
        openProgress: 0
      )
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
    if let notebookID = presence.focusedNotebookID,
      !workspace.notebooks.contains(where: { $0.id == notebookID })
    {
      return false
    }
    if presence.mode != .board,
      presence.focusedNotebookID != workspace.selectedNotebookID
    { return false }
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

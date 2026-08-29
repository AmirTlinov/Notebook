import Foundation
import Observation
import TetradCore

@MainActor
@Observable
final class TetradAppModel {
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
  private(set) var isConnected = false
  private(set) var actionCue: String?
  private(set) var penStyle: PenStyle

  let store: TetradStore
  let actorID: UUID

  private var pageSize = defaultPageSize
  private var started = false
  private var saveTasks: [UUID: Task<Void, Never>] = [:]
  private var cueTask: Task<Void, Never>?
  private var pencilUndoHistory = PencilUndoHistory()
  private let sync: NearbySync

  init(store: TetradStore = TetradStore(root: TetradStore.defaultRoot)) {
    self.store = store
    penStyle = Self.loadPenStyle()
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
    sync.onConnectionChange = { [weak self] connected in
      guard let self else { return }
      isConnected = connected
      if connected { sendSnapshot() }
    }
  }

  var activePage: PageDocument? {
    guard let pageID = workspace?.selectedPageID else { return nil }
    return pages[pageID]
  }

  var activeNotebook: Notebook? {
    workspace?.selectedNotebook
  }

  var pageNumber: Int {
    (workspace?.selectedPageIndex ?? 0) + 1
  }

  var pageCount: Int {
    workspace?.selectedNotebook.pageIDs.count ?? 0
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
      loadState = .ready
      sync.start()
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

  func changeNotebook(_ direction: Int) {
    guard var workspace else { return }
    let created = workspace.changeNotebook(
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
    showCue(workspace.selectedNotebook.title)
  }

  func replaceDrawing(_ data: Data, settled: Bool) {
    guard var page = activePage else { return }
    pencilUndoHistory.observeChange(
      pageID: page.id,
      before: page.drawingData,
      after: data,
      settled: settled
    )
    let previous = page.drawingStamp
    page.replaceDrawing(data, actor: actorID)
    if previous != page.drawingStamp {
      pages[page.id] = page
      sync.send(
        .drawing(
          pageID: page.id,
          data: page.drawingData,
          stamp: page.drawingStamp
        )
      )
    }
    if settled {
      saveTasks[page.id]?.cancel()
      saveTasks[page.id] = nil
      if let current = pages[page.id] {
        persistMerged(current)
      }
    } else if previous != page.drawingStamp {
      scheduleSave(page.id)
    }
  }

  func undoLastDrawingAction() {
    guard var page = activePage,
          let previousDrawing = pencilUndoHistory.removeLastChange(for: page.id)
    else { return }
    page.replaceDrawing(previousDrawing, actor: actorID)
    pages[page.id] = page
    saveTasks[page.id]?.cancel()
    saveTasks[page.id] = nil
    page = persistMerged(page)
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
    guard color != penStyle.color else { return }
    penStyle = PenStyle(color: color, width: penStyle.width)
    savePenStyle()
  }

  func selectPenWidth(_ width: Double) {
    let next = PenStyle(color: penStyle.color, width: width)
    guard next != penStyle else { return }
    penStyle = next
    savePenStyle()
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
      for notebook in diskIndex.notebooks {
        for pageID in notebook.pageIDs {
          let diskPage = try store.loadPage(pageID)
          if var current = pages[pageID] {
            let oldDrawing = current.drawingStamp
            let oldAgent = current.agentStamp
            guard current.merge(diskPage) else { continue }
            pages[pageID] = current
            if oldDrawing < current.drawingStamp {
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
    case .requestSnapshot:
      sendSnapshot()
    case .index(let incoming):
      if workspace?.merge(incoming) == true {
        workspace = incoming
        try? store.saveIndex(incoming)
      }
    case .page(let incoming):
      if var current = pages[incoming.id] {
        guard current.merge(incoming) else { return }
        persistMerged(current)
      } else {
        persistMerged(incoming)
      }
    case .drawing(let pageID, let data, let stamp):
      guard var page = pages[pageID], page.drawingStamp < stamp else { return }
      page.drawingData = data
      page.drawingStamp = stamp
      persistMerged(page)
    case .elements(let pageID, let elements, let stamp):
      guard var page = pages[pageID], page.agentStamp < stamp else { return }
      page.elements = elements
      page.agentStamp = stamp
      persistMerged(page)
    }
  }

  private func sendSnapshot() {
    guard let workspace else { return }
    sync.send(.index(workspace))
    for page in pages.values {
      sync.send(.page(page))
    }
  }

  private func scheduleSave(_ pageID: UUID) {
    saveTasks[pageID]?.cancel()
    saveTasks[pageID] = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(180))
      guard !Task.isCancelled, let self, let page = pages[pageID] else { return }
      persistMerged(page)
      saveTasks[pageID] = nil
    }
  }

  @discardableResult
  private func persistMerged(_ page: PageDocument) -> PageDocument {
    let resolved = (try? store.saveMergedPage(page)) ?? page
    pages[page.id] = resolved
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

  private static func loadActorID() -> UUID {
    let key = "tetrad.actor-id"
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
    let color = defaults.string(forKey: "tetrad.pen-color")
      .flatMap(PenColor.init(rawValue:)) ?? PenStyle.standard.color
    let width = defaults.object(forKey: "tetrad.pen-width") as? Double
      ?? PenStyle.standard.width
    return PenStyle(color: color, width: width)
  }

  private func savePenStyle() {
    UserDefaults.standard.set(penStyle.color.rawValue, forKey: "tetrad.pen-color")
    UserDefaults.standard.set(penStyle.width, forKey: "tetrad.pen-width")
  }
}

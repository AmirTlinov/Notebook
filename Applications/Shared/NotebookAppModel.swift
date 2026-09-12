import Foundation
import CoreGraphics
import Observation
import NotebookCore
#if os(macOS)
import NotebookCodex
#endif

/// A retained native host must relinquish its last presentation when the same
/// model that admitted its input acknowledges terminal shutdown.
@MainActor
protocol NotebookScenePresentationOwner: AnyObject {
  func uninstall()
}

@MainActor
@Observable
final class NotebookAppModel {
  enum LoadState: Equatable {
    case loading
    case ready
    case failed(String)
  }

  enum ShutdownPhase: Equatable {
    case running
    /// External admission is closed; an unsuccessful save may still be repaired.
    case closing
    /// Accepted input is saved, but derived owners and the final write drain remain.
    case draining
    /// Every drain succeeded. No mounted presentation may retain this scene.
    case stopped
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
  /// A prepared slot belongs to one immutable order. This finite view cache
  /// is not the notebook's membership list; SQLite/vector remain its owner.
  private struct PageAddress: Hashable { let itemID: UUID; let index: Int; let root: String }
  @ObservationIgnored private var pageAddresses: [PageAddress: UUID] = [:]
  @ObservationIgnored private var pagePreparationTasks: [PageAddress: Task<Void, Never>] = [:]

  func notebookPageCount(_ itemID: UUID) -> Int {
    workspace?.notebookPageOrder(in: itemID)?.count ?? 0
  }

  func notebookPageRoot(_ itemID: UUID) -> String? {
    workspace?.notebookPageOrder(in: itemID)?.root
  }

  func notebookPageIndex(_ pageID: UUID, in itemID: UUID) -> Int? {
    guard let root = notebookPageRoot(itemID) else { return nil }
    return pageAddresses.first { $0.key.itemID == itemID && $0.key.root == root && $0.value == pageID }?.key.index
  }

  func notebookPageOwner(_ pageID: UUID) -> UUID? {
    pageAddresses.first { $0.value == pageID && notebookPageRoot($0.key.itemID) == $0.key.root }?.key.itemID
  }

  func notebookPage(at index: Int, in itemID: UUID) -> PageDocument? {
    guard let root = notebookPageRoot(itemID), let id = pageAddresses[.init(itemID: itemID, index: index, root: root)] else { return nil }
    return pages[id]
  }

  /// An unloaded existing sheet never certifies a blank page. The requested
  /// immutable slot must still exist before its bytes can become UIKit content.
  func prepareNotebookPage(at index: Int, in itemID: UUID) async {
    guard !isStopped, index >= 0, index < notebookPageCount(itemID), !isItemBeingDeleted(itemID),
      let root = notebookPageRoot(itemID) else { return }
    let address = PageAddress(itemID: itemID, index: index, root: root)
    if notebookPage(at: index, in: itemID) != nil { return }
    if let pending = pagePreparationTasks[address] { await pending.value; return }
    let task = Task { [weak self] in
      guard let self else { return }
      defer { pagePreparationTasks[address] = nil }
      while !Task.isCancelled, let workspace, let presence, !isItemBeingDeleted(itemID), notebookPageRoot(itemID) == root {
        let epoch = collaborationReadEpoch
        do {
          let prepared = try await persistence.submit { store -> (NotebookPageWindow, WorkspaceIndex) in
            try store.readTransaction { _ in
              let window = try store.readNotebookPageWindow(itemID: itemID, pages: [.index(index)], expectedVisibleRoot: root)
              let id = window.pages[0].document.id
              let items = workspace.items.map { item in
                guard item.id == itemID else { return item }
                return .notebook(id: item.id, title: item.title,
                  pageIDs: item.pageIDs.contains(id) ? item.pageIDs : item.pageIDs + [id])
              }
              let projection = try store.workspaceProjection(items: items, selectedItemID: workspace.selectedItemID,
                selectedPageID: workspace.selectedPageID)
              return (window, projection)
            }
          }
          guard epoch == collaborationReadEpoch else { continue }
          guard !Task.isCancelled, !isItemBeingDeleted(itemID), notebookPageRoot(itemID) == root else { return }
          self.workspace = prepared.1
          let page = prepared.0.pages[0].document
          pageAddresses[address] = page.id
          pages[page.id] = page
          retainPreparedPages(near: address, selectedPageID: presence.notebookPageID)
          return
        } catch NotebookStorageError.transactionConflict {
          reloadExternalChanges()
          return
        } catch {
          publicationFailure = error.localizedDescription
          persistenceFailure = error.localizedDescription
          return
        }
      }
    }
    pagePreparationTasks[address] = task
    await task.value
  }

  /// A numbered command is leased to the order seen at the button press.
  /// It can wait for content/input, but it cannot adopt a new slot occupant.
  func navigateToNotebookPage(at index: Int, in itemID: UUID, expectedRoot: String) async {
    guard await finishPendingInteraction(), notebookPageRoot(itemID) == expectedRoot else { return }
    await prepareNotebookPage(at: index, in: itemID)
    afterPageInput { [weak self] in
      guard let self else { return }
      _ = selectNotebookPage(index, notebookID: itemID, expectedRoot: expectedRoot)
    }
  }

  /// A reference is a UUID intent, not an old page number. Resolve it and the
  /// physical notebook into one bounded scene, then publish only if no new
  /// input, selection, or cancellation overtook that read.
  func navigateToNotebookPage(id pageID: UUID, isCurrent: @MainActor () -> Bool) async -> Bool {
    while !Task.isCancelled, !isStopped, isCurrent() {
      guard await finishPendingInteraction(), let presence, isCurrent() else { return false }
      let epoch = collaborationReadEpoch, generation = inputGate.pencilGeneration
      do {
        let state = try await persistence.submit { store in
          try store.readTransaction { _ in
            guard let itemID = try store.ownerItemID(ofPage: pageID),
              try store.resolveNotebookPage(pageID, in: itemID) != nil,
              let boardID = try store.ownerBoardID(of: itemID) else { throw NotebookStorageError.transactionConflict }
            let selection = SessionPresence(boardID: boardID, mode: .page, camera: presence.camera,
              viewport: presence.viewport, focusedItemID: itemID, openProgress: 1,
              selectedItemID: itemID, notebookPageID: pageID)
            return try NotebookSceneState.read(store: store, presence: selection, viewport: presence.viewport)
          }
        }
        guard !Task.isCancelled, isCurrent() else { return false }
        guard epoch == collaborationReadEpoch, generation == inputGate.pencilGeneration, !inputGate.hasActivePencil else { continue }
        guard let itemID = state.presence.selectedItemID, !isItemBeingDeleted(itemID), state.presence.notebookPageID == pageID else { return false }
        acceptSceneState(state)
        // The caller owns its camera animation. Selection changes now, not the
        // old camera, and the same actor segment returns its prepared target.
        self.presence = presence.selecting(itemID: itemID, pageID: pageID)
        scheduleWorkspaceSelectionSave(state.workspace, createdPage: nil)
        return true
      } catch {
        showCue("Лист недоступен: \(error.localizedDescription)")
        return false
      }
    }
    return false
  }

  private func retainPreparedPages(near address: PageAddress, selectedPageID: UUID?) {
    let ordered = pages.keys.sorted { lhs, rhs in
      @MainActor func score(_ id: UUID) -> Int {
        if id == selectedPageID { return 0 }
        if id == pageAddresses[address] { return 1 }
        guard let location = pageAddresses.first(where: { $0.value == id && $0.key.root == address.root })?.key,
          location.itemID == address.itemID else { return 1_000 }
        return 2 + abs(location.index - address.index)
      }
      return score(lhs) == score(rhs) ? lhs.uuidString < rhs.uuidString : score(lhs) < score(rhs)
    }
    let retained = Set(ordered.prefix(4))
    pages = pages.filter { retained.contains($0.key) }
    pageAddresses = pageAddresses.filter { retained.contains($0.value) && notebookPageRoot($0.key.itemID) == $0.key.root }
    if var workspace {
      do { try workspace.retainPageProjection(retained); self.workspace = workspace }
      catch { publicationFailure = error.localizedDescription }
    }
  }

  private(set) var documents: [UUID: DocumentDocument] = [:] { didSet { collaborationReadEpoch &+= 1; scheduleScenePreparation() } }
  private(set) var documentEditingSessions: [DocumentEditingSession] = []
  @ObservationIgnored private var documentDraftEpoch: UInt64 = 0
  private(set) var documentStates: [UUID: DocumentStateJournal] = [:] { didSet { collaborationReadEpoch &+= 1 } }
  private(set) var boardHierarchy: BoardHierarchy? { didSet { collaborationReadEpoch &+= 1; scheduleScenePreparation() } }
  private(set) var spatialInk: SpatialInkJournal? { didSet { collaborationReadEpoch &+= 1 } }
  private(set) var loadedInkSurfaces: Set<SurfaceID> = []
  func renderingInk(on surface: SurfaceID, fallback: SpatialInkJournal?) -> SpatialInkJournal? {
    loadedInkSurfaces.contains(surface) ? spatialInk : fallback
  }
  let compositionTiles: SceneCompositionTiles
  private(set) var sceneIndex: WorkspaceSceneIndex?
  private(set) var workspaceHeader: NotebookWorkspaceHeader?
  private(set) var documentPaperSizes: [UUID: DocumentPaperSize] = [:]
  private(set) var sceneCoverage: [UUID: WorkspaceSpatialBounds] = [:]
  private(set) var truncatedSceneBoards: Set<UUID> = []
  private(set) var scenePreparationPending = false
  private(set) var sceneIndexGeneration: UInt64 = 0
  private(set) var scenePublicationGeneration: UInt64 = 0
  @ObservationIgnored private var scenePreparationTask: Task<Void, Never>?
  @ObservationIgnored private var scenePreparationRequest: UInt64 = 0
  @ObservationIgnored private var scenePreparationIsCoverageOnly = false
  @ObservationIgnored private var sceneWindowTask: Task<Void, Never>?
  @ObservationIgnored private var requestedScenePresence: SessionPresence?
  @ObservationIgnored private var scenePinnedElements: [UUID: [String]] = [:]
  @ObservationIgnored private var scenePinnedItems: [UUID: [UUID]] = [:]
  @ObservationIgnored private var preparedScene: (index: WorkspaceSceneIndex?, changed: Bool, portals: [UUID: BoardPortalCamera], request: UInt64, coverageOnly: Bool)?
  private var scenePortalCameras: [UUID: BoardPortalCamera] = [:]
  @ObservationIgnored private(set) var sceneQueryCount: UInt64 = 0

  /// Coalesce a completed content publication before deriving the spatial
  /// read model. The old generation remains visible until the next is whole.
  private func scheduleScenePreparation(coverageOnly: Bool = false) {
    guard !isStopped else { return }
    scenePreparationIsCoverageOnly = coverageOnly
    scenePreparationRequest &+= 1
    scenePreparationPending = true
    preparedScene = nil
    guard scenePreparationTask == nil else { return }
    scenePreparationTask = Task { [weak self] in
      await Task.yield()
      guard let self else { return }
      while !Task.isCancelled, let workspace, let boardHierarchy {
        let request = scenePreparationRequest
        let coverageOnly = scenePreparationIsCoverageOnly
        let paperSizes = documentPaperSizes.merging(documents.mapValues(\.paperSize)) { _, live in live }
        let previous = sceneIndex
        let result = await Task.detached(priority: .utility) {
          let portals = Dictionary(uniqueKeysWithValues: boardHierarchy.boards.map { ($0.id, $0.portalCamera) })
          let changed = previous?.represents(workspace: workspace, hierarchy: boardHierarchy, paperSizes: paperSizes) != true
          let index = changed ? WorkspaceSceneIndex(workspace: workspace, hierarchy: boardHierarchy, paperSizes: paperSizes) : previous
          return (index, changed, portals)
        }.value
        // At most one builder exists. Obsolete work cannot publish or enqueue
        // a second expensive build in parallel with the latest publication.
        guard request == scenePreparationRequest else { continue }
        preparedScene = (result.0, result.1, result.2, request, coverageOnly)
        scenePreparationTask = nil
        publishPreparedSceneIfPossible()
        return
      }
      scenePreparationTask = nil
    }
  }

  private func publishPreparedSceneIfPossible() {
    guard let prepared = preparedScene, prepared.request == scenePreparationRequest,
      !prepared.changed || (!peerInputIsActive && (!inputIsActive || (prepared.coverageOnly && !inputGate.hasActivePencil))) else { return }
    scenePortalCameras = prepared.portals
    if prepared.changed { sceneIndex = prepared.index; sceneIndexGeneration &+= 1 }
    preparedScene = nil
    scenePreparationPending = false
    scenePublicationGeneration &+= 1
  }

  /// Pages are read from their current catalog owner, independently of the
  /// background geometry generation and any preceding membership changes.
  func itemForDisplay(id: UUID) -> WorkspaceItem? {
    isItemBeingDeleted(id) ? nil : workspace?.item(id: id)
  }

  func scenePortalCamera(boardID: UUID) -> BoardPortalCamera? { scenePortalCameras[boardID] }

  func sceneWorkset(presence: SessionPresence, pinned: Set<WorkspaceSpatialID> = [],
    limit: Int = WorkspaceSceneIndex.detailLimit, pixelScale: Double? = nil) -> WorkspaceSceneWorkset {
    sceneQueryCount &+= 1
    if sceneCoverage[presence.boardID]?.contains(NotebookSceneState.bounds(for: presence, margin: 64)) != true {
      requestSceneCoverage(presence)
    }
    return sceneIndex?.workset(presence: presence, pinned: pinned, limit: limit, pixelScale: pixelScale) ?? .empty
  }

  /// Called by the view's task, never by its body or a UIKit update callback.
  /// The camera can replace one pending coverage request without growing a queue.
  func prepareComposition(presence: SessionPresence, frame: WorkspaceSceneFrame?,
    pinned: Set<WorkspaceSpatialID>, displayScale: Double, installedItemOwners: [UUID: UUID] = [:]) {
    let elements = pinned.compactMap { id -> String? in
      if case .element(let value) = id { return value }; return nil
    }.sorted()
    let missingPin = elements.contains { sceneIndex?.element(id: $0, boardID: presence.boardID) == nil }
    scenePinnedElements = elements.isEmpty ? [:] : [presence.boardID: elements]
    let itemIDs = pinned.compactMap { pin -> UUID? in if case .item(let id) = pin { return id }; return nil }
    guard itemIDs.count <= 7, Set(installedItemOwners.keys).isSubset(of: Set(itemIDs)) else {
      publicationFailure = "Слишком много одновременно удерживаемых предметов"
      compositionTiles.cancelPreparation(); return
    }
    var itemPins: [UUID: [UUID]] = [:]
    for id in itemIDs.sorted() {
      let owner = installedItemOwners[id] ?? frame?.index.ownerBoard(itemID: id) ?? presence.boardID
      itemPins[owner, default: []].append(id)
    }
    scenePinnedItems = itemPins
    let missingItemPin = itemIDs.contains { sceneIndex?.item(id: $0) == nil }
    if missingPin || missingItemPin || sceneCoverage[presence.boardID]?.contains(NotebookSceneState.bounds(for: presence, margin: 64)) != true {
      requestSceneCoverage(presence)
    }
    // An addressed pin is still being fetched. Do not turn the previous
    // partial index into a failed complete source for this new request.
    if missingPin || missingItemPin { compositionTiles.cancelPreparation(); return }
    guard permitsBackgroundPreparation, !scenePreparationPending else { compositionTiles.cancelPreparation(); return }
    guard let header = workspaceHeader, let frame else { return }
    let source = SceneCompositionSource(store: store, revision: header.cursor, workspaceID: header.workspaceID)
    compositionTiles.prepare(source: source, presence: presence, frame: frame, pinned: pinned,
      displayScale: displayScale, permitsPreparation: { [weak self] in self?.permitsBackgroundPreparation == true })
  }

  private func clearRemovedElementPins(_ ids: Set<String>) {
    guard !ids.isEmpty else { return }
    scenePinnedElements = scenePinnedElements.mapValues { $0.filter { !ids.contains($0) } }
    if case .spatial(let id) = elementEditingSession.selection, ids.contains(id) {
      elementEditingSession = .init()
    }
    if case .board(_, let id) = interactiveElementFocus, ids.contains(id) { interactiveElementFocus = nil }
  }

  /// Derived publication also uses the process's one ordered writer. Reads can
  /// use separate WAL snapshots; a background renderer cannot open a write path.
  func performStoreCommand<T: Sendable>(publishesChanges: Bool = false,
    _ operation: @escaping @Sendable (NotebookStore) throws -> T) async throws -> T {
    guard !isClosing else { throw CollaborationError("owner_unavailable", "Notebook завершает работу.") }
    return try await persistence.submit(publishesChanges: publishesChanges, operation)
  }

  /// Camera queries replace one pending address, never enqueue an archive
  /// read per frame. An old content revision cannot replace a newer scene.
  private func requestSceneCoverage(_ view: SessionPresence) {
    guard loadState == .ready, !isStopped else { return }
    requestedScenePresence = view
    guard sceneWindowTask == nil else { return }
    sceneWindowTask = Task { [weak self] in
      await Task.yield()
      guard let self else { return }
      defer { sceneWindowTask = nil }
      while let requested = requestedScenePresence, !Task.isCancelled {
        requestedScenePresence = nil
        let epoch = collaborationReadEpoch
        let pins = scenePinnedElements, itemPins = scenePinnedItems
        let preparedIDs = preparedNotebookPageIDs(in: requested.selectedItemID)
        do {
          let state = try await persistence.submit { store in
            try NotebookSceneState.read(store: store, presence: requested,
              viewport: requested.viewport, loadsLiveContent: false, pinnedElements: pins, pinnedItems: itemPins, preparedPages: preparedIDs)
          }
          guard epoch == collaborationReadEpoch, state.header.cursor == workspaceHeader?.cursor else {
            externalReloadPending = true
            if presencePhase == .settled, !inputIsActive { reloadExternalChanges() }
            return
          }
          guard !inputGate.hasActivePencil else { externalReloadPending = true; return }
          guard itemPins == scenePinnedItems else { requestedScenePresence = self.presence; continue }
          guard self.presence?.boardID == requested.boardID,
            self.presence?.selectedItemID == requested.selectedItemID else { continue }
          acceptItemOwnerInvalidations(state, requested: itemPins)
          workspace = state.workspace
          let retained = Set(state.pagePositions.map(\.pageID))
          pages = pages.filter { retained.contains($0.key) }
          pageAddresses = Dictionary(uniqueKeysWithValues: state.pagePositions.map {
            (PageAddress(itemID: $0.itemID, index: $0.index, root: $0.visibleRoot), $0.pageID)
          })
          boardHierarchy = state.hierarchy
          documentPaperSizes = state.paperSizes.merging(documents.mapValues(\.paperSize)) { _, live in live }
          sceneCoverage = state.coverage
          truncatedSceneBoards = state.truncatedBoards
          clearRemovedElementPins(state.missingPinnedElements)
          spatialInk = state.ink
          loadedInkSurfaces = state.inkSurfaces
          alignWorkspaceSelection()
          scheduleScenePreparation(coverageOnly: true)
        } catch {
          publicationFailure = error.localizedDescription
          return
        }
      }
    }
  }

  /// A scene refresh follows the UUIDs already prepared by the page owner. It
  /// resolves their positions again, without replacing a distant curl target
  /// with an unrelated neighbor of the current selection.
  private func preparedNotebookPageIDs(in itemID: UUID?) -> [UUID] {
    pageAddresses.filter { $0.key.itemID == itemID && pages[$0.value] != nil }
      .values.sorted { $0.uuidString < $1.uuidString }
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
  private(set) var sharedContexts: [SharedContextSummary] = [] { didSet { collaborationReadEpoch &+= 1 } }
  private(set) var contextSelection: SharedContextSelection?
  var activeSharedContext: SharedContextSummary? {
    sharedContexts.first { $0.id == contextSelection?.contextID }
  }
  var presentedSharedContext: SharedContextSummary? {
    guard showsCollaborationNotice else { return activeSharedContext }
    let newest = sharedContexts.max { ($0.lastEntry?.createdAt ?? .distantPast) < ($1.lastEntry?.createdAt ?? .distantPast) }
    if let action = collaborationActions.first,
      (action.undo?.completedAt ?? action.createdAt) >= (newest?.lastEntry?.createdAt ?? .distantPast) {
      return sharedContexts.first { $0.id == action.action.resolvedContextID }
    }
    return newest ?? activeSharedContext
  }
  private(set) var agentQuestion: NotebookAgentQuestion?
  private(set) var agentRequestError: String?
  private(set) var isSavingAgentQuestion = false
  @ObservationIgnored private var pinnedAttentionSelections: [(UUID, NotebookAttentionSelection)] = []
  @ObservationIgnored private var attentionGeneration = UUID()
  @ObservationIgnored private var hasRestoredAgentQuestion = false

  #if os(iOS)
    @discardableResult func discussCode(_ fragment: NotebookCodeFragment) -> Task<Void, Never>? {
      guard !isClosing, !inputGate.hasActivePencil, !isSavingAgentQuestion, let chat else { return nil }
      let generation = UUID(); attentionGeneration = generation; isSavingAgentQuestion = true
      let source = chat.files.document?.address == fragment.currentFile ? chat.files.document?.text : nil
      let selection = source.flatMap { fragment.range(in: $0) }
      let related = chat.files.notes.fragments.filter { note in
        guard note.id != fragment.id, note.currentFile == fragment.currentFile, let source, let selection,
          let range = note.range(in: source) else { return false }
        return NSIntersectionRange(selection, range).length > 0
      }.prefix(31).map(\.id)
      let actor = actorID
      let task = Task { [self] in
        defer { isSavingAgentQuestion = false; chatSubmissionTask = nil }
        do {
          let annotations = try await persistence.submit { store in
            try store.readTransaction { store in
              let first = try store.codeAnnotation(fragment.id) ?? .init(fragment: fragment, ink: .init(stamp: fragment.stamp))
              return [first] + (try related.compactMap { try store.codeAnnotation($0) })
            }
          }
          let references = try annotations.map { try $0.reference() }
          var images: [UUID: AgentPinnedImage] = [:], unavailable: [UUID: String] = [:], bytes = 0
          for (annotation, reference) in zip(annotations, references) {
            do {
              let image = try await NotebookCodeImageRenderer.render(annotation, reference: reference)
              guard bytes + image.png.count <= NotebookPinnedImageRenderer.maximumTotalBytes else { throw SceneRenderError.resourceLimit }
              images[reference.id] = image; bytes += image.png.count
            } catch { unavailable[reference.id] = error.localizedDescription }
          }
          try Task.checkCancellation()
          let capturedImages = images, missing = unavailable
          let context = try await persistence.submit(publishesChanges: true) {
            try $0.discussCode(annotations, references: references, images: capturedImages, unavailable: missing, actor: actor)
          }
          reloadExternalChanges()
          guard attentionGeneration == generation, !isClosing else { return }
          agentQuestion = .init(contextID: context.id, entryID: context.entry.id, references: references)
          agentRequestError = nil; chat.expanded = true; chat.browsesChats = false
          await chat.files.notes.refresh()
        } catch { agentRequestError = error.localizedDescription }
      }
      chatSubmissionTask = task
      return task
    }

    func openNotebookLink(_ url: URL) {
      guard let link = NotebookCodeLink(url: url) else { return }
      inputGate.performAfterPageContact { [weak self] in
        guard let self, let chat else { return }
        switch link {
        case .file(let file, let line): Task { await chat.files.navigate(to: file, line: line) }
        case .fragment(let id):
          Task { [weak self] in
            guard let self else { return }
            do {
              guard let fragment = try await persistence.submit({ try $0.codeFragment(id) }) else {
                throw CollaborationError("source_missing", "Рассмотренный код ещё не доставлен.")
              }
              inputGate.performAfterPageContact { Task { await chat.files.navigate(to: fragment) } }
            } catch { agentRequestError = error.localizedDescription }
          }
        case .conversation(let computer, let thread):
          Task {
            if computer != chat.computerID { await chat.chooseComputer(computer) }
            guard computer == chat.computerID else { agentRequestError = "Разговор находится на Mac, доступ к которому не подключён."; return }
            chat.select(.init(id: thread.uuidString.lowercased(), title: "Сохранённый разговор", cwd: "")); chat.expanded = true
          }
        }
      }
    }

    func saveChatExplanation(_ message: CodexMessage, thread: String, computer: UUID) {
      guard message.role == .assistant, message.activity == nil, let threadID = UUID(uuidString: thread), let chat else { return }
      let contextID = chat.jobs.first { $0.input.action.threadID == thread && $0.result == .turn(message.turnID) }?.input.attentionContextID
      let actor = actorID, link = NotebookCodeLink.conversation(computer: computer, thread: threadID).url.absoluteString
      let text = "[Ответ Codex в исходном разговоре](\(link))\n\n" + (message.isTruncated ? "Сохранён показанный фрагмент ответа.\n\n" : "") + message.text
      persistence.enqueueCommand(publishesChanges: true, { store in
        let references = try contextID.map { try store.sharedContextPage(contextID: $0, limit: 1).entries.first?.references ?? [] } ?? []
        return try store.appendContext(references: references, author: .human, actor: actor, text: text)
      }) { [weak self] result in
        Task { @MainActor [weak self] in
          do { _ = try result.get(); self?.reloadExternalChanges(); self?.showCue("Ответ сохранён в заметках") }
          catch { self?.agentRequestError = error.localizedDescription }
        }
      }
    }

    private(set) var chat: NotebookChatController?
    @ObservationIgnored private var chatSubmissionTask: Task<Void, Never>?
  #endif

  private(set) var actionCue: String?
  private(set) var penStyle: PenStyle
  private(set) var eraserStyle: EraserStyle
  private(set) var drawingTool: DrawingTool = .pen
  private(set) var isElementEditingEnabled = false
  private(set) var elementEditingSession = ElementEditingSession()

  /// The document bundle supplies its physical size. A notebook or an
  /// unselected board uses the canonical notebook/portal rectangle.
  func itemGeometry(_ itemID: UUID?) -> WorkspaceItemGeometry {
    if let itemID, let paper = documents[itemID]?.paperSize ?? documentPaperSizes[itemID] {
      return .document(paper)
    }
    return .notebook
  }

  let store: NotebookStore
  let actorID: UUID
  let inputGate = NotebookInputGate()

  private var pageSize = defaultPageSize
  private var started = false
  @ObservationIgnored private var startupTask: Task<Void, Never>?
  @ObservationIgnored private let persistence: NotebookPersistenceQueue
  private(set) var persistenceFailure: String?
  private var pendingDeletions: [UUID: Set<UUID>] = [:]
  private var completedDeletions: [UUID: UInt64] = [:]
  @ObservationIgnored private var itemOwnerObserver: (owner: UUID, receive: (UUID, UUID, UInt64) -> Void)?

  func bindItemOwnerObserver(owner: UUID, receive: @escaping (UUID, UUID, UInt64) -> Void) {
    itemOwnerObserver = (owner, receive)
  }

  func unbindItemOwnerObserver(owner: UUID) {
    if itemOwnerObserver?.owner == owner { itemOwnerObserver = nil }
  }

  var pendingDeletionItemIDs: Set<UUID> { Set(pendingDeletions.keys) }
  func isItemBeingDeleted(_ id: UUID) -> Bool { pendingDeletions[id] != nil }
  private func isPageBeingDeleted(_ id: UUID) -> Bool {
    pendingDeletions.values.contains { $0.contains(id) }
  }
  private func surfaceAcceptsChanges(_ surface: SurfaceID) -> Bool {
    guard let id = surface.ownerID else { return false }
    switch surface.kind {
    case .codeFragment: return false
    case .board, .cover: return !isItemBeingDeleted(id)
    case .page: return !isPageBeingDeleted(id)
    }
  }
  private var publicationFailure: String?
  private var peerActivities: [UUID: NotebookInputActivity] = [:]
  private var cueTask: Task<Void, Never>?
  private var pencilUndoHistory = PencilUndoHistory()
  private var inkUndoInProgress = false
  private var reservedDrawingCounters: [UUID: UInt64] = [:]
  typealias PageInkPreparation = @Sendable (PageDocument, PageInkMutation, VersionStamp) async throws -> PreparedPageInkChange
  @MainActor private final class AcceptedPageInk {
    let pageID: UUID
    enum Intent { case append(PageInkAction), undoLast }
    let intent: Intent
    var mutation: PageInkMutation?
    let stamp: VersionStamp
    var page: PageDocument
    var next: AcceptedPageInk?
    var nextOnPage: AcceptedPageInk?
    private enum Delivery { case pending, completed(PreparedPageInkChange?) }
    private var delivery = Delivery.pending
    private var waiters: [CheckedContinuation<PreparedPageInkChange?, Never>] = []

    init(page: PageDocument, intent: Intent, stamp: VersionStamp) {
      self.pageID = page.id; self.page = page; self.intent = intent; self.stamp = stamp
      if case .append(let action) = intent { mutation = .append(action) }
    }
    func value() async -> PreparedPageInkChange? {
      if case .completed(let result) = delivery { return result }
      return await withCheckedContinuation { waiters.append($0) }
    }
    func resolve(_ result: PreparedPageInkChange?) {
      guard case .pending = delivery else { return }
      delivery = .completed(result)
      let completions = waiters; waiters = []
      for waiter in completions { waiter.resume(returning: result) }
    }
  }
  @ObservationIgnored private let preparePageInk: PageInkPreparation
  private struct DrawingReservationKey: Hashable { let pageID: UUID; let stamp: VersionStamp }
  @ObservationIgnored private var drawingReservations: [DrawingReservationKey: PageDocument] = [:]
  @ObservationIgnored private var acceptedPageInkHead: AcceptedPageInk?
  @ObservationIgnored private var acceptedPageInkTail: AcceptedPageInk?
  @ObservationIgnored private var lastAcceptedPageInk: [UUID: AcceptedPageInk] = [:]
  private var acceptedPageInkCount = 0
  @ObservationIgnored private var pageInkPreparationTask: Task<Void, Never>?
  private(set) var acceptedPageInkFailure: String?
  var pendingAcceptedPageInkCount: Int { acceptedPageInkCount }
  var pendingPageDrawingReservationCount: Int { drawingReservations.count }
  private let presenceSessionID = UUID()
  private var presenceSequence: UInt64 = 0
  private var lastSettledPresenceEnvelope: PresenceEnvelope?
  private var presenceSequenceTracker = PresenceSequenceTracker()
  private let startsNearbySync: Bool
  @ObservationIgnored private var sync: NearbySync?
  private(set) var pairingState = NotebookPairingState.idle
  private(set) var pairedPeers: [NotebookTransportIdentity] = []
  @ObservationIgnored private var peerGenerations: [UUID: UUID] = [:]
  #if os(iOS)
    @ObservationIgnored private let inputFrameMonitor: InputFrameMonitor
  #endif
  @ObservationIgnored private var diskRefreshTask: Task<Void, Never>?
  @ObservationIgnored private var headerRefreshTask: Task<Void, Never>?
  @ObservationIgnored private var headerRefreshRequested = false
  @ObservationIgnored private var diskRefreshRequested = false
  @ObservationIgnored private var externalReloadPending = false
  private(set) var shutdownPhase = ShutdownPhase.running
  private var isStopped: Bool { shutdownPhase == .draining || shutdownPhase == .stopped }
  private var isClosing: Bool { shutdownPhase != .running }
  private struct WeakScenePresentationOwner {
    weak var value: (any NotebookScenePresentationOwner)?
  }
  @ObservationIgnored private var scenePresentationOwners: [ObjectIdentifier: WeakScenePresentationOwner] = [:]
  @ObservationIgnored private var shutdownTask: Task<Bool, Never>?
  @ObservationIgnored private var inputSequence: UInt64 = 0
  private(set) var inputIsActive = false
  private(set) var peerInputIsActive = false { didSet { if !peerInputIsActive { publishPreparedSceneIfPossible() } } }
  var permitsBackgroundPreparation: Bool { !isStopped && !inputIsActive && !peerInputIsActive && presencePhase == .settled }
  #if os(macOS)
    @ObservationIgnored private var codexSidecar: NotebookCodexSidecar?
    private(set) var agentStartupError: String?
    @ObservationIgnored private var commandServer: NotebookIPCServer?
    private let commandSocketURL: URL?
    /// Agent vision follows the process-level mirror, not a disposable window.
    private var previewPublisher: MacPreviewPublisher?
  #endif

  let allowsCodexRegistration: Bool
  let pairingActivationID: UUID?

  init(
    store: NotebookStore = NotebookStore(root: NotebookStore.defaultRoot),
    startsNearbySync: Bool = true,
    commandSocketURL: URL? = nil,
    allowsCodexRegistration: Bool = false,
    pairingActivationID: UUID? = nil,
    preparePageInk: @escaping PageInkPreparation = { page, mutation, stamp in
      try await Task.detached(priority: .userInitiated) {
        try page.prepareInkChange(mutation, stamp: stamp)
      }.value
    }
  ) {
    self.store = store
    self.allowsCodexRegistration = allowsCodexRegistration
    self.pairingActivationID = pairingActivationID
    self.preparePageInk = preparePageInk
    persistence = NotebookPersistenceQueue(store: store)
    compositionTiles = SceneCompositionTiles(cacheRoot: store.root.appendingPathComponent("derived/composition", isDirectory: true))
    #if os(iOS)
      inputFrameMonitor = InputFrameMonitor(root: store.root)
    #endif
    self.startsNearbySync = startsNearbySync
    penStyle = Self.loadPenStyle()
    eraserStyle = Self.loadEraserStyle()
    actorID = Self.loadActorID()
    #if os(macOS)
      self.commandSocketURL = commandSocketURL ?? (startsNearbySync ? NotebookIPC.defaultSocketURL : nil)
    #endif
    inputGate.bindNewContactAdmission { [weak self] in self?.shutdownPhase == .running }
    persistence.onFailureChange = { [weak self] message in
      guard let self else { return }
      persistenceFailure = message ?? acceptedPageInkFailure ?? publicationFailure
    }
    persistence.onContentMerged = { [weak self] in self?.reloadExternalChanges() }
    persistence.onCommit = { [weak self] owner in
      guard self?.isStopped == false else { return }
      self?.sync?.notifyDurableChanges()
      switch owner {
      case .page, .document, .documentState, .board, .spatialInk, .nativeText, .elementState:
        self?.refreshCommittedHeader()
      case nil, .presence, .inputActivity, .documentDraft, .fileDraft, .fileWindow, .chatPanel, .runCommand: break
      }

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
        if externalReloadPending {
          externalReloadPending = false
          reloadExternalChanges()
        }
      }
    }
  }

  private func publishInputActivity() {
    guard !isStopped else { return }
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
    sync?.sendTransient(.inputActivity(activity))
    enqueueStoreWrite(owner: .inputActivity(activity.deviceID)) { try $0.saveInputActivity(activity) }
  }

  /// Connection identity is established by TLS and both pairing approvals.
  /// Only this generation may publish or release the peer's contact barrier.
  func peerConnected(_ peer: NotebookTransportIdentity, generation: UUID) {
    peerGenerations[peer.deviceID] = generation
    isPeerConnected = true
    pairedPeers = sync?.pairedPeers ?? []
    publishInputActivity()
    #if os(iOS)
      chat?.updateComputers(pairedPeers)
      Task { [weak self] in
        guard let self, peerGenerations[peer.deviceID] == generation else { return }
        await chat?.connect(peer.deviceID)
      }
      if let lastSettledPresenceEnvelope { sync?.sendTransient(.presence(lastSettledPresenceEnvelope)) }
    #endif
  }

  func peerDisconnected(peerID: UUID, generation: UUID) {
    guard peerGenerations[peerID] == generation else { return }
    #if os(iOS)
      chat?.disconnect(peerID)
    #endif
    peerGenerations[peerID] = nil
    peerActivities[peerID] = nil
    isPeerConnected = !peerGenerations.isEmpty
    peerInputIsActive = peerActivities.values.contains(where: \.isActive)
    enqueueStoreWrite { try $0.resetInputActivity(deviceID: peerID) }
    if !isPeerConnected { restoreSettledPresenceAfterDisconnect() }
  }

  private func startTrustedSync() async throws {
    guard sync == nil else { return }
    let header = try await persistence.submit { try $0.workspaceHeader() }
    let writer = persistence
    let storage = NotebookTransportStorage(
      changes: { cursor, limit in try await writer.submit { try $0.changeJournal(after: cursor, limit: limit) } },
      incomingCursor: { peer in try await writer.submit { try $0.peerCursor(peerID: peer, direction: .incoming) } },
      acknowledgePeer: { peer, cursor in try await writer.submit { try $0.acknowledgePeer(peerID: peer, through: cursor) } },
      blobSize: { hash in try await writer.submit { try $0.blobSize(hash: hash) } },
      readBlobChunk: { hash, offset, count in try await writer.submit { try $0.readBlobChunk(hash: hash, offset: offset, maxBytes: count) } },
      stageBlob: { file, hash, count in try await writer.submit { try $0.stageBlob(file: file, expectedHash: hash, byteCount: count) } },
      missingBlobHashes: { change, limit, after in
        try await writer.submit { try $0.missingBlobHashes(for: change, limit: limit, after: after) }
      },
      applyRemoteChange: { [weak self] change, peer in
        guard let self else { throw NotebookTransportError.disconnected }
        return try await self.applyDurablePeerChange(change, peerID: peer)
      })
    #if os(iOS)
      let role = NearbySync.Role.iPadConnector
      let name = "iPad"
    #else
      let role = NearbySync.Role.macListener
      let name = Host.current().localizedName ?? "Mac"
    #endif
    let connection = NearbySync(role: role,
      identity: .init(deviceID: actorID, workspaceID: header.workspaceID, displayName: name),
      storage: storage, stagingRoot: store.root.appendingPathComponent("transfer-staging", isDirectory: true),
      trustStore: NotebookKeychainPairingStore(activationID: pairingActivationID))
    connection.onPairingChange = { [weak self] state in
      self?.pairingState = state
      self?.pairedPeers = self?.sync?.pairedPeers ?? []
      #if os(iOS)
      self?.chat?.updateComputers(self?.pairedPeers ?? [])
      #endif
    }
    connection.onConnect = { [weak self] peer, generation in self?.peerConnected(peer, generation: generation) }
    connection.onDisconnect = { [weak self] peer, generation in self?.peerDisconnected(peerID: peer, generation: generation) }
    connection.onTransient = { [weak self] value, peer, generation in
      self?.receivePeerTransient(value, peerID: peer, generation: generation)
    }
    connection.onDurableChange = { [weak self] _, peer, generation in
      guard let self, peerGenerations[peer] == generation else { return }
      reloadExternalChanges()
    }
    sync = connection
    connection.start()
    pairedPeers = connection.pairedPeers
    #if os(iOS)
    chat?.updateComputers(pairedPeers)
    #endif
  }

  /// Called only after the transport has authenticated the workspace and
  /// staged every referenced hash. Completion is the durable ACK boundary.
  func applyDurablePeerChange(_ change: NotebookDurableChange, peerID: UUID) async throws -> UInt64 {
    guard !isClosing else { throw CollaborationError("owner_unavailable", "Notebook завершает работу.") }
    // Wait outside the writer so the accepted Pencil tail and contact release
    // can finish. Presence and transfer credits keep their independent lane.
    while inputIsActive || presencePhase == .active {
      guard !isClosing else { throw CollaborationError("owner_unavailable", "Notebook завершает работу.") }
      try await Task.sleep(for: .milliseconds(20))
    }
    guard !isClosing else { throw CollaborationError("owner_unavailable", "Notebook завершает работу.") }
    try Task.checkCancellation()
    let cursor = try await persistence.submit(publishesChanges: true) {
      try $0.applyRemoteChange(change, peerID: peerID)
    }
    reloadExternalChanges()
    return cursor
  }

  func createPairingInvitation() throws -> String {
    guard let sync else { throw NotebookTransportError.storageUnavailable }
    return try sync.createPairingInvitation().encoded()
  }

  func joinPairingInvitation(_ invitation: String) throws {
    guard let sync else { throw NotebookTransportError.storageUnavailable }
    try sync.joinPairingInvitation(invitation.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  func confirmPairing(generation: UUID) throws {
    guard let sync else { throw NotebookTransportError.storageUnavailable }
    try sync.confirmPairing(generation: generation)
  }

  func cancelPairing() throws { try sync?.cancelPairing() }

  #if os(iOS)
  func chooseChatComputer(_ id: UUID) {
    inputGate.performAfterPageContact { [weak self] in Task { await self?.chat?.chooseComputer(id) } }
  }
  #endif

  func revokePeer(_ id: UUID) throws {
    guard let sync else { throw NotebookTransportError.storageUnavailable }
    try sync.revokePeer(id)
    pairedPeers = sync.pairedPeers
    #if os(iOS)
    chat?.updateComputers(pairedPeers)
    #endif
  }

  isolated deinit {
    sync?.stop()
    #if os(macOS)
      commandServer?.stop()
    #endif
  }

  var activePage: PageDocument? {
    guard let pageID = presence?.notebookPageID, !isPageBeingDeleted(pageID) else { return nil }
    return pages[pageID]
  }

  var board: BoardDocument? {
    guard let boardHierarchy else { return nil }
    return boardHierarchy.board(
      presence?.boardID ?? workspace?.rootBoardID ?? WorkspaceRoot.boardID
    )
  }

  var activeItem: WorkspaceItem? {
    presence?.selectedItemID.flatMap { workspace?.item(id: $0) }
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

  func start(pageSize: PageSize) async {
    guard !isStopped else { return }
    if let startupTask { await startupTask.value; return }
    guard !started else { return }
    started = true
    self.pageSize = pageSize
    let startup = Task<Void, Never> { [weak self] in
      guard let self else { return }
      await loadInitialState(pageSize: pageSize)
    }
    startupTask = startup
    await startup.value
    startupTask = nil
  }

  private func loadInitialState(pageSize: PageSize) async {
    do {
      let actor = actorID
      let notebookID = Self.initialNotebookID, pageID = Self.initialPageID
      let stored = try await persistence.submit { store in
        try NotebookSceneState.start(store: store, actor: actor, pageSize: pageSize,
          notebookID: notebookID, pageID: pageID)
      }
      acceptSceneState(stored)
      presence = settledPresence(from: stored.presence, workspace: stored.workspace,
        board: stored.hierarchy, viewport: .init(x: pageSize.width, y: pageSize.height))
      if let presence {
        let selection = presence.selectedItemID.flatMap { workspace?.item(id: $0) }
          ?? stored.workspace.selectedItem
        let pageID = presence.notebookPageID.flatMap { selection.pageIDs.contains($0) ? $0 : nil }
          ?? selection.pageIDs.first
        let presence = presence.selecting(itemID: selection.id, pageID: pageID)
        self.presence = presence
        alignWorkspaceSelection()
        try await persistence.submit { try $0.savePresence(presence) }
        lastSettledPresenceEnvelope = makePresenceEnvelope(
          presence,
          phase: .settled
        )
      }
      loadState = .ready
      reloadCollaborationMetadata()
      reloadExternalChanges()
      #if os(macOS)
        try startCommandServer()
        startPreviewPublication()
      #endif
      #if os(iOS)
        let chat = NotebookChatController(persistence: persistence, author: actorID) { [weak self] envelope, peer in
          self?.sync?.sendTransient(.codex(envelope), to: peer)
        }
        self.chat = chat
        await chat.start()
      #endif
      if startsNearbySync {
        try await startTrustedSync()
        #if os(macOS)
          await startCodexSidecar()
        #endif
      }
    } catch {
      loadState = .failed(error.localizedDescription)
    }
  }

  @discardableResult
  func selectNotebookPage(
    _ pageIndex: Int,
    notebookID: UUID, expectedRoot: String
  ) -> Int? {
    guard !isItemBeingDeleted(notebookID), var workspace, workspace.selectedItemID == notebookID,
      let order = workspace.notebookPageOrder(in: notebookID), order.root == expectedRoot, pageIndex >= 0, pageIndex <= order.count else { return nil }
    let pageID: UUID, createdPage: PageDocument?
    if pageIndex == order.count {
      guard let selection = workspace.appendPage(in: notebookID, actor: actorID, pageSize: pageSize),
        let page = selection.createdPage, let next = workspace.notebookPageOrder(in: notebookID) else { return nil }
      pageID = page.id; createdPage = page
      pages[page.id] = page
      // An append preserves every existing slot. Move only our finite prepared
      // identities to its new root; a peer reorder is never treated this way.
      pageAddresses = Dictionary(uniqueKeysWithValues: pageAddresses.map { address, id in
        (address.itemID == notebookID && address.root == order.root
          ? PageAddress(itemID: notebookID, index: address.index, root: next.root) : address, id)
      })
      pageAddresses[.init(itemID: notebookID, index: pageIndex, root: next.root)] = pageID
    } else {
      guard let page = notebookPage(at: pageIndex, in: notebookID),
        workspace.selectedPageID != page.id,
        workspace.selectItem(notebookID, pageID: page.id, actor: actorID) else { return nil }
      pageID = page.id; createdPage = nil
    }
    self.workspace = workspace
    updateSessionSelection(from: workspace)
    scheduleWorkspaceSelectionSave(workspace, createdPage: createdPage)
    if let root = notebookPageRoot(notebookID) {
      retainPreparedPages(near: .init(itemID: notebookID, index: pageIndex, root: root), selectedPageID: pageID)
    }
    return pageIndex
  }

  @discardableResult
  func createNotebook(at center: WorldPoint) -> UUID? {
    guard center.isValid, var workspace, var board = boardHierarchy, let presence else {
      return nil
    }
    let beforeWorkspace = workspace, beforeBoard = board
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

    enqueueStoreWrite(reload: true) { [workspace, board] store in
      _ = try store.saveWorkspaceEdits(before: beforeWorkspace, after: workspace,
        boardBefore: beforeBoard, boardAfter: board, pages: [created.page])
    }

    self.workspace = workspace
    updateSessionSelection(from: workspace)
    boardHierarchy = board
    pages[created.page.id] = created.page
    if let root = notebookPageRoot(created.item.id) {
      pageAddresses[.init(itemID: created.item.id, index: 0, root: root)] = created.page.id
      retainPreparedPages(near: .init(itemID: created.item.id, index: 0, root: root), selectedPageID: created.page.id)
    }



    showCue("Новая тетрадь")
    return created.item.id
  }

  @discardableResult
  func createDocument(
    at center: WorldPoint,
    paperSize: DocumentPaperSize
  ) -> UUID? {
    guard center.isValid, let beforeWorkspace = workspace, let beforeBoard = boardHierarchy, let presence else { return nil }
    var workspace = beforeWorkspace, board = beforeBoard
    guard let item = workspace.createDocument(title: "", actor: actorID),
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
    enqueueStoreWrite(reload: true) { [workspace, board] store in
      _ = try store.saveWorkspaceEdits(before: beforeWorkspace, after: workspace,
        boardBefore: beforeBoard, boardAfter: board, documents: [document], states: [state])
    }

    self.workspace = workspace
    boardHierarchy = board
    documents[item.id] = document
    updateSessionSelection(from: workspace)
    documentStates[item.id] = state




    showCue("Новый документ")
    return item.id
  }

  @discardableResult
  func createBoard(at center: WorldPoint) -> UUID? {
    guard center.isValid, let beforeWorkspace = workspace, let beforeBoard = boardHierarchy, let presence else { return nil }
    var workspace = beforeWorkspace, hierarchy = beforeBoard
    guard let item = workspace.createBoard(title: "", actor: actorID),
      hierarchy.createBoard(
        item.id,
        in: presence.boardID,
        near: center,
        actor: actorID
      )
    else { return nil }

    enqueueStoreWrite(reload: true) { [workspace, hierarchy] store in
      _ = try store.saveWorkspaceEdits(before: beforeWorkspace, after: workspace,
        boardBefore: beforeBoard, boardAfter: hierarchy)
    }

    self.workspace = workspace
    boardHierarchy = hierarchy
    updateSessionSelection(from: workspace)


    showCue("Новая доска")
    return item.id
  }

  func selectItem(_ itemID: UUID) {
    guard !isItemBeingDeleted(itemID), var workspace else { return }
    if workspace.item(id: itemID) != nil {
      guard workspace.selectItem(itemID, actor: actorID) else { return }
      self.workspace = workspace
      updateSessionSelection(from: workspace)
      scheduleWorkspaceSelectionSave(workspace, createdPage: nil)
      return
    }
    // An addressed navigation result can lie outside the current camera cache.
    // Publish its selection intent now; the writer resolves the actual page.
    guard let presence else { return }
    let next = presence.selecting(itemID: itemID, pageID: nil)
    self.presence = next
    enqueueStoreWrite(reload: true) { store in
      guard let item = try store.readItemHeader(itemID) else { return }
      let durable = try store.loadPresence()
      try store.savePresence(durable.selecting(itemID: itemID, pageID: item.firstPageID))
    }
    requestSceneCoverage(next)
  }

  /// The catalog value projects selection for existing geometry consumers;
  /// SessionPresence is the only durable owner of that selection.
  private func updateSessionSelection(from workspace: WorkspaceIndex) {
    guard let presence else { return }
    let next = presence.selecting(itemID: workspace.selectedItemID, pageID: workspace.selectedPageID)
    self.presence = next
    requestSceneCoverage(next)
    #if os(iOS)
      if let settled = lastSettledPresenceEnvelope?.presence {
        lastSettledPresenceEnvelope = makePresenceEnvelope(
          settled.selecting(itemID: workspace.selectedItemID, pageID: workspace.selectedPageID), phase: .settled)
      }
      if let envelope = makePresenceEnvelope(next, phase: presencePhase) { sync?.sendTransient(.presence(envelope)) }
    #endif
  }

  private func alignWorkspaceSelection() {
    guard var workspace, let presence, let id = presence.selectedItemID else { return }
    if workspace.selectItem(id, pageID: presence.notebookPageID, actor: actorID) {
      self.workspace = workspace
    }
  }

  @discardableResult
  func deleteItem(_ itemID: UUID) async -> Bool {
    // Resuming an actor continuation is not admission: another Pencil-down may
    // arrive before this task resumes. Reserve the target in the same actor
    // segment as the final contact check, before yielding to persistence.
    while true {
      let generation = inputGate.pencilGeneration
      await withCheckedContinuation { continuation in
        inputGate.performAfterPageInput { continuation.resume() }
      }
      guard await finishAcceptedPageInk() else { return false }
      // A second contact may already be lifted but still have unpublished ink.
      // Its generation also requires a fresh page drain.
      if !inputGate.hasActivePencil, inputGate.pencilGeneration == generation { break }
    }
    guard !isItemBeingDeleted(itemID), let removed = workspace?.item(id: itemID),
      let hierarchy = boardHierarchy, let ownerID = hierarchy.ownerBoardID(of: itemID),
      let owner = hierarchy.board(ownerID) else { return false }
    guard max(workspaceHeader?.itemCount ?? 0, workspace?.items.count ?? 0) > 1 else {
      showCue("Один рабочий элемент должен остаться")
      return false
    }
    let loadedPageIDs = Set(removed.pageIDs).union(pageAddresses.filter { $0.key.itemID == itemID }.values)
    pendingDeletions[itemID] = loadedPageIDs
    let actor = actorID, expected = owner.stamp
    // Reserve the exact command clock before yielding. Edits of other visible
    // members remain admitted and cannot reuse the deletion's causal identity.
    if let next = expected.advanced(by: actor), var current = boardHierarchy {
      let frontier = BoardHierarchy(rootBoardID: hierarchy.rootBoardID,
        boards: [.init(id: ownerID, board: .init(freeItems: [], stamp: next))],
        stamp: max(hierarchy.stamp, next))
      current.observeCausalFrontiers(from: frontier)
      boardHierarchy = current
    }
    if var current = workspace, let next = current.stamp.advanced(by: actor) {
      current.observeCausalFrontier(next)
      workspace = current
    }
    do {
      let header = try await persistence.submit(publishesChanges: true) {
        try $0.deleteWorkspaceItem(itemID: itemID, expected: expected, actor: actor)
      }
      completedDeletions[itemID] = header.cursor
      itemOwnerObserver?.receive(itemID, ownerID, header.cursor)
      scenePinnedItems = scenePinnedItems.mapValues { $0.filter { $0 != itemID } }
      for pageID in loadedPageIDs {
        persistence.discardPending(owner: .page(pageID))
        pages[pageID] = nil
        reservedDrawingCounters[pageID] = nil
        pencilUndoHistory.discardChanges(for: pageID)
      }
      pageAddresses = pageAddresses.filter { $0.key.itemID != itemID }
      documents[removed.id] = nil
      documentStates[removed.id] = nil
      // The reload follows every already accepted native write. If another
      // contact is active, keep the deleted owner guarded until publication.
      if let task = reloadExternalChanges() { await task.value }
      else { externalReloadPending = true }
    } catch NotebookStoreError.boardContainsContent {
      pendingDeletions[itemID] = nil
      reloadExternalChanges()
      showCue("Сначала очистите вложенную доску")
      return false
    } catch NotebookStorageError.transactionConflict {
      pendingDeletions[itemID] = nil
      reloadExternalChanges()
      showCue("Элемент обновился. Повторите удаление")
      return false
    } catch {
      pendingDeletions[itemID] = nil
      showCue("Удаление не сохранено: \(error.localizedDescription)")
      return false
    }
    switch removed.kind {
    case .notebook: showCue("Тетрадь удалена")
    case .document: showCue("Документ удалён")
    case .board: showCue("Доска удалена")
    }
    return true
  }

  func moveItem(_ itemID: UUID, to center: WorldPoint) {
    guard !isItemBeingDeleted(itemID), let presence else { return }
    if var board = boardHierarchy, board.moveItem(itemID, in: presence.boardID, to: center, actor: actorID) {
      persistBoard(board)
    } else {
      let boardID = presence.boardID, actor = actorID
      enqueueStoreWrite(reload: true) {
        _ = try $0.moveWorkspaceItem(itemID: itemID, in: boardID, to: center, actor: actor)
      }
    }
  }

  @discardableResult
  func stackItem(_ movingID: UUID, onto targetID: UUID) -> UUID? {
    guard !isItemBeingDeleted(movingID), !isItemBeingDeleted(targetID), var board = boardHierarchy, let presence,
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
    guard !isItemBeingDeleted(itemID), var board = boardHierarchy, let presence,
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
    guard !isItemBeingDeleted(presence.boardID),
      presence.focusedItemID.map({ !isItemBeingDeleted($0) }) ?? true else { return }
    applyPresence(
      presence,
      settled: settled
    )
  }

  @discardableResult
  func enterBoard(_ boardID: UUID, through parentCamera: SpatialCamera? = nil, settled: Bool = true) -> Bool {
    guard !isItemBeingDeleted(boardID), let workspace, let hierarchy = boardHierarchy, let presence else { return false }
    // The accepted catalog owns navigation. A derived image index may still
    // be preparing the newly created portal and cannot veto its identity.
    let item = workspace.item(id: boardID)
    let boardExists = hierarchy.board(boardID) != nil
    guard item?.kind == .board, boardExists else { return false }
    let portal = hierarchy.portalCamera(boardID) ?? BoardPortalCamera()
    let camera: SpatialCamera
    if let parentCamera {
      guard let center = hierarchy.focusedCenter(of: boardID, in: presence.boardID),
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
      let center = hierarchy.focusedCenter(of: presence.boardID, in: parentID), center.isValid
    else { return false }
    let projection = passage ?? BoardPortalProjection.exitingCamera(
      boundary: presence.camera, centroid: .init(x: presence.viewport.x / 2, y: presence.viewport.y / 2),
      portalCenter: center, viewport: presence.viewport)
    guard projection.parentCamera.isValid else { return false }
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
    let selectionItem = presence.selectedItemID ?? self.presence?.selectedItemID
    let selectedPage = presence.notebookPageID
      ?? (selectionItem == self.presence?.selectedItemID ? self.presence?.notebookPageID : nil)
      ?? selectionItem.flatMap { workspace?.item(id: $0)?.pageIDs.first }
    let presence = presence.selecting(itemID: selectionItem, pageID: selectedPage)
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
    alignWorkspaceSelection()
    // A continuous contact can cross a portal without ending. Transfer its
    // publication barrier with the physical owner, not with each camera frame.
    if inputIsActive && inputOwnerChanged { publishInputActivity() }
    let phase = settled ? PresencePhase.settled : .active
    presencePhase = phase
    #if os(iOS)
      guard let envelope = makePresenceEnvelope(resolved, phase: phase) else {
        return
      }
      sync?.sendTransient(.presence(envelope))
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
    guard !isItemBeingDeleted(documentID), pageIndex >= 0,
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
        sync?.sendTransient(
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

  @discardableResult
  func appendSpatialInk(
    tool: SpatialInkTool,
    color: SpatialInkColor,
    spans: [SpatialInkSpan]
  ) -> SpatialInkAction? {
    guard spans.allSatisfy({ surfaceAcceptsChanges($0.surface) }), var journal = spatialInk,
      let action = journal.append(
        tool: tool,
        color: color,
        spans: spans,
        actor: actorID
      )
    else { return nil }
    spatialInk = journal

    scheduleSpatialInkSave(.append(action, journalStamp: journal.stamp))
    return action
  }

  func undoLastSurfaceAction() {
    #if os(iOS)
      if let files = chat?.files, files.window.isOpen {
        guard inputGate.permitsNewContact, !inputGate.hasActivePencil else { return }
        files.notes.undo(); return
      }
    #endif
    guard inputGate.permitsNewContact, !inputGate.hasActivePencil,
      presence?.mode != .document else { return }
    if isPageOpen {
      _ = acceptDrawingUndo()
      return
    }
    guard var journal = spatialInk else { return }
    let surface: SurfaceID? = presence.flatMap { presence in
      presence.focusedItemID.map(SurfaceID.cover)
        ?? .board(presence.boardID)
    }
    guard let action = journal.undoLast(actor: actorID, touching: surface)
      ?? (surface != nil ? journal.undoLast(actor: actorID) : nil)
    else { return }
    spatialInk = journal

    scheduleSpatialInkSave(.state(actionID: action.id, creationStamp: action.stamp,
      isActive: action.isActive, stateStamp: action.stateStamp, journalStamp: journal.stamp))
    showCue("Отменено")
  }

  func afterPageInput(_ action: @escaping NotebookInputCompletion) {
    inputGate.performAfterPageInput(action)
  }

  func addNativeText(boardID: UUID, on itemID: UUID, at point: SpatialPoint) -> String? {
    guard !isItemBeingDeleted(itemID), !isItemBeingDeleted(boardID), var hierarchy = boardHierarchy,
      let board = hierarchy.board(boardID),
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
      in: boardID,
      expected: nil,
      actor: actorID
    ) else {
      return nil
    }
    persistBoard(hierarchy)
    return id
  }

  func updateNativeText(boardID: UUID, elementID: String, text: String) {
    publishNativeText(boardID: boardID, elementID: elementID, text: text, finish: false)
  }

  /// The editor keeps the address of its accepted input after its old board
  /// leaves the finite scene. Disk admission checks that owner, not the camera.
  func finishNativeTextEditing(boardID: UUID, elementID: String, text: String) {
    publishNativeText(boardID: boardID, elementID: elementID, text: text, finish: true)
  }

  private func publishNativeText(boardID: UUID, elementID: String, text: String, finish: Bool) {
    guard !isItemBeingDeleted(boardID) else { return }
    if var hierarchy = boardHierarchy,
      var element = hierarchy.board(boardID)?.elements.first(where: { $0.id == elementID }),
      element.kind == .nativeText {
      guard surfaceAcceptsChanges(element.surface) else { return }
      if finish && text.isEmpty {
        _ = hierarchy.removeElements(ids: [elementID], from: boardID, actor: actorID)
      } else {
        let expected = element.stamp
        if element.update(source: text, actor: actorID) {
          _ = hierarchy.upsertElement(element, in: boardID, expected: expected, actor: actorID)
        }
      }
      if hierarchy != boardHierarchy { boardHierarchy = hierarchy }
    }
    let actor = actorID
    enqueueStoreWrite(owner: finish ? nil : .nativeText(boardID, elementID), reload: true) {
      _ = try $0.updateNativeSpatialText(boardID: boardID, elementID: elementID, text: text, finish: finish, actor: actor)
    }
  }

  /// Geometry/state changes do not revoke a program's accepted message. A
  /// different program or an explicit deletion does, even if this view is gone.
  func commitSpatialElementState(boardID: UUID, rendered: SpatialElement, state: JSONValue) {
    guard surfaceAcceptsChanges(rendered.surface) else { return }
    let actor = actorID
    enqueueStoreWrite(owner: .elementState(boardID, rendered.id), reload: true) { store in
      do { _ = try store.commitSpatialElementState(boardID: boardID, rendered: rendered, state: state, actor: actor) }
      catch let error as CollaborationError where error.code == "source_conflict" {
        // A terminal rejection is not a failed disk write. The replacement
        // program keeps its state; dependent writes must not wait for a retry.
      }
    }
  }

  func reserveDrawingAction(pageID: UUID) -> VersionStamp? {
    guard !isPageBeingDeleted(pageID), let page = pages[pageID] else { return nil }
    let latestCounter = max(
      page.drawingStamp.counter,
      reservedDrawingCounters[pageID] ?? 0
    )
    guard latestCounter < VersionStamp.maximumCounter else { return nil }
    let stamp = VersionStamp(counter: latestCounter + 1, actor: actorID)
    reservedDrawingCounters[pageID] = stamp.counter
    drawingReservations[.init(pageID: pageID, stamp: stamp)] = page
    return stamp
  }

  func releaseDrawingReservation(pageID: UUID, stamp: VersionStamp) {
    drawingReservations[.init(pageID: pageID, stamp: stamp)] = nil
  }

  /// Admission is synchronous with Pencil-up. The model, not a mounted sheet,
  /// retains the measured action before any preparation task can suspend.
  func acceptDrawingAction(
    _ action: PageInkAction,
    pageID: UUID,
    stamp: VersionStamp
  ) -> Task<PreparedPageInkChange?, Never> {
    acceptInkIntent(.append(action), pageID: pageID, stamp: stamp)
  }

  private func acceptInkIntent(_ intent: AcceptedPageInk.Intent, pageID: UUID,
    stamp: VersionStamp) -> Task<PreparedPageInkChange?, Never> {
    guard let page = drawingReservations.removeValue(forKey: .init(pageID: pageID, stamp: stamp)),
      !isPageBeingDeleted(pageID) else { return Task { nil } }
    let accepted = AcceptedPageInk(page: page, intent: intent, stamp: stamp)
    if let tail = acceptedPageInkTail { tail.next = accepted }
    else { acceptedPageInkHead = accepted }
    acceptedPageInkTail = accepted
    lastAcceptedPageInk[pageID]?.nextOnPage = accepted
    lastAcceptedPageInk[pageID] = accepted
    acceptedPageInkCount += 1
    if acceptedPageInkFailure != nil { accepted.resolve(nil) }
    startAcceptedPageInkPreparation()
    // This task only observes delivery. Cancelling or discarding it cannot
    // cancel the accepted action, whose lifetime belongs to this model.
    return Task { await accepted.value() }
  }

  private func startAcceptedPageInkPreparation() {
    guard pageInkPreparationTask == nil, acceptedPageInkFailure == nil,
      acceptedPageInkHead != nil else { return }
    pageInkPreparationTask = Task { [self] in
      defer { pageInkPreparationTask = nil }
      while let accepted = acceptedPageInkHead {
        if accepted.mutation == nil {
          guard let ids = pencilUndoHistory.lastContribution(for: accepted.pageID) else {
            accepted.nextOnPage?.page = pages[accepted.pageID] ?? accepted.page
            completeAcceptedPageInk(accepted, result: nil)
            continue
          }
          // Resolve the queued undo once, after its predecessors. A failed
          // preparation or a peer CAS retry cannot redirect it to other UUIDs.
          accepted.mutation = .remove(ids)
        }
        guard let mutation = accepted.mutation else { preconditionFailure("Accepted ink has no resolved mutation") }
        do {
          let change = try await publishInkMutation(accepted, mutation: mutation)
          switch mutation {
          case .append(let action):
            // An exact repeated UUID is a no-op, not another human contribution.
            if change.stamp != change.baseStamp {
              pencilUndoHistory.recordAction(ownerID: accepted.pageID, actionID: action.id)
            }
          case .remove(let ids):
            pencilUndoHistory.didRemoveContribution(ids, for: accepted.pageID)
            if change.stamp != change.baseStamp { showCue("Отменено") }
          }
          completeAcceptedPageInk(accepted, result: change)
        } catch {
          acceptedPageInkFailure = error.localizedDescription
          persistenceFailure = error.localizedDescription
          // A failed preparation releases observers with failure, but retains
          // this action and its dependencies for the same explicit retry path.
          var next = acceptedPageInkHead
          while let pending = next { pending.resolve(nil); next = pending.next }
          return
        }
      }
    }
  }

  private func completeAcceptedPageInk(_ accepted: AcceptedPageInk, result: PreparedPageInkChange?) {
    acceptedPageInkHead = accepted.next
    accepted.next = nil
    accepted.nextOnPage = nil
    if acceptedPageInkHead == nil { acceptedPageInkTail = nil }
    if lastAcceptedPageInk[accepted.pageID] === accepted { lastAcceptedPageInk[accepted.pageID] = nil }
    acceptedPageInkCount -= 1
    if case .undoLast = accepted.intent { inkUndoInProgress = false }
    accepted.resolve(result)
  }

  /// A page evicted by navigation is retained by its accepted action, not by
  /// the disposable coordinator. A newer in-memory peer value joins the CAS.
  private func publishInkMutation(_ accepted: AcceptedPageInk, mutation: PageInkMutation) async throws -> PreparedPageInkChange {
    while !isPageBeingDeleted(accepted.pageID) {
      let snapshot = pages[accepted.pageID] ?? accepted.page
      let change = try await preparePageInk(snapshot, mutation, accepted.stamp)
      guard !isPageBeingDeleted(accepted.pageID) else { throw NotebookStorageError.transactionConflict }
      var current = pages[accepted.pageID] ?? snapshot
      guard current.publishInkChange(change) else { accepted.page = current; continue }
      // A later queued action may outlive this page's working-set entry too.
      // Hand it the published baseline before releasing this accepted owner.
      accepted.nextOnPage?.page = current
      accepted.page = current
      if change.stamp != change.baseStamp {
        if pages[accepted.pageID] != nil { pages[accepted.pageID] = current }
        scheduleSave(current)
      }
      return change
    }
    throw NotebookStorageError.transactionConflict
  }

  @discardableResult
  private func finishAcceptedPageInk() async -> Bool {
    while let task = pageInkPreparationTask { await task.value }
    return acceptedPageInkHead == nil && acceptedPageInkFailure == nil
  }

  /// Capture the human command before returning to its caller. The same FIFO
  /// resolves its last contribution after prior accepted strokes, even if the
  /// page has left the working set or shutdown starts before it is prepared.
  func acceptDrawingUndo() -> Task<PreparedPageInkChange?, Never> {
    guard inputGate.permitsNewContact, !inputGate.hasActivePencil,
      !inkUndoInProgress, let page = activePage,
      let stamp = reserveDrawingAction(pageID: page.id) else { return Task { nil } }
    inkUndoInProgress = true
    return acceptInkIntent(.undoLast, pageID: page.id, stamp: stamp)
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
    guard !isPageBeingDeleted(pageID), var page = pages[pageID] else { return }
    guard let index = page.elements.firstIndex(where: { $0.id == elementID }) else {
      return
    }
    var elements = page.elements
    elements[index] = elements[index].updating(state: state)
    let previous = page.agentStamp
    page.replaceElements(elements, actor: actorID)
    guard previous != page.agentStamp else { return }
    page = persistMerged(page)
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
    guard surfaceAcceptsChanges(element.surface) else { return false }
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
    guard let element = hierarchy.board(presence.boardID)?.elements.first(where: { $0.id == elementID }),
      surfaceAcceptsChanges(element.surface) else { return false }
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
    guard !isPageBeingDeleted(pageID), var page = pages[pageID] else { return false }
    var elements = page.elements
    guard mutation(page, &elements),
      page.replaceElements(elements, actor: actorID)
    else { return false }
    persistMerged(page)
    return true
  }

  func saveDocumentDraft(_ draft: DocumentEditingSession) {
    guard !isItemBeingDeleted(draft.edit.documentID) else { return }
    if let previous = documentEditingSessions.first(where: { $0.id == draft.id }),
      previous.edit.sequence >= draft.edit.sequence { return }
    documentDraftEpoch &+= 1
    documentEditingSessions.removeAll { $0.id == draft.id }
    documentEditingSessions.append(draft)
    enqueueStoreWrite(owner: .documentDraft(draft.id)) { try $0.saveDocumentDraft(draft) }
  }

  func discardDocumentDraft(_ sessionID: UUID) {
    documentDraftEpoch &+= 1
    documentEditingSessions.removeAll { $0.id == sessionID }
    enqueueStoreWrite { try $0.discardDocumentDraft(sessionID) }
  }

  func commitDocumentSource(edit: DocumentSourceEdit) async throws -> DocumentSourceCommitResult.Status {
    guard shutdownPhase == .running else {
      throw NotebookPersistenceQueue.Failure(message: "Notebook завершает работу; новый исходник не принят.")
    }
    guard !isItemBeingDeleted(edit.documentID) else {
      throw NotebookPersistenceQueue.Failure(message: "Документ удаляется; новые изменения временно недоступны.")
    }
    let actor = actorID
    let result = try await persistence.submit(publishesChanges: true) { try $0.commitDocumentSource(edit: edit, actor: actor) }
    documentDraftEpoch &+= 1
    if result.status == .committed {
      documentEditingSessions.removeAll { $0.id == edit.sessionID }
      if !isStopped, !isItemBeingDeleted(edit.documentID),
        let publication = result.publication, var document = documents[edit.documentID] {
        _ = document.mergeSource(publication)
        documents[document.id] = document
      }
    } else {
      let phase: DocumentEditingSession.Phase = result.status == .conflict ? .conflict : .targetMissing
      let current = documentEditingSessions.first { $0.id == edit.sessionID }
      documentEditingSessions.removeAll { $0.id == edit.sessionID }
      documentEditingSessions.append(.init(edit: current?.edit ?? edit,
        selectionStart: current?.selectionStart ?? 0, selectionEnd: current?.selectionEnd ?? 0,
        isComposing: current?.isComposing ?? false, phase: phase))
    }
    return result.status
  }

  func commitDocumentState(
    documentID: UUID,
    blockID: String,
    value: JSONValue
  ) {
    guard !isStopped, !isItemBeingDeleted(documentID), var journal = documentStates[documentID],
      journal.commit(blockID: blockID, value: value, actor: actorID)
    else { return }
    documentStates[documentID] = journal

    guard let record = journal.records.first(where: { $0.id == blockID }) else { return }
    let command = NotebookDocumentStateCommand(documentID: documentID, record: record, journalStamp: journal.stamp)
    persistence.enqueue(owner: .documentState(documentID)) { try $0.commitDocumentState(command) != command.expectedResult }
  }

  @discardableResult
  func reloadExternalChanges() -> Task<Void, Never>? {
    guard loadState == .ready, !isStopped else { return nil }
    guard !inputGate.isActive, presencePhase != .active else { externalReloadPending = true; return nil }
    diskRefreshRequested = true
    if let diskRefreshTask { return diskRefreshTask }
    let task = Task { [weak self] in
      guard let self else { return }
      defer { diskRefreshTask = nil }
      while diskRefreshRequested, !Task.isCancelled, let presence {
        guard !inputGate.isActive, presencePhase != .active else { externalReloadPending = true; return }
        diskRefreshRequested = false
        let epoch = collaborationReadEpoch
        let draftEpoch = documentDraftEpoch
        let elementPins = scenePinnedElements, itemPins = scenePinnedItems
        let preparedIDs = preparedNotebookPageIDs(in: presence.selectedItemID)
        #if os(iOS)
          let receivingDeviceID: UUID? = actorID
        #else
          let receivingDeviceID: UUID? = nil
        #endif
        do {
          let prepared = try await persistence.submit(publishesChanges: receivingDeviceID != nil) { store in
            try NotebookDiskRefresh.prepare(store: store, presence: presence, receivingDeviceID: receivingDeviceID,
              pinnedElements: elementPins, pinnedItems: itemPins, preparedPages: preparedIDs)
          }
          publicationFailure = nil
          if persistence.failure == nil { persistenceFailure = acceptedPageInkFailure }
          guard !inputGate.isActive, presencePhase != .active else { externalReloadPending = true; return }
          // Settled camera/selection can change without changing content. The
          // old read must not bring the person back after its SQL await.
          guard epoch == collaborationReadEpoch, self.presence == presence, itemPins == scenePinnedItems else {
            diskRefreshRequested = true; continue
          }
          let liveDrafts = documentEditingSessions
          acceptItemOwnerInvalidations(prepared.scene, requested: itemPins)
          acceptSceneState(prepared.scene)
          if draftEpoch != documentDraftEpoch { documentEditingSessions = liveDrafts }
          acceptCollaborationMetadata(actions: prepared.actions, contexts: prepared.contexts, delivery: prepared.delivery)
        } catch {
          publicationFailure = error.localizedDescription
          persistenceFailure = error.localizedDescription
          return
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

    private func startCodexSidecar() async {
      guard codexSidecar == nil, let workspaceID = workspaceHeader?.workspaceID else { return }
      do {
        guard allowsCodexRegistration else {
          agentStartupError = "Запуск Codex из этого архива закрыт до безопасной активации пары. Действующие инструменты Notebook не перенаправлены."
          return
        }
        let installation = try CodexDesktopInstallation.discover()
        guard let entry = Bundle.main.resourceURL?.appendingPathComponent("NotebookTools/dist/index.mjs"),
          let commandSocketURL else { throw CodexBridgeError.notInstalled }
        try await installation.registerNotebookTools(entry: entry, socket: commandSocketURL)
        let directory = FileManager.default.homeDirectoryForCurrentUser
          .appendingPathComponent("Library/Application Support/Notebook/Codex", isDirectory: true)
        let sidecar = NotebookCodexSidecar(persistence: persistence, installation: installation,
          workspaceID: workspaceID, computerID: actorID, directory: directory) { [weak self] envelope, peer in
            self?.sync?.sendTransient(.codex(envelope), to: peer)
          }
        codexSidecar = sidecar; sidecar.start(); agentStartupError = nil
      } catch { agentStartupError = NotebookCodexSidecar.message(error) }
    }

    private func startCommandServer() throws {
      guard commandServer == nil, let commandSocketURL else { return }
      let server = NotebookIPCServer(socketURL: commandSocketURL) { [weak self] command in
        guard let self else { throw CollaborationError("owner_unavailable", "Notebook завершает работу.") }
        return try await self.executeLocalCommand(command)
      }
      try server.start()
      commandServer = server
    }

    /// Wait outside the writer: a contact release must be able to commit while
    /// an agent is waiting. Core rechecks activity and causal versions inside SQL.
    func executeLocalCommand(_ command: NotebookCommand) async throws -> JSONValue {
      guard loadState == .ready, !isClosing else {
        throw CollaborationError("owner_unavailable", "Хранилище Notebook ещё не открыто.")
      }
      let deadline = ContinuousClock.now.advanced(by: .seconds(4))
      while true {
        if command.command == .apply || command.command == .undo {
          while (inputIsActive || peerInputIsActive), ContinuousClock.now < deadline {
            guard !isClosing else { throw CollaborationError("owner_unavailable", "Notebook завершает работу.") }
            try await Task.sleep(for: .milliseconds(20))
          }
        }
        do {
          guard !isClosing else { throw CollaborationError("owner_unavailable", "Notebook завершает работу.") }
          let result = try await persistence.submit(publishesChanges: command.changesStore) {
            try NotebookCommandDispatcher(store: $0).handle(command)
          }
          if command.changesStore { reloadExternalChanges() }
          return result
        } catch let error as CollaborationError where error.code == "input_active" && ContinuousClock.now < deadline {
          try await Task.sleep(for: .milliseconds(20))
        }
      }
    }
  #endif

  func receivePeerTransient(_ message: NotebookTransportTransient, peerID: UUID, generation: UUID) {
    guard !isClosing, peerGenerations[peerID] == generation else { return }
    switch message {
    case .codex(let envelope):
      #if os(iOS)
        chat?.receive(envelope, peerID: peerID)
      #else
        Task { [weak self] in
          guard let self else { return }
          let reply: NotebookChatEnvelope
          if let codexSidecar {
            guard let response = await codexSidecar.receive(envelope, peerID: peerID) else { return }
            reply = response
          } else {
            reply = .init(id: envelope.id, body: .reply(.failure(agentStartupError ?? "Codex недоступен")))
          }
          guard peerGenerations[peerID] == generation, !isClosing else { return }
          sync?.sendTransient(.codex(reply), to: peerID)
        }
      #endif
    case .inputActivity(let activity):
      guard activity.isValid, activity.deviceID == peerID else { return }
      // Stop optional preparation before the disk acknowledges the peer contact.
      if let previous = peerActivities[activity.deviceID], previous.sessionID == activity.sessionID,
        previous.sequence >= activity.sequence { return }
      peerActivities[activity.deviceID] = activity
      peerInputIsActive = peerActivities.values.contains { $0.deviceID != actorID && $0.isActive }
      #if os(macOS)
      if peerInputIsActive { previewPublisher?.suspendForInput() }
      #endif
      enqueueStoreWrite(owner: .inputActivity(activity.deviceID)) { try $0.saveInputActivity(activity) }
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
        alignWorkspaceSelection()
        presencePhase = envelope.phase
        if envelope.phase == .settled {
          lastSettledPresenceEnvelope = envelope
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

  func publishHumanContext(_ selection: NotebookAttentionSelection) {
    let actor = actorID, generation = UUID()
    attentionGeneration = generation
    isPointing = false
    persistence.enqueueCommand(publishesChanges: true, { store in
      let sealed = try selection.seal(in: store)
      let context = try store.appendContext(references: sealed.references, author: .human, actor: actor,
        select: true, sourceWorkspaceID: sealed.workspaceID)
      return (context, sealed)
    }) { [weak self] result in
      Task { @MainActor [weak self] in
        guard let self else { return }
        let context: SharedContextAppend, sealed: NotebookAttentionSelection.Sealed
        do { (context, sealed) = try result.get() }
        catch {
          if self.attentionGeneration == generation { self.agentRequestError = error.localizedDescription }
          return
        }
        let entry = context.entry
        self.pinnedAttentionSelections.append((context.id, sealed.selection))
        if self.pinnedAttentionSelections.count > 2 { self.pinnedAttentionSelections.removeFirst() }
        self.reloadExternalChanges()
        guard self.attentionGeneration == generation else { return }
        self.agentQuestion = .init(contextID: context.id, entryID: entry.id, references: sealed.references)
        self.agentRequestError = nil
      }
    }
  }

  func selectSharedContext(_ id: UUID?) {
    let actor = actorID, generation = UUID()
    attentionGeneration = generation
    hasRestoredAgentQuestion = true
    agentQuestion = id.flatMap { id in
      guard let entry = sharedContexts.first(where: { $0.id == id })?.firstEntry, entry.author == .human else { return nil }
      return .init(contextID: id, entryID: entry.id, references: entry.references)
    }
    persistence.enqueueCommand(publishesChanges: true, { store in
      try store.selectSharedContext(id, actor: actor)
      return try id.flatMap { try store.sharedContextPage(contextID: $0, limit: 1).entries.first }
    }) { [weak self] result in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.reloadExternalChanges()
        guard self.attentionGeneration == generation else { return }
        do {
          if let id, let entry = try result.get(), entry.author == .human {
            self.agentQuestion = .init(contextID: id, entryID: entry.id, references: entry.references)
          }
        } catch { self.agentRequestError = error.localizedDescription }
      }
    }
  }

  /// Close the local indication immediately and persist deselection in the
  /// same order as accepted pointing. History and running grants stay intact;
  /// neither a late pointer completion nor restart may reopen the fragment.
  func dismissAgentQuestion() { selectSharedContext(nil) }

  #if os(iOS)
    /// Selection narrows attention, not the agent's tool authority. This value
    /// captures the physical owner and camera before any save/network suspension.
    @discardableResult func sendChatMessage(steering: Bool = false) -> Task<Void, Never>? {
      guard !isClosing, let chat, let submittedThread = chat.threadID, !isSavingAgentQuestion,
        !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
      let submittedText = chat.draft
      let submittedTurn = steering ? chat.conversation?.activeTurnID : nil
      if steering && submittedTurn == nil { return nil }
      isSavingAgentQuestion = true
      let question = agentQuestion
      let retained = question.flatMap { q in pinnedAttentionSelections.first { $0.0 == q.contextID }?.1 }
      let capturedPresence = presence, capturedWorkspace = workspaceHeader?.workspaceID
      let capturedFile = chat.files.window.isOpen ? chat.files.document : nil
      let task = Task { [self] in
        defer { isSavingAgentQuestion = false; chatSubmissionTask = nil }
        do {
          if let question {
            let visual = try await retained?.renderPinnedImages(references: question.references)
            try await persistence.submit(publishesChanges: true) { store in
              if try store.hasAttentionEvidence(contextID: question.contextID) { return }
              guard let retained else { throw CollaborationError("source_missing", "Историческое изображение не сохранено. Укажите фрагмент снова.") }
              let files = try retained.sourceFiles()
              let sources = try question.references.map { reference in
                try AgentPinnedSource.capture(requestID: question.contextID, reference: reference, files: files)
                  .withVisual(visual?.images[reference.id], unavailable: visual?.unavailable[reference.id] ?? "source_pixels_unavailable")
              }
              try store.saveAttentionEvidence(sources, contextID: question.contextID)
            }
          }
          let context: JSONValue = .object([
            "workspaceID": capturedWorkspace.map { .string($0.uuidString) } ?? .null,
            "presence": try capturedPresence.map(JSONValue.encode) ?? .null,
            "file": try capturedFile.map { try .encode($0.address) } ?? .null,
            "fileLink": capturedFile.map { .string(NotebookCodeLink.file($0.address, line: 1).url.absoluteString) } ?? .null,
            "fileHasLocalDraft": capturedFile.map { .bool($0.text != $0.base) } ?? .null,
            "attention": try question.map { question in
              .object(["contextID": .string(question.contextID.uuidString),
                "entryID": .string(question.entryID.uuidString), "references": try .encode(question.references)])
            } ?? .null,
            "meaning": .string("Read frozen attention via notebook_read_attention(context_id, reference_id). Shared Notebook workspace. Selection directs attention, not permissions. Use Notebook tools for source/version checks, undoable edits and delivery receipts. For code notes use notebook_read_code_notes and appendInkStroke on codeFragment. Use the returned notebook://code/UUID link, or fileLink with the required 1-based line query, in Markdown references. These links scroll only the document. A local draft is not yet the working file on Mac. Do not move the board camera.")
          ])
          let text = String(decoding: try JSONEncoder().encode(context), as: UTF8.self)
          _ = await chat.sendMessage(threadID: submittedThread, text: submittedText, context: text, attentionContextID: question?.contextID, steeringTurnID: submittedTurn)
        } catch { agentRequestError = error.localizedDescription }
      }
      chatSubmissionTask = task
      return task
    }
  #endif

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
    var references = sharedContexts.flatMap { $0.previewEntries.flatMap(\.references) }
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
    let references = sharedContexts.flatMap { $0.previewEntries.flatMap(\.references) }.filter { $0.region != nil && $0.elementID == nil }
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
    case .codeFragment: return "Код с пометками"
    case .page: return "Лист"
    case .document: return "Документ"
    case .cover: return "Обложка"
    case .board: return "Доска"
    case .workspace: return "Рабочее место"
    }
  }

  func requestShow(_ reference: CollaborationReference) {
    if reference.target.kind == .codeFragment {
      #if os(iOS)
        let id = reference.target.id
        Task { [weak self] in
          guard let self, let fragment = try? await persistence.submit({ try $0.codeFragment(id) }) else { return }
          inputGate.performAfterPageContact { [weak self] in
            Task { [weak self] in
              await self?.chat?.files.navigate(to: fragment)
            }
          }
        }
      #endif
      return
    }
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
    let itemID = reference.target.kind == .page
      ? notebookPageOwner(reference.target.id) : reference.target.id
    guard let itemID, let item = workspace?.item(id: itemID) else { return referenceTitle(reference) }
    let kind: String = switch item.kind {
      case .notebook: "Тетрадь"
      case .document: "Документ"
      case .board: "Доска"
    }
    let title = item.title.isEmpty ? kind : item.title
    if reference.target.kind == .page, let index = notebookPageIndex(reference.target.id, in: itemID) {
      return "\(title) · лист \(index + 1)"
    }
    return title
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
      let actor = actorID
      collaborationUndoTask = Task { [weak self] in
        guard let self else { return }
        let result: Result<CollaborationReceipt, Error>
        do {
          result = .success(try await persistence.submit(publishesChanges: true) {
            try $0.undoCollaborationAction(id, actor: actor, waitForInput: 0)
          })
        } catch { result = .failure(error) }
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
    case .codeFragment: return nil // Visibility is acknowledged by the code viewport, never by the board.
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
              ready = DocumentRenderRegistry.shared.hasLiveSurface(document:document,state:state,pageIndex:visible.documentPageIndex)
            } else { ready = false }
          case .board, .cover:
            ready = scene.map { sceneRepresents(reference, in: $0, presence: visible) } ?? false
          case .workspace, .codeFragment: ready = false
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

  private func acceptItemOwnerInvalidations(_ state: NotebookSceneState, requested: [UUID: [UUID]]) {
    let unavailable = state.missingPinnedItems.union(state.transferredPinnedItems.keys)
    guard !unavailable.isEmpty else { return }
    for (boardID, ids) in requested {
      for id in ids where unavailable.contains(id) {
        itemOwnerObserver?.receive(id, boardID, state.header.cursor)
      }
    }
    scenePinnedItems = scenePinnedItems.mapValues { $0.filter { !unavailable.contains($0) } }
  }

  private func acceptSceneState(_ state: NotebookSceneState) {
    workspaceHeader = state.header
    for (id, cursor) in completedDeletions where state.header.cursor >= cursor {
      pendingDeletions[id] = nil
      completedDeletions[id] = nil
    }
    documentPaperSizes = state.paperSizes
    sceneCoverage = state.coverage
    truncatedSceneBoards = state.truncatedBoards
    workspace = state.workspace
    boardHierarchy = state.hierarchy
    spatialInk = state.ink
    loadedInkSurfaces = state.inkSurfaces
    pages = state.pages
    pageAddresses = Dictionary(uniqueKeysWithValues: state.pagePositions.map {
      (PageAddress(itemID: $0.itemID, index: $0.index, root: $0.visibleRoot), $0.pageID)
    })
    documents = state.documents
    documentStates = state.states
    documentEditingSessions = state.drafts
    presence = state.presence
    alignWorkspaceSelection()
  }

  private func reloadCollaborationMetadata() { reloadExternalChanges() }

  /// Native owners already published their local values. Advance only the
  /// durable source identity; rereading the archive or replacing that input is
  /// neither necessary nor safe. Peer commands publish a complete scene cut
  /// through reloadExternalChanges instead.
  private func refreshCommittedHeader() {
    guard !isStopped else { return }
    headerRefreshRequested = true
    guard headerRefreshTask == nil else { return }
    headerRefreshTask = Task { [weak self] in
      guard let self else { return }
      defer { headerRefreshTask = nil }
      while headerRefreshRequested, !Task.isCancelled {
        headerRefreshRequested = false
        do {
          let header = try await persistence.submit { try $0.workspaceHeader() }
          if workspaceHeader?.workspaceID == header.workspaceID,
            header.cursor >= (workspaceHeader?.cursor ?? 0) { workspaceHeader = header }
        } catch {
          publicationFailure = error.localizedDescription
        }
      }
    }
  }

  private func acceptCollaborationMetadata(actions: [CollaborationReceipt], contexts: SharedContextDirectory,
    delivery: [DeviceActionReceipt]) {
    if collaborationActions != actions { collaborationActions = actions }
    var prepared = contexts.contexts
    if let selected = contexts.selectedContext, !prepared.contains(where: { $0.id == selected.id }) {
      if prepared.count == 64 { prepared.removeLast() }
      prepared.append(selected)
    }
    if sharedContexts != prepared { sharedContexts = prepared }
    contextSelection = contexts.selection
    if !hasRestoredAgentQuestion {
      hasRestoredAgentQuestion = true
      if let context = prepared.first(where: { $0.id == contexts.selection?.contextID }),
        let entry = context.previewEntries.first(where: { $0.author == .human }) {
        agentQuestion = .init(contextID: context.id, entryID: entry.id, references: entry.references)
      }
    }
    deviceActionReceipts = delivery
    let latest = collaborationActions.first
    let attention = sharedContexts.flatMap(\.previewEntries).filter { $0.author == .agent }.max { $0.createdAt < $1.createdAt }
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

  private func scheduleSave(_ page: PageDocument) {
    persistence.enqueue(owner: .page(page.id)) { try $0.savePage(page) != page }
  }

  private func scheduleSpatialInkSave(_ command: NotebookSpatialInkCommand) {
    persistence.enqueue(owner: .spatialInk(command.expectedResult.actionID)) {
      try $0.commitSpatialInk(command) != command.expectedResult
    }
  }

  private func scheduleWorkspaceSelectionSave(
    _ workspace: WorkspaceIndex,
    createdPage: PageDocument?
  ) {
    // Creation is a fence: the following first stroke cannot overtake it.
    persistence.enqueue { store in
      let accepted = try store.saveWorkspaceSelection(index: workspace, createdPage: createdPage)
      return accepted != workspace.notebookPageOrder(in: workspace.selectedItemID)?.root
    }
  }

  private func schedulePresenceSave(_ presence: SessionPresence) {
    enqueueStoreWrite(owner: .presence) { try $0.savePresence(presence) }
  }

  private func persistBoard(_ board: BoardHierarchy) {
    guard let before = boardHierarchy else { return }
    boardHierarchy = board
    persistence.enqueueBoardEdit(before: before, after: board)
  }

  @discardableResult
  private func persistMerged(_ page: PageDocument) -> PageDocument {
    pages[page.id] = page
    scheduleSave(page)
    return page
  }

  private func enqueueStoreWrite(owner: NotebookPersistenceQueue.Owner? = nil,
    reload: Bool = false, _ operation: @escaping @Sendable (NotebookStore) throws -> Void) {
    persistence.enqueue(owner: owner) { store in
      try operation(store)
      return reload
    }
  }

  func retryPendingPersistence() {
    acceptedPageInkFailure = nil
    startAcceptedPageInkPreparation()
    persistence.retry()
    if publicationFailure != nil { reloadExternalChanges() }
  }

  @discardableResult
  func finishPendingInteraction() async -> Bool {
    while true {
      let generation = inputGate.pencilGeneration
      await withCheckedContinuation { continuation in
        inputGate.performAfterPageInput { continuation.resume() }
      }
      if presencePhase == .active, let presence { updatePresence(presence, settled: true) }
      guard await finishPendingPersistence() else { return false }
      // The await itself is not a contact boundary: a later Pencil may have
      // started or even lifted while the preceding publication was draining.
      if !inputGate.hasActivePencil, generation == inputGate.pencilGeneration { return true }
    }
  }

  /// A completed wait is not a successful save: failures retain their writes
  /// and are returned to shutdown/cutover rather than disappearing with a cue.
  @discardableResult
  func finishPendingPersistence() async -> Bool {
    if let startupTask { await startupTask.value }
    #if os(iOS)
      await chatSubmissionTask?.value
    #endif
    repeat {
      guard await finishAcceptedPageInk() else { return false }
      if let task = diskRefreshTask { await task.value }
      if let task = sceneWindowTask { await task.value }
      if let task = headerRefreshTask { await task.value }
      guard await persistence.flush() else { return false }
    } while diskRefreshTask != nil || headerRefreshTask != nil || persistence.pendingCount > 0
      || pageInkPreparationTask != nil || acceptedPageInkHead != nil
    return publicationFailure == nil
  }

  /// Close service admission, finish accepted input, and join every background
  /// reader before the store can be removed or its process can acknowledge quit.
  /// A failed native write remains in the same queue and returns false.
  @discardableResult
  func shutdown() async -> Bool {
    if let shutdownTask { return await shutdownTask.value }
    if shutdownPhase == .stopped { return true }
    if shutdownPhase == .running { shutdownPhase = .closing }
    let task = Task { [self] in
      if let startupTask { await startupTask.value }
      sync?.stop(); sync = nil
      #if os(macOS)
        await commandServer?.stopAndDrain(); commandServer = nil
        await codexSidecar?.stop(); codexSidecar = nil
        let agentStopped = true
        await previewPublisher?.stop()
      #else
        await chatSubmissionTask?.value
        await chat?.stop()
        let agentStopped = true
      #endif
      let inputSaved = await finishPendingInteraction()
      // A failed quit keeps admission closed but leaves the same writer and
      // refresh owner available to the explicit repair/retry action. Terminal
      // teardown would otherwise make publicationFailure impossible to clear.
      guard agentStopped && inputSaved else { return false }
      shutdownPhase = .draining
      inputGate.onActivityChange = nil
      itemOwnerObserver = nil
      let readers = [scenePreparationTask, sceneWindowTask, diskRefreshTask, headerRefreshTask]
        .compactMap { $0 } + Array(pagePreparationTasks.values)
      for task in readers { task.cancel() }
      for task in readers { await task.value }
      scenePreparationTask = nil; sceneWindowTask = nil; diskRefreshTask = nil; headerRefreshTask = nil
      pagePreparationTasks = [:]
      collaborationReadTask?.cancel()
      if let task = collaborationReadTask { _ = await task.result }
      collaborationReadTask = nil
      collaborationNoticeTask?.cancel(); referenceHighlightTask?.cancel(); cueTask?.cancel()
      if let task = collaborationUndoTask { await task.value }
      await compositionTiles.stop()
      let saved = await persistence.flush()
      if saved {
        shutdownPhase = .stopped
        // A hidden UIHostingController may not evaluate its observed body again.
        // Deliver the terminal boundary directly, without a display/layout tick.
        let owners = scenePresentationOwners.values.compactMap(\.value)
        scenePresentationOwners.removeAll()
        for owner in owners { owner.uninstall() }
      }
      return saved
    }
    shutdownTask = task
    let saved = await task.value
    shutdownTask = nil
    return saved
  }

  func registerScenePresentation(_ owner: any NotebookScenePresentationOwner) {
    guard shutdownPhase != .stopped else { owner.uninstall(); return }
    scenePresentationOwners = scenePresentationOwners.filter { $0.value.value != nil }
    scenePresentationOwners[ObjectIdentifier(owner)] = .init(value: owner)
  }

  func unregisterScenePresentation(_ owner: any NotebookScenePresentationOwner) {
    scenePresentationOwners.removeValue(forKey: ObjectIdentifier(owner))
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
    if !center.isValid {
      // A fan can extend past the address boundary. Restore an overview at
      // its stored physical anchor, not a paper centered at another position.
      let anchor = board?.board(ownerBoardID)?.stack(containing: itemID)?.center ?? .zero
      return SessionPresence(boardID: ownerBoardID, mode: .board,
        camera: .init(center: anchor), viewport: viewportPoint)
        .selecting(itemID: workspace.selectedItemID, pageID: workspace.selectedPageID)
    }
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
    ).selecting(itemID: workspace.selectedItemID, pageID: workspace.selectedPageID)
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
      itemCenter.isValid,
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
          : 0,
        selectedItemID: presence.selectedItemID,
        notebookPageID: presence.notebookPageID
      )
    }

    if presence.mode == .cover, let itemID, !isItemBeingDeleted(itemID) {
      // No placement in a partial query is not evidence of deletion. The next
      // addressed scene read validates this intent without snapping its camera.
      return adapted
    }

    return SessionPresence(
      boardID: presence.boardID,
      mode: .board,
      camera: adapted.camera,
      viewport: viewport,
      selectedItemID: presence.selectedItemID,
      notebookPageID: presence.notebookPageID
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

  /// Content deletion can invalidate a session focus; visibility alone cannot.
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

  private func restoreSettledPresenceAfterDisconnect() {
    #if os(macOS)
      guard presencePhase == .active, let stored = lastSettledPresenceEnvelope?.presence else { return }
      presence = stored
      presencePhase = .settled
      alignWorkspaceSelection()
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

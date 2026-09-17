import Foundation
import CoreGraphics
import Observation
import NotebookCore
#if os(macOS)
import NotebookCodex
import NotebookScriptHost
#else
import UIKit
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
  private(set) var workspace: WorkspaceIndex? {
    didSet {
      collaborationReadEpoch &+= 1
      if oldValue != workspace { collaborationContentEpoch &+= 1 }
      scheduleScenePreparation()
    }
  }
  private(set) var pages: [UUID: PageDocument] = [:] {
    didSet {
      collaborationReadEpoch &+= 1
      if oldValue != pages { collaborationContentEpoch &+= 1 }
    }
  }
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
  func navigateToNotebookPage(at index: Int, in itemID: UUID, expectedRoot: String,
    navigationGeneration generation: UInt64) async {
    guard !Task.isCancelled, navigationGeneration == generation,
      await finishNavigationInput(isCurrent: { self.navigationGeneration == generation }), !Task.isCancelled, !isStopped,
      navigationGeneration == generation, notebookPageRoot(itemID) == expectedRoot else { return }
    await prepareNotebookPage(at: index, in: itemID)
    afterPageInput { [weak self] in
      guard let self, !self.isStopped, self.navigationGeneration == generation,
        self.presence?.focusedItemID == itemID else { return }
      _ = selectNotebookPage(index, notebookID: itemID, expectedRoot: expectedRoot)
    }
  }

  /// A reference is a UUID intent, not an old page number. Resolve it and the
  /// physical notebook into one bounded scene, then publish only if no new
  /// input, selection, or cancellation overtook that read.
  func navigateToNotebookPage(id pageID: UUID, isCurrent: @MainActor () -> Bool) async -> Bool {
    while !Task.isCancelled, !isStopped, isCurrent() {
      guard await finishNavigationInput(isCurrent: isCurrent), !Task.isCancelled, !isStopped,
        let presence, isCurrent() else { return false }
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
        guard !Task.isCancelled, !isStopped, isCurrent() else { return false }
        guard epoch == collaborationReadEpoch, generation == inputGate.pencilGeneration, !inputGate.hasActivePencil else { continue }
        guard let itemID = state.presence.selectedItemID, !isItemBeingDeleted(itemID), state.presence.notebookPageID == pageID else { return false }
        acceptSceneState(state)
        // The caller owns its camera animation. Selection changes now, not the
        // old camera, and the same actor segment returns its prepared target.
        self.presence = presence.selecting(itemID: itemID, pageID: pageID)
        scheduleWorkspaceSelectionSave(state.workspace, createdPage: nil)
        return true
      } catch {
        guard !Task.isCancelled, !isStopped, isCurrent() else { return false }
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

  private(set) var documents: [UUID: DocumentDocument] = [:] {
    didSet {
      collaborationReadEpoch &+= 1
      if oldValue != documents { collaborationContentEpoch &+= 1 }
      validateDocumentPageNavigation(); scheduleScenePreparation()
    }
  }
  private(set) var documentEditingSessions: [DocumentEditingSession] = []
  private(set) var documentReadingPositions: [UUID: DocumentReadingPosition] = [:]
  @ObservationIgnored private var documentReadingLayout: (id: UUID, stamp: VersionStamp, record: DocumentLayoutRecord)?
  @ObservationIgnored private var readingRestoreDocument: UUID?
  @ObservationIgnored private var readingSuppressedDocument: UUID?
  @ObservationIgnored private var readingReturnPosition: DocumentReadingPosition?
  @ObservationIgnored private var readingRestoreTarget: (id: UUID, stamp: VersionStamp, page: Int)?
  @ObservationIgnored private var documentDraftEpoch: UInt64 = 0
  private struct DocumentOpeningRequest: Sendable {
    let id = UUID()
    let documentID: UUID
    let boardID: UUID
    let workspaceID: UUID
  }
  private struct DocumentOpeningRead: Sendable {
    let request: DocumentOpeningRequest
    let epoch: UInt64
    let draftEpoch: UInt64
    let result: AsyncStream<Result<NotebookSceneState.OpenedDocument?, Error>>
  }
  @ObservationIgnored private var documentOpeningRequest: DocumentOpeningRequest?
  @ObservationIgnored private var documentOpeningTask: Task<Void, Never>?
  private(set) var documentStates: [UUID: DocumentStateJournal] = [:] {
    didSet {
      collaborationReadEpoch &+= 1
      if oldValue != documentStates { collaborationContentEpoch &+= 1 }
    }
  }
  private(set) var boardContentRevisions: [UUID: String] = [:] {
    didSet {
      if oldValue != boardContentRevisions { collaborationReadEpoch &+= 1; collaborationContentEpoch &+= 1 }
    }
  }
  private(set) var boardHierarchy: BoardHierarchy? {
    didSet {
      // An optimistic body is not proof of the complete stored board. Only an
      // accepted SQL scene cut can supply its new content revision.
      for id in Array(boardContentRevisions.keys) where oldValue?.board(id) != boardHierarchy?.board(id) {
        boardContentRevisions[id] = nil
      }
      collaborationReadEpoch &+= 1
      if oldValue != boardHierarchy { collaborationContentEpoch &+= 1 }
      scheduleScenePreparation()
    }
  }
  private(set) var spatialInk: SpatialInkJournal? {
    didSet {
      collaborationReadEpoch &+= 1
      if oldValue != spatialInk { collaborationContentEpoch &+= 1 }
    }
  }
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
  private(set) var completeSceneCoverOwners: Set<UUID> = []
  private(set) var missingSceneElements: [UUID: Set<String>] = [:]
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

  /// Opt-in, read-only state at the same native presentation boundary as pixels.
  /// A blank physical scene must be distinguishable from an unready document.
  var scenePreparationDiagnostic: String? {
    guard documentMeasurements.enabled else { return nil }
    let id = presence?.focusedItemID
    let cohort = compositionTiles.published
    return "focus=\(id?.uuidString ?? "none") body=\(id.flatMap { documents[$0] } != nil) state=\(id.flatMap { documentStates[$0] } != nil) opening=\(documentOpeningRequest?.documentID.uuidString ?? "none") openingTask=\(documentOpeningTask != nil) indexed=\(id.flatMap { sceneIndex?.item(id: $0) } != nil) scenePending=\(scenePreparationPending) permits=\(permitsScenePreparation) input=\(inputIsActive) peerInput=\(peerInputIsActive) composing=\(compositionTiles.isPreparing) cohortBoard=\(cohort?.plan.rootBoardID.uuidString ?? "none") live=\(id.map { id in cohort?.plan.liveOwners.contains { $0.id == .item(id) } == true } ?? false) paint=\(cohort?.isPaintInstalled == true) failure=\(persistenceFailure ?? publicationFailure ?? compositionTiles.failure ?? "none")"
  }

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
    guard permitsScenePreparation else { compositionTiles.cancelPreparation(); return }
    if scenePreparationPending {
      // Extending the same SQL cut must not cancel the image already on its
      // way to the screen. A changed content generation still invalidates it.
      if !scenePreparationIsCoverageOnly { compositionTiles.cancelPreparation() }
      return
    }
    guard let header = workspaceHeader, let frame else { return }
    let source = SceneCompositionSource(store: store, revision: header.cursor, workspaceID: header.workspaceID)
    compositionTiles.prepare(source: source, presence: presence, frame: frame, pinned: pinned,
      displayScale: displayScale, refinesDetails: presencePhase == .settled,
      permitsPreparation: { [weak self] in self?.permitsScenePreparation == true },
      onSourceInvalidated: { [weak self] in self?.reloadExternalChanges() })
  }

  private func clearRemovedElementPins(_ missing: [UUID: Set<String>]) {
    for (boardID, ids) in missing {
      scenePinnedElements[boardID] = scenePinnedElements[boardID]?.filter { !ids.contains($0) }
      if case .spatial(let selectedBoard, let id) = selectionSession.element, selectedBoard == boardID, ids.contains(id) { clearSelection() }
    }
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
        let draftEpoch = documentDraftEpoch
        let pins = scenePinnedElements, itemPins = scenePinnedItems
        let preparedIDs = preparedNotebookPageIDs(in: requested.selectedItemID)
        // Selection admits its source through this same addressed read. A
        // cold document cannot wait for an unrelated peer refresh to appear.
        // Ordinary camera coverage still reads headers, not document bodies.
        let loadsDocument = requested.selectedItemID.map {
          workspace?.item(id: $0)?.kind == .document
            && (documents[$0] == nil || documentStates[$0] == nil)
        } ?? false
        do {
          let state = try await persistence.submit { store in
            try NotebookSceneState.read(store: store, presence: requested,
              viewport: requested.viewport, loadsLiveContent: loadsDocument, pinnedElements: pins, pinnedItems: itemPins, preparedPages: preparedIDs)
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
          boardContentRevisions = state.boardContentRevisions
          admitDocumentReading(state.reading)
          if loadsDocument {
            documents = state.documents
            documentStates = state.states
            if draftEpoch == documentDraftEpoch { documentEditingSessions = state.drafts }
          }
          documentPaperSizes = state.paperSizes.merging(documents.mapValues(\.paperSize)) { _, live in live }
          sceneCoverage = state.coverage
          truncatedSceneBoards = state.truncatedBoards
          completeSceneCoverOwners = state.completeCoverElementOwners
          missingSceneElements = state.missingPinnedElements
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

  #if os(iOS)
  let nativeCameraProjection = SceneNativeCameraProjection()
  @ObservationIgnored private var openDocumentPresentation: DocumentPagePresentationOwner.OpenDocument?
  @ObservationIgnored private var returnDocumentPresentation: DocumentPagePresentationOwner.OpenDocument?
  #endif

  private(set) var presence: SessionPresence? {
    didSet {
      #if os(iOS)
      nativeCameraProjection.update(presence)
      let opened = presence.flatMap { value -> UUID? in
        guard value.openProgress > 0, value.mode == .document else { return nil }
        return value.focusedItemID
      }
      if openDocumentPresentation?.documentID != opened {
        let returning = returnDocumentPresentation?.documentID == opened ? returnDocumentPresentation : nil
        if returning != nil { returnDocumentPresentation = nil }
        if let outgoing = openDocumentPresentation {
          returnDocumentPresentation?.close()
          outgoing.parkForReturn(); returnDocumentPresentation = outgoing
          openDocumentPresentation = nil
        }
        if let opened, !isClosing {
          if let returning { returning.resume(); openDocumentPresentation = returning }
          else {
            openDocumentPresentation = DocumentPagePresentationOwner.shared(documentID: opened,
              resources: .shared).retainOpenDocument()
          }
        } else { returning?.close() }
      }
      openDocumentPresentation?.cameraDidChange()
      pagePresentations.cameraDidChange()
      #endif
    }
  }
  private(set) var presencePhase = PresencePhase.settled
  private(set) var documentSavePresentation: DocumentSavePresentation?
  @ObservationIgnored private var documentSaveObserver: UUID?
  var interactiveElementFocus: InteractiveElementReference? {
    get {
      guard selectionSession.isInteractive else { return nil }
      switch selectionSession.element {
      case .page(let pageID, let id): return .page(pageID: pageID, elementID: id)
      case .spatial(let boardID, let id): return .board(boardID: boardID, elementID: id)
      case nil: return nil
      }
    }
    set {
      guard let newValue else { selectionSession.isInteractive = false; return }
      let reference: EditableElementReference
      switch newValue {
      case .page(let pageID, let id): reference = .page(pageID: pageID, elementID: id)
      case .board(let boardID, let id): reference = .spatial(boardID: boardID, elementID: id)
      }
      selectElement(reference)
      selectionSession.isInteractive = true
    }
  }
  /// A disappearing editor can release only the selection that admitted it.
  func finishInteractiveElementInput(_ reference: EditableElementReference, selectionID: UUID) {
    guard selectionSession.id == selectionID, selectionSession.element == reference else { return }
    selectionSession.isInteractive = false
  }
  var isPointing: Bool { selectionSession.preview != nil || selectionSession.manipulation != nil }
  struct ReturnPlace: Identifiable {
    let id = UUID()
    let presence: SessionPresence
    let pageID: UUID?
    var reading: DocumentReadingPosition? = nil
  }
  private(set) var returnPlaces: [ReturnPlace] = []
  private(set) var requestedReturn: ReturnPlace?
  private(set) var requestedReference: CollaborationReference?
  private(set) var navigationGeneration: UInt64 = 0
  private(set) var documentPageSelection: DocumentPageNavigationRequest?
  private(set) var documentPageNavigationStatus: DocumentPageNavigationStatus?
  @ObservationIgnored private var documentPageController: (id: UUID, documentID: UUID, source: String)?
  @ObservationIgnored private var documentPageLandingRevision: UInt64 = 0
  @ObservationIgnored private var documentPageStatusRevision: UInt64 = 0
  @ObservationIgnored var stopNavigationPresentation: ((UUID) -> Void)?
  let presentationPlayer = NotebookPresentationPlayer()
  let presentationRelay = NotebookPresentationRelay()
  var highlightedReference: CollaborationReference? { selectionSession.highlightedReference }
  private(set) var pendingAgentHighlights = Set<UUID>()
  private var hasReadCollaborationActions = false
  private var referenceHighlightTask: Task<Void, Never>?
  private var collaborationUndoTask: Task<Void, Never>?
  private var collaborationReadSnapshot: CollaborationReadSnapshot?
  /// Publication/admission order rejects stale asynchronous scene reads, even
  /// when the accepted cut happens to contain the same source values.
  private(set) var collaborationReadEpoch: UInt64 = 0
  /// History preparation follows changed input values, not repeated SQL reads.
  /// This identity does not replace the scene publication frontier above.
  private var collaborationContentEpoch: UInt64 = 0
  private var preparedCollaborationVersion: UInt64?
  @ObservationIgnored private var collaborationReadTask: Task<CollaborationReadSnapshot, Error>?
  @ObservationIgnored private var collaborationReadGeneration = 0
  private var deviceActionReceipts: [DeviceActionReceipt] = []
  #if os(iOS)
  let pagePresentations = NotebookPagePresentationRegistry()
  let workspacePresentations = NotebookWorkspacePresentationRegistry()
  let coverPresentations = NotebookCoverPresentationRegistry()
  #endif
  private(set) var isPeerConnected = false
  private(set) var collaborationActions: [NotebookActionReadModel] = [] {
    didSet {
      collaborationReadEpoch &+= 1
      if oldValue != collaborationActions { collaborationContentEpoch &+= 1 }
    }
  }
  private(set) var regionalReferenceStatuses: [UUID: ReferenceStatus] = [:]
  private(set) var sharedContexts: [SharedContextSummary] = [] {
    didSet {
      collaborationReadEpoch &+= 1
      if oldValue != sharedContexts { collaborationContentEpoch &+= 1 }
    }
  }
  var activeSharedContext: SharedContextSummary? {
    sharedContexts.first { $0.id == agentQuestion?.contextID }
  }
  var agentQuestion: NotebookAgentQuestion? { selectionSession.context }
  private(set) var agentRequestError: String?
  private(set) var isSavingAgentQuestion = false
  @ObservationIgnored private var pinnedAttentionSelections: [(UUID, NotebookAttentionSelection)] = []
  @ObservationIgnored private var hasRestoredAgentQuestion = false

  #if os(iOS)
    @discardableResult func discussCode(_ fragment: NotebookCodeFragment) -> Task<Void, Never>? {
      guard !isClosing, !inputGate.hasActivePencil, !isSavingAgentQuestion, let chat else { return nil }
      let generation = replaceSelection(.context); selectionSession.isResolvingContext = true; isSavingAgentQuestion = true
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
          guard selectionSession.id == generation else { return }
          let capturedImages = images, missing = unavailable
          let context = try await persistence.submit(publishesChanges: true) {
            try $0.discussCode(annotations, references: references, images: capturedImages, unavailable: missing, actor: actor)
          }
          reloadExternalChanges()
          guard selectionSession.id == generation, !isClosing else { return }
          selectionSession.isResolvingContext = false
          selectionSession.context = .init(contextID: context.id, entryID: context.entry.id, references: references)
          agentRequestError = nil; chat.expanded = true; chat.browsesChats = false
          await chat.files.notes.refresh()
        } catch {
          if selectionSession.id == generation { selectionSession.isResolvingContext = false; agentRequestError = error.localizedDescription }
        }
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
  private(set) var selectionSession = NotebookSelectionSession() {
    didSet {
      if oldValue.highlightedReference != selectionSession.highlightedReference { collaborationContentEpoch &+= 1 }
    }
  }

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
  let inputGate: NotebookInputGate

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
  private var graphicCommandTask: Task<Void, Never>?
  // Lift transfers its final draft to the accepted command. It is retired by
  // a scene read at/after the durable cursor, not by lift or receipt delivery.
  private(set) var graphicCommandPreview: NotebookElementManipulation?
  @ObservationIgnored private var graphicCommandPreviewCursor: UInt64?
  var graphicCommandPending: Bool { graphicCommandTask != nil || graphicCommandPreview != nil }
  private var inkUndoInProgress = false
  private var reservedDrawingCounters: [UUID: UInt64] = [:]
  typealias PageInkPreparation = @Sendable (PageDocument, PageInkMutation, VersionStamp) async throws -> PreparedPageInkChange
  @MainActor private final class AcceptedPageInk {
    let pageID: UUID
    enum Intent { case append(PageInkAction), undoLast }
    let intent: Intent
    let quickShape: NotebookQuickShapeFit?
    var mutation: PageInkMutation?
    let stamp: VersionStamp
    var page: PageDocument
    var next: AcceptedPageInk?
    var nextOnPage: AcceptedPageInk?
    private enum Delivery { case pending, completed(PreparedPageInkChange?) }
    private var delivery = Delivery.pending
    private var waiters: [CheckedContinuation<PreparedPageInkChange?, Never>] = []

    init(page: PageDocument, intent: Intent, stamp: VersionStamp, quickShape: NotebookQuickShapeFit?) {
      self.pageID = page.id; self.page = page; self.intent = intent; self.stamp = stamp
      self.quickShape = quickShape
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
  var cloudStatus = NotebookCloudStatus.off
  @ObservationIgnored private var cloudSync: NotebookCloudSync?
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
  @ObservationIgnored private var documentShellPreparation: DocumentShellPreparation?
  @ObservationIgnored private var documentPreparationIsForeground = true
  @ObservationIgnored private var shutdownTask: Task<Bool, Never>?
  @ObservationIgnored private var inputSequence: UInt64 = 0
  private(set) var inputIsActive = false
  private(set) var peerInputIsActive = false { didSet { if !peerInputIsActive { publishPreparedSceneIfPossible() } } }
  // Mounted view tasks can run before start() registers its writer. Until the
  // initial workspace is published, a read must not bootstrap SQLite beside it.
  // This admission also changes the history task's key when startup completes.
  var permitsBackgroundPreparation: Bool {
    loadState == .ready && !isStopped && !inputIsActive && !peerInputIsActive && presencePhase == .settled
  }

  /// Moving the camera must not leave newly visible material waiting for lift.
  /// It can project a new immutable scene without replacing an accepted Pencil
  /// contact or the owner of a content manipulation. Other background work
  /// still waits for settlement through permitsBackgroundPreparation.
  var permitsScenePreparation: Bool {
    !isStopped && !peerInputIsActive && !inputGate.hasActivePencil
      && (!inputIsActive || presencePhase == .active)
  }
  #if os(macOS)
    @ObservationIgnored private var codexSidecar: NotebookCodexSidecar?
    private(set) var agentStartupError: String?
    @ObservationIgnored private var commandServer: NotebookIPCServer?
    @ObservationIgnored private var scriptCoordinator: NotebookScriptCoordinator?
    private let commandSocketURL: URL?
    /// Agent vision follows the process-level mirror, not a disposable window.
    private var previewPublisher: MacPreviewPublisher?
  #endif

  let allowsCodexRegistration: Bool
  let pairingActivationID: UUID?
  let acceptance: NotebookAcceptanceConfiguration?
  @ObservationIgnored let documentMeasurements: DocumentPresentationRecorder
  @ObservationIgnored let preferences: UserDefaults
  private let pairingService: String?

  init(
    store: NotebookStore = NotebookStore(root: NotebookStore.defaultRoot),
    startsNearbySync: Bool = true,
    commandSocketURL: URL? = nil,
    allowsCodexRegistration: Bool = false,
    pairingActivationID: UUID? = nil,
    preferences: UserDefaults = .standard,
    pairingService: String? = nil,
    acceptance: NotebookAcceptanceConfiguration? = nil,
    preparePageInk: @escaping PageInkPreparation = { page, mutation, stamp in
      try await Task.detached(priority: .userInitiated) {
        try page.prepareInkChange(mutation, stamp: stamp)
      }.value
    }
  ) {
    self.store = store
    self.allowsCodexRegistration = allowsCodexRegistration
    self.pairingActivationID = pairingActivationID
    self.preferences = preferences
    self.pairingService = pairingService
    self.acceptance = acceptance
    documentMeasurements = DocumentPresentationRecorder(enabled: acceptance != nil
      || ProcessInfo.processInfo.arguments.contains("--notebook-profile-documents"))
    #if DEBUG && targetEnvironment(simulator)
      let arguments = ProcessInfo.processInfo.arguments
      let fixturePencil = arguments.contains(NotebookDrawingFixture.launchArgument)
        && (!arguments.contains(NotebookDrawingFixture.fingerGestureArgument)
          || arguments.contains(NotebookDrawingFixture.mixedInputArgument))
      inputGate = NotebookInputGate(simulatesPencilContacts: fixturePencil || acceptance?.simulatorContact == "pencil")
    #else
      inputGate = NotebookInputGate(simulatesPencilContacts: acceptance?.simulatorContact == "pencil")
    #endif
    self.preparePageInk = preparePageInk
    persistence = NotebookPersistenceQueue(store: store)
    compositionTiles = SceneCompositionTiles()
    #if os(iOS)
      inputFrameMonitor = InputFrameMonitor(root: store.root)
    #endif
    self.startsNearbySync = startsNearbySync
    penStyle = Self.loadPenStyle(defaults: preferences)
    eraserStyle = Self.loadEraserStyle(defaults: preferences)
    actorID = Self.loadActorID(defaults: preferences)
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
      if let cloud = self?.cloudSync { Task { await cloud.notifyLocalChanges() } }
      switch owner {
      case .page, .document, .documentState, .board, .spatialInk, .nativeText, .elementState:
        self?.refreshCommittedHeader()
      case nil, .presence, .inputActivity, .documentDraft, .documentReading, .fileDraft, .fileWindow, .chatPanel, .runCommand: break
      }

    }
    inputGate.onNewAcceptedContact = { [weak self] in self?.cancelRequestedNavigation() }
    inputGate.onActivityChange = { [weak self] active in
      guard let self else { return }
      inputIsActive = active
      if active { presentationPlayer.interrupt() }
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
    presentationRelay.disconnect(peerID)
    presentationPlayer.disconnected(peerID)
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
    let source = try await writer.submit { [actorID] in try $0.replicationSource(deviceID: actorID) }
    let storage = NotebookTransportStorage(
      journalGeneration: source.generation,
      changes: { cursor, limit in try await writer.submit { try $0.changeJournal(after: cursor, limit: limit) } },
      incomingCursor: { peer in try await writer.submit { try $0.admitReplicationSource(peer) } },
      acknowledgePeer: { peer, cursor in try await writer.submit { try $0.acknowledgePeer(peerID: peer, through: cursor) } },
      blobSize: { hash in try await writer.submit { try $0.blobSize(hash: hash) } },
      readBlobChunk: { hash, offset, count in try await writer.submit { try $0.readBlobChunk(hash: hash, offset: offset, maxBytes: count) } },
      stageBlob: { file, hash, count in try await writer.submit { try $0.stageBlob(file: file, expectedHash: hash, byteCount: count) } },
      missingBlobHashes: { delivery, limit, after in
        try await writer.submit {
          try $0.deliveryNeedsContent(delivery) ? $0.missingBlobHashes(for: delivery.change, limit: limit, after: after) : []
        }
      },
      applyRemoteChange: { [weak self] delivery in
        guard let self else { throw NotebookTransportError.disconnected }
        return try await self.applyDurableDelivery(delivery)
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
      trustStore: NotebookKeychainPairingStore(activationID: pairingActivationID, service: pairingService))
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
    await connection.start()
    guard !isClosing, sync === connection else { connection.stop(); return }
    pairedPeers = connection.pairedPeers
    #if os(iOS)
    chat?.updateComputers(pairedPeers)
    #endif
  }

  /// Called only after the transport has authenticated the workspace and
  /// staged every referenced hash. Completion is the durable ACK boundary.
  func applyDurablePeerChange(_ change: NotebookDurableChange, peerID: UUID) async throws -> UInt64 {
    try await applyDurableDelivery(.init(source: .init(deviceID: peerID, generation: peerID), change: change))
  }

  func applyDurableDelivery(_ delivery: NotebookReplicationDelivery, cloudAccount: String? = nil) async throws -> UInt64 {
    guard !isClosing else { throw CollaborationError("owner_unavailable", "Notebook завершает работу.") }
    // Wait outside the writer so the accepted Pencil tail and contact release
    // can finish. Presence and transfer credits keep their independent lane.
    while inputIsActive || presencePhase == .active {
      guard !isClosing else { throw CollaborationError("owner_unavailable", "Notebook завершает работу.") }
      try await Task.sleep(for: .milliseconds(20))
    }
    guard !isClosing else { throw CollaborationError("owner_unavailable", "Notebook завершает работу.") }
    try Task.checkCancellation()
    let cursor = try await persistence.submit(publishesChanges: true) { store in
      if let cloudAccount {
        return try store.applyCloudDelivery(delivery, account: cloudAccount)
      }
      return try store.applyDelivery(delivery)
    }
    reloadExternalChanges()
    return cursor
  }

  private func prepareCloudSync() async {
    do {
      let writer = persistence, actor = actorID
      let identity = try await writer.submit { store in
        try store.prepareCloudStorage()
        return try (store.replicationSource(deviceID: actor), store.workspaceHeader().workspaceID)
      }
      let cloud = NotebookCloudSync(store: store, writer: writer, source: identity.0, workspaceID: identity.1,
        apply: { [weak self] delivery, account in
          guard let self else { throw NotebookTransportError.disconnected }
          _ = try await self.applyDurableDelivery(delivery, cloudAccount: account)
        }, report: { [weak self] status in await self?.acceptCloudStatus(status) })
      cloudSync = cloud
      // Account/network discovery must not hold up LAN or local startup.
      Task { await cloud.resume() }
    } catch { cloudStatus = .init(enabled: false, message: error.localizedDescription) }
  }

  private func acceptCloudStatus(_ value: NotebookCloudStatus) { cloudStatus = value }
  func enableCloud() async {
    if cloudSync == nil { await prepareCloudSync() }
    await cloudSync?.enable()
  }
  func disableCloud() async { await cloudSync?.disable() }
  func syncCloudNow() async { await cloudSync?.syncNow() }

  func createPairingInvitation() async throws -> String {
    guard !isClosing, let sync else { throw NotebookTransportError.storageUnavailable }
    return try await sync.createPairingInvitation().encoded()
  }

  func joinPairingInvitation(_ invitation: String) async throws {
    guard !isClosing, let sync else { throw NotebookTransportError.storageUnavailable }
    try await sync.joinPairingInvitation(invitation.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  func confirmPairing(generation: UUID) async throws {
    guard !isClosing, let sync else { throw NotebookTransportError.storageUnavailable }
    try await sync.confirmPairing(generation: generation)
  }

  func cancelPairing() async throws {
    guard !isClosing else { throw NotebookTransportError.storageUnavailable }
    try await sync?.cancelPairing()
  }

  #if os(iOS)
  func chooseChatComputer(_ id: UUID) {
    inputGate.performAfterPageContact { [weak self] in Task { await self?.chat?.chooseComputer(id) } }
  }
  #endif

  func revokePeer(_ id: UUID) async throws {
    guard !isClosing, let sync else { throw NotebookTransportError.storageUnavailable }
    try await sync.revokePeer(id)
    pairedPeers = sync.pairedPeers
    #if os(iOS)
    chat?.updateComputers(pairedPeers)
    #endif
  }

  isolated deinit {
    if let documentSaveObserver { DocumentRenderRegistry.shared.removeLiveObserver(documentSaveObserver) }
    sync?.stop()
    if let cloudSync { Task { await cloudSync.stop() } }
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
      presence = settledPresence(from: stored.presence, viewport: .init(x: pageSize.width, y: pageSize.height))
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
        try await scripts().start()
        try startCommandServer()
        startPreviewPublication()
      #endif
      #if os(iOS)
        #if DEBUG && targetEnvironment(simulator)
        let syncFixture = try await SimulatorChatFixture.make(persistence: persistence, author: actorID)
        let terminalFixture = try await SimulatorTerminalFixture.make(persistence: persistence, author: actorID, directory: store.root)
        let fixtureChat = syncFixture ?? terminalFixture
        #else
        let fixtureChat: NotebookChatController? = nil
        #endif
        let chat = fixtureChat ?? NotebookChatController(persistence: persistence, author: actorID, preferences: preferences) { [weak self] envelope, peer in
          self?.sync?.sendTransient(.codex(envelope), to: peer)
        }
        self.chat = chat
        chat.dictation.submissionInProgress = { [weak self] in self?.isSavingAgentQuestion == true }
        chat.dictation.captureSubmission = { [weak self, weak chat] in
          guard let self, let chat, !self.isClosing, !self.selectionSession.isResolvingContext else { return nil }
          let context = self.captureChatSubmissionContext(chat)
          return { [weak self, weak chat] recording, text in
            guard let self, let chat, self.chat === chat,
              chat.threadID == recording.thread, chat.computerID == recording.computer else { return false }
            return await withCheckedContinuation { continuation in
              self.sendChatMessage(source: .dictation(recording, text), context: context) { saved in
                continuation.resume(returning: saved)
              }
            }
          }
        }
        await chat.start()
        chat.dictation.setForeground(UIApplication.shared.applicationState == .active)
      #endif
      if startsNearbySync {
        await prepareCloudSync()
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
    if let request = documentOpeningRequest, request.documentID != itemID { cancelDocumentOpening() }
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

  /// Opening owns body admission even when the same closed cover was already
  /// selected. Camera samples and the eventual native mount are consumers of
  /// this request, not prerequisites for reading its source.
  @discardableResult
  func prepareDocumentOpening(_ documentID: UUID, pageIndex: Int, boardID: UUID? = nil, restoreReading: Bool = true) -> Task<Void, Never>? {
    guard !isClosing, pageIndex >= 0, !isItemBeingDeleted(documentID),
      let presence, presence.selectedItemID == documentID,
      let workspaceHeader else { return nil }
    readingRestoreDocument = restoreReading ? documentID : nil
    readingSuppressedDocument = restoreReading ? nil : documentID
    readingRestoreTarget = nil
    // A resolved reference may be outside the camera cache or on another board.
    // Its addressed SQL read validates kind and owner without moving the camera.
    let boardID = boardID ?? presence.boardID
    documentMeasurements.request(documentID: documentID, pageIndex: pageIndex, cause: .open)
    if documents[documentID] != nil, documentStates[documentID] != nil { return nil }
    if documentOpeningRequest?.documentID != documentID || documentOpeningRequest?.boardID != boardID {
      documentOpeningRequest = .init(documentID: documentID, boardID: boardID,
        workspaceID: workspaceHeader.workspaceID)
      observeNavigation("opening_body_requested", fields: ["documentID": .string(documentID.uuidString),
        "openingID": .string(documentOpeningRequest!.id.uuidString)])
    }
    guard documentOpeningTask == nil, let request = documentOpeningRequest else { return documentOpeningTask }
    // Register the first read in this accepted MainActor segment, before the
    // caller starts animation or a later contact enqueues its own writes.
    let firstRead = enqueueDocumentOpeningRead(request)
    let task = Task { [weak self] in
      guard let self else { return }
      defer { documentOpeningTask = nil }
      var pendingRead: DocumentOpeningRead? = firstRead
      while !isClosing, !Task.isCancelled {
        let read: DocumentOpeningRead
        if let accepted = pendingRead { read = accepted; pendingRead = nil }
        else if let request = documentOpeningRequest { read = enqueueDocumentOpeningRead(request) }
        else { return }
        var result = read.result.makeAsyncIterator()
        guard let completion = await result.next() else { return }
        // Even an opening revoked before this task's first turn retains its
        // one submitted read. A later intent cannot accumulate more FIFO reads
        // while that accepted command is still blocked by an earlier write.
        let request = read.request
        let observation: [String: JSONValue] = ["documentID": .string(request.documentID.uuidString),
          "openingID": .string(request.id.uuidString)]
        do {
          let opened = try completion.get()
          observeNavigation("opening_body_read_end", fields: observation)
          guard documentOpeningRequest?.id == request.id, !isClosing, !Task.isCancelled else { continue }
          guard self.presence?.selectedItemID == request.documentID,
            !isItemBeingDeleted(request.documentID), let opened,
            opened.header.workspaceID == request.workspaceID,
            self.workspaceHeader?.workspaceID == request.workspaceID else { cancelDocumentOpening(); return }
          // An accepted edit or a newer read publication can advance while the
          // FIFO read is running. Re-read its one address instead of publishing
          // the older body or waiting for camera settlement/global refresh.
          guard read.epoch == collaborationReadEpoch,
            opened.header.cursor >= (self.workspaceHeader?.cursor ?? 0) else { continue }
          documents[request.documentID] = opened.document
          documentStates[request.documentID] = opened.state
          admitDocumentReading(opened.reading)
          if read.draftEpoch == documentDraftEpoch {
            documentEditingSessions.removeAll { $0.edit.documentID == request.documentID }
            documentEditingSessions += opened.drafts
          }
          documentOpeningRequest = nil
          observeNavigation("opening_body_published", fields: observation)
          return
        } catch {
          guard documentOpeningRequest?.id == request.id, !isClosing, !Task.isCancelled else { continue }
          documentOpeningRequest = nil
          publicationFailure = error.localizedDescription
          persistenceFailure = error.localizedDescription
          return
        }
      }
    }
    documentOpeningTask = task
    return task
  }

  private func enqueueDocumentOpeningRead(_ request: DocumentOpeningRequest) -> DocumentOpeningRead {
    let (result, continuation) = AsyncStream<Result<NotebookSceneState.OpenedDocument?, Error>>
      .makeStream(bufferingPolicy: .bufferingNewest(1))
    let read = DocumentOpeningRead(request: request, epoch: collaborationReadEpoch,
      draftEpoch: documentDraftEpoch, result: result)
    observeNavigation("opening_body_read_begin", fields: ["documentID": .string(request.documentID.uuidString),
      "openingID": .string(request.id.uuidString)])
    persistence.enqueueCommand { store in
      try NotebookSceneState.readOpenedDocument(store: store, documentID: request.documentID, boardID: request.boardID)
    } completion: { completion in
      continuation.yield(completion)
      continuation.finish()
    }
    return read
  }

  /// A submitted read keeps its FIFO lifetime; revoking its identity prevents
  /// the completion from publishing into a closed or subsequently opened item.
  func cancelDocumentOpening() {
    if let request = documentOpeningRequest {
      observeNavigation("opening_body_cancelled", fields: ["documentID": .string(request.documentID.uuidString),
        "openingID": .string(request.id.uuidString)])
    }
    documentOpeningRequest = nil
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
    if let previous = self.presence, let id = previous.focusedItemID,
      previous.openProgress > 0, presence.focusedItemID != id || presence.openProgress <= 0 {
      documentMeasurements.cancel(documentID: id)
    }
    let openingID: UUID?
    if let id = presence.focusedItemID, presence.openProgress > 0,
      itemForDisplay(id: id)?.kind == .document,
      self.presence?.focusedItemID != id || (self.presence?.openProgress ?? 0) <= 0 {
      openingID = id
    } else { openingID = nil }
    applyPresence(
      presence,
      settled: settled
    )
    if let openingID { prepareDocumentOpening(openingID, pageIndex: presence.documentPageIndex) }
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
    if presence.mode != .document || presence.focusedItemID != self.presence?.focusedItemID || presence.openProgress <= 0 {
      rememberDocumentReading()
      documentPageSelection = nil; documentPageNavigationStatus = nil; documentPageController = nil
      if documentReadingLayout?.id != presence.focusedItemID || (settled && presence.openProgress <= 0) {
        documentReadingLayout = nil
      }
      readingRestoreTarget = nil
    }
    let resolved: SessionPresence
    let selectionItem = presence.selectedItemID ?? self.presence?.selectedItemID
    let selectedPage = presence.notebookPageID
      ?? (selectionItem == self.presence?.selectedItemID ? self.presence?.notebookPageID : nil)
      ?? selectionItem.flatMap { workspace?.item(id: $0)?.pageIDs.first }
    let presence = presence.selecting(itemID: selectionItem, pageID: selectedPage)
    if let request = documentOpeningRequest,
      presence.selectedItemID != request.documentID
        || (settled && (presence.boardID != request.boardID || presence.focusedItemID != request.documentID || presence.openProgress <= 0)) {
      cancelDocumentOpening()
    }
    if settled {
      resolved = settledPresence(from: presence, viewport: presence.viewport)
    } else {
      resolved = presence
    }
    let inputOwnerChanged = self.presence?.boardID != resolved.boardID
      || self.presence?.mode != resolved.mode
      || self.presence?.focusedItemID != resolved.focusedItemID
    if inputOwnerChanged { endSurfaceEditing() }
    else if self.presence?.camera != resolved.camera || self.presence?.viewport != resolved.viewport { cancelElementManipulation() }
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
    if settled {
      restoreDocumentReadingIfPossible()
      rememberDocumentReading()
    }
    if settled && externalReloadPending { externalReloadPending = false; reloadExternalChanges() }
  }

  /// Native WebKit has already validated the installed frame and the terminal
  /// activation. This stable owner validates the current document/presence,
  /// rather than a SwiftUI closure's earlier interaction flags or page count.
  func activateDocumentLink(_ activation: DocumentLinkActivation) -> DocumentLinkDestination? {
    let origin = activation.origin, documentID = origin.documentID
    guard !isClosing, !isItemBeingDeleted(documentID),
      let document = documents[documentID], origin.source.matches(document),
      let layout = origin.source.layout,
      let presence, presence.mode == .document, presence.focusedItemID == documentID,
      presence.openProgress >= 0.999, presence.documentPageIndex == origin.pageIndex else { return nil }
    if case .page(let target) = activation.destination {
      guard target >= 0, target < layout.pageCount else { return nil }
      if target != presence.documentPageIndex {
        cancelRequestedNavigation()
        guard selectDocumentPage(target, documentID: documentID) != nil else { return nil }
      }
    }
    return activation.destination
  }

  func documentReadingPosition(_ documentID: UUID) -> DocumentReadingPosition? {
    documentReadingPositions[documentID]
  }

  private func admitDocumentReading(_ reading: DocumentReadingPosition?) {
    guard let reading, documentReadingPositions[reading.documentID] == nil else { return }
    documentReadingPositions[reading.documentID] = reading
  }

  func documentReadingCamera(_ documentID: UUID, center: WorldPoint, viewport: SpatialPoint) -> SpatialCamera {
    let fit = itemGeometry(documentID).fitScale(viewport: viewport)
    guard let reading = documentReadingPositions[documentID],
      let position = center.addressOffset(x: reading.centerOffset.x, y: reading.centerOffset.y) else {
      return .init(center: center, scale: fit)
    }
    return .init(center: position, scale: max(SpatialCamera.minimumScale, fit * reading.zoomRatio))
  }

  /// Source measurement provides content addresses, never a fabricated landing.
  /// Only the open document retains this charged record; the view keeps a summary.
  func acceptDocumentReadingLayout(_ layout: DocumentPageLayout, documentID: UUID) {
    guard let document = documents[documentID], let record = layout.record,
      layout.pageCount(for: Self.documentPageSourceRevision(document)) != nil,
      presence?.focusedItemID == documentID, (presence?.openProgress ?? 0) > 0 else { return }
    documentReadingLayout = (documentID, document.contentStamp, record)
    inputGate.performAfterPageContact { [weak self] in self?.restoreDocumentReadingIfPossible() }
  }

  private func restoreDocumentReadingIfPossible() {
    guard let presence, presence.mode == .document, presence.openProgress >= 0.999,
      presencePhase == .settled, !inputGate.isActive,
      let id = presence.focusedItemID, readingRestoreTarget == nil,
      readingSuppressedDocument != id, documentPageSelection == nil,
      let document = documents[id], let measured = documentReadingLayout,
      measured.id == id, measured.stamp == document.contentStamp, measured.record.isComplete else { return }
    guard let saved = readingReturnPosition ?? documentReadingPositions[id] else {
      readingRestoreDocument = nil
      return
    }
    guard
      saved.documentID == id,
      readingRestoreDocument == id || saved.sourceStamp != document.contentStamp || readingReturnPosition != nil,
      let page = measured.record.reading.page(for: saved.anchor,
        survivingBlockOrder: document.blocks.map(\.id), regions: measured.record.regions) else { return }
    readingRestoreDocument = nil; readingReturnPosition = nil
    if page != presence.documentPageIndex {
      readingRestoreTarget = (id, document.contentStamp, page)
      _ = selectDocumentPage(page, documentID: id, restoresReading: true)
    }
    // Reflow preserves zoom; reopening also restores the book-relative camera.
    guard let center = boardHierarchy?.board(presence.boardID)?.focusedCenter(of: id),
      let cameraCenter = center.addressOffset(x: saved.centerOffset.x, y: saved.centerOffset.y) else { return }
    let camera = SpatialCamera(center: cameraCenter, scale: max(SpatialCamera.minimumScale,
      itemGeometry(id).fitScale(viewport: presence.viewport) * saved.zoomRatio))
    if camera != presence.camera {
      applyPresence(.init(boardID: presence.boardID, mode: presence.mode, camera: camera,
        viewport: presence.viewport, focusedItemID: id, openProgress: presence.openProgress,
        documentPageIndex: presence.documentPageIndex, selectedItemID: presence.selectedItemID), settled: true)
    }
  }

  private func rememberDocumentReading() {
    guard let presence, presence.mode == .document, presence.openProgress >= 0.999,
      let id = presence.focusedItemID, readingRestoreDocument != id,
      readingRestoreTarget?.id != id, let document = documents[id],
      let measured = documentReadingLayout, measured.id == id, measured.stamp == document.contentStamp,
      let center = boardHierarchy?.board(presence.boardID)?.focusedCenter(of: id) else { return }
    let geometry = itemGeometry(id), offset = center.delta(to: presence.camera.center)
    // At fit, the beginning of the sheet is the reading address. Under zoom,
    // retain the nearest visible text segment rather than the old page number.
    let visibleTop = max(0, geometry.height / 2 + offset.y - presence.viewport.y / (2 * presence.camera.scale))
    let order = document.blocks.map(\.id)
    let anchor = measured.record.reading.anchor(page: presence.documentPageIndex, blockOrder: order, y: visibleTop)
      ?? measured.record.regions.first(where: { $0.pageIndex == presence.documentPageIndex }).map {
        DocumentReadingAnchor(blockID: $0.id, nodeID: "", textOffset: 0, offset: 0, blockOrder: order)
      }
    guard let anchor else { return }
    let position = DocumentReadingPosition(documentID: id, sourceStamp: document.contentStamp, anchor: anchor,
      zoomRatio: presence.camera.scale / geometry.fitScale(viewport: presence.viewport), centerOffset: offset)
    guard position.isValid, documentReadingPositions[id] != position else { return }
    documentReadingPositions[id] = position
    // The addressed SQL read restores an evicted bookmark. This is a small
    // current-working-set cache, not another archive-sized history reader.
    if documentReadingPositions.count > 32 {
      let keep = Set(documents.keys).union(returnPlaces.compactMap { $0.reading?.documentID }).union([id])
      documentReadingPositions = documentReadingPositions.filter { keep.contains($0.key) }
    }
    enqueueStoreWrite(owner: .documentReading(id)) { try $0.saveDocumentReadingPosition(position) }
  }

  static func documentPageSourceRevision(_ document: DocumentDocument) -> String {
    "\(document.contentStamp.actor):\(document.contentStamp.counter)"
  }

  /// Requests preparation. Only a landing by the bound iPad controller writes
  /// actual page presence; the Mac sends the same request to that owner.
  @discardableResult
  func selectDocumentPage(_ pageIndex: Int, documentID: UUID,
    publishesRequest: Bool = true, restoresReading: Bool = false) -> Int? {
    guard !isClosing, !isItemBeingDeleted(documentID), pageIndex >= 0,
      pageIndex <= DocumentPageSelectionRequest.maximumPageIndex,
      let document = documents[documentID], let presence,
      presence.mode == .document, presence.focusedItemID == documentID,
      presence.openProgress >= 0.999 else { return nil }
    if !restoresReading {
      readingRestoreDocument = nil; readingReturnPosition = nil; readingRestoreTarget = nil
      readingSuppressedDocument = documentID
    }
    if pageIndex == presence.documentPageIndex, documentPageSelection == nil {
      documentPageNavigationStatus = nil
      return pageIndex
    }
    let source = Self.documentPageSourceRevision(document)
    if documentPageSelection?.pageIndex == pageIndex,
      documentPageSelection?.documentID == documentID,
      documentPageSelection?.sourceRevision == source { return pageIndex }
    documentMeasurements.request(documentID: documentID, pageIndex: pageIndex, cause: .page)
    documentPageNavigationStatus = nil
    #if os(iOS)
      documentPageSelection = .init(id: UUID(), documentID: documentID,
        sourceRevision: source, pageIndex: pageIndex)
    #elseif os(macOS)
      if publishesRequest {
        sync?.sendTransient(.documentPageSelection(.init(documentID: documentID, pageIndex: pageIndex)))
      }
    #endif
    return pageIndex
  }

  /// Binding is not an observable write: UIViewControllerRepresentable may
  /// register its owner during update. Status/landing publication is deferred
  /// by the native controller and checked against this exact binding.
  func bindDocumentPageController(_ id: UUID, documentID: UUID, source: String) {
    guard documents[documentID].map(Self.documentPageSourceRevision) == source,
      presence?.mode == .document, presence?.focusedItemID == documentID else { return }
    if documentPageController?.id != id || documentPageController?.source != source {
      documentPageController = (id, documentID, source)
      documentPageLandingRevision = 0; documentPageStatusRevision = 0
    }
  }

  func unbindDocumentPageController(_ id: UUID) {
    guard documentPageController?.id == id else { return }
    documentPageController = nil
  }

  private func acceptsDocumentPageController(_ id: UUID, documentID: UUID, source: String) -> Bool {
    !isClosing && documentPageController?.id == id
      && documentPageController?.documentID == documentID && documentPageController?.source == source
      && documents[documentID].map(Self.documentPageSourceRevision) == source
      && presence?.mode == .document && presence?.focusedItemID == documentID
      && (presence?.openProgress ?? 0) >= 0.999 && !isItemBeingDeleted(documentID)
  }

  @discardableResult
  func acceptDocumentPageLanding(_ landing: DocumentPageLanding) -> Bool {
    guard acceptsDocumentPageController(landing.controllerID, documentID: landing.documentID, source: landing.sourceRevision),
      landing.revision > documentPageLandingRevision, landing.pageIndex >= 0,
      landing.pageIndex <= DocumentPageSelectionRequest.maximumPageIndex,
      let presence else { return false }
    documentPageLandingRevision = landing.revision
    if let target = readingRestoreTarget, target.id == landing.documentID,
      target.page == landing.pageIndex, documents[target.id]?.contentStamp == target.stamp {
      readingRestoreTarget = nil
    }
    // A is still the actual landing when B superseded its request. A may
    // publish that fact, but cannot clear B or restore an obsolete intent.
    if documentPageSelection?.id == landing.requestID {
      documentPageSelection = nil; documentPageNavigationStatus = nil
    }
    if presence.documentPageIndex != landing.pageIndex {
      applyPresence(.init(boardID: presence.boardID, mode: presence.mode,
        camera: presence.camera, viewport: presence.viewport, focusedItemID: landing.documentID,
        openProgress: presence.openProgress, documentPageIndex: landing.pageIndex,
        selectedItemID: presence.selectedItemID, notebookPageID: presence.notebookPageID), settled: true)
    }
    rememberDocumentReading()
    readingSuppressedDocument = nil
    completeDocumentSavePresentation()
    return true
  }

  func acceptDocumentPageNavigationStatus(_ status: DocumentPageNavigationStatus) {
    guard acceptsDocumentPageController(status.controllerID, documentID: status.documentID, source: status.sourceRevision),
      status.revision > documentPageStatusRevision else { return }
    documentPageStatusRevision = status.revision
    guard status.requestID == documentPageSelection?.id else { return }
    documentPageNavigationStatus = status.target == nil ? nil : status
  }

  func retryDocumentPageNavigation() {
    guard let status = documentPageNavigationStatus, let failure = status.failure,
      status.requestID == documentPageSelection?.id,
      acceptsDocumentPageController(status.controllerID, documentID: status.documentID, source: status.sourceRevision),
      let target = status.target else { return }
    documentMeasurements.request(documentID: status.documentID, pageIndex: target, cause: .page)
    failure.retry()
  }

  private func validateDocumentPageNavigation() {
    if let request = documentPageSelection,
      documents[request.documentID].map(Self.documentPageSourceRevision) != request.sourceRevision {
      documentPageSelection = nil; documentPageNavigationStatus = nil
    }
    if let binding = documentPageController,
      documents[binding.documentID].map(Self.documentPageSourceRevision) != binding.source {
      documentPageController = nil; documentPageNavigationStatus = nil
    }
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
    for surface in Set(action.spans.map(\.surface)) {
      if let owner = surface.ownerID { pencilUndoHistory.recordAction(ownerID: owner, actionID: action.id) }
    }
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
    if let owner = isPageOpen ? activePage?.id : (presence?.focusedItemID ?? presence?.boardID) {
      let restored = pencilUndoHistory.hasHistory(for: owner) ? nil : collaborationActions.first {
        $0.author == .human && $0.undo == nil && $0.action.operations.contains { $0.target.id == owner && [.convertInkToElement, .insertElement, .updateElement, .removeElement].contains($0.kind) }
      }?.id
      if let command = pencilUndoHistory.lastCommand(for: owner) ?? restored { undoCollaboration(command); return }
    }
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
    if let owner = surface?.ownerID { pencilUndoHistory.didRemoveContribution([action.id], for: owner) }

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
  @discardableResult
  func commitSpatialElementState(boardID: UUID, rendered: SpatialElement, state: JSONValue) -> Bool {
    guard surfaceAcceptsChanges(rendered.surface) else { return false }
    // Admission changes the input frontier before its addressed write can
    // finish. A read queued before this contact must not overwrite the live
    // program with an earlier saved value while that write is still pending.
    collaborationReadEpoch &+= 1
    collaborationContentEpoch &+= 1
    let actor = actorID
    enqueueStoreWrite(owner: .elementState(boardID, rendered.id), reload: true) { store in
      do { _ = try store.commitSpatialElementState(boardID: boardID, rendered: rendered, state: state, actor: actor) }
      catch let error as CollaborationError where error.code == "source_conflict" {
        // A terminal rejection is not a failed disk write. The replacement
        // program keeps its state; dependent writes must not wait for a retry.
      }
    }
    return true
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
    stamp: VersionStamp,
    quickShape: NotebookQuickShapeFit? = nil
  ) -> Task<PreparedPageInkChange?, Never> {
    acceptInkIntent(.append(action), pageID: pageID, stamp: stamp, quickShape: quickShape)
  }

  private func acceptInkIntent(_ intent: AcceptedPageInk.Intent, pageID: UUID,
    stamp: VersionStamp, quickShape: NotebookQuickShapeFit? = nil) -> Task<PreparedPageInkChange?, Never> {
    guard let page = drawingReservations.removeValue(forKey: .init(pageID: pageID, stamp: stamp)),
      !isPageBeingDeleted(pageID) else { return Task { nil } }
    let accepted = AcceptedPageInk(page: page, intent: intent, stamp: stamp, quickShape: quickShape)
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
              // Register conversion before releasing the accepted input owner.
              // A disappearing sheet or immediate Save cannot drop this tail.
              if let fit = accepted.quickShape { acceptQuickShape(fit, pageID: accepted.pageID, stroke: action) }
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
    clearSelection()
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
    clearSelection()
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
    clearSelection()
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
    clearSelection()
    drawingTool = .eraser
    let next = EraserStyle(maximumWidth: maximumWidth)
    guard next != eraserStyle else { return }
    eraserStyle = next
    saveEraserStyle()
  }

  func selectDrawingTool(_ tool: DrawingTool) {
    clearSelection()
    drawingTool = tool
  }

  /// All local admissions invalidate previous asynchronous selection work.
  /// History is retained, but its selected pointer follows this same ordered writer.
  @discardableResult
  private func replaceSelection(_ target: NotebookSelectionSession.Target?,
    persistsDeselection: Bool = true) -> UUID {
    let removesContext = !hasRestoredAgentQuestion || selectionSession.context != nil || selectionSession.isResolvingContext
    hasRestoredAgentQuestion = true
    referenceHighlightTask?.cancel(); referenceHighlightTask = nil
    cancelElementManipulation()
    selectionSession = .init(target: target)
    collaborationReadEpoch &+= 1
    agentRequestError = nil
    if persistsDeselection && removesContext {
      let actor = actorID, generation = selectionSession.id
      persistence.enqueueCommand(publishesChanges: true, { try $0.selectSharedContext(nil, actor: actor) }) { [weak self] result in
        Task { @MainActor [weak self] in
          guard let self, selectionSession.id == generation, case .failure(let error) = result else { return }
          agentRequestError = error.localizedDescription
        }
      }
    }
    return selectionSession.id
  }

  func selectWorkspaceItem(_ itemID: UUID, boardID: UUID) {
    let target = NotebookSelectionSession.Target.item(boardID: boardID, itemID: itemID)
    if selectionSession.target != target { replaceSelection(target) }
  }

  func selectElement(_ reference: EditableElementReference) {
    if selectionSession.element != reference { replaceSelection(.element(reference)) }
  }

  func updateSelectionPreview(_ rect: CGRect?) {
    if let rect {
      if selectionSession.preview == nil { replaceSelection(.context) }
      selectionSession.preview = rect
    } else { selectionSession.preview = nil }
  }

  func clearSelection() {
    replaceSelection(nil)
  }

  /// Navigation ends manipulation, but retains explicitly pinned material for
  /// the conversation. Only the resulting context target can show its outline.
  func endSurfaceEditing() {
    guard selectionSession.element != nil || selectionSession.target.map({
      if case .item = $0 { return true }; return false
    }) == true else { return }
    cancelElementManipulation()
    selectionSession.target = .context
    selectionSession.isInteractive = false
  }

  /// A contact belongs to the current selection and exact source frame, not a
  /// reusable element ID. No late lift can commit a superseded contact.
  func beginElementManipulation(_ reference: EditableElementReference,
    kind: NotebookElementManipulation.Kind) -> UUID? {
    if graphicElement(reference) != nil, graphicCommandPending { return nil }
    // A passive raster is selectable, but it is not a live manipulation owner.
    // Selection requests its ordinary scene admission; do not commit an
    // invisible drag while the installed cohort still owns baked pixels.
    if case .spatial = reference, graphicElement(reference) != nil,
      let cohort = compositionTiles.published, presentedElement(reference, cohort: cohort) == nil { return nil }
    guard selectionSession.element == reference, inputGate.beginFingerSequence() != nil,
      let geometry = elementGeometry(reference) else { return nil }
    let connection = graphicElement(reference)?.connection
    let kind: NotebookElementManipulation.Kind = kind == .move && connection?.bindings.isEmpty == false ? .bend : kind
    cancelElementManipulation()
    let contact = NotebookElementManipulation(reference: reference, kind: kind,
      frame: geometry.frame, bounds: geometry.bounds, identity: geometry.identity, worldOrigin: geometry.worldOrigin,
      connection: connection, layout: graphicLayout(reference, preview:false))
    selectionSession.manipulation = contact
    inputGate.beginContact(source: contact.id)
    inputGate.registerFingerCancellation(source: contact.id) { [weak self] in self?.cancelElementManipulation(contact.id) }
    return contact.id
  }

  func updateElementManipulation(_ id: UUID, translation: SpatialPoint) {
    guard selectionSession.manipulation?.id == id else { return }
    selectionSession.manipulation?.update(translation: .init(x: translation.x, y: translation.y))
    selectionSession.manipulation?.bindEndpoint(manipulatedEndpointBinding())
  }

  @discardableResult
  func finishElementManipulation(_ id: UUID, translation: SpatialPoint) -> Bool {
    guard selectionSession.manipulation?.id == id else { return false }
    updateElementManipulation(id, translation: translation)
    guard let contact = selectionSession.manipulation else { return false }
    cancelElementManipulation(id)
    guard contact.frame != contact.original || contact.connection != contact.originalConnection,
      let current = elementGeometry(contact.reference), current.frame == contact.original,
      current.identity == contact.identity, current.worldOrigin == contact.worldOrigin,
      graphicElement(contact.reference)?.connection == contact.originalConnection else { return false }
    if let connection = contact.connection, connection != contact.originalConnection {
      guard let original = contact.originalConnection else { return false }
      var patch: [String: JSONValue] = [:]
      if connection.start != original.start { patch["start"] = try? .encode(connection.start) }
      if connection.end != original.end { patch["end"] = try? .encode(connection.end) }
      if connection.bend != original.bend { patch["bend"] = .number(connection.bend) }
      return performGraphicOperation(.updateElement, reference: contact.reference,
        values: ["graphic": .object(["connection": .object(patch)])], summary: "Изменить связь", preview: contact)
    }
    return commitElementFrame(contact)
  }

  /// Preview and commit use the same completed rectangle. Storage changes the
  /// addressed material; it does not run a second resize calculation.
  private func commitElementFrame(_ contact: NotebookElementManipulation) -> Bool {
    guard let identity = contact.identity else { return false }
    let frame = contact.frame, original = contact.original, actor = actorID
    if graphicElement(contact.reference) != nil {
      return performGraphicOperation(.updateElement, reference: contact.reference,
        values: ["frame": (try? .encode(PageRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height))) ?? .null],
        summary: "Переместить фигуру", preview: contact)
    }
    switch contact.reference {
    case .page(let pageID, let elementID):
      guard var page = pages[pageID], let index = page.elements.firstIndex(where: { $0.id == elementID }) else { return false }
      var elements = page.elements
      let value = PageRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
      elements[index] = elements[index].updating(frame: value)
      guard page.replaceElements(elements, actor: actor) else { return false }
      pages[pageID] = page
      let expected = elements[index], expectedStamp = page.agentStamp
      persistence.enqueue { store in
        let committed = try store.commitPageElementFrame(pageID: pageID, elementID: elementID, identity: identity,
          original: .init(x: original.minX, y: original.minY, width: original.width, height: original.height),
          frame: value, actor: actor)
        return committed?.element != expected || committed?.stamp != expectedStamp
      }
      return true
    case .spatial(let boardID, let elementID):
      guard var hierarchy = boardHierarchy, workspace != nil,
        var element = hierarchy.board(boardID)?.elements.first(where: { $0.id == elementID }),
        surfaceAcceptsChanges(element.surface) else { return false }
      let expected = element.stamp
      guard element.update(frame: .init(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height), actor: actorID),
        hierarchy.upsertElement(element, in: boardID, expected: expected, actor: actorID) else { return false }
      boardHierarchy = hierarchy
      let accepted = element, expectedStamp = hierarchy.stamp
      persistence.enqueue { store in
        let committed = try store.commitSpatialElementFrame(boardID: boardID, elementID: elementID, identity: identity,
          original: .init(x: original.minX, y: original.minY, width: original.width, height: original.height),
          frame: accepted.frame, origin: contact.worldOrigin, actor: actor)
        return committed?.element != accepted || committed?.stamp != expectedStamp
      }
      return true
    }
  }

  func cancelElementManipulation(_ id: UUID? = nil) {
    guard let contact = selectionSession.manipulation, id == nil || contact.id == id else { return }
    selectionSession.manipulation = nil
    inputGate.unregisterFingerCancellation(source: contact.id)
    inputGate.endContact(source: contact.id)
  }

  func elementMovement(_ reference: EditableElementReference) -> SpatialPoint {
    guard let contact = selectionSession.manipulation, contact.reference == reference else { return .zero }
    return .init(x: contact.movement.x, y: contact.movement.y)
  }

  private func elementGeometry(_ reference: EditableElementReference) -> (frame: CGRect, bounds: CGRect?, identity: VersionStamp?, worldOrigin: WorldPoint?)? {
    switch reference {
    case .page(let pageID, let id):
      guard !isPageBeingDeleted(pageID), let page = pages[pageID],
        let element = page.elements.first(where: { $0.id == id }) else { return nil }
      return (.init(x: element.frame.x, y: element.frame.y, width: element.frame.width, height: element.frame.height),
        .init(x: 0, y: 0, width: page.size.width, height: page.size.height), page.elementIdentityStamp(id), nil)
    case .spatial(let boardID, let id):
      guard let element = boardHierarchy?.board(boardID)?.elements.first(where: { $0.id == id }),
        surfaceAcceptsChanges(element.surface) else { return nil }
      let size = itemGeometry(element.surface.ownerID)
      let bounds: CGRect? = element.surface.kind == .cover ? .init(x: 0, y: 0, width: size.width, height: size.height) : nil
      return (.init(x: element.frame.x, y: element.frame.y, width: element.frame.width, height: element.frame.height), bounds,
        boardHierarchy?.board(boardID)?.elementIdentityStamp(id), element.worldOrigin)
    }
  }

  func moveElementAccessibly(_ reference: EditableElementReference, by translation: SpatialPoint) {
    selectElement(reference)
    guard let id = beginElementManipulation(reference, kind: .move) else { return }
    finishElementManipulation(id, translation: translation)
  }

  func graphicElement(_ reference: EditableElementReference) -> NotebookGraphic? {
    switch reference {
    case .page(let pageID, let id): return pages[pageID]?.elements.first { $0.id == id }?.graphic
    case .spatial(let boardID, let id): return boardHierarchy?.board(boardID)?.elements.first { $0.id == id }?.graphic
    }
  }

  func acceptQuickShape(_ fit: NotebookQuickShapeFit, pageID: UUID, stroke: PageInkAction) {
    let graphic = NotebookGraphic(shape:fit.shape,style: .init(stroke: stroke.color, strokeWidth: stroke.samples.first?.width ?? 2), sourceInkIDs: fit.precedingStrokeIDs + [stroke.id],connection:fit.connection)
    guard let values = try? ["kind": JSONValue.string("graphic"), "source": .string(""),
      "frame": .encode(fit.frame), "graphic": .encode(graphic)] else { return }
    performGraphicOperation(.convertInkToElement, reference: .page(pageID: pageID, elementID: UUID().uuidString.lowercased()),
      values: values, summary:"Преобразовать набросок: " + fit.shape.displayName)
  }

  func acceptQuickShape(_ fit: NotebookQuickShapeFit, boardID: UUID, origin: WorldPoint, stroke: SpatialInkAction) {
    let graphic = NotebookGraphic(shape:fit.shape,style: .init(stroke: stroke.color, strokeWidth: stroke.spans.first?.samples.first?.width ?? 2), sourceInkIDs: fit.precedingStrokeIDs + [stroke.id],connection:fit.connection)
    guard let values = try? ["kind": JSONValue.string("graphic"), "source": .string(""),
      "frame": .encode(fit.frame), "graphic": .encode(graphic), "worldOrigin": .encode(origin)] else { return }
    performGraphicOperation(.convertInkToElement, reference: .spatial(boardID: boardID, elementID: UUID().uuidString.lowercased()),
      values: values, summary:"Преобразовать набросок: " + fit.shape.displayName)
  }

  func setGraphicLabel(_ text: String, reference: EditableElementReference, replacing original: String? = nil) {
    if let original, graphicElement(reference)?.label != original {
      showCue("Подпись уже изменена другим действием. Ваш текст: \(text)")
      return
    }
    guard graphicElement(reference)?.label != text else { return }
    performGraphicOperation(.updateElement, reference: reference,
      values: ["graphic": .object(["label": .string(text)])], summary: "Изменить подпись фигуры")
  }

  func setGraphicStyle(reference: EditableElementReference, update: (inout NotebookGraphic.Style) -> Void) {
    guard let original = graphicElement(reference)?.style else { return }
    var style = original; update(&style)
    guard original != style, let value = try? JSONValue.encode(style) else { return }
    performGraphicOperation(.updateElement,reference:reference,values:["graphic":.object(["style":value])],summary:"Изменить оформление фигуры")
  }

  func setGraphicArrowhead(_ head: NotebookGraphicConnection.Arrowhead, terminal: NotebookGraphicConnection.Terminal,
    reference: EditableElementReference) {
    guard graphicElement(reference)?.connection != nil else { return }
    performGraphicOperation(.updateElement,reference:reference,
      values:["graphic":.object(["connection":.object([terminal == .start ? "startArrowhead" : "endArrowhead":.string(head.rawValue)])])],
      summary:"Изменить наконечник связи")
  }

  @discardableResult
  private func performGraphicOperation(_ kind: CollaborationOperation.Kind, reference: EditableElementReference,
    values: [String: JSONValue], summary: String, preview: NotebookElementManipulation? = nil) -> Bool {
    guard !graphicCommandPending else {
      if kind != .convertInkToElement { showCue("Предыдущее изменение ещё сохраняется") }
      return false
    }
    let target: CollaborationTarget, id: String, expectedPage: AgentElement?, expectedSpatial: SpatialElement?
    switch reference {
    case .page(let pageID, let elementID):
      target = .init(kind: .page, id: pageID); id = elementID
      expectedPage = pages[pageID]?.elements.first { $0.id == id }; expectedSpatial = nil
    case .spatial(let boardID, let elementID):
      expectedSpatial = boardHierarchy?.board(boardID)?.elements.first { $0.id == elementID }; expectedPage = nil; id = elementID
      target = expectedSpatial?.surface.kind == .cover
        ? .init(kind: .cover, id: expectedSpatial!.surface.ownerID!, boardID: boardID) : .init(kind: .board, id: boardID)
    }
    let actor = actorID
    graphicCommandPreview = preview
    graphicCommandTask = Task { [weak self] in
      guard let self else { return }
      defer { graphicCommandTask = nil }
      await withCheckedContinuation { continuation in
        inputGate.performAfterIdle { continuation.resume() }
      }
      do {
        let (receipt, cursor) = try await persistence.submit(publishesChanges: true) { store in
          if let expectedPage, try store.readPageElement(pageID: target.id, elementID: id) != expectedPage {
            throw CollaborationError("revision_conflict", "Фигура изменилась до завершения жеста.")
          }
          if let expectedSpatial, try store.readSpatialElement(boardID: target.boardID ?? target.id, elementID: id) != expectedSpatial {
            throw CollaborationError("revision_conflict", "Фигура изменилась до завершения жеста.")
          }
          let revision = try store.targetContentRevision(target: target)
          let ink = kind == .convertInkToElement ? try store.inkRevision(on: target) : nil
          let receipt = try store.applyNativeGraphicAction(.init(summary: summary,
            references: [.init(target: target, elementID: id, revision: revision)],
            expected: [.init(target: target, revision: revision, inkRevision: ink)],
            operations: [.init(kind: kind, target: target, id: id, values: values)]), actor: actor)
          return (receipt, try store.currentChangeCursor())
        }
        if graphicCommandPreview != nil { graphicCommandPreviewCursor = cursor }
        pencilUndoHistory.recordCommand(ownerID: target.id, actionID: receipt.id)
        reloadExternalChanges()
      } catch {
        clearGraphicCommandPreview()
        showCue(error.localizedDescription)
      }
    }
    return true
  }

  private func clearGraphicCommandPreview() {
    graphicCommandPreview = nil
    graphicCommandPreviewCursor = nil
  }

  func deleteElement(_ reference: EditableElementReference) {
    guard selectionSession.element == reference else { return }
    if graphicElement(reference) != nil {
      performGraphicOperation(.removeElement, reference: reference, values: [:], summary: "Удалить фигуру")
      clearSelection(); return
    }
    clearSelection()
    switch reference {
    case .page(let pageID, let elementID): _ = removePageElement(pageID: pageID, elementID: elementID)
    case .spatial(let boardID, let elementID): _ = removeSpatialElement(boardID: boardID, elementID: elementID)
    }
  }

  @discardableResult
  func commitElementState(pageID: UUID, elementID: String, state: JSONValue) -> Bool {
    guard !isPageBeingDeleted(pageID), var page = pages[pageID] else { return false }
    guard let index = page.elements.firstIndex(where: { $0.id == elementID }) else {
      return false
    }
    var elements = page.elements
    elements[index] = elements[index].updating(state: state)
    let previous = page.agentStamp
    page.replaceElements(elements, actor: actorID)
    guard previous != page.agentStamp else { return true }
    page = persistMerged(page)
    return true
  }

  @discardableResult
  func removePageElement(pageID: UUID, elementID: String) -> Bool {
    let removed = mutatePageElements(pageID: pageID) { _, elements in
      let count = elements.count
      elements.removeAll { $0.id == elementID }
      return elements.count != count
    }
    return removed
  }

  @discardableResult
  func removeSpatialElement(boardID: UUID, elementID: String) -> Bool {
    guard var hierarchy = boardHierarchy, workspace != nil else {
      return false
    }
    guard let element = hierarchy.board(boardID)?.elements.first(where: { $0.id == elementID }),
      surfaceAcceptsChanges(element.surface) else { return false }
    guard hierarchy.removeElements(
      ids: [elementID],
      from: boardID,
      actor: actorID
    ) == 1 else {
      return false
    }
    persistBoard(hierarchy)
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
    if let documentSaveObserver { DocumentRenderRegistry.shared.removeLiveObserver(documentSaveObserver) }
    documentSavePresentation = .init(sessionID: edit.sessionID, documentID: edit.documentID,
      blockID: edit.blockID, phase: .saving, source: edit.source)
    documentSaveObserver = DocumentRenderRegistry.shared.observeLive(documentID: edit.documentID) { [weak self] in
      // The native publication can occur during representable update. Its
      // actual attachment is checked again after that update, never polled.
      Task { @MainActor [weak self] in self?.completeDocumentSavePresentation() }
    }
    let result: DocumentSourceCommitResult
    do {
      result = try await persistence.submit(publishesChanges: true) { try $0.commitDocumentSource(edit: edit, actor: actor) }
    } catch {
      clearDocumentSavePresentation(sessionID: edit.sessionID)
      throw error
    }
    documentDraftEpoch &+= 1
    if result.status == .committed {
      documentEditingSessions.removeAll { $0.id == edit.sessionID }
      if !isStopped, !isItemBeingDeleted(edit.documentID),
        let publication = result.publication, var document = documents[edit.documentID] {
        _ = document.mergeSource(publication)
        documents[document.id] = document
      }
      if documentSavePresentation?.sessionID == edit.sessionID {
        documentSavePresentation?.phase = .saved
        completeDocumentSavePresentation()
      }
    } else {
      clearDocumentSavePresentation(sessionID: edit.sessionID)
      let phase: DocumentEditingSession.Phase = result.status == .conflict ? .conflict : .targetMissing
      let current = documentEditingSessions.first { $0.id == edit.sessionID }
      documentEditingSessions.removeAll { $0.id == edit.sessionID }
      documentEditingSessions.append(.init(edit: current?.edit ?? edit,
        selectionStart: current?.selectionStart ?? 0, selectionEnd: current?.selectionEnd ?? 0,
        isComposing: current?.isComposing ?? false, scrollTop: current?.scrollTop, phase: phase))
    }
    return result.status
  }

  private func clearDocumentSavePresentation(sessionID: UUID) {
    guard documentSavePresentation?.sessionID == sessionID else { return }
    documentSavePresentation = nil
    if let documentSaveObserver { DocumentRenderRegistry.shared.removeLiveObserver(documentSaveObserver) }
    documentSaveObserver = nil
  }

  private func completeDocumentSavePresentation() {
    guard let saved = documentSavePresentation, saved.phase == .saved,
      let presence, presence.mode == .document, presence.focusedItemID == saved.documentID,
      presence.openProgress >= 0.999, presencePhase == .settled,
      readingRestoreTarget?.id != saved.documentID, readingRestoreDocument != saved.documentID,
      let document = documents[saved.documentID], let state = documentStates[saved.documentID],
      document.blocks.first(where: { $0.id == saved.blockID })?.source == saved.source,
      DocumentRenderRegistry.shared.hasLiveSurface(document: document, state: state, pageIndex: presence.documentPageIndex, scope: .paper) else { return }
    documentSavePresentation?.phase = .installed
    documentSavePresentation?.source = nil
    if let documentSaveObserver { DocumentRenderRegistry.shared.removeLiveObserver(documentSaveObserver) }
    documentSaveObserver = nil
  }

  @discardableResult
  func commitDocumentState(
    documentID: UUID,
    blockID: String,
    value: JSONValue,
    sourceVersion: ContentFieldVersion
  ) -> ContentFieldVersion? {
    guard !isStopped, !isItemBeingDeleted(documentID),
      let document = documents[documentID], document.sourceVersion(blockID: blockID) == sourceVersion,
      document.blocks.contains(where: { $0.id == blockID && $0.kind == .interactive }),
      var journal = documentStates[documentID] else { return nil }
    guard journal.commit(blockID: blockID, value: value, actor: actorID) else {
      return journal.records.first(where: { $0.id == blockID && $0.value == value })?.valueVersion
    }
    documentStates[documentID] = journal

    guard let record = journal.records.first(where: { $0.id == blockID }) else { return nil }
    let command = NotebookDocumentStateCommand(documentID: documentID, record: record,
      journalStamp: journal.stamp, expectedSourceVersion: sourceVersion)
    persistence.enqueue(owner: .documentState(documentID)) { try $0.commitDocumentState(command) != command.expectedResult }
    // Admission acknowledges this exact human value synchronously. It does
    // not claim durability; runtime retirement waits for the separate fence.
    return record.valueVersion
  }

  /// A runtime may retire only after its last accepted state crossed the sole
  /// writer. The optimistic SwiftUI echo is not a persistence acknowledgement.
  func checkpointDocumentState(documentID: UUID, blockID: String, value: JSONValue,
    sourceVersion: ContentFieldVersion) async throws -> Bool {
    guard !isStopped, !isItemBeingDeleted(documentID),
      let document = documents[documentID], document.sourceVersion(blockID: blockID) == sourceVersion,
      let block = document.blocks.first(where: { $0.id == blockID }),
      let journal = documentStates[documentID] else { return false }
    let record = journal.records.first { $0.id == blockID }
    let stateVersion = record?.valueVersion
    guard (record?.value ?? block.initialState) == value else { return false }
    let stored = try await persistence.submit { try $0.readDocumentBlock(documentID: documentID, blockID: blockID) }
    try Task.checkCancellation()
    guard !isStopped, !isItemBeingDeleted(documentID), let stored,
      stored.block == block, stored.sourceVersion == sourceVersion,
      stored.stateVersion == stateVersion, (stored.state ?? stored.block.initialState) == value,
      documents[documentID]?.sourceVersion(blockID: blockID) == sourceVersion,
      documents[documentID]?.blocks.first(where: { $0.id == blockID }) == block,
      documentStates[documentID]?.records.first(where: { $0.id == blockID }) == record else { return false }
    return true
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
          let liveDrafts = documentEditingSessions
          guard acceptExternalScene(prepared.scene, observedEpoch: epoch,
            observedPresence: presence, itemPins: itemPins) else {
            if inputGate.isActive || presencePhase == .active { externalReloadPending = true; return }
            diskRefreshRequested = true; continue
          }
          if draftEpoch != documentDraftEpoch { documentEditingSessions = liveDrafts }
          acceptCollaborationMetadata(actions: prepared.actions,
            contexts: prepared.contexts, delivery: prepared.delivery)
        } catch {
          publicationFailure = error.localizedDescription
          persistenceFailure = error.localizedDescription
          // A failed publication cannot masquerade as a still-pending write.
          // Its durable command remains available to undo/reopen normally.
          if graphicCommandPreviewCursor != nil { clearGraphicCommandPreview() }
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
        guard allowsCodexRegistration || acceptance != nil else {
          agentStartupError = "Запуск Codex из этого архива закрыт до безопасной активации пары. Действующие инструменты Notebook не перенаправлены."
          return
        }
        let installation = try CodexDesktopInstallation.discover()
        guard let entry = Bundle.main.resourceURL?.appendingPathComponent("NotebookTools/dist/index.mjs"),
          let commandSocketURL else { throw CodexBridgeError.notInstalled }
        let directory: URL
        let scope: CodexRuntimeScope?
        if let acceptance, let path = acceptance.codexDirectory {
          directory = URL(fileURLWithPath: path, isDirectory: true)
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
          scope = try CodexRuntimeScope(directory: directory, toolsEntry: entry, socket: commandSocketURL)
        } else {
          try await installation.registerNotebookTools(entry: entry, socket: commandSocketURL)
          directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Notebook/Codex", isDirectory: true)
          scope = nil
        }
        let sidecar = NotebookCodexSidecar(persistence: persistence, installation: installation,
          workspaceID: workspaceID, computerID: actorID, directory: directory, scope: scope) { [weak self] envelope, peer in
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
      if command.command == .script || command.command == .scriptContext {
        let coordinator = try scripts()
        if command.command == .script, let request = command.script {
          return try await coordinator.handle(request)
        }
        if command.command == .scriptContext, let request = command.scriptContext {
          return try await coordinator.context(request)
        }
        throw CollaborationError("invalid_script_request", "Запрос исполнения или контекста отсутствует.")
      }
      if command.command == .presentation {
        presentationRelay.send = { [weak self] message, peer in
          self?.sync?.sendTransient(.presentation(message), to: peer)
        }
        return try presentationRelay.handle(command)
      }
      let deadline = ContinuousClock.now.advanced(by: .seconds(4))
      while true {
        if command.command == .apply || command.command == .commitAction || command.command == .undo {
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

    private func scripts() throws -> NotebookScriptCoordinator {
      if let scriptCoordinator { return scriptCoordinator }
      guard let userService = Bundle.main.object(forInfoDictionaryKey: "NotebookScriptService") as? String,
        let markupService = Bundle.main.object(forInfoDictionaryKey: "NotebookMarkupService") as? String,
        !userService.isEmpty, !markupService.isEmpty else {
        throw CollaborationError("script_service_unavailable", "В сборке отсутствует изолированный исполнитель Notebook.")
      }
      let persistence = persistence
      let coordinator = NotebookScriptCoordinator(command: { [weak self] command in
        guard let self else { throw CollaborationError("owner_unavailable", "Notebook завершает работу.") }
        return try await self.executeLocalCommand(command)
      }, persistence: { operation in
        try await persistence.submit(publishesChanges: false, operation)
      }, workingDirectory: store.root.appendingPathComponent("derived/script-runtime", isDirectory: true),
        userServiceName: userService, markupServiceName: markupService)
      scriptCoordinator = coordinator
      return coordinator
    }
  #endif

  func receivePeerTransient(_ message: NotebookTransportTransient, peerID: UUID, generation: UUID) {
    guard !isClosing, peerGenerations[peerID] == generation else { return }
    switch message {
    case .presentation(let message):
      #if os(iOS)
        presentationPlayer.currentView = { [weak self] in
          guard let self, UIApplication.shared.applicationState == .active,
            chat?.files.window.isOpen != true, let envelope = lastSettledPresenceEnvelope else { return nil }
          return (actorID, envelope)
        }
        presentationPlayer.isInputActive = { [weak self] in
          guard let self else { return true }
          return inputGate.isActive || presencePhase != .settled || isClosing
        }
        presentationPlayer.reply = { [weak self] receipt, peer in
          self?.sync?.sendTransient(.presentation(.receipt(receipt)), to: peer)
        }
        presentationPlayer.receive(message, peer: peerID)
      #else
        if case .receipt(let receipt) = message { presentationRelay.receive(receipt, from: peerID) }
      #endif
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
        guard presenceSequenceTracker.accepts(envelope) else { return }
        presentationRelay.observe(envelope, from: peerID)
        let incoming = envelope.phase == .settled
          ? settledPresence(from: envelope.presence, viewport: envelope.presence.viewport)
          : envelope.presence
        guard presenceIsUsable(incoming) else { return }
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
        guard presence?.mode == .document, presence?.focusedItemID == request.documentID else { return }
        cancelRequestedNavigation()
        _ = selectDocumentPage(request.pageIndex, documentID: request.documentID, publishesRequest: false)
      #endif
    }
  }

  func publishHumanContext(_ selection: NotebookAttentionSelection, target: NotebookSelectionSession.Target = .context) {
    let actor = actorID
    let generation = replaceSelection(target, persistsDeselection: false)
    selectionSession.isResolvingContext = true
    persistence.enqueueCommand(publishesChanges: true, { store in
      do {
        let sealed = try selection.seal(in: store)
        let context = try store.appendContext(references: sealed.references, author: .human, actor: actor,
          select: true, sourceWorkspaceID: sealed.workspaceID)
        return (context, sealed)
      } catch {
        // A rejected new source must not reopen the previous choice on restart.
        try store.selectSharedContext(nil, actor: actor)
        throw error
      }
    }) { [weak self] result in
      Task { @MainActor [weak self] in
        guard let self else { return }
        let context: SharedContextAppend, sealed: NotebookAttentionSelection.Sealed
        do { (context, sealed) = try result.get() }
        catch {
          if self.selectionSession.id == generation { self.selectionSession.isResolvingContext = false; self.agentRequestError = error.localizedDescription }
          return
        }
        let entry = context.entry
        self.pinnedAttentionSelections.append((context.id, sealed.selection))
        if self.pinnedAttentionSelections.count > 2 { self.pinnedAttentionSelections.removeFirst() }
        self.reloadExternalChanges()
        guard self.selectionSession.id == generation else { return }
        self.selectionSession.isResolvingContext = false
        self.selectionSession.context = .init(contextID: context.id, entryID: entry.id, references: sealed.references)
        self.agentRequestError = nil
      }
    }
  }

  func selectSharedContext(_ id: UUID?) {
    let actor = actorID
    let generation = replaceSelection(id == nil ? nil : .context, persistsDeselection: false)
    selectionSession.isResolvingContext = id != nil
    selectionSession.context = id.flatMap { id in
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
        guard self.selectionSession.id == generation else { return }
        self.selectionSession.isResolvingContext = false
        do {
          if let id, let entry = try result.get(), entry.author == .human {
            self.selectionSession.context = .init(contextID: id, entryID: entry.id, references: entry.references)
          }
        } catch { self.agentRequestError = error.localizedDescription }
      }
    }
  }

  /// Close the local indication immediately and persist deselection in the
  /// same order as accepted pointing. History and running grants stay intact;
  /// neither a late pointer completion nor restart may reopen the fragment.
  func dismissAgentQuestion() { clearSelection() }

  #if os(iOS)
    func finishDictation(sending: Bool) {
      guard let chat else { return }
      guard sending else { chat.dictation.finish(); return }
      guard !isClosing, !isSavingAgentQuestion, !selectionSession.isResolvingContext else { return }
      let thread = chat.threadID, computer = chat.computerID
      let context = captureChatSubmissionContext(chat)
      chat.dictation.finish { [weak self, weak chat] in
        guard let self, let chat, self.chat === chat, chat.threadID == thread, chat.computerID == computer else { return }
        self.sendChatMessage(context: context) { [weak self, weak chat] saved in
          guard !saved, self?.isClosing == false, let chat, chat.threadID == thread, chat.computerID == computer else { return }
          chat.dictation.revealDraft()
        }
      }
    }

    /// Selection narrows attention, not the agent's tool authority. This value
    /// captures the physical owner and camera before any save/network suspension.
    enum ChatMessageSource {
      case draft
      case dictation(NotebookDictationController.Pending, String)
    }
    @discardableResult func sendChatMessage(steering: Bool = false, source: ChatMessageSource = .draft, context captured: ChatSubmissionContext? = nil, onSaved: (@MainActor (Bool) -> Void)? = nil) -> Task<Void, Never>? {
      guard !isClosing, let chat, let submittedThread = chat.threadID, !isSavingAgentQuestion,
        captured != nil || !selectionSession.isResolvingContext else { onSaved?(false); return nil }
      let submittedText: String, dictationID: UUID?
      switch source {
      case .draft:
        guard !chat.dictation.busy else { onSaved?(false); return nil }
        submittedText = chat.draft; dictationID = nil
      case .dictation(let recording, let text):
        guard chat.dictation.pending?.id == recording.id, recording.thread == submittedThread,
          recording.computer == chat.computerID else { onSaved?(false); return nil }
        submittedText = text; dictationID = recording.id
      }
      guard !submittedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { onSaved?(false); return nil }
      let submittedComputer = chat.computerID
      let submittedTurn = steering ? chat.conversation?.activeTurnID : nil
      if steering && submittedTurn == nil { onSaved?(false); return nil }
      isSavingAgentQuestion = true
      let captured = captured ?? captureChatSubmissionContext(chat)
      let task = Task { [self] in
        var saved = false
        defer { isSavingAgentQuestion = false; chatSubmissionTask = nil; onSaved?(saved) }
        do {
          let context = try await captured.prepare()
          guard chat.computerID == submittedComputer else { throw NotebookTransportError.disconnected }
          saved = await chat.sendMessage(threadID: submittedThread, text: submittedText, context: context.text,
            attentionContextID: context.attentionContextID, steeringTurnID: submittedTurn, attachments: captured.attachments,
            dictationID: dictationID)
        } catch { agentRequestError = error.localizedDescription }
      }
      chatSubmissionTask = task
      return task
    }

    struct ChatSubmissionContext {
      let attachments: [CodexInputAttachment]
      let prepare: @MainActor () async throws -> (text: String, attentionContextID: UUID?)
    }
    /// The send gesture freezes attention and attachments before transcription
    /// or image rendering can suspend. Both text and dictation use this owner.
    func captureChatSubmissionContext(_ chat: NotebookChatController) -> ChatSubmissionContext {
      let question = agentQuestion
      let retainedSource = question.flatMap { q in pinnedAttentionSelections.first { $0.0 == q.contextID }?.1 }
      let retained = retainedSource?.freezingSubmissionVisuals()
      let capturedPresence = presence, capturedWorkspace = workspaceHeader?.workspaceID
      let capturedFile = chat.files.window.isOpen ? chat.files.document : nil
      return .init(attachments: chat.attachments) { [self] in
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
          "meaning": .string("Read frozen attention inside notebook_execute with await nb.attention({contextID, referenceID}); use emitImage(result.artifact) when present. notebook_context gives compact current context; nb.help(topic) gives SDK and operation contracts. Shared Notebook workspace. Selection directs attention, not permissions. Use nb.reference, nb.transaction, nb.undo and nb.action for source/version checks, undoable edits and separate saved/received/shown receipts. For code notes use nb.code and the appendInkStroke operation on codeFragment. Use the returned notebook://code/UUID link, or fileLink with the required 1-based line query, in Markdown references. These links scroll only the document. A local draft is not yet the working file on Mac. Do not move the board camera.")
        ])
        let text = String(decoding: try JSONEncoder().encode(context), as: UTF8.self)
        return (text, question?.contextID)
      }
    }
  #endif

  func results(for action: NotebookActionReadModel) -> [CollaborationReference] {
    guard collaborationDetailsAreCurrent else { return [] }
    return collaborationReadSnapshot?.results[action.id] ?? []
  }

  func continuations(for action: NotebookActionReadModel) -> [CollaborationContinuation] {
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

  // Re-reading equal source values keeps the existing immutable projection.
  // Actual content, receipt/context or highlighted-reference changes invalidate
  // it. Scene reads keep their independent publication/admission ordering.
  var collaborationPreparationKey: CollaborationPreparationKey {
    .init(epoch: collaborationContentEpoch, permitsPreparation: permitsBackgroundPreparation)
  }

  var collaborationDetailsAreCurrent: Bool {
    collaborationReadSnapshot != nil && preparedCollaborationVersion == collaborationContentEpoch
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
      permitsBackgroundPreparation else { return }
    let version = collaborationContentEpoch
    // History describes accepted durable content. Drain the already accepted
    // input tail before its SQL read; a later input still invalidates the result.
    guard await finishPendingPersistence(boundary: .acceptedInput, continuing: {
      generation == self.collaborationReadGeneration && version == self.collaborationContentEpoch
        && self.permitsBackgroundPreparation
    }), !Task.isCancelled, generation == collaborationReadGeneration,
      version == collaborationContentEpoch, permitsBackgroundPreparation else { return }
    let actions = collaborationActions, store = store
    var references = sharedContexts.flatMap { $0.previewEntries.flatMap(\.references) }
    if let highlightedReference { references.append(highlightedReference) }
    let considered = references
    let worker = Task.detached(priority: .utility) {
      try CollaborationReadSnapshot(store: store, actions: actions, references: considered)
    }
    collaborationReadTask = worker
    let result = try? await withTaskCancellationHandler {
      try await worker.value
    } onCancel: { worker.cancel() }
    guard generation == collaborationReadGeneration else { return }
    collaborationReadTask = nil
    guard !Task.isCancelled, permitsBackgroundPreparation, version == collaborationContentEpoch, let result else { return }
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
    let version = collaborationContentEpoch
    let references = sharedContexts.flatMap { $0.previewEntries.flatMap(\.references) }.filter { $0.region != nil && $0.elementID == nil }
    let store = store
    let values = await Task.detached(priority: .utility) {
      guard !references.isEmpty else { return [(UUID, ReferenceStatus)]() }
      // The batch shares one WAL read, not a fresh connection/schema preparation
      // for every proof. No connection or result outlives this synchronous cut.
      return (try? store.readTransaction { store in
        references.compactMap { reference -> (UUID, ReferenceStatus)? in
          guard let revision = snapshot.references[reference.id]?.currentRevision else { return nil }
          return (reference.id, (try? store.referenceStatus(reference, currentRevision: revision)) ?? .init(.checking))
        }
      }) ?? []
    }.value
    guard !Task.isCancelled, permitsBackgroundPreparation, version == collaborationContentEpoch else { return }
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

  private func navigationObservationScope() -> [String: JSONValue] {
    guard NotebookNavigationObservation.enabled else { return [:] }
    return ["scopeID": .string(UUID().uuidString),
      "originGeneration": .string(String(navigationGeneration)),
      "originRequestID": requestedReference.map { .string($0.id.uuidString) } ?? .null,
      "originReturnID": requestedReturn.map { .string($0.id.uuidString) } ?? .null]
  }

  func observeNavigation(_ stage: String, reference: CollaborationReference? = nil,
    fields: [String: JSONValue] = [:]) {
    guard NotebookNavigationObservation.enabled else { return }
    var fields = fields
    fields["startupPending"] = .bool(startupTask != nil)
    fields["sceneReadPending"] = .bool(sceneWindowTask != nil)
    fields["diskReadPending"] = .bool(diskRefreshTask != nil)
    fields["headerReadPending"] = .bool(headerRefreshTask != nil)
    fields["writerPendingCount"] = .number(Double(persistence.pendingCount))
    fields["hasPublicationFailure"] = .bool(publicationFailure != nil)
    fields["collaborationReadEpoch"] = .string(String(collaborationReadEpoch))
    fields["workspaceCursor"] = workspaceHeader.map { .string(String($0.cursor)) } ?? .null
    NotebookNavigationObservation.record(stage, model: self, reference: reference, fields: fields)
  }

  func requestShow(_ reference: CollaborationReference) {
    observeNavigation("request_received", reference: reference)
    let replacesPendingShow = requestedReference != nil
    cancelRequestedNavigation()
    let generation = navigationGeneration
    if reference.target.kind == .document {
      let isOpen = presence?.mode == .document && presence?.focusedItemID == reference.target.id
        && (presence?.openProgress ?? 0) > 0
      documentMeasurements.request(documentID: reference.target.id, pageIndex: reference.pageIndex ?? 0,
        cause: isOpen ? .page : .open)
    }
    if reference.target.kind == .codeFragment {
      #if os(iOS)
        let id = reference.target.id
        Task { [weak self] in
          guard let self, let fragment = try? await persistence.submit({ try $0.codeFragment(id) }),
            !Task.isCancelled, !isStopped, navigationGeneration == generation else { return }
          inputGate.performAfterPageContact { [weak self] in
            guard let self, self.navigationGeneration == generation, !self.isStopped else { return }
            Task { [weak self] in
              guard let self, self.navigationGeneration == generation, !self.isStopped else { return }
              await self.chat?.files.navigate(to: fragment)
            }
          }
        }
      #endif
      return
    }
    if !replacesPendingShow, let presence,
      returnPlaces.last?.presence != presence {
      returnPlaces.append(.init(presence: presence, pageID: presence.notebookPageID,
        reading: presence.focusedItemID.flatMap { documentReadingPositions[$0] }))
      returnPlaces = Array(returnPlaces.suffix(32))
    }
    requestedReference = .init(target:reference.target,elementID:reference.elementID,region:reference.region,
      worldOrigin:reference.worldOrigin,pageIndex:reference.pageIndex,revision:reference.revision,label:reference.label)
    observeNavigation("request_published")
  }

  /// A new human action replaces pending navigation without consuming history
  /// or changing the current camera. Completion callbacks carry this generation.
  func cancelRequestedNavigation(reason: String = #function, source: String = #fileID, line: Int = #line) {
    observeNavigation("cancel", fields: ["reason": .string(reason), "source": .string(source), "line": .number(Double(line))])
    let requestID = requestedReference?.id ?? requestedReturn?.id
    navigationGeneration &+= 1
    requestedReference = nil
    requestedReturn = nil
    documentPageSelection = nil; documentPageNavigationStatus = nil
    cancelDocumentOpening()
    if let requestID { stopNavigationPresentation?(requestID) }
  }

  func resolveReferenceLocation(_ reference: CollaborationReference,
    apply: @MainActor (NotebookReferenceLocation) -> Void) async {
    observeNavigation("resolver_enter", reference: reference)
    defer { observeNavigation("resolver_exit", reference: reference) }
    let generation = navigationGeneration
    let isCurrent: @MainActor () -> Bool = { self.navigationGeneration == generation && self.requestedReference?.id == reference.id }
    if reference.target.kind == .page {
      guard await navigateToNotebookPage(id: reference.target.id, isCurrent: isCurrent) else {
        if !Task.isCancelled, !isStopped, isCurrent() { cancelRequestedNavigation() }
        return
      }
    }
    await resolveNavigationLocation(reference, isCurrent: isCurrent, apply: apply)
  }

  /// Resolve after the accepted input tail, then apply in this same actor
  /// segment. No delayed callback is allowed to retain an old physical address.
  private func finishNavigationInput(isCurrent: @MainActor () -> Bool) async -> Bool {
    let trace = navigationObservationScope()
    observeNavigation("input_fence_enter", fields: trace)
    defer { observeNavigation("input_fence_exit", fields: trace) }
    var observedContactWait = false
    while !Task.isCancelled, !isStopped, isCurrent() {
      // A held WebKit control or a physical pose tail also owns the current
      // view. Pencil's publication fence alone does not end those contacts.
      if inputGate.isActive {
        if !observedContactWait { observeNavigation("input_fence_wait_contact", fields: trace); observedContactWait = true }
        do { try await Task.sleep(for: .milliseconds(20)) } catch { return false }
        continue
      }
      guard await finishPendingInteraction(boundary: .acceptedInput, continuing: isCurrent) else { return false }
      guard !Task.isCancelled, !isStopped, isCurrent() else { return false }
      if !inputGate.isActive { return true }
    }
    return false
  }

  private func resolveNavigationLocation(_ reference: CollaborationReference,
    isCurrent: @MainActor () -> Bool,
    apply: @MainActor (NotebookReferenceLocation) -> Void) async {
    while !Task.isCancelled, !isStopped, isCurrent() {
      guard await finishNavigationInput(isCurrent: isCurrent) else {
        if !Task.isCancelled, !isStopped, isCurrent() { cancelRequestedNavigation() }
        return
      }
      guard !Task.isCancelled, !isStopped, isCurrent() else { return }
      let epoch = collaborationReadEpoch
      let pencilGeneration = inputGate.pencilGeneration
      do {
        observeNavigation("location_read_begin", reference: reference)
        let location = try await persistence.submit { try $0.readReferenceLocation(reference) }
        observeNavigation("location_read_end", reference: reference)
        guard !Task.isCancelled, !isStopped, isCurrent() else { return }
        guard epoch == collaborationReadEpoch, pencilGeneration == inputGate.pencilGeneration,
          !inputGate.isActive else { continue }
        switch location {
        case .board(let id, _, _):
          guard !isItemBeingDeleted(id) else {
            throw CollaborationError("reference_unavailable", "Место больше недоступно.", target: reference.target)
          }
        case .item(let boardID, let id, _, _):
          guard !isItemBeingDeleted(boardID), !isItemBeingDeleted(id) else {
            throw CollaborationError("reference_unavailable", "Место больше недоступно.", target: reference.target)
          }
        }
        observeNavigation("location_apply", reference: reference)
        apply(location)
        return
      } catch {
        guard !Task.isCancelled, !isStopped, isCurrent() else { return }
        observeNavigation("location_read_failure", reference: reference)
        cancelRequestedNavigation()
        showCue("Место недоступно: \(error.localizedDescription)")
        return
      }
    }
  }

  func requestReturnToPlace() {
    guard let place = returnPlaces.last else { return }
    cancelRequestedNavigation()
    requestedReturn = place
  }

  func resolveReturnToPlace(_ place: ReturnPlace, viewport: SpatialPoint,
    apply: @MainActor (SessionPresence, @escaping @MainActor () -> Void) -> Void) async {
    let generation = navigationGeneration
    let isCurrent: @MainActor () -> Bool = { self.navigationGeneration == generation && self.requestedReturn?.id == place.id }
    let saved = place.presence
    let target: CollaborationTarget
    if saved.mode == .page, let pageID = place.pageID {
      guard await navigateToNotebookPage(id: pageID, isCurrent: isCurrent) else {
        if !Task.isCancelled, !isStopped, isCurrent() { cancelRequestedNavigation() }
        return
      }
      target = .init(kind: .page, id: pageID)
    } else if let itemID = saved.focusedItemID {
      target = .init(kind: saved.mode == .document ? .document : .cover, id: itemID, boardID: saved.boardID)
    } else { target = .init(kind: .board, id: saved.boardID) }
    await resolveNavigationLocation(.init(target: target, revision: "return"), isCurrent: isCurrent) { location in
      let viewport = self.presence?.viewport ?? viewport
      let destination: SessionPresence
      switch location {
      case .board:
        destination = saved.adapted(to: viewport, geometry: .notebook)
      case .item(let boardID, let itemID, let center, let geometry):
        let adapted = saved.adapted(to: viewport, geometry: geometry)
        if saved.mode != .page { self.selectItem(itemID) }
        destination = .init(boardID: boardID, mode: adapted.mode,
          camera: boardID == saved.boardID ? adapted.camera : .init(center: center, scale: adapted.camera.scale),
          viewport: viewport, focusedItemID: itemID, openProgress: adapted.openProgress,
          documentPageIndex: adapted.documentPageIndex, selectedItemID: itemID,
          notebookPageID: saved.mode == .page ? place.pageID : nil)
      }
      if destination.mode == .document, let reading = place.reading {
        self.readingReturnPosition = reading; self.readingRestoreDocument = reading.documentID
        self.readingSuppressedDocument = nil; self.readingRestoreTarget = nil
      }
      apply(destination) { [weak self] in
        guard let self, self.navigationGeneration == generation else { return }
        self.completeReturnToPlace(place.id)
      }
    }
  }

  private func completeReturnToPlace(_ id: UUID) {
    guard requestedReturn?.id == id else { return }
    requestedReturn = nil
    if returnPlaces.last?.id == id { returnPlaces.removeLast() }
    if highlightedReference != nil { clearSelection() }
  }

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
    observeNavigation("show_complete", reference: reference)
    guard requestedReference?.id == reference.id else { return }
    requestedReference = nil
    let generation = replaceSelection(.reference(reference))
    referenceHighlightTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled else { return }
      guard let self, selectionSession.id == generation else { return }
      clearSelection()
    }
  }

  func finishAgentHighlight(_ actionID: UUID) { pendingAgentHighlights.remove(actionID) }

  func undoCollaboration(_ id: UUID) {
    guard collaborationUndoTask == nil else { return }
    collaborationUndoTask = Task { [weak self] in
      guard let self else { return }
      await withCheckedContinuation { continuation in
        inputGate.performAfterIdle { continuation.resume() }
      }
      let actor = actorID
      let result: Result<CollaborationReceipt, Error>
      do {
        result = .success(try await persistence.submit(publishesChanges: true) {
          try $0.undoCollaborationAction(id, actor: actor, waitForInput: 0)
        })
      } catch { result = .failure(error) }
      collaborationUndoTask = nil
      switch result {
      case .success(let receipt):
        for owner in Set(receipt.action.operations.map { $0.target.id }) {
          pencilUndoHistory.didUndoCommand(ownerID: owner, actionID: id)
        }
        reloadExternalChanges()
        showCue(receipt.undo?.preserved.isEmpty == false ? "Ход отменён. Ваши доработки сохранены" : "Ход отменён")
      case .failure(let error): showCue(error.localizedDescription)
      }
    }
  }

  private func collaborationRevision(_ target: CollaborationTarget) -> String? {
    switch target.kind {
    case .codeFragment: return nil // Visibility is acknowledged by the code viewport, never by the board.
    case .page: return pages[target.id]?.agentStamp.revision
    case .document: return documents[target.id]?.contentStamp.revision
    case .board: return boardContentRevisions[target.id]
    case .cover: return target.boardID.flatMap { boardContentRevisions[$0] }
    case .workspace: return workspace?.stamp.revision
    }
  }

  func confirmVisibleActions(presence visible: SessionPresence, scene: WorkspaceSceneWorkset? = nil,
    cohort: SceneCompositionCohort? = nil) {
    #if os(iOS)
      func matches(_ receipt: DeviceActionReceipt, _ action: NotebookActionReadModel) -> Bool {
        receipt.matches(action)
      }
      guard collaborationActions.contains(where: { action in !deviceActionReceipts.contains(where: { matches($0, action) && $0.displayComplete }) }),
        presencePhase == .settled, presence == visible, !isPointing,
        collaborationDetailsAreCurrent else { return }
      let receipts = deviceActionReceipts
      var changed: [DeviceActionReceipt] = []
      for action in collaborationActions.prefix(50) {
        guard var receipt = receipts.first(where: { matches($0, action) }), !receipt.displayComplete else { continue }
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
            if let page = pages[reference.target.id] { ready = pagePresentations.isPresented(page) }
            else { ready = false }
          case .document:
            if let document = documents[reference.target.id], let state = documentStates[document.id] {
              ready = DocumentRenderRegistry.shared.hasLiveSurface(document: document, state: state, pageIndex: visible.documentPageIndex,
                scope: reference.elementID.map(DocumentPresentationScope.block) ?? .page)
            } else { ready = false }
          case .board, .cover:
            ready = scene.map { sceneRepresents(reference, in: $0, cohort: cohort,
              presence: visible, inkRevision: expected.inkRevision) } ?? false
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

  /// This opportunity comes from the native board confirmation path. Prepared
  /// rasters or a SwiftUI appearance alone cannot start optional WebKit work.
  func prepareCommonDocumentShellIfIdle(presence visible: SessionPresence, cohort: SceneCompositionCohort?) {
    #if os(iOS)
      guard documentPreparationIsForeground, UIApplication.shared.applicationState == .active,
        !isClosing, permitsBackgroundPreparation, presence == visible,
        visible.openProgress <= 0, let cohort, cohort.isPaintInstalled,
        cohort.plan.rootBoardID == visible.boardID,
        compositionTiles.published === cohort else { return }
      if documentShellPreparation == nil || documentShellPreparation?.isStopped == true {
        let resources = SceneRenderResources.shared
        let owner = resources.documentShellPreparation ?? DocumentShellPreparation(resources: resources)
        documentShellPreparation = owner
        owner.onTransition = { [weak self] observation in
          self?.observeNavigation("common_shell_" + observation.event, fields: [
            "shellID": .string(observation.shellID.uuidString),
            "surfaceLeaseID": .string(observation.leaseID.uuidString),
            "webIdentity": observation.webIdentity.map(JSONValue.string) ?? .null,
            "commonRuntimeReady": .bool(observation.commonRuntimeReady)])
        }
      }
      documentShellPreparation?.prepareIfIdle()
    #endif
  }

  func setDocumentPreparationForeground(_ foreground: Bool) {
    guard documentPreparationIsForeground != foreground else { return }
    documentPreparationIsForeground = foreground
    if foreground { documentShellPreparation?.allowPreparationAfterForeground() }
    else { documentShellPreparation?.retireUnused() }
  }

  /// A cached image proves preparation, not mounting. The completed display
  /// callback supplies the actual admitted generation; an overview region
  /// cannot acknowledge that its detailed sources were shown.
  private func sceneRepresents(_ reference: CollaborationReference,
    in scene: WorkspaceSceneWorkset, cohort: SceneCompositionCohort?, presence: SessionPresence,
    inkRevision: String? = nil) -> Bool {
    guard let cohort, cohort.isPaintInstalled, scene.generationID == cohort.frame.index.generationID,
      cohort.plan.rootBoardID == presence.boardID else { return false }
    let sceneIndex = cohort.frame.index
    #if os(iOS)
      if let inkRevision {
        let surface: SurfaceID = reference.target.kind == .cover ? .cover(reference.target.id) : .board(reference.target.id)
        guard let canvas = compositionTiles.surfaceRegistry.canvas(for: surface),
          canvas.window?.isKeyWindow == true, canvas.isStableFramePresented,
          canvas.installedSpatialSource?.journalRevision == inkRevision else { return false }
      }
    #endif
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
    return elements.allSatisfy { element in
      if element.kind == .nativeText || element.kind == .graphic { return true }
      let plane: SceneCompositionPlane = reference.target.kind == .cover
        ? .cover(boardID: presence.boardID, itemID: reference.target.id) : .board(reference.target.id)
      let address = SceneSourceAddress(plane: plane, elementID: element.id)
      guard cohort.hasInstalledPixels(for: address), let receipt = cohort.sourceReceipts[address],
        receipt.hasCurrentPixels else { return false }
      return SceneRasterSource.agent(receipt.demand.source) == .agent(agentElementSnapshotSource(element))
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

  /// A completed SQL read observes the local content frontier from its request,
  /// not from its eventual callback. A later accepted move, stroke or selection
  /// invalidates that read even while the old pixels are still displayed.
  @discardableResult
  func acceptExternalScene(_ state: NotebookSceneState, observedEpoch: UInt64,
    observedPresence: SessionPresence, itemPins: [UUID: [UUID]]) -> Bool {
    guard !inputGate.isActive, presencePhase != .active,
      observedEpoch == collaborationReadEpoch, presence == observedPresence,
      itemPins == scenePinnedItems else { return false }
    acceptItemOwnerInvalidations(state, requested: itemPins)
    acceptSceneState(state)
    return true
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
    completeSceneCoverOwners = state.completeCoverElementOwners
    missingSceneElements = state.missingPinnedElements
    workspace = state.workspace
    boardHierarchy = state.hierarchy
    boardContentRevisions = state.boardContentRevisions
    spatialInk = state.ink
    loadedInkSurfaces = state.inkSurfaces
    pages = state.pages
    pageAddresses = Dictionary(uniqueKeysWithValues: state.pagePositions.map {
      (PageAddress(itemID: $0.itemID, index: $0.index, root: $0.visibleRoot), $0.pageID)
    })
    documents = state.documents
    documentStates = state.states
    documentEditingSessions = state.drafts
    admitDocumentReading(state.reading)
    presence = state.presence
    if let cursor = graphicCommandPreviewCursor, state.header.cursor >= cursor {
      clearGraphicCommandPreview()
    }
    alignWorkspaceSelection()
    if case .page(let pageID, let elementID) = selectionSession.element,
      let page = pages[pageID], !page.elements.contains(where: { $0.id == elementID }) {
      clearSelection()
    }
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

  private func acceptCollaborationMetadata(actions: [NotebookActionReadModel], contexts: SharedContextDirectory,
    delivery: [DeviceActionReceipt]) {
    if hasReadCollaborationActions {
      let known = Set(collaborationActions.map(\.id))
      pendingAgentHighlights.formUnion(actions.filter { !known.contains($0.id) && $0.undo == nil }.map(\.id))
      pendingAgentHighlights.formIntersection(actions.filter { $0.undo == nil }.map(\.id))
    }
    hasReadCollaborationActions = true
    if collaborationActions != actions { collaborationActions = actions }
    var prepared = contexts.contexts
    if let selected = contexts.selectedContext, !prepared.contains(where: { $0.id == selected.id }) {
      if prepared.count == 64 { prepared.removeLast() }
      prepared.append(selected)
    }
    if sharedContexts != prepared { sharedContexts = prepared }
    if !hasRestoredAgentQuestion {
      hasRestoredAgentQuestion = true
      if let context = prepared.first(where: { $0.id == contexts.selection?.contextID }),
        let entry = context.previewEntries.first(where: { $0.author == .human }) {
        selectionSession = .init(target: .context, context: .init(contextID: context.id, entryID: entry.id, references: entry.references))
      }
    }
    deviceActionReceipts = delivery
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
  func finishPendingInteraction(boundary: PersistenceBoundary = .quiescent,
    continuing: @MainActor () -> Bool = { true }) async -> Bool {
    let trace = navigationObservationScope()
    observeNavigation("interaction_finish_enter", fields: trace)
    defer { observeNavigation("interaction_finish_exit", fields: trace) }
    while true {
      guard !Task.isCancelled, continuing() else { return false }
      let generation = inputGate.pencilGeneration
      observeNavigation("page_input_finish_begin", fields: trace)
      await withCheckedContinuation { continuation in
        inputGate.performAfterPageInput { continuation.resume() }
      }
      observeNavigation("page_input_finish_end", fields: trace)
      guard !Task.isCancelled, continuing() else { return false }
      if presencePhase == .active, let presence { updatePresence(presence, settled: true) }
      if let documentID = presence?.focusedItemID, documents[documentID] != nil,
        !(await DocumentRenderRegistry.shared.finishEditing(documentID: documentID)) { return false }
      guard await finishPendingPersistence(boundary: boundary, continuing: continuing) else { return false }
      // The await itself is not a contact boundary: a later Pencil may have
      // started or even lifted while the preceding publication was draining.
      if !inputGate.hasActivePencil, generation == inputGate.pencilGeneration { return true }
    }
  }

  /// A completed wait is not a successful save: failures retain their writes
  /// and are returned to shutdown/cutover rather than disappearing with a cue.
  enum PersistenceBoundary {
    /// The accepted input tail, followed by one immutable writer FIFO cut.
    case acceptedInput
    /// Explicit cutover/shutdown also joins background publication owners.
    case quiescent
  }

  @discardableResult
  func finishPendingPersistence(boundary: PersistenceBoundary = .quiescent,
    continuing: @MainActor () -> Bool = { true }) async -> Bool {
    let trace = navigationObservationScope()
    observeNavigation("persistence_finish_enter", fields: trace)
    defer { observeNavigation("persistence_finish_exit", fields: trace) }
    guard !Task.isCancelled, continuing() else { return false }
    if let startupTask { observeNavigation("wait_startup_begin", fields: trace); await startupTask.value; observeNavigation("wait_startup_end", fields: trace) }
    guard !Task.isCancelled, continuing() else { return false }
    #if os(iOS)
      if chatSubmissionTask != nil { observeNavigation("wait_chat_submission_begin", fields: trace) }
      await chatSubmissionTask?.value
      observeNavigation("wait_chat_submission_end", fields: trace)
    #endif
    repeat {
      guard !Task.isCancelled, continuing() else { return false }
      observeNavigation("wait_accepted_ink_begin", fields: trace)
      guard await finishAcceptedPageInk() else { return false }
      observeNavigation("wait_accepted_ink_end", fields: trace)
      if let task = graphicCommandTask { await task.value }
      if let task = collaborationUndoTask { await task.value }
      guard !Task.isCancelled, continuing() else { return false }
      if boundary == .quiescent {
        if let task = diskRefreshTask { observeNavigation("wait_disk_refresh_begin", fields: trace); await task.value; observeNavigation("wait_disk_refresh_end", fields: trace) }
        guard !Task.isCancelled, continuing() else { return false }
        if let task = sceneWindowTask { observeNavigation("wait_scene_window_begin", fields: trace); await task.value; observeNavigation("wait_scene_window_end", fields: trace) }
        guard !Task.isCancelled, continuing() else { return false }
        if let task = headerRefreshTask { observeNavigation("wait_header_refresh_begin", fields: trace); await task.value; observeNavigation("wait_header_refresh_end", fields: trace) }
        guard !Task.isCancelled, continuing() else { return false }
        if let task = documentOpeningTask { await task.value }
        guard !Task.isCancelled, continuing() else { return false }
      }
      observeNavigation("writer_flush_begin", fields: trace)
      guard await persistence.flush() else { return false }
      observeNavigation("writer_flush_end", fields: trace)
      guard !Task.isCancelled, continuing() else { return false }
    } while boundary == .quiescent && (diskRefreshTask != nil || headerRefreshTask != nil || documentOpeningTask != nil || persistence.pendingCount > 0
      || pageInkPreparationTask != nil || acceptedPageInkHead != nil)
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
      cancelRequestedNavigation()
      cancelDocumentOpening()
      documentShellPreparation?.stop(); documentShellPreparation = nil
      presentationPlayer.interrupt("closing")
      if let startupTask { await startupTask.value }
      await cloudSync?.stop()
      if let sync, !(await sync.stopAndDrainTrust()) { return false }
      sync = nil
      #if os(macOS)
        await commandServer?.stopAndDrain(); commandServer = nil
        await codexSidecar?.stop(); codexSidecar = nil
        await scriptCoordinator?.shutdown(); scriptCoordinator = nil
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
      if let documentSaveObserver { DocumentRenderRegistry.shared.removeLiveObserver(documentSaveObserver) }
      documentSaveObserver = nil
      #if os(iOS)
        openDocumentPresentation?.close(); openDocumentPresentation = nil
        returnDocumentPresentation?.close(); returnDocumentPresentation = nil
      #endif
      shutdownPhase = .draining
      inputGate.onActivityChange = nil
      inputGate.onNewAcceptedContact = nil
      itemOwnerObserver = nil
      let readers = [scenePreparationTask, sceneWindowTask, diskRefreshTask, headerRefreshTask, documentOpeningTask]
        .compactMap { $0 } + Array(pagePreparationTasks.values)
      for task in readers { task.cancel() }
      for task in readers { await task.value }
      scenePreparationTask = nil; sceneWindowTask = nil; diskRefreshTask = nil; headerRefreshTask = nil
      documentOpeningTask = nil
      pagePreparationTasks = [:]
      collaborationReadTask?.cancel()
      if let task = collaborationReadTask { _ = await task.result }
      collaborationReadTask = nil
      pendingAgentHighlights.removeAll(); referenceHighlightTask?.cancel(); cueTask?.cancel()
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

  /// Camera settlement only adapts geometry. UUID existence, ownership and
  /// semantic mode belong to NotebookSceneState's addressed SQL snapshot; a
  /// bounded display projection cannot revoke a navigation destination.
  private func settledPresence(from presence: SessionPresence, viewport: SpatialPoint) -> SessionPresence {
    presence.adapted(to: viewport, geometry: itemGeometry(presence.focusedItemID))
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

  private func restoreSettledPresenceAfterDisconnect() {
    #if os(macOS)
      guard presencePhase == .active, let stored = lastSettledPresenceEnvelope?.presence else { return }
      presence = stored
      presencePhase = .settled
      alignWorkspaceSelection()
    #endif
  }

  private func presenceIsUsable(_ presence: SessionPresence) -> Bool {
    presence.isValid && !isItemBeingDeleted(presence.boardID)
      && (presence.focusedItemID.map { !isItemBeingDeleted($0) } ?? true)
  }

  private static func loadActorID(defaults: UserDefaults) -> UUID {
    let key = "notebook.actor-id"
    if let raw = defaults.string(forKey: key),
       let id = UUID(uuidString: raw) {
      return id
    }
    let id = UUID()
    defaults.set(id.uuidString, forKey: key)
    return id
  }

  private static func loadPenStyle(defaults: UserDefaults) -> PenStyle {
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

  private static func loadEraserStyle(defaults: UserDefaults) -> EraserStyle {
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
    preferences.set(penStyle.color.rawValue, forKey: "notebook.pen-color")
    preferences.set(penStyle.width, forKey: "notebook.pen-width")
    preferences.set(
      penStyle.minimumOpacity,
      forKey: "notebook.pen-minimum-opacity"
    )
  }

  private func saveEraserStyle() {
    preferences.set(
      eraserStyle.maximumWidth,
      forKey: "notebook.eraser-width"
    )
  }
}

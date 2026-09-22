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
  static let defaultPageSize = PageSize(
    width: WorkspaceItemGeometry.notebook.width,
    height: WorkspaceItemGeometry.notebook.height
  )

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
      elementErasureCache.retain(pages: pages)
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
  @ObservationIgnored weak var documentSourceEditor: DocumentSourceEditorSession?
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
      elementErasureCache.retain(hierarchy: boardHierarchy)
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
      elementErasureCache.invalidateSpatial()
      collaborationReadEpoch &+= 1
      if oldValue != spatialInk { collaborationContentEpoch &+= 1 }
    }
  }
  private(set) var loadedInkSurfaces: Set<SurfaceID> = []
  func renderingInk(on surface: SurfaceID, fallback: SpatialInkJournal?) -> SpatialInkJournal? {
    loadedInkSurfaces.contains(surface) ? spatialInk : fallback
  }
  var lassoMembershipRevision:UInt64 { collaborationContentEpoch }
  let compositionTiles: SceneCompositionTiles
  private(set) var sceneIndex: WorkspaceSceneIndex?
  private(set) var workspaceHeader: NotebookWorkspaceHeader?
  // Logical content admission, not the durable header-only refresh or GPU cohort.
  private(set) var sceneContentCursor: UInt64 = 0
  private(set) var spatialGroupReads: [UUID:[String:NotebookElementGroupRead]] = [:]
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
    let missingGroup = elements.contains { sceneIndex?.element(id:$0,boardID:presence.boardID)?.kind == .group && spatialGroupReads[presence.boardID]?[$0] == nil }
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
    if missingPin || missingGroup || missingItemPin || sceneCoverage[presence.boardID]?.contains(NotebookSceneState.bounds(for: presence, margin: 64)) != true {
      requestSceneCoverage(presence)
    }
    // An addressed pin is still being fetched. Do not turn the previous
    // partial index into a failed complete source for this new request.
    if missingPin || missingGroup || missingItemPin { compositionTiles.cancelPreparation(); return }
    guard permitsScenePreparation else { compositionTiles.cancelPreparation(); return }
    if scenePreparationPending {
      // Extending the same SQL cut must not cancel the image already on its
      // way to the screen. A changed content generation still invalidates it.
      if !scenePreparationIsCoverageOnly { compositionTiles.cancelPreparation() }
      return
    }
    guard let header = workspaceHeader, let frame else { return }
    let source = SceneCompositionSource(store: store, revision: header.cursor, workspaceID: header.workspaceID,groupPoses:compositionGroupPoses)
    compositionTiles.prepare(source: source, presence: presence, frame: frame, pinned: pinned,
      displayScale: displayScale, refinesDetails: presencePhase == .settled,
      permitsPreparation: { [weak self] in self?.permitsScenePreparation == true },
      onSourceInvalidated: { [weak self] in self?.reloadExternalChanges() })
  }

  private func clearRemovedElementPins(_ missing: [UUID: Set<String>], through cursor: UInt64) {
    for (boardID, missingIDs) in missing {
      // A coverage read made before an accepted insertion cannot declare its
      // new editing pin deleted. The existing causal command owns that frontier.
      let ids = missingIDs.filter { id in
        let reference = EditableElementReference.spatial(boardID:boardID,elementID:id)
        if ownsUnpublishedTextDraft(reference) { return false }
        guard let command = elementCommandSources[reference] else { return true }
        return command.cursor.map { $0 <= cursor } ?? false
      }
      scenePinnedElements[boardID] = scenePinnedElements[boardID]?.filter { !ids.contains($0) }
      if selectionSession.elements.contains(where: { reference in
        if case .spatial(let selectedBoard,let id) = reference { return selectedBoard == boardID && ids.contains(id) }; return false
      }) { clearSelection() }
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
            if permitsExternalScenePublication { reloadExternalChanges() }
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
          spatialGroupReads = state.groupReads
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
          clearRemovedElementPins(state.missingPinnedElements,through:state.header.cursor)
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

  /// Camera samples have a native owner on iPad. Keep the accepted value
  /// current for input and persistence, but do not invalidate the entire
  /// SwiftUI scene for every sample. Semantic changes and the terminal sample
  /// publish once through `presencePublication`.
  @ObservationIgnored private var presenceValue: SessionPresence?
  private var presencePublication: UInt64 = 0
  private(set) var presence: SessionPresence? {
    get { _ = presencePublication; return presenceValue }
    set { setPresence(newValue, publishes: true) }
  }

  private func setPresence(_ value: SessionPresence?, publishes: Bool) {
    let previous = presenceValue
    guard previous != value else { return }
    presenceValue = value
    #if os(iOS)
    nativeCameraProjection.update(value)
    let opened = value.flatMap { presence -> UUID? in
      guard presence.openProgress > 0, presence.mode == .document else { return nil }
      return presence.focusedItemID
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
    // Mounted paper observes ScenePlaneProjection.didProject directly.
    // Calling the registry here as well schedules the same visible-region
    // walk twice for every pinch sample.
    #endif
    if publishes { presencePublication &+= 1 }
    if previous?.boardID != value?.boardID || previous?.mode != value?.mode
      || previous?.focusedItemID != value?.focusedItemID || previous?.notebookPageID != value?.notebookPageID
      || previous?.documentPageIndex != value?.documentPageIndex {
      publishSelection()
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
      if let target = nativeTextTarget(reference) { prepareNativeTextEditing(target) }
      selectionSession.isInteractive = true
    }
  }
  func nativeTextTarget(_ reference: EditableElementReference) -> NotebookNativeTextTarget? {
    guard elementCommandDrafts[reference]?.removed != true else { return nil }
    if let target = selectionSession.nativeText, target.reference == reference { return target }
    guard let value = nativeElementSource(reference) else { return nil }
    if let page = value.page, page.kind == .nativeText {
      return .init(reference:reference,address:.init(surface:.page(value.target.id),boardID:nil,
        worldOrigin:nil,bounds:pages[value.target.id].map { .init(x:0,y:0,width:$0.size.width,height:$0.size.height) }),
        frame:elementCommandDrafts[reference]?.frame ?? page.frame,source:elementCommandDrafts[reference]?.textSource ?? page.source,
        style:elementCommandDrafts[reference]?.textStyle ?? page.textStyle ?? .standard,page:page,basis:elementCommandDrafts[reference]?.basis ?? page.basis)
    }
    if let stored = value.spatial, stored.kind == .nativeText {
      let spatial:SpatialElement
      if let draft=elementCommandDrafts[reference] {
        guard let projected=draft.projecting(stored) else { return nil };spatial=projected
      } else { spatial=stored }
      return .init(reference:reference,address:.init(surface:spatial.surface,boardID:value.target.boardID ?? value.target.id,
        worldOrigin:spatial.worldOrigin,bounds:spatial.surface.kind == .cover ? .init(x:0,y:0,width:itemGeometry(spatial.surface.ownerID).width,height:itemGeometry(spatial.surface.ownerID).height) : nil),frame:.init(x:spatial.frame.x,y:spatial.frame.y,width:spatial.frame.width,height:spatial.frame.height),
        source:spatial.source,style:spatial.textStyle,spatial:spatial,basis:spatial.basis)
    }
    return nil
  }

  func formatNativeText(_ reference: EditableElementReference, change: (inout NativeTextFormat) -> Void) {
    guard selectionSession.element == reference, !selectionSession.isInteractive,
      var target = nativeTextTarget(reference) else { return }
    var format = target.style.format ?? .init(); change(&format); target.style.format = format
    target.style.runs = target.style.runs?.map { run in var run = run; change(&run.format); return run }
    let fitted=NotebookTextTypography.fittingFrame(target.source,style:target.style,in:target.localFrame)
    guard (try? target.resizeBody(width:target.localFrame.width,height:max(1,min(fitted.height,target.maximumBodyHeight)))) != nil,
      let value=try? JSONValue.encode(target.style),let frame=try? JSONValue.encode(target.frame) else { return }
    var values:[String:JSONValue] = ["textStyle":value,"frame":frame]
    if let basis=target.basis { values["basis"] = try? .encode(basis) }
    guard performElementOperations([.init(reference:reference,kind:.updateElement,values:values)],summary:"Оформить текст") else { return }
    selectionSession.nativeText = target
  }

  /// A canvas tap finishes the current draft before the text tool can create
  /// another object. Teardown flushes the addressed editor, including early input.
  @discardableResult
  func consumeNativeTextCanvasTap(at point: CGPoint? = nil) -> Bool {
    guard selectionSession.isInteractive, let target = selectionSession.nativeText else { return false }
    if let point, let presence,
      NotebookAttentionProjection.nativeTextEditingFrame(target,model:self,presence:presence)?.contains(point) == true {
      return true
    }
    clearSelection()
    return true
  }
  private func ownsUnpublishedTextDraft(_ reference: EditableElementReference) -> Bool {
    guard let target = selectionSession.nativeText, target.reference == reference else { return false }
    return target.page == nil && target.spatial == nil
  }
  func prepareNativeTextEditing(_ target: NotebookNativeTextTarget) {
    guard selectionSession.element == target.reference else { return }
    var target = target
    // Existing transformed text keeps its local layout width. Plain short
    // text can still open room for another character in the current camera.
    if target.basis == nil,!target.hasParent {
      let width=min(target.address.bounds.map { $0.maxX-target.frame.x } ?? 1_000_000,
        max(target.frame.width,320/max(0.001,presence?.camera.scale ?? 1)))
      guard (try? target.resizeBody(width:max(1,width),height:target.localFrame.height)) != nil else { return }
    }
    selectionSession.nativeText = target
  }
  func measureNativeText(_ reference: EditableElementReference, height: Double) {
    guard selectionSession.nativeText?.reference == reference, var target = selectionSession.nativeText,
      height.isFinite, height > 0 else { return }
    let height=min(height,target.maximumBodyHeight)
    guard height>0,abs(target.localFrame.height-height)>0.5,
      (try? target.resizeBody(width:target.localFrame.width,height:height)) != nil else { return }
    selectionSession.nativeText = target
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
  let agentFeedback = NotebookAgentFeedback()
  private var referenceHighlightTask: Task<Void, Never>?
  private var collaborationUndoTask: Task<Void, Never>?
  private var contextPublicationTask: Task<Void, Never>?
  private var contextPublicationID: UUID?
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
  #if os(macOS)
  var macInputTool = MacNotebookInputTool.pointer
  #endif
  var drawingToolSettings = NotebookDrawingToolSettings() {
    didSet { if let data = try? JSONEncoder().encode(drawingToolSettings) { preferences.set(data,forKey:"notebook.drawing-tool-settings") } }
  }
  @ObservationIgnored lazy var drawingTools = NotebookDrawingToolController(model:self)
  var activePenStyle: PenStyle { drawingTool == .marker ? drawingToolSettings.marker : penStyle }
  private(set) var drawingTool: DrawingTool = .pen
  private(set) var selectionSession = NotebookSelectionSession() {
    didSet {
      if oldValue.highlightedReference != selectionSession.highlightedReference { collaborationContentEpoch &+= 1 }
      if oldValue.id != selectionSession.id || oldValue.target != selectionSession.target
        || oldValue.context != selectionSession.context || oldValue.isResolvingContext != selectionSession.isResolvingContext {
        publishSelection()
      }
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
  let laserContext = NotebookLaserContext()
  let inputGate: NotebookInputGate

  private(set) var notebookPageSize = defaultPageSize
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
  @ObservationIgnored private var pendingCollaborationCommands:[UUID:Task<Bool,Never>]=[:]
  private(set) var graphicCommandTask: Task<NotebookElementCommandResult?, Never>?
  @ObservationIgnored private var graphicCommandGeneration = UUID()
  @ObservationIgnored var workingGraphics: [NotebookWorkingGraphic] = []
  @ObservationIgnored var workingGraphicSignals:[SurfaceID:NotebookWorkingGraphicSignal] = [:]
  var workingElementErasures: [UUID: [NotebookElementErasing]] = [:] {
    didSet { elementErasureCache.invalidateWorking() }
  }
  @ObservationIgnored let elementErasureCache = NotebookElementErasureCache()
  // Lift transfers its final draft to the accepted command. It is retired by
  // a scene read at/after the durable cursor, not by lift or receipt delivery.
  var elementCommandDrafts: [EditableElementReference: NotebookElementCommandDraft] = [:]
  @ObservationIgnored var editingNativeTextReferences: Set<EditableElementReference> = []
  @ObservationIgnored var elementCommandSources: [EditableElementReference: NotebookElementCommand] = [:]
  var graphicCommandPending: Bool {
    graphicCommandTask != nil || !elementCommandDrafts.isEmpty || workingGraphics.contains { $0.accepted && $0.publicationCursor == nil }
  }
  private var reservedDrawingCounters: [UUID: UInt64] = [:]
  private struct DrawingReservationKey: Hashable { let pageID: UUID; let stamp: VersionStamp }
  @ObservationIgnored private var drawingReservations: [DrawingReservationKey: PageDocument] = [:]
  var pendingPageInkCommitCount: Int { persistence.pendingPageInkCount }
  var pendingPageDrawingReservationCount: Int { drawingReservations.count }
  private let presenceSessionID = UUID()
  private var presenceSequence: UInt64 = 0
  private var lastSettledPresenceEnvelope: PresenceEnvelope?
  #if os(macOS)
  private(set) var observedPeerID: UUID?
  private(set) var peerPresenceEnvelope: PresenceEnvelope?
  var observedPresence: SessionPresence? { observedPeerID == nil ? presence : peerPresenceEnvelope?.presence }
  var observedPresencePhase: PresencePhase { observedPeerID == nil ? presencePhase : peerPresenceEnvelope?.phase ?? .active }
  #endif
  private var presenceSequenceTracker = PresenceSequenceTracker()
  @ObservationIgnored private(set) var lastSelectionEnvelope: NotebookSelectionEnvelope?
  @ObservationIgnored private var selectionSequence: UInt64 = 0
  @ObservationIgnored private var selectionSurfaceIsActive = false
  private let startsNearbySync: Bool
  var cloudStatus = NotebookCloudStatus.off
  @ObservationIgnored private var cloudSync: NotebookCloudSync?
  @ObservationIgnored private var sync: NearbySync?
  private(set) var connectionState = NotebookConnectionState.waiting
  private(set) var accountConnection: NotebookAccountConnection?
  var workspaceName = "Моё пространство"
  var publishesWorkspaceName = false
  @ObservationIgnored var accountWorkspaceNameSaved: (@MainActor (String, Set<UUID>) -> Void)?
  @ObservationIgnored var workspaceDeleted: (@MainActor () -> Void)?
  @ObservationIgnored var openWorkspaceLibrary: (@MainActor (NotebookWorkspaceTab) -> Void)?
  @ObservationIgnored var openDefaultAccountWorkspace: (@MainActor (UUID) -> Void)?
  private let requiresExistingAccountContent: Bool
  private(set) var awaitingAccountContent = false
  @ObservationIgnored private var accountContentTask: Task<Void, Never>?
  private let opensDefaultAccountWorkspace: Bool
  private var initialAccountWorkspaceCursor: UInt64?
  private(set) var pairedPeers: [NotebookTransportIdentity] = []
  @ObservationIgnored private var peerGenerations: [UUID: UUID] = [:]
  #if os(iOS)
    @ObservationIgnored private let inputFrameMonitor: InputFrameMonitor?
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
  private var preparationIsForeground = true
  @ObservationIgnored private var programBoundaryTask: Task<Bool, Never>?
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
    preparationIsForeground && !isStopped && !peerInputIsActive && !inputGate.hasActivePencil
      && (!inputIsActive || presencePhase == .active || hasSpatialGroupContact)
      && !workingGraphics.contains { $0.surface.kind == .board && $0.accepted
        && ($0.publicationCursor.map { (workspaceHeader?.cursor ?? 0) < $0 } ?? true) }
  }
  #if os(macOS)
    @ObservationIgnored var codexHost: NotebookCodexHost?
    @ObservationIgnored private var codexSidecar: NotebookCodexSidecar?
    private(set) var localCodexEvent: NotebookChatEnvelope?
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
    opensDefaultAccountWorkspace: Bool = false,
    requiresExistingAccountContent: Bool = false,
    acceptance: NotebookAcceptanceConfiguration? = nil,
    persistenceQueue: NotebookPersistenceQueue? = nil
  ) {
    self.store = store
    self.allowsCodexRegistration = allowsCodexRegistration
    self.pairingActivationID = pairingActivationID
    self.preferences = preferences
    self.pairingService = pairingService
    self.opensDefaultAccountWorkspace = opensDefaultAccountWorkspace
    self.requiresExistingAccountContent = requiresExistingAccountContent
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
    persistence = persistenceQueue ?? NotebookPersistenceQueue(store: store)
    compositionTiles = SceneCompositionTiles()
    #if os(iOS)
      inputFrameMonitor = ProcessInfo.processInfo.arguments.contains("--notebook-profile-input")
        ? InputFrameMonitor(root: store.root) : nil
    #endif
    self.startsNearbySync = startsNearbySync
    penStyle = Self.loadPenStyle(defaults: preferences)
    eraserStyle = Self.loadEraserStyle(defaults: preferences)
    if let data = preferences.data(forKey:"notebook.drawing-tool-settings"),
      let settings = try? JSONDecoder().decode(NotebookDrawingToolSettings.self,from:data), settings.isValid { drawingToolSettings = settings }
    actorID = Self.loadActorID(defaults: preferences)
    #if os(macOS)
      self.commandSocketURL = commandSocketURL ?? (startsNearbySync ? NotebookIPC.defaultSocketURL : nil)
    #endif
    inputGate.bindNewContactAdmission { [weak self] in self?.shutdownPhase == .running }
    persistence.onFailureChange = { [weak self] message in
      guard let self else { return }
      persistenceFailure = message ?? publicationFailure
    }
    persistence.onContentMerged = { [weak self] in self?.reloadExternalChanges() }
    persistence.onCommit = { [weak self] owner in
      guard self?.isStopped == false else { return }
      self?.sync?.notifyDurableChanges()
      if let cloud = self?.cloudSync { Task { await cloud.notifyLocalChanges() } }
      switch owner {
      case .page, .pageInk, .document, .documentState, .board, .spatialInk, .elementState:
        self?.refreshCommittedHeader()
      case nil, .presence, .peerPresence, .inputActivity, .documentDraft, .documentReading, .fileDraft, .fileWindow, .chatPanel, .runCommand: break
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
        if active { inputFrameMonitor?.begin(mode: presence?.mode.rawValue ?? "unknown") }
        else { inputFrameMonitor?.end() }
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

  /// Connection identity is established by TLS and persisted account authorization.
  /// Only this generation may publish or release the peer's contact barrier.
  func peerConnected(_ peer: NotebookTransportIdentity, generation: UUID) {
    peerGenerations[peer.deviceID] = generation
    #if os(macOS)
      observedPeerID = peer.deviceID
      peerPresenceEnvelope = nil
      presenceSequenceTracker = PresenceSequenceTracker()
      enqueueStoreWrite(publishesChanges: false) { try $0.beginSelectionPublication(deviceID: peer.deviceID, connectionID: generation) }
    #endif
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
      publishSelection(force: true)
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
    enqueueStoreWrite {
      try $0.resetInputActivity(deviceID: peerID)
      try $0.endSelectionPublication(deviceID: peerID, connectionID: generation)
    }
    #if os(macOS)
      if observedPeerID == peerID {
        observedPeerID = nil; peerPresenceEnvelope = nil
      }
    #endif
  }

  private func startTrustedSync() async throws {
    guard sync == nil else { return }
    let workspaceID = try await persistence.submit { try $0.storedWorkspaceID() }
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
    let identity = NotebookTransportIdentity(deviceID: actorID, workspaceID: workspaceID, displayName: name)
    let trust = NotebookKeychainDeviceStore(activationID: pairingActivationID, service: pairingService)
    let retiredPeers = try await writer.submit { try $0.retiredReplicationPeers() }
    let connection = NearbySync(role: role, identity: identity,
      storage: storage, stagingRoot: store.root.appendingPathComponent("transfer-staging", isDirectory: true), trustStore: trust,
      retiredPeers: retiredPeers)
    connection.onStateChange = { [weak self] state in
      self?.connectionState = state
      self?.pairedPeers = self?.sync?.pairedPeers ?? []
      self?.knownDevices = self?.sync?.knownPeers ?? []
      self?.blockedDeviceIDs = self?.sync?.savedTrust.blocked ?? []
      #if os(iOS)
      self?.chat?.updateComputers(self?.pairedPeers ?? [])
      #endif
    }
    #if os(macOS)
    connection.onDeviceRevoked = { [weak self] id in self?.codexSidecar?.revokeDevice(id) }
    #endif
    connection.onConnect = { [weak self] peer, generation in self?.peerConnected(peer, generation: generation)
      #if os(macOS)
      self?.codexSidecar?.allowDevice(peer.deviceID)
      #endif
    }
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
    knownDevices = connection.knownPeers
    blockedDeviceIDs = connection.savedTrust.blocked
    await startAccountConnection(connection)
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
    if awaitingAccountContent { resumeAccountContent() } else { reloadExternalChanges() }
    if delivery.isSnapshot { sync?.receivedCheckpoint(from: delivery.source.deviceID) }
    return cursor
  }

  /// A new replica receives the existing scene; it must never manufacture a
  /// competing initial notebook (or resurrect a notebook the account deleted).
  private func resumeAccountContent() {
    guard accountContentTask == nil, !isClosing else { return }
    accountContentTask = Task { [weak self] in
      guard let self else { return }
      defer { self.accountContentTask = nil }
      await self.startupTask?.value
      guard !self.isClosing, self.awaitingAccountContent else { return }
      await self.loadInitialState(pageSize: self.notebookPageSize,
        viewport: .init(x: self.notebookPageSize.width, y: self.notebookPageSize.height))
    }
  }

  private func prepareCloudSync() async {
    guard cloudSync == nil else { return }
    do {
      let writer = persistence, actor = actorID
      let identity = try await writer.submit { store in
        try store.prepareCloudStorage()
        return try (store.replicationSource(deviceID: actor), store.storedWorkspaceID())
      }
      let cloud = NotebookCloudSync(store: store, writer: writer, source: identity.0, workspaceID: identity.1,
        apply: { [weak self] delivery, account in
          guard let self else { throw NotebookTransportError.disconnected }
          _ = try await self.applyDurableDelivery(delivery, cloudAccount: account)
        }, report: { [weak self] status in await self?.acceptCloudStatus(status) })
      cloudSync = cloud
      // Account connection alone authorizes automatic content sync.
      // No second account-discovery loop races the device owner.
    } catch { cloudStatus = .init(enabled: false, message: error.localizedDescription) }
  }

  private func acceptCloudStatus(_ value: NotebookCloudStatus) { cloudStatus = value }
  func enableCloud() async {
    if cloudSync == nil { await prepareCloudSync() }
    guard let account = accountConnection?.account else { return }
    await cloudSync?.enable(account: account)
  }
  func disableCloud() async { await cloudSync?.disable() }

  #if os(iOS)
  func chooseChatComputer(_ id: UUID) {
    inputGate.performAfterPageContact { [weak self] in Task { await self?.chat?.chooseComputer(id) } }
  }
  #endif

  private(set) var knownDevices: [NotebookTransportIdentity] = []
  private(set) var blockedDeviceIDs: Set<UUID> = []
  func deviceRouteTitle(_ id: UUID) -> String? { sync?.routeTitle(for: id) }
  func remoteAccessEnabled(_ id: UUID) -> Bool { sync?.remoteEnabled(for: id) ?? false }
  func configureRemoteAccess(_ id: UUID, route: NotebookRelayRoute?) async throws {
    guard let sync else { throw NotebookTransportError.disconnected }; try await sync.configureRelay(for: id, route: route)
  }
  func deviceIsConnected(_ id: UUID) -> Bool { peerGenerations[id] != nil }
  func deviceConnectsAutomatically(_ id: UUID) -> Bool { !blockedDeviceIDs.contains(id) }
  var canChangeDeviceConnections: Bool {
    switch accountConnection?.status {
    case .checking, .needsAccount, .accountChanged: false
    default: !isClosing
    }
  }
  func setDeviceAutomatic(_ id: UUID, allowed: Bool) async {
    guard canChangeDeviceConnections else { return }
    do { try await sync?.setDeviceAllowed(id, allowed: allowed) }
    catch { connectionState = .failed(error.localizedDescription) }
  }

  func mayAutomaticallySwitchWorkspace() async -> Bool {
    guard let baseline = initialAccountWorkspaceCursor, !isClosing, !inputGate.isActive,
      await finishPendingInteraction() else { return false }
    // finishPendingInteraction drained the writer. Read the bounded cursor in
    // this uninterrupted admission turn: an async submit can resume before its
    // own FIFO entry is retired and must not be mistaken for new user input.
    guard !isClosing, !inputGate.isActive, persistence.pendingCount == 0,
      pendingPageInkCommitCount == 0 else { return false }
    return (try? store.currentChangeCursor()) == baseline
  }

  func prepareAutomaticWorkspaceSwitch() async -> Bool {
    guard await mayAutomaticallySwitchWorkspace(), !isClosing, !inputGate.isActive,
      persistence.pendingCount == 0, pendingPageInkCommitCount == 0 else { return false }
    // Close input admission BEFORE the last SQL cut. A contact accepted while
    // CloudKit was answering keeps this space; it can never be left behind.
    shutdownPhase = .closing
    let cursor = try? await persistence.submit { try $0.currentChangeCursor() }
    guard cursor == initialAccountWorkspaceCursor else { shutdownPhase = .running; return false }
    return true
  }

  func automaticWorkspaceCutIsUnchanged() throws -> Bool {
    guard shutdownPhase == .stopped, let baseline = initialAccountWorkspaceCursor else { return false }
    return try store.currentChangeCursor() == baseline
  }

  var deviceStatusMessage: String {
    if isPeerConnected { return "Подключено" }
    if case .failed(let message) = connectionState { return message }
    switch accountConnection?.status {
    case .needsAccount: return "Войдите в iCloud в системных настройках."
    case .accountChanged: return "Apple Account изменился. Материалы сохранены на устройстве."
    case .failed(let message): return message
    case .checking: return pairedPeers.isEmpty ? "Ищем ваши устройства…" : "Подключаемся автоматически…"
    case .waitingForNetwork: return "Ожидаем сеть. Сохранение на устройстве работает."
    default: return pairedPeers.isEmpty ? "Откройте Notebook на своём Mac и iPad. Они подключатся автоматически." : "Устройство сейчас недоступно. Подключение восстановится автоматически."
    }
  }

  func refreshDeviceConnection() { accountConnection?.refresh(); sync?.resumeDiscovery() }

  private func startAccountConnection(_ connection: NearbySync) async {
    let service: any NotebookAccountService
    if let acceptance {
      guard let pair = acceptance.pair else { return }
      service = NotebookAcceptanceAccountService(configuration: acceptance, pair: pair)
    } else {
      guard let cloudSync else { return }
      service = NotebookAccountCloud(cloud: cloudSync)
    }
    #if os(iOS)
      let platform = NotebookAccountDirectory.Device.Platform.iPad
    #else
      let platform = NotebookAccountDirectory.Device.Platform.mac
    #endif
    let bound: String?
    do { bound = try await persistence.submit { try $0.cloudConfiguration().account } }
    catch {
      // Unknown is not unbound: an unreadable old account must never let its
      // retained credentials be promoted into whichever account is signed in.
      connectionState = .failed("Не удалось проверить настройки устройств. Локальное сохранение доступно.")
      return
    }
    guard !isClosing else { return }
    let account = NotebookAccountConnection(
      device: .init(identity: connection.identity, platform: platform, activation: pairingActivationID), sync: connection, service: service, initialBoundAccount: bound, spaceName: workspaceName, publishName: publishesWorkspaceName,
      workspaceDeleted: { [weak self] in self?.workspaceDeleted?() },
      shouldOpenDefault: { [weak self] in
        await self?.mayAutomaticallySwitchWorkspace() ?? false
      }, openWorkspace: { [weak self] id in self?.openDefaultAccountWorkspace?(id) },
      accountReady: { [weak self] account in
        guard let self, !self.isClosing else { return }
        if let name = self.accountConnection?.spaces.first(where: { $0.id == connection.identity.workspaceID })?.name {
          self.accountWorkspaceNameSaved?(name, self.accountConnection?.deletedSpaces ?? [])
        }
        await self.cloudSync?.connect(account: account)
      }, accountUnavailable: { [weak self] in await self?.cloudSync?.stop() })
    accountConnection = account
    account.start()
  }


  isolated deinit {
    if let documentSaveObserver { DocumentRenderRegistry.shared.removeLiveObserver(documentSaveObserver) }
    sync?.stop()
    if let accountConnection { Task { await accountConnection.stop() } }
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

  func start(pageSize: PageSize, viewport: SpatialPoint? = nil) async {
    guard !isStopped else { return }
    if let startupTask { await startupTask.value; return }
    guard !started else { return }
    started = true
    notebookPageSize = pageSize
    let startup = Task<Void, Never> { [weak self] in
      guard let self else { return }
      await loadInitialState(pageSize: pageSize,
        viewport: viewport ?? .init(x: pageSize.width, y: pageSize.height))
    }
    startupTask = startup
    await startup.value
    startupTask = nil
  }

  private func loadInitialState(pageSize: PageSize, viewport: SpatialPoint) async {
    do {
      if requiresExistingAccountContent {
        let hasScene = try await persistence.submit { store in try store.hasWorkspaceContent() }
        if !hasScene {
          awaitingAccountContent = true
          if startsNearbySync {
            await prepareCloudSync()
            try await startTrustedSync()
          }
          return
        }
      }
      let actor = actorID
      let notebookID = Self.initialNotebookID, pageID = Self.initialPageID
      let stored = try await persistence.submit { store in
        try NotebookSceneState.start(store: store, actor: actor, pageSize: pageSize,
          notebookID: notebookID, pageID: pageID, viewport: viewport)
      }
      acceptSceneState(stored)
      presence = settledPresence(from: stored.presence, viewport: viewport)
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
      // Initial presence is part of bootstrap too. Capture its durable cut
      // before making the scene editable, never after async service startup.
      if opensDefaultAccountWorkspace {
        initialAccountWorkspaceCursor = try await persistence.submit { try $0.currentChangeCursor() }
      }
      loadState = .ready
      publishSelection()
      awaitingAccountContent = false
      reloadCollaborationMetadata()
      reloadExternalChanges()
      #if os(macOS)
        try await scripts().start()
        try startCommandServer()
        startPreviewPublication()
      #endif
      #if os(iOS)
        #if DEBUG
        let approvalFixture = try await NotebookApprovalFixture.make(persistence: persistence, author: actorID, directory: store.root)
        #if targetEnvironment(simulator)
        let syncFixture = try await SimulatorChatFixture.make(persistence: persistence, author: actorID)
        #else
        let syncFixture: NotebookChatController? = nil
        #endif
        let terminalFixture = try await NotebookTerminalFixture.make(persistence: persistence, author: actorID, directory: store.root)
        let fixtureChat = approvalFixture ?? syncFixture ?? terminalFixture
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
      guard let selection = workspace.appendPage(in: notebookID, actor: actorID, pageSize: notebookPageSize),
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
      pageSize: notebookPageSize
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
      // Admission is synchronous with lift; the writer FIFO now owns it.
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
  func enterBoard(_ boardID: UUID) -> Bool {
    guard !isItemBeingDeleted(boardID), let workspace, let hierarchy = boardHierarchy, let presence else { return false }
    // The accepted catalog owns navigation. A derived image index may still
    // be preparing the newly created portal and cannot veto its identity.
    let item = workspace.item(id: boardID)
    let boardExists = hierarchy.board(boardID) != nil
    guard item?.kind == .board, boardExists else { return false }
    let portal = hierarchy.portalCamera(boardID) ?? BoardPortalCamera()
    let camera = BoardPortalProjection.entryCamera(portalCamera: portal, viewport: presence.viewport)
    selectItem(boardID)
    updatePresence(
      SessionPresence(
        boardID: boardID,
        mode: .board,
        camera: camera,
        viewport: presence.viewport
      ),
      settled: true
    )
    return true
  }

  /// Explicit Back stores the child's camera in its parent preview. Zoom never
  /// transfers navigation ownership.
  @discardableResult
  func leaveBoard() -> Bool {
    guard var hierarchy = boardHierarchy, let presence,
      let parentID = hierarchy.parentBoardID(of: presence.boardID),
      let center = hierarchy.focusedCenter(of: presence.boardID, in: parentID), center.isValid
    else { return false }
    let portalCamera = BoardPortalProjection.portalCamera(from: presence.camera, viewport: presence.viewport)
    let parentCamera = BoardPortalProjection.parentBoundaryCamera(portalCenter: center, viewport: presence.viewport)
    // A local passage changes only coordinates. When both physical owners are
    // already represented, its normalized camera must reach the very first
    // parent frame, rather than wait for a background metadata comparison.
    let carriesPreparedGeometry = sceneIndex?.board(id: presence.boardID)?.stamp == hierarchy.board(presence.boardID)?.stamp
      && sceneIndex?.board(id: parentID)?.stamp == hierarchy.board(parentID)?.stamp
    if hierarchy.updatePortalCamera(
      portalCamera,
      for: presence.boardID,
      actor: actorID
    ) {
      persistBoard(hierarchy)
    }
    if carriesPreparedGeometry {
      scenePortalCameras[presence.boardID] = portalCamera
    }
    selectItem(presence.boardID)
    updatePresence(
      SessionPresence(
        boardID: parentID,
        mode: .cover,
        camera: parentCamera,
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
    settled: Bool
  ) {
    guard presence.isValid else { return }
    let previous = self.presence
    let documentOwnerChanged = presence.mode != previous?.mode
      || presence.focusedItemID != previous?.focusedItemID
      || (presence.openProgress > 0) != ((previous?.openProgress ?? 0) > 0)
    if documentOwnerChanged {
      rememberDocumentReading()
      if documentPageSelection != nil { documentPageSelection = nil }
      if documentPageNavigationStatus != nil { documentPageNavigationStatus = nil }
      if documentPageController != nil { documentPageController = nil }
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
      resolved = constrainedPaperPresence(presence)
    }
    let inputOwnerChanged = previous?.boardID != resolved.boardID
      || previous?.mode != resolved.mode
      || previous?.focusedItemID != resolved.focusedItemID
    if inputOwnerChanged { endSurfaceEditing() }
    else if previous?.camera != resolved.camera || previous?.viewport != resolved.viewport { cancelElementManipulation() }
    let onlyCameraChanged = previous.map { $0.replacingCamera(resolved.camera) == resolved } == true
    setPresence(resolved, publishes: settled || !onlyCameraChanged)
    if previous?.selectedItemID != resolved.selectedItemID || previous?.notebookPageID != resolved.notebookPageID {
      alignWorkspaceSelection()
    }
    // Explicit navigation can change the owner during an active contact. Transfer
    // its publication barrier with that owner, not with each camera frame.
    if inputIsActive && inputOwnerChanged { publishInputActivity() }
    let phase = settled ? PresencePhase.settled : .active
    if presencePhase != phase { presencePhase = phase }
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
    return itemGeometry(documentID).readingCamera(
      .init(center: position, scale: fit * reading.zoomRatio), centeredOn: center, viewport: viewport)
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

  /// Requests preparation. Only the bound native controller's verified landing
  /// writes this device's page presence; navigation never commands another screen.
  @discardableResult
  func selectDocumentPage(_ pageIndex: Int, documentID: UUID,
    restoresReading: Bool = false) -> Int? {
    guard !isClosing, !isItemBeingDeleted(documentID), pageIndex >= 0,
      pageIndex <= DocumentPageNavigationRequest.maximumPageIndex,
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
    documentPageSelection = .init(id: UUID(), documentID: documentID,
      sourceRevision: source, pageIndex: pageIndex)
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
      landing.pageIndex <= DocumentPageNavigationRequest.maximumPageIndex,
      let presence else { return false }
    documentPageLandingRevision = landing.revision
    if let target = readingRestoreTarget, target.id == landing.documentID,
      target.page == landing.pageIndex, documents[target.id]?.contentStamp == target.stamp {
      readingRestoreTarget = nil
    }
    // A is still the actual landing when B superseded its request. A may
    // publish that fact, but cannot clear B or restore an obsolete intent.
    if documentPageSelection?.id == landing.requestID {
      // Readiness is replayed into a new native callback after a view update.
      // Publishing nil over nil here would schedule that same update again.
      if documentPageSelection != nil { documentPageSelection = nil }
      if documentPageNavigationStatus != nil { documentPageNavigationStatus = nil }
    }
    if presence.documentPageIndex != landing.pageIndex {
      applyPresence(.init(boardID: presence.boardID, mode: presence.mode,
        camera: presence.camera, viewport: presence.viewport, focusedItemID: landing.documentID,
        openProgress: presence.openProgress, documentPageIndex: landing.pageIndex,
        selectedItemID: presence.selectedItemID, notebookPageID: presence.notebookPageID), settled: true)
    }
    if presencePhase == .settled { rememberDocumentReading() }
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
    spans: [SpatialInkSpan],
    id: UUID = UUID()
  ) -> SpatialInkAction? {
    guard spans.allSatisfy({ surfaceAcceptsChanges($0.surface) }), var journal = spatialInk,
      let action = journal.append(
        tool: tool,
        color: color,
        spans: spans,
        actor: actorID,
        id: id
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
    guard inputGate.permitsNewContact, !inputGate.hasActivePencil else { return }
    if presence?.mode == .document {
      guard let owner = presence?.focusedItemID else { return }
      let restored = collaborationActions.first {
        $0.author == .human && $0.undo == nil && $0.action.operations.contains {
          $0.target == CollaborationTarget(kind: .document, id: owner) && [.updateBlock, .setPreamble].contains($0.kind)
        }
      }?.id
      if let command = pencilUndoHistory.lastCommand(for: owner) ?? restored { undoCollaboration(command) }
      return
    }
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

  /// Creation, typing and geometry share the same addressed causal queue.
  /// Late editor teardown can finish its original object, never the new page.
  func commitNativeText(reference: EditableElementReference, text: String, finish: Bool,
    retainedPage: AgentElement? = nil, retainedSpatial: SpatialElement? = nil, height: Double? = nil,
    style: NativeTextStyle? = nil, draftTarget: NotebookNativeTextTarget? = nil) {
    defer { if finish { endNativeTextEditing(reference) } }
    let retained: NotebookNativeElementSource?
    switch reference {
    case .page(let owner,let id): retained = retainedPage.map { .init(target:.init(kind:.page,id:owner),id:id,page:$0) }
    case .spatial(let owner,let id): retained = retainedSpatial.map {
      .init(target:.init(kind:$0.surface.kind == .cover ? .cover : .board,id:$0.surface.kind == .cover ? $0.surface.ownerID! : owner,
        boardID:$0.surface.kind == .cover ? owner : nil),id:id,spatial:$0)
    }
    }
    var values: [String:JSONValue] = ["source":.string(text),"html":.string(text)]
    if let style { values["textStyle"] = try? .encode(style) }
    let live = nativeElementSource(reference)
    let source = live?.page != nil || live?.spatial != nil ? live : retained ?? live
    let draftTarget = draftTarget ?? (selectionSession.nativeText?.reference == reference ? selectionSession.nativeText : nil)
    var geometry=draftTarget ?? nativeTextTarget(reference)
    if geometry == nil,let source,let placement=source.placementSource {
      let surface:SurfaceID = source.page.map { _ in .page(source.target.id) } ?? source.spatial!.surface
      geometry = .init(reference:reference,address:.init(surface:surface,boardID:source.target.boardID ?? (source.spatial == nil ? nil : source.target.id),
        worldOrigin:source.spatial?.worldOrigin,bounds:nil),frame:placement.frame,source:text,
        style:style ?? source.page?.textStyle ?? source.spatial?.textStyle ?? .standard,page:source.page,spatial:source.spatial,basis:placement.basis)
    }
    if var target=geometry {
      let requested=height.flatMap { $0.isFinite && $0>0 ? $0 : nil }
        ?? NotebookTextTypography.fittingFrame(text,style:style ?? target.style,in:target.localFrame).height
      guard (try? target.resizeBody(width:target.localFrame.width,height:max(1,min(target.maximumBodyHeight,requested)))) != nil else { return }
      values["frame"] = try? .encode(target.frame)
      if let basis=target.basis { values["basis"] = try? .encode(basis) }
      geometry=target
    }
    let removes = finish && text.isEmpty
    let inserting = source?.page == nil && source?.spatial == nil && elementCommandSources[reference] == nil
    if inserting {
      guard !text.isEmpty, let draftTarget else { return }
      values["kind"] = .string("nativeText")
      values["frame"] = values["frame"] ?? (try? .encode(draftTarget.frame))
      values["textStyle"] = try? .encode(style ?? draftTarget.style)
      if let origin = draftTarget.address.worldOrigin { values["worldOrigin"] = try? .encode(origin) }
    }
    guard performElementOperations([.init(reference:reference,kind:removes ? .removeElement : inserting ? .insertElement : .updateElement,
      values:removes ? [:] : values)],summary:inserting ? "Добавить текст" : "Изменить текст",
      insertionTarget:inserting ? draftTarget?.address.target : nil,
      retainedSources:retained.map { [reference:$0] } ?? [:]) else { return }
    if var target = selectionSession.nativeText, target.reference == reference {
      target.source = text
      if let style { target.style = style }
      if let geometry { target.frame=geometry.frame;target.basis=geometry.basis }
      selectionSession.nativeText = target
    }
    if !finish { editingNativeTextReferences.insert(reference) }
    // The command draft owns accepted content until its SQL scene is admitted.
  }

  func endNativeTextEditing(_ reference: EditableElementReference) {
    editingNativeTextReferences.remove(reference)
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
  /// advances the retained vector journal before storage can suspend.
  func acceptDrawingAction(
    _ action: PageInkAction,
    pageID: UUID,
    stamp: VersionStamp,
    quickShape: NotebookQuickShapeFit? = nil
  ) -> PreparedPageInkChange? {
    acceptInkMutation(.append(action),pageID:pageID,stamp:stamp,quickShape:quickShape)
  }

  private func acceptInkMutation(_ mutation:PageInkMutation,pageID:UUID,stamp:VersionStamp,
    quickShape:NotebookQuickShapeFit? = nil) -> PreparedPageInkChange? {
    guard let retained=drawingReservations.removeValue(forKey:.init(pageID:pageID,stamp:stamp)),
      !isPageBeingDeleted(pageID) else {
      if case .append(let action)=mutation { updateWorkingGraphic(nil,strokeID:action.id) }
      return nil
    }
    let page=pages[pageID] ?? retained
    if case .append(let action)=mutation,let targets=action.elementTargets {
      workingElementErasures[action.id] = [.init(id: action.id, surface: .page(pageID),
        samples: action.samples, targets: targets, accepted: true)]
    }
    do {
      let change=try page.prepareInkChange(mutation,stamp:stamp)
      guard change.stamp != change.baseStamp,page.publishLiveInkChange(change) else {
        if case .append(let action)=mutation { workingElementErasures[action.id]=nil }
        return change
      }
      collaborationReadEpoch &+= 1;collaborationContentEpoch &+= 1
      elementErasureCache.record(change)
      switch change.mutation {
      case .append(let action):
        workingElementErasures[action.id]=nil
        pencilUndoHistory.recordAction(ownerID:pageID,actionID:action.id)
        if let quickShape { acceptQuickShape(quickShape,pageID:pageID,stroke:action) }
      case .remove(let ids):
        pencilUndoHistory.didRemoveContribution(ids,for:pageID)
        // Undo and sync replace visible state; ordinary Pencil-up already
        // installed its exact delta in the native canvas.
        if pages[pageID] != nil { pages[pageID]=page }
        showCue("Отменено")
      }
      let command=NotebookPageInkCommand(change)
      persistence.enqueue(owner:.pageInk(pageID)) { store in
        try store.commitPageInk(pageID:pageID,command:command).stamp != change.stamp
      }
      return change
    } catch {
      if case .append(let action)=mutation {
        workingElementErasures[action.id]=nil;updateWorkingGraphic(nil,strokeID:action.id)
      }
      persistenceFailure=error.localizedDescription
      return nil
    }
  }

  /// Lasso borrows the same retained vector root advanced at Pencil-up.
  func lassoInkSnapshot(_ page: PageDocument) -> Task<NotebookLassoInkSource?,Never> {
    Task { .page(page,pending:[]) }
  }

  /// Undo resolves its target and writes the inverse into the same journal in
  /// the button's actor segment; storage follows in the ordinary FIFO.
  func acceptDrawingUndo() -> PreparedPageInkChange? {
    guard inputGate.permitsNewContact, !inputGate.hasActivePencil,
      let page=activePage,let ids=pencilUndoHistory.lastContribution(for:page.id),
      let stamp=reserveDrawingAction(pageID:page.id) else { return nil }
    return acceptInkMutation(.remove(ids),pageID:page.id,stamp:stamp)
  }

  // The toolbar projects the active tool’s stored color, never a second copy.
  var drawingColor: PenColor {
    switch drawingTool {
    case .marker: drawingToolSettings.markerColor
    case .shape: drawingToolSettings.shapeColor
    case .text: drawingToolSettings.textColor
    case .connector: drawingToolSettings.connectionColor
    case .laser: drawingToolSettings.laserColor
    case .pen, .ruler, .eraser, .lasso: penStyle.color
    }
  }
  func selectDrawingColor(_ color: PenColor) {
    switch drawingTool {
    case .marker: drawingToolSettings.markerColor = color
    case .shape: drawingToolSettings.shapeColor = color
    case .text: drawingToolSettings.textColor = color
    case .connector: drawingToolSettings.connectionColor = color
    case .laser: drawingToolSettings.laserColor = color
    case .pen, .ruler:
      guard color != penStyle.color else { return }
      penStyle = PenStyle(color:color,width:penStyle.width,minimumOpacity:penStyle.minimumOpacity)
      savePenStyle()
    case .eraser, .lasso: break
    }
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
    drawingTools.cancel()
    clearSelection()
    drawingTool = tool
    if tool == .ruler { drawingTools.placeRuler() }
  }

  /// All local admissions invalidate previous asynchronous selection work.
  /// History is retained, but its selected pointer follows this same ordered writer.
  @discardableResult
  private func replaceSelection(_ target: NotebookSelectionSession.Target?,
    persistsDeselection: Bool = true) -> UUID {
    for (_, retained) in pinnedAttentionSelections { retained.resumePrograms() }
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

  func selectElements(_ references: [EditableElementReference], items: [NotebookSelectedItem] = []) {
    let refs = Array(Set(references)).sorted { String(describing:$0) < String(describing:$1) }
    let items = Array(Set(items)).sorted { $0.itemID.uuidString < $1.itemID.uuidString }
    guard refs.count+items.count <= 32 else { showCue("Выберите не более 32 объектов за один раз."); return }
    if items.isEmpty { replaceSelection(refs.isEmpty ? nil : refs.count == 1 ? .element(refs[0]) : .elements(refs)) }
    else if refs.isEmpty, items.count == 1 { replaceSelection(.item(boardID:items[0].boardID,itemID:items[0].itemID)) }
    else { replaceSelection(.elements(refs,items:items)) }
  }

  func selectRegion(_ region: NotebookRegionSelection) {
    replaceSelection(.region(region))
  }

  func resolveRegionPreparation(_ region:NotebookRegionSelection) {
    guard selectionSession.region?.id == region.id,region.materialization != nil else { return }
    selectionSession.target = .region(region)
    if var contact=selectionSession.manipulation,contact.reference == region.reference {
      contact.region=region;selectionSession.manipulation=contact
      if contact.regionGestureEnded { _ = finishRegionManipulation(contact) }
      else { updateRegionPreview(contact) }
    }
  }

  func beginMultipleSelection() {
    guard let reference = selectionSession.element, graphicElement(reference) != nil else { return }
    selectionSession.addingElements = true
  }

  func finishMultipleSelection() { selectionSession.addingElements = false }
  func setMultipleSelectionAdding(_ adding: Bool) { selectionSession.addingElements = adding }

  /// Additive picking is an explicit editing mode, never a second recognizer.
  /// All members remain on the same physical page/cover/board.
  func graphicSelectionToggling(_ reference: EditableElementReference) -> [EditableElementReference]? {
    guard selectionSession.addingElements, let graphic = graphicElement(reference), graphic.showsGeometry,
      let target = nativeElementSource(reference)?.target,
      selectionSession.elements.allSatisfy({ nativeElementSource($0)?.target == target }) else { return nil }
    var refs = selectionSession.elements
    if let index = refs.firstIndex(of:reference) { refs.remove(at:index) }
    else if refs.count < 32 { refs.append(reference) }
    else { showCue("Выберите не более 32 объектов за один раз."); return nil }
    return refs
  }

  func toggleGraphicSelection(_ reference: EditableElementReference) {
    guard let refs = graphicSelectionToggling(reference) else { return }
    guard !refs.isEmpty else { clearSelection(); return }
    replaceSelection(refs.count == 1 ? .element(refs[0]) : .elements(refs))
    selectionSession.addingElements = true
  }

  private func selectedGraphicMembers() -> [NotebookGraphicSelection.Member]? {
    let refs = selectionSession.elements
    guard selectionSession.items.isEmpty,let first=refs.first,let target=nativeElementSource(first)?.target,
      refs.allSatisfy({ nativeElementSource($0)?.target == target }),let graph=editingGraphicGraph(first) else { return nil }
    let members = refs.compactMap { reference -> NotebookGraphicSelection.Member? in
      guard let graphic = graphicElement(reference), graphic.showsGeometry,
        let geometry = elementGeometry(reference),let resolved=graphicManipulationGeometry(reference,in:graph),
        let source = nativeElementSource(reference) else { return nil }
      if case .spatial = reference, let cohort = compositionTiles.published,
        presentedElement(reference,cohort:cohort) == nil,acceptedWorkingGraphic(reference) == nil { return nil }
      return .init(id:source.id,frame:.init(x:geometry.frame.minX,y:geometry.frame.minY,width:geometry.frame.width,height:geometry.frame.height),
        graphic:graphic,layout:resolved.display,body:resolved.body,placement:resolved.placement)
    }
    return members.count == refs.count ? members : nil
  }

  @discardableResult
  private func applySelectionEdits(_ edits: [NotebookGraphicSelection.Edit], summary: String) -> Bool {
    let byID = Dictionary(uniqueKeysWithValues:selectionSession.elements.compactMap { reference in
      nativeElementSource(reference).map { ($0.id,reference) }
    })
    do {
      let operations = try edits.compactMap { edit -> NotebookElementEdit? in
        guard let reference = byID[edit.id], let geometry = elementGeometry(reference),
          let graphic = graphicElement(reference) else { return nil }
        var values: [String:JSONValue] = [:]
        let frame = PageRect(x:geometry.frame.minX,y:geometry.frame.minY,width:geometry.frame.width,height:geometry.frame.height)
        if frame != edit.frame { values["frame"] = try .encode(edit.frame) }
        if (elementCommandDrafts[reference]?.basis ?? nativeElementSource(reference)?.placementSource?.basis) != edit.basis {
          values["basis"] = try .encode(edit.basis)
        }
        var patch: [String:JSONValue] = [:]
        if graphic.connection != edit.graphic.connection { patch["connection"] = try .encode(edit.graphic.connection) }
        if graphic.transform != edit.graphic.transform { patch["transform"] = try .encode(edit.graphic.transform) }
        if graphic.style != edit.graphic.style { patch["style"] = try .encode(edit.graphic.style) }
        if graphic.cornerRadius != edit.graphic.cornerRadius { patch["cornerRadius"] = try .encode(edit.graphic.cornerRadius) }
        if !patch.isEmpty { values["graphic"] = .object(patch) }
        return values.isEmpty ? nil : .init(reference:reference,kind:.updateElement,values:values)
      }
      let sources=selectionSession.elements.flatMap { reference in
        [reference]+(editingGraphicGraph(reference)?.placement(reference.elementID)?.ancestors ?? []).map { id in
          switch reference { case .page(let owner,_): EditableElementReference.page(pageID:owner,elementID:id)
            case .spatial(let owner,_): EditableElementReference.spatial(boardID:owner,elementID:id) }
        }
      }
      return operations.isEmpty || performElementOperations(operations,summary:summary,readSources:Array(Set(sources)))
    } catch { showCue(error.localizedDescription); return false }
  }

  func alignGraphicSelection(_ alignment: NotebookGraphicSelection.Alignment) {
    guard let members = selectedGraphicMembers() else { return }
    _ = applySelectionEdits(NotebookGraphicSelection.aligned(members,to:alignment),summary:"Выровнять фигуры")
  }

  func transformGraphicSelection(radians: Double = 0, scale: Double = 1) {
    if let region=selectionSession.region { transformRegion(region,radians:radians,scale:scale);return }
    if transformSelectedGroup(radians:radians,scale:scale) { return }
    guard let members = selectedGraphicMembers(), let first = selectionSession.elements.first else { return }
    let edits = NotebookGraphicSelection.transformed(members,radians:radians,scale:scale)
    if let bounds = elementGeometry(first)?.bounds,
      edits.contains(where: { !bounds.contains(CGRect(x:$0.frame.x,y:$0.frame.y,width:$0.frame.width,height:$0.frame.height)) }) {
      showCue("Для этого поворота или масштаба не хватает места на листе."); return
    }
    _ = applySelectionEdits(edits,summary:radians == 0 ? "Масштабировать выделение" : "Повернуть выделение")
  }

  func duplicateGraphicSelection() {
    if let region=selectionSession.region,let prepared=region.materialization {
      let f=region.frame,bounds=region.address.bounds
      let offset=SpatialPoint(x:min(24,max(0,bounds.map { $0.maxX-f.x-f.width } ?? 24)),
        y:min(24,max(0,bounds.map { $0.maxY-f.y-f.height } ?? 24)))
      do { _ = commitRegion(region,prepared:try prepared.copying(offset:offset,address:region.address),summary:"Дублировать область лассо") }
      catch { showCue(error.localizedDescription) };return
    }
    guard let members = selectedGraphicMembers(), let first = selectionSession.elements.first else { return }
    let sources = selectionSession.elements
    // Page placement is clamped as a whole; a copied construction is never
    // squeezed or partly moved beyond the physical sheet.
    var offset = SpatialPoint(x:24,y:24)
    if let bounds = elementGeometry(first)?.bounds {
      let right = members.map { $0.frame.x+$0.frame.width }.max()!, bottom = members.map { $0.frame.y+$0.frame.height }.max()!
      offset = .init(x:min(24,max(0,bounds.maxX-right)),y:min(24,max(0,bounds.maxY-bottom)))
    }
    let visibleMembers=members.map { member -> NotebookGraphicSelection.Member in
      guard let reference=sources.first(where:{ $0.elementID == member.id }),
        let target=nativeElementSource(reference)?.target else { return member }
      let surface:SurfaceID = target.kind == .page ? .page(target.id)
        : target.kind == .cover ? .cover(target.id) : .board(target.id)
      let cuts=elementErasures(on:surface)[member.id] ?? []
      guard !cuts.isEmpty else { return member }
      var graphic=member.graphic
      graphic.mask=(graphic.mask ?? .init()).capturing(cuts,transform:graphic.transform)
      return .init(id:member.id,frame:member.frame,graphic:graphic,layout:member.layout,body:member.body,placement:member.placement)
    }
    let edits = NotebookGraphicSelection.duplicated(visibleMembers,namespace:UUID(),offset:offset)
    do {
      let operations = try zip(edits,members).map { edit,member -> NotebookElementEdit in
        let reference: EditableElementReference
        var values: [String:JSONValue] = ["kind":.string("graphic"),"source":.string(""),"frame":try .encode(edit.frame),"graphic":try .encode(edit.graphic)]
        if let original=sources.first(where:{ $0.elementID == member.id }),
          let source=nativeElementSource(original)?.placementSource {
          if let basis=edit.basis { values["basis"]=try .encode(basis) }
          if let parent=source.parentID { values["parentID"] = .string(parent) }
        }
        switch first {
        case .page(let owner,_): reference = .page(pageID:owner,elementID:edit.id)
        case .spatial(let owner,_):
          reference = .spatial(boardID:owner,elementID:edit.id)
          if nativeElementSource(first)?.target.kind == .board { values["worldOrigin"] = try .encode(member.origin) }
        }
        return .init(reference:reference,kind:.insertElement,values:values)
      }
      if performElementOperations(operations,summary:"Дублировать фигуры",readSources:sources,
        copiedFrom:Dictionary(uniqueKeysWithValues:zip(edits,members).map { ($0.id,$1.id) })) {
        selectElements(operations.map(\.reference))
      }
    } catch { showCue(error.localizedDescription) }
  }

  func deleteSelectedContent() {
    if let region=selectionSession.region,let prepared=region.materialization {
      do { _ = commitRegion(region,prepared:try prepared.deleting(),summary:"Удалить область лассо") }
      catch { showCue(error.localizedDescription) };return
    }
    let elements = selectionSession.elements, items = selectionSession.items, selection = selectionSession.id
    if !elements.isEmpty {
      guard performElementOperations(elements.map { .init(reference:$0,kind:.removeElement,values:[:]) },summary:"Удалить выделенное") else { return }
    }
    Task { [weak self] in
      guard let self else { return }
      for item in items { guard await deleteItem(item.itemID) else { return } }
      if selectionSession.id == selection { clearSelection() }
    }
  }

  func deleteGraphicSelection() {
    guard selectedGraphicMembers() != nil else { return }
    if performElementOperations(selectionSession.elements.map { .init(reference:$0,kind:.removeElement,values:[:]) },summary:"Удалить выбранные фигуры") { clearSelection() }
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

  /// A read-only projection of the single UI owner. Missing physical knowledge
  /// stays unknown; a camera can name a surface, never an element selection.
  var selectionForPublication: NotebookSelection? {
    guard let presence else { return nil }
    let surface: CollaborationTarget
    switch presence.mode {
    case .board: surface = .init(kind: .board, id: presence.boardID)
    case .cover:
      guard let id = presence.focusedItemID else { return nil }
      surface = .init(kind: .cover, id: id, boardID: presence.boardID)
    case .page:
      guard let id = presence.notebookPageID else { return nil }
      surface = .init(kind: .page, id: id)
    case .document:
      guard let id = presence.focusedItemID else { return nil }
      surface = .init(kind: .document, id: id)
    }
    let session = selectionSession
    let kind: NotebookSelection.Kind
    switch session.target {
    case nil: kind = .empty
    case .item: kind = .item
    case .element: kind = .element
    case .elements: kind = .elements
    case .region: kind = .region
    case .context: kind = .context
    case .reference: kind = .reference
    }
    var value = NotebookSelection(id: session.id, kind: kind, surface: surface,
      pageIndex: presence.mode == .document ? presence.documentPageIndex : nil,
      contextID: kind == .empty ? nil : session.context?.contextID,
      resolving: session.isResolvingContext || (session.region != nil && session.region?.materialization == nil))
    switch session.target {
    case nil, .context: break
    case .item(let board, let id):
      guard surface.kind == .board, surface.id == board else { return nil }
      value.itemID = id
    case .element(.page(let page, let id)):
      value.target = .init(kind: .page, id: page); value.elementID = id
    case .element(let reference):
      guard let source=nativeElementSource(reference) else { return nil }
      value.target=source.target;value.elementID=source.id
    case .elements(let refs,let items):
      let target = refs.first.flatMap { nativeElementSource($0)?.target }
        ?? items.first.map { CollaborationTarget(kind:.board,id:$0.boardID) }
      guard let target, refs.allSatisfy({ nativeElementSource($0)?.target == target }),
        items.allSatisfy({ target.kind == .board && $0.boardID == target.id }) else { return nil }
      value.target = target; value.elementIDs = refs.compactMap { nativeElementSource($0)?.id }
      value.itemIDs = items.isEmpty ? nil : items.map(\.itemID)
    case .region(let region):
      value.target=region.address.target;value.region=region.polygon;value.worldOrigin=region.address.worldOrigin
    case .reference(let reference): value.reference = reference
    }
    return value.isValid ? value : nil
  }

  /// Availability does not clear or replace the UI choice. Returning to the
  /// active scene republishes it with a new generation in the same process.
  func setSelectionSurfaceActive(_ active: Bool) {
    guard selectionSurfaceIsActive != active else { return }
    selectionSurfaceIsActive = active
    publishSelection()
  }

  private func publishSelection(force: Bool = false) {
    guard !isClosing, loadState == .ready else { return }
    let selected = selectionSurfaceIsActive ? selectionForPublication : nil
    if let previous = lastSelectionEnvelope, previous.selection == selected {
      #if os(iOS)
      if force { sync?.sendTransient(.selection(previous)) }
      #endif
      return
    }
    guard selectionSequence < VersionStamp.maximumCounter else { return }
    selectionSequence += 1
    let envelope = NotebookSelectionEnvelope(deviceID: actorID, sessionID: presenceSessionID,
      sequence: selectionSequence, selection: selected)
    lastSelectionEnvelope = envelope
    #if os(iOS)
    sync?.sendTransient(.selection(envelope))
    #else
    enqueueStoreWrite(publishesChanges: false) { try $0.saveLocalSelectionPublication(envelope) }
    #endif
  }

  /// Navigation ends manipulation, but retains explicitly pinned material for
  /// the conversation. Only the resulting context target can show its outline.
  func endSurfaceEditing() {
    guard selectionSession.count > 0 || selectionSession.target.map({
      if case .item = $0 { return true }; return false
    }) == true else { return }
    cancelElementManipulation()
    selectionSession.target = .context
    selectionSession.addingElements = false
    selectionSession.isInteractive = false
  }

  func setElementGeometryMode(_ mode: NotebookSelectionSession.GeometryMode, reference: EditableElementReference) {
    guard selectionSession.element == reference else { return }
    cancelElementManipulation()
    selectionSession.geometryMode = mode
  }

  /// A contact belongs to the current selection and exact source frame, not a
  /// reusable element ID. No late lift can commit a superseded contact.
  func beginElementManipulation(_ reference: EditableElementReference,
    kind: NotebookElementManipulation.Kind) -> UUID? {
    if let region=selectionSession.region,region.reference == reference {
      return beginRegionManipulation(region,kind:kind)
    }
    // A passive raster is selectable, but it is not a live manipulation owner.
    // Selection requests its ordinary scene admission; do not commit an
    // invisible drag while the installed cohort still owns baked pixels.
    if case .spatial = reference, acceptedWorkingGraphic(reference) == nil,
      graphicElement(reference) != nil || nativeTextTarget(reference) != nil,
      let cohort = compositionTiles.published, presentedElement(reference, cohort: cohort) == nil { return nil }
    guard selectionSession.contains(reference), inputGate.beginFingerSequence() != nil,
      let geometry = elementGeometry(reference) else { return nil }
    let connection = graphicElement(reference)?.connection
    cancelElementManipulation()
    let captured=editingGraphicGraph(reference)
    let graphicGeometry=graphicManipulationGeometry(reference,in:captured)
    let groupGeometry=groupManipulationGeometry(reference,in:captured)
    if isElementGroup(reference), groupGeometry == nil || !groupAllowsLiveManipulation(reference,in:captured) { return nil }
    let native=elementPresentation(reference,graph:captured)
    let text=nativeTextTarget(reference)
    // Text width edits its body, while a whole/group resize changes placement.
    let nativePlacement=native.flatMap { value -> NotebookElementPlacement? in
      text != nil || kind == .move || value.placement.parentID != nil || value.placement.basis != nil ? value.placement : nil
    }
    var contact = NotebookElementManipulation(reference: reference, kind: kind,
      frame: geometry.frame, bounds: geometry.bounds, identity: geometry.identity, worldOrigin: geometry.worldOrigin,
      connection:connection,layout:graphicGeometry?.body,graphic:graphicElement(reference),placement:graphicGeometry?.placement ?? groupGeometry?.placement ?? nativePlacement,
      displayFrame:graphicGeometry.map { geometry in
        let f=graphicElement(reference)?.mask.flatMap { geometry.display.visibleFrame(mask:$0) } ?? geometry.display.frame
        return .init(x:f.x,y:f.y,width:f.width,height:f.height)
      } ?? groupGeometry?.bounds ?? native?.bounds,text:text)
    if let captured,let source=captured.source(reference.elementID) {
      let closed:Bool?
      if case .spatial(let owner,let id)=reference { closed=spatialGroupReads[owner]?[id]?.isSelfContained } else { closed=nil }
      contact.graphicCapture = .init(graph:captured,source:source,id:reference.elementID,closedGroup:closed)
    }
    if selectionSession.elements.count > 1 {
      switch kind { case .move,.resize: break; default: return nil }
      guard let members=selectedGraphicMembers(),let origin=members.first?.origin else { return nil }
      let box=NotebookGraphicSelection.bounds(members,relativeTo:origin)
      guard !box.isNull,box.width>0,box.height>0 else { return nil }
      let capture=contact.graphicCapture
      contact=NotebookElementManipulation(reference:reference,kind:kind,frame:box,bounds:geometry.bounds,worldOrigin:origin)
      contact.graphicCapture=capture;contact.selectedMembers=members
    }
    if !selectionSession.isInteractive { selectionSession.nativeText = nil }
    selectionSession.manipulation = contact
    inputGate.beginContact(source: contact.id)
    inputGate.registerFingerCancellation(source: contact.id) { [weak self] in self?.cancelElementManipulation(contact.id) }
    return contact.id
  }

  func beginRegionManipulation(_ region:NotebookRegionSelection,kind:NotebookElementManipulation.Kind) -> UUID? {
    switch kind { case .move,.resize: break; default: return nil }
    guard selectionSession.manipulation?.regionGestureEnded != true else { return nil }
    if region.materialization != nil {
      guard regionIsCurrent(region) else { showCue("Материал области изменился. Повторите лассо.");return nil }
    } else if drawingTools.pendingLasso?.id != region.id { return nil }
    guard inputGate.beginFingerSequence() != nil else { return nil }
    cancelElementManipulation()
    let f=region.frame
    var contact=NotebookElementManipulation(reference:region.reference,kind:kind,
      frame:.init(x:f.x,y:f.y,width:f.width,height:f.height),bounds:region.address.bounds,
      worldOrigin:region.address.worldOrigin)
    contact.region=region;selectionSession.manipulation=contact
    updateRegionPreview(contact)
    inputGate.beginContact(source:contact.id)
    inputGate.registerFingerCancellation(source:contact.id) { [weak self] in self?.cancelElementManipulation(contact.id) }
    return contact.id
  }

  func updateElementManipulation(_ id: UUID, translation: SpatialPoint) {
    guard selectionSession.manipulation?.id == id else { return }
    let previous = manipulatedBindingTarget?.elementID
    selectionSession.manipulation?.update(translation:.init(x:translation.x,y:translation.y))
    selectionSession.manipulation?.bindEndpoint(manipulatedEndpointBinding(retaining:previous))
    if let contact=selectionSession.manipulation,contact.region != nil { updateRegionPreview(contact) }
  }

  @discardableResult
  func finishElementManipulation(_ id: UUID, translation: SpatialPoint) -> Bool {
    guard selectionSession.manipulation?.id == id else { return false }
    updateElementManipulation(id, translation: translation)
    guard let contact = selectionSession.manipulation else { return false }
    if let region=contact.region {
      if region.materialization == nil,contact.frame != contact.original {
        selectionSession.manipulation?.regionGestureEnded=true
        inputGate.unregisterFingerCancellation(source:id);inputGate.endContact(source:id)
        return true
      }
      return finishRegionManipulation(contact)
    }
    cancelElementManipulation(id)
    if !contact.selectedMembers.isEmpty {
      guard selectedGraphicMembers() == contact.selectedMembers else { return false }
      guard contact.frame != contact.original,contact.selectedEdits.count == contact.selectedMembers.count else { return false }
      return applySelectionEdits(contact.selectedEdits,summary:contact.kind == .move ? "Переместить выбранные фигуры" : "Изменить размер выбранных фигур")
    }
    guard contact.frame != contact.original || contact.basis != contact.originalBasis || contact.connection != contact.originalConnection
      || contact.vertices != contact.originalVertices || contact.cornerRadius != contact.originalCornerRadius,
      let current = elementGeometry(contact.reference), current.frame == contact.original,
      current.identity == contact.identity,
      graphicElement(contact.reference)?.connection == contact.originalConnection else { return false }
    if let placement=contact.placement {
      if case .spatial(let boardID,let elementID)=contact.reference,let captured=contact.graphicCapture,captured.source.isGroup {
        let source=elementCommandDrafts[contact.reference]?.source ?? nativeElementSource(contact.reference)?.placementSource
        let desired=projectingGraphicCommands(boardHierarchy?.board(boardID)?.graphicGraph() ?? NotebookGraphicGraph([])) { .spatial(boardID:boardID,elementID:$0) }.placement(elementID)
        guard source == captured.source,desired?.parentTransform == placement.parentTransform,desired?.origin == placement.origin else { return false }
      } else {
        guard (graphicManipulationGeometry(contact.reference)?.placement ?? groupManipulationGeometry(contact.reference)?.placement ?? elementPresentation(contact.reference)?.placement) == placement else { return false }
      }
    } else if current.worldOrigin != contact.worldOrigin { return false }
    if contact.vertices != contact.originalVertices || contact.cornerRadius != contact.originalCornerRadius {
      guard graphicElement(contact.reference).flatMap(NotebookGraphicGeometry.polygon) == contact.originalVertices,
        (graphicElement(contact.reference)?.cornerRadius ?? 0) == contact.originalCornerRadius else { return false }
      var patch: [String:JSONValue] = [:]
      if contact.vertices != contact.originalVertices { patch["vertices"] = try? .encode(contact.vertices) }
      if contact.cornerRadius != contact.originalCornerRadius { patch["cornerRadius"] = .number(contact.cornerRadius) }
      var values: [String:JSONValue] = ["graphic":.object(patch)]
      if contact.frame != contact.original {
        values["frame"] = try? .encode(PageRect(x:contact.frame.minX,y:contact.frame.minY,width:contact.frame.width,height:contact.frame.height))
      }
      return performElementOperation(.updateElement,reference:contact.reference,values:values,summary:"Изменить геометрию фигуры",readSources:contact.ancestorReferences,capture:contact.graphicCapture?.retaining(bounds:contact.presentedFrame))
    }
    if let connection = contact.connection, connection != contact.originalConnection {
      guard let original = contact.originalConnection else { return false }
      var patch: [String: JSONValue] = [:]
      if connection.start != original.start { patch["start"] = try? .encode(connection.start) }
      if connection.end != original.end { patch["end"] = try? .encode(connection.end) }
      if connection.bend != original.bend { patch["bend"] = .number(connection.bend) }
      if connection.routing != original.routing { patch["routing"] = try? .encode(connection.routing) }
      if connection.bendPosition != original.bendPosition { patch["bendPosition"] = try? .encode(connection.bendPosition) }
      var values: [String:JSONValue] = ["graphic": .object(["connection": .object(patch)])]
      if contact.frame != contact.original {
        values["frame"] = try? .encode(PageRect(x:contact.frame.minX,y:contact.frame.minY,width:contact.frame.width,height:contact.frame.height))
      }
      return performElementOperation(.updateElement, reference: contact.reference,
        values:values,summary:"Изменить связь",readSources:contact.ancestorReferences,capture:contact.graphicCapture?.retaining(bounds:contact.presentedFrame))
    }
    return commitElementFrame(contact)
  }

  @discardableResult
  private func finishRegionManipulation(_ contact:NotebookElementManipulation)->Bool {
    cancelElementManipulation(contact.id)
    guard let region=contact.region,contact.frame != contact.original,
      let prepared=try? region.materialization?.transformed(from:region.frame,to:contact.frame,address:region.address) else { return false }
    return commitRegion(region,prepared:prepared,
      summary:contact.kind == .move ? "Переместить область лассо" : "Изменить размер области лассо")
  }

  /// Preview and commit use the same completed rectangle. Storage changes the
  /// addressed material; it does not run a second resize calculation.
  private func commitElementFrame(_ contact: NotebookElementManipulation) -> Bool {
    guard contact.identity != nil else { return false }
    let frame=contact.frame
    return performElementOperation(.updateElement,reference:contact.reference,
      values:["frame":(try? .encode(PageRect(x:frame.minX,y:frame.minY,width:frame.width,height:frame.height))) ?? .null]
        .merging(contact.basis == contact.originalBasis ? [:] : ["basis":(try? .encode(contact.basis)) ?? .null]) { _,new in new },
      summary:"Изменить положение объекта",readSources:contact.ancestorReferences,capture:contact.graphicCapture?.retaining(bounds:contact.presentedFrame))
  }

  func cancelElementManipulation(_ id: UUID? = nil) {
    guard let contact = selectionSession.manipulation, id == nil || contact.id == id else { return }
    selectionSession.manipulation = nil
    if let prepared=contact.region?.materialization {
      let ids=Set(prepared.working.map(\.id));removeWorkingGraphics { !$0.accepted && ids.contains($0.id) }
    }
    inputGate.unregisterFingerCancellation(source: contact.id)
    inputGate.endContact(source: contact.id)
  }

  func elementPresentationFrame(_ reference: EditableElementReference, fallback: PageRect, preview: Bool = true) -> PageRect {
    guard preview else { return fallback }
    let frame: PageRect
    if let contact = selectionSession.manipulation, contact.reference == reference {
      frame = .init(x:contact.frame.minX,y:contact.frame.minY,width:contact.frame.width,height:contact.frame.height)
    } else {
      frame = elementCommandDrafts[reference]?.frame ?? fallback
    }
    if let presentation=elementPresentation(reference) { return presentation.frame }
    guard let text = nativeTextTarget(reference) else { return frame }
    return NotebookTextTypography.fittingFrame(text.source,style:text.style,in:frame)
  }

  func elementGeometry(_ reference: EditableElementReference) -> (frame: CGRect, bounds: CGRect?, identity: VersionStamp?, worldOrigin: WorldPoint?)? {
    guard elementCommandDrafts[reference]?.removed != true else { return nil }
    func rectangle(_ frame: PageRect) -> CGRect {
      .init(x:frame.x,y:frame.y,width:frame.width,height:frame.height)
    }
    if let region=selectionSession.region,region.reference == reference {
      return (rectangle(region.frame),region.address.bounds,nil,region.address.worldOrigin)
    }
    if let working = acceptedWorkingGraphic(reference) {
      let bounds: CGRect?
      if working.surface.kind == .page, let page = working.surface.ownerID.flatMap({ pages[$0] }) {
        bounds = .init(x:0,y:0,width:page.size.width,height:page.size.height)
      } else if working.surface.kind == .cover {
        let size = itemGeometry(working.surface.ownerID); bounds = .init(x:0,y:0,width:size.width,height:size.height)
      } else { bounds = nil }
      let f = working.frame
      return (elementCommandDrafts[reference]?.rect ?? .init(x:f.x,y:f.y,width:f.width,height:f.height),bounds,nil,working.worldOrigin)
    }
    switch reference {
    case .page(let pageID, let id):
      guard !isPageBeingDeleted(pageID), let page = pages[pageID],
        let element = page.element(id:id) else { return nil }
      return (rectangle(elementCommandDrafts[reference]?.frame ?? element.frame),
        .init(x: 0, y: 0, width: page.size.width, height: page.size.height), page.elementIdentityStamp(id), nil)
    case .spatial(let boardID, let id):
      guard let element = boardHierarchy?.board(boardID)?.element(id:id),
        surfaceAcceptsChanges(element.surface) else { return nil }
      let size = itemGeometry(element.surface.ownerID)
      let bounds: CGRect? = element.surface.kind == .cover ? .init(x: 0, y: 0, width: size.width, height: size.height) : nil
      return (rectangle(elementCommandDrafts[reference]?.frame ?? .init(x:element.frame.x,y:element.frame.y,width:element.frame.width,height:element.frame.height)), bounds,
        boardHierarchy?.board(boardID)?.elementIdentityStamp(id), element.worldOrigin)
    }
  }

  func moveElementAccessibly(_ reference: EditableElementReference, by translation: SpatialPoint) {
    selectElement(reference)
    guard let id = beginElementManipulation(reference, kind: .move) else { return }
    finishElementManipulation(id, translation: translation)
  }

  func graphicElement(_ reference: EditableElementReference) -> NotebookGraphic? {
    if let region=selectionSession.region,region.reference == reference {
      return region.rawInk?.graphic ?? region.graphics.lazy.compactMap { self.graphicElement($0) }.first
    }
    if let draft = elementCommandDrafts[reference] { return draft.graphic }
    if let working = acceptedWorkingGraphic(reference) { return working.graphic }
    switch reference {
    case .page(let pageID, let id): return pages[pageID]?.element(id:id)?.graphic
    case .spatial(let boardID, let id): return boardHierarchy?.board(boardID)?.element(id:id)?.graphic
    }
  }

  func acceptQuickShape(_ fit: NotebookQuickShapeFit, pageID: UUID, stroke: PageInkAction) {
    acceptQuickShape(.init(strokeID: stroke.id, fit: fit, surface: .page(pageID),
      color: stroke.color, width: stroke.samples.first?.width ?? 2))
  }

  func acceptQuickShape(_ fit: NotebookQuickShapeFit, boardID: UUID, origin: WorldPoint, stroke: SpatialInkAction) {
    acceptQuickShape(.init(strokeID: stroke.id, fit: fit, surface: .board(boardID), worldOrigin: origin,
      color: stroke.color, width: stroke.spans.first?.samples.first?.width ?? 2))
  }

  private func acceptQuickShape(_ object: NotebookWorkingGraphic) {
    guard let owner = object.surface.ownerID else { return }
    var accepted = object
    accepted.accepted = true
    updateWorkingGraphic(accepted,strokeID:object.strokeID)
    let values: [String: JSONValue]
    do { values = try object.authoredValues() }
    catch {
      removeWorkingGraphics { $0.strokeID == object.strokeID }
      showCue(error.localizedDescription)
      return
    }
    let reference: EditableElementReference = object.surface.kind == .page
      ? .page(pageID: owner, elementID: object.id) : .spatial(boardID: owner, elementID: object.id)
    if !performElementOperation(.convertInkToElement, reference: reference,
      values: values, summary: "Преобразовать набросок: " + object.graphic.shape.displayName) {
      removeWorkingGraphics { $0.strokeID == object.strokeID }
    }
  }

  func setGraphicLabel(_ text: String, reference: EditableElementReference, replacing original: String? = nil) {
    if let original, graphicElement(reference)?.label != original {
      showCue("Подпись уже изменена другим действием. Ваш текст: \(text)")
      return
    }
    guard graphicElement(reference)?.label != text else { return }
    performElementOperation(.updateElement, reference: reference,
      values: ["graphic": .object(["label": .string(text)])], summary: "Изменить подпись фигуры")
  }

  func setGraphicStyle(reference: EditableElementReference, update: (inout NotebookGraphic.Style) -> Void) {
    guard let original = graphicElement(reference)?.style else { return }
    var style = original; update(&style)
    guard original != style, let value = try? JSONValue.encode(style) else { return }
    performElementOperation(.updateElement,reference:reference,values:["graphic":.object(["style":value])],summary:"Изменить оформление фигуры")
  }

  func setGraphicRouting(_ routing: NotebookGraphicConnection.Routing, reference: EditableElementReference) {
    guard let original = graphicElement(reference)?.connection, original.resolvedRouting != routing else { return }
    var patch: [String: JSONValue] = ["routing":.string(routing.rawValue)]
    if routing != .straight && abs(original.bend) < 0.01 {
      let layout = graphicLayout(reference)
      let distance = layout.map { hypot($0.axisEnd.x-$0.axisStart.x,$0.axisEnd.y-$0.axisStart.y) } ?? 120
      patch["bend"] = .number(min(60,max(24,distance*0.2)))
    }
    performElementOperation(.updateElement,reference:reference,
      values:["graphic":.object(["connection":.object(patch)])],summary:"Изменить стиль соединения")
  }

  func setGraphicArrowhead(_ head: NotebookGraphicConnection.Arrowhead, terminal: NotebookGraphicConnection.Terminal,
    reference: EditableElementReference) {
    guard graphicElement(reference)?.connection != nil else { return }
    performElementOperation(.updateElement,reference:reference,
      values:["graphic":.object(["connection":.object([terminal == .start ? "startArrowhead" : "endArrowhead":.string(head.rawValue)])])],
      summary:"Изменить наконечник связи")
  }

  /// Clipboard and SDK fragments use the ordinary atomic action executor. This
  /// task joins the existing command tail, so navigation/shutdown cannot outrun it.
  func insertClipboardFragment(_ fragment: NotebookPasteFragment, at destination: NotebookPasteDestination) async -> Bool {
    guard fragment.canInsert, await finishPendingInteraction(boundary:.acceptedInput), !isClosing else { return false }
    let actor = actorID, predecessor = graphicCommandTask, generation = UUID()
    let task = Task<NotebookElementCommandResult?, Never> { [weak self] in
      guard let self else { return nil }
      defer { if graphicCommandGeneration == generation { graphicCommandTask = nil } }
      _ = await predecessor?.value
      await withCheckedContinuation { continuation in inputGate.performAfterIdle { continuation.resume() } }
      do {
        let operations = try fragment.operations(target:destination.target,offset:destination.offset(for:fragment),worldOrigin:destination.worldOrigin)
        let receipt = try await persistence.submit(publishesChanges:true) { store in
          let revision = try store.targetContentRevision(target:destination.target)
          return try store.applyNativeGraphicAction(.init(summary:"Вставить из буфера",
            expected:[.init(target:destination.target,revision:revision)],operations:operations),actor:actor)
        }
        pencilUndoHistory.recordCommand(ownerID:destination.target.id,actionID:receipt.id)
        reloadExternalChanges()
        showCue("Вставлено: \(fragment.elements.count)")
        return .init(page:nil,spatial:nil)
      } catch { showCue(error.localizedDescription); return nil }
    }
    graphicCommandGeneration = generation
    graphicCommandTask = task
    return await task.value != nil
  }

  @discardableResult
  func performElementOperation(_ kind: CollaborationOperation.Kind, reference: EditableElementReference,
    values: [String: JSONValue], summary: String, layerMove: NotebookElementLayerMove? = nil,
    readSources: [EditableElementReference] = [],capture:NotebookGraphicContactSource? = nil) -> Bool {
    performElementOperations([.init(reference:reference,kind:kind,values:values)],summary:summary,layerMove:layerMove,readSources:readSources,capture:capture)
  }

  @discardableResult
  func performElementOperations(_ edits: [NotebookElementEdit], summary: String,
    layerMove: NotebookElementLayerMove? = nil, readSources: [EditableElementReference] = [], copiedFrom: [String:String] = [:],
    insertionTarget explicitTarget: CollaborationTarget? = nil, expectedInkRevision: String? = nil, retainedSources: [EditableElementReference:NotebookNativeElementSource] = [:], previews: Bool = true,capture:NotebookGraphicContactSource? = nil,
    frozenSources:[EditableElementReference:NotebookNativeElementSource] = [:]) -> Bool {
    guard !edits.isEmpty, edits.count <= 32 else { return false }
    let references = Array(Set(edits.map(\.reference) + readSources))
    let insertionTarget = explicitTarget ?? readSources.first.flatMap { nativeElementSource($0)?.target }
    var originals: [EditableElementReference: NotebookNativeElementSource] = [:]
    for reference in references {
      let live = frozenSources[reference] ?? nativeElementSource(reference)
      guard let source = live?.page != nil || live?.spatial != nil ? live : retainedSources[reference] ?? live else { return false }
      originals[reference] = source.page == nil && source.spatial == nil && insertionTarget != nil
        ? .init(target:insertionTarget!,id:source.id) : source
    }
    guard let target = originals[edits[0].reference]?.target,
      originals.values.allSatisfy({ $0.target == target }) else { return false }
    let operations = edits.map { edit in
      CollaborationOperation(kind:edit.kind,target:target,id:originals[edit.reference]!.id,values:edit.values)
    }
    let sources = originals
    let predecessor = graphicCommandTask, actor = actorID, generation = UUID(),commandID=UUID()
    let sourceTasks = references.reduce(into: [EditableElementReference: Task<NotebookElementCommandResult?, Never>]()) {
      if frozenSources[$1] == nil { $0[$1] = elementCommandSources[$1]?.task }
    }
    var drafts: [EditableElementReference: NotebookElementCommandDraft] = [:]
    do {
      for edit in edits where previews {
        // Creation already has a working object; its full payload is not an update patch.
        guard ![CollaborationOperation.Kind.insertElement,.convertInkToElement].contains(edit.kind),
          let geometry = elementGeometry(edit.reference) else { continue }
        var graphic = graphicElement(edit.reference)
        guard graphic != nil || originals[edit.reference]?.placementSource != nil else { continue }
        if let patch = edit.values["graphic"] { graphic = try graphic?.applying(patch) }
        if edit.kind == .removeElement { graphic?.visible = false }
        let frame = try edit.values["frame"]?.decode(PageRect.self)
          ?? PageRect(x:geometry.frame.minX,y:geometry.frame.minY,width:geometry.frame.width,height:geometry.frame.height)
        let basis=try edit.values["basis"]?.decode(NotebookElementBasis.self)
          ?? elementCommandDrafts[edit.reference]?.basis ?? originals[edit.reference]?.page?.basis ?? originals[edit.reference]?.spatial?.basis
        var source=elementCommandDrafts[edit.reference]?.source ?? originals[edit.reference]?.placementSource
          ?? .init(frame:frame,origin:geometry.worldOrigin ?? .zero)
        source.frame=frame;source.basis=basis
        drafts[edit.reference] = .init(source:source,graphic:graphic,capture:capture,
          removed:edit.kind == .removeElement && graphic == nil,textSource:try edit.values["source"]?.decode(String.self) ?? elementCommandDrafts[edit.reference]?.textSource,
          textHTML:try edit.values["html"]?.decode(String.self) ?? elementCommandDrafts[edit.reference]?.textHTML,
          textStyle:try edit.values["textStyle"]?.decode(NativeTextStyle.self) ?? elementCommandDrafts[edit.reference]?.textStyle)
      }
    } catch { showCue(error.localizedDescription); return false }
    for (reference,draft) in drafts { elementCommandDrafts[reference] = draft }
    if !drafts.isEmpty { collaborationReadEpoch &+= 1;collaborationContentEpoch &+= 1 }
    let task = Task<[EditableElementReference: NotebookElementCommandResult]?, Never> { [weak self] in
      guard let self else { return nil }
      defer { if graphicCommandGeneration == generation { graphicCommandTask = nil } }
      _ = await predecessor?.value
      do {
        var expected: [NotebookNativeElementSource] = []
        for reference in references {
          let source = sources[reference]!
          if let task = sourceTasks[reference] {
            guard let accepted = await task.value else {
              throw CollaborationError("revision_conflict","Предыдущее изменение выбранного элемента не было сохранено.")
            }
            expected.append(.init(target:target,id:source.id,page:accepted.page,spatial:accepted.spatial))
          } else { expected.append(source) }
        }
        await withCheckedContinuation { continuation in inputGate.performAfterIdle { continuation.resume() } }
        let admittedSources = expected
        let (_,cursor,saved,header) = try await persistence.submit(publishesChanges:true) { store in
          let result = try store.applyNativeElementEdits(operations,summary:summary,sources:admittedSources,layerMove:layerMove,
            copiedFrom:copiedFrom,expectedInkRevision:expectedInkRevision,actionID:commandID,actor:actor)
          return (result.receipt,try store.currentChangeCursor(),result.sources,
            target.kind == .page ? nil : try store.readBoardNodeHeader(target.boardID ?? target.id)?.board)
        }
        var results: [EditableElementReference:NotebookElementCommandResult] = [:]
        for reference in references {
          if elementCommandSources[reference]?.id == generation { elementCommandSources[reference]?.cursor = cursor }
          let id = sources[reference]!.id
          let source = saved.first { $0.id == id }
          results[reference] = .init(page:source?.page,spatial:source?.spatial,boardHeader:header)
          if operations.contains(where: { $0.id == id && [.convertInkToElement,.insertElement].contains($0.kind) }),
            let index = workingGraphics.firstIndex(where: { $0.id == id }) {
            let surface=workingGraphics[index].surface
            workingGraphics[index].publicationCursor = cursor;didChangeWorkingGraphics(on:[surface])
          }
        }
        pendingCollaborationCommands[commandID]=nil
        reloadExternalChanges()
        return results
      } catch {
        pendingCollaborationCommands[commandID]=nil
        pencilUndoHistory.didUndoCommand(ownerID:target.id,actionID:commandID)
        for reference in references {
          if elementCommandSources[reference]?.id == generation { elementCommandDrafts[reference] = nil; elementCommandSources[reference] = nil }
          cancelElementManipulationForFailedCommand(reference)
          removeWorkingGraphics { $0.id == sources[reference]!.id }
        }
        showCue(error.localizedDescription); reloadExternalChanges(); return nil
      }
    }
    // The visible draft and its undo identity become one accepted action in
    // this actor segment. Undo below joins this exact write before reverting it.
    pencilUndoHistory.recordCommand(ownerID:target.id,actionID:commandID)
    pendingCollaborationCommands[commandID]=Task { await task.value != nil }
    graphicCommandGeneration = generation
    graphicCommandTask = Task { await task.value?.values.first }
    for edit in edits {
      let reference = edit.reference
      elementCommandSources[reference] = .init(id:generation,task:Task { await task.value?[reference] })
    }
    return true
  }

  func nativeElementSource(_ reference: EditableElementReference) -> NotebookNativeElementSource? {
    switch reference {
    case .page(let owner,let id):
      guard pages[owner] != nil else { return nil }
      return .init(target:.init(kind:.page,id:owner),id:id,page:pages[owner]?.element(id:id))
    case .spatial(let owner,let id):
      let element = boardHierarchy?.board(owner)?.element(id:id)
      guard boardHierarchy?.board(owner) != nil else { return nil }
      let surface = element?.surface ?? acceptedWorkingGraphic(reference)?.surface
      let target = surface?.kind == .cover
        ? CollaborationTarget(kind:.cover,id:surface!.ownerID!,boardID:owner) : .init(kind:.board,id:owner)
      return .init(target:target,id:id,spatial:element)
    }
  }

  private func cancelElementManipulationForFailedCommand(_ reference: EditableElementReference) {
    if selectionSession.manipulation?.reference == reference || selectionSession.contains(reference) { cancelElementManipulation() }
  }

  func deleteElement(_ reference: EditableElementReference) {
    if selectionSession.region?.reference == reference { deleteSelectedContent();return }
    guard selectionSession.element == reference else { return }
    // Text, figures and programs have the same causal deletion owner. A page
    // snapshot save must not race and resurrect a queued native edit.
    if performElementOperations([.init(reference:reference,kind:.removeElement,values:[:])],summary:"Удалить элемент") {
      clearSelection()
    }
  }

  func programStateBasis(focus: InteractiveElementReference, rendered: AgentElement) -> NotebookProgramStateBasis? {
    switch focus {
    case .page(let pageID, let elementID):
      guard elementID == rendered.id, let page = pages[pageID],
        let source=page.element(id:elementID),
        AgentProgramSource(source) == AgentProgramSource(rendered),source.state == rendered.state else { return nil }
      return page.programStateBasis(elementID)
    case .board(let boardID, let elementID):
      guard elementID == rendered.id, let board = boardHierarchy?.board(boardID),
        let source = board.element(id:elementID),
        AgentProgramSource(agentElementSnapshotSource(source)) == AgentProgramSource(rendered),
        source.state == rendered.state else { return nil }
      return board.programStateBasis(elementID)
    }
  }

  func checkpointProgramState(focus: InteractiveElementReference, rendered: AgentElement, value: JSONValue, basis: NotebookProgramStateBasis) async throws -> NotebookProgramStateBasis? {
    guard !isStopped else { return nil }
    let target: CollaborationTarget
    switch focus {
    case .page(let pageID, let elementID):
      guard elementID == rendered.id, !isPageBeingDeleted(pageID) else { return nil }
      target = .init(kind: .page, id: pageID)
    case .board(let boardID, let elementID):
      guard elementID == rendered.id else { return nil }
      target = .init(kind: .board, id: boardID)
    }
    let actor = actorID
    collaborationReadEpoch &+= 1; collaborationContentEpoch &+= 1
    let accepted = try await persistence.submit(publishesChanges: true) { store in
      try store.checkpointProgramState(target: target, rendered: rendered, state: value, basis: basis, actor: actor)
    }
    if accepted != nil { reloadExternalChanges() }
    return accepted
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

  func insertDocumentSource(documentID: UUID, kind: DocumentBlockKind) async throws -> DocumentSourceRequest {
    guard shutdownPhase == .running, !isItemBeingDeleted(documentID) else { throw CancellationError() }
    let actor = actorID
    await withCheckedContinuation { continuation in inputGate.performAfterIdle { continuation.resume() } }
    let inserted = try await persistence.submit(publishesChanges: true) {
      try $0.insertDocumentSource(documentID: documentID, kind: kind, actor: actor)
    }
    pencilUndoHistory.recordCommand(ownerID: documentID, actionID: inserted.receipt.id)
    if var current = documents[documentID] { _ = current.merge(inserted.document); documents[documentID] = current }
    else { documents[documentID] = inserted.document }
    reloadExternalChanges()
    return .init(documentID: documentID, block: inserted.document.blocks.first { $0.id == inserted.blockID }!,
      version: inserted.document.sourceVersion(blockID: inserted.blockID), offset: 0)
  }

  func selectSourceForAgent(documentID: UUID, blockID: String, version: ContentFieldVersion, range: NSRange) {
    guard let workspace, let hierarchy = boardHierarchy, let ink = spatialInk,
      let document = documents[documentID], let block = document.blocks.first(where: { $0.id == blockID }),
      document.sourceVersion(blockID: blockID) == version,
      range.location >= 0, range.length > 0, NSMaxRange(range) <= block.source.utf16.count else { return }
    let geometry = WorkspaceItemGeometry.document(document.paperSize)
    let selection = NotebookAttentionSelection(fragments: [.init(target: .init(kind: .document, id: documentID),
      elementID: blockID, region: .init(x: 0, y: 0, width: geometry.width, height: geometry.height),
      worldOrigin: nil, pageIndex: nil, label: "Исходник · " + blockID)], workspace: workspace, hierarchy: hierarchy,
      ink: ink, pages: pages, documents: [documentID: document], states: documentStates)
    let selected = (block.source as NSString).substring(with: range)
    publishHumanContext(selection, text: "Выделенный исходник (UTF-16: \(range.location)..<\(NSMaxRange(range))):\n" + selected)
    #if os(iOS)
    chat?.expanded = true; chat?.browsesChats = false
    #else
    showCue("Выделенный исходник добавлен в контекст Codex")
    #endif
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

  func commitDocumentSource(edit: DocumentSourceEdit, onCommit: ((DocumentSourceCommitResult) -> Void)? = nil) async throws -> DocumentSourceCommitResult.Status {
    guard shutdownPhase == .running else {
      throw NotebookPersistenceQueue.Failure(message: "Notebook завершает работу; новый исходник не принят.")
    }
    guard !isItemBeingDeleted(edit.documentID) else {
      throw NotebookPersistenceQueue.Failure(message: "Документ удаляется; новые изменения временно недоступны.")
    }
    let actor = actorID
    if let documentSaveObserver { DocumentRenderRegistry.shared.removeLiveObserver(documentSaveObserver) }
    documentSavePresentation = .init(sessionID: edit.sessionID, documentID: edit.documentID,
      blockID: edit.blockID, isPreamble: edit.isPreamble, phase: .saving, source: edit.source)
    documentSaveObserver = DocumentRenderRegistry.shared.observeLive(documentID: edit.documentID) { [weak self] in
      // The native publication can occur during representable update. Its
      // actual attachment is checked again after that update, never polled.
      Task { @MainActor [weak self] in self?.completeDocumentSavePresentation() }
    }
    let result: DocumentSourceCommitResult
    do {
      // The Save button can post its WebKit message before UIKit retires the
      // same contact. Join that contact and its ordered input publication;
      // do not bypass the common command executor's human-input barrier.
      await withCheckedContinuation { continuation in
        inputGate.performAfterIdle { continuation.resume() }
      }
      result = try await persistence.submit(publishesChanges: true) { try $0.commitDocumentSource(edit: edit, actor: actor) }
    } catch {
      clearDocumentSavePresentation(sessionID: edit.sessionID)
      throw error
    }
    documentDraftEpoch &+= 1
    if result.status == .committed {
      if let actionID = result.actionID { pencilUndoHistory.recordCommand(ownerID: edit.documentID, actionID: actionID) }
      documentEditingSessions.removeAll { $0.id == edit.sessionID }
      if !isStopped, !isItemBeingDeleted(edit.documentID),
        let publication = result.publication, var document = documents[edit.documentID] {
        _ = document.mergeSource(publication)
        documents[document.id] = document
      }
      if !isStopped, !isItemBeingDeleted(edit.documentID),
        let publication = result.preamblePublication, var document = documents[edit.documentID] {
        _ = document.mergeSource(publication); documents[document.id] = document
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
    onCommit?(result)
    return result.status
  }

  private func clearDocumentSavePresentation(sessionID: UUID) {
    guard documentSavePresentation?.sessionID == sessionID else { return }
    documentSavePresentation = nil
    if let documentSaveObserver { DocumentRenderRegistry.shared.removeLiveObserver(documentSaveObserver) }
    documentSaveObserver = nil
  }

  private func completeDocumentSavePresentation() {
    guard let saved = documentSavePresentation, saved.phase == .saved else { return }
    if let document = documents[saved.documentID],
      (saved.isPreamble ? document.preamble : document.blocks.first(where: { $0.id == saved.blockID })?.source) != saved.source {
      // Undo or a newer author's source superseded this pending presentation.
      // It can no longer install, so it must not leave an endless save cue.
      clearDocumentSavePresentation(sessionID: saved.sessionID); return
    }
    guard
      let presence, presence.mode == .document, presence.focusedItemID == saved.documentID,
      presence.openProgress >= 0.999, presencePhase == .settled,
      readingRestoreTarget?.id != saved.documentID, readingRestoreDocument != saved.documentID,
      let document = documents[saved.documentID], let state = documentStates[saved.documentID],
      (saved.isPreamble ? document.preamble : document.blocks.first(where: { $0.id == saved.blockID })?.source) == saved.source,
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

  /// Checkpoint admission compares the executor's causal basis before changing
  /// the model, and again inside the sole writer. A delayed animation cannot
  /// adopt a newer human state just because SwiftUI has not echoed it yet.
  func checkpointDocumentState(documentID: UUID, blockID: String, value: JSONValue,
    sourceVersion: ContentFieldVersion, stateVersion: ContentFieldVersion?) async throws -> ContentFieldVersion? {
    guard value.isValid else { throw NotebookStorageError.invalidTransaction("document checkpoint value") }
    guard !isStopped, !isItemBeingDeleted(documentID) else { return nil }
    if documents[documentID] == nil || documentStates[documentID] == nil {
      let actor = actorID
      let accepted = try await persistence.submit(publishesChanges: true) { store in
        try store.checkpointDocumentState(documentID: documentID, blockID: blockID, value: value,
          sourceVersion: sourceVersion, stateVersion: stateVersion, actor: actor)
      }
      if accepted != nil { reloadExternalChanges() }
      return accepted
    }
    guard !isStopped, !isItemBeingDeleted(documentID),
      let document = documents[documentID], document.sourceVersion(blockID: blockID) == sourceVersion,
      let block = document.blocks.first(where: { $0.id == blockID && $0.kind == .interactive }),
      var journal = documentStates[documentID],
      journal.records.first(where: { $0.id == blockID })?.valueVersion == stateVersion else { return nil }
    if journal.commit(blockID: blockID, value: value, actor: actorID) {
      let record = journal.records.first { $0.id == blockID }!
      let command = NotebookDocumentStateCommand(documentID: documentID, record: record,
        journalStamp: journal.stamp, expectedSourceVersion: sourceVersion, stateCondition: .matching(stateVersion))
      documentStates[documentID] = journal
      persistence.enqueue(owner: .documentState(documentID)) { try $0.commitDocumentState(command) != command.expectedResult }
    }
    guard let record = journal.records.first(where: { $0.id == blockID }), record.value == value else {
      throw NotebookStorageError.invalidTransaction("document checkpoint admission")
    }
    let stored = try await persistence.submit { try $0.readDocumentBlock(documentID: documentID, blockID: blockID) }
    try Task.checkCancellation()
    guard !isStopped, !isItemBeingDeleted(documentID), let stored,
      stored.block == block, stored.sourceVersion == sourceVersion,
      stored.stateVersion == record.valueVersion, stored.state == value,
      documents[documentID]?.sourceVersion(blockID: blockID) == sourceVersion,
      documentStates[documentID]?.records.first(where: { $0.id == blockID }) == record else { return nil }
    return record.valueVersion
  }

  // A camera contact owns its coordinates, not the old content cursor. The
  // same admission as scene preparation still protects Pencil and controls.
  private var permitsExternalScenePublication: Bool {
    (!inputGate.isActive && presencePhase != .active)
      || (presencePhase == .active && permitsScenePreparation)
  }

  @discardableResult
  func reloadExternalChanges() -> Task<Void, Never>? {
    guard loadState == .ready, !isStopped else { return nil }
    guard permitsExternalScenePublication else { externalReloadPending = true; return nil }
    diskRefreshRequested = true
    if let diskRefreshTask { return diskRefreshTask }
    let task = Task { [weak self] in
      guard let self else { return }
      defer { diskRefreshTask = nil }
      while diskRefreshRequested, !Task.isCancelled, let presence {
        guard permitsExternalScenePublication else { externalReloadPending = true; return }
        diskRefreshRequested = false
        let epoch = collaborationReadEpoch
        let draftEpoch = documentDraftEpoch
        let elementPins = scenePinnedElements, itemPins = scenePinnedItems
        let preparedIDs = preparedNotebookPageIDs(in: presence.selectedItemID)
        let attentionID = agentFeedback.attentionID, attentionReferences = agentFeedback.attention.map(\.reference)
        #if os(iOS)
          let receivingDeviceID: UUID? = actorID
          let feedbackKnown = agentFeedback.knownActions, feedbackTracked = agentFeedback.trackedActions
        #else
          let receivingDeviceID: UUID? = nil
          let feedbackKnown: Set<UUID>? = nil, feedbackTracked: Set<UUID> = []
        #endif
        do {
          let prepared = try await persistence.submit(publishesChanges: receivingDeviceID != nil) { store in
            try NotebookDiskRefresh.prepare(store: store, presence: presence, receivingDeviceID: receivingDeviceID,
              pinnedElements: elementPins, pinnedItems: itemPins, preparedPages: preparedIDs,
              feedbackKnown: feedbackKnown, feedbackTracked: feedbackTracked, attentionReferences: attentionReferences)
          }
          publicationFailure = nil
          if persistence.failure == nil { persistenceFailure = publicationFailure }
          let liveDrafts = documentEditingSessions
          guard acceptExternalScene(prepared.scene, observedEpoch: epoch,
            observedPresence: presence, itemPins: itemPins) else {
            if inputGate.isActive || presencePhase == .active { externalReloadPending = true; return }
            diskRefreshRequested = true; continue
          }
          if draftEpoch != documentDraftEpoch { documentEditingSessions = liveDrafts }
          agentFeedback.receive(actions: prepared.actions, changes: prepared.feedback)
          if let attentionID, attentionID == agentFeedback.attentionID {
            if let attention = prepared.attention { agentFeedback.refreshAttention(attention) }
            else { presentationPlayer.interrupt("attention_source_changed") }
          }
          acceptCollaborationMetadata(actions: prepared.actions,
            contexts: prepared.contexts, delivery: prepared.delivery)
        } catch {
          publicationFailure = error.localizedDescription
          persistenceFailure = error.localizedDescription
          // A failed publication cannot masquerade as a still-pending write.
          // Its durable command remains available to undo/reopen normally.
          for (reference, command) in elementCommandSources where command.cursor != nil && !editingNativeTextReferences.contains(reference) {
            elementCommandDrafts[reference] = nil; elementCommandSources[reference] = nil
          }
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

    /// Local presentation uses the same journal/owner directly, never a loopback transport.
    func localCodexQuery(_ query: NotebookChatQuery, requestID: UUID = UUID()) async throws -> NotebookChatReply {
      if codexSidecar == nil { await startCodexSidecar() }
      guard let codexSidecar else { throw NotebookPersistenceQueue.Failure(message: agentStartupError ?? "Codex недоступен") }
      guard let envelope = await codexSidecar.receive(.init(id: requestID, body: .request(query)), peerID: actorID),
        case .reply(let reply) = envelope.body else { throw NotebookTransportError.disconnected }
      if case .failure(let message) = reply { throw NotebookPersistenceQueue.Failure(message: message) }
      return reply
    }
    func localCodexPanel() async throws -> NotebookChatPanelState {
      let author = actorID
      return try await persistence.submit { try $0.chatPanel(author: author, computer: author) }
    }
    func saveLocalCodexPanel(_ state: NotebookChatPanelState) {
      let author = actorID
      persistence.enqueue(publishesChanges: false) { try $0.saveChatPanel(state, author: author); return false }
    }
    func localCodexControl(_ action: NotebookChatAction) async throws -> NotebookChatJob? {
        let author = actorID
        return try await persistence.submit { try $0.savedChatControl(action, author: author, computer: author) }
    }

    func localCodexJobs() async throws -> [NotebookChatJob] {
      let author = actorID
      return try await persistence.submit { try $0.routedChatJobs(author: author, computer: author) }
    }

    /// Deliberate external integration, never a prerequisite for opening a task.
    func registerExternalCodexTools() async throws {
      guard allowsCodexRegistration, acceptance == nil else {
        throw NotebookPersistenceQueue.Failure(message: "Тестовая или неактивированная сборка не меняет общие инструменты Codex. Откройте установленный Notebook.")
      }
      let installation = try await Task.detached { try CodexRuntimeInstallation.discover() }.value
      guard let entry = Bundle.main.resourceURL?.appendingPathComponent("NotebookTools/dist/index.mjs") else { throw CodexBridgeError.notInstalled }
      try await installation.registerNotebookTools(entry: entry, socket: NotebookIPC.defaultSocketURL)
    }

    private func startCodexSidecar() async {
      guard codexSidecar == nil, let workspaceID = workspaceHeader?.workspaceID else { return }
      do {
        guard allowsCodexRegistration || acceptance != nil else {
          agentStartupError = "Запуск Codex из этого архива закрыт до безопасной активации пары. Действующие инструменты Notebook не перенаправлены."
          return
        }
        let installation = try await Task.detached(priority: .userInitiated) { try CodexRuntimeInstallation.discover() }.value
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
          directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Notebook/Codex", isDirectory: true)
          scope = nil
        }
        let host = codexHost ?? NotebookCodexHost()
        codexHost = host
        let sidecar = try await host.workspace(store: store, persistence: persistence, installation: installation,
          workspaceID: workspaceID, computerID: actorID, directory: directory, scope: scope, entry: entry, socket: commandSocketURL,
          authorizePeer: { [weak self] peer in
            guard let self else { return false }
            return peer == self.actorID || self.sync?.pairedPeers.contains(where: { $0.deviceID == peer }) == true
          }) { [weak self] envelope, peer in
            guard let self else { return }
            if peer == actorID { localCodexEvent = envelope }
            else { sync?.sendTransient(.codex(envelope), to: peer) }
          }
        codexSidecar = sidecar; sidecar.start(); agentStartupError = nil
      } catch { agentStartupError = NotebookCodexSidecar.message(error) }
    }

    @ObservationIgnored private var programImporter: NotebookProgramImporter?

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
          return .object(["api_version": .number(2), "value": try await coordinator.context(request)])
        }
        throw CollaborationError("invalid_script_request", "Запрос исполнения или контекста отсутствует.")
      }
      if command.command == .importProgram {
        guard let request = command.programImport, let workspaceID = workspaceHeader?.workspaceID else {
          throw CollaborationError("invalid_program_package", "Запрос импорта отсутствует.")
        }
        if programImporter == nil { programImporter = NotebookProgramImporter(persistence: persistence, workspaceID: workspaceID) }
        return try await programImporter!.handle(request)
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
        canonicalExport: { [weak self] cut, options, id in
          guard let self else { throw CancellationError() }
          return try await DocumentCanonicalExport.publish(cut: cut, options: options, jobID: id, store: self.store, persistence: persistence)
        }, userServiceName: userService, markupServiceName: markupService)
      scriptCoordinator = coordinator
      return coordinator
    }
  #endif

  func receivePeerTransient(_ message: NotebookTransportTransient, peerID: UUID, generation: UUID) {
    guard !isClosing, peerGenerations[peerID] == generation else { return }
    switch message {
    case .relay: break // Routing credentials terminate at NearbySync.
    case .selection(let value):
      #if os(macOS)
        guard value.deviceID == peerID, value.isValid else { return }
        enqueueStoreWrite(publishesChanges: false) { _ = try $0.acceptSelectionPublication(value, connectionID: generation) }
      #endif
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
        presentationPlayer.clearAttention = { [weak self] in self?.agentFeedback.clearAttention() }
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
        guard observedPeerID == peerID, presenceSequenceTracker.accepts(envelope),
          presenceIsUsable(envelope.presence) else { return }
        presentationRelay.observe(envelope, from: peerID)
        peerPresenceEnvelope = envelope
        if envelope.phase == .settled {
          enqueueStoreWrite(owner: .peerPresence(peerID), publishesChanges: false) {
            _ = try $0.acceptPresencePublication(envelope, deviceID: peerID, connectionID: generation)
          }
        }
      #endif
    }
  }

  #if os(iOS)
  func selectProgramForAttention(_ choice: NotebookAttentionProjection.ProgramChoice) {
    guard let selected = NotebookAttentionProjection.captureProgram(choice, model: self) else {
      agentRequestError = "Программа переместилась или ещё не показана. Выберите её снова."
      return
    }
    publishHumanContext(selected)
  }

  var canFreezeProgramForAttention: Bool {
    guard let refs = agentQuestion?.references, refs.count == 1, let ref = refs.first,
      let id = ref.elementID, ref.region != nil else { return false }
    switch ref.target.kind {
    case .document: return documents[ref.target.id]?.blocks.first(where: { $0.id == id })?.kind == .interactive
    case .page: return pages[ref.target.id]?.element(id:id)?.kind == .web
    case .board, .cover:
      return boardHierarchy?.board(ref.target.boardID ?? ref.target.id)?.element(id:id)?.kind == .web
    default: return false
    }
  }

  var hasFrozenProgramForAttention: Bool {
    guard let question = agentQuestion else { return false }
    return pinnedAttentionSelections.first { $0.0 == question.contextID }?.1.hasFrozenProgram == true
  }

  /// Explicitly stop one selected model outside the pointing contact. Rebind
  /// its accepted state, then Send still copies the actual native pixels.
  func freezeProgramForAttention() async {
    guard canFreezeProgramForAttention, !selectionSession.isResolvingContext,
      let reference = agentQuestion?.references.first, let id = reference.elementID, let region = reference.region else { return }
    let generation = selectionSession.id
    selectionSession.isResolvingContext = true
    defer { if selectionSession.id == generation { selectionSession.isResolvingContext = false } }
    var pause: NotebookProgramAttentionPause?
    do {
      let revision = try await persistence.submit(publishesChanges: false) {
        try $0.referenceRevision(target: reference.target, elementID: id)
      }
      guard revision == reference.revision, selectionSession.id == generation else { throw CancellationError() }
      let acceptsState: (JSONValue) -> Bool
      switch reference.target.kind {
      case .document:
        guard let document = documents[reference.target.id],
          let block = document.blocks.first(where: { $0.id == id }) else { throw CancellationError() }
        let sourceVersion = document.sourceVersion(blockID: id)
        acceptsState = { value in
          self.documents[document.id]?.sourceVersion(blockID: id) == sourceVersion
            && self.documents[document.id]?.blocks.first(where: { $0.id == id }) == block
            && self.documentStates[document.id]?.records.first(where: { $0.id == id })?.value == value
        }
        pause = try await DocumentPagePresentationOwner.pauseForAttention(documentID: reference.target.id, blockID: id)
      case .page:
        guard let element = pages[reference.target.id]?.element(id:id) else { throw CancellationError() }
        acceptsState = { value in self.pages[reference.target.id]?.element(id:id) == element.updating(state: value) }
        pause = try await AgentWebCoordinator.pauseForAttention(focus: .page(pageID: reference.target.id, elementID: id), element: element, model: self)
      case .board, .cover:
        let board = reference.target.boardID ?? reference.target.id
        guard let element = boardHierarchy?.board(board)?.element(id:id) else { throw CancellationError() }
        acceptsState = { value in
          guard let current = self.boardHierarchy?.board(board)?.element(id:id) else { return false }
          return current.frame == element.frame && current.worldOrigin == element.worldOrigin && current.surface == element.surface
            && agentElementSnapshotSource(current) == agentElementSnapshotSource(element).updating(state: value)
        }
        pause = try await AgentWebCoordinator.pauseForAttention(focus: .board(boardID: board, elementID: id), element: agentElementSnapshotSource(element), model: self)
      default: throw CancellationError()
      }
      await reloadExternalChanges()?.value
      guard selectionSession.id == generation, let pause, pause.isCurrent(), acceptsState(pause.value),
        let workspace, let hierarchy = boardHierarchy, let ink = spatialInk else { throw CancellationError() }
      let fragment = NotebookAttentionSelection.Fragment(target: reference.target, elementID: id, region: region,
        worldOrigin: reference.worldOrigin, pageIndex: reference.pageIndex, label: reference.label)
      let visuals = NotebookFrozenVisualSources.capture(fragments: [fragment], hierarchy: hierarchy,
        pages: pages, documents: documents, states: documentStates,
        elementErasures: { self.elementErasures(on: $0)[$1] ?? [] }, capturesLivePrograms: true)
      visuals.attentionPause = pause
      let selection = NotebookAttentionSelection(fragments: [fragment], workspace: workspace, hierarchy: hierarchy,
        ink: ink, pages: pages, documents: documents, states: documentStates, visuals: visuals)
      publishHumanContext(selection)
    } catch {
      pause?.release()
      if selectionSession.id == generation { agentRequestError = "Не удалось связать объект с кадром. Укажите готовую программу снова." }
    }
  }
  #endif

  func publishHumanContext(_ selection: NotebookAttentionSelection, target: NotebookSelectionSession.Target = .context, text: String? = nil) {
    let actor = actorID
    let generation = replaceSelection(target, persistsDeselection: false)
    selectionSession.isResolvingContext = true
    let predecessor=contextPublicationTask,id=UUID()
    contextPublicationID=id
    func enqueue(_ prepared:Result<NotebookAttentionSelection,Error>) -> Task<Void,Never> {
      let selects=selectionSession.id == generation
      let (results,continuation)=AsyncStream<Result<(SharedContextAppend,NotebookAttentionSelection.Sealed),Error>>
        .makeStream(bufferingPolicy:.bufferingNewest(1))
      // Already-resolved captures register their writer fence before returning
      // to the next contact. Only a captured native command needs preparation.
      persistence.enqueueCommand(publishesChanges:true, { store in
        do {
          let sealed=try prepared.get().seal(in:store)
          let context=try store.appendContext(references:sealed.references,author:.human,actor:actor,
            text:text,select:selects,sourceWorkspaceID:sealed.workspaceID)
          return (context,sealed)
        } catch {
          if selects { try store.selectSharedContext(nil,actor:actor) }
          throw error
        }
      }) { result in continuation.yield(result);continuation.finish() }
      return Task { [weak self] in
        // Completion order must not let older pending captures evict the
        // current selection's retained source from the bounded history.
        await predecessor?.value
        guard let self else { return }
        for await result in results {
          do {
            let (context,sealed)=try result.get()
            pinnedAttentionSelections.append((context.id,sealed.selection))
            if pinnedAttentionSelections.count>2 { pinnedAttentionSelections.removeFirst() }
            reloadExternalChanges()
            guard selectionSession.id == generation else { return }
            selectionSession.isResolvingContext=false
            selectionSession.context = .init(contextID:context.id,entryID:context.entry.id,references:sealed.references)
            agentRequestError=nil
          } catch {
            if selectionSession.id == generation { selectionSession.isResolvingContext=false;agentRequestError=error.localizedDescription }
          }
        }
      }
    }
    let publication:Task<Void,Never>
    if selection.hasAcceptedElements {
      publication=Task {
        let prepared:Result<NotebookAttentionSelection,Error>
        do { prepared = .success(try await selection.resolvingAcceptedElements()) }
        catch { prepared = .failure(error) }
        await enqueue(prepared).value
      }
    } else { publication=enqueue(.success(selection)) }
    contextPublicationTask=Task { [weak self] in
      await publication.value
      guard let self,contextPublicationID == id else { return }
      contextPublicationTask=nil;contextPublicationID=nil
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
      let laser = laserContext.take(scope:.init(computer:submittedComputer,thread:submittedThread))
      let task = Task { [self] in
        var saved = false
        defer { isSavingAgentQuestion = false; chatSubmissionTask = nil; onSaved?(saved) }
        do {
          let context = try await captured.prepare()
          let images = Array((await NotebookLaserContext.images(laser)).prefix(max(0,16-captured.attachments.count)))
          let author = actorID
          let imageAttachments = images.isEmpty ? [] : try await persistence.submit(publishesChanges:true) {
            try $0.saveChatImageAttachments(images,author:author)
          }
          let attachments = captured.attachments + imageAttachments
          guard chat.computerID == submittedComputer else { throw NotebookTransportError.disconnected }
          saved = await chat.sendMessage(threadID: submittedThread, text: submittedText, context: context.text,
            attentionContextID: context.attentionContextID, steeringTurnID: submittedTurn, attachments: attachments,
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
      retainedSource?.resumePrograms()
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
                .withProgramSemanticSelection(visual?.semanticSelections[reference.id])
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
          "meaning": .string("Read frozen attention inside notebook_execute with await nb.attention({contextID, referenceID}); use emitImage(result.data.artifact) when present. notebook_context gives compact current context; Reads return {data,basis,coverage,cursor}; nb.transaction(key,{base:snapshot.basis,summary,operations}) returns immutable ActionResult. Consult nb.help(topic) only when needed. Shared Notebook workspace. Selection directs attention, not permissions. Use nb.reference, nb.transaction, nb.undo and nb.action for source/version checks, undoable edits and separate saved/received/shown receipts. For code notes use nb.code and the appendInkStroke operation on codeFragment. Use notebook://code/UUID for the read fragment, or fileLink with the required 1-based line query, in Markdown references. These links scroll only the document. A local draft is not yet the working file on Mac. Do not move the board camera.")
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
    if !replacesPendingShow { rememberReturnPlace() }
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
      if !inputGate.isActive {
        guard await checkpointPrograms(resume: true) else {
          showCue("Не удалось сохранить состояние программы"); return false
        }
        if inputGate.isActive { continue }
        return !Task.isCancelled && !isStopped && isCurrent()
      }
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

  func rememberReturnPlace() {
    guard let presence, returnPlaces.last?.presence != presence else { return }
    returnPlaces.append(.init(presence: presence, pageID: presence.notebookPageID,
      reading: presence.focusedItemID.flatMap { documentReadingPositions[$0] }))
    returnPlaces = Array(returnPlaces.suffix(32))
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

  func prepareAgentAttention(_ stage: NotebookPresentationPlayer.Stage?) async {
    agentFeedback.clearAttention()
    guard let stage, let references = stage.step.attention else { return }
    do {
      let subjects = try await persistence.submit { try $0.agentAttentionSubjects(references) }
      guard !Task.isCancelled, presentationPlayer.stage?.id == stage.id else { return }
      agentFeedback.setAttention(subjects,id:stage.id)
    } catch {
      guard !Task.isCancelled, presentationPlayer.stage?.id == stage.id else { return }
      presentationPlayer.interrupt("attention_source_changed")
    }
  }

  func undoCollaboration(_ id: UUID) {
    guard collaborationUndoTask == nil else { return }
    collaborationUndoTask = Task { [weak self] in
      guard let self else { return }
      if let pending=pendingCollaborationCommands[id],!(await pending.value) {
        collaborationUndoTask=nil
        return
      }
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

  func collaborationRevision(_ target: CollaborationTarget) -> String? {
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
      if let cohort { retireWorkingGraphics(in: cohort) }
      confirmAgentFeedback(presence: visible, scene: scene, cohort: cohort)
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
      guard preparationIsForeground, UIApplication.shared.applicationState == .active,
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

  private func checkpointPrograms(resume: Bool) async -> Bool {
    let spatial = Task { @MainActor in await AgentWebCoordinator.checkpointPrograms(ownedBy: self, resume: resume) }
    let document = Task { @MainActor in await DocumentRenderRegistry.shared.checkpointPrograms(resume: resume) }
    let spatialSaved = await spatial.value, documentSaved = await document.value
    return spatialSaved && documentSaved
  }

  func finishProgramBoundary() async -> Bool { await programBoundaryTask?.value ?? true }

  func setPreparationForeground(_ foreground: Bool) {
    guard preparationIsForeground != foreground else { return }
    preparationIsForeground = foreground
    let prior = programBoundaryTask
    programBoundaryTask = Task { @MainActor [weak self] in
      _ = await prior?.value
      guard let self, !isStopped else { return true }
      if foreground {
        await AgentWebCoordinator.resumePrograms(ownedBy: self)
        await DocumentRenderRegistry.shared.resumePrograms(); return true
      }
      let saved = await checkpointPrograms(resume: false)
      if !saved { showCue("Не удалось сохранить состояние программы") }
      return saved
    }
    if !foreground { agentFeedback.stop() }
    if foreground { documentShellPreparation?.allowPreparationAfterForeground() }
    else {
      // A system dialog can deactivate the scene before native ink obtains a
      // window. Retire that candidate, not the last installed composition.
      // The observed foreground admission restarts the view's same scene task.
      compositionTiles.cancelPreparation()
      documentShellPreparation?.retireUnused()
    }
  }

  /// A cached image proves preparation, not mounting. The completed display
  /// callback supplies the actual admitted generation; an overview region
  /// cannot acknowledge that its detailed sources were shown.
  func sceneRepresents(_ reference: CollaborationReference,
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
    let graph=presentedGraphicGraph(boardID:presence.boardID,cohort:cohort)
    return elements.allSatisfy { element in
      let plane: SceneCompositionPlane = reference.target.kind == .cover
        ? .cover(boardID: presence.boardID, itemID: reference.target.id) : .board(reference.target.id)
      let address = SceneSourceAddress(plane: plane, elementID: element.id)
      if element.kind == .nativeText || element.kind == .graphic {
        let graphic=graph.nodes[element.id]?.graphic
        let layout=element.kind == .graphic ? graph.resolve(element.id).layout : nil
        let size=CGSize(width:element.basis?.size.x ?? layout?.frame.width ?? element.frame.width,
          height:element.basis?.size.y ?? layout?.frame.height ?? element.frame.height)
        let cuts=elementErasures(on:element.surface,fallback:cohort.liveData.ink)[element.id] ?? []
        let appearance=elementErasureCache.preparedAppearance(surface:element.surface,id:element.id,
          graphic:graphic,layout:layout,size:size,erasures:cuts)
        return cohort.hasPresentedMaterials(address,sources:NotebookInkMaterialView.Content.required(
          graphic:graphic,layout:layout,erasures:cuts,appearance:appearance))
      }
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
    guard permitsExternalScenePublication, observedEpoch == collaborationReadEpoch,
      let current = presence, itemPins == scenePinnedItems else { return false }
    let moving = presencePhase == .active
    func withCurrentCamera(_ value: SessionPresence) -> SessionPresence {
      .init(boardID: value.boardID, mode: value.mode, camera: current.camera, viewport: current.viewport,
        focusedItemID: value.focusedItemID, openProgress: value.openProgress, documentPageIndex: value.documentPageIndex,
        selectedItemID: value.selectedItemID, notebookPageID: value.notebookPageID)
    }
    guard moving ? (withCurrentCamera(observedPresence) == current && withCurrentCamera(state.presence) == current)
      : current == observedPresence else { return false }
    acceptItemOwnerInvalidations(state, requested: itemPins)
    acceptSceneState(state, preservingPresence: moving ? current : nil)
    // This refresh may advance content, but no content contact is admitted.
    // Publish its finite window now, never an old camera from the SQL read.
    if moving { scheduleScenePreparation(coverageOnly: true) }
    return true
  }

  private func acceptSceneState(_ state: NotebookSceneState, preservingPresence: SessionPresence? = nil) {
    workspaceHeader = state.header
    sceneContentCursor = state.header.cursor
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
    spatialGroupReads = state.groupReads
    boardContentRevisions = state.boardContentRevisions
    spatialInk = state.ink
    loadedInkSurfaces = state.inkSurfaces
    pages = state.pages
    removeWorkingGraphics { graphic in
      graphic.surface.kind == .page
        && (graphic.publicationCursor.map { state.header.cursor >= $0 } ?? false)
    }
    pageAddresses = Dictionary(uniqueKeysWithValues: state.pagePositions.map {
      (PageAddress(itemID: $0.itemID, index: $0.index, root: $0.visibleRoot), $0.pageID)
    })
    documents = state.documents
    documentStates = state.states
    documentEditingSessions = state.drafts
    admitDocumentReading(state.reading)
    presence = preservingPresence ?? constrainedPaperPresence(state.presence)
    // A blank inline draft is intentionally absent from SQL. A scene refresh
    // cannot call that absence deletion. Once first input publishes, retain its
    // real identity so subsequent removal is handled normally.
    if var target = selectionSession.nativeText {
      switch target.reference {
      case .page(let owner,let id):
        if let element = pages[owner]?.element(id:id) { target.page = element }
      case .spatial(let owner,let id):
        if let element = boardHierarchy?.board(owner)?.element(id:id) { target.spatial = element }
      }
      selectionSession.nativeText = target
    }
    retireGraphicCommands(through: state.header.cursor)
    alignWorkspaceSelection()
    if selectionSession.elements.contains(where: { reference in
      // Accepted creation owns its presentation until its exact publication
      // cursor arrives. An earlier scene cut cannot turn that absence into a
      // deletion and silently discard a freshly completed lasso selection.
      guard !ownsUnpublishedTextDraft(reference), acceptedWorkingGraphic(reference) == nil else { return false }
      guard case .page(let pageID,let id) = reference, let page = pages[pageID] else { return false }
      return page.element(id:id) == nil
    }) { clearSelection() }
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

  private func enqueueStoreWrite(owner: NotebookPersistenceQueue.Owner? = nil, publishesChanges: Bool = true,
    reload: Bool = false, _ operation: @escaping @Sendable (NotebookStore) throws -> Void) {
    persistence.enqueue(owner: owner, publishesChanges: publishesChanges) { store in
      try operation(store)
      return reload
    }
  }

  func retryPendingPersistence() {
    AgentWebCoordinator.retryRetirements(ownedBy: self)
    DocumentRenderRegistry.shared.retryRetiringPrograms()
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
      await documentSourceEditor?.checkpoint()
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
      if let task = graphicCommandTask { _ = await task.value }
      if let task = contextPublicationTask { await task.value }
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
      || graphicCommandTask != nil || contextPublicationTask != nil)
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
      drawingTools.cancel()
      cancelRequestedNavigation()
      cancelDocumentOpening()
      documentShellPreparation?.stop(); documentShellPreparation = nil
      presentationPlayer.interrupt("closing")
      if let startupTask { await startupTask.value }
      accountContentTask?.cancel()
      await accountContentTask?.value
      accountContentTask = nil
      await accountConnection?.stop()
      await cloudSync?.stop()
      if let sync, !(await sync.stopAndDrainTrust()) { return false }
      sync = nil
      #if os(macOS)
        await commandServer?.stopAndDrain(); commandServer = nil
        codexSidecar?.detachView(); codexSidecar = nil
        await scriptCoordinator?.shutdown(); scriptCoordinator = nil
        let agentStopped = true
        await previewPublisher?.stop()
      #else
        await chatSubmissionTask?.value
        await chat?.stop()
        let agentStopped = true
      #endif
      #if os(macOS)
        programImporter?.stop()
      #endif
      let programsSaved = await checkpointPrograms(resume: false)
      let inputSaved = await finishPendingInteraction()
      // A failed quit keeps admission closed but leaves the same writer and
      // refresh owner available to the explicit repair/retry action. Terminal
      // teardown would otherwise make publicationFailure impossible to clear.
      guard agentStopped && inputSaved && programsSaved else { return false }
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
      agentFeedback.stop()
      referenceHighlightTask?.cancel(); cueTask?.cancel()
      if let task = collaborationUndoTask { await task.value }
      await elementErasureCache.stop()
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

  func showCue(_ text: String) {
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
    constrainedPaperPresence(presence.adapted(to: viewport, geometry: itemGeometry(presence.focusedItemID)))
  }

  private func constrainedPaperPresence(_ presence: SessionPresence) -> SessionPresence {
    #if os(iOS)
    guard (presence.mode == .page || presence.mode == .document), presence.openProgress == 1,
      let id = presence.focusedItemID,
      let center = boardHierarchy?.board(presence.boardID)?.focusedCenter(of: id) else { return presence }
    return presence.replacingCamera(itemGeometry(id).readingCamera(presence.camera,
      centeredOn: center, viewport: presence.viewport))
    #else
    return presence
    #endif
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

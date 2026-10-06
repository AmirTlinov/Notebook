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

  @ObservationIgnored let readAdmission = NotebookReadAdmission()
  @ObservationIgnored private let bootstrapAdmission = NotebookBootstrapAdmission()
  private(set) var loadState: LoadState = .loading {
    didSet {
      if loadState != .loading {
        bootstrapAdmission.resolve(acceptsWrites: loadState == .ready && !isClosing)
      }
    }
  }
  private(set) var workspace: WorkspaceIndex? {
    didSet {
      for id in Set(oldValue?.items.map(\.id) ?? []).union(workspace?.items.map(\.id) ?? []) {
        if oldValue?.item(id: id)?.kind != workspace?.item(id: id)?.kind
          || oldValue?.item(id: id)?.title != workspace?.item(id: id)?.title
          || oldValue?.notebookPageOrder(in: id)?.root != workspace?.notebookPageOrder(in: id)?.root
          || oldValue?.notebookPageOrder(in: id)?.count != workspace?.notebookPageOrder(in: id)?.count {
          if !acceptingSceneState { readAdmission.changed(.init(kind: .cover, id: id)) }
        }
      }
      collaborationReadEpoch &+= 1
      if oldValue != workspace { collaborationContentEpoch &+= 1 }
      scheduleScenePreparation()
    }
  }
  @ObservationIgnored private var acceptedPageSources: [UUID: NotebookPageSource] = [:]
  private(set) var pages: [UUID: PageDocument] = [:] {
    didSet {
      acceptedPageSources = acceptedPageSources.filter { pages[$0.key] != nil }
      elementErasureCache.retain(pages: pages)
      notebookPagePreparation.acceptedPages(pages, model: self)
      for id in oldValue.keys where pages[id] == nil { peerPublication.scopes[.init(kind: .page, id: id)] = nil }
      var changed = false
      for id in Set(oldValue.keys).union(pages.keys) {
        let a = oldValue[id], b = pages[id]
        if a?.inkSource.identity != b?.inkSource.identity || a?.elementSourceIdentity != b?.elementSourceIdentity
          || a?.drawingStamp != b?.drawingStamp || a?.agentStamp != b?.agentStamp || a?.size != b?.size {
          changed = true
          if !acceptingSceneState { readAdmission.changed(.init(kind: .page, id: id)) }
        }
      }
      collaborationReadEpoch &+= 1
      if changed { collaborationContentEpoch &+= 1 }
    }
  }
  let notebookPagePreparation = NotebookPagePreparationWindow()
  private typealias PageAddress = NotebookPagePreparationWindow.Address
  private var pageAddresses: [PageAddress: UUID] {
    get { notebookPagePreparation.addresses }
    set { notebookPagePreparation.addresses = newValue }
  }
  let notebookPageNavigation = NotebookPageNavigation()
  let pageInkPublication = NotebookPageInkPublication()

  func retainNotebookPageWindow(_ indices: Set<Int>, in itemID: UUID, root: String, target: Int? = nil,
    controllerID: UUID? = nil) {
    guard notebookPageRoot(itemID) == root else { return }
    if let controllerID, !indices.isEmpty,
      !notebookPageNavigation.isBound(ownerID: itemID, source: root, controllerID: controllerID) { return }
    let target = target.flatMap { indices.contains($0) && $0 < notebookPageCount(itemID) ? $0 : nil }
    notebookPagePreparation.retain(indices, in: itemID, root: root, target: target,
      targetIsLoaded: target.map { notebookPage(at: $0, in: itemID) != nil } ?? true, controllerID: controllerID)
  }

  func notebookPageCount(_ itemID: UUID) -> Int {
    workspace?.notebookPageOrder(in: itemID)?.count ?? 0
  }

  func notebookResidentPageIdentities(_ itemID: UUID) -> [Int: UUID] {
    guard let root = notebookPageRoot(itemID) else { return [:] }
    return Dictionary(uniqueKeysWithValues: pageAddresses.compactMap { address, id in
      address.itemID == itemID && address.root == root ? (address.index, id) : nil
    })
  }

  func notebookPageID(at index: Int, in itemID: UUID) -> UUID? {
    guard let root = notebookPageRoot(itemID) else { return nil }
    return pageAddresses[.init(itemID: itemID, index: index, root: root)]
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
    return pagePresentationSource(id)
  }

  /// The read window owns mounted source publication. Unmounted callers and
  /// the initial loading shell still read the accepted model dictionary.
  func pagePresentationSource(_ pageID: UUID) -> PageDocument? {
    notebookPagePreparation.acceptedPage(pageID) ?? pages[pageID]
  }

  /// An unloaded existing sheet never certifies a blank page. The requested
  /// immutable slot must still exist before its bytes can become UIKit content.
  func prepareNotebookPage(at index: Int, in itemID: UUID) async {
    guard let root = notebookPageRoot(itemID) else { return }
    await notebookPagePreparation.prepare(.init(itemID: itemID, index: index, root: root),
      isLoaded: { [weak self] address in self?.notebookPage(at: address.index, in: address.itemID) != nil },
      isCurrent: { [weak self] address in
        guard let self else { return false }
        return !isStopped && address.index >= 0 && address.index < notebookPageCount(address.itemID)
          && !isItemBeingDeleted(address.itemID) && notebookPageRoot(address.itemID) == address.root
      }, read: { [weak self] address in await self?.readNotebookPage(address) })
  }

  private func readNotebookPage(_ address: PageAddress) async {
    let itemID = address.itemID, index = address.index, root = address.root
    var previous: NotebookPagePreparation?
    while !Task.isCancelled, notebookPagePreparation.permits(address), presence != nil,
      !isItemBeingDeleted(itemID), notebookPageRoot(itemID) == root {
      let admission = readAdmission.begin()
      defer { readAdmission.end(admission) }
      do {
        // Only the accepted-write boundary belongs to the writer FIFO. The
        // existing scene reader owns decoding, alongside other scene reads.
        let _: Void = try await persistence.submit { _ in () }
        try Task.checkCancellation()
        let prepared = try await sceneReader.read { [actor = actorID, previous] store in
          try NotebookPagePreparation.read(store: store, itemID: itemID, index: index,
            root: root, actor: actor, reusing: previous)
        }
        previous = prepared
        try await peerPublication.wait(to: .init(kind: .page, id: prepared.page.id), carrier: itemID, scope: prepared.inputScope)
        try Task.checkCancellation()
        let isCurrent = try await persistence.submit { [actor = actorID] store in
          try prepared.isCurrent(store: store, actor: actor)
        }
        // A local admission may still await durability. Recheck its SQL cut,
        // retaining this immutable body if the addressed identity is equal.
        guard isCurrent, peerAllowsPublication(to: .init(kind: .page, id: prepared.page.id), carrier: itemID, scope: prepared.inputScope),
          readAdmission.permits(admission, targets: prepared.inputScope.publicationTargets) else { continue }
        guard !Task.isCancelled, notebookPagePreparation.permits(address), !isItemBeingDeleted(itemID),
          notebookPageRoot(itemID) == root, var workspace, let presence else { return }
        if notebookPage(at: index, in: itemID) != nil { return }
        let page = prepared.page
        try workspace.includePageProjection(prepared.projection, pageID: page.id, in: itemID)
        let wasAcceptingSceneState = acceptingSceneState
        acceptingSceneState = true
        defer { acceptingSceneState = wasAcceptingSceneState }
        self.workspace = workspace
        pageAddresses[address] = page.id
        pages[page.id] = page
        acceptedPageSources[page.id] = prepared.source
        peerPublication.scopes[.init(kind: .page, id: page.id)] = prepared.inputScope
        pencilUndoHistory.restore(prepared.undo, for: .page(page.id))
        pencilUndoHistory.restoreRedo(prepared.redo, for: .page(page.id))
        retainPreparedPages(near: address, selectedPageID: presence.notebookPageID, directoryChanged: false)
        return
      } catch NotebookStorageError.transactionConflict {
        guard !Task.isCancelled, notebookPagePreparation.permits(address) else { return }
        reloadExternalChanges()
        return
      } catch {
        guard !Task.isCancelled, notebookPagePreparation.permits(address) else { return }
        publicationFailure = error.localizedDescription
        persistenceFailure = error.localizedDescription
        return
      }
    }
  }

  /// A reference is a UUID intent, not an old page number. Resolve it and the
  /// physical notebook into one bounded scene, then publish only if no new
  /// input, selection, or cancellation overtook that read.
  func navigateToNotebookPage(id pageID: UUID, isCurrent: @MainActor () -> Bool) async -> Bool {
    while !Task.isCancelled, !isStopped, isCurrent() {
      guard await finishNavigationInput(destination: .init(kind: .page, id: pageID), isCurrent: isCurrent), !Task.isCancelled, !isStopped,
        let presence, isCurrent() else { return false }
      let admission = readAdmission.begin(), generation = inputGate.pencilGeneration
      defer { readAdmission.end(admission) }
      do {
        let _: Void = try await persistence.submit { _ in () }
        let state = try await sceneReader.read { [actor = actorID] store in
          try store.readTransaction { _ in
            guard let itemID = try store.ownerItemID(ofPage: pageID),
              try store.resolveNotebookPage(pageID, in: itemID) != nil,
              let boardID = try store.ownerBoardID(of: itemID) else { throw NotebookStorageError.transactionConflict }
            let selection = SessionPresence(boardID: boardID, mode: .page, camera: presence.camera,
              viewport: presence.viewport, focusedItemID: itemID, openProgress: 1,
              selectedItemID: itemID, notebookPageID: pageID)
            return try NotebookSceneState.read(store: store, presence: selection, viewport: presence.viewport, historyActor: actor)
          }
        }
        guard !Task.isCancelled, !isStopped, isCurrent() else { return false }
        let scope = state.inputScopes.first { $0.target.kind == .page && $0.target.id == pageID }
        try await peerPublication.wait(to: .init(kind: .page, id: pageID, boardID: state.presence.boardID),
          carrier: state.presence.selectedItemID, scope: scope, navigation: navigationGeneration)
        guard !Task.isCancelled, !isStopped, isCurrent() else { return false }
        let sourceIsCurrent = try await persistence.submit { [actor = actorID] store in try state.isCurrent(store: store, actor: actor) }
        guard !Task.isCancelled, !isStopped, isCurrent() else { return false }
        guard peerAllowsPublication(to: .init(kind: .page, id: pageID, boardID: state.presence.boardID), carrier: state.presence.selectedItemID, scope: scope), sourceIsCurrent, readAdmission.permits(admission, targets: state.readTargets),
          generation == inputGate.pencilGeneration, !inputGate.isActive else { continue }
        guard let itemID = state.presence.selectedItemID, !isItemBeingDeleted(itemID), state.presence.notebookPageID == pageID else { return false }
        // An already mounted reader owns visual selection. References use the
        // same explicit command as its arrows, never an implicit model-index
        // change. The source sheet and presence stay current until landing.
        if presence.mode == .page, presence.focusedItemID == itemID, presence.openProgress > 0,
          let root = notebookPageRoot(itemID), root == state.workspace.notebookPageOrder(in: itemID)?.root,
          let target = state.pagePositions.first(where: { $0.pageID == pageID }),
          notebookPageNavigation.isBound(ownerID: itemID, source: root) {
          return notebookPageNavigation.send(.jump(target.index), ownerID: itemID, source: root)
        }
        installSceneCut(state)
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

  private func retainPreparedPages(near address: PageAddress, selectedPageID: UUID?, directoryChanged: Bool = true) {
    let window = notebookPagePreparation.retainedIndices(in: address.itemID, root: address.root)
    let ordered = pages.keys.sorted { lhs, rhs in
      @MainActor func score(_ id: UUID) -> Int {
        if id == selectedPageID { return 0 }
        if id == pageAddresses[address] { return 1 }
        guard let location = pageAddresses.first(where: { $0.value == id && $0.key.root == address.root })?.key,
          location.itemID == address.itemID else { return 1_000 }
        if let window { return window.contains(location.index) ? 2 : 1_000 }
        return 2 + abs(location.index - address.index)
      }
      return score(lhs) == score(rhs) ? lhs.uuidString < rhs.uuidString : score(lhs) < score(rhs)
    }
    let retained = Set(ordered.prefix(4))
    let evicted = retained.count != pages.count
    if evicted { pages = pages.filter { retained.contains($0.key) } }
    let addresses = pageAddresses.filter { retained.contains($0.value) && notebookPageRoot($0.key.itemID) == $0.key.root }
    if addresses != pageAddresses { pageAddresses = addresses }
    // A page read only admits membership; it adds no directory nodes. Prune
    // after actual eviction or a directory edit, then publish that result once.
    if directoryChanged || evicted, var workspace {
      do { try workspace.retainPageProjection(retained); self.workspace = workspace }
      catch { publicationFailure = error.localizedDescription }
    }
  }

  private(set) var documents: [UUID: DocumentDocument] = [:] {
    didSet {
      for id in oldValue.keys where documents[id] == nil { peerPublication.scopes[.init(kind: .document, id: id)] = nil }
      for id in Set(oldValue.keys).union(documents.keys) where oldValue[id]?.contentStamp != documents[id]?.contentStamp {
        if !acceptingSceneState { readAdmission.changed(.init(kind: .document, id: id)) }
      }
      collaborationReadEpoch &+= 1
      if oldValue != documents { collaborationContentEpoch &+= 1 }
      if let opening = documentOpening { opening.sourceDidChange(documents[opening.request.documentID]) }
      validateDocumentPageNavigation(); scheduleScenePreparation()
    }
  }
  private(set) var documentEditingSessions: [DocumentEditingSession] = []
  @ObservationIgnored weak var documentSourceEditor: DocumentSourceEditorSession?
  let documentReading = DocumentReadingSession()
  @ObservationIgnored private var documentDraftEpoch: UInt64 = 0
  @ObservationIgnored private var documentOpening: DocumentRenderSession.Opening?
  private(set) var documentStates: [UUID: DocumentStateJournal] = [:] {
    didSet {
      for id in Set(oldValue.keys).union(documentStates.keys) where oldValue[id]?.stamp != documentStates[id]?.stamp {
        if !acceptingSceneState { readAdmission.changed(.init(kind: .document, id: id)) }
      }
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
      for id in Set(oldValue?.boards.map(\.id) ?? []).union(boardHierarchy?.boards.map(\.id) ?? [])
        where oldValue?.board(id) != boardHierarchy?.board(id) {
        if !acceptingSceneState { readAdmission.changed(.init(kind: .board, id: id)) }
      }
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
      // Action bodies are immutable at admission. Source membership and causal
      // gates identify this window without comparing sample trees on MainActor.
      if !Self.sameSpatialInkWindow(oldValue, spatialInk) {
        collaborationContentEpoch &+= 1
        for surface in loadedInkSurfaces { if let id = surface.ownerID {
          if !acceptingSceneState {
            readAdmission.changed(.init(kind: surface.kind == .cover ? .cover : .board, id: id))
          }
        } }
      }
    }
  }
  private static func sameSpatialInkWindow(_ previous: SpatialInkJournal?, _ current: SpatialInkJournal?) -> Bool {
    guard let previous, let current else { return previous == nil && current == nil }
    return previous.hasSameActionStates(as: current)
  }
  private(set) var spatialInkWindow: NotebookSpatialInkWindow?
  private(set) var spatialInkHistoryStates: [UUID: NotebookSpatialInkHistoryState] = [:]
  var loadedInkSurfaces: Set<SurfaceID> { Set(spatialInkWindow?.coverage.keys ?? Dictionary<SurfaceID, WorkspaceSpatialBounds>().keys) }
  func renderingInk(on surface: SurfaceID, fallback: SpatialInkJournal?) -> SpatialInkJournal? {
    loadedInkSurfaces.contains(surface) ? spatialInk : fallback
  }
  var lassoMembershipRevision:UInt64 { collaborationContentEpoch }
  let compositionTiles: SceneCompositionTiles
  let scenePublication: NotebookScenePublication
  var sceneIndex: WorkspaceSceneIndex? { scenePublication.index }
  var workspaceHeader: NotebookWorkspaceHeader? { scenePublication.sourceHeader }
  // The frontier and source header always name the same installed read.
  var sceneContentCursor: UInt64 { scenePublication.sourceHeader?.cursor ?? 0 }
  private(set) var committedHeader: NotebookWorkspaceHeader?
  private(set) var spatialGroupReads: [UUID:[String:NotebookElementGroupRead]] = [:]
  private(set) var documentPaperSizes: [UUID: WorkspaceItemGeometry] = [:]
  private(set) var sceneCoverage: [UUID: WorkspaceSpatialBounds] = [:]
  private(set) var truncatedSceneBoards: Set<UUID> = []
  private(set) var completeSceneCoverOwners: Set<UUID> = []
  private(set) var missingSceneElements: [UUID: Set<String>] = [:]
  var scenePreparationPending: Bool { scenePublication.isPending }
  var sceneIndexGeneration: UInt64 { scenePublication.indexGeneration }
  var scenePublicationGeneration: UInt64 { scenePublication.publicationGeneration }
  @ObservationIgnored private var acceptingSceneState = false
  @ObservationIgnored private var sceneWindowTask: Task<Void, Never>?
  @ObservationIgnored private var requestedScenePresence: SessionPresence?
  @ObservationIgnored private var compositionPreparationPresence: SessionPresence?
  @ObservationIgnored private var scenePinnedElements: [UUID: [String]] = [:]
  @ObservationIgnored private var scenePinnedItems: [UUID: [UUID]] = [:]
  @ObservationIgnored private(set) var sceneQueryCount: UInt64 = 0

  private func scheduleScenePreparation(coverageOnly: Bool = false) {
    guard !isStopped, !acceptingSceneState, let workspace, let boardHierarchy else { return }
    scenePublication.prepare(workspace: workspace, hierarchy: boardHierarchy,
      paperSizes: documentPaperSizes, coverageOnly: coverageOnly)
  }

  private func publishPreparedSceneIfPossible() {
    // An optimistic placement must reach the accepted SQL cut before a local
    // portal camera can publish over that geometry.
    guard itemPlacementCommands.isEmpty else { return }
    scenePublication.publish { coverageOnly in
      peerAllowsCurrentPublication && (!inputIsActive || historyContactPermitsPublication
        || (coverageOnly && !inputGate.hasActivePencil))
    }
  }

  /// Pages are read from their current catalog owner, independently of the
  /// background geometry generation and any preceding membership changes.
  func itemForDisplay(id: UUID) -> WorkspaceItem? {
    isItemBeingDeleted(id) ? nil : workspace?.item(id: id)
  }

  func scenePortalCamera(boardID: UUID) -> BoardPortalCamera? { scenePublication.portals[boardID] }

  /// Opt-in, read-only state at the same native presentation boundary as pixels.
  /// A blank physical scene must be distinguishable from an unready document.
  var scenePreparationDiagnostic: String? {
    guard documentMeasurements.enabled else { return nil }
    let id = presence?.focusedItemID
    let cohort = compositionTiles.published
    return "focus=\(id?.uuidString ?? "none") body=\(id.flatMap { documents[$0] } != nil) state=\(id.flatMap { documentStates[$0] } != nil) opening=\(documentOpening?.request.documentID.uuidString ?? "none") openingTask=\(documentOpening?.task != nil) indexed=\(id.flatMap { sceneIndex?.item(id: $0) } != nil) scenePending=\(scenePreparationPending) permits=\(permitsScenePreparation) input=\(inputIsActive) peerInput=\(peerInputIsActive) composing=\(compositionTiles.isPreparing) cohortBoard=\(cohort?.plan.rootBoardID.uuidString ?? "none") live=\(id.map { id in cohort?.plan.liveOwners.contains { $0.id == .item(id) } == true } ?? false) paint=\(cohort?.isPaintInstalled == true) failure=\(persistenceFailure ?? publicationFailure ?? compositionTiles.failure ?? "none")"
  }

  func sceneWorkset(presence: SessionPresence, pinned: Set<WorkspaceSpatialID> = [],
    limit: Int = WorkspaceSceneIndex.detailLimit, pixelScale: Double? = nil) -> WorkspaceSceneWorkset {
    sceneQueryCount &+= 1
    if sceneCoverage[presence.boardID]?.contains(NotebookSceneState.bounds(for: presence,
      margin: WorkspaceSceneIndex.preparationMargin(for: presence))) != true {
      requestSceneCoverage(presence)
    }
    return sceneIndex?.workset(presence: presence, pinned: pinned, limit: limit, pixelScale: pixelScale) ?? .empty
  }

  /// Called by scheduled scene preparation, never inline from a view body or native update.
  /// The camera can replace one pending coverage request without growing a queue.
  func prepareComposition(presence: SessionPresence, frame: WorkspaceSceneFrame?,
    pinned: Set<WorkspaceSpatialID>, displayScale: Double, installedItemOwners: [UUID: UUID] = [:],
    preparationOperationID: UUID? = nil) {
    compositionPreparationPresence = presence
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
    if missingPin || missingGroup || missingItemPin || sceneCoverage[presence.boardID]?.contains(NotebookSceneState.bounds(for: presence,
      margin: WorkspaceSceneIndex.preparationMargin(for: presence))) != true {
      requestSceneCoverage(presence)
    }
    // An addressed pin is still being fetched. Do not turn the previous
    // partial index into a failed complete source for this new request.
    if missingPin || missingGroup || missingItemPin || sceneCoverage[presence.boardID] == nil {
      compositionTiles.cancelPreparation(); return
    }
    guard permitsScenePreparation else { compositionTiles.cancelPreparation(); return }
    if scenePreparationPending {
      // Extending the same SQL cut must not cancel the image already on its
      // way to the screen. A changed content generation still invalidates it.
      if !scenePublication.isCoverageOnly { compositionTiles.cancelPreparation() }
      return
    }
    guard let header = workspaceHeader, let frame else { return }
    #if os(iOS)
    notebookPagePreparation.prepareCurrent(model: self, presence: presence, frame: frame, displayScale: displayScale,
      operationID: preparationOperationID)
    #endif
    let source = SceneCompositionSource(store: store, revision: header.cursor, workspaceID: header.workspaceID, groupPoses: compositionGroupPoses, inkWindow: spatialInkWindow, documentGeometry: documentPaperSizes)
    compositionTiles.prepare(source: source, presence: presence, frame: frame, pinned: pinned,
      displayScale: displayScale, refinesDetails: presencePhase == .settled,
      permitsPreparation: { [weak self] in self?.permitsScenePreparation == true },
      onSourceInvalidated: { [weak self] in self?.reloadExternalChanges() })
  }

  private func clearRemovedElementPins(in state: NotebookSceneState) {
    for (boardID, missingIDs) in state.missingPinnedElements {
      // A coverage read made before an accepted insertion cannot declare its
      // new editing pin deleted. The existing causal command owns that frontier.
      let ids = missingIDs.filter { id in
        let reference = EditableElementReference.spatial(boardID:boardID,elementID:id)
        if ownsUnpublishedTextDraft(reference) { return false }
        guard let command = elementCommandSources[reference] else { return true }
        guard let expected = command.accepted, let observed = state.elementSource(reference) else { return false }
        return observed.covers(expected)
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
    return try await persistence.submit(publishesChanges: publishesChanges, writesStore: true, operation)
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
        let admission = readAdmission.begin()
        defer { readAdmission.end(admission) }
        let draftEpoch = documentDraftEpoch
        let pins = scenePinnedElements, itemPins = scenePinnedItems
        let preparedIDs = preparedNotebookPageIDs(in: requested.selectedItemID)
        let inkPins = drawingTools.pinnedSpatialInkActionIDs
        // Selection admits its source through this same addressed read. A
        // cold document cannot wait for an unrelated peer refresh to appear.
        // Ordinary camera coverage still reads headers, not document bodies.
        let loadsDocument = requested.selectedItemID.map {
          workspace?.item(id: $0)?.kind == .document
            && (documents[$0] == nil || documentStates[$0] == nil)
        } ?? false
        do {
          let _: Void = try await persistence.submit { _ in () }
          let state = try await sceneReader.read { [actor = actorID] store in
            try NotebookSceneState.read(store: store, presence: requested,
              viewport: requested.viewport, loadsLiveContent: loadsDocument, pinnedElements: pins, pinnedItems: itemPins, preparedPages: preparedIDs, historyActor: actor, pinnedInkActionIDs: inkPins)
          }
          let sourceIsCurrent = try await persistence.submit { [actor = actorID] store in try state.isCurrent(store: store, actor: actor) }
          guard sourceIsCurrent, readAdmission.permits(admission, targets: state.readTargets) else {
            // A body or selection can publish while this addressed read waits.
            // Keep draining the latest requested destination, not the camera
            // it is preparing to leave. Never install the obsolete SQL cut.
            requestedScenePresence = requestedScenePresence ?? compositionPreparationPresence ?? self.presence
            continue
          }
          guard !Task.isCancelled, !isStopped else { return }
          guard !inputGate.hasActivePencil, peerAllowsPublication(of: requested, in: state) else {
            externalReloadPending = true; return
          }
          guard itemPins == scenePinnedItems else { requestedScenePresence = compositionPreparationPresence; continue }
          // A prepared destination is not yet the accepted location. Only the
          // latest composition request may publish its addressed read; reversing
          // or replacing the passage invalidates that request immediately.
          let current=compositionPreparationPresence ?? self.presence
          guard current?.boardID == requested.boardID,
            current?.focusedItemID == requested.focusedItemID,
            current?.selectedItemID == requested.selectedItemID else { continue }
          // Coverage carries a finite notebook window. A newer selection or
          // prepared neighbour cannot be replaced by this read's older window,
          // even when that newly loaded page was outside its content read set.
          // Camera movement alone does not revoke these addressed materials.
          guard current?.notebookPageID == requested.notebookPageID,
            preparedNotebookPageIDs(in: requested.selectedItemID) == preparedIDs else {
            requestedScenePresence = requestedScenePresence ?? current
            continue
          }
          installSceneCut(state, as: .coverage(loadsDocument: loadsDocument,
            preservesDocumentDraft: draftEpoch != documentDraftEpoch),
            preservingPresence: self.presence, itemPins: itemPins)
        } catch {
          guard !Task.isCancelled, !isStopped else { return }
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
  /// SwiftUI scene for every sample. A finite camera window wakes the existing
  /// composition task before the viewport leaves the prepared workset. Within
  /// that window only native projection runs; semantic/terminal changes publish
  /// normally.
  @ObservationIgnored private var presenceValue: SessionPresence?
  @ObservationIgnored private var cameraPreparationPresence: SessionPresence?
  private var presencePublication: UInt64 = 0
  private(set) var presence: SessionPresence? {
    get { _ = presencePublication; return presenceValue }
    set { setPresence(newValue, publishes: true) }
  }

  private func setPresence(_ value: SessionPresence?, publishes: Bool) {
    let previous = presenceValue
    guard previous != value else { return }
    presenceValue = value
    notebookPagePreparation.updatePresence(value)
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
    if publishes || cameraNeedsPreparation(value) {
      cameraPreparationPresence = value
      presencePublication &+= 1
    }
    if previous?.boardID != value?.boardID || previous?.mode != value?.mode
      || previous?.focusedItemID != value?.focusedItemID || previous?.notebookPageID != value?.notebookPageID
      || previous?.documentPageIndex != value?.documentPageIndex {
      drawingTools.releaseGuideIfSurfaceChanged()
      publishSelection()
    }
  }

  private func cameraNeedsPreparation(_ presence: SessionPresence?) -> Bool {
    guard let presence, let basis = cameraPreparationPresence,
      basis.boardID == presence.boardID, basis.viewport == presence.viewport else { return true }
    // Revisit the viewport-relative preparation window after 64 pt,
    // without querying the spatial index or restarting source jobs per sample.
    // Magnification also has to request detail when the viewport only shrinks.
    return !(0.6...sqrt(2.0)).contains(presence.camera.scale / basis.camera.scale)
      || !NotebookSceneState.bounds(for: basis, margin: 64)
        .contains(NotebookSceneState.bounds(for: presence, margin: 0))
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
        worldOrigin:nil,bounds:pagePresentationSource(value.target.id).map { .init(x:0,y:0,width:$0.size.width,height:$0.size.height) }),
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
  @ObservationIgnored private var navigationInputWaiters: [UUID: Task<Bool, Never>] = [:]
  let documentNavigation = DocumentPageNavigation()
  @ObservationIgnored var stopNavigationPresentation: ((UUID) -> Void)?
  let presentationPlayer = NotebookPresentationPlayer()
  let presentationRelay = NotebookPresentationRelay()
  var highlightedReference: CollaborationReference? { selectionSession.highlightedReference }
  let agentFeedback = NotebookAgentFeedback()
  private var referenceHighlightTask: Task<Void, Never>?
  private var collaborationHistoryTask: Task<Bool, Never>?
  private var collaborationHistoryRequest: UUID?
  private let surfaceHistory = NotebookSurfaceHistoryOwner()
  private var contextPublicationTask: Task<Void, Never>?
  private var contextPublicationID: UUID?
  private var collaborationReadSnapshot: CollaborationReadSnapshot?
  /// Publication/admission order rejects stale asynchronous scene reads, even
  /// when the accepted cut happens to contain the same source values.
  private(set) var collaborationReadEpoch: UInt64 = 0
  /// History preparation follows changed input values, not repeated SQL reads.
  /// This identity does not replace the scene publication frontier above.
  private var collaborationContentEpoch: UInt64 = 0
  private(set) var preparedCollaborationVersion: UInt64?
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
    @ObservationIgnored private var chatSubmissionError: String?
    @ObservationIgnored private var pendingChatSubmission: (computer: UUID?, destination: NotebookChatController.MessageDestination,
      text: String, steeringTurn: String?, context: ChatSubmissionContext)?
  #endif

  private(set) var actionCue: String?
  private(set) var penStyle: PenStyle
  private(set) var eraserStyle: EraserStyle
  var drawingToolSettings = NotebookDrawingToolSettings() {
    didSet { if let data = try? JSONEncoder().encode(drawingToolSettings) { preferences.set(data,forKey:"notebook.drawing-tool-settings") } }
  }
  @ObservationIgnored lazy var drawingTools = NotebookDrawingToolController(model:self)
  var activePenStyle: PenStyle { drawingTool == .marker ? drawingToolSettings.marker : penStyle }
  private(set) var drawingTool: DrawingTool = .pen
  private(set) var selectionSession = NotebookSelectionSession() {
    didSet {
      #if os(iOS)
      if oldValue.id != selectionSession.id || oldValue.elements != selectionSession.elements {
        selectedGraphicHosts.select(selectionSession)
      }
      #endif
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
    if let itemID, documents[itemID] != nil || workspace?.item(id: itemID)?.kind == .document {
      let page = presence?.focusedItemID == itemID && presence?.mode == .document ? (presence?.documentPageIndex ?? 0) : 0
      return documentGeometry(itemID, page: page)
    }
    return .notebook
  }

  let store: NotebookStore
  private let sceneReader: NotebookSceneReader
  private let commandReader: NotebookCommandReader
  func readClipboardTransfer(target:CollaborationTarget,rootIDs:[String],observedSources:[NotebookNativeElementSource],inkRevision:String?) async throws -> NotebookElementTransfer {
    try await sceneReader.read { store in
      try store.readElementTransfer(target:target,rootIDs:rootIDs,observedSources:observedSources,expectedInkRevision:inkRevision)
    }
  }
  func reserveClipboardWork(maximumCost: NotebookPersistenceAdmission.Cost) -> NotebookPersistenceAdmission.Reservation? {
    guard let reservation = persistence.reserveWrite(maximumCost) else {
      showCue("Сохранение заполнено. Повторите после восстановления записи."); return nil
    }
    return reservation
  }
  func releaseClipboardWork(_ reservation: NotebookPersistenceAdmission.Reservation) {
    persistence.releaseWriteReservation(reservation)
  }
  func resizeClipboardWork(_ reservation: NotebookPersistenceAdmission.Reservation,
    to cost: NotebookPersistenceAdmission.Cost) throws {
    try persistence.resizeWriteReservation(reservation, to: cost)
  }
  func beginClipboardWork() throws -> NotebookClipboardWorkLease {
    guard !isClosing, let reservation=reserveClipboardWork(maximumCost:.init(
      payloadBytes:96 * 1_024 * 1_024,completionBytes:96 * 1_024 * 1_024)) else {
      throw CollaborationError("resource_limit","Дождитесь завершения сохранения и повторите перенос.")
    }
    return .init(reservation:reservation) { [weak self] in
      Task { @MainActor [weak self] in self?.releaseClipboardWork(reservation) }
    }
  }
  func readClipboard(_ providers:[NSItemProvider],availableSize:SpatialPoint,
    workLease suppliedWork:NotebookClipboardWorkLease? = nil) async throws -> NotebookClipboard.Read {
    let work=try suppliedWork ?? beginClipboardWork()
    defer { withExtendedLifetime(work) {} }
    return .init(content:try await NotebookClipboard.read(providers,availableSize:availableSize),workLease:work)
  }
  func reserveElementPreparation() -> NotebookPersistenceAdmission.Reservation? {
    guard let reservation = persistence.reserveWrite(NotebookElementWriteAllowance.maximumCost) else {
      showCue("Сохранение заполнено. Повторите после восстановления записи."); return nil
    }
    return reservation
  }
  func releaseElementPreparation(_ reservation: NotebookPersistenceAdmission.Reservation) {
    persistence.releaseWriteReservation(reservation)
  }
  private let backgroundSceneReader: NotebookSceneReader
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
  @ObservationIgnored private var collaborationMetadataGeneration: UInt64 = 0
  private var arrivalFailure: String?
  @ObservationIgnored private let peerPublication: NotebookPeerPublication

  func peerAllowsPublication(to target: CollaborationTarget, carrier: UUID? = nil,
    scope: NotebookInputScope? = nil) -> Bool {
    peerPublication.allows(target,
      carrier: carrier ?? (target.kind == .page ? notebookPageOwner(target.id) : nil), scope: scope)
  }

  private func publicationTarget(_ presence: SessionPresence) -> CollaborationTarget {
    if presence.mode == .page, let id = presence.notebookPageID { return .init(kind: .page, id: id, boardID: presence.boardID) }
    if presence.mode == .document, let id = presence.focusedItemID { return .init(kind: .document, id: id, boardID: presence.boardID) }
    if presence.mode == .cover, let id = presence.focusedItemID { return .init(kind: .cover, id: id, boardID: presence.boardID) }
    return .init(kind: .board, id: presence.boardID)
  }

  private func peerAllowsPublication(of presence: SessionPresence, in state: NotebookSceneState) -> Bool {
    let target = publicationTarget(presence)
    return peerAllowsPublication(to: target, scope: state.inputScopes.first {
      $0.target.kind == target.kind && $0.target.id == target.id
    })
  }

  private var peerAllowsCurrentPublication: Bool {
    presence.map { peerAllowsPublication(to: publicationTarget($0)) } ?? true
  }

  private var cueTask: Task<Void, Never>?
  private var pencilUndoHistory = PencilUndoHistory()
  @ObservationIgnored private var pendingCollaborationCommands:[UUID:Task<Bool,Never>]=[:]
  private(set) var graphicCommandTask: Task<NotebookElementCommandResult?, Never>?
  @ObservationIgnored var pendingMaterialAdmissions:[SurfaceID:(id:UUID,task:Task<Void,Never>)] = [:]
  @ObservationIgnored private var graphicCommandGeneration = UUID()
  @ObservationIgnored var workingGraphics: [NotebookWorkingGraphic] = []
  @ObservationIgnored var workingGraphicSignals:[SurfaceID:NotebookWorkingGraphicSignal] = [:]
  #if os(iOS)
  @ObservationIgnored let selectedGraphicHosts = NotebookSelectedGraphicHosts()
  #endif
  var workingElementErasures: [UUID: [NotebookElementErasing]] = [:] {
    didSet { elementErasureCache.invalidateWorking() }
  }
  @ObservationIgnored let elementErasureCache = NotebookElementErasureCache()
  // Lift transfers its final draft to the accepted command. Its addressed
  // source and installed pixels retire it; the writer receipt retains it.
  var elementCommandDrafts: [EditableElementReference: NotebookElementCommandDraft] = [:]
  var itemPlacementCommands: [UUID: NotebookItemPlacementCommand] = [:]
  @ObservationIgnored var editingNativeTextReferences: Set<EditableElementReference> = []
  @ObservationIgnored var elementCommandSources: [EditableElementReference: NotebookElementCommand] = [:]
  var graphicCommandPending: Bool {
    graphicCommandTask != nil || !elementCommandDrafts.isEmpty || workingGraphics.contains { $0.accepted && $0.publicationCursor == nil }
  }
  private var reservedDrawingCounters: [UUID: UInt64] = [:]
  private struct DrawingReservationKey: Hashable { let pageID: UUID; let stamp: VersionStamp }
  private struct DrawingReservation {
    let page: PageDocument
    let write: NotebookPersistenceAdmission.Reservation
  }
  @ObservationIgnored private var drawingReservations: [DrawingReservationKey: DrawingReservation] = [:]
  @ObservationIgnored private var spatialDrawingReservations: [UUID: NotebookPersistenceAdmission.Reservation] = [:]
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
  @ObservationIgnored private var transportReader: NotebookTransportReader?
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
  private(set) var admittedWorkspaceID: UUID?
  struct AutomaticWorkspaceTransition: Equatable {
    fileprivate let id: UUID
    let workspaceID: UUID
    let cursor: UInt64
    let inputGeneration: UInt64
    let mutationGeneration: UInt64
  }
  @ObservationIgnored private var automaticWorkspaceTransition: AutomaticWorkspaceTransition?
  private var workspaceTransitionIsFrozen = false
  private(set) var pairedPeers: [NotebookTransportIdentity] = []
  @ObservationIgnored private var peerGenerations: [UUID: UUID] = [:]
  #if os(iOS)
    @ObservationIgnored let inputFrameMonitor: InputFrameMonitor?
  #endif
  @ObservationIgnored private var diskRefreshTask: Task<Void, Never>?
  @ObservationIgnored private var arrivalDrainTask: Task<Void, Never>?
  @ObservationIgnored private var arrivalDrainRequested = false
  @ObservationIgnored private var headerRefreshTask: Task<Void, Never>?
  @ObservationIgnored private var headerRefreshRequested = false
  @ObservationIgnored private var diskRefreshRequested = false
  @ObservationIgnored private var externalReloadPending = false
  private(set) var shutdownPhase = ShutdownPhase.running {
    didSet {
      if shutdownPhase != .running { bootstrapAdmission.resolve(acceptsWrites: false) }
    }
  }
  private var isStopped: Bool { shutdownPhase == .draining || shutdownPhase == .stopped }
  var permitsExternalWork: Bool { shutdownPhase == .running && !workspaceTransitionIsFrozen }
  private var isClosing: Bool { !permitsExternalWork }
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
  var peerInputIsActive: Bool { peerPublication.isActive }
  // Mounted view tasks can run before start() registers its writer. Until the
  // initial workspace is published, a read must not bootstrap SQLite beside it.
  // This admission also changes the history task's key when startup completes.
  var permitsBackgroundPreparation: Bool {
    loadState == .ready && !isStopped && automaticWorkspaceTransition == nil
      && !inputIsActive && !peerInputIsActive && presencePhase == .settled
  }

  /// A finger navigating paper must not suspend the destination it needs.
  /// Preparation reads immutable sources and cannot replace accepted ink or
  /// an active content edit. A focused program must not suspend immutable
  /// neighbours until the user dismisses its focus.
  var permitsPagePreparation: Bool {
    // The accepted SQL source can prepare while bootstrap persists presence.
    // Editing still waits for loadState.ready; immutable work must not lose its
    // only scene-demand edge merely because that independent write is pending.
    guard workspaceHeader != nil, workspace != nil, preparationIsForeground,
      !isStopped, !inputGate.hasActivePencil else { return false }
    switch loadState {
    case .loading, .ready: return true
    case .failed: return false
    }
  }

  /// Camera and whole-cover movement prepare newly exposed material through
  /// the existing owners. Accepted Pencil retains its geometry; unrelated
  /// background work waits for settlement through permitsBackgroundPreparation.
  var permitsScenePreparation: Bool {
    preparationIsForeground && !isStopped && !inputGate.hasActivePencil
      && (!inputIsActive || presencePhase == .active || hasSpatialGroupContact || historyContactPermitsPublication
        || compositionTiles.surfaceRegistry.hasMovingCover)
      && !workingGraphics.contains { $0.surface.kind == .board && $0.accepted
        && $0.publication == nil }
  }
  #if os(macOS)
    @ObservationIgnored var codexHost: NotebookCodexHost?
    @ObservationIgnored private var codexSidecar: NotebookCodexSidecar?
    @ObservationIgnored private var codexStartupTask: Task<Void, Never>?
    private(set) var agentStartupError: String?
    @ObservationIgnored private var commandServer: NotebookIPCServer?
    @ObservationIgnored private var scriptCoordinator: NotebookScriptCoordinator?
    private let commandSocketURL: URL?
    var runtimeStartupPending: Bool { startupTask != nil }
    var runtimeSocketKey: String? {
      commandServer == nil ? nil : commandSocketURL?.deletingPathExtension().lastPathComponent
    }
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
    expectedWorkspaceID: UUID? = nil,
    acceptance: NotebookAcceptanceConfiguration? = nil,
    persistenceQueue: NotebookPersistenceQueue? = nil,
    sceneReader: NotebookSceneReader? = nil,
    backgroundSceneReader: NotebookSceneReader? = nil,
    documentMeasurements: DocumentPresentationRecorder? = nil
  ) {
    self.store = store
    self.sceneReader = sceneReader ?? NotebookSceneReader(store: store)
    self.commandReader = NotebookCommandReader(store: store)
    self.backgroundSceneReader = backgroundSceneReader ?? NotebookSceneReader(store: store)
    self.allowsCodexRegistration = allowsCodexRegistration
    self.pairingActivationID = pairingActivationID
    self.preferences = preferences
    self.pairingService = pairingService
    self.opensDefaultAccountWorkspace = opensDefaultAccountWorkspace
    self.requiresExistingAccountContent = requiresExistingAccountContent
    admittedWorkspaceID = expectedWorkspaceID
    self.acceptance = acceptance
    self.documentMeasurements = documentMeasurements ?? DocumentPresentationRecorder(enabled: acceptance != nil
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
    peerPublication = NotebookPeerPublication(persistence: persistence, actorID: actorID)
    scenePublication = NotebookScenePublication(actorID: actorID)
    #if os(macOS)
      self.commandSocketURL = commandSocketURL ?? (startsNearbySync ? NotebookIPC.defaultSocketURL : nil)
    #endif
    scenePublication.onPrepared = { [weak self] in self?.publishPreparedSceneIfPossible() }
    inputGate.bindNewContactAdmission { [weak self] in
      self?.loadState == .ready && self?.permitsExternalWork == true
    }
    peerPublication.onFailure = { [weak self] error in
      self?.publicationFailure = error.localizedDescription
      self?.persistenceFailure = error.localizedDescription
    }
    peerPublication.onChange = { [weak self] in
      guard let self else { return }
      #if os(macOS)
        if peerPublication.isActive { previewPublisher?.suspendForInput() }
      #endif
      publishPreparedSceneIfPossible()
      if externalReloadPending, peerAllowsCurrentPublication { reloadExternalChanges() }
    }
    persistence.onFailureChange = { [weak self] message in
      guard let self else { return }
      persistenceFailure = message ?? arrivalFailure ?? publicationFailure
      surfaceHistory.setWriterBlocked(message != nil)
    }
    persistence.onContentMerged = { [weak self] in self?.reloadExternalChanges() }
    persistence.onCommit = { [weak self] owner in self?.didCommitDurableChanges(owner: owner) }
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

  private var localInputTargets: [CollaborationTarget] {
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
    return targets
  }

  private func didCommitDurableChanges(owner: NotebookPersistenceQueue.Owner?) {
    guard !isStopped else { return }
    sync?.notifyDurableChanges()
    if let cloudSync { Task { await cloudSync.notifyLocalChanges() } }
    switch owner {
    case .page, .pageInk, .document, .documentState, .board, .spatialInk, .elementState:
      refreshCommittedHeader()
    default: break
    }
  }

  /// Arrival belongs to admitted phases, independently of camera/contact refresh.
  /// Each bounded batch releases the writer before the next one is enqueued.
  private func requestActionArrivalDrain() {
    #if os(iOS)
    guard loadState == .ready, !isStopped else { return }
    arrivalDrainRequested = true
    guard arrivalDrainTask == nil else { return }
    arrivalDrainTask = Task { [weak self] in
      guard let self else { return }
      defer { arrivalDrainTask = nil }
      while arrivalDrainRequested, !Task.isCancelled, !isStopped {
        arrivalDrainRequested = false
        do {
          let result = try await persistence.submit(writesStore: true) { [deviceID = actorID] in
            try $0.acknowledgeReceivedActions(deviceID: deviceID)
          }
          arrivalFailure = nil
          persistenceFailure = persistence.failure ?? publicationFailure
          if result.published > 0 { didCommitDurableChanges(owner: nil) }
          arrivalDrainRequested = arrivalDrainRequested || result.hasMore
        } catch {
          arrivalFailure = error.localizedDescription
          persistenceFailure = persistence.failure ?? arrivalFailure
          return
        }
      }
    }
    #endif
  }

  private func publishInputActivity() {
    guard !isStopped else { return }
    guard loadState == .ready else { return }
    inputSequence &+= 1
    let activity = NotebookInputActivity(deviceID: actorID, sessionID: presenceSessionID, sequence: inputSequence, targets: localInputTargets)
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
      enqueueStoreWrite(owner: .peerSession(peer.deviceID)) { try $0.beginSelectionPublication(deviceID: peer.deviceID, connectionID: generation) }
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
    peerPublication.disconnect(peerID)
    isPeerConnected = !peerGenerations.isEmpty
    enqueueStoreWrite(owner: .peerSession(peerID)) {
      try $0.resetInputActivity(deviceID: peerID)
      try $0.endSelectionPublication(deviceID: peerID, connectionID: generation)
    }
    #if os(macOS)
      if observedPeerID == peerID {
        observedPeerID = nil; peerPresenceEnvelope = nil
      }
    #endif
  }

  /// The app's one durable transport adapter. Native integration checks use the
  /// same writer, contact boundary and scene publication as an admitted peer.
  func makeTransportStorage() async throws -> NotebookTransportStorage {
    let source = try await performStoreCommand { [actorID] in try $0.replicationSource(deviceID: actorID) }
    guard !isClosing else { throw CollaborationError("owner_unavailable", "Notebook завершает работу.") }
    let reader = transportReader ?? NotebookTransportReader(store: store)
    transportReader = reader
    return NotebookTransportStorage(
      journalGeneration: source.generation,
      // Offering already committed content is a WAL read, just like its blobs.
      // A later native command may be waiting for preparation in the FIFO; it
      // cannot hold the preceding accepted change off the trusted connection.
      changes: { cursor, limit in
        try await reader.changes(after: cursor, limit: limit)
      },
      incomingCursor: { [weak self] peer in
        guard let self else { throw NotebookTransportError.disconnected }
        return try await self.performStoreCommand { try $0.admitReplicationSource(peer) }
      },
      acknowledgePeer: { [weak self] peer, cursor in
        guard let self else { throw NotebookTransportError.disconnected }
        try await self.performStoreCommand { try $0.acknowledgePeer(peerID: peer, through: cursor) }
      },
      // Offered hashes are already committed and immutable. Their bounded WAL
      // snapshot cannot sit behind the next native contact or scene reload.
      readBlobWindow: { requests in
        try await reader.blobs(requests)
      },
      stageBlobs: { [weak self] blobs in
        guard let self else { throw NotebookTransportError.disconnected }
        try await self.performStoreCommand { try $0.stageBlobs(blobs) }
      },
      prepareIncoming: { [weak self] delivery, blobs in
        guard let self else { throw NotebookTransportError.disconnected }
        return try await self.performStoreCommand { try $0.prepareIncomingBlobs(delivery, staging: blobs) }
      },
      applyRemoteChange: { [weak self] delivery in
        guard let self else { throw NotebookTransportError.disconnected }
        return try await self.applyDurableDelivery(delivery)
      })
  }

  private func startTrustedSync() async throws {
    guard sync == nil else { return }
    let workspaceID = try await persistence.submit { try $0.storedWorkspaceID() }
    let writer = persistence
    let storage = try await makeTransportStorage()
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
    // The storage adapter publishes the committed scene in applyDurableDelivery.
    // A second transport callback must not schedule the same full read again.
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
    let applied: (cursor: UInt64, changed: Bool)
    while true {
      guard !isClosing else { throw CollaborationError("owner_unavailable", "Notebook завершает работу.") }
      try Task.checkCancellation()
      let targets = localInputTargets
      do {
        applied = try await persistence.submit(publishesChanges: true) { store in
          let needsContent = try store.deliveryNeedsContent(delivery)
          let cursor: UInt64
          if let cloudAccount {
            cursor = try store.applyCloudDelivery(delivery, account: cloudAccount, protectingInputOn: targets)
          } else {
            cursor = try store.applyDelivery(delivery, protectingInputOn: targets)
          }
          return (cursor, needsContent)
        }
        break
      } catch let error as CollaborationError where error.code == "input_active" {
        // A conflicting merge rolled back, including its cursor. Wait outside
        // the writer for the contact and accepted tail, not on a polling timer.
        // Independent material does not enter this wait at all.
        await withCheckedContinuation { continuation in
          inputGate.performAfterIdle { continuation.resume() }
        }
      }
    }
    // A returning known transaction still validates and durably advances its
    // peer cursor. It did not publish content: rebuilding the scene for that
    // echo queues expensive reads ahead of the next actual peer edit.
    if awaitingAccountContent { resumeAccountContent() } else if applied.changed { reloadExternalChanges() }
    if delivery.isSnapshot { sync?.receivedCheckpoint(from: delivery.source.deviceID) }
    return applied.cursor
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
    guard let transition = await prepareAutomaticWorkspaceSwitch() else { return false }
    rollbackAutomaticWorkspaceSwitch(transition)
    return true
  }

  /// Preparation borrows the live source. New input remains admitted while a
  /// destination opens, and invalidates this exact attempt rather than closing
  /// the retained runtime owner.
  func prepareAutomaticWorkspaceSwitch() async -> AutomaticWorkspaceTransition? {
    guard let cursor = initialAccountWorkspaceCursor, let workspaceID = admittedWorkspaceID,
      loadState == .ready, permitsExternalWork, automaticWorkspaceTransition == nil,
      !inputGate.isActive else { return nil }
    let transition = AutomaticWorkspaceTransition(id: UUID(), workspaceID: workspaceID, cursor: cursor,
      inputGeneration: inputGate.acceptedContactGeneration, mutationGeneration: persistence.acceptedMutationGeneration)
    automaticWorkspaceTransition = transition
    #if os(macOS)
      // Derived jobs cannot enqueue another store observation/publication
      // behind this source cut. Existing accepted commands keep their FIFO.
      previewPublisher?.suspendForInput()
    #endif
    var prepared = false
    defer { if !prepared { rollbackAutomaticWorkspaceSwitch(transition) } }
    guard await finishPendingInteraction(boundary: .acceptedInput, continuing: {
      self.automaticWorkspaceTransition == transition
        && self.automaticWorkspaceInputIsUnchanged(transition)
    }), automaticWorkspaceInputIsUnchanged(transition), (try? store.currentChangeCursor()) == cursor else { return nil }
    prepared = true
    return transition
  }

  private func automaticWorkspaceInputIsUnchanged(_ transition: AutomaticWorkspaceTransition) -> Bool {
    shutdownPhase == .running && loadState == .ready && admittedWorkspaceID == transition.workspaceID && !inputGate.isActive
      && inputGate.acceptedContactGeneration == transition.inputGeneration
      && persistence.acceptedMutationGeneration == transition.mutationGeneration
  }

  /// Freeze and durable catalog selection run in one uninterrupted MainActor
  /// turn. No await, executor request, or terminal shutdown belongs between them.
  func freezeAutomaticWorkspaceSwitch(_ transition: AutomaticWorkspaceTransition) throws -> Bool {
    // Preparation completed the accepted writer fence. An unchanged acceptance
    // generation proves that its whole write prefix is still drained; later
    // pure read observers neither edit this source nor revoke its cut.
    guard automaticWorkspaceTransition == transition, !workspaceTransitionIsFrozen,
      automaticWorkspaceInputIsUnchanged(transition) else { return false }
    workspaceTransitionIsFrozen = true
    do {
      guard try store.currentChangeCursor() == transition.cursor else {
        rollbackAutomaticWorkspaceSwitch(transition); return false
      }
      return true
    } catch { rollbackAutomaticWorkspaceSwitch(transition); throw error }
  }

  func commitAutomaticWorkspaceSwitch(_ transition: AutomaticWorkspaceTransition) {
    guard automaticWorkspaceTransition == transition, workspaceTransitionIsFrozen else { return }
    automaticWorkspaceTransition = nil; workspaceTransitionIsFrozen = false
  }

  func rollbackAutomaticWorkspaceSwitch(_ transition: AutomaticWorkspaceTransition) {
    guard automaticWorkspaceTransition == transition else { return }
    automaticWorkspaceTransition = nil; workspaceTransitionIsFrozen = false
  }

  /// Identity is admitted once from an exact local store cut, including an
  /// account replica which has its UUID but is still waiting for real content.
  func admitWorkspaceIdentity(_ workspaceID: UUID) throws {
    guard admittedWorkspaceID == nil || admittedWorkspaceID == workspaceID else {
      throw NotebookStorageError.invalidTransaction("workspace identity changed")
    }
    admittedWorkspaceID = workspaceID
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
    peerPublication.stop()
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
    let id = presence?.boardID ?? workspace?.rootBoardID ?? WorkspaceRoot.boardID
    return boardHierarchy.board(id).map { acceptedPlacementBoard($0, boardID: id) }
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
    if let startupTask { _ = await persistence.waitForLifecycle(startupTask); return }
    guard !started else { return }
    started = true
    notebookPageSize = pageSize
    let startup = Task<Void, Never> { [weak self] in
      guard let self else { return }
      defer { startupTask = nil }
      await loadInitialState(pageSize: pageSize,
        viewport: viewport ?? .init(x: pageSize.width, y: pageSize.height))
    }
    startupTask = startup
    _ = await persistence.waitForLifecycle(startup)
  }

  /// The workspace transition retains this join after its UI/IPC observer has
  /// reported a storage fault. Only Retry may release the accepted startup.
  func finishStartup() async { await startupTask?.value }

  func waitForPersistenceLifecycle<Value: Sendable>(_ work: Task<Value, Never>) async
    -> NotebookPersistenceQueue.LifecycleResult<Value> {
    await persistence.waitForLifecycle(work)
  }

  private func loadInitialState(pageSize: PageSize, viewport: SpatialPoint) async {
    do {
      if requiresExistingAccountContent {
        let (hasScene, workspaceID) = try await persistence.submit { store in
          try (store.hasWorkspaceContent(), store.storedWorkspaceID())
        }
        try admitWorkspaceIdentity(workspaceID)
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
      let observesStartup = NotebookNavigationObservation.onWebPreparation != nil
      NotebookNavigationObservation.webPreparation("startup_store_requested", ownerID: actor)
      let preparation = try await persistence.submit(writesStore: true) { store in
        let began: ContinuousClock.Instant? = observesStartup ? .now : nil
        let state = try NotebookSceneState.start(store: store, actor: actor, pageSize: pageSize,
          notebookID: notebookID, pageID: pageID, viewport: viewport)
        let ended: ContinuousClock.Instant? = observesStartup ? .now : nil
        return (state, began, ended)
      }
      if let began = preparation.1, let ended = preparation.2 {
        NotebookNavigationObservation.webPreparation("startup_store_began", ownerID: actor, at: began)
        NotebookNavigationObservation.webPreparation("startup_store_ended", ownerID: actor, at: ended)
      }
      let stored = preparation.0
      NotebookNavigationObservation.webPreparation("startup_store_resumed", ownerID: actor)
      guard installSceneCut(stored) else { throw NotebookStorageError.transactionConflict }
      presence = settledPresence(from: stored.presence, viewport: viewport)
      NotebookNavigationObservation.webPreparation("startup_state_installed", ownerID: actor)
      if let presence {
        let selection = presence.selectedItemID.flatMap { workspace?.item(id: $0) }
          ?? stored.workspace.selectedItem
        let pageID = presence.notebookPageID.flatMap { selection.pageIDs.contains($0) ? $0 : nil }
          ?? selection.pageIDs.first
        let presence = presence.selecting(itemID: selection.id, pageID: pageID)
        self.presence = presence
        alignWorkspaceSelection()
        NotebookNavigationObservation.webPreparation("startup_presence_requested", ownerID: actor)
        try await persistence.submit(writesStore: true) { try $0.savePresence(presence) }
        NotebookNavigationObservation.webPreparation("startup_presence_installed", ownerID: actor)
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
      NotebookNavigationObservation.webPreparation("startup_load_ready", ownerID: actor)
      requestActionArrivalDrain()
      publishSelection()
      awaitingAccountContent = false
      reloadCollaborationMetadata()
      reloadExternalChanges()
      #if os(macOS)
        do { try await scripts().start() }
        catch { agentStartupError = error.localizedDescription }
        do { try startCommandServer() }
        catch { agentStartupError = error.localizedDescription }
        startPreviewPublication()
      #endif
      #if os(iOS)
        #if DEBUG
        let fixtureChat: NotebookChatController?
        do {
          let approvalFixture = try await NotebookApprovalFixture.make(persistence: persistence, author: actorID, directory: store.root)
          let syncFixture = try await NotebookChatFixture.make(persistence:persistence,author:actorID)
          let terminalFixture = try await NotebookTerminalFixture.make(persistence: persistence, author: actorID, directory: store.root)
          fixtureChat = approvalFixture ?? syncFixture ?? terminalFixture
        } catch { fixtureChat = nil; showCue(error.localizedDescription) }
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
        do { try await startTrustedSync() }
        catch { connectionState = .failed(error.localizedDescription) }
        #if os(macOS)
          await startCodexSidecar()
        #endif
      }
    } catch {
      NotebookNavigationObservation.webPreparation("startup_failure_enter", ownerID: actorID)
      loadState = .failed(error.localizedDescription)
      NotebookNavigationObservation.webPreparation("startup_failure_admission_rejected", ownerID: actorID)
      // Accepted immutable source may already own native preparation. Failure
      // withdraws that whole lifetime, not just the root view which borrowed it.
      let openingRead = documentOpening?.task
      abortBootstrapPreparations()
      NotebookNavigationObservation.webPreparation("startup_failure_executors_aborted", ownerID: actorID)
      cancelDocumentOpening()
      documentShellPreparation?.stop(); documentShellPreparation = nil
      let owners = scenePresentationOwners.values.compactMap(\.value)
      scenePresentationOwners.removeAll()
      for owner in owners { owner.uninstall() }
      let reads = [scenePublication.cancel(), sceneWindowTask, openingRead].compactMap { $0 }
        + notebookPagePreparation.stop()
      for read in reads { read.cancel() }
      NotebookNavigationObservation.webPreparation("startup_failure_composition_stop", ownerID: actorID)
      await compositionTiles.stop()
      NotebookNavigationObservation.webPreparation("startup_failure_readers_join", ownerID: actorID)
      for read in reads { await read.value }
      NotebookNavigationObservation.webPreparation("startup_failure_complete", ownerID: actorID)
      sceneWindowTask = nil; documentOpening = nil
    }
  }

  private func abortBootstrapPreparations() {
    AgentWebCoordinator.abortBootstrapPreparations(ownedBy: self)
    #if os(iOS)
      openDocumentPresentation?.abortBootstrapPreparation(); openDocumentPresentation = nil
      returnDocumentPresentation?.abortBootstrapPreparation(); returnDocumentPresentation = nil
    #endif
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

  /// File picker, Files/Finder and MCP converge on the same import owner.
  func importDocumentFile(_ url: URL) async throws -> UUID {
    guard loadState == .ready, !isClosing, let header = workspaceHeader else {
      throw CollaborationError("owner_unavailable", "Хранилище Notebook ещё не открыто.")
    }
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let boardID = presence?.boardID ?? header.rootBoardID
    let center = presence?.camera.center ?? WorldPoint(x: 0, y: 0)
    let request = try await Task.detached {
      try NotebookDocumentImportRequest.inspect(url, targetBoardID: boardID, center: center)
    }.value
    return try await importDocument(request).documentID
  }

  private func importDocument(_ request: NotebookDocumentImportRequest) async throws -> NotebookDocumentImportOwner.Result {
    let result = try await NotebookDocumentImportOwner.run(request, persistence: persistence, actor: actorID)
    pencilUndoHistory.recordCommand(domain: .document(result.documentID), actionID: result.actionID)
    reloadExternalChanges()
    return result
  }

  @discardableResult
  func createDocument(
    at center: WorldPoint,
    template: DocumentTemplate = .article
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
      entrypoint: template.entrypoint, files: template.files
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
    if let request = documentOpening?.request, request.documentID != itemID { cancelDocumentOpening() }
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
    documentReading.beginOpening(documentID, restoresReading: restoreReading)
    // A resolved reference may be outside the camera cache or on another board.
    // Its addressed SQL read validates kind and owner without moving the camera.
    let boardID = boardID ?? presence.boardID
    documentMeasurements.request(documentID: documentID, pageIndex: pageIndex, cause: .open)
    if presence.focusedItemID != documentID || presence.openProgress <= 0,
      let layout = readingLayout(documentID) {
      let geometry = layout.paper(on: pageIndex).geometry
      if documentPaperSizes[documentID] != geometry {
        documentPaperSizes[documentID] = geometry; scheduleScenePreparation()
      }
    }
    if let current = documentOpening, current.outcome == nil,
      current.request.documentID == documentID, current.request.boardID == boardID,
      current.request.pageIndex == pageIndex { return current.task }
    let predecessor = documentOpening?.task
    documentOpening?.cancel(superseded: true)
    let request = DocumentRenderSession.Opening.Request(documentID: documentID, boardID: boardID,
      workspaceID: workspaceHeader.workspaceID, pageIndex: pageIndex)
    let session = DocumentRenderRegistry.shared.session(documentID: documentID, resources: .shared)
    let policy = DocumentRenderSession.Opening.Policy(
      beginRead: { [weak self] in (self?.readAdmission.begin() ?? UUID(), self?.documentDraftEpoch ?? 0) },
      endRead: { [weak self] in self?.readAdmission.end($0) },
      fence: { [weak self] completed in
        guard let self else { completed(.failure(CancellationError())); return }
        persistence.enqueueCommand { _ in () } completion: { result in
          Task { @MainActor in completed(result) }
        }
      }, read: { [reader = sceneReader, actor = actorID] request in
        try await reader.read { store in
          try Task.checkCancellation()
          return try NotebookSceneState.readOpenedDocument(store: store, documentID: request.documentID,
            boardID: request.boardID, historyActor: actor)
        }
      }, isCurrent: { [weak self] request in
        guard let self else { return false }
        return !isClosing && documentOpening?.request.id == request.id
          && documentOpening?.outcome == nil && self.presence?.selectedItemID == request.documentID
          && self.workspaceHeader?.workspaceID == request.workspaceID && !isItemBeingDeleted(request.documentID)
      }, waitForPublication: { [weak self] opened, request in
        guard let self else { throw CancellationError() }
        try await peerPublication.wait(to: .init(kind: .document, id: request.documentID, boardID: request.boardID),
          scope: opened.inputScope, opening: request.id)
      }, accepts: { [weak self] opened, request, admission in
        guard let self else { throw CancellationError() }
        let current = try await persistence.submit { [actor = actorID] store in
          try opened.isCurrent(store: store, actor: actor)
        }
        return current && !Task.isCancelled && !isClosing && documentOpening?.request.id == request.id
          && self.presence?.selectedItemID == request.documentID && !isItemBeingDeleted(request.documentID)
          && peerAllowsPublication(to: .init(kind: .document, id: request.documentID, boardID: request.boardID), scope: opened.inputScope)
          && readAdmission.permits(admission, targets: opened.inputScope.publicationTargets)
      }, publish: { [weak self] opened, request, draftEpoch in
        guard let self else { return }
        peerPublication.scopes[.init(kind: .document, id: request.documentID)] = opened.inputScope
        documents[request.documentID] = opened.document
        pencilUndoHistory.restore(opened.history, for: .document(request.documentID))
        pencilUndoHistory.restoreRedo(opened.redoHistory, for: .document(request.documentID))
        documentStates[request.documentID] = opened.state
        admitDocumentReading(opened.reading)
        if draftEpoch == documentDraftEpoch {
          documentEditingSessions.removeAll { $0.edit.documentID == request.documentID }
          documentEditingSessions += opened.drafts
        }
      }, failed: { [weak self] error in
        self?.publicationFailure = error.localizedDescription
        self?.persistenceFailure = error.localizedDescription
      }, revoked: { [weak self] request in
        guard let self else { return }
        peerPublication.cancelOpening(request.id)
        observeNavigation("opening_body_cancelled", fields: ["documentID": .string(request.documentID.uuidString),
          "openingID": .string(request.id.uuidString)])
      }, observe: { [weak self] event, request in
        self?.observeNavigation(event, fields: ["documentID": .string(request.documentID.uuidString),
          "openingID": .string(request.id.uuidString)])
      })
    observeNavigation("opening_body_requested", fields: ["documentID": .string(documentID.uuidString),
      "openingID": .string(request.id.uuidString)])
    let accepted = documentStates[documentID] == nil ? nil : documents[documentID]
    let opening = DocumentRenderSession.Opening(session: session, store: store, request: request, policy: policy,
      accepted: accepted, predecessor: predecessor)
    documentOpening = opening
    return opening.task
  }

  func cancelDocumentOpening() { documentOpening?.cancel() }

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
    guard !isClosing, !isItemBeingDeleted(itemID), let removed = workspace?.item(id: itemID),
      let ownerID = boardHierarchy?.ownerBoardID(of: itemID),
      let contact = itemMoveSource(itemID, boardID: ownerID),
      let placement = contact.placements[itemID] else { return false }
    guard max(workspaceHeader?.itemCount ?? 0, workspace?.items.count ?? 0) > 1 else {
      showCue("Один рабочий элемент должен остаться")
      return false
    }
    let removedKind = removed.kind, removedTitle = removed.title
    do { _ = try NotebookItemWriteAllowance.deletionSourceCost(placement: placement, title: removedTitle) }
    catch { showCue(error.localizedDescription); return false }
    guard let sourceReservation = persistence.reserveWrite(NotebookItemWriteAllowance.sourceReadMaximumCost) else {
      showCue("Сохранение заполнено. Повторите после восстановления записи."); return false
    }
    guard let deletionReservation = persistence.reserveWrite(NotebookItemWriteAllowance.maximumCost) else {
      persistence.releaseWriteReservation(sourceReservation)
      showCue("Сохранение заполнено. Повторите после восстановления записи."); return false
    }
    defer {
      persistence.releaseWriteReservation(sourceReservation)
      persistence.releaseWriteReservation(deletionReservation)
    }
    // Cleanup retains only resident pages; the complete hidden extent belongs
    // to the maintained Core lifecycle cut, not a copied UI page-ID directory.
    let loadedPageIDs = Set(removed.pageIDs.filter { pages[$0] != nil })
      .union(pageAddresses.filter { $0.key.itemID == itemID }.values)
    let actor = actorID, actionID = UUID(), previous = contact.dependencies[itemID]
    // A native Delete names the whole item. Capture its complete maintained
    // extent once at this FIFO cut, after its accepted local writes. The second
    // fence retains that exact basis across storage failures, never refreshing
    // hidden peer material on retry or manufacturing a board clock in the UI.
    let sourcePreparation = Task { () throws -> NotebookPersistenceQueue.PreparedCommand<(NotebookItemLifecycle, WorkspacePlacement)> in
      let expected: WorkspacePlacement
      if let previous {
        guard let saved = await previous.task.value?.placements[itemID] else {
          throw CollaborationError("revision_conflict", "Предыдущее перемещение не было сохранено.")
        }
        expected = saved
      } else { expected = placement }
      let cost = try NotebookItemWriteAllowance.deletionSourceCost(placement: expected, captured: placement,
        title: removedTitle)
      return .init(cost: cost, operation: { store in
        let source = try store.readNativeDeletionSource(itemID: itemID, boardID: ownerID,
          placement: expected, kind: removedKind, title: removedTitle)
        return (source, expected)
      })
    }
    let sourceRead: Task<(NotebookItemLifecycle, WorkspacePlacement), Error>
    do { sourceRead = try persistence.enqueuePreparedCommand(reservation: sourceReservation, sourcePreparation) }
    catch { sourcePreparation.cancel(); showCue(error.localizedDescription); return false }
    let deletionPreparation = Task { () throws -> NotebookPersistenceQueue.PreparedCommand<NotebookWorkspaceHeader> in
      let (source, placement) = try await sourceRead.value
      let cost = try NotebookItemWriteAllowance.deletionCost(source: source, placement: placement,
        loadedPageCount: loadedPageIDs.count)
      let accepted = NotebookNativeCommand(deleting: source, placement: placement, actionID: actionID, actor: actor)
      return .init(cost: cost, operation: { (store: NotebookStore) in
        _ = try accepted.apply(to: store)
        // Session selection is an adapter effect, never another content writer.
        let presence = try store.loadPresence()
        if try store.readItemHeader(itemID) == nil,
          presence.selectedItemID == itemID, let replacement = try store.readItemHeaders(limit: 1).first {
          try store.savePresence(presence.selecting(itemID: replacement.id, pageID: replacement.firstPageID))
        }
        return try store.workspaceHeader()
      })
    }
    let saved: Task<NotebookWorkspaceHeader, Error>
    do { saved = try persistence.enqueuePreparedCommand(reservation: deletionReservation,
      deletionPreparation, publishesChanges: true) }
    catch { deletionPreparation.cancel(); showCue(error.localizedDescription); return false }
    pendingDeletions[itemID] = loadedPageIDs
    pencilUndoHistory.recordCommand(domain: .board(ownerID), actionID: actionID)
    readAdmission.changed(.init(kind: .board, id: ownerID))
    readAdmission.changed(.init(kind: .cover, id: itemID))
    collaborationReadEpoch &+= 1; collaborationContentEpoch &+= 1
    let completion = Task { [self] in
      defer { pendingCollaborationCommands[actionID] = nil }
      do {
        let header = try await saved.value
        completedDeletions[itemID] = header.cursor
        notifyItemOwnerUnavailable(itemID, on: ownerID, through: header.cursor, deleted: true)
        scenePinnedItems = scenePinnedItems.mapValues { $0.filter { $0 != itemID } }
        for pageID in loadedPageIDs {
          persistence.discardPending(owner: .page(pageID))
          pages[pageID] = nil
          reservedDrawingCounters[pageID] = nil
          pencilUndoHistory.discardChanges(for: .page(pageID))
        }
        pageAddresses = pageAddresses.filter { $0.key.itemID != itemID }
        documents[itemID] = nil; documentStates[itemID] = nil
        collaborationReadEpoch &+= 1; collaborationContentEpoch &+= 1
        // A queued Undo may already await this accepted command. Publication
        // can follow it, but completion must not wait for a read behind Undo.
        if reloadExternalChanges() == nil { externalReloadPending = true }
        switch removedKind {
        case .notebook: showCue("Тетрадь удалена")
        case .document: showCue("Документ удалён")
        case .board: showCue("Доска удалена")
        }
        return true
      } catch {
        pendingDeletions[itemID] = nil
        pencilUndoHistory.discardCommand(domain: .board(ownerID), actionID: actionID)
        collaborationReadEpoch &+= 1; collaborationContentEpoch &+= 1
        reloadExternalChanges(); showCue(error.localizedDescription)
        return false
      }
    }
    pendingCollaborationCommands[actionID] = completion
    let deleted = await completion.value
    if deleted, let publication = reloadExternalChanges() { await publication.value }
    return deleted
  }

  /// One lift enters the same causal FIFO as ink, elements and Undo. The
  /// immediate pose is only a draft; saved heads come from this exact command.
  @discardableResult
  func moveItem(_ itemID: UUID, to center: WorldPoint, onto targetID: UUID? = nil,
    source retained: NotebookItemMoveSource? = nil) -> NotebookItemPlacementCommand? {
    guard !isClosing, center.isValid, let boardID = presence?.boardID,
      let source = retained ?? itemMoveSource(itemID, boardID: boardID),
      source.boardID == boardID, source.itemID == itemID,
      itemMoveSourceIsCurrent(source),
      let canonical = boardHierarchy?.board(boardID) else { return nil }
    var sources = source.placements, dependencies = source.dependencies
    if let targetID {
      guard let target = itemMoveSource(targetID, boardID: boardID) else { return nil }
      sources.merge(target.placements) { first, _ in first }
      dependencies.merge(target.dependencies) { first, _ in first }
    }
    guard (1...10).contains(sources.count), sources.keys.allSatisfy({ !isItemBeingDeleted($0) }) else { return nil }
    let summary = targetID == nil ? "Перенос предмета" : "Перенос в стопку"
    let maximumCost: NotebookPersistenceAdmission.Cost
    do {
      try sources[itemID]?.requireAuthoredActorRoom(actorID)
      if let targetID, WorkspacePlacementDraft.requiresTargetAuthorship(targetID,
        afterMoving: [itemID], sources: Array(sources.values)) {
        try sources[targetID]?.requireAuthoredActorRoom(actorID)
      }
      maximumCost = try NotebookItemWriteAllowance.placementReservationCost(captured: Array(sources.values),
        operationCount: targetID == nil ? 1 : 2, summary: summary)
    } catch NotebookStorageError.limitExceeded { showCue(NotebookItemWriteAllowance.limit().localizedDescription); return nil
    } catch { showCue(error.localizedDescription); return nil }
    guard let reservation = persistence.reserveWrite(maximumCost) else {
      showCue("Сохранение заполнено. Повторите после восстановления записи."); return nil
    }
    defer { persistence.releaseWriteReservation(reservation) }
    let actionID = UUID(), actor = actorID, target = CollaborationTarget(kind: .board, id: boardID)
    let operations: [CollaborationOperation], poses: [UUID: WorkspacePlacementPose]
    do {
      var values: [CollaborationOperation] = [.init(kind: .moveItem, target: target,
        id: itemID.uuidString, values: ["center": try .encode(center)])]
      if let targetID { values.append(.init(kind: .stackItems, target: target,
        values: ["itemIDs": try .encode([itemID, targetID])])) }
      let highest = itemPlacementCommands.values.reduce(canonical.highestZIndex) { highest, command in
        guard command.boardID == boardID, !command.rejected else { return highest }
        if let accepted = command.accepted {
          return accepted.placements.values.reduce(highest) { max($0, $1.pose?.zIndex ?? 0) }
        }
        return command.poses.values.reduce(highest) { max($0, $1.zIndex) }
      }
      let stackID = NotebookStore.submissionID(actionID, suffix: "stack:1")
      let draft = try WorkspacePlacementDraft(placements: Array(sources.values), moving: itemID,
        to: center, onto: targetID, highestZIndex: highest, stackID: stackID,
        stackIDIsAvailable: targetID == nil || !canonical.placements.contains { $0.pose?.stackID == stackID })
      operations = values; poses = draft.poses
    } catch { showCue(error.localizedDescription); return nil }
    let command = NotebookItemPlacementCommand(id: actionID, boardID: boardID, poses: poses)
    let captured = sources, predecessors = dependencies
    let preparation = Task { () throws -> NotebookPersistenceQueue.PreparedCommand<NotebookItemPlacementResult> in
      var expected: [WorkspacePlacement] = []
      for (id, source) in captured {
        if let previous = predecessors[id] {
          guard let value = await previous.task.value?.placements[id] else {
            throw CollaborationError("revision_conflict", "Предыдущее перемещение не было сохранено.")
          }
          expected.append(value)
        } else { expected.append(source) }
      }
      let cost = try NotebookItemWriteAllowance.placementCost(captured: Array(captured.values),
        resolved: expected, operations: operations, summary: summary)
      let accepted = NotebookNativeCommand(operations, summary: summary,
        placements: expected, actionID: actionID, actor: actor, maximumExecutionBytes: cost.completionBytes)
      return .init(cost: cost, operation: { store in
        let result = try accepted.apply(to: store)
        guard let header = try store.readBoardNodeHeader(boardID)?.board else {
          throw CollaborationError("target_missing", "Не найдена доска принятого перемещения.")
        }
        return .init(cursor: try store.currentChangeCursor(),
          placements: Dictionary(uniqueKeysWithValues: result.sources.map { ($0.id, $0) }), header: header)
      })
    }
    let saved: Task<NotebookItemPlacementResult, Error>
    do { saved = try persistence.enqueuePreparedCommand(reservation: reservation, preparation, publishesChanges: true) }
    catch { preparation.cancel(); showCue(error.localizedDescription); return nil }
    command.task = Task { [weak self] in
      guard let self else { return nil }
      defer { pendingCollaborationCommands[actionID] = nil }
      do {
        let result = try await saved.value
        command.accepted = result
        collaborationReadEpoch &+= 1; collaborationContentEpoch &+= 1
        reloadExternalChanges()
        return result
      } catch {
        preparation.cancel(); command.rejected = true
        for id in captured.keys where itemPlacementCommands[id]?.id == actionID { itemPlacementCommands[id] = nil }
        pencilUndoHistory.discardCommand(domain: .board(boardID), actionID: actionID)
        collaborationReadEpoch &+= 1; collaborationContentEpoch &+= 1
        showCue(error.localizedDescription); reloadExternalChanges()
        return nil
      }
    }
    for id in sources.keys { itemPlacementCommands[id] = command }
    pencilUndoHistory.recordCommand(domain: .board(boardID), actionID: actionID)
    pendingCollaborationCommands[actionID] = Task { await command.task.value != nil }
    boardContentRevisions[boardID] = nil
    readAdmission.changed(.init(kind: .board, id: boardID))
    for id in sources.keys { readAdmission.changed(.init(kind: .cover, id: id)) }
    collaborationReadEpoch &+= 1; collaborationContentEpoch &+= 1
    if targetID != nil { showCue("Стопка") }
    return command
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

  @discardableResult
  func rememberBoardReturn(_ child:SessionPresence,portal:BoardPortalCamera) -> Bool {
    guard var hierarchy=boardHierarchy,let parent=hierarchy.parentBoardID(of:child.boardID) else { return false }
    let carriesPreparedGeometry=pendingCollaborationCommands.isEmpty && sceneIndex?.board(id:child.boardID)?.stamp == hierarchy.board(child.boardID)?.stamp
      && sceneIndex?.board(id:parent)?.stamp == hierarchy.board(parent)?.stamp
    if hierarchy.updatePortalCamera(portal,for:child.boardID,actor:actorID) { persistBoard(hierarchy) }
    if carriesPreparedGeometry { scenePublication.updatePortalCamera(portal, boardID: child.boardID) }
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
      documentNavigation.ownerChanged()
      documentReading.ownerChanged(to: presence, settled: settled)
    }
    let resolved: SessionPresence
    let selectionItem = presence.selectedItemID ?? presence.focusedItemID ?? self.presence?.selectedItemID
    let selectedPage = presence.notebookPageID
      ?? (selectionItem == self.presence?.selectedItemID ? self.presence?.notebookPageID : nil)
      ?? selectionItem.flatMap { workspace?.item(id: $0)?.pageIDs.first }
    let presence = presence.selecting(itemID: selectionItem, pageID: selectedPage)
    if let opening = documentOpening, opening.outcome == nil {
      let request = opening.request
      if presence.selectedItemID != request.documentID
        || (settled && (presence.boardID != request.boardID || presence.focusedItemID != request.documentID || presence.openProgress <= 0)) {
        cancelDocumentOpening()
      }
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
    #if os(iOS)
    let nativeOpening = true
    #else
    let nativeOpening = false
    #endif
    let onlyNativePoseChanged = previous.map { old in
      (old.openProgress == resolved.openProgress || nativeOpening)
        && old.boardID == resolved.boardID && old.mode == resolved.mode && old.viewport == resolved.viewport
        && old.focusedItemID == resolved.focusedItemID && old.selectedItemID == resolved.selectedItemID
        && old.notebookPageID == resolved.notebookPageID && old.documentPageIndex == resolved.documentPageIndex
        && (old.openProgress > 0) == (resolved.openProgress > 0)
        && (old.openProgress >= 0.999) == (resolved.openProgress >= 0.999)
    } == true
    setPresence(resolved, publishes: settled || !onlyNativePoseChanged)
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
    documentReading.position(for: documentID)
  }

  private func admitDocumentReading(_ reading: DocumentReadingPosition?) { documentReading.admit(reading) }

  private func readingLayout(_ documentID: UUID) -> DocumentLayoutRecord? {
    documents[documentID].flatMap { documentReading.layout(for: $0) }
  }

  private func documentGeometry(_ documentID: UUID, page: Int) -> WorkspaceItemGeometry {
    readingLayout(documentID)?.paper(on: page).geometry ?? documentPaperSizes[documentID] ?? .uncompiledDocument
  }

  func documentOpeningPage(_ documentID: UUID, fallback: Int) -> Int {
    documents[documentID].map { documentReading.openingPage(for: $0, fallback: fallback) } ?? fallback
  }

  func documentReadingCamera(_ documentID: UUID, page: Int, center: WorldPoint, viewport: SpatialPoint) -> SpatialCamera {
    documentReading.camera(for: documentID, geometry: documentGeometry(documentID, page: page), center: center, viewport: viewport)
  }

  func beginDocumentCameraInteraction() {
    guard let id = presence?.focusedItemID, documents[id] != nil else { return }
    documentReading.beginContact(id)
  }

  func acceptDocumentReadingLayout(_ layout: DocumentPageLayout, documentID: UUID) {
    guard let document = documents[documentID],
      let geometry = documentReading.accept(layout, document: document, presence: presence) else { return }
    if documentPaperSizes[documentID] != geometry {
      documentPaperSizes[documentID] = geometry; scheduleScenePreparation()
    }
    inputGate.performAfterPageContact { [weak self] in self?.restoreDocumentReadingIfPossible() }
  }

  private func restoreDocumentReadingIfPossible() {
    guard let presence, let id = presence.focusedItemID, let document = documents[id],
      let effect = documentReading.restore(document: document, presence: presence,
        center: boardHierarchy?.board(presence.boardID)?.focusedCenter(of: id),
        settled: presencePhase == .settled, inputIsActive: inputGate.isActive,
        selectionPending: documentNavigation.request != nil, contact: inputGate.acceptedContactGeneration) else { return }
    switch effect {
    case .page(let page): _ = selectDocumentPage(page, documentID: id, restoresReading: true)
    case .camera(let camera):
      applyPresence(.init(boardID: presence.boardID, mode: presence.mode, camera: camera,
        viewport: presence.viewport, focusedItemID: id, openProgress: presence.openProgress,
        documentPageIndex: presence.documentPageIndex, selectedItemID: presence.selectedItemID), settled: true)
    }
  }

  private func rememberDocumentReading() {
    guard let presence, let id = presence.focusedItemID, let document = documents[id],
      let position = documentReading.remember(document: document, presence: presence,
        center: boardHierarchy?.board(presence.boardID)?.focusedCenter(of: id),
        selectionPending: documentNavigation.request != nil,
        retaining: Set(documents.keys).union(returnPlaces.compactMap { $0.reading?.documentID })) else { return }
    enqueueStoreWrite(owner: .documentReading(id)) { try $0.saveDocumentReadingPosition(position) }
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
    if !restoresReading { documentReading.beginContact(documentID) }
    if documentNavigation.select(pageIndex, documentID: documentID,
      source: DocumentPageNavigation.sourceRevision(document), currentPage: presence.documentPageIndex) {
      documentMeasurements.request(documentID: documentID, pageIndex: pageIndex, cause: .page)
    }
    return pageIndex
  }

  /// Binding is not an observable write: UIViewControllerRepresentable may
  /// register its owner during update. Status/landing publication is deferred
  /// by the native controller and checked against this exact binding.
  func bindDocumentPageController(_ id: UUID, documentID: UUID, source: String) {
    guard documents[documentID].map(DocumentPageNavigation.sourceRevision) == source,
      presence?.mode == .document, presence?.focusedItemID == documentID else { return }
    documentNavigation.bind(id, documentID: documentID, source: source)
  }

  func unbindDocumentPageController(_ id: UUID) { documentNavigation.unbind(id) }

  private func acceptsDocumentPageController(_ id: UUID, documentID: UUID, source: String) -> Bool {
    !isClosing && documentNavigation.accepts(id, documentID: documentID, source: source)
      && documents[documentID].map(DocumentPageNavigation.sourceRevision) == source
      && presence?.mode == .document && presence?.focusedItemID == documentID
      && (presence?.openProgress ?? 0) >= 0.999 && !isItemBeingDeleted(documentID)
  }

  @discardableResult
  func acceptDocumentPageLanding(_ landing: DocumentPageLanding) -> Bool {
    guard acceptsDocumentPageController(landing.controllerID, documentID: landing.documentID, source: landing.sourceRevision),
      let presence, let document = documents[landing.documentID], documentNavigation.landed(landing) else { return false }
    documentReading.landed(landing, document: document, presence: presence, contact: inputGate.acceptedContactGeneration)
    if presence.documentPageIndex != landing.pageIndex {
      applyPresence(.init(boardID: presence.boardID, mode: presence.mode,
        camera: presence.camera, viewport: presence.viewport, focusedItemID: landing.documentID,
        openProgress: presence.openProgress, documentPageIndex: landing.pageIndex,
        selectedItemID: presence.selectedItemID, notebookPageID: presence.notebookPageID), settled: true)
    }
    if let document = documents[landing.documentID], let layout = DocumentRenderRegistry.shared.layout(document: document) {
      let geometry = layout.paper(on: landing.pageIndex).geometry
      if documentPaperSizes[landing.documentID] != geometry {
        documentPaperSizes[landing.documentID] = geometry; scheduleScenePreparation()
      }
    }
    if presencePhase == .settled { rememberDocumentReading() }
    completeDocumentSavePresentation()
    return true
  }

  func acceptDocumentPageNavigationStatus(_ status: DocumentPageNavigationStatus) {
    guard acceptsDocumentPageController(status.controllerID, documentID: status.documentID, source: status.sourceRevision) else { return }
    documentNavigation.receive(status)
  }

  func retryDocumentPageNavigation() {
    guard let status = documentNavigation.status, let failure = status.failure,
      status.requestID == documentNavigation.request?.id,
      acceptsDocumentPageController(status.controllerID, documentID: status.documentID, source: status.sourceRevision),
      let target = status.target else { return }
    documentMeasurements.request(documentID: status.documentID, pageIndex: target, cause: .page)
    failure.retry()
  }

  private func validateDocumentPageNavigation() {
    documentReading.validate(documents)
    documentNavigation.validate(documents)
  }

  @discardableResult
  func appendSpatialInk(
    tool: SpatialInkTool,
    color: SpatialInkColor,
    spans: [SpatialInkSpan],
    id: UUID = UUID()
  ) -> SpatialInkAction? {
    let cost: NotebookPersistenceAdmission.Cost
    do { cost = try NotebookInkWriteAllowance.cost(spans) }
    catch { showCue(error.localizedDescription); releaseSpatialDrawingReservation(id); return nil }
    guard let reservation = spatialDrawingReservations.removeValue(forKey: id) ?? persistence.reserveWrite(cost) else {
      showCue("Сохранение заполнено. Повторите после восстановления записи."); return nil
    }
    defer { persistence.releaseWriteReservation(reservation) }
    guard spans.allSatisfy({ surfaceAcceptsChanges($0.surface) }), var journal = spatialInk,
      let action = journal.append(
        tool: tool,
        color: color,
        spans: spans,
        actor: actorID,
        id: id
      )
    else { return nil }
    let command = NotebookSpatialInkCommand.append(action, journalStamp: journal.stamp)
    guard scheduleSpatialInkSave(command, reservation: reservation, cost: cost) else { return nil }
    spatialInk = journal
    spatialInkHistoryStates[action.id] = .init(result: command.expectedResult, surfaces: Set(action.spans.map(\.surface)))
    for surface in Set(action.spans.map(\.surface)) {
      if let domain = PencilUndoHistory.Domain(surface: surface) { pencilUndoHistory.recordAction(domain: domain, actionID: action.id) }
    }
    return action
  }

  func reserveSpatialDrawingAction(_ id: UUID) -> Bool {
    guard spatialDrawingReservations[id] == nil,
      let reservation = persistence.reserveWrite(NotebookInkWriteAllowance.maximumCost) else {
      showCue("Сохранение заполнено. Повторите после восстановления записи."); return false
    }
    spatialDrawingReservations[id] = reservation
    return true
  }

  func releaseSpatialDrawingReservation(_ id: UUID) {
    if let reservation = spatialDrawingReservations.removeValue(forKey: id) {
      persistence.releaseWriteReservation(reservation)
    }
  }

  private var activeHistoryDomain:PencilUndoHistory.Domain? {
    if presence?.mode == .document { return presence?.focusedItemID.map(PencilUndoHistory.Domain.document) }
    if isPageOpen { return activePage.map { .page($0.id) } }
    return presence.map { $0.focusedItemID.map(PencilUndoHistory.Domain.cover) ?? .board($0.boardID) }
  }

  func undoLastSurfaceAction() { performSurfaceHistory(redo: false) }
  func redoLastSurfaceAction() { performSurfaceHistory(redo: true) }

  /// One entry for gesture, keyboard and menu history. Each accepted contact
  /// retains its domain and inverse before the following contact can change it.
  func performSurfaceHistory(redo: Bool, documentID: UUID? = nil,
    after prepare: (@MainActor () async -> Bool)? = nil) {
    guard shutdownPhase == .running, inputGate.permitsNewContact, !inputGate.hasPencilContact,
      selectionSession.manipulation == nil else { return }
    #if os(iOS)
      if documentID == nil, let files = chat?.files, files.window.isOpen {
        let accepted: NotebookInputCompletion = {
          if redo { files.notes.redo() } else { files.notes.undo() }
        }
        if inputGate.hasActivePencil { inputGate.performAfterPageContact(accepted) } else { accepted() }
        return
      }
    #endif
    guard let domain = documentID.map(PencilUndoHistory.Domain.document) ?? activeHistoryDomain else { return }
    let accepted: NotebookInputCompletion = { [self] in
      surfaceHistory.accept(redo: redo, domain: domain, history: { [self] in pencilUndoHistory }, after: prepare,
        apply: { [self] redo, domain, history, request, previous in
          applySurfaceHistory(redo: redo, domain: domain, history: history,
            request: request, previous: previous)
        }, onOverflow: { [self] in showCue("Дождитесь сохранения предыдущих действий") })
    }
    if inputGate.hasActivePencil { inputGate.performAfterPageContact(accepted) }
    else { accepted() }
  }

  private func applySurfaceHistory(redo: Bool, domain: PencilUndoHistory.Domain,
    history: PencilUndoHistory, request: UUID, previous: Task<Bool, Never>?) -> Task<Bool, Never>? {
    if let command = redo ? history.lastRedoCommand(for: domain) : history.lastCommand(for: domain) {
      return acceptCollaborationHistory(command, redo: redo, actionID: request, after: previous)
    }
    if case .target(.document, _) = domain { return nil }
    guard let ids = redo ? history.lastRedoContribution(for: domain) : history.lastContribution(for: domain) else { return nil }
    let gate = redo ? history.lastRedoStateStamp(for: domain) : nil
    // The synchronous ink inverse must advance the same accepted order as the
    // queued authored inverses; otherwise a mixed Undo loses its Redo head.
    let priorHistory = pencilUndoHistory
    pencilUndoHistory = history
    let accepted: Bool
    if case .target(.page, let pageID) = domain {
      accepted = acceptDrawingHistory(pageID: pageID, ids: ids, redo: redo, gate: gate) != nil
    } else {
      accepted = setSpatialInkContribution(ids, domain: domain, active: redo, redoGate: gate)
      if accepted { showCue(redo ? "Повторено" : "Отменено") }
    }
    if !accepted { pencilUndoHistory = priorHistory }
    return nil
  }

  /// The history directory owns cold inverses; a geometry window is never
  /// mistaken for the surface's complete action history.
  private func setSpatialInkContribution(_ ids: Set<UUID>, domain: PencilUndoHistory.Domain,
    active: Bool, redoGate: VersionStamp? = nil) -> Bool {
    guard var journal = spatialInk,
      let source = ids.compactMap({ spatialInkHistoryStates[$0] }).filter({ state in
        state.result.isActive != active && state.result.creationStamp.actor == actorID
          && state.surfaces.contains { PencilUndoHistory.Domain(surface: $0) == domain }
          && (redoGate == nil || state.result.stateStamp == redoGate)
      }).max(by: { $0.result.creationStamp < $1.result.creationStamp }),
      let next = source.result.stateStamp.advanced(by: actorID),
      let journalStamp = max(journal.stamp, next).advanced(by: actorID) else { return false }
    let prior = source.result
    let command = NotebookSpatialInkCommand.state(actionID: prior.actionID, creationStamp: prior.creationStamp,
      expectedStateStamp: prior.stateStamp, isActive: active, stateStamp: next, journalStamp: journalStamp, nativeRedo: active)
    guard journal.applyState(command.expectedResult), scheduleSpatialInkSave(command) else { return false }
    spatialInk = journal
    spatialInkHistoryStates[prior.actionID] = .init(result: command.expectedResult, surfaces: source.surfaces)
    for surface in source.surfaces {
      guard let touched = PencilUndoHistory.Domain(surface: surface) else { continue }
      if active { pencilUndoHistory.recordAction(domain: touched, actionID: prior.actionID) }
      else { pencilUndoHistory.didRemoveContribution([prior.actionID], for: touched, stateStamp: next) }
    }
    return true
  }

  func afterPageInput(_ action: @escaping NotebookInputCompletion) {
    inputGate.performAfterPageInput(action)
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
  func commitSpatialElementState(boardID: UUID, rendered: SpatialElement, state: JSONValue,
    onCommitted: NotebookProgramStateCompletion) -> Bool {
    guard !isStopped, surfaceAcceptsChanges(rendered.surface),
      let sourceBasis = onCommitted.sourceBasis else { return false }
    if loadState == .loading, !isClosing, workspaceHeader != nil {
      return bootstrapAdmission.deferProgramWrite(accept: { [weak self] in
        guard let self,
          self.commitSpatialElementState(boardID: boardID, rendered: rendered, state: state, onCommitted: onCommitted)
        else { onCommitted(nil); return }
      }, reject: { onCommitted(nil) })
    }
    guard loadState == .ready else { return false }
    let cost:NotebookPersistenceAdmission.Cost
    do { cost=try NotebookElementWriteAllowance.programStateCost(boardID:boardID,rendered:rendered,state:state,basis:sourceBasis) }
    catch { showCue(error.localizedDescription);return false }
    guard let reservation=persistence.reserveWrite(cost) else {
      showCue("Сохранение заполнено. Повторите после восстановления записи.");return false
    }
    defer { persistence.releaseWriteReservation(reservation) }
    let actor = actorID
    do {
      try persistence.enqueueCommand(owner:.elementState(boardID,rendered.id),reservation:reservation,cost:cost,{ store in
        try store.commitSpatialElementState(boardID:boardID,rendered:rendered,state:state,actor:actor,
          expectedProgramBasis:sourceBasis,admittedStateBytes:onCommitted.admittedBytes)?.basis
      },completion:{ [weak self] result in
        // The outer accepted transaction owns this result. A storage failure
        // keeps the closure, browser checkpoint and credit pending for Retry.
        switch result {
        case .success(let basis): onCommitted(basis)
        case .failure: onCommitted(nil)
        }
        Task { @MainActor [weak self] in self?.reloadExternalChanges() }
      })
    } catch { showCue(error.localizedDescription);return false }
    // Admission changes the input frontier before its addressed write can
    // finish. A read queued before this contact must not overwrite the live
    // program with an earlier saved value while that write is still pending.
    readAdmission.changed(.init(kind: rendered.surface.kind == .cover ? .cover : .board,
      id: rendered.surface.ownerID ?? boardID))
    collaborationReadEpoch &+= 1
    collaborationContentEpoch &+= 1
    return true
  }

  func reserveDrawingAction(pageID: UUID) -> VersionStamp? {
    guard !isPageBeingDeleted(pageID),let page=pages[pageID],page.preparedInkDrawing != nil else {return nil}
    let latestCounter = max(
      page.drawingStamp.counter,
      reservedDrawingCounters[pageID] ?? 0
    )
    guard latestCounter < VersionStamp.maximumCounter else { return nil }
    guard let reservation = persistence.reserveWrite(NotebookInkWriteAllowance.maximumCost) else {
      showCue("Сохранение заполнено. Повторите после восстановления записи."); return nil
    }
    let stamp = VersionStamp(counter: latestCounter + 1, actor: actorID)
    reservedDrawingCounters[pageID] = stamp.counter
    drawingReservations[.init(pageID: pageID, stamp: stamp)] = .init(page: page, write: reservation)
    return stamp
  }

  func releaseDrawingReservation(pageID: UUID, stamp: VersionStamp) {
    if let reservation = drawingReservations.removeValue(forKey: .init(pageID: pageID, stamp: stamp)) {
      persistence.releaseWriteReservation(reservation.write)
    }
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
    quickShape:NotebookQuickShapeFit? = nil,nativeRedo:Bool = false) -> PreparedPageInkChange? {
    guard let reservation=drawingReservations.removeValue(forKey:.init(pageID:pageID,stamp:stamp)) else {
      if case .append(let action)=mutation { updateWorkingGraphic(nil,strokeID:action.id) }
      return nil
    }
    defer { persistence.releaseWriteReservation(reservation.write) }
    guard !isPageBeingDeleted(pageID) else { return nil }
    let page=pages[pageID] ?? reservation.page
    if case .append(let action)=mutation,let targets=action.elementTargets,!targets.isEmpty {
      workingElementErasures[action.id] = [.init(id: action.id, surface: .page(pageID),
        samples: action.samples, targets: targets, accepted: true)]
    }
    do {
      let change=try page.prepareLiveInkChange(mutation,stamp:stamp)
      guard change.stamp != change.baseStamp else {
        if case .append(let action)=mutation,workingElementErasures[action.id] != nil {
          workingElementErasures[action.id]=nil
        }
        return change
      }
      let cost: NotebookPersistenceAdmission.Cost
      switch change.mutation {
      case .append(let action): cost = try NotebookInkWriteAllowance.cost(action)
      case .setActive: cost = NotebookInkWriteAllowance.stateCost(entries: change.expectedVisibility.count)
      }
      let command=NotebookPageInkCommand(change,nativeRedo:nativeRedo), expectedStamp = change.stamp
      try persistence.enqueueReserved(owner:.pageInk(pageID),reservation:reservation.write,cost:cost,
        onRejected:{ [weak self] error in self?.showCue(error.localizedDescription) }) { store in
        try store.withNativeWriteAllowance(.init(executionBytes:cost.completionBytes)) {
          try store.commitPageInk(pageID:pageID,command:command).stamp != expectedStamp
        }
      }
      guard page.publishLiveInkChange(change) else { return nil }
      readAdmission.changed(.init(kind:.page,id:pageID))
      collaborationReadEpoch &+= 1;collaborationContentEpoch &+= 1
      elementErasureCache.record(change)
      switch change.mutation {
      case .append(let action):
        if workingElementErasures[action.id] != nil { workingElementErasures[action.id]=nil }
        pencilUndoHistory.recordAction(domain:.page(pageID),actionID:action.id)
      case .setActive(let ids, let active):
        if active { for id in ids { pencilUndoHistory.recordAction(domain:.page(pageID),actionID:id) } }
        else { pencilUndoHistory.didRemoveContribution(ids,for:.page(pageID),stateStamp:change.stamp) }
        // SwiftUI publishes the accepted source too; mounted canvases receive
        // this exact delta synchronously through pageInkPublication.
        if pages[pageID] != nil { pages[pageID]=page }
        showCue(active ? "Повторено" : "Отменено")
      }
      if case .append(let action)=change.mutation,let quickShape {
        // Conversion consumes this accepted ink, so its reservation follows
        // the ink in the same FIFO rather than depending on a later idle turn.
        acceptQuickShape(quickShape,pageID:pageID,stroke:action)
      }
      var suppressed = pageSuppressedInkIDs(page)
      if let quickShape, case .append(let action) = change.mutation {
        suppressed.formUnion(quickShape.precedingStrokeIDs + [action.id])
      }
      if NotebookNavigationObservation.enabled {
        let mutationName: String, actionIDs: [UUID], actionCount: Int, active: JSONValue
        switch change.mutation {
        case .append(let action):
          mutationName = "append"; actionIDs = [action.id]; actionCount = 1; active = .bool(action.isActive)
        case .setActive(let ids, let value):
          mutationName = "setActive"; actionIDs = Array(ids.prefix(64)); actionCount = ids.count; active = .bool(value)
        }
        NotebookNavigationObservation.recordInk("ink_accepted", fields: [
          "pageID": .string(pageID.uuidString), "baseStamp": NotebookNavigationObservation.inkStamp(change.baseStamp),
          "stamp": NotebookNavigationObservation.inkStamp(change.stamp), "mutation": .string(mutationName),
          "actionIDs": .array(actionIDs.map { .string($0.uuidString) }), "active": active,
          "actionCount": .number(Double(actionCount)), "actionIDsTruncated": .bool(actionCount > actionIDs.count),
          "nativeRedo": .bool(nativeRedo)])
      }
      pageInkPublication.publish(change, suppressedIDs: suppressed)
      return change
    } catch {
      if case .append(let action)=mutation {
        if workingElementErasures[action.id] != nil { workingElementErasures[action.id]=nil }
        updateWorkingGraphic(nil,strokeID:action.id)
      }
      showCue(error.localizedDescription)
      return nil
    }
  }

  /// Lasso borrows the same retained vector root advanced at Pencil-up.
  func lassoInkSnapshot(_ page:PageDocument)->NotebookLassoInkSource { .page(page) }

  /// Undo resolves its target and writes the inverse into the same journal in
  /// the button's actor segment; storage follows in the ordinary FIFO.
  func acceptDrawingUndo(pageID: UUID? = nil) -> PreparedPageInkChange? {
    guard inputGate.permitsNewContact, !inputGate.hasActivePencil,
      let page = pageID == nil ? activePage : pages[pageID!],
      let ids = pencilUndoHistory.lastContribution(for: .page(page.id)) else { return nil }
    return acceptDrawingHistory(pageID: page.id, ids: ids, redo: false, gate: nil)
  }

  func acceptDrawingRedo(pageID: UUID? = nil) -> PreparedPageInkChange? {
    guard inputGate.permitsNewContact, !inputGate.hasActivePencil,
      let page = pageID == nil ? activePage : pages[pageID!],
      let ids = pencilUndoHistory.lastRedoContribution(for: .page(page.id)),
      let gate = pencilUndoHistory.lastRedoStateStamp(for: .page(page.id)) else { return nil }
    return acceptDrawingHistory(pageID: page.id, ids: ids, redo: true, gate: gate)
  }

  private func acceptDrawingHistory(pageID: UUID, ids: Set<UUID>, redo: Bool,
    gate: VersionStamp?) -> PreparedPageInkChange? {
    guard let page = pages[pageID], let drawing = page.preparedInkDrawing,
      !redo || (gate != nil && ids.allSatisfy { drawing.action(id: $0)?.visibility.stateStamp == gate }),
      let stamp = reserveDrawingAction(pageID: pageID) else { return nil }
    return acceptInkMutation(.setActive(ids, redo), pageID: pageID, stamp: stamp, nativeRedo: redo)
  }

  // The toolbar projects the active tool’s stored color, never a second copy.
  var drawingColor: PenColor {
    switch drawingTool {
    case .marker: drawingToolSettings.markerColor
    case .shape: drawingToolSettings.shapeColor
    case .text: drawingToolSettings.textColor
    case .connector: drawingToolSettings.connectionColor
    case .laser: drawingToolSettings.laserColor
    case .pen, .eraser, .lasso: penStyle.color
    }
  }
  func selectDrawingColor(_ color: PenColor) {
    switch drawingTool {
    case .marker: drawingToolSettings.markerColor = color
    case .shape: drawingToolSettings.shapeColor = color
    case .text: drawingToolSettings.textColor = color
    case .connector: drawingToolSettings.connectionColor = color
    case .laser: drawingToolSettings.laserColor = color
    case .pen:
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

  @discardableResult
  func selectElements(_ references:[EditableElementReference],items:[NotebookSelectedItem] = [],
    ink:[NotebookSelectedInk] = []) -> Bool {
    let refs=Array(Set(references)).sorted { String(describing:$0)<String(describing:$1) }
    let items=Array(Set(items)).sorted { $0.itemID.uuidString<$1.itemID.uuidString }
    var raw:[NotebookSelectedInk]=[],seen:[NotebookSelectedInk.Key:String]=[:]
    for member in ink {
      if seen[member.key] != nil {
        guard selectionInkIsCurrent(member) else {showCue("Рукопись изменилась. Повторите выделение.");return false}
      } else { seen[member.key]=member.revision;raw.append(member) }
    }
    guard refs.count+items.count+raw.count<=32 else { showCue("Выберите не более 32 объектов за один раз.");return false }
    if let first=raw.first {
      guard raw.allSatisfy({ $0.address.target == first.address.target }),
        refs.allSatisfy({ nativeElementSource($0)?.target == first.address.target }),
        items.allSatisfy({ first.address.target.kind == .board && $0.boardID == first.address.target.id }) else {
        showCue("Рукопись и объекты можно выбрать вместе только на одной поверхности.");return false
      }
      guard selectionAddressIsCurrent(first.address),raw.allSatisfy(selectionInkIsCurrent) else {
        showCue("Рукопись изменилась. Повторите выделение.");return false
      }
      replaceSelection(.elements(refs,items:items,ink:raw.sorted { $0.painterOrder<$1.painterOrder }))
      InkRasterRenderer.shared.requestOrderedPreparation()
    } else if items.isEmpty {
      replaceSelection(refs.isEmpty ? nil : refs.count == 1 ? .element(refs[0]) : .elements(refs))
    } else if refs.isEmpty,items.count == 1 {
      replaceSelection(.item(boardID:items[0].boardID,itemID:items[0].itemID))
    } else { replaceSelection(.elements(refs,items:items)) }
    return true
  }

  func selectionAddressIsCurrent(_ address:NotebookToolAddress) -> Bool {
    guard let presence else { return false }
    switch address.surface.kind {
    case .page: return presence.mode == .page && presence.notebookPageID == address.surface.ownerID
    case .board: return presence.mode == .board && presence.boardID == address.surface.ownerID
    case .cover:
      return presence.boardID == address.boardID && (presence.mode == .board
        || (presence.mode == .cover && presence.focusedItemID == address.surface.ownerID))
    case .codeFragment: return false
    }
  }

  func selectRegion(_ region: NotebookRegionSelection) {
    replaceSelection(.region(region))
  }

  /// Only a still-current, unmaterialized contour may return the choice it
  /// borrowed. A later tap/selection must never be overwritten by worker failure.
  func restoreRejectedRegionSelection(_ previous:NotebookSelectionSession,replacing pendingID:UUID) {
    guard selectionSession.id == pendingID,let region=selectionSession.region,
      region.materialization == nil else { return }
    cancelElementManipulation()
    selectionSession=previous
    collaborationReadEpoch &+= 1
  }

  func resolveRegionPreparation(_ region:NotebookRegionSelection) {
    guard selectionSession.region?.id == region.id,region.materialization != nil else { return }
    selectionSession.target = .region(region)
    if var contact=selectionSession.manipulation,contact.reference == region.reference {
      contact.region=region;selectionSession.manipulation=contact
      updateRegionPreview(contact)
    } else if region.editingExisting,let material=region.materialization {
      selectElements(material.selected)
    }
  }

  func beginMultipleSelection() {
    guard let reference = selectionSession.element, graphicElement(reference) != nil else { return }
    selectionSession.addingElements = true
  }

  func setMultipleSelectionAdding(_ adding: Bool) { selectionSession.addingElements = adding }

  /// Additive picking is an explicit editing mode, never a second recognizer.
  /// All members remain on the same physical page/cover/board.
  func graphicSelectionToggling(_ reference: EditableElementReference) -> [EditableElementReference]? {
    guard selectionSession.addingElements, let graphic = graphicElement(reference), graphic.showsGeometry,
      let target = nativeElementSource(reference)?.target,
      selectionSession.elements.allSatisfy({ nativeElementSource($0)?.target == target }),
      selectionSession.ink.allSatisfy({ $0.address.target == target }),
      selectionSession.items.allSatisfy({ target.kind == .board && $0.boardID == target.id }) else { return nil }
    var refs = selectionSession.elements
    if let index = refs.firstIndex(of:reference) { refs.remove(at:index) }
    else if selectionSession.count < 32 { refs.append(reference) }
    else { showCue("Выберите не более 32 объектов за один раз."); return nil }
    return refs
  }

  func toggleGraphicSelection(_ reference: EditableElementReference) {
    guard let refs = graphicSelectionToggling(reference) else { return }
    guard selectElements(refs,items:selectionSession.items,ink:selectionSession.ink) else { return }
    selectionSession.addingElements = true
  }

  func removeInkFromMultipleSelection(_ key:NotebookSelectedInk.Key) {
    guard selectionSession.addingElements,selectionSession.ink.contains(where:{$0.key == key}) else {return}
    guard selectElements(selectionSession.elements,items:selectionSession.items,
      ink:selectionSession.ink.filter{$0.key != key}) else {return}
    selectionSession.addingElements=true
  }

  var canTransformSelection:Bool { selectionSession.manipulation?.selectionSource != nil || selectedGraphicMembers() != nil }
  var canDeleteSelection:Bool { selectionSession.items.isEmpty || (selectionSession.ink.isEmpty && !selectionContainsSourceAnchoredInk) }

  private func selectedGraphicMembers(deleting:Bool = false) -> [NotebookGraphicSelection.Member]? {
    let refs=selectionSession.elements,ink=selectionSession.ink
    guard selectionSession.items.isEmpty,!refs.isEmpty || !ink.isEmpty else { return nil }
    let target=ink.first?.address.target ?? refs.first.flatMap { nativeElementSource($0)?.target }
    guard let target,refs.allSatisfy({ nativeElementSource($0)?.target == target }),
      ink.allSatisfy({ $0.address.target == target && selectionInkIsCurrent($0) }) else { return nil }
    let graph=refs.first.flatMap(editingGraphicGraph)
    var members:[NotebookGraphicSelection.Member]=[]
    for reference in refs {
      // Non-graphic peers have their own deletion route. A graphic peer must
      // remain in the same native handoff as a selected raw contact.
      if deleting,graphicElement(reference) == nil {continue}
      guard let graphic=graphicElement(reference),graphic.showsGeometry,
        let geometry=elementGeometry(reference),let graph,
        let resolved=graphicManipulationGeometry(reference,in:graph),let source=nativeElementSource(reference) else { return nil }
      if case .spatial=reference,let cohort=compositionTiles.published,
        presentedElement(reference,cohort:cohort) == nil,acceptedWorkingGraphic(reference) == nil { return nil }
      members.append(.init(id:source.id,frame:.init(x:geometry.frame.minX,y:geometry.frame.minY,
        width:geometry.frame.width,height:geometry.frame.height),graphic:graphic,
        layout:resolved.display,body:resolved.body,placement:resolved.placement))
    }
    if deleting { return members }
    let rawGraph=NotebookGraphicGraph(ink.map { $0.working.node })
    for raw in ink {
      guard let node=rawGraph.node(raw.memberID),let body=rawGraph.resolve(raw.memberID,space:.body).layout,
        let layout=rawGraph.resolve(raw.memberID).layout else { return nil }
      members.append(.init(id:raw.memberID,frame:raw.material.frame,graphic:raw.material.graphic,
        layout:layout,body:body,placement:node.placement))
    }
    return members
  }

  private func selectionEditSource(deleting:Bool = false) -> NotebookSelectionEditSource? {
    let references=selectionSession.elements,ink=selectionSession.ink
    guard selectionSession.items.isEmpty,!references.isEmpty || !ink.isEmpty else { return nil }
    guard let members=selectedGraphicMembers(deleting:deleting) else { return nil }
    let address:NotebookToolAddress
    if let raw=ink.first { address=raw.address }
    else {
      guard let first=references.first,let target=nativeElementSource(first)?.target,
        let geometry=elementGeometry(first) else { return nil }
      address = .init(surface:target.kind == .page ? .page(target.id) : target.kind == .cover ? .cover(target.id) : .board(target.id),
        boardID:target.kind == .page ? nil : (target.boardID ?? target.id),worldOrigin:geometry.worldOrigin,bounds:geometry.bounds)
    }
    guard references.allSatisfy({ nativeElementSource($0)?.target == address.target }),
      ink.allSatisfy({ $0.address.target == address.target && selectionInkIsCurrent($0) }) else { return nil }
    var sources:[EditableElementReference:NotebookNativeElementSource]=[:]
    var dependencies:[EditableElementReference:NotebookElementCommand]=[:]
    let graph=references.first.flatMap(editingGraphicGraph)
    for reference in references {
      for id in [reference.elementID]+(graph?.placement(reference.elementID)?.ancestors ?? []) {
        let ref=address.reference(id)
        guard let source=acceptedElementSource(ref),source.target == address.target else { return nil }
        sources[ref]=source;dependencies[ref]=elementCommandSources[ref]
      }
    }
    guard sources.count+ink.count<=64 else { showCue("У выделения слишком много связанных исходников.");return nil }
    return .init(selectionID:selectionSession.id,address:address,references:references,ink:ink,
      sources:sources,dependencies:dependencies,members:members)
  }

  func selectionEditSourceIsCurrent(_ source:NotebookSelectionEditSource) -> Bool {
    selectionSession.id == source.selectionID && selectionSession.ink == source.ink
      && selectionSession.elements == source.references
      && source.ink.allSatisfy { selectionInkIsCurrent($0) }
      && selectionSourcesAreCurrent(source.sources,dependencies:source.dependencies)
  }

  @discardableResult
  private func applySelectionEdits(_ edits:[NotebookGraphicSelection.Edit],summary:String,
    source frozen:NotebookSelectionEditSource? = nil,deleting:Bool = false,
    presentation:NotebookSelectionPresentation? = nil) -> Bool {
    guard let source=frozen ?? selectionEditSource(deleting:deleting),selectionEditSourceIsCurrent(source),
      deleting || (edits.count == source.members.count && Set(edits.map(\.id)) == Set(source.members.map(\.id))) else { return false }
    guard let reservation = reserveElementPreparation() else { return false }
    var transferred = false
    defer { if !transferred { releaseElementPreparation(reservation) } }
    // Authored-only patches contain bounded poses/styles, never a measured
    // body. Preserve their synchronous draft admission through the same helper.
    if !source.needsOrderedPresentation {
      do {
        let prepared=try source.prepare(edits,deleting:deleting)
        guard !prepared.edits.isEmpty else { return true }
        guard let plan=prepareElementOperations(prepared.edits,summary:summary,
          readSources:Array(prepared.sources.keys),frozenSources:prepared.sources,
          frozenDependencies:source.dependencies) else { return false }
        if let presentation {
          let bounds=selectionSession.manipulation?.frame
            ?? NotebookGraphicSelection.bounds(source.members,relativeTo:source.members.first?.origin ?? .zero)
          presentation.update([],edits:edits,frame:bounds)
          presentation.claim()
        }
        guard enqueueElementCommand(target:source.address.target,ready:plan,presentation:presentation,
          reservation:reservation) != nil else { presentation?.commandFailed(); return false }
        transferred = true
        if deleting { clearSelection() };return true
      } catch { showCue(error.localizedDescription);return false }
    }
    let working:[NotebookWorkingGraphic]
    do { working=try source.presentationWorking(for:edits,deleting:deleting) }
    catch { showCue(error.localizedDescription);return false }
    guard let presentation=presentation ?? NotebookSelectionPresentation(id:UUID(),source:source,model:self) else {
      showCue("Дождитесь появления выбранного материала.");return false
    }
    if deleting {presentation.stageDeletion()}
    let presentedBounds=selectionSession.manipulation?.frame
      ?? NotebookGraphicSelection.bounds(source.members,relativeTo:source.members.first?.origin ?? .zero)
    presentation.update(working,edits:edits,frame:presentedBounds);presentation.claim()
    let preparation=Task.detached(priority:.userInitiated) { try source.prepare(edits,deleting:deleting) }
    let pending=Task { [weak self] () throws -> NotebookElementCommandPlan in
      let prepared=try await preparation.value
      guard let self,let plan=prepareElementOperations(prepared.edits,summary:summary,
        readSources:Array(prepared.sources.keys),insertionTarget:source.address.target,
        expectedInkRevision:nil,inkReadSets:source.ink.compactMap(\.readSet),previews:false,frozenSources:prepared.sources,
        frozenDependencies:source.dependencies) else {
        throw CollaborationError("revision_conflict","Не удалось подготовить всё выделение.")
      }
      return plan
    }
    let refs=source.references+source.ink.map { source.address.reference($0.memberID) }
    // Typed previews and references are admitted with the existing command
    // generation. Async body encoding cannot expose a snap-back after lift,
    // or leave an unowned draft if preparation fails before its plan exists.
    guard let batch=enqueueElementCommand(target:source.address.target,preparing:pending,reserving:refs,
      presentation:presentation,reservation:reservation) else {
      presentation.commandFailed()
      Task { [self] in
        _ = await pending.result; _ = await preparation.result
        releaseElementPreparation(reservation)
      }
      transferred = true
      return false
    }
    transferred = true
    if !deleting {publishSelectionDrafts(source:source,edits:edits,deleting:false)}
    updateWorkingGraphics(presentation.working)
    acceptWorkingGraphics(presentation.working)
    selectElements(deleting ? [] : refs)
    let admission=Task { [weak self] in
      _ = try? await batch.prepared()
      if self?.pendingMaterialAdmissions[source.address.surface]?.id == batch.id {
        self?.pendingMaterialAdmissions[source.address.surface]=nil
      }
    }
    pendingMaterialAdmissions[source.address.surface]=(batch.id,admission)
    return true
  }

  func publishSelectionDrafts(source:NotebookSelectionEditSource,
    edits:[NotebookGraphicSelection.Edit],deleting:Bool) {
    let byID=Dictionary(uniqueKeysWithValues:edits.map { ($0.id,$0) })
    for reference in source.references {
      guard var pose=source.sources[reference]?.placementSource else { continue }
      let original=source.sources[reference]?.page?.graphic ?? source.sources[reference]?.spatial?.graphic
      let edit=byID[reference.elementID]
      if let edit {pose.frame=edit.frame;pose.basis=edit.basis}
      var graphic=edit?.graphic ?? original
      if deleting {graphic?.visible=false}
      elementCommandDrafts[reference] = .init(source:pose,graphic:graphic,removed:deleting)
    }
  }

  func alignGraphicSelection(_ alignment: NotebookGraphicSelection.Alignment) {
    guard let members = selectedGraphicMembers() else { return }
    let aligned=Dictionary(uniqueKeysWithValues:NotebookGraphicSelection.aligned(members,to:alignment).map { ($0.id,$0) })
    let edits=NotebookGraphicSelection.translated(members,by:.zero).map { aligned[$0.id] ?? $0 }
    _ = applySelectionEdits(edits,summary:"Выровнять фигуры")
  }

  func transformGraphicSelection(radians: Double = 0, scale: Double = 1) {
    if let region=selectionSession.region { transformRegion(region,radians:radians,scale:scale);return }
    if transformSelectedGroup(radians:radians,scale:scale) { return }
    guard let members=selectedGraphicMembers() else { return }
    let edits=NotebookGraphicSelection.transformed(members,radians:radians,scale:scale)
    let bounds=selectionSession.ink.first?.address.bounds ?? selectionSession.elements.first.flatMap { elementGeometry($0)?.bounds }
    if let bounds,
      edits.contains(where: { !bounds.contains(CGRect(x:$0.frame.x,y:$0.frame.y,width:$0.frame.width,height:$0.frame.height)) }) {
      showCue("Для этого поворота или масштаба не хватает места на листе."); return
    }
    _ = applySelectionEdits(edits,summary:radians == 0 ? "Масштабировать выделение" : "Повернуть выделение")
  }

  func duplicateGraphicMaterial() {
    if !selectionSession.ink.isEmpty || selectionContainsSourceAnchoredInk { duplicateMeasuredSelection();return }
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
    if !selectionSession.ink.isEmpty || selectionContainsSourceAnchoredInk {
      guard canDeleteSelection,let source=selectionEditSource(deleting:true) else {
        showCue("Эти объекты нельзя удалить вместе. Выберите рукопись отдельно от карточек.");return
      }
      _ = applySelectionEdits([],summary:"Удалить выделенное",source:source,deleting:true);return
    }
    if let region=selectionSession.region {
      deleteRegion(region);return
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
    deleteSelectedContent()
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
    case .elements(let refs,let items,let ink):
      let target=ink.first?.address.target ?? refs.first.flatMap { nativeElementSource($0)?.target }
        ?? items.first.map { CollaborationTarget(kind:.board,id:$0.boardID) }
      guard let target,refs.allSatisfy({ nativeElementSource($0)?.target == target }),
        ink.allSatisfy({ $0.address.target == target }),
        items.allSatisfy({ target.kind == .board && $0.boardID == target.id }) else { return nil }
      value.target=target;value.elementIDs=refs.map(\.elementID)
      value.itemIDs=items.isEmpty ? nil : items.map(\.itemID)
      value.inkActionIDs=ink.isEmpty ? nil : ink.map(\.actionID)
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
    enqueueStoreWrite(owner: .peerSession(envelope.deviceID)) { try $0.saveLocalSelectionPublication(envelope) }
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
    if selectionSession.elements.count>1 || !selectionSession.ink.isEmpty
      || (graphicElement(reference)?.sourceInkContactID != nil
        && editingGraphicGraph(reference)?.placement(reference.elementID)?.parentID == nil) {
      guard selectionSession.contains(reference) else { return nil }
      return beginSelectionManipulation(kind:kind)
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
        let f=graphicElement(reference)?.mask.flatMap { geometry.display.selectionFrame(mask:$0) } ?? geometry.display.frame
        return .init(x:f.x,y:f.y,width:f.width,height:f.height)
      } ?? groupGeometry?.bounds ?? native?.bounds,text:text)
    if let captured,let source=captured.source(reference.elementID) {
      let closed:Bool?
      if case .spatial(let owner,let id)=reference { closed=spatialGroupReads[owner]?[id]?.isSelfContained } else { closed=nil }
      contact.graphicCapture = .init(graph:captured,source:source,id:reference.elementID,closedGroup:closed)
    }
    contact.commandSource=elementCommandSources[reference]
    if !selectionSession.isInteractive { selectionSession.nativeText = nil }
    selectionSession.manipulation = contact
    inputGate.beginContact(source: contact.id)
    inputGate.registerFingerCancellation(source: contact.id) { [weak self] in self?.cancelElementManipulation(contact.id) }
    return contact.id
  }

  func beginSelectionManipulation(kind:NotebookElementManipulation.Kind) -> UUID? {
    switch kind { case .move,.resize:break;default:return nil }
    guard !selectionSession.isInteractive,let source=selectionEditSource(),let origin=source.members.first?.origin,
      inputGate.beginFingerSequence() != nil else { return nil }
    let box=NotebookGraphicSelection.bounds(source.members,relativeTo:origin)
    guard !box.isNull,box.width>0,box.height>0 else { return nil }
    cancelElementManipulation()
    var contact=NotebookElementManipulation(reference:nil,kind:kind,frame:box,
      bounds:source.address.bounds,worldOrigin:origin)
    contact.selectionSource=source;contact.selectedMembers=source.members
    #if os(iOS)
    let needsPresentation=true
    #else
    let needsPresentation=source.needsOrderedPresentation
    #endif
    if needsPresentation {
      guard let presentation=NotebookSelectionPresentation(id:contact.id,source:source,model:self) else {
        showCue("Дождитесь появления выбранного материала.");return nil
      }
      contact.inkPresentation=presentation
    }
    if let reference=source.references.first,let graph=editingGraphicGraph(reference),let value=graph.source(reference.elementID) {
      contact.graphicCapture = .init(graph:graph,source:value,id:reference.elementID)
    }
    selectionSession.manipulation=contact
    inputGate.beginContact(source:contact.id)
    inputGate.registerFingerCancellation(source:contact.id) { [weak self] in self?.cancelElementManipulation(contact.id) }
    updateWholeSelectionPreview(contact)
    return contact.id
  }

  private func updateWholeSelectionPreview(_ contact:NotebookElementManipulation) {
    guard let source=contact.selectionSource,
      let working=try? source.presentationWorking(for:contact.selectedEdits,deleting:false) else { return }
    contact.inkPresentation?.update(working,edits:contact.selectedEdits,frame:contact.frame)
    if !working.isEmpty { updateWorkingGraphics(contact.inkPresentation?.working ?? working) }
  }

  func beginRegionManipulation(_ region:NotebookRegionSelection,kind:NotebookElementManipulation.Kind) -> UUID? {
    switch kind { case .move,.resize: break; default: return nil }
    if region.materialization != nil {
      guard regionIsCurrent(region) else { showCue("Материал области изменился. Повторите лассо.");return nil }
    } else if region.preparation == nil { return nil }
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
    if let contact=selectionSession.manipulation {
      if contact.region != nil { updateRegionPreview(contact) }
      else if contact.selectionSource != nil { updateWholeSelectionPreview(contact) }
    }
  }

  func updateRegionPoses(_ id:UUID,poses:[String:NotebookElementPlacement.Source]) {
    guard selectionSession.manipulation?.id == id else { return }
    selectionSession.manipulation?.regionPoses=poses
  }

  @discardableResult
  func finishElementManipulation(_ id: UUID, translation: SpatialPoint) -> Bool {
    guard selectionSession.manipulation?.id == id else { return false }
    updateElementManipulation(id, translation: translation)
    guard let contact = selectionSession.manipulation else { return false }
    if contact.region != nil { return finishRegionManipulation(contact) }
    if !contact.selectedMembers.isEmpty {
      guard let source=contact.selectionSource,selectionEditSourceIsCurrent(source),
        contact.frame != contact.original,contact.selectedEdits.count == contact.selectedMembers.count else {
        cancelElementManipulation(id);return false
      }
      let result=applySelectionEdits(contact.selectedEdits,summary:contact.kind == .move ? "Переместить выбранные фигуры" : "Изменить размер выбранных фигур",source:source,presentation:contact.inkPresentation)
      cancelElementManipulation(id);return result
    }
    cancelElementManipulation(id)
    guard let reference=contact.reference else { return false }
    guard contact.frame != contact.original || contact.basis != contact.originalBasis || contact.connection != contact.originalConnection
      || contact.vertices != contact.originalVertices || contact.cornerRadius != contact.originalCornerRadius,
      let current = elementGeometry(reference), current.frame == contact.original,
      (current.identity == contact.identity || contactOwnSourceWasPublished(contact)),
      graphicElement(reference)?.connection == contact.originalConnection else { return false }
    if let placement=contact.placement {
      if case .spatial(let boardID,let elementID)=reference,let captured=contact.graphicCapture,captured.source.isGroup {
        let source=elementCommandDrafts[reference]?.source ?? nativeElementSource(reference)?.placementSource
        let desired=projectingGraphicCommands(boardHierarchy?.board(boardID)?.graphicGraph() ?? NotebookGraphicGraph([]),holdingSelectedInk:false) { .spatial(boardID:boardID,elementID:$0) }.placement(elementID)
        guard source == captured.source,desired?.parentTransform == placement.parentTransform,desired?.origin == placement.origin else { return false }
      } else {
        guard (graphicManipulationGeometry(reference)?.placement ?? groupManipulationGeometry(reference)?.placement ?? elementPresentation(reference)?.placement) == placement else { return false }
      }
    } else if current.worldOrigin != contact.worldOrigin { return false }
    if contact.vertices != contact.originalVertices || contact.cornerRadius != contact.originalCornerRadius {
      guard graphicElement(reference).flatMap(NotebookGraphicGeometry.polygon) == contact.originalVertices,
        (graphicElement(reference)?.cornerRadius ?? 0) == contact.originalCornerRadius else { return false }
      var patch: [String:JSONValue] = [:]
      if contact.vertices != contact.originalVertices { patch["vertices"] = try? .encode(contact.vertices) }
      if contact.cornerRadius != contact.originalCornerRadius { patch["cornerRadius"] = .number(contact.cornerRadius) }
      var values: [String:JSONValue] = ["graphic":.object(patch)]
      if contact.frame != contact.original {
        values["frame"] = try? .encode(PageRect(x:contact.frame.minX,y:contact.frame.minY,width:contact.frame.width,height:contact.frame.height))
      }
      return performElementOperation(.updateElement,reference:reference,values:values,summary:"Изменить геометрию фигуры",readSources:contact.ancestorReferences,capture:contact.graphicCapture?.retaining(bounds:contact.presentedFrame),dependency:contact.commandSource)
    }
    if let connection = contact.connection, connection != contact.originalConnection {
      guard let original = contact.originalConnection else { return false }
      var patch: [String: JSONValue] = [:]
      if connection.start != original.start { patch["start"] = try? .encode(connection.start) }
      if connection.end != original.end { patch["end"] = try? .encode(connection.end) }
      if connection.bend != original.bend { patch["bend"] = .number(connection.bend) }
      if connection.elbowAxis != original.elbowAxis { patch["elbowAxis"] = try? .encode(connection.elbowAxis) }
      if connection.routing != original.routing { patch["routing"] = try? .encode(connection.routing) }
      if connection.bendPosition != original.bendPosition { patch["bendPosition"] = try? .encode(connection.bendPosition) }
      var values: [String:JSONValue] = ["graphic": .object(["connection": .object(patch)])]
      if contact.frame != contact.original {
        values["frame"] = try? .encode(PageRect(x:contact.frame.minX,y:contact.frame.minY,width:contact.frame.width,height:contact.frame.height))
      }
      return performElementOperation(.updateElement, reference: reference,
        values:values,summary:"Изменить связь",readSources:contact.ancestorReferences,capture:contact.graphicCapture?.retaining(bounds:contact.presentedFrame),dependency:contact.commandSource)
    }
    return commitElementFrame(contact)
  }

  @discardableResult
  private func finishRegionManipulation(_ contact:NotebookElementManipulation)->Bool {
    cancelElementManipulation(contact.id)
    guard let region=contact.region,contact.frame != contact.original else { return false }
    return placeRegion(region,in:contact.frame,
      summary:contact.kind == .move ? "Переместить область лассо" : "Изменить размер области лассо")
  }

  /// Preview and commit use the same completed rectangle. Storage changes the
  /// addressed material; it does not run a second resize calculation.
  private func commitElementFrame(_ contact: NotebookElementManipulation) -> Bool {
    guard let reference=contact.reference,contact.identity != nil || contact.commandSource != nil else { return false }
    let frame=contact.frame
    return performElementOperation(.updateElement,reference:reference,
      values:["frame":(try? .encode(PageRect(x:frame.minX,y:frame.minY,width:frame.width,height:frame.height))) ?? .null]
        .merging(contact.basis == contact.originalBasis ? [:] : ["basis":(try? .encode(contact.basis)) ?? .null]) { _,new in new },
      summary:"Изменить положение объекта",readSources:contact.ancestorReferences,capture:contact.graphicCapture?.retaining(bounds:contact.presentedFrame),dependency:contact.commandSource)
  }

  private func contactOwnSourceWasPublished(_ contact:NotebookElementManipulation)->Bool {
    guard let reference=contact.reference,let previous=contact.commandSource,let captured=contact.graphicCapture,
      let current=acceptedElementSource(reference),
      elementCommandSources[reference].map({ $0.id == previous.id }) ?? true else { return false }
    return current.placementSource == captured.source
      && (current.page?.graphic ?? current.spatial?.graphic) == captured.graph.node(reference.elementID)?.graphic
    // The captured predecessor's exact receipt is still checked by the writer.
  }

  func cancelElementManipulation(_ id: UUID? = nil) {
    guard let contact = selectionSession.manipulation, id == nil || contact.id == id else { return }
    // Transfer the installed pose to its retiring owner before observers can
    // see a selection without the contact that previously held that pose.
    contact.inkPresentation?.cancel()
    selectionSession.manipulation = nil
    let ids=Set(contact.region?.materialization?.working.map(\.id) ?? [])
      .union(contact.selectionSource?.ink.map(\.memberID) ?? [])
    removeWorkingGraphics { !$0.accepted && ids.contains($0.id) && $0.inkPresentation == nil }
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
    guard let graphic=graphicElement(reference),graphic.freehand == nil,
      selectionSession.ink.isEmpty || !selectionSession.elements.contains(reference) else { return }
    let original=graphic.style
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
  func insertClipboardFragment(_ fragment: NotebookPasteFragment, at destination: NotebookPasteDestination,
    workLease suppliedWork:NotebookClipboardWorkLease? = nil) async -> Bool {
    let work:NotebookClipboardWorkLease
    do { work=try suppliedWork ?? beginClipboardWork() }
    catch { showCue(error.localizedDescription);return false }
    defer { withExtendedLifetime(work) {} }
    guard fragment.canInsert, await finishPendingInteraction(boundary:.acceptedInput), !isClosing else { return false }
    let actor = actorID,generation = UUID(),actionID = UUID()
    let operation=Task.detached(priority:.userInitiated) { () throws -> NotebookPersistenceQueue.PreparedCommand<CollaborationReceipt> in
      defer { withExtendedLifetime(work) {} }
      try Task.checkCancellation()
      let resources=try fragment.prepareProgramResources()
      let operations=try fragment.operations(target:destination.target,offset:destination.offset(for:fragment),worldOrigin:destination.worldOrigin)
      let cost=try NotebookElementWriteAllowance.clipboardCost(fragment:fragment,operations:operations,programResources:resources)
      return .init(cost:cost,operation:{ store in
        let revision=try store.targetContentRevision(target:destination.target)
        return try store.applyNativeAction(.init(id:actionID,summary:"Вставить из буфера",
          expected:[.init(target:destination.target,revision:revision)],operations:operations),actor:actor,programResources:resources)
      })
    }
    let saved:Task<CollaborationReceipt,Error>
    do { saved=try persistence.enqueuePreparedCommand(reservation:work.reservation,operation,publishesChanges:true) }
    catch {
      operation.cancel()
      _ = await operation.result
      work.finish();releaseClipboardWork(work.reservation)
      showCue(error.localizedDescription);return false
    }
    pencilUndoHistory.recordCommand(domain:.init(destination.target),actionID:actionID)
    readAdmission.changed(destination.target)
    collaborationReadEpoch &+= 1
    let task = Task<NotebookElementCommandResult?, Never> { [weak self] in
      guard let self else { return nil }
      defer {
        pendingCollaborationCommands[actionID] = nil
        if graphicCommandGeneration == generation { graphicCommandTask = nil }
      }
      do {
        _ = try await saved.value
        reloadExternalChanges()
        showCue("Вставлено: \(fragment.elements.count)")
        return .init(page:nil,spatial:nil)
      } catch {
        pencilUndoHistory.discardCommand(domain:.init(destination.target),actionID:actionID)
        showCue(error.localizedDescription); return nil
      }
    }
    pendingCollaborationCommands[actionID] = Task { await task.value != nil }
    graphicCommandGeneration = generation
    graphicCommandTask = task
    return await task.value != nil
  }

  @discardableResult
  func performElementOperation(_ kind: CollaborationOperation.Kind, reference: EditableElementReference,
    values: [String: JSONValue], summary: String, layerMove: NotebookElementLayerMove? = nil,
    readSources: [EditableElementReference] = [],capture:NotebookGraphicContactSource? = nil,dependency:NotebookElementCommand? = nil) -> Bool {
    performElementOperations([.init(reference:reference,kind:kind,values:values)],summary:summary,layerMove:layerMove,readSources:readSources,capture:capture,
      frozenDependencies:dependency.map { [reference:$0] } ?? [:])
  }

  @discardableResult
  func performElementOperations(_ edits: [NotebookElementEdit], summary: String,
    layerMove: NotebookElementLayerMove? = nil, readSources: [EditableElementReference] = [], copiedFrom: [String:String] = [:],
    insertionTarget explicitTarget: CollaborationTarget? = nil, expectedInkRevision: String? = nil, inkReadSets:[NotebookInkReadSet] = [], retainedSources: [EditableElementReference:NotebookNativeElementSource] = [:], previews: Bool = true,capture:NotebookGraphicContactSource? = nil,
    frozenSources:[EditableElementReference:NotebookNativeElementSource] = [:],
    frozenDependencies:[EditableElementReference:NotebookElementCommand] = [:]) -> Bool {
    guard let plan=prepareElementOperations(edits,summary:summary,layerMove:layerMove,readSources:readSources,
      copiedFrom:copiedFrom,insertionTarget:explicitTarget,expectedInkRevision:expectedInkRevision,inkReadSets:inkReadSets,
      retainedSources:retainedSources,previews:previews,capture:capture,frozenSources:frozenSources,
      frozenDependencies:frozenDependencies) else { return false }
    return enqueueElementCommand(target:plan.target,ready:plan) != nil
  }

  func prepareElementOperations(_ edits: [NotebookElementEdit], summary: String,
    layerMove: NotebookElementLayerMove? = nil, readSources: [EditableElementReference] = [], copiedFrom: [String:String] = [:],
    insertionTarget explicitTarget: CollaborationTarget? = nil, expectedInkRevision: String? = nil, inkReadSets:[NotebookInkReadSet] = [], retainedSources: [EditableElementReference:NotebookNativeElementSource] = [:], previews: Bool = true,capture:NotebookGraphicContactSource? = nil,
    frozenSources:[EditableElementReference:NotebookNativeElementSource] = [:],
    frozenDependencies:[EditableElementReference:NotebookElementCommand] = [:]) -> NotebookElementCommandPlan? {
    guard !edits.isEmpty, edits.count <= 32 else { return nil }
    let references = Array(Set(edits.map(\.reference) + readSources))
    guard references.count <= 64 else { return nil }
    let insertionTarget = explicitTarget ?? readSources.first.flatMap { nativeElementSource($0)?.target }
    var originals: [EditableElementReference: NotebookNativeElementSource] = [:]
    for reference in references {
      let live = frozenSources[reference] ?? nativeElementSource(reference)
      guard let source = live?.page != nil || live?.spatial != nil ? live : retainedSources[reference] ?? live else { return nil }
      originals[reference] = source.page == nil && source.spatial == nil && insertionTarget != nil
        ? .init(target:insertionTarget!,id:source.id,versions:source.versions) : source
    }
    guard let target = originals[edits[0].reference]?.target,
      originals.values.allSatisfy({ $0.target == target }) else { return nil }
    let operations = edits.map { edit in
      CollaborationOperation(kind:edit.kind,target:target,id:originals[edit.reference]!.id,values:edit.values)
    }
    let sources = originals
    let sourceTasks = references.reduce(into: [EditableElementReference: Task<NotebookElementCommandResult?, Never>]()) {
      if let dependency=frozenDependencies[$1] { $0[$1]=dependency.task }
      else if frozenSources[$1] == nil { $0[$1] = elementCommandSources[$1]?.task }
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
        let basis:NotebookElementBasis?
        if let value=edit.values["basis"] { basis=value == .null ? nil : try value.decode(NotebookElementBasis.self) }
        else { basis=elementCommandDrafts[edit.reference]?.basis ?? originals[edit.reference]?.page?.basis ?? originals[edit.reference]?.spatial?.basis }
        var source=elementCommandDrafts[edit.reference]?.source ?? originals[edit.reference]?.placementSource
          ?? .init(frame:frame,origin:geometry.worldOrigin ?? .zero)
        source.frame=frame;source.basis=basis
        drafts[edit.reference] = .init(source:source,graphic:graphic,capture:capture,
          removed:edit.kind == .removeElement && graphic == nil,textSource:try edit.values["source"]?.decode(String.self) ?? elementCommandDrafts[edit.reference]?.textSource,
          textHTML:try edit.values["html"]?.decode(String.self) ?? elementCommandDrafts[edit.reference]?.textHTML,
          textStyle:try edit.values["textStyle"]?.decode(NativeTextStyle.self) ?? elementCommandDrafts[edit.reference]?.textStyle)
      }
    } catch { showCue(error.localizedDescription); return nil }
    return .init(target:target,references:references,sources:sources,sourceTasks:sourceTasks,
      operations:operations,summary:summary,layerMove:layerMove,copiedFrom:copiedFrom,expectedInkRevision:expectedInkRevision,
      inkReadSets:inkReadSets,drafts:drafts)
  }

  func didChangeElementCommandProjection() {
    collaborationReadEpoch &+= 1;collaborationContentEpoch &+= 1
  }

  /// Lift accepts one action immediately, including when its immutable source
  /// is still being prepared. Later focus changes cannot cancel this writer.
  @discardableResult
  func enqueueElementCommand(target:CollaborationTarget,ready:NotebookElementCommandPlan? = nil,
    preparing:Task<NotebookElementCommandPlan,Error>? = nil,
    reserving reservedReferences:[EditableElementReference] = [],
    presentation:NotebookSelectionPresentation? = nil,
    batch:NotebookElementCommandBatch = .init(),
    reservation suppliedReservation:NotebookPersistenceAdmission.Reservation? = nil) -> NotebookElementCommandBatch? {
    guard let reservation = suppliedReservation ?? persistence.reserveWrite(NotebookElementWriteAllowance.maximumCost) else {
      showCue("Сохранение заполнено. Повторите после восстановления записи."); return nil
    }
    if let ready {
      do { _ = try NotebookElementWriteAllowance.cost(ready) }
      catch { persistence.releaseWriteReservation(reservation); showCue(error.localizedDescription); return nil }
    }
    let actor=actorID
    let commandID=batch.id,generation=batch.generation
    let operation=Task { [weak self] () throws -> NotebookPersistenceQueue.PreparedCommand<NotebookElementCommandWriteResult> in
      guard let self else { throw CancellationError() }
      let plan:NotebookElementCommandPlan
      if let ready { plan=ready }
      else if let preparing {
        plan=try await withTaskCancellationHandler { try await preparing.value } onCancel:{ preparing.cancel() }
      } else { throw CollaborationError("invalid_action","Не подготовлено изменение материала.") }
      try Task.checkCancellation()
      guard plan.target == target else { throw CollaborationError("invalid_action","Изменился адрес материала.") }
      _ = try NotebookElementWriteAllowance.cost(plan)
      if ready == nil {
        registerElementCommand(plan,batch:batch,reserved:batch.reservedReferences)
        publishElementCommandDrafts(plan,batch:batch)
        batch.resolve(.success(plan))
      }
      var expected:[NotebookNativeElementSource]=[]
      for reference in plan.references {
        let source=plan.sources[reference]!
        if let task=plan.sourceTasks[reference] {
          guard let accepted=await task.value else {
            throw CollaborationError("revision_conflict","Предыдущее изменение выбранного элемента не было сохранено.")
          }
          expected.append(accepted.source(target:target,id:source.id))
        } else { expected.append(source) }
      }
      let command=NotebookNativeCommand(plan.operations,summary:plan.summary,sources:expected,
        layerMove:plan.layerMove,copiedFrom:plan.copiedFrom,expectedInkRevision:plan.expectedInkRevision,inkReadSets:plan.inkReadSets,
        transferWitness:plan.transferWitness,
        actionID:commandID,actor:actor)
      let cost = try NotebookElementWriteAllowance.cost(plan, resolvedSources: expected)
      return .init(cost: cost, operation: { store in
        let result=try command.apply(to:store)
        return .init(cursor:try store.currentChangeCursor(),sources:result.sources,
          header:target.kind == .page ? nil : try store.readBoardNodeHeader(target.boardID ?? target.id)?.board)
      })
    }
    // This reservation is synchronous with acceptance, not an enqueue after
    // awaiting preparation. Ink, undo and later commands share this same FIFO.
    let saved:Task<NotebookElementCommandWriteResult,Error>
    do { saved = try persistence.enqueuePreparedCommand(reservation:reservation,operation,publishesChanges:true) }
    catch {
      operation.cancel()
      // The worker may already hold a body. Join its actual completion before
      // returning its unused credit, even when this UI has disappeared.
      Task { [persistence] in _ = await operation.result; persistence.releaseWriteReservation(reservation) }
      showCue(error.localizedDescription); return nil
    }
    readAdmission.changed(target)
    batch.result=Task { [weak self] in
      guard let self else { return nil }
      defer {
        pendingCollaborationCommands[commandID]=nil
        if graphicCommandGeneration == generation { graphicCommandTask=nil }
      }
      do {
        let receipt=try await saved.value,plan=try await batch.prepared()
        var results:[EditableElementReference:NotebookElementCommandResult]=[:]
        for reference in plan.references {
          let id=plan.sources[reference]!.id,source=receipt.sources.first { $0.id == plan.sources[reference]!.id }
          let output=NotebookElementCommandResult(page:source?.page,spatial:source?.spatial,
            versions:source?.versions,target:source?.target ?? target,boardHeader:receipt.header)
          results[reference] = output
          if elementCommandSources[reference]?.id == generation {
            elementCommandSources[reference]?.cursor=receipt.cursor
            elementCommandSources[reference]?.accepted=output
            if plan.operations.contains(where:{ $0.id == id }),
              let index=workingGraphics.firstIndex(where:{ workingGraphicReference($0) == reference }) {
              let surface=workingGraphics[index].surface
              workingGraphics[index].publicationCursor=receipt.cursor
              workingGraphics[index].durableSource=output.source(target:target,id:id)
              workingGraphics[index].publication=nil
              didChangeWorkingGraphics(on:[surface])
            }
          }
        }
        presentation?.didAcceptSource(cursor:receipt.cursor,sources:Dictionary(uniqueKeysWithValues:results.map { reference,result in
          (reference,result.source(target:target,id:reference.elementID))
        }))
        reloadExternalChanges();return results
      } catch {
        operation.cancel();preparing?.cancel();batch.resolve(.failure(error))
        presentation?.commandFailed()
        pencilUndoHistory.discardCommand(domain:.init(target),actionID:commandID)
        for reference in batch.reservedReferences {
          guard elementCommandSources[reference]?.id == generation else { continue }
          elementCommandDrafts[reference]=nil;elementCommandSources[reference]=nil
          let failedPresentation=presentation ?? workingGraphics.first { $0.id == reference.elementID }?.inkPresentation
          failedPresentation?.commandFailed()
          cancelElementManipulationForFailedCommand(reference)
          removeWorkingGraphics { $0.id == reference.elementID && $0.inkPresentation?.retiring != true
            && (presentation == nil || $0.inkPresentation === presentation) }
        }
        showCue(error.localizedDescription);reloadExternalChanges();return nil
      }
    }
    for reference in reservedReferences { registerElementCommand(reference,batch:batch) }
    if let ready {
      registerElementCommand(ready,batch:batch)
      publishElementCommandDrafts(ready,batch:batch)
      batch.resolve(.success(ready))
    }
    pencilUndoHistory.recordCommand(domain:.init(target),actionID:commandID)
    collaborationReadEpoch &+= 1
    pendingCollaborationCommands[commandID]=Task { await batch.result.value != nil }
    graphicCommandGeneration=generation
    graphicCommandTask=Task { await batch.result.value?.values.first }
    return batch
  }

  private func publishElementCommandDrafts(_ plan:NotebookElementCommandPlan,batch:NotebookElementCommandBatch) {
    let working=plan.working.filter { value in
      guard let reference=workingGraphicReference(value) else { return false }
      return elementCommandSources[reference]?.id == batch.generation
    }
    if !working.isEmpty { acceptWorkingGraphics(working) }
    var changed=false
    for (reference,draft) in plan.drafts where elementCommandSources[reference]?.id == batch.generation {
      elementCommandDrafts[reference]=draft;changed=true
    }
    if changed { didChangeElementCommandProjection() }
  }

  private func registerElementCommand(_ plan:NotebookElementCommandPlan,batch:NotebookElementCommandBatch,
    reserved:Set<EditableElementReference> = []) {
    for operation in plan.operations {
      guard let reference=plan.references.first(where:{ $0.elementID == operation.id }) else { continue }
      if reserved.contains(reference),elementCommandSources[reference]?.id != batch.generation { continue }
      registerElementCommand(reference,batch:batch)
    }
  }

  func registerElementCommand(_ reference:EditableElementReference,batch:NotebookElementCommandBatch) {
    batch.reservedReferences.insert(reference)
    elementCommandSources[reference] = .init(id:batch.generation,task:Task { await batch.result.value?[reference] })
  }

  func nativeElementSource(_ reference: EditableElementReference) -> NotebookNativeElementSource? {
    switch reference {
    case .page(let owner,let id):
      guard let page = pagePresentationSource(owner) else { return nil }
      return .init(target:.init(kind:.page,id:owner),id:id,page:page.element(id:id),
        versions:page.collaboration?.elementVersions(id:id))
    case .spatial(let owner,let id):
      let element = boardHierarchy?.board(owner)?.element(id:id)
      guard boardHierarchy?.board(owner) != nil else { return nil }
      if element == nil, let pinned = scenePublication.pinnedElementSources[reference] { return pinned }
      let surface = element?.surface ?? acceptedWorkingGraphic(reference)?.surface
      let target = surface?.kind == .cover
        ? CollaborationTarget(kind:.cover,id:surface!.ownerID!,boardID:owner) : .init(kind:.board,id:owner)
      return .init(target:target,id:id,spatial:element,
        versions:boardHierarchy?.board(owner)?.collaboration?.elementVersions(id:id))
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
    guard let current = programModelCut(focus: focus), current.source.id == rendered.id,
      AgentProgramSource(current.source) == AgentProgramSource(rendered), current.source.state == rendered.state else { return nil }
    return current.basis
  }

  func programModelCut(focus: InteractiveElementReference) -> (source: AgentElement, basis: NotebookProgramStateBasis)? {
    switch focus {
    case .page(let pageID, let elementID):
      guard !isPageBeingDeleted(pageID), let page = pagePresentationSource(pageID),
        let source = page.element(id: elementID), source.kind == .web,
        let basis = page.programStateBasis(elementID) else { return nil }
      return (source, basis)
    case .board(let boardID, let elementID):
      guard let board = boardHierarchy?.board(boardID), let source = board.element(id: elementID),
        source.kind == .web, let basis = board.programStateBasis(elementID) else { return nil }
      return (agentElementSnapshotSource(source), basis)
    }
  }

  func checkpointProgramState(focus: InteractiveElementReference, rendered: AgentElement, value: JSONValue, basis: NotebookProgramStateBasis,
    admittedStateBytes: Int? = nil) async throws -> NotebookProgramStateBasis? {
    guard bootstrapAdmission.wasAccepted, !isStopped else { return nil }
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
    // A stopped runtime often checkpoints state already committed by its last
    // interaction. Validate that basis in storage, but do not invalidate every
    // page read/render for a no-op (one per visible program during a turn).
    let changesState = value != rendered.state
    if changesState { readAdmission.changed(target); collaborationReadEpoch &+= 1; collaborationContentEpoch &+= 1 }
    let accepted = try await persistence.submit(publishesChanges: changesState) { store in
      try store.checkpointProgramState(target: target, rendered: rendered, state: value, basis: basis, actor: actor, admittedStateBytes: admittedStateBytes)
    }
    if let accepted, accepted != basis { reloadExternalChanges() }
    return accepted
  }

  @discardableResult
  func commitElementState(pageID: UUID, elementID: String, state: JSONValue,
    onCommitted: NotebookProgramStateCompletion) -> Bool {
    guard !isStopped, !isPageBeingDeleted(pageID),
      let captured = onCommitted.sourceBasis else { return false }
    if loadState == .loading, !isClosing, workspaceHeader != nil {
      return bootstrapAdmission.deferProgramWrite(accept: { [weak self] in
        guard let self,
          self.commitElementState(pageID: pageID, elementID: elementID, state: state, onCommitted: onCommitted)
        else { onCommitted(nil); return }
      }, reject: { onCommitted(nil) })
    }
    guard loadState == .ready else { return false }
    // An accepted immutable state outlives the page's render window. Eviction
    // removes presentation, not its addressed writer or captured source basis.
    guard var page = pages[pageID] else {
      guard state.isValid else { return false }
      let cost:NotebookPersistenceAdmission.Cost
      do { cost=try NotebookElementWriteAllowance.pageProgramStateCost(state:state,basis:captured) }
      catch { showCue(error.localizedDescription);return false }
      guard let reservation=persistence.reserveWrite(cost) else {
        showCue("Сохранение заполнено. Повторите после восстановления записи.");return false
      }
      defer { persistence.releaseWriteReservation(reservation) }
      let basis = captured, actor = actorID
      do {
        try persistence.enqueueCommand(owner:.elementState(pageID,elementID),reservation:reservation,cost:cost,{ store in
          try store.commitPageProgramState(pageID:pageID,elementID:elementID,state:state,basis:basis,actor:actor,
            admittedStateBytes:onCommitted.admittedBytes)
        },completion:{ [weak self] result in
          switch result {
          case .success(let receipt):
            onCommitted(receipt.basis)
            if receipt.basis != nil,receipt.basis != basis {
              Task { @MainActor [weak self] in self?.reloadExternalChanges() }
            }
          case .failure:
            onCommitted(nil)
            Task { @MainActor [weak self] in self?.reloadExternalChanges() }
          }
        })
      } catch { showCue(error.localizedDescription);return false }
      // There is no published page value whose didSet could revoke an older
      // read. Admission still precedes its queued write, including a read's
      // final validation fence already in flight.
      readAdmission.changed(.init(kind: .page, id: pageID))
      collaborationReadEpoch &+= 1; collaborationContentEpoch &+= 1
      return true
    }
    guard let index = page.elements.firstIndex(where: { $0.id == elementID && $0.kind == .web }) else { return false }
    guard let current = page.programStateBasis(elementID), captured.hasSameSource(as: current) else { return false }
    guard let reservation=persistence.reserveWrite(NotebookElementWriteAllowance.maximumCost) else {
      showCue("Сохранение заполнено. Повторите после восстановления записи.");return false
    }
    defer { persistence.releaseWriteReservation(reservation) }
    let before = page
    if page.elements[index].state != state {
      guard page.replaceProgramState(state, elementID: elementID, actor: actorID) else { return false }
    }
    guard let command = NotebookPageProgramStateCommand(before: before, after: page, elementID: elementID) else { return false }
    let cost:NotebookPersistenceAdmission.Cost
    do { cost=try NotebookElementWriteAllowance.pageProgramStateCost(state:state,basis:captured,command:command) }
    catch { showCue(error.localizedDescription);return false }
    // Even a visible no-op crosses the addressed source/causal check after
    // earlier writes. A FIFO fence alone cannot attest a still-current heap.
    do {
      try persistence.enqueueCommand(owner:.elementState(pageID,elementID),reservation:reservation,cost:cost,{ store in
        try store.commitPageProgramState(command,admittedStateBytes:onCommitted.admittedBytes)
      },completion:{ [weak self] result in
        switch result {
        case .success(let receipt):
          onCommitted(receipt.basis)
          if receipt.basis != command.expectedBasis {
            Task { @MainActor [weak self] in self?.reloadExternalChanges() }
          }
        case .failure:
          onCommitted(nil)
          Task { @MainActor [weak self] in self?.reloadExternalChanges() }
        }
      })
    } catch { showCue(error.localizedDescription);return false }
    if before.agentStamp != page.agentStamp { pages[pageID] = page }
    readAdmission.changed(.init(kind:.page,id:pageID))
    collaborationReadEpoch &+= 1;collaborationContentEpoch &+= 1
    return true
  }

  func insertDocumentFile(documentID: UUID, path: String) async throws -> DocumentSourceRequest {
    guard shutdownPhase == .running, !isItemBeingDeleted(documentID) else { throw CancellationError() }
    let actor = actorID
    await withCheckedContinuation { continuation in inputGate.performAfterIdle { continuation.resume() } }
    let inserted = try await persistence.submit(publishesChanges: true) {
      try $0.insertDocumentFile(documentID: documentID, path: path, actor: actor)
    }
    pencilUndoHistory.recordCommand(domain: .document(documentID), actionID: inserted.receipt.id)
    if var current = documents[documentID] { _ = current.merge(inserted.document); documents[documentID] = current }
    else { documents[documentID] = inserted.document }
    reloadExternalChanges()
    return .init(documentID: documentID, file: inserted.document.files.first { $0.id == inserted.fileID }!,
      version: inserted.document.fileVersion(fileID: inserted.fileID))
  }

  func renameDocumentFile(documentID: UUID, fileID: String, path: String) async throws -> DocumentSourceRequest {
    guard shutdownPhase == .running, !isItemBeingDeleted(documentID) else { throw CancellationError() }
    let actor = actorID
    await withCheckedContinuation { continuation in inputGate.performAfterIdle { continuation.resume() } }
    readAdmission.changed(.init(kind: .document, id: documentID))
    let renamed = try await persistence.submit(publishesChanges: true) {
      try $0.renameDocumentFile(documentID: documentID, fileID: fileID, path: path, actor: actor)
    }
    pencilUndoHistory.recordCommand(domain: .document(documentID), actionID: renamed.receipt.id)
    if var current = documents[documentID] { _ = current.merge(renamed.document); documents[documentID] = current }
    else { documents[documentID] = renamed.document }
    reloadExternalChanges()
    return .init(documentID: documentID, file: renamed.document.files.first { $0.id == fileID }!,
      version: renamed.document.fileVersion(fileID: fileID))
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
    readAdmission.changed(.init(kind: .document, id: edit.documentID))
    let actor = actorID
    if let documentSaveObserver { DocumentRenderRegistry.shared.removeLiveObserver(documentSaveObserver) }
    documentSavePresentation = .init(sessionID: edit.sessionID, documentID: edit.documentID,
      fileID: edit.fileID, phase: .saving, source: edit.source)
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
      if let actionID = result.actionID { pencilUndoHistory.recordCommand(domain: .document(edit.documentID), actionID: actionID) }
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
      document.files.first(where: { $0.id == saved.fileID })?.source != saved.source {
      // Undo or a newer author's source superseded this pending presentation.
      // It can no longer install, so it must not leave an endless save cue.
      clearDocumentSavePresentation(sessionID: saved.sessionID); return
    }
    guard
      let presence, presence.mode == .document, presence.focusedItemID == saved.documentID,
      presence.openProgress >= 0.999, presencePhase == .settled,
      !documentReading.isRestoring(saved.documentID),
      let document = documents[saved.documentID], let state = documentStates[saved.documentID],
      document.files.first(where: { $0.id == saved.fileID })?.source == saved.source,
      DocumentRenderRegistry.shared.hasLiveSurface(document: document, state: state, pageIndex: presence.documentPageIndex, scope: .paper) else { return }
    documentSavePresentation?.phase = .installed
    documentSavePresentation?.source = nil
    if let documentSaveObserver { DocumentRenderRegistry.shared.removeLiveObserver(documentSaveObserver) }
    documentSaveObserver = nil
  }

  func drainAcceptedProgramWrites() async {
    await persistence.finishAcceptedProgramWrites()
  }

  @discardableResult
  func commitDocumentState(documentID: UUID, program: DocumentProgramSource, value: JSONValue) async throws -> ContentFieldVersion? {
    guard value.isValid else { throw NotebookStorageError.invalidTransaction("document state value") }
    guard !isStopped, !isItemBeingDeleted(documentID) else { return nil }
    if loadState == .loading {
      guard !isClosing, workspaceHeader != nil, let document = documents[documentID],
        (try? DocumentProgramSource(document: document, instanceID: program.id, path: program.path).sourceBasis) == program.sourceBasis,
        await bootstrapAdmission.waitForProgramWrites() else { return nil }
      try Task.checkCancellation()
    }
    guard loadState == .ready, !isStopped, !isItemBeingDeleted(documentID) else { return nil }
    readAdmission.changed(.init(kind: .document, id: documentID))
    if documents[documentID] == nil || documentStates[documentID] == nil {
      // A retiring heap keeps its admitted value and writer position even after
      // the document leaves the working set. Eviction does not revoke source.
      let actor = actorID
      return await withCheckedContinuation { continuation in
        persistence.enqueue(owner: .documentState(documentID)) { store in
          let accepted = try store.commitDocumentState(documentID: documentID, programID: program.id,
            programPath: program.path, value: value, sourceBasis: program.sourceBasis, actor: actor)
          continuation.resume(returning: accepted?.record.value == value ? accepted?.record.valueVersion : nil)
          return accepted != nil
        }
      }
    }
    guard let document = documents[documentID],
      (try? DocumentProgramSource(document: document, instanceID: program.id, path: program.path).sourceBasis) == program.sourceBasis,
      var journal = documentStates[documentID] else { return nil }
    if journal.commit(instanceID: program.id, value: value, actor: actorID) {
      documentStates[documentID] = journal
    }
    guard let record = journal.records.first(where: { $0.id == program.id && $0.value == value }) else { return nil }
    let command = NotebookDocumentStateCommand(documentID: documentID, record: record,
      journalStamp: journal.stamp, programPath: program.path, expectedSourceBasis: program.sourceBasis)
    // Display is immediate; the executor adopts only its value's durable receipt.
    // A concurrent winner cannot authorize this heap's next checkpoint.
    return await withCheckedContinuation { continuation in
      persistence.enqueue(owner: .documentState(documentID)) { store in
        let result = try store.commitDocumentState(command)
        let version: ContentFieldVersion?
        if case .committed(let accepted) = result, accepted.record.value == value {
          version = accepted.record.valueVersion
        } else { version = nil }
        continuation.resume(returning: version)
        return result != command.expectedResult
      }
    }
  }

  /// A checkpoint always reaches the durable file-basis CAS. Closing an editor
  /// cannot lose the captured program path or turn an old heap into a new author.
  func checkpointDocumentState(documentID: UUID, blockID: String, value: JSONValue,
    program: DocumentProgramSource, stateVersion: ContentFieldVersion?) async throws -> ContentFieldVersion? {
    guard value.isValid, program.id == blockID else { throw NotebookStorageError.invalidTransaction("document checkpoint value") }
    guard bootstrapAdmission.wasAccepted, !isStopped, !isItemBeingDeleted(documentID) else { return nil }
    if let document = documents[documentID],
      (try? DocumentProgramSource(document: document, instanceID: program.id, path: program.path).sourceBasis) != program.sourceBasis { return nil }
    let observesLocalState = documentStates[documentID] != nil
    let command: NotebookDocumentStateCommand?
    if var journal = documentStates[documentID] {
      guard journal.records.first(where: { $0.id == blockID })?.valueVersion == stateVersion else { return nil }
      _ = journal.commit(instanceID: blockID, value: value, actor: actorID)
      guard let record = journal.records.first(where: { $0.id == blockID }), record.value == value else {
        throw NotebookStorageError.invalidTransaction("document checkpoint admission")
      }
      command = .init(documentID: documentID, record: record, journalStamp: journal.stamp,
        programPath: program.path, expectedSourceBasis: program.sourceBasis, stateCondition: .matching(stateVersion))
    } else { command = nil }
    let actor = actorID
    // Keep the admitted frozen snapshot in the existing writer FIFO through a
    // disk retry. Publish its exact addressed receipt, never the whole scene.
    let accepted: NotebookDocumentStatePublication? = await withCheckedContinuation { continuation in
      persistence.enqueue(owner: .documentState(documentID)) { store in
        let publication: NotebookDocumentStatePublication?
        let reload: Bool
        if let command {
          let result = try store.commitDocumentState(command)
          if case .committed(let value) = result { publication = value } else { publication = nil }
          reload = result != command.expectedResult
        } else {
          publication = try store.checkpointDocumentState(documentID: documentID, programID: program.id,
            programPath: program.path, value: value, sourceBasis: program.sourceBasis, stateVersion: stateVersion, actor: actor)
          reload = publication != nil
        }
        continuation.resume(returning: publication)
        return reload
      }
    }
    try Task.checkCancellation()
    guard let accepted, !isStopped, !isItemBeingDeleted(documentID) else { return nil }
    // SQL accepts the checkpoint at its position in the write queue. A later
    // contact can already be admitted locally while that write was waiting.
    // Only the observed state or this exact writer publication may retire it.
    if let document = documents[documentID],
      (try? DocumentProgramSource(document: document, instanceID: program.id, path: program.path).sourceBasis) != program.sourceBasis { return nil }
    if var journal = documentStates[documentID] {
      let current = journal.records.first(where: { $0.id == blockID })
      guard current?.valueVersion == stateVersion
        || (current?.valueVersion == accepted.record.valueVersion && current?.value == value) else { return nil }
      // This exact writer publication does not replace the scene protected by
      // the current gesture. The next contact still needs its accepted clock.
      let changed = journal.merge(accepted)
      guard let record = journal.records.first(where: { $0.id == blockID }),
        record.valueVersion == accepted.record.valueVersion, record.value == value else { return nil }
      if changed { documentStates[documentID] = journal }
      return record.valueVersion
    }
    // A detached runtime does not reopen the document to acknowledge its write.
    guard !observesLocalState else { return nil }
    return accepted.record.valueVersion
  }

  // Undo's recognized contacts must see the material they are changing. This
  // uses the shared contact owner, not a second "ignore input" publication path.
  private var historyContactPermitsPublication: Bool {
    inputGate.hasOnlyHistoryContacts && peerAllowsCurrentPublication
      && presencePhase == .settled && selectionSession.manipulation == nil
  }

  // A camera contact owns its coordinates, not the old content cursor. The
  // same admission as scene preparation still protects Pencil and controls.
  private var permitsExternalScenePublication: Bool {
    (!inputGate.isActive && presencePhase != .active)
      || (presencePhase == .active && permitsScenePreparation)
      || historyContactPermitsPublication
  }

  @discardableResult
  func reloadExternalChanges() -> Task<Void, Never>? {
    guard loadState == .ready, !isStopped else { return nil }
    requestActionArrivalDrain()
    guard permitsExternalScenePublication else { externalReloadPending = true; return nil }
    diskRefreshRequested = true
    if let diskRefreshTask { return diskRefreshTask }
    let task = Task { [weak self] in
      guard let self else { return }
      defer { diskRefreshTask = nil }
      while diskRefreshRequested, !Task.isCancelled, let presence {
        guard permitsExternalScenePublication else { externalReloadPending = true; return }
        diskRefreshRequested = false
        let admission = readAdmission.begin()
        defer { readAdmission.end(admission) }
        let draftEpoch = documentDraftEpoch
        let elementPins = scenePinnedElements, itemPins = scenePinnedItems
        let metadataGeneration = collaborationMetadataGeneration
        let previousIndex = sceneIndex, previousPages = acceptedPageSources
        let readPresence = sceneReadPresence(for: presence)
        let preparedIDs = preparedNotebookPageIDs(in: readPresence.selectedItemID)
        let inkPins = drawingTools.pinnedSpatialInkActionIDs
        let attentionID = agentFeedback.attentionID, attentionReferences = agentFeedback.attention.map(\.reference)
        #if os(iOS)
          let feedbackKnown = agentFeedback.knownActions, feedbackTracked = agentFeedback.trackedActions
        #else
          let feedbackKnown: Set<UUID>? = nil, feedbackTracked: Set<UUID> = []
        #endif
        do {
          let _: Void = try await persistence.submit { _ in () }
          let prepared = try await backgroundSceneReader.read { [actor = actorID] store in
            try NotebookDiskRefresh.prepare(store: store, presence: readPresence,
              pinnedElements: elementPins, pinnedItems: itemPins, preparedPages: preparedIDs,
              feedbackKnown: feedbackKnown, feedbackTracked: feedbackTracked, attentionReferences: attentionReferences,
              historyActor: actor, pinnedInkActionIDs: inkPins, reusing: previousIndex, reusingPages: previousPages)
          }
          publicationFailure = nil
          if persistence.failure == nil { persistenceFailure = arrivalFailure }
          let liveDrafts = documentEditingSessions
          let sourceIsCurrent = try await persistence.submit { [actor = actorID] store in try prepared.scene.isCurrent(store: store, actor: actor) }
          guard sourceIsCurrent,
            preparedNotebookPageIDs(in: readPresence.selectedItemID) == preparedIDs,
            acceptExternalScene(prepared.scene, admission: admission,
            observedPresence: presence, observedPreparation: readPresence, itemPins: itemPins, preparedIndex: prepared.sceneIndex) else {
            if !permitsExternalScenePublication || !peerAllowsCurrentPublication { externalReloadPending = true; return }
            diskRefreshRequested = true; continue
          }
          if draftEpoch != documentDraftEpoch { documentEditingSessions = liveDrafts }
          guard metadataGeneration == collaborationMetadataGeneration else { diskRefreshRequested = true; continue }
          agentFeedback.receive(actions: prepared.actions, changes: prepared.feedback)
          if let attentionID, attentionID == agentFeedback.attentionID {
            if let attention = prepared.attention { agentFeedback.refreshAttention(attention) }
            else { presentationPlayer.interrupt("attention_source_changed") }
          }
          acceptCollaborationMetadata(actions: prepared.actions,
            contexts: prepared.contexts, delivery: prepared.delivery)
        } catch {
          guard !Task.isCancelled, !isStopped else { return }
          publicationFailure = error.localizedDescription
          // Successful writes retain their addressed output and presentation.
          // Retrying this owner repeats only the read/publication.
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

    /// Native acceptance exercises the same journal and owner as paired input.
    func localCodexQuery(_ query: NotebookChatQuery, requestID: UUID = UUID()) async throws -> NotebookChatReply {
      if codexSidecar == nil { await startCodexSidecar() }
      guard let codexSidecar else { throw NotebookPersistenceQueue.Failure(message: agentStartupError ?? "Codex недоступен") }
      guard let envelope = await codexSidecar.receive(.init(id: requestID, body: .request(query)), peerID: actorID),
        case .reply(let reply) = envelope.body else { throw NotebookTransportError.disconnected }
      if case .failure(let message) = reply { throw NotebookPersistenceQueue.Failure(message: message) }
      return reply
    }
    func startCodexSidecar() async {
      guard !isClosing, loadState == .ready, codexSidecar == nil,
        let workspaceID = workspaceHeader?.workspaceID else { return }
      if let codexStartupTask { await codexStartupTask.value; return }
      let task = Task { [self] in
        defer { codexStartupTask = nil }
        do {
          guard allowsCodexRegistration || acceptance != nil else {
            agentStartupError = "Запуск Codex из этого архива закрыт до безопасной активации пары. Действующие инструменты Notebook не перенаправлены."
            return
          }
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
          let sidecar = try await host.workspace(persistence: persistence,
            workspaceID: workspaceID, computerID: actorID, directory: directory, scope: scope, entry: entry, socket: commandSocketURL,
            isWorkspaceOpen: { [weak self] in self?.isClosing == false },
            authorizePeer: { [weak self] peer in
              guard let self else { return false }
              return peer == self.actorID || self.sync?.pairedPeers.contains(where: { $0.deviceID == peer }) == true
            }) { [weak self] envelope, peer in
              guard let self, !isClosing, peer != actorID else { return }
              sync?.sendTransient(.codex(envelope), to: peer)
            }
          guard !isClosing else { sidecar.detachView(); return }
          codexSidecar = sidecar; agentStartupError = nil
        } catch { if !isClosing { agentStartupError = NotebookCodexSidecar.message(error) } }
      }
      codexStartupTask = task
      await task.value
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
      guard loadState == .ready, permitsExternalWork else {
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
      if command.command == .importDocument {
        guard let request = command.documentImport else {
          throw CollaborationError("invalid_document_import", "Запрос импорта документа отсутствует.")
        }
        return try await importDocument(request).response
      }
      if command.command == .importDocumentResource {
        guard let request = command.documentResourceImport, let workspaceID = workspaceHeader?.workspaceID else {
          throw CollaborationError("invalid_document_resource", "Запрос импорта ресурса отсутствует.")
        }
        if programImporter == nil { programImporter = NotebookProgramImporter(persistence: persistence, workspaceID: workspaceID) }
        return try await programImporter!.handle(request)
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
      if command.command == .panelPresentation {
        guard let request = command.panelPresentation, let publisher = previewPublisher,
          let socket = commandSocketURL else {
          throw CollaborationError("owner_unavailable", "Представление Notebook ещё не готово.")
        }
        let result = try await publisher.panelPresentation(request)
        guard case .object(var fields) = result else {
          throw CollaborationError("invalid_panel_presentation", "Представление Notebook не содержит адреса.")
        }
        fields["socketKey"] = .string(socket.deletingPathExtension().lastPathComponent)
        return .object(fields)
      }
      if NotebookReadCommand.accepts(command.command) {
        let request = try NotebookReadCommand(command), nativeActor = actorID
        var result = try await readCommandCut { try $0.handle(request, nativeActor: nativeActor) }
        if command.command == .panelRead, let socket = commandSocketURL, case .object(var fields) = result {
          fields["socketKey"] = .string(socket.deletingPathExtension().lastPathComponent)
          result = .object(fields)
        }
        return result
      }
      let deadline = ContinuousClock.now.advanced(by: .seconds(4))
      while true {
        // Core admits the actual affected carriers in the writer transaction.
        // An unrelated contact never delays the first attempt; only a rejected
        // affected surface waits outside the FIFO so its release can commit.
        do {
          guard permitsExternalWork else { throw CollaborationError("owner_unavailable", "Notebook завершает работу.") }
          let nativeActor = actorID
          let result = try await persistence.submit(owner: .command(command.command)) {
            try NotebookCommandDispatcher(store: $0, nativeActor: nativeActor).handle(command)
          }
          if command.changesStore { reloadExternalChanges() }
          return result
        } catch let error as CollaborationError where error.code == "input_active" && ContinuousClock.now < deadline {
          try await Task.sleep(for: .milliseconds(20))
        }
      }
    }

    /// A fixed accepted prefix is captured before the first await. The reader
    /// then owns its own fresh WAL snapshot; later writes keep draining.
    private func readCommandCut<Value: Sendable>(
      _ operation: @escaping @Sendable (NotebookQueryCut) throws -> Value) async throws -> Value {
      guard loadState == .ready, permitsExternalWork, let workspaceID = admittedWorkspaceID else {
        throw CollaborationError("owner_unavailable", "Читатель рабочего пространства ещё не готов.")
      }
      let fence = persistence.captureReadFence()
      try await fence.wait()
      guard permitsExternalWork, admittedWorkspaceID == workspaceID else {
        throw CollaborationError("owner_unavailable", "Чтение этого рабочего пространства завершено.")
      }
      return try await commandReader.read(workspaceID: workspaceID, operation)
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
      }, reader: { [weak self] operation in
        guard let self else { throw CollaborationError("owner_unavailable", "Notebook завершает работу.") }
        return try await self.readCommandCut(operation)
      }, persistence: { operation in
        try await persistence.submit(writesStore: true, operation)
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
        enqueueStoreWrite(owner: .peerSession(value.deviceID)) { _ = try $0.acceptSelectionPublication(value, connectionID: generation) }
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
          guard let self, peerGenerations[peerID] == generation, !isClosing else { return }
          await startCodexSidecar()
          guard peerGenerations[peerID] == generation, !isClosing else { return }
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
      // Admission precedes the durable contact record in the same writer order.
      guard peerPublication.receive(activity) else { return }
      enqueueStoreWrite(owner: .inputActivity(activity.deviceID)) { try $0.saveInputActivity(activity) }
    case .presence(let envelope):
      #if os(macOS)
        guard observedPeerID == peerID, presenceSequenceTracker.accepts(envelope),
          presenceIsUsable(envelope.presence) else { return }
        presentationRelay.observe(envelope, from: peerID)
        peerPresenceEnvelope = envelope
        if envelope.phase == .settled {
          enqueueStoreWrite(owner: .peerPresence(peerID)) {
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
    case .document: return DocumentRenderRegistry.shared.program(documentID: ref.target.id, id: id) != nil
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
          let program = DocumentRenderRegistry.shared.program(documentID: document.id, id: id) else { throw CancellationError() }
        acceptsState = { value in
          DocumentRenderRegistry.shared.program(documentID: document.id, id: id)?.sourceBasis == program.sourceBasis
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
    if selection.hasAcceptedCommands {
      publication=Task {
        let prepared:Result<NotebookAttentionSelection,Error>
        do { prepared = .success(try await selection.resolvingAcceptedCommands()) }
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
      guard !isClosing, let chat, !isSavingAgentQuestion,
        captured != nil || !selectionSession.isResolvingContext else { onSaved?(false); return nil }
      var submittedContext = captured
      if case .draft = source {
        guard chat.canSendDraft else { onSaved?(false); return nil }
        if chat.browsesChats {
          submittedContext = submittedContext ?? captureChatSubmissionContext(chat)
          guard chat.beginDraft(project:nil) else { onSaved?(false); return nil }
        }
      }
      let destination = chat.messageDestination, submittedThread = destination.threadID
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
      if let chatSubmissionError, agentRequestError == chatSubmissionError { agentRequestError = nil }
      chatSubmissionError = nil
      isSavingAgentQuestion = true
      let previous = pendingChatSubmission
      let keepsIntent = previous.map { pending in
        pending.computer == submittedComputer && pending.destination == destination
          && pending.text == submittedText && pending.steeringTurn == submittedTurn
          && pending.context.attachments == chat.attachments
          && pending.context.selectionID == selectionSession.id
          && pending.context.pointing.intentGeneration == laserContext.intentGeneration
          && (submittedContext == nil || pending.context === submittedContext)
      } ?? false
      let captured = keepsIntent ? previous!.context : submittedContext ?? captureChatSubmissionContext(chat)
      laserContext.reserve(captured.pointing)
      laserContext.rebind(captured.pointing,to:chat.pointingScope)
      let task = Task { [self] in
        var saved = false
        defer {
          laserContext.finish(captured.pointing, consumed:saved)
          if saved { pendingChatSubmission = nil }
          isSavingAgentQuestion = false; chatSubmissionTask = nil; onSaved?(saved)
        }
        do {
          if !keepsIntent, let previous {
            let recovery = try await chat.reconcileFailedMessageForChangedIntent()
            pendingChatSubmission = nil
            if recovery == .saved {
              // Confirm the prior immutable message, not this changed draft.
              // Its exact old IDs cannot consume newer pointing.
              laserContext.finish(previous.context.pointing,consumed:true)
              return
            }
          }
          let context = try await captured.prepare()
          let attachments = captured.attachments + context.images
          guard CodexInputAttachment.valid(attachments) else {
            throw CollaborationError("chat_image_limit", "В сообщение можно включить не более пяти изображений и шестнадцати вложений. Уберите лишние перед отправкой.")
          }
          guard chat.computerID == submittedComputer else { throw NotebookTransportError.disconnected }
          pendingChatSubmission = (submittedComputer,destination,submittedText,submittedTurn,captured)
          saved = await chat.sendMessage(to: destination, text: submittedText, context: context.text,
            attentionContextID: context.attentionContextID, steeringTurnID: submittedTurn, attachments: attachments,
            dictationID: dictationID)
        } catch {
          let message = (error as? NotebookStorageError) == .limitExceeded("chat images")
            ? "В сообщение можно включить не более пяти изображений общим размером 4 МиБ. Уберите лишние указания перед отправкой."
            : error.localizedDescription
          chatSubmissionError = message; agentRequestError = message
        }
      }
      chatSubmissionTask = task
      return task
    }

    @MainActor final class ChatSubmissionContext {
      typealias Prepared = (text: String, attentionContextID: UUID?, images: [CodexInputAttachment])
      let selectionID: UUID
      let attachments: [CodexInputAttachment]
      let pointing: NotebookLaserContext.Batch
      private let preparation: @MainActor () async throws -> Prepared
      private var prepared: Prepared?
      init(selectionID: UUID, attachments: [CodexInputAttachment], pointing: NotebookLaserContext.Batch,
        prepare: @escaping @MainActor () async throws -> Prepared) {
        self.selectionID = selectionID; self.attachments = attachments; self.pointing = pointing; preparation = prepare
      }
      func prepare() async throws -> Prepared {
        if let prepared { return prepared }
        let result = try await preparation(); prepared = result; return result
      }
    }
    /// The send gesture freezes attention and attachments before transcription
    /// or image rendering can suspend. Both text and dictation use this owner.
    func captureChatSubmissionContext(_ chat: NotebookChatController) -> ChatSubmissionContext {
      // Freeze the native selection at Send, before any suspension. A local
      // draft remains explicitly a draft, not a reference to different SQL text.
      let sourceSelection = documentSourceEditor?.messageSelection
      let question = sourceSelection == nil ? agentQuestion : nil
      let retainedSource = question.flatMap { q in pinnedAttentionSelections.first { $0.0 == q.contextID }?.1 }
      let retained = retainedSource?.freezingSubmissionVisuals()
      retainedSource?.resumePrograms()
      let capturedPresence = presence, capturedWorkspace = workspaceHeader?.workspaceID
      let capturedFile = chat.files.window.isOpen ? chat.files.document : nil
      let pointing = laserContext.snapshot(scope: chat.pointingScope)
      // Reuse the installed attention owner. No offscreen render or later
      // camera can substitute pixels for the view at the Send gesture.
      let viewport: NotebookAttentionSelection?
      if question == nil, pointing.isEmpty, capturedFile == nil,
        let presence = capturedPresence {
        viewport = NotebookAttentionProjection.capture(start:.zero,
          end:.init(x:presence.viewport.x,y:presence.viewport.y),model:self,presence:presence,
          cohort:compositionTiles.published,installedInk:compositionTiles.surfaceRegistry.installedSources(),compositeRegion:true)?.freezingSubmissionVisuals()
      } else { viewport = nil }
      let persistence = self.persistence, actor = actorID, attachments = chat.attachments
      return .init(selectionID: selectionSession.id, attachments: attachments, pointing: pointing) {
        var imageAttachments: [CodexInputAttachment] = []
        var imageAdmissionValidated = false
        var viewReferences: [CollaborationReference] = []
        var viewUnavailable: String?

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
          imageAttachments = try await persistence.submit { try $0.chatAttentionAttachments(contextID:question.contextID) }
        }
        let pointingImages = try await NotebookLaserContext.images(pointing)
        if !pointingImages.isEmpty {
          let existingAttachments = attachments + imageAttachments
          imageAttachments += try await persistence.submit(publishesChanges:true) {
            try $0.saveChatImageAttachments(pointingImages,author:actor,existingAttachments:existingAttachments)
          }
          imageAdmissionValidated = true
          viewReferences = pointingImages.map(\.reference)
        } else if question == nil, capturedFile == nil {
          if let viewport {
            do {
              let ready = try await viewport.resolvingAcceptedCommands()
              let references = try await Task.detached { try ready.resolvedReferences() }.value
              let rendered = try await ready.renderPinnedImages(references:references)
              let images = try references.map { reference -> NotebookChatImage in
                guard let image = rendered.images[reference.id] else {
                  throw CollaborationError("view_pixels_missing", rendered.unavailable[reference.id] ?? "Видимое изображение ещё не готово.")
                }
                return .init(reference:reference,image:image)
              }
              imageAttachments = try await persistence.submit(publishesChanges:true) {
                try $0.saveChatImageAttachments(images,author:actor,name:"Текущий вид Notebook",existingAttachments:attachments)
              }
              imageAdmissionValidated = true
              viewReferences = references
            } catch { viewUnavailable = error.localizedDescription }
          } else { viewUnavailable = "Видимое изображение ещё не установлено. Presence описывает положение камеры, но не доказывает видимые пиксели." }
        }
        let combinedAttachments = attachments + imageAttachments
        if !imageAdmissionValidated, combinedAttachments.contains(where: { $0.kind == .image }) {
          try await persistence.submit { store in
            do {
              guard try store.resolvedChatImageAttachments(combinedAttachments) != nil else {
                throw CollaborationError("attention_pixels_missing", "Изображение выбранного фрагмента не готово. Укажите его снова.")
              }
            } catch NotebookStorageError.limitExceeded("chat images") {
              throw CollaborationError("chat_image_limit", "В сообщение можно включить не более пяти изображений общим размером 4 МиБ. Уберите лишние указания перед отправкой.")
            }
          }
        }
        let context: JSONValue = .object([
          "workspaceID": capturedWorkspace.map { .string($0.uuidString) } ?? .null,
          "presence": try capturedPresence.map(JSONValue.encode) ?? .null,
          "file": try capturedFile.map { try .encode($0.address) } ?? .null,
          "fileLink": capturedFile.map { .string(NotebookCodeLink.file($0.address, line: 1).url.absoluteString) } ?? .null,
          "fileHasLocalDraft": capturedFile.map { .bool($0.text != $0.base) } ?? .null,
          "visibleImages": try .encode(viewReferences),
          "visibleImageUnavailable": viewUnavailable.map(JSONValue.string) ?? .null,
          "documentSourceSelection": try sourceSelection.map(JSONValue.encode) ?? .null,
          "attention": try question.map { question in
            .object(["contextID": .string(question.contextID.uuidString),
              "entryID": .string(question.entryID.uuidString), "references": try .encode(question.references)])
          } ?? .null,
          "meaning": .string("Attached images show the exact frozen Notebook view or explicit pointing at submission; presence alone is not visual evidence. If visibleImageUnavailable is non-null, say that the image was unavailable instead of claiming to see it. Read frozen attention inside notebook_execute with await nb.attention({contextID, referenceID}); use emitImage(result.data.artifact) when present. notebook_context gives compact current context; Reads return {data,basis,coverage,cursor}; nb.transaction(key,{base:snapshot.basis,summary,operations}) returns immutable ActionResult. Consult nb.help(topic) only when needed. Shared Notebook workspace. Selection directs attention, not permissions. Use nb.reference, nb.transaction, nb.undo and nb.action for source/version checks, undoable edits and separate saved/received/shown receipts. For code notes use nb.code and the appendInkStroke operation on codeFragment. Use notebook://code/UUID for the read fragment, or fileLink with the required 1-based line query, in Markdown references. These links scroll only the document. documentSourceSelection contains the exact native text selection at Send, its UTF-16 range and baseVersion. hasLocalDraft marks unsaved or conflicting human text: read the current file before an addressed edit; do not treat the draft as the saved source. A local draft is not yet the working file on Mac. Do not move the board camera.")
        ])
        let text = String(decoding: try JSONEncoder().encode(context), as: UTF8.self)
        return (text, question?.contextID, imageAttachments)
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
    if requestedReference?.target.kind == .page || requestedReturn?.presence.mode == .page,
      let item = presence?.focusedItemID, let root = notebookPageRoot(item) {
      notebookPageNavigation.send(.cancel, ownerID: item, source: root)
    }
    navigationGeneration &+= 1
    peerPublication.navigationChanged(to: navigationGeneration)
    for waiter in navigationInputWaiters.values { waiter.cancel() }
    requestedReference = nil
    requestedReturn = nil
    documentNavigation.cancel()
    documentReading.cancelRestoration()
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

  private func waitForNavigationInput(idle: Bool) async -> Bool {
    let id = UUID()
    let task = Task { [inputGate] in
      if idle { return await inputGate.waitUntilIdle() }
      return await inputGate.waitUntilPageInputFinishes()
    }
    navigationInputWaiters[id] = task
    defer { navigationInputWaiters[id] = nil }
    return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
  }

  /// Resolve after the accepted input tail, then apply in this same actor
  /// segment. No delayed callback is allowed to retain an old physical address.
  private func finishNavigationInput(destination: CollaborationTarget,
    isCurrent: @MainActor () -> Bool) async -> Bool {
    let trace = navigationObservationScope()
    observeNavigation("input_fence_enter", fields: trace)
    defer { observeNavigation("input_fence_exit", fields: trace) }
    var observedContactWait = false
    while !Task.isCancelled, !isStopped, isCurrent() {
      // A held WebKit control or a physical pose tail also owns the current
      // view. Pencil's publication fence alone does not end those contacts.
      if inputGate.isActive {
        if !observedContactWait { observeNavigation("input_fence_wait_contact", fields: trace); observedContactWait = true }
        guard await waitForNavigationInput(idle: true) else { return false }
        continue
      }
      guard await finishPendingInteraction(boundary: .acceptedInput, continuing: isCurrent) else { return false }
      guard !Task.isCancelled, !isStopped, isCurrent() else { return false }
      if !inputGate.isActive {
        guard await checkpointDepartingProgram(destination: destination) else {
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
      guard await finishNavigationInput(destination: reference.target, isCurrent: isCurrent) else {
        if !Task.isCancelled, !isStopped, isCurrent() { cancelRequestedNavigation() }
        return
      }
      guard !Task.isCancelled, !isStopped, isCurrent() else { return }
      let admission = readAdmission.begin()
      defer { readAdmission.end(admission) }
      let pencilGeneration = inputGate.pencilGeneration
      do {
        observeNavigation("location_read_begin", reference: reference)
        let resolved = try await persistence.submit { store in
          try store.readTransaction { _ in
            (try store.readReferenceLocation(reference), try store.inputScopes(for: [reference.target])[0])
          }
        }
        let (location, scope) = resolved
        observeNavigation("location_read_end", reference: reference)
        guard !Task.isCancelled, !isStopped, isCurrent() else { return }
        guard readAdmission.permits(admission, targets: scope.publicationTargets), pencilGeneration == inputGate.pencilGeneration,
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

  func rememberReturnPlace(_ captured: SessionPresence? = nil) {
    guard let presence = captured ?? presence, returnPlaces.last?.presence != presence else { return }
    returnPlaces.append(.init(presence: presence, pageID: presence.notebookPageID,
      reading: presence.focusedItemID.flatMap { documentReading.position(for: $0) }))
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
        self.documentReading.returnTo(reading)
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

  private func admitHistoryChange(_ id: UUID) {
    if let action = collaborationActions.first(where: { $0.id == id }) {
      for operation in action.action.operations { readAdmission.changed(operation.target) }
    } else {
      // A not-yet-published command has no receipt projection. Its accepted
      // history domain is still the physical owner of this local Undo/Redo.
      if case .target(let kind, let owner)? = activeHistoryDomain { readAdmission.changed(.init(kind: kind, id: owner)) }
    }
  }

  func undoCollaboration(_ id: UUID) {
    guard inputGate.permitsNewContact, !inputGate.hasActivePencil,
      selectionSession.manipulation == nil else { return }
    _ = acceptCollaborationHistory(id, redo: false, actionID: UUID(), after: collaborationHistoryTask)
  }

  func redoCollaboration(_ id: UUID) {
    guard inputGate.permitsNewContact, !inputGate.hasActivePencil,
      selectionSession.manipulation == nil else { return }
    _ = acceptCollaborationHistory(id, redo: true, actionID: UUID(), after: collaborationHistoryTask)
  }

  /// Admission happened at the input owner. Reserve this exact inverse now;
  /// its preparation joins only the preceding history receipt and source action.
  private func acceptCollaborationHistory(_ id: UUID, redo: Bool, actionID: UUID,
    after previous: Task<Bool, Never>?) -> Task<Bool, Never> {
    guard let reservation = persistence.reserveWrite(NotebookItemWriteAllowance.maximumCost) else {
      showCue("Сохранение заполнено. Повторите после восстановления записи.")
      return Task { false }
    }
    defer { persistence.releaseWriteReservation(reservation) }
    admitHistoryChange(id)
    let pending = pendingCollaborationCommands[id], actor = actorID
    let operation = Task { () throws -> NotebookPersistenceQueue.PreparedCommand<CollaborationReceipt> in
      if let previous, !(await previous.value) {
        throw CollaborationError("revision_conflict", "История не продолжена: предыдущая отмена была отклонена.")
      }
      if let pending, !(await pending.value) {
        throw CollaborationError("revision_conflict", "Отмена не применяется: исходное действие было отклонено.")
      }
      return .init(cost: NotebookItemWriteAllowance.maximumCost, operation: { store in
        if redo { return try store.redoNativeAction(id, actionID: actionID, actor: actor) }
        return try store.undoNativeAction(id, actor: actor)
      })
    }
    let saved: Task<CollaborationReceipt, Error>
    do { saved = try persistence.enqueuePreparedCommand(reservation: reservation, operation, publishesChanges: true) }
    catch { operation.cancel(); showCue(error.localizedDescription); return Task { false } }
    collaborationReadEpoch &+= 1
    collaborationHistoryRequest = actionID
    let completion = Task { [weak self] in
      guard let self else { return false }
      let result = await saved.result
      if collaborationHistoryRequest == actionID {
        collaborationHistoryTask = nil; collaborationHistoryRequest = nil
      }
      switch result {
      case .success(let receipt):
        for domain in receipt.action.nativeHistoryDomains {
          if redo { _ = pencilUndoHistory.recordRepeatedCommand(domain: domain, originalID: id, actionID: actionID) }
          else { pencilUndoHistory.didUndoCommand(domain: domain, actionID: id) }
        }
        reloadExternalChanges()
        showCue(redo ? "Повторено" : (receipt.undo?.preserved.isEmpty == false ? "Ход отменён. Ваши доработки сохранены" : "Ход отменён"))
        return true
      case .failure(let error):
        reloadExternalChanges(); showCue(error.localizedDescription); return false
      }
    }
    collaborationHistoryTask = completion
    return completion
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

  /// Returns whether a current on-screen source is still awaiting presentation.
  /// The display clock uses this for scheduling, never as a shown receipt.
  @discardableResult
  func confirmVisibleActions(presence visible: SessionPresence, scene: WorkspaceSceneWorkset? = nil,
    cohort: SceneCompositionCohort? = nil) -> Bool {
    if let cohort { retirePresentedGraphicCommands(in:cohort) }
    #if os(iOS)
      if let id = visible.notebookPageID, let page = pages[id] {
        retirePresentedPageGraphicCommands(page, installedGraphics: pagePresentations.hasInstalledGraphics(page))
      }
      if let cohort { retireWorkingGraphics(in: cohort) }
      confirmAgentFeedback(presence: visible, scene: scene, cohort: cohort)
      func matches(_ receipt: DeviceActionReceipt, _ action: NotebookActionReadModel) -> Bool {
        receipt.matches(action)
      }
      guard collaborationActions.contains(where: { action in !deviceActionReceipts.contains(where: { matches($0, action) && $0.displayComplete }) }),
        presencePhase == .settled, presence == visible, !isPointing,
        collaborationDetailsAreCurrent else { return false }
      let receipts = deviceActionReceipts
      var changed: [DeviceActionReceipt] = []
      var awaitingPresentation = false
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
          guard ready else { awaitingPresentation = true; continue }
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
      return awaitingPresentation
    #else
      return false
    #endif
  }

  /// This opportunity comes from the native board confirmation path. Prepared
  /// rasters or a SwiftUI appearance alone cannot start optional WebKit work.
  func prepareCommonDocumentShellIfIdle(presence visible: SessionPresence, cohort: SceneCompositionCohort?) {
    #if os(iOS)
      guard preparationIsForeground, UIApplication.shared.applicationState == .active,
        !isClosing, permitsBackgroundPreparation, requestedReference == nil, requestedReturn == nil,
        presence == visible,
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

  /// A reference transfers the focused input owner. Retained unrelated heaps
  /// keep running; their eventual retirement owns their final checkpoint.
  private func checkpointDepartingProgram(destination: CollaborationTarget) async -> Bool {
    if let focus = interactiveElementFocus {
      let remainsOnSurface: Bool
      switch focus {
      case .page(let pageID, _): remainsOnSurface = destination.kind == .page && destination.id == pageID
      case .board(let boardID, _): remainsOnSurface = destination.kind == .board && destination.id == boardID
      }
      if !remainsOnSurface {
      guard await AgentWebCoordinator.checkpointPrograms(ownedBy: self, resume: true, focus: focus) else { return false }
      }
    }
    guard presence?.mode == .document, let documentID = presence?.focusedItemID,
      destination.kind != .document || destination.id != documentID else { return true }
    return await DocumentRenderRegistry.shared.checkpointFocusedProgram(documentID: documentID, resume: true)
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
        if graphic?.sourceInkContactID != nil,graph.node(element.id)?.placement.parentID == nil {
          guard let plan=cohort.liveData.orderedInk[element.surface],
            let canvas=compositionTiles.surfaceRegistry.canvas(for:element.surface),canvas.window != nil,
            canvas.isStableFramePresented,canvas.orderedInkPlan == plan else {return false}
          return true
        }
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

  private func notifyItemOwnerUnavailable(_ id: UUID, on boardID: UUID, through cursor: UInt64, deleted: Bool) {
    itemOwnerObserver?.receive(id, boardID, cursor)
    // A native cancellation can restore an origin carrying the retired
    // selection. Clear only the canonical receipt's address, after that owner
    // has chosen its surviving camera; nil in updatePresence means inheritance.
    // A transfer retires only the old physical placement; its live item
    // remains a valid session selection on another board.
    guard deleted, let current = presence, current.selectedItemID == id else { return }
    let cleared = current.selecting(itemID: nil, pageID: nil)
    setPresence(cleared, publishes: true)
    updatePresence(cleared, settled: presencePhase == .settled)
  }

  private func acceptItemOwnerInvalidations(_ state: NotebookSceneState, requested: [UUID: [UUID]]) {
    let unavailable = state.missingPinnedItems.union(state.transferredPinnedItems.keys)
    guard !unavailable.isEmpty else { return }
    for (boardID, ids) in requested {
      for id in ids where unavailable.contains(id) {
        notifyItemOwnerUnavailable(id, on: boardID, through: state.header.cursor,
          deleted: state.missingPinnedItems.contains(id))
      }
    }
    scenePinnedItems = scenePinnedItems.mapValues { $0.filter { !unavailable.contains($0) } }
  }

  /// The pending passage owns the sources it is preparing, not the still-closed
  /// cover along its camera route. A settled/cancelled passage has no such demand.
  private func sceneReadPresence(for actual: SessionPresence) -> SessionPresence {
    guard presencePhase == .active, let preparing = compositionPreparationPresence,
      preparing.selectedItemID == actual.selectedItemID else { return actual }
    return preparing
  }

  /// A completed SQL read observes the local content frontier from its request,
  /// not from its eventual callback. A later accepted move, stroke or selection
  /// invalidates that read even while the old pixels are still displayed.
  @discardableResult
  func acceptExternalScene(_ state: NotebookSceneState, admission: UUID,
    observedPresence: SessionPresence, observedPreparation: SessionPresence, itemPins: [UUID: [UUID]], preparedIndex: WorkspaceSceneIndex? = nil) -> Bool {
    guard !Task.isCancelled, !isStopped, permitsExternalScenePublication,
      peerAllowsPublication(of: observedPresence, in: state), peerAllowsPublication(of: observedPreparation, in: state),
      readAdmission.permits(admission, targets: state.readTargets),
      let current = presence, itemPins == scenePinnedItems else { return false }
    let moving = presencePhase == .active
    func withCurrentCamera(_ value: SessionPresence) -> SessionPresence {
      .init(boardID: value.boardID, mode: value.mode, camera: current.camera, viewport: current.viewport,
        focusedItemID: value.focusedItemID, openProgress: value.openProgress, documentPageIndex: value.documentPageIndex,
        selectedItemID: value.selectedItemID, notebookPageID: value.notebookPageID)
    }
    let retiredDemand = (observedPreparation.focusedItemID ?? observedPreparation.selectedItemID).map { id in
      itemPins[observedPreparation.boardID]?.contains(id) == true
        && (state.missingPinnedItems.contains(id) || state.transferredPinnedItems[id] != nil)
    } ?? false
    guard withCurrentCamera(observedPreparation) == withCurrentCamera(sceneReadPresence(for: current)),
      moving ? (withCurrentCamera(observedPresence) == current
        && (withCurrentCamera(state.presence) == withCurrentCamera(observedPreparation) || retiredDemand))
        : current == observedPresence else { return false }
    // Canonical removal/transfer normalizes the SQL presence. It must reach the
    // same mounted owner, not trigger an endless retry of its obsolete demand.
    // Without a mounted owner, the model can immediately accept normalization.
    let unownedRetirement = moving && retiredDemand && itemOwnerObserver == nil
    if unownedRetirement { cancelRequestedNavigation() }
    guard installSceneCut(state, preservingPresence: moving && !unownedRetirement ? current : nil,
      preparedIndex: preparedIndex, geometryCoverageOnly: moving && !unownedRetirement, itemPins: itemPins) else { return false }
    if unownedRetirement, let normalized = presence { updatePresence(normalized, settled: true) }
    // This refresh may advance content, but no content contact is admitted.
    // Publish its finite window now, never an old camera from the SQL read.
    return true
  }

  /// Full refresh and camera coverage enter the same source installer. The
  /// mode controls demand retention; header, frontier, bodies and absence
  /// witnesses always come from this exact completed WAL cut.
  @discardableResult
  private func installSceneCut(_ state: NotebookSceneState,
    as mode: NotebookScenePublication.Installation = .full,
    preservingPresence: SessionPresence? = nil, preparedIndex: WorkspaceSceneIndex? = nil,
    geometryCoverageOnly: Bool = false, itemPins: [UUID: [UUID]]? = nil) -> Bool {
    do { try admitWorkspaceIdentity(state.header.workspaceID) }
    catch { publicationFailure = error.localizedDescription; return false }
    acceptingSceneState = true
    defer { acceptingSceneState = false }
    let installed = scenePublication.install(state, as: mode) { mode in
      retainPreparedGraphicMasks(in:state)
      let retainedScopes: [CollaborationTarget: NotebookInputScope]
      switch mode {
      case .full: retainedScopes = [:]
      case .coverage(let loadsDocument, _):
        let retainedPages = Set(state.pagePositions.map(\.pageID))
        retainedScopes = peerPublication.scopes.filter { target, _ in
          (target.kind == .document && !loadsDocument && documents[target.id] != nil)
            || (target.kind == .page && state.pages[target.id] == nil && retainedPages.contains(target.id))
        }
      }
      peerPublication.scopes = Dictionary(uniqueKeysWithValues: state.inputScopes.map {
        (CollaborationTarget(kind:$0.target.kind,id:$0.target.id), $0)
      }).merging(retainedScopes) { current, _ in current }
      if committedHeader?.workspaceID != state.header.workspaceID
        || state.header.cursor >= (committedHeader?.cursor ?? 0) { committedHeader = state.header }
      for (id, cursor) in completedDeletions where state.header.cursor >= cursor {
        pendingDeletions[id] = nil
        completedDeletions[id] = nil
      }
      documentPaperSizes = state.paperSizes.merging(documentPaperSizes) { _, current in current }
      sceneCoverage = state.coverage
      truncatedSceneBoards = state.truncatedBoards
      completeSceneCoverOwners = state.completeCoverElementOwners
      missingSceneElements = state.missingPinnedElements
      workspace = state.workspace
      boardHierarchy = state.hierarchy
      spatialGroupReads = state.groupReads
      boardContentRevisions = state.boardContentRevisions
      spatialInk = state.ink
      spatialInkWindow = state.inkWindow
      spatialInkHistoryStates = state.inkHistoryStates
      switch mode {
      case .full:
        pages = state.pages
        acceptedPageSources = state.pageSources
      case .coverage:
        let retainedPages = Set(state.pagePositions.map(\.pageID))
        pages = pages.filter { retainedPages.contains($0.key) }.merging(state.pages) { _, incoming in incoming }
        acceptedPageSources = acceptedPageSources.filter { retainedPages.contains($0.key) }
          .merging(state.pageSources) { _, incoming in incoming }
      }
      for (owner, entries) in state.history { pencilUndoHistory.restore(entries, for: owner) }
      for (owner, entries) in state.redoHistory { pencilUndoHistory.restoreRedo(entries, for: owner) }
      pageAddresses = Dictionary(uniqueKeysWithValues: state.pagePositions.map {
        (PageAddress(itemID: $0.itemID, index: $0.index, root: $0.visibleRoot), $0.pageID)
      })
      switch mode {
      case .full:
        documents = state.documents
        documentStates = state.states
        documentEditingSessions = state.drafts
      case .coverage(let loadsDocument, let preservesDocumentDraft):
        if loadsDocument {
          documents = state.documents
          documentStates = state.states
          if !preservesDocumentDraft { documentEditingSessions = state.drafts }
        }
      }
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
      admitGraphicCommandSources(in: state)
      admitWorkingGraphicSources(in: state)
      #if os(iOS)
      selectedGraphicHosts.admitAcceptedAuthoredSources()
      #endif
      retireItemPlacementCommands(in: state)
      clearRemovedElementPins(in:state)
      alignWorkspaceSelection()
      if selectionSession.elements.contains(where: { reference in
        // Accepted creation owns its presentation until its addressed source
        // arrives. An earlier scene cut cannot turn that absence into a
        // deletion and silently discard a freshly completed lasso selection.
        guard !ownsUnpublishedTextDraft(reference), acceptedWorkingGraphic(reference) == nil else { return false }
        guard case .page(let pageID,let id) = reference, let page = pages[pageID] else { return false }
        return page.element(id:id) == nil
      }) { clearSelection() }
      // The observer may synchronously cancel navigation and restore its origin.
      // Deliver after installing this SQL cut, but before its prepared cohort can
      // replace the physical owner that must receive the retirement.
      if let itemPins { acceptItemOwnerInvalidations(state, requested: itemPins) }
    }
    guard installed else { return false }
    let coverageOnly = geometryCoverageOnly || mode.isCoverageOnly
    acceptingSceneState = false
    if let preparedIndex {
      scenePublication.accept(preparedIndex, hierarchy: state.hierarchy, coverageOnly: coverageOnly)
    } else { scheduleScenePreparation(coverageOnly: coverageOnly) }
    retireUnshownGraphicCommands()
    return true
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
          if committedHeader?.workspaceID == header.workspaceID,
            header.cursor >= (committedHeader?.cursor ?? 0) { committedHeader = header }
        } catch {
          publicationFailure = error.localizedDescription
        }
      }
    }
  }

  private func acceptCollaborationMetadata(actions: [NotebookActionReadModel], contexts: SharedContextDirectory,
    delivery: [DeviceActionReceipt]) {
    collaborationMetadataGeneration &+= 1
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

  @discardableResult
  private func scheduleSpatialInkSave(_ command: NotebookSpatialInkCommand,
    reservation admitted: NotebookPersistenceAdmission.Reservation? = nil,
    cost suppliedCost: NotebookPersistenceAdmission.Cost? = nil) -> Bool {
    let cost: NotebookPersistenceAdmission.Cost
    do {
      if let suppliedCost { cost = suppliedCost }
      else if case .append(let action, _) = command { cost = try NotebookInkWriteAllowance.cost(action.spans) }
      else { cost = NotebookInkWriteAllowance.stateCost(entries: 1) }
      guard let reservation = admitted ?? persistence.reserveWrite(cost) else {
        showCue("Сохранение заполнено. Повторите после восстановления записи."); return false
      }
      defer { persistence.releaseWriteReservation(reservation) }
      let expectedResult = command.expectedResult
      try persistence.enqueueReserved(owner: .spatialInk(expectedResult.actionID), reservation: reservation,
        cost: cost, onRejected: { [weak self] error in self?.showCue(error.localizedDescription) }) { store in
        try store.withNativeWriteAllowance(.init(executionBytes:cost.completionBytes)) {
          try store.commitSpatialInk(command) != expectedResult
        }
      }
      return true
    } catch { showCue(error.localizedDescription); return false }
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
    AgentWebCoordinator.retryRetirements(ownedBy: self)
    DocumentRenderRegistry.shared.retryRetiringPrograms()
    persistence.retry()
    peerPublication.retry()
    requestActionArrivalDrain()
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
      let inputFinished: Bool
      if boundary == .acceptedInput { inputFinished = await waitForNavigationInput(idle: false) }
      else { inputFinished = await inputGate.waitUntilPageInputFinishes() }
      guard inputFinished else { return false }
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
    if (boundary == .quiescent || loadState != .ready), let startupTask {
      observeNavigation("wait_startup_begin", fields: trace)
      guard case .completed = await persistence.waitForLifecycle(startupTask) else { return false }
      observeNavigation("wait_startup_end", fields: trace)
    }
    guard !Task.isCancelled, continuing() else { return false }
    if boundary == .acceptedInput {
      // Capture only the accepted input tail. These commands already reserved
      // their FIFO positions; future chat/context/service work is not input.
      let history = surfaceHistory.pending
      let commands = Array(pendingCollaborationCommands.values)
      guard await persistence.flush() else { return false }
      if let history, !(await history.value) { return false }
      for task in commands { guard await task.value else { return false } }
      guard !Task.isCancelled, continuing() else { return false }
      // A failed background read is not an unsaved accepted input. The
      // destination's own source read reports its failure at its actual owner.
      return persistence.failure == nil
    }
    #if os(iOS)
      if chatSubmissionTask != nil { observeNavigation("wait_chat_submission_begin", fields: trace) }
      await chatSubmissionTask?.value
      observeNavigation("wait_chat_submission_end", fields: trace)
    #endif
    repeat {
      guard !Task.isCancelled, continuing() else { return false }
      if let task = surfaceHistory.pending, !(await task.value) { return false }
      let commands = Array(pendingCollaborationCommands.values)
      if !commands.isEmpty {
        // Positions were reserved at acceptance. A storage failure retains the
        // commands for retry, but must release shutdown/navigation.
        guard await persistence.flush() else { return false }
        for task in commands { _ = await task.value }
      }
      if let task = contextPublicationTask {
        // The accepted context retains its result across storage failure.
        // Release this boundary's observer so Retry rejoins that publication.
        guard case .completed = await persistence.waitForLifecycle(task) else { return false }
      }
      if let task = collaborationHistoryTask {
        guard await persistence.flush() else { return false }
        _ = await task.value
      }
      guard !Task.isCancelled, continuing() else { return false }
      if boundary == .quiescent {
        if let task = arrivalDrainTask { await task.value }
        if let task = diskRefreshTask { observeNavigation("wait_disk_refresh_begin", fields: trace); await task.value; observeNavigation("wait_disk_refresh_end", fields: trace) }
        guard !Task.isCancelled, continuing() else { return false }
        if let task = sceneWindowTask { observeNavigation("wait_scene_window_begin", fields: trace); await task.value; observeNavigation("wait_scene_window_end", fields: trace) }
        guard !Task.isCancelled, continuing() else { return false }
        if let task = headerRefreshTask { observeNavigation("wait_header_refresh_begin", fields: trace); await task.value; observeNavigation("wait_header_refresh_end", fields: trace) }
        guard !Task.isCancelled, continuing() else { return false }
        if let task = documentOpening?.task { await task.value }
        guard !Task.isCancelled, continuing() else { return false }
      }
      observeNavigation("writer_flush_begin", fields: trace)
      guard await persistence.flush() else { return false }
      observeNavigation("writer_flush_end", fields: trace)
      guard !Task.isCancelled, continuing() else { return false }
    } while boundary == .quiescent && (arrivalDrainTask != nil || diskRefreshTask != nil || headerRefreshTask != nil || documentOpening?.task != nil || persistence.pendingCount > 0
      || !pendingCollaborationCommands.isEmpty || contextPublicationTask != nil || surfaceHistory.pending != nil)
    return publicationFailure == nil && arrivalFailure == nil
  }

  /// Close service admission, finish accepted input, and join every background
  /// reader before the store can be removed or its process can acknowledge quit.
  /// A failed native write remains in the same queue and returns false.
  @discardableResult
  func shutdown() async -> Bool {
    if let shutdownTask {
      guard case .completed(let saved) = await persistence.waitForLifecycle(shutdownTask) else { return false }
      return saved
    }
    if shutdownPhase == .stopped { return true }
    if shutdownPhase == .running { shutdownPhase = .closing }
    let task = Task { [self] in
      defer { shutdownTask = nil }
      commandReader.stop()
      drawingTools.cancel()
      cancelRequestedNavigation()
      cancelDocumentOpening()
      documentShellPreparation?.stop(); documentShellPreparation = nil
      presentationPlayer.interrupt("closing")
      NotebookNavigationObservation.webPreparation("shutdown_startup_join", ownerID: actorID)
      if let startupTask { await startupTask.value }
      #if os(macOS)
        if let codexStartupTask { await codexStartupTask.value }
      #endif
      NotebookNavigationObservation.webPreparation("shutdown_services_stop", ownerID: actorID)
      if !bootstrapAdmission.wasAccepted { abortBootstrapPreparations() }
      accountContentTask?.cancel()
      await accountContentTask?.value
      accountContentTask = nil
      await accountConnection?.stop()
      await cloudSync?.stop()
      if let sync, !(await sync.stopAndDrainTrust()) { return false }
      #if os(macOS)
        // The stopped transport retains persisted trust until the host joins
        // accepted Codex work. Closing admission does not revoke its authors.
        await previewPublisher?.stop()
        await commandServer?.stopAndDrain(); commandServer = nil
        codexSidecar?.detachView(); codexSidecar = nil
        await scriptCoordinator?.shutdown(); scriptCoordinator = nil
        let agentStopped = true
      #else
        sync = nil
        await chatSubmissionTask?.value
        await chat?.stop()
        let agentStopped = true
      #endif
      #if os(macOS)
        programImporter?.stop()
      #endif
      NotebookNavigationObservation.webPreparation("shutdown_programs_checkpoint", ownerID: actorID)
      let programsSaved = await checkpointPrograms(resume: false)
      NotebookNavigationObservation.webPreparation("shutdown_input_finish", ownerID: actorID)
      let inputSaved = await finishPendingInteraction()
      NotebookNavigationObservation.webPreparation("shutdown_saved_boundary", ownerID: actorID)
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
      peerPublication.stop()
      inputGate.onActivityChange = nil
      inputGate.onNewAcceptedContact = nil
      itemOwnerObserver = nil
      let readers = [scenePublication.cancel(), sceneWindowTask, diskRefreshTask, arrivalDrainTask, headerRefreshTask, documentOpening?.task]
        .compactMap { $0 } + notebookPagePreparation.stop()
      for task in readers { task.cancel() }
      for task in readers { await task.value }
      sceneWindowTask = nil; diskRefreshTask = nil; arrivalDrainTask = nil; headerRefreshTask = nil
      documentOpening = nil
      collaborationReadTask?.cancel()
      if let task = collaborationReadTask { _ = await task.result }
      collaborationReadTask = nil
      agentFeedback.stop()
      referenceHighlightTask?.cancel(); cueTask?.cancel()
      if let task = collaborationHistoryTask { _ = await task.value }
      await elementErasureCache.stop()
      await compositionTiles.stop()
      await sceneReader.close()
      await backgroundSceneReader.close()
      await commandReader.close()
      await transportReader?.close()
      transportReader = nil
      let saved = await persistence.flush()
      if saved {
        shutdownPhase = .stopped
        // A hidden UIHostingController may not evaluate its observed body again.
        // Deliver the terminal boundary directly, without a display/layout tick.
        let owners = scenePresentationOwners.values.compactMap(\.value)
        scenePresentationOwners.removeAll()
        for owner in owners { owner.uninstall() }
        #if os(iOS)
          await inputFrameMonitor?.finish()
        #endif
      }
      return saved
    }
    shutdownTask = task
    guard case .completed(let saved) = await persistence.waitForLifecycle(task) else { return false }
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

  func constrainedPaperPresence(_ presence: SessionPresence) -> SessionPresence {
    #if os(iOS)
    guard (presence.mode == .page || presence.mode == .document), presence.openProgress == 1,
      let id = presence.focusedItemID,
      let center = boardHierarchy?.board(presence.boardID)?.focusedCenter(of: id) else { return presence }
    let geometry = presence.mode == .document ? documentGeometry(id, page: presence.documentPageIndex) : itemGeometry(id)
    let camera = presence.mode == .page
      ? SpatialCamera(center: center, scale: geometry.fitScale(viewport: presence.viewport))
      : geometry.readingCamera(presence.camera, centeredOn: center, viewport: presence.viewport)
    return presence.replacingCamera(camera)
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

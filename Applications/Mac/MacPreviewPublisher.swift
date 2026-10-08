import Combine
import Foundation
import NotebookCore
import NotebookTypesetter
import Observation

/// Pixel dependencies, separate from the workspace cursor used to discover changes.
/// Header/reference reads never decode an unrelated page or its ink bodies.
enum PreviewSourceIdentity: Equatable, Sendable {
  case content(NotebookContentHeader)
  case scene([NotebookReferenceIdentity])

  static func read(_ store: NotebookStore, presence: SessionPresence) throws -> Self {
    try store.readTransaction { store in
      switch presence.mode {
      case .page:
        guard let id = presence.notebookPageID, try store.ownerItemID(ofPage: id) == presence.focusedItemID else {
          throw NotebookStorageError.transactionConflict
        }
        return .content(try store.readContentHeader(target: .init(kind: .page, id: id)))
      case .document:
        guard let id = presence.focusedItemID else { throw NotebookStorageError.transactionConflict }
        return .content(try store.readContentHeader(target: .init(kind: .document, id: id)))
      case .board:
        return .scene(try store.referenceIdentities(targets: [.init(kind: .board, id: presence.boardID)]))
      case .cover:
        guard let id = presence.focusedItemID else { throw NotebookStorageError.transactionConflict }
        return .scene(try store.referenceIdentities(targets: [.init(kind: .cover, id: id, boardID: presence.boardID)]))
      }
    }
  }
}

extension SessionPresence {
  /// Exactly the presentation fields read by the current-view raster paths.
  /// Selection is receipt metadata; page/document rasters are fitted in full,
  /// while board/cover pixels also depend on their camera and portal opening.
  var previewPixelIdentity: SessionPresence {
    let scene = mode == .board || mode == .cover
    return .init(boardID: boardID, mode: mode, camera: scene ? camera : .init(), viewport: viewport,
      focusedItemID: focusedItemID, openProgress: scene ? openProgress : 0,
      documentPageIndex: mode == .document ? documentPageIndex : 0,
      notebookPageID: mode == .page ? notebookPageID : nil)
  }
}

private struct PreviewPageKey: Equatable, Sendable {
  let pageID: UUID
  let inkStamp: VersionStamp
  let size: PageSize?
}

private struct PreviewCurrentViewKey: Equatable, Sendable {
  let workspaceID: UUID
  let source: PreviewSourceIdentity
  let presence: SessionPresence
  let presencePhase: PresencePhase
  let documentSnapshotGeneration: Int

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.workspaceID == rhs.workspaceID && lhs.source == rhs.source
      && lhs.presence.previewPixelIdentity == rhs.presence.previewPixelIdentity
      && lhs.presencePhase == rhs.presencePhase
      && lhs.documentSnapshotGeneration == rhs.documentSnapshotGeneration
  }
}

private struct PreviewReadDemand: Equatable, Sendable {
  let workspaceID: UUID
  let cursor: UInt64
  let presence: SessionPresence
  let phase: PresencePhase
  let documentSnapshotGeneration: Int
}

private struct PreviewPublicationSlot<Key: Equatable> {
  private(set) var desired: Key?
  private(set) var published: Key?
  private(set) var pending: Key?
  private(set) var generation: UInt64 = 0
  private(set) var lastError: String?

  mutating func request(_ key: Key) -> Bool {
    desired = key
    return key != published && key != pending
  }

  mutating func begin(_ key: Key) -> UInt64 {
    desired = key
    pending = key
    generation &+= 1
    return generation
  }

  mutating func finish(_ key: Key, generation: UInt64, error: (any Error)?) {
    guard pending == key, self.generation == generation else { return }
    if let error {
      lastError = String(describing: error)
    } else {
      published = key
      lastError = nil
    }
    pending = nil
  }
}

private enum PreviewPublicationError {
  static let sourceUnavailable = CollaborationError("snapshot_changed", "Источник изображения больше недоступен.")
  static let sourceChanged = CollaborationError("snapshot_changed", "Источник изображения изменился во время подготовки.")
}

/// The process owns publication independently from the working
/// window. Stopping it drains every accepted preparation before storage closes.
@MainActor
final class MacPreviewPublisher {
  #if DEBUG
    /// Configure the real AppModel-started owner for one isolated acceptance
    /// store. Other workspaces keep the production delays and read lifetime.
    struct AcceptanceConfiguration {
      let storeRoot: URL
      let currentViewDelay: Duration
      let reconciliationInterval: Duration
      let sourceReader: NotebookSceneReader
    }
    static var acceptanceConfiguration: AcceptanceConfiguration?
  #endif
  private weak var model: NotebookAppModel?
  private let sourceReader: NotebookSceneReader
  private let currentViewDelay: Duration
  private let reconciliationInterval: Duration
  private var currentViewTask: Task<Void, Never>?
  private var pageRequestTask: Task<Void, Never>?
  private var pageRequestPublication: NotebookPreviewPublication<PreviewPageKey>?
  private var sourceReadTask: Task<Void, Never>?
  private var lastReadDemand: PreviewReadDemand?
  private var receiptRefresh: (demand: PreviewReadDemand, permit: NotebookPreviewPublication<CurrentViewPublicationFiles?>)?
  private var sourceKey: PreviewCurrentViewKey?
  private var sourcePageKey: PreviewPageKey?
  private var renderedScene: (key: PreviewCurrentViewKey, dependencies: ScenePixelDependencies)?
  private var healthWriteTask: Task<Void, Never>?
  private var requestedPageKey: PreviewPageKey?
  private var reconciliationTask: Task<Void, Never>?
  private var documentSnapshotObserver: AnyCancellable?
  private var agentSnapshotObserver: AnyCancellable?
  private var documentSnapshotGeneration = 0
  private var currentView = PreviewPublicationSlot<PreviewCurrentViewKey>()
  private var started = false
  private var stopped = false
  private var stoppingTask: Task<Void, Never>?
  private var targetTask: Task<Void, Never>?

  init(
    model: NotebookAppModel,
    currentViewDelay: Duration = .milliseconds(220),
    reconciliationInterval: Duration = .seconds(1)
  ) {
    self.model = model
    #if DEBUG
      if let configuration = Self.acceptanceConfiguration, configuration.storeRoot == model.store.root {
        sourceReader = configuration.sourceReader
        self.currentViewDelay = configuration.currentViewDelay
        self.reconciliationInterval = configuration.reconciliationInterval
        return
      }
    #endif
    sourceReader = NotebookSceneReader(store: model.store)
    self.currentViewDelay = currentViewDelay
    self.reconciliationInterval = reconciliationInterval
  }

  deinit {
    currentViewTask?.cancel()
    pageRequestTask?.cancel()
    reconciliationTask?.cancel()
    targetTask?.cancel(); sourceReadTask?.cancel(); healthWriteTask?.cancel()
  }

  func start() {
    guard !started, !stopped else { return }
    started = true
    documentSnapshotObserver = NotificationCenter.default.publisher(
      for: DocumentSnapshotCache.didChange
    ).sink { [weak self] notification in
      let documentID = notification.object as? UUID
      Task { @MainActor [weak self] in
        guard let self, started, let documentID,
          model?.observedPresence?.mode == .document,
          model?.observedPresence?.focusedItemID == documentID else { return }
        documentSnapshotGeneration &+= 1
        requestSourceIdentity()
      }
    }
    agentSnapshotObserver = NotificationCenter.default.publisher(
      for: SceneRenderResources.didChange
    ).sink { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, started else { return }
        scheduleCurrentView(for: makeCurrentViewKey())
      }
    }
    observeOptionalPreparation()
    observeCurrentView()
    let reconciliationInterval = reconciliationInterval
    reconciliationTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: reconciliationInterval)
        guard !Task.isCancelled else { return }
        if let self { reconcilePublication() }
      }
    }
  }

  /// A publisher is single-use. The admission fence precedes the first await;
  /// late Observation and snapshot notifications cannot restart a stopped owner.
  func stop() async {
    if let stoppingTask { await stoppingTask.value; return }
    guard !stopped else { return }
    stopped = true
    started = false
    documentSnapshotObserver?.cancel(); documentSnapshotObserver = nil
    agentSnapshotObserver?.cancel(); agentSnapshotObserver = nil
    let tasks = [currentViewTask, pageRequestTask, reconciliationTask, targetTask, sourceReadTask, healthWriteTask].compactMap { $0 }
    for task in tasks { task.cancel() }
    let sourceReader = sourceReader
    let drain = Task { @MainActor [weak self] in
      for task in tasks { await task.value }
      await sourceReader.close()
      guard let self else { return }
      currentViewTask = nil; pageRequestTask = nil; reconciliationTask = nil
      targetTask = nil; sourceReadTask = nil; healthWriteTask = nil
      requestedPageKey = nil; renderedScene = nil
      pageRequestPublication = nil
      currentView = .init()
      stoppingTask = nil
    }
    stoppingTask = drain
    await drain.value
  }

  func suspendForInput() {
    suspendOptionalPreparation()
    targetTask?.cancel()
  }

  /// Pressure revokes automatic preparation. Durable targets and publications
  /// already admitted by the writer retain their bytes through the same FIFO.
  private func suspendOptionalPreparation() {
    receiptRefresh?.permit.revoke()
    pageRequestPublication?.revoke()
    currentViewTask?.cancel()
    pageRequestTask?.cancel()
    sourceReadTask?.cancel()
  }

  private func permitsOptionalPreparation(_ generation: UInt64) -> Bool {
    model?.permitsOptionalPreparation == true
      && SceneRenderResources.shared.optionalPreparationGeneration == generation
  }

  private func resumeOptionalPreparation() {
    guard started, model?.permitsOptionalPreparation == true else { return }
    requestSourceIdentity()
    scheduleCurrentView(for: makeCurrentViewKey())
    schedulePagePreview(for: pageKey)
  }

  /// Observation gives immediate updates. This small process-level pass gives
  /// the durable readout the same eventual guarantee as the files it mirrors:
  /// if a burst coalesces observation callbacks, the final versions still get
  /// published without reopening the app.
  private func reconcilePublication() {
    guard started else { return }
    requestSourceIdentity()
    scheduleCurrentView(for: makeCurrentViewKey())
    schedulePagePreview(for: pageKey)
    guard let model else { return }
    if healthWriteTask == nil {
      let health = NotebookRuntimeStatus(status: model.isPeerConnected ? "connected" : "disconnected")
      let url = model.store.root.appendingPathComponent("previews/runtime.json")
      healthWriteTask = Task { [weak self] in
        let writer = Task.detached(priority: .utility) {
          try Task.checkCancellation()
          try JSONEncoder().encode(health).write(to: url, options: .atomic)
        }
        _ = await withTaskCancellationHandler { try? await writer.value } onCancel: { writer.cancel() }
        self?.healthWriteTask = nil
      }
    }
    if !model.permitsBackgroundPreparation { suspendForInput() }
    scheduleTargetRender(model)
  }

  private func scheduleTargetRender(_ model: NotebookAppModel) {
    guard started, !stopped, targetTask == nil,
      model.permitsBackgroundPreparation else { return }
    let selectedPage = pageKey?.pageID
    targetTask = Task { [weak self, weak model] in
      defer { self?.targetTask = nil }
      guard self?.started == true, !Task.isCancelled, let model else { return }
      do {
        try Task.checkCancellation()
        guard model.permitsBackgroundPreparation else { return }
        let request = try await model.performStoreCommand { store in
          try store.targetRenderRequests().sorted { left, right in
            let leftCurrent = left.pageVisionRevision != nil && left.target.id == selectedPage
            let rightCurrent = right.pageVisionRevision != nil && right.target.id == selectedPage
            return leftCurrent == rightCurrent ? left.createdAt < right.createdAt : leftCurrent
          }.first { !FileManager.default.fileExists(atPath: store.targetReceiptURL($0.id).path) }
        }
        guard self?.started == true, !Task.isCancelled else { return }
        guard model.permitsBackgroundPreparation, let request else { return }
        do {
          if !FileManager.default.fileExists(atPath: model.store.targetReceiptURL(request.id).path) {
            try await CurrentViewPreviewWriter.writeTarget(request, model: model)
          }
        } catch is CancellationError {
          // A cancelled producer has no terminal result. The durable request
          // remains owned by this publisher's queue and can resume on admission.
          // Historical ready/error receipts are never rewritten here.
          return
        } catch {
          guard self?.started == true, !Task.isCancelled, model.permitsBackgroundPreparation else { return }
          let rendering = error as? DocumentRenderingFailure
          let diagnostics = rendering?.diagnostics ?? (error as? NotebookTypesetterError)?.diagnostics.map {
            RenderDiagnostic(kind: $0.severity, fileID: $0.fileID, path: $0.path, line: $0.line, message: $0.message)
          } ?? [.init(kind: "render_error", message: String(describing: error))]
          let receipt = TargetRenderReceipt(request: request, status: "error", buildID: rendering?.buildID, diagnostics: diagnostics,
            programs: request.target.kind == .document ? rendering?.programs ?? [] : nil)
          try await model.performStoreCommand { try $0.saveTargetRender(receipt) }
        }
      } catch is CancellationError {
        return
      } catch {
        // Durable requests remain owned by reconciliation after a failed read.
      }
    }
  }

  private var readDemand: PreviewReadDemand? {
    guard let model, let header = model.workspaceHeader, let presence = model.observedPresence else { return nil }
    return .init(workspaceID: header.workspaceID, cursor: header.cursor, presence: presence,
      phase: model.observedPresencePhase, documentSnapshotGeneration: documentSnapshotGeneration)
  }

  private func observeCurrentView() {
    guard started else { return }
    _ = withObservationTracking {
      (readDemand, model?.permitsOptionalPreparation)
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in self?.observeCurrentView() }
    }
    if model?.permitsOptionalPreparation != true { suspendOptionalPreparation() }
    resumeOptionalPreparation()
  }

  private func observeOptionalPreparation() {
    guard started else { return }
    _ = withObservationTracking {
      SceneRenderResources.shared.optionalPreparationGeneration
    } onChange: { [weak self] in
      // The pool changes this generation on MainActor. Revoke queued permits
      // in that same pressure turn; a deferred callback could lose the writer
      // admission race. Rearm and retry after the new value has been installed.
      MainActor.assumeIsolated { self?.suspendOptionalPreparation() }
      Task { @MainActor [weak self] in
        guard let self, started else { return }
        observeOptionalPreparation()
        resumeOptionalPreparation()
      }
    }
  }

  private func samePresentation(_ key: PreviewCurrentViewKey, _ demand: PreviewReadDemand) -> Bool {
    key.workspaceID == demand.workspaceID && key.presence.previewPixelIdentity == demand.presence.previewPixelIdentity
      && key.presencePhase == demand.phase && key.documentSnapshotGeneration == demand.documentSnapshotGeneration
  }

  private func requestSourceIdentity() {
    // Revoke queued derived output before waiting for any source read. The
    // accepted shared writer itself is never cancelled by presentation changes.
    let demand = readDemand
    if let pending = currentView.pending,
      demand.map({ samePresentation(pending, $0) }) != true { currentViewTask?.cancel() }
    if let refresh = receiptRefresh, refresh.demand != demand { refresh.permit.revoke() }
    guard started, let model, model.permitsOptionalPreparation, sourceReadTask == nil,
      readDemand != lastReadDemand else { return }
    // The renderer validates its own dependencies during preparation. Discover
    // unrelated cursor changes after it finishes, not by cancelling that work.
    if let pending = currentView.pending, let demand = readDemand, samePresentation(pending, demand) { return }
    let reader = sourceReader
    let optionalGeneration = SceneRenderResources.shared.optionalPreparationGeneration
    sourceReadTask = Task { [weak self] in
      guard let self else { return }
      defer {
        sourceReadTask = nil
        if Task.isCancelled || !permitsOptionalPreparation(optionalGeneration) {
          resumeOptionalPreparation()
        }
      }
      while started, !Task.isCancelled, permitsOptionalPreparation(optionalGeneration),
        let demand = readDemand, demand != lastReadDemand {
        if let pending = currentView.pending, samePresentation(pending, demand) { break }
        let previous = renderedScene.flatMap { samePresentation($0.key, demand) ? $0 : nil }
        let read = Task.detached(priority: .utility) {
          try await reader.read { store -> (PreviewSourceIdentity, NotebookContentHeader?) in
            guard try store.workspaceHeader().workspaceID == demand.workspaceID else { throw NotebookStorageError.transactionConflict }
            let source: PreviewSourceIdentity
            if let previous, try previous.dependencies.isCurrent(store) { source = previous.key.source }
            else { source = try PreviewSourceIdentity.read(store, presence: demand.presence) }
            let page = try demand.presence.notebookPageID.map { try store.readContentHeader(target: .init(kind: .page, id: $0)) }
            return (source, page)
          }
        }
        do {
          let (identity, page) = try await withTaskCancellationHandler { try await read.value } onCancel: { read.cancel() }
          guard started, !Task.isCancelled, permitsOptionalPreparation(optionalGeneration) else { return }
          lastReadDemand = demand
          guard readDemand?.workspaceID == demand.workspaceID, readDemand?.presence == demand.presence else { continue }
          sourceKey = .init(workspaceID: demand.workspaceID, source: identity, presence: demand.presence,
            presencePhase: demand.phase, documentSnapshotGeneration: demand.documentSnapshotGeneration)
          sourcePageKey = page.flatMap { header in header.inkStamp.map { .init(pageID: header.target.id, inkStamp: $0, size: header.size) } }
          if let key = makeCurrentViewKey(), currentView.published == key {
            let dependencies = renderedScene.flatMap { $0.key == key ? $0.dependencies : nil }
            let permit = NotebookPreviewPublication<CurrentViewPublicationFiles?>()
            receiptRefresh = (demand, permit)
            defer { if receiptRefresh?.permit === permit { receiptRefresh = nil } }
            try await withTaskCancellationHandler {
              try await model.performStoreCommand { store in
                try CurrentViewPreviewWriter.refreshReceipt(store: store, presence: demand.presence,
                  identity: key.source, dependencies: dependencies, permit: permit)
              }
            } onCancel: { permit.revoke() }
          }
          scheduleCurrentView(for: makeCurrentViewKey()); schedulePagePreview(for: pageKey)
        } catch {
          if lastReadDemand == demand { lastReadDemand = nil }
          return
        }
      }
    }
  }

  private var pageKey: PreviewPageKey? {
    guard sourcePageKey?.pageID == model?.observedPresence?.notebookPageID else { return nil }
    return sourcePageKey
  }

  private func makeCurrentViewKey() -> PreviewCurrentViewKey? {
    guard let sourceKey, let demand = readDemand, demand.workspaceID == sourceKey.workspaceID,
      demand.presence.previewPixelIdentity == sourceKey.presence.previewPixelIdentity, demand.phase == sourceKey.presencePhase,
      demand.documentSnapshotGeneration == sourceKey.documentSnapshotGeneration else { return nil }
    return sourceKey
  }

  private func scheduleCurrentView(for key: PreviewCurrentViewKey?) {
    guard started else { return }
    guard let key, key.presencePhase == .settled, model?.permitsOptionalPreparation == true else { currentViewTask?.cancel(); return }
    guard currentView.request(key) else { return }
    // Keep the cancelled task owned until it has drained. Replacing its handle
    // would let shutdown acknowledge while an older renderer still uses SQL.
    if let currentViewTask { currentViewTask.cancel(); return }
    let generation = currentView.begin(key)
    let optionalGeneration = SceneRenderResources.shared.optionalPreparationGeneration
    let reader = sourceReader
    currentViewTask = Task { [weak self] in
      try? await Task.sleep(for: self?.currentViewDelay ?? .zero)
      guard let self else { return }
      guard started, !Task.isCancelled,
        permitsOptionalPreparation(optionalGeneration),
        makeCurrentViewKey() == key
      else {
        finishCurrentViewPublication(key, generation: generation, error: PreviewPublicationError.sourceChanged)
        return
      }
      do {
        guard let model else { throw PreviewPublicationError.sourceUnavailable }
        // The peer's page may be outside the Mac window's bounded scene cache.
        // Join the accepted prefix, then use this publisher's cancellable WAL
        // reader. Optional decoding must not become an accepted writer task.
        guard let presence = model.observedPresence else { throw PreviewPublicationError.sourceUnavailable }
        let fence = model.capturePreviewReadFence()
        try await fence.wait()
        guard started, !Task.isCancelled, permitsOptionalPreparation(optionalGeneration), makeCurrentViewKey() == key else {
          throw PreviewPublicationError.sourceChanged
        }
        let content = try await reader.read { store -> (PageDocument?, DocumentDocument?, DocumentStateJournal?) in
          guard try store.storedWorkspaceID() == key.workspaceID else { throw PreviewPublicationError.sourceChanged }
          let page = try presence.mode == .page ? presence.notebookPageID.map { try store.loadPage($0) } : nil
          let document = try presence.mode == .document ? presence.focusedItemID.map { try store.loadDocument($0) } : nil
          let state = try document.map { try store.loadDocumentState($0.id) }
          return (page, document, state)
        }
        guard started, !Task.isCancelled, permitsOptionalPreparation(optionalGeneration), makeCurrentViewKey() == key else {
          throw PreviewPublicationError.sourceChanged
        }
        var documentRaster: RasterLease?
        defer { documentRaster?.release() }
        if let document = content.1, let state = content.2 {
          documentRaster = try await DocumentSnapshotCache.shared.prepare(document: document, state: state,
            pageIndex: presence.documentPageIndex, programStore: model.store, purpose: { .optional })
        }
        guard started, !Task.isCancelled, permitsOptionalPreparation(optionalGeneration), makeCurrentViewKey() == key else {
          throw PreviewPublicationError.sourceChanged
        }
        let dependencies = try await CurrentViewPreviewWriter.write(model: model,
          viewport: .init(width: presence.viewport.x, height: presence.viewport.y), presence: presence,
          page: content.0, document: content.1, documentState: content.2, documentRaster: documentRaster, sourceIdentity: key.source,
          pngURL: model.store.currentViewPreviewURL, receiptURL: model.store.currentViewRevisionURL)
        renderedScene = dependencies.map { (key, $0) }
        finishCurrentViewPublication(key, generation: generation, error: nil)
      } catch {
        finishCurrentViewPublication(key, generation: generation, error: error)
      }
    }
  }

  private func finishCurrentViewPublication(
    _ key: PreviewCurrentViewKey,
    generation: UInt64,
    error: (any Error)?
  ) {
    guard currentView.pending == key,
      currentView.generation == generation else { return }
    let wasSuperseded = currentView.desired != key
    currentView.finish(key, generation: generation, error: error)
    currentViewTask = nil
    if started { requestSourceIdentity() }
    if started, wasSuperseded || Task.isCancelled { scheduleCurrentView(for: makeCurrentViewKey()) }
  }

  /// Only the selected physical page is requested automatically. Explicit
  /// agent requests and this request share one queue and one render executor.
  private func schedulePagePreview(for key: PreviewPageKey?) {
    guard started, let key, requestedPageKey != key, pageRequestTask == nil, let model,
      model.permitsOptionalPreparation else { return }
    let optionalGeneration = SceneRenderResources.shared.optionalPreparationGeneration
    let publication = NotebookPreviewPublication<PreviewPageKey>()
    pageRequestPublication = publication
    pageRequestTask = Task { [weak self, weak model] in
      defer {
        self?.pageRequestTask = nil
        if self?.pageRequestPublication === publication { self?.pageRequestPublication = nil }
        if Task.isCancelled || self?.permitsOptionalPreparation(optionalGeneration) != true {
          self?.resumeOptionalPreparation()
        }
      }
      guard let self, started, !Task.isCancelled, let model,
        permitsOptionalPreparation(optionalGeneration) else { return }
      do {
        try await withTaskCancellationHandler {
          try await model.performStoreCommand { store in
            try publication.publish(preparing: {
              guard try store.readContentHeader(target: .init(kind: .page, id: key.pageID)).inkStamp == key.inkStamp else {
                throw PreviewPublicationError.sourceUnavailable
              }
              return key
            }, writing: { admitted in
              _ = try store.requestPageVision(pageID: admitted.pageID, expectedRevision: admitted.inkStamp.revision)
            })
          }
        } onCancel: { publication.revoke() }
        // Persistence makes this request required even if pressure cancelled
        // its automatic producer while the accepted writer was finishing.
        guard started else { return }
        if pageKey == key { requestedPageKey = key }
        scheduleTargetRender(model)
      } catch { }
    }
  }

}

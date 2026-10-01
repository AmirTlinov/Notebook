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

private struct PreviewPageKey: Equatable {
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

private enum PreviewPublicationError: Error {
  case sourceUnavailable
  case sourceChanged
}

/// The process owns publication independently from the working
/// window. Stopping it drains every accepted preparation before storage closes.
@MainActor
final class MacPreviewPublisher {
  private weak var model: NotebookAppModel?
  private let currentViewDelay: Duration
  private let reconciliationInterval: Duration
  private var currentViewTask: Task<Void, Never>?
  private var pageRequestTask: Task<Void, Never>?
  private var sourceReadTask: Task<Void, Never>?
  private var lastReadDemand: PreviewReadDemand?
  private var receiptRefresh: (demand: PreviewReadDemand, permit: CurrentViewPublicationPermit)?
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
  private var targetInProgress: UUID?
  private struct PanelWaiter {
    let cut: NotebookPanelPresentationCut
    let knownAssets: Set<UUID>
    let enqueuedAt: ContinuousClock.Instant
    let continuation: CheckedContinuation<JSONValue, any Error>
  }
  private var panelWaiters: [UUID: PanelWaiter] = [:]
  private struct PanelValidation {
    let id: UUID
    let cursor: String
    let rasterGeneration: UInt64
  }
  private var panelValidations: [PanelValidation] = []
  private var targetQueuePrepared = false
  private var lastTargetWasPanel = false

  init(
    model: NotebookAppModel,
    currentViewDelay: Duration = .milliseconds(220),
    reconciliationInterval: Duration = .seconds(1)
  ) {
    self.model = model
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
    let waiters = panelWaiters.values; panelWaiters.removeAll()
    panelValidations.removeAll()
    for waiter in waiters { waiter.continuation.resume(throwing: CancellationError()) }
    documentSnapshotObserver?.cancel(); documentSnapshotObserver = nil
    agentSnapshotObserver?.cancel(); agentSnapshotObserver = nil
    let tasks = [currentViewTask, pageRequestTask, reconciliationTask, targetTask, sourceReadTask, healthWriteTask].compactMap { $0 }
    for task in tasks { task.cancel() }
    let drain = Task { @MainActor [weak self] in
      for task in tasks { await task.value }
      guard let self else { return }
      currentViewTask = nil; pageRequestTask = nil; reconciliationTask = nil
      targetTask = nil; sourceReadTask = nil; healthWriteTask = nil
      targetInProgress = nil; requestedPageKey = nil; renderedScene = nil
      currentView = .init()
      stoppingTask = nil
    }
    stoppingTask = drain
    await drain.value
  }

  /// A panel joins the existing pixel scheduler with an ephemeral source cut.
  /// Camera movement does not enqueue durable artifacts or author store state.
  func panelPresentation(_ request: NotebookPanelPresentationRequest) async throws -> JSONValue {
    guard started, !stopped, let model, model.permitsBackgroundPreparation else {
      throw CollaborationError("snapshot_pending", "Представление Notebook ждёт завершения ввода.")
    }
    try await prepareTargetQueue(model)
    let cut = try await model.performStoreCommand { try $0.requestPanelPresentation(request) }
    try Task.checkCancellation()
    guard started, !stopped, model.permitsBackgroundPreparation else { throw CancellationError() }
    if request.knownRequestID == cut.id, request.knownCursor == String(cut.cursor),
      panelValidations.contains(where: { $0.id == cut.id && $0.cursor == String(cut.cursor)
        && $0.rasterGeneration == SceneRenderResources.shared.rasterGeneration }) {
      return .object(["workspaceID": try .encode(cut.projection.workspaceID), "target": try .encode(cut.target),
        "cursor": .string(String(cut.cursor)), "unchanged": .bool(true)])
    }
    let waiterID = UUID()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        guard started, !stopped, model.permitsBackgroundPreparation else { continuation.resume(throwing: CancellationError()); return }
        panelWaiters[waiterID] = .init(cut: cut, knownAssets: Set(request.knownAssets ?? []),
          enqueuedAt: ContinuousClock.now, continuation: continuation)
        scheduleTargetRender(model)
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        guard let self, let removed = panelWaiters.removeValue(forKey: waiterID) else { return }
        removed.continuation.resume(throwing: CancellationError())
        if targetInProgress == removed.cut.id && !panelWaiters.values.contains(where: { $0.cut.id == removed.cut.id }) {
          targetTask?.cancel()
        }
      }
    }
  }

  private func completePanel(_ waiter: PanelWaiter, model: NotebookAppModel) async {
    let result: Result<JSONValue, any Error>
    let generation = SceneRenderResources.shared.rasterGeneration
    do {
      let snapshot = try await CurrentViewPreviewWriter.panelMaterial(waiter.cut, model: model,
        knownAssets: waiter.knownAssets)
      try Task.checkCancellation()
      guard started, !stopped, model.permitsBackgroundPreparation else { throw CancellationError() }
      // A warmed render can establish the idle shortcut only if no native pixels
      // changed across its whole preparation. First-time captures simply skip it.
      if generation == SceneRenderResources.shared.rasterGeneration {
        panelValidations.removeAll { $0.id == waiter.cut.id }
        panelValidations.append(.init(id: waiter.cut.id, cursor: String(waiter.cut.cursor), rasterGeneration: generation))
        if panelValidations.count > 16 { panelValidations.removeFirst(panelValidations.count - 16) }
      }
      result = .success(snapshot)
    } catch { result = .failure(error) }
    // Readers with identical asset possession may join even while this job is
    // painting. Other readers keep their own missing-byte contract in the queue.
    let ids = panelWaiters.filter { $0.value.cut.id == waiter.cut.id && $0.value.cut.cursor == waiter.cut.cursor
      && $0.value.knownAssets == waiter.knownAssets }.map(\.key)
    for id in ids { panelWaiters.removeValue(forKey: id)?.continuation.resume(with: result) }
  }

  private func prepareTargetQueue(_ model: NotebookAppModel) async throws {
    guard !targetQueuePrepared else { return }
    try await model.performStoreCommand { _ = try $0.retireObsoletePanelRenderRequests() }
    targetQueuePrepared = true
  }

  func suspendForInput() {
    receiptRefresh?.permit.revoke()
    currentViewTask?.cancel()
    pageRequestTask?.cancel()
    targetTask?.cancel()
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
    guard model.permitsBackgroundPreparation else { targetTask?.cancel(); return }
    scheduleTargetRender(model)
  }

  private func scheduleTargetRender(_ model: NotebookAppModel) {
    guard started, model.permitsBackgroundPreparation, targetTask == nil else { return }
    let selectedPage = pageKey?.pageID
    targetTask = Task { [weak self, weak model] in
      defer {
        self?.targetInProgress = nil; self?.targetTask = nil
        if model?.permitsBackgroundPreparation != true {
          let waiters = self?.panelWaiters.values.map { $0 } ?? []
          self?.panelWaiters.removeAll()
          for waiter in waiters { waiter.continuation.resume(throwing: CancellationError()) }
        }
        if let self, let model, !panelWaiters.isEmpty { scheduleTargetRender(model) }
      }
      guard self?.started == true, !Task.isCancelled, let model else { return }
      do {
        try await self?.prepareTargetQueue(model)
        try Task.checkCancellation()
        if let self, !lastTargetWasPanel, let waiter = panelWaiters.values.min(by: { $0.enqueuedAt < $1.enqueuedAt }) {
          targetInProgress = waiter.cut.id
          lastTargetWasPanel = true
          await completePanel(waiter, model: model)
          return
        }
        let request = try await model.performStoreCommand { store in
          try store.targetRenderRequests().sorted { left, right in
            let leftCurrent = left.pageVisionRevision != nil && left.target.id == selectedPage
            let rightCurrent = right.pageVisionRevision != nil && right.target.id == selectedPage
            return leftCurrent == rightCurrent ? left.createdAt < right.createdAt : leftCurrent
          }.first { !FileManager.default.fileExists(atPath: store.targetReceiptURL($0.id).path) }
        }
        guard self?.started == true, !Task.isCancelled, model.permitsBackgroundPreparation else { return }
        guard let request else {
          if let self, let waiter = panelWaiters.values.min(by: { $0.enqueuedAt < $1.enqueuedAt }) {
            targetInProgress = waiter.cut.id
            lastTargetWasPanel = true
            await completePanel(waiter, model: model)
          }
          return
        }
        // Continuous human camera motion shares the pixel worker fairly with
        // the agent's already-admitted durable captures.
        self?.lastTargetWasPanel = false
        self?.targetInProgress = request.id
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
      } catch {
        let waiters = self?.panelWaiters.values.map { $0 } ?? []
        self?.panelWaiters.removeAll()
        for waiter in waiters { waiter.continuation.resume(throwing: error) }
        // Durable requests still belong to the existing publisher observation.
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
    _ = withObservationTracking { readDemand } onChange: { [weak self] in
      Task { @MainActor [weak self] in self?.observeCurrentView() }
    }
    requestSourceIdentity()
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
    guard started, let model, model.permitsBackgroundPreparation, sourceReadTask == nil,
      readDemand != lastReadDemand else { return }
    // The renderer validates its own dependencies during preparation. Discover
    // unrelated cursor changes after it finishes, not by cancelling that work.
    if let pending = currentView.pending, let demand = readDemand, samePresentation(pending, demand) { return }
    let reader = NotebookSceneReader(store: model.store)
    sourceReadTask = Task { [weak self] in
      guard let self else { return }
      defer { sourceReadTask = nil }
      while started, !Task.isCancelled, let demand = readDemand, demand != lastReadDemand {
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
          guard started, !Task.isCancelled, model.permitsBackgroundPreparation else { return }
          lastReadDemand = demand
          guard readDemand?.workspaceID == demand.workspaceID, readDemand?.presence == demand.presence else { continue }
          sourceKey = .init(workspaceID: demand.workspaceID, source: identity, presence: demand.presence,
            presencePhase: demand.phase, documentSnapshotGeneration: demand.documentSnapshotGeneration)
          sourcePageKey = page.flatMap { header in header.inkStamp.map { .init(pageID: header.target.id, inkStamp: $0, size: header.size) } }
          if let key = makeCurrentViewKey(), currentView.published == key {
            let dependencies = renderedScene.flatMap { $0.key == key ? $0.dependencies : nil }
            let permit = CurrentViewPublicationPermit()
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
    guard let key, key.presencePhase == .settled, model?.permitsBackgroundPreparation == true else { currentViewTask?.cancel(); return }
    guard currentView.request(key) else { return }
    // Keep the cancelled task owned until it has drained. Replacing its handle
    // would let shutdown acknowledge while an older renderer still uses SQL.
    if let currentViewTask { currentViewTask.cancel(); return }
    let generation = currentView.begin(key)
    currentViewTask = Task { [weak self] in
      try? await Task.sleep(for: self?.currentViewDelay ?? .zero)
      guard let self else { return }
      guard started, !Task.isCancelled,
        model?.permitsBackgroundPreparation == true,
        makeCurrentViewKey() == key
      else {
        finishCurrentViewPublication(key, generation: generation, error: PreviewPublicationError.sourceChanged)
        return
      }
      do {
        guard let model else { throw PreviewPublicationError.sourceUnavailable }
        // The peer's page may be outside the Mac window's bounded scene cache.
        // Read its addressed materials from the same writer, not a second model.
        guard let presence = model.observedPresence else { throw PreviewPublicationError.sourceUnavailable }
        let content = try await model.performStoreCommand { store in
          try store.readTransaction { _ -> (PageDocument?, DocumentDocument?, DocumentStateJournal?) in
            let page = try presence.mode == .page ? presence.notebookPageID.map { try store.loadPage($0) } : nil
            let document = try presence.mode == .document ? presence.focusedItemID.map { try store.loadDocument($0) } : nil
            let state = try document.map { try store.loadDocumentState($0.id) }
            return (page, document, state)
          }
        }
        var documentRaster: RasterLease?
        defer { documentRaster?.release() }
        if let document = content.1, let state = content.2 {
          documentRaster = try await DocumentSnapshotCache.shared.prepare(document: document, state: state,
            pageIndex: presence.documentPageIndex, programStore: model.store)
        }
        guard started, !Task.isCancelled, model.permitsBackgroundPreparation, makeCurrentViewKey() == key else {
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
    if started, wasSuperseded { scheduleCurrentView(for: makeCurrentViewKey()) }
  }

  /// Only the selected physical page is requested automatically. Explicit
  /// agent requests and this request share one queue and one render executor.
  private func schedulePagePreview(for key: PreviewPageKey?) {
    guard started, let key, requestedPageKey != key, pageRequestTask == nil, let model,
      model.permitsBackgroundPreparation else { return }
    pageRequestTask = Task { [weak self, weak model] in
      defer { self?.pageRequestTask = nil }
      guard self?.started == true, !Task.isCancelled, let model else { return }
      do {
        _ = try await model.performStoreCommand { store in
          guard let stamp = try store.readContentHeader(target: .init(kind: .page, id: key.pageID)).inkStamp,
            stamp == key.inkStamp else {
            throw PreviewPublicationError.sourceUnavailable
          }
          return try store.requestPageVision(pageID: key.pageID, expectedRevision: stamp.revision)
        }
        guard !Task.isCancelled, let self, started, pageKey == key else { return }
        requestedPageKey = key
        scheduleTargetRender(model)
      } catch { }
    }
  }

}

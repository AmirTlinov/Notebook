import Combine
import Foundation
import NotebookCore
import Observation

private struct PreviewPageKey: Hashable {
  let pageID: UUID
  let cursor: UInt64
}

private struct PreviewCurrentViewKey: Hashable {
  let workspaceStamp: VersionStamp
  let cursor: UInt64
  let boardRevision: String
  let spatialInkStamp: VersionStamp
  let presence: SessionPresence
  let presencePhase: PresencePhase
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
    targetTask?.cancel()
  }

  func start() {
    guard !started, !stopped else { return }
    started = true
    documentSnapshotObserver = NotificationCenter.default.publisher(
      for: DocumentSnapshotCache.didChange
    ).sink { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, started else { return }
        documentSnapshotGeneration &+= 1
        scheduleCurrentView(for: makeCurrentViewKey())
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
    observePages()
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
    let tasks = [currentViewTask, pageRequestTask, reconciliationTask, targetTask].compactMap { $0 }
    for task in tasks { task.cancel() }
    let drain = Task { @MainActor [weak self] in
      for task in tasks { await task.value }
      guard let self else { return }
      currentViewTask = nil; pageRequestTask = nil; reconciliationTask = nil
      targetTask = nil
      targetInProgress = nil; requestedPageKey = nil
      currentView = .init()
      stoppingTask = nil
    }
    stoppingTask = drain
    await drain.value
  }

  func suspendForInput() {
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
    scheduleCurrentView(for: makeCurrentViewKey())
    schedulePagePreview(for: pageKey)
    guard let model else { return }
    let health: [String: Any] = ["status": model.isPeerConnected ? "connected" : "disconnected", "updatedAt": Date().timeIntervalSince1970]
    if let data = try? JSONSerialization.data(withJSONObject: health) {
      try? data.write(to: model.store.root.appendingPathComponent("previews/runtime.json"), options: .atomic)
    }
    guard model.permitsBackgroundPreparation else { targetTask?.cancel(); return }
    scheduleTargetRender(model)
  }

  private func scheduleTargetRender(_ model: NotebookAppModel) {
    guard started, model.permitsBackgroundPreparation, targetTask == nil else { return }
    let selectedPage = pageKey?.pageID
    targetTask = Task { [weak self, weak model] in
      defer { self?.targetInProgress = nil; self?.targetTask = nil }
      guard self?.started == true, !Task.isCancelled, let model else { return }
      do {
        let request = try await model.performStoreCommand { store in
          try store.targetRenderRequests().sorted { left, right in
            let leftCurrent = left.pageVisionRevision != nil && left.target.id == selectedPage
            let rightCurrent = right.pageVisionRevision != nil && right.target.id == selectedPage
            return leftCurrent == rightCurrent ? left.createdAt < right.createdAt : leftCurrent
          }.first { !FileManager.default.fileExists(atPath: store.targetReceiptURL($0.id).path) }
        }
        guard self?.started == true, !Task.isCancelled, model.permitsBackgroundPreparation, let request else { return }
        self?.targetInProgress = request.id
        do {
          try await CurrentViewPreviewWriter.writeTarget(request, model: model)
        } catch is CancellationError {
          // A cancelled producer has no terminal result. The durable request
          // remains owned by this publisher's queue and can resume on admission.
          // Historical ready/error receipts are never rewritten here.
          return
        } catch {
          guard self?.started == true, !Task.isCancelled, model.permitsBackgroundPreparation else { return }
          let receipt = TargetRenderReceipt(request: request, status: "error", diagnostics: [
            .init(kind: "render_error", message: String(describing: error))])
          try await model.performStoreCommand { try $0.saveTargetRender(receipt) }
        }
      } catch { /* The next publisher observation can retry an unread request. */ }
    }
  }

  private func observeCurrentView() {
    guard started else { return }
    let key = withObservationTracking {
      makeCurrentViewKey()
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        self?.observeCurrentView()
      }
    }
    scheduleCurrentView(for: key)
  }

  private func observePages() {
    guard started else { return }
    let key = withObservationTracking {
      pageKey
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        self?.observePages()
      }
    }
    schedulePagePreview(for: key)
  }

  private var pageKey: PreviewPageKey? {
    guard let model, let id = model.observedPresence?.notebookPageID, let header = model.workspaceHeader else { return nil }
    return .init(pageID: id, cursor: header.cursor)
  }

  private func makeCurrentViewKey() -> PreviewCurrentViewKey? {
    guard let model, let header = model.workspaceHeader,
      let boardRevision = header.boardRevision, let inkStamp = header.spatialInkStamp,
      let presence = model.observedPresence else { return nil }
    return .init(workspaceStamp: header.stamp, cursor: header.cursor,
      boardRevision: boardRevision, spatialInkStamp: inkStamp,
      presence: presence, presencePhase: model.observedPresencePhase,
      documentSnapshotGeneration: documentSnapshotGeneration)
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
        let presence = key.presence
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
            pageIndex: presence.documentPageIndex)
        }
        guard started, !Task.isCancelled, model.permitsBackgroundPreparation, makeCurrentViewKey() == key else {
          throw PreviewPublicationError.sourceChanged
        }
        try await CurrentViewPreviewWriter.write(model: model,
          viewport: .init(width: presence.viewport.x, height: presence.viewport.y), presence: presence,
          page: content.0, document: content.1, documentState: content.2, documentRaster: documentRaster,
          pngURL: model.store.currentViewPreviewURL, receiptURL: model.store.currentViewRevisionURL)
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
          guard let stamp = try store.readContentHeader(target: .init(kind: .page, id: key.pageID)).inkStamp else {
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

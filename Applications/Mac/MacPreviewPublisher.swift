import Combine
import Foundation
import NotebookCore
import Observation

private struct PreviewPageKey: Hashable {
  let pageID: UUID
  let drawingStamp: VersionStamp
}

private struct PreviewCurrentViewKey: Hashable {
  let workspaceStamp: VersionStamp
  let boardRevision: String
  let spatialInkStamp: VersionStamp
  let presence: SessionPresence
  let presencePhase: PresencePhase
  let pageDrawingStamp: VersionStamp?
  let pageAgentStamp: VersionStamp?
  let documentContentStamp: VersionStamp?
  let documentStateStamp: VersionStamp?
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

/// Publishes the visual readout consumed by MCP for the lifetime of the Mac
/// app. The publisher deliberately does not belong to a window: closing the
/// mirror must not make the iPad invisible to an agent.
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
  private var targetTask: Task<Void, Never>?
  private var targetInProgress: UUID?
  private var referenceVisionTask: Task<Void, Never>?
  private var referenceVisionKey: String?

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
    referenceVisionTask?.cancel()
  }

  func start() {
    guard !started else { return }
    started = true
    documentSnapshotObserver = NotificationCenter.default.publisher(
      for: DocumentSnapshotCache.didChange
    ).sink { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        documentSnapshotGeneration &+= 1
        scheduleCurrentView(for: makeCurrentViewKey())
      }
    }
    agentSnapshotObserver = NotificationCenter.default.publisher(
      for: SceneRenderResources.didChange
    ).sink { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
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

  func suspendForInput() {
    currentViewTask?.cancel()
    pageRequestTask?.cancel()
    targetTask?.cancel()
    referenceVisionTask?.cancel()
    referenceVisionKey = nil
  }

  /// Observation gives immediate updates. This small process-level pass gives
  /// the durable readout the same eventual guarantee as the files it mirrors:
  /// if a burst coalesces observation callbacks, the final versions still get
  /// published without reopening the app.
  private func reconcilePublication() {
    scheduleCurrentView(for: makeCurrentViewKey())
    schedulePagePreview(for: pageKey)
    guard let model else { return }
    let health: [String: Any] = ["status": model.isPeerConnected ? "connected" : "disconnected", "updatedAt": Date().timeIntervalSince1970]
    if let data = try? JSONSerialization.data(withJSONObject: health) {
      try? data.write(to: model.store.root.appendingPathComponent("previews/runtime.json"), options: .atomic)
    }
    guard model.permitsBackgroundPreparation else { targetTask?.cancel(); return }
    scheduleReferenceVision(model)
    scheduleTargetRender(model)
  }

  private func scheduleTargetRender(_ model: NotebookAppModel) {
    guard model.permitsBackgroundPreparation, targetInProgress == nil,
      let request = (try? model.store.targetRenderRequests())?.sorted(by: { left, right in
        let leftCurrent = left.pageVisionRevision != nil && left.target.id == pageKey?.pageID
        let rightCurrent = right.pageVisionRevision != nil && right.target.id == pageKey?.pageID
        return leftCurrent == rightCurrent ? left.createdAt < right.createdAt : leftCurrent
      }).first(where: {
      !FileManager.default.fileExists(atPath: model.store.targetReceiptURL($0.id).path)
    }) else { return }
    targetInProgress = request.id
    targetTask = Task { [weak self, weak model] in
      defer { self?.targetInProgress = nil; self?.targetTask = nil }
      guard let model else { return }
      do { try await CurrentViewPreviewWriter.writeTarget(request, model: model); self?.referenceVisionKey = nil }
      catch {
        guard !Task.isCancelled, model.permitsBackgroundPreparation else { return }
        try? model.store.saveTargetRender(.init(request: request, status: "error", diagnostics: [
          .init(kind: "render_error", message: String(describing: error))]))
      }
    }
  }

  private func scheduleReferenceVision(_ model: NotebookAppModel) {
    let references = Array(model.sharedContexts.sorted(by: { ($0.entries.last?.createdAt ?? .distantPast) > ($1.entries.last?.createdAt ?? .distantPast) })
      .prefix(8).flatMap({ $0.entries.flatMap(\.references) }).filter { $0.region != nil && $0.elementID == nil }.prefix(32))
    guard !references.isEmpty else { return }
    let key = String(model.collaborationReadEpoch)
    guard referenceVisionTask == nil, referenceVisionKey != key else { return }
    referenceVisionKey = key
    let store = model.store
    referenceVisionTask = Task { [weak self] in
      defer { self?.referenceVisionTask = nil }
      let worker = Task.detached(priority: .utility) {
        for reference in references {
          guard !Task.isCancelled else { return }
          _ = try? store.referenceStatus(reference)
        }
      }
      await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }
  }

  private func observeCurrentView() {
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
    guard let model, let id = model.workspace?.selectedPageID, let page = model.pages[id] else { return nil }
    return .init(pageID: id, drawingStamp: page.drawingStamp)
  }

  private func makeCurrentViewKey() -> PreviewCurrentViewKey? {
    guard let model, let workspace = model.workspace,
      let board = model.boardHierarchy,
      let spatialInk = model.spatialInk,
      let presence = model.presence
    else { return nil }
    let focusedIsSelected = presence.focusedItemID == workspace.selectedItemID
    let page = focusedIsSelected ? model.activePage : nil
    let document = focusedIsSelected ? model.activeDocument : nil
    let documentState = document.flatMap { model.documentStates[$0.id] }
    return PreviewCurrentViewKey(
      workspaceStamp: workspace.stamp,
      boardRevision: board.revision,
      spatialInkStamp: spatialInk.stamp,
      presence: presence,
      presencePhase: model.presencePhase,
      pageDrawingStamp: page?.drawingStamp,
      pageAgentStamp: page?.agentStamp,
      documentContentStamp: document?.contentStamp,
      documentStateStamp: documentState?.stamp,
      documentSnapshotGeneration: documentSnapshotGeneration
    )
  }

  private func scheduleCurrentView(for key: PreviewCurrentViewKey?) {
    guard let key, key.presencePhase == .settled, model?.permitsBackgroundPreparation == true else { currentViewTask?.cancel(); return }
    guard currentView.request(key) else { return }
    currentViewTask?.cancel()
    let generation = currentView.begin(key)
    currentViewTask = Task { [weak self] in
      try? await Task.sleep(for: self?.currentViewDelay ?? .zero)
      guard let self else { return }
      guard !Task.isCancelled,
        model?.permitsBackgroundPreparation == true,
        makeCurrentViewKey() == key
      else {
        finishCurrentViewPublication(key, generation: generation, error: PreviewPublicationError.sourceChanged)
        return
      }
      do {
        var documentRaster: RasterLease?
        defer { documentRaster?.release() }
        if let model, model.presence?.mode == .document, let document = model.activeDocument,
          let state = model.documentStates[document.id] {
          documentRaster = try await DocumentSnapshotCache.shared.prepare(document: document, state: state, pageIndex: model.presence?.documentPageIndex ?? 0)
        }
        guard !Task.isCancelled, model?.permitsBackgroundPreparation == true, makeCurrentViewKey() == key else {
          throw PreviewPublicationError.sourceChanged
        }
        finishCurrentViewPublication(key, generation: generation,
          error: await writeCurrentView(documentRaster: documentRaster))
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
    currentView.finish(key, generation: generation, error: error)
    currentViewTask = nil
  }

  /// Only the selected physical page is requested automatically. Explicit
  /// agent requests and this request share one queue and one render executor.
  private func schedulePagePreview(for key: PreviewPageKey?) {
    guard let key, requestedPageKey != key, pageRequestTask == nil, let model,
      model.permitsBackgroundPreparation else { return }
    let store = model.store
    pageRequestTask = Task { [weak self, weak model] in
      defer { self?.pageRequestTask = nil }
      let worker = Task.detached(priority: .utility) {
        try Task.checkCancellation()
        return try store.requestPageVision(pageID: key.pageID, expectedRevision: key.drawingStamp.revision)
      }
      do {
        _ = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled, let self, let model, pageKey == key else { return }
        requestedPageKey = key
        scheduleTargetRender(model)
      } catch { }
    }
  }

  private func writeCurrentView(documentRaster: RasterLease?) async -> (any Error)? {
    guard let model, let workspace = model.workspace,
      let board = model.boardHierarchy,
      let spatialInk = model.spatialInk,
      let presence = model.presence,
      presence.viewport.x > 0,
      presence.viewport.y > 0
    else { return PreviewPublicationError.sourceUnavailable }
    let focusedIsSelected = presence.focusedItemID == workspace.selectedItemID
    let page = focusedIsSelected ? model.activePage : nil
    let document = focusedIsSelected ? model.activeDocument : nil
    let documentState = document.flatMap { model.documentStates[$0.id] }
    guard presence.mode != .document
      || (document != nil && documentState != nil)
    else { return PreviewPublicationError.sourceUnavailable }
    do {
      try await CurrentViewPreviewWriter.write(
        model: model,
        viewport: CGSize(
          width: presence.viewport.x,
          height: presence.viewport.y
        ),
        workspace: workspace,
        board: board,
        spatialInk: spatialInk,
        presence: presence,
        page: page,
        document: document,
        documentState: documentState,
        documentRaster: documentRaster,
        pngURL: model.store.currentViewPreviewURL,
        receiptURL: model.store.currentViewRevisionURL
      )
      return nil
    } catch {
      return error
    }
  }
}

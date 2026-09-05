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

/// One owner for the desired, published, pending, and failed state of every
/// durable preview. Timers merely wake this state machine; they do not own it.
private struct PreviewReconciler {
  var currentView = PreviewPublicationSlot<PreviewCurrentViewKey>()
  var pages = PreviewPublicationSlot<[PreviewPageKey]>()
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
  private let pagePreviewDelay: Duration
  private let reconciliationInterval: Duration
  private var currentViewTask: Task<Void, Never>?
  private var pagePreviewTask: Task<Void, Never>?
  private var reconciliationTask: Task<Void, Never>?
  private var documentSnapshotObserver: AnyCancellable?
  private var agentSnapshotObserver: AnyCancellable?
  private var documentSnapshotGeneration = 0
  private var reconciler = PreviewReconciler()
  private var started = false
  private var targetTask: Task<Void, Never>?
  private var targetInProgress: UUID?
  private var referenceVisionTask: Task<Void, Never>?
  private var referenceVisionKey: String?

  init(
    model: NotebookAppModel,
    currentViewDelay: Duration = .milliseconds(220),
    pagePreviewDelay: Duration = .milliseconds(420),
    reconciliationInterval: Duration = .seconds(1)
  ) {
    self.model = model
    self.currentViewDelay = currentViewDelay
    self.pagePreviewDelay = pagePreviewDelay
    self.reconciliationInterval = reconciliationInterval
  }

  deinit {
    currentViewTask?.cancel()
    pagePreviewTask?.cancel()
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
      for: AgentElementSnapshotCache.didChange
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
    pagePreviewTask?.cancel()
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
    schedulePagePreviews(for: pageKeys)
    guard let model else { return }
    let health: [String: Any] = ["status": model.isPeerConnected ? "connected" : "disconnected", "updatedAt": Date().timeIntervalSince1970]
    if let data = try? JSONSerialization.data(withJSONObject: health) {
      try? data.write(to: model.store.root.appendingPathComponent("previews/runtime.json"), options: .atomic)
    }
    guard model.permitsBackgroundPreparation else { targetTask?.cancel(); return }
    scheduleReferenceVision(model)
    guard targetInProgress == nil, let request = (try? model.store.targetRenderRequests())?.first(where: {
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
    let key = references.map { $0.id.uuidString }.joined() + (model.boardHierarchy?.revision ?? "")
      + (model.spatialInk?.stamp.revision ?? "")
      + model.pages.values.sorted { $0.id.uuidString < $1.id.uuidString }.map { $0.drawingStamp.revision + $0.agentStamp.revision }.joined()
      + model.documents.values.sorted { $0.id.uuidString < $1.id.uuidString }.map { $0.contentStamp.revision }.joined()
      + model.documentStates.values.sorted { $0.id.uuidString < $1.id.uuidString }.map { $0.stamp.revision }.joined()
    guard referenceVisionTask == nil, referenceVisionKey != key else { return }
    referenceVisionKey = key
    let store = model.store
    referenceVisionTask = Task { [weak self] in
      await Task.detached(priority: .utility) {
        for reference in references { _ = try? store.referenceStatus(reference) }
      }.value
      self?.referenceVisionTask = nil
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
    let keys = withObservationTracking {
      pageKeys
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        self?.observePages()
      }
    }
    schedulePagePreviews(for: keys)
  }

  private var pageKeys: [PreviewPageKey] {
    guard let model else { return [] }
    return model.pages.values
      .map {
        PreviewPageKey(pageID: $0.id, drawingStamp: $0.drawingStamp)
      }
      .sorted { $0.pageID.uuidString < $1.pageID.uuidString }
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
    guard reconciler.currentView.request(key) else { return }
    currentViewTask?.cancel()
    let generation = reconciler.currentView.begin(key)
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
        try await AgentElementSnapshotCache.shared.prepare(snapshotElements())
        if let model, model.presence?.mode == .document, let document = model.activeDocument,
          let state = model.documentStates[document.id] {
          try await DocumentSnapshotCache.shared.prepare(document: document, state: state, pageIndex: model.presence?.documentPageIndex ?? 0)
        }
        guard !Task.isCancelled, model?.permitsBackgroundPreparation == true, makeCurrentViewKey() == key else {
          throw PreviewPublicationError.sourceChanged
        }
        finishCurrentViewPublication(key, generation: generation, error: await writeCurrentView())
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
    guard reconciler.currentView.pending == key,
      reconciler.currentView.generation == generation else { return }
    reconciler.currentView.finish(key, generation: generation, error: error)
    currentViewTask = nil
  }

  private func schedulePagePreviews(for keys: [PreviewPageKey]) {
    guard model?.permitsBackgroundPreparation == true else { pagePreviewTask?.cancel(); return }
    guard reconciler.pages.request(keys) else { return }
    pagePreviewTask?.cancel()
    let generation = reconciler.pages.begin(keys)
    pagePreviewTask = Task { [weak self] in
      try? await Task.sleep(for: self?.pagePreviewDelay ?? .zero)
      guard let self else { return }
      guard !Task.isCancelled, pageKeys == keys else {
        finishPagePublication(keys, generation: generation, error: PreviewPublicationError.sourceChanged)
        return
      }
      var publicationError: (any Error)?
      for key in keys {
        guard !Task.isCancelled,
          let model, model.permitsBackgroundPreparation, let page = model.pages[key.pageID],
          page.drawingStamp == key.drawingStamp
        else {
          publicationError = PreviewPublicationError.sourceChanged
          break
        }
        let store = model.store
        let worker = Task.detached(priority: .utility) {
          guard !PagePreviewWriter.hasCurrentArtifacts(for: page, store: store) else { return }
          try Task.checkCancellation()
          try PagePreviewWriter.write(page, store: store)
        }
        do {
          try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        } catch { publicationError = error }
        await Task.yield()
      }
      finishPagePublication(
        keys,
        generation: generation,
        error: publicationError
      )
    }
  }

  private func finishPagePublication(
    _ keys: [PreviewPageKey],
    generation: UInt64,
    error: (any Error)?
  ) {
    guard reconciler.pages.pending == keys,
      reconciler.pages.generation == generation else { return }
    reconciler.pages.finish(keys, generation: generation, error: error)
    pagePreviewTask = nil
  }

  private func snapshotElements() -> [AgentElement] {
    guard let model, let workspace = model.workspace, let hierarchy = model.boardHierarchy,
      let presence = model.presence else { return [] }
    switch presence.mode {
    case .board, .cover:
      return WorkspaceSceneProjection.snapshotLayers(
        workspace: workspace, hierarchy: hierarchy, presence: presence, documents: model.documents
      ).elements.filter { $0.kind != .nativeText }.map(agentElementSnapshotSource)
    case .page:
      return model.activePage?.elements ?? []
    case .document:
      return []
    }
  }

  private func writeCurrentView() async -> (any Error)? {
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
        pngURL: model.store.currentViewPreviewURL,
        receiptURL: model.store.currentViewRevisionURL
      )
      return nil
    } catch {
      return error
    }
  }
}

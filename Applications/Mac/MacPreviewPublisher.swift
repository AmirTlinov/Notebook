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
  let boardStamp: VersionStamp
  let spatialInkStamp: VersionStamp
  let presence: SessionPresence
  let presencePhase: PresencePhase
  let pageDrawingStamp: VersionStamp?
  let pageAgentStamp: VersionStamp?
  let documentContentStamp: VersionStamp?
  let documentStateStamp: VersionStamp?
  let documentSnapshotGeneration: Int
}

/// Publishes the visual readout consumed by MCP for the lifetime of the Mac
/// app. The publisher deliberately does not belong to a window: closing the
/// mirror must not make the iPad invisible to an agent.
@MainActor
final class MacPreviewPublisher {
  private unowned let model: NotebookAppModel
  private let currentViewDelay: Duration
  private let pagePreviewDelay: Duration
  private var currentViewTask: Task<Void, Never>?
  private var pagePreviewTask: Task<Void, Never>?
  private var documentSnapshotObserver: AnyCancellable?
  private var documentSnapshotGeneration = 0
  private var started = false

  init(
    model: NotebookAppModel,
    currentViewDelay: Duration = .milliseconds(220),
    pagePreviewDelay: Duration = .milliseconds(420)
  ) {
    self.model = model
    self.currentViewDelay = currentViewDelay
    self.pagePreviewDelay = pagePreviewDelay
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
    observeCurrentView()
    observePages()
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
    model.pages.values
      .map {
        PreviewPageKey(pageID: $0.id, drawingStamp: $0.drawingStamp)
      }
      .sorted { $0.pageID.uuidString < $1.pageID.uuidString }
  }

  private func makeCurrentViewKey() -> PreviewCurrentViewKey? {
    guard let workspace = model.workspace,
      let board = model.board,
      let spatialInk = model.spatialInk,
      let presence = model.presence
    else { return nil }
    let focusedIsSelected = presence.focusedItemID == workspace.selectedItemID
    let page = focusedIsSelected ? model.activePage : nil
    let document = focusedIsSelected ? model.activeDocument : nil
    let documentState = document.flatMap { model.documentStates[$0.id] }
    return PreviewCurrentViewKey(
      workspaceStamp: workspace.stamp,
      boardStamp: board.stamp,
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
    currentViewTask?.cancel()
    guard let key, key.presencePhase == .settled else { return }
    currentViewTask = Task { [weak self] in
      try? await Task.sleep(for: self?.currentViewDelay ?? .zero)
      guard let self else { return }
      guard !Task.isCancelled,
        model.presencePhase == .settled,
        makeCurrentViewKey() == key
      else { return }
      writeCurrentView()
    }
  }

  private func schedulePagePreviews(for keys: [PreviewPageKey]) {
    pagePreviewTask?.cancel()
    pagePreviewTask = Task { [weak self] in
      try? await Task.sleep(for: self?.pagePreviewDelay ?? .zero)
      guard let self else { return }
      guard !Task.isCancelled, pageKeys == keys else { return }
      for key in keys {
        guard !Task.isCancelled,
          let page = model.pages[key.pageID],
          page.drawingStamp == key.drawingStamp
        else { return }
        guard !PagePreviewWriter.hasCurrentArtifacts(
          for: page,
          store: model.store
        ) else { continue }
        try? PagePreviewWriter.write(page, store: model.store)
        await Task.yield()
      }
    }
  }

  private func writeCurrentView() {
    guard let workspace = model.workspace,
      let board = model.board,
      let spatialInk = model.spatialInk,
      let presence = model.presence,
      presence.viewport.x > 0,
      presence.viewport.y > 0
    else { return }
    let focusedIsSelected = presence.focusedItemID == workspace.selectedItemID
    let page = focusedIsSelected ? model.activePage : nil
    let document = focusedIsSelected ? model.activeDocument : nil
    let documentState = document.flatMap { model.documentStates[$0.id] }
    guard presence.mode != .document
      || (document != nil && documentState != nil)
    else { return }
    try? CurrentViewPreviewWriter.write(
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
  }
}

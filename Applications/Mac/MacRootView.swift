import Combine
import SwiftUI
import NotebookCore

private struct PreviewKey: Hashable {
  let pageID: UUID
  let drawingStamp: VersionStamp
}

private struct CurrentViewKey: Hashable {
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
  let width: Int
  let height: Int
}

struct MacRootView: View {
  @Environment(NotebookAppModel.self) private var model
  @State private var documentSnapshotGeneration = 0

  var body: some View {
    GeometryReader { geometry in
      NotebookRootView()
        .task(id: currentViewKey(viewport: geometry.size)) {
          guard model.presencePhase == .settled else { return }
          try? await Task.sleep(for: .milliseconds(220))
          guard !Task.isCancelled, model.presencePhase == .settled else { return }
          writeCurrentView(viewport: geometry.size)
        }
    }
      .task(id: previewKeys) {
        try? await Task.sleep(for: .milliseconds(420))
        guard !Task.isCancelled else { return }
        for key in previewKeys {
          guard !Task.isCancelled, let page = model.pages[key.pageID] else {
            return
          }
          guard !PagePreviewWriter.hasCurrentArtifacts(
            for: page,
            store: model.store
          ) else {
            continue
          }
          try? PagePreviewWriter.write(
            page,
            store: model.store
          )
          await Task.yield()
        }
      }
      .onReceive(
        NotificationCenter.default.publisher(
          for: DocumentSnapshotCache.didChange
        )
      ) { _ in
        documentSnapshotGeneration &+= 1
      }
  }

  private var previewKeys: [PreviewKey] {
    model.pages.values
      .map { PreviewKey(pageID: $0.id, drawingStamp: $0.drawingStamp) }
      .sorted { $0.pageID.uuidString < $1.pageID.uuidString }
  }

  private func currentViewKey(viewport: CGSize) -> CurrentViewKey? {
    guard let workspace = model.workspace,
      let board = model.board,
      let spatialInk = model.spatialInk,
      let presence = model.presence
    else { return nil }
    let page = presence.focusedItemID == workspace.selectedItemID
      ? model.activePage
      : nil
    let document = presence.focusedItemID == workspace.selectedItemID
      ? model.activeDocument
      : nil
    let documentState = document.flatMap { model.documentStates[$0.id] }
    return CurrentViewKey(
      workspaceStamp: workspace.stamp,
      boardStamp: board.stamp,
      spatialInkStamp: spatialInk.stamp,
      presence: presence,
      presencePhase: model.presencePhase,
      pageDrawingStamp: page?.drawingStamp,
      pageAgentStamp: page?.agentStamp,
      documentContentStamp: document?.contentStamp,
      documentStateStamp: documentState?.stamp,
      documentSnapshotGeneration: documentSnapshotGeneration,
      width: max(1, Int(viewport.width.rounded())),
      height: max(1, Int(viewport.height.rounded()))
    )
  }

  @MainActor
  private func writeCurrentView(viewport: CGSize) {
    guard viewport.width > 0, viewport.height > 0,
      let workspace = model.workspace,
      let board = model.board,
      let spatialInk = model.spatialInk,
      let presence = model.presence
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
      viewport: viewport,
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

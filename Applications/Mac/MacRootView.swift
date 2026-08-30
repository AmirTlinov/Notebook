import SwiftUI
import NotebookCore

private struct PreviewKey: Hashable {
  let pageID: UUID
  let drawingStamp: VersionStamp

  var revision: String {
    "\(drawingStamp.counter)@\(drawingStamp.actor.uuidString.lowercased())"
  }
}

private struct CurrentViewKey: Hashable {
  let workspaceStamp: VersionStamp
  let boardStamp: VersionStamp
  let spatialInkStamp: VersionStamp
  let presence: SessionPresence
  let presencePhase: PresencePhase
  let pageDrawingStamp: VersionStamp?
  let pageAgentStamp: VersionStamp?
  let width: Int
  let height: Int
}

struct MacRootView: View {
  @Environment(NotebookAppModel.self) private var model

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
          let revisionURL = model.store.previewRevisionURL(page.id)
          let renderedRevision = try? String(
            contentsOf: revisionURL,
            encoding: .utf8
          ).trimmingCharacters(in: .whitespacesAndNewlines)
          let previewExists = FileManager.default.fileExists(
            atPath: model.store.previewURL(page.id).path
          )
          guard !previewExists || renderedRevision != key.revision else {
            continue
          }
          try? PagePreviewWriter.write(
            page,
            to: model.store.previewURL(page.id)
          )
          await Task.yield()
        }
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
    let page = presence.focusedNotebookID == workspace.selectedNotebookID
      ? model.activePage
      : nil
    return CurrentViewKey(
      workspaceStamp: workspace.stamp,
      boardStamp: board.stamp,
      spatialInkStamp: spatialInk.stamp,
      presence: presence,
      presencePhase: model.presencePhase,
      pageDrawingStamp: page?.drawingStamp,
      pageAgentStamp: page?.agentStamp,
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
    try? CurrentViewPreviewWriter.write(
      model: model,
      viewport: viewport,
      workspace: workspace,
      board: board,
      spatialInk: spatialInk,
      presence: presence,
      page: presence.focusedNotebookID == workspace.selectedNotebookID
        ? model.activePage
        : nil,
      pngURL: model.store.currentViewPreviewURL,
      receiptURL: model.store.currentViewRevisionURL
    )
  }
}

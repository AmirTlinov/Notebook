import SwiftUI
import TetradCore

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
  let pageDrawingStamp: VersionStamp?
  let pageAgentStamp: VersionStamp?
  let width: Int
  let height: Int
}

struct MacRootView: View {
  @Environment(TetradAppModel.self) private var model
  @State private var watcher: DirectoryWatcher?

  var body: some View {
    GeometryReader { geometry in
      TetradRootView()
        .task(id: currentViewKey(viewport: geometry.size)) {
          writeCurrentView(viewport: geometry.size)
        }
    }
      .onAppear {
        try? model.store.prepare()
        let watcher = DirectoryWatcher(
          urls: [model.store.root, model.store.pagesURL]
        ) {
          model.reloadExternalChanges()
        }
        watcher.start()
        self.watcher = watcher
      }
      .onDisappear {
        watcher?.stop()
        watcher = nil
      }
      .task(id: previewKeys) {
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

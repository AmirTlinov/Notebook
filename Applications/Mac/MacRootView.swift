import SwiftUI
import TetradCore

private struct PreviewKey: Hashable {
  let pageID: UUID
  let drawingStamp: VersionStamp

  var revision: String {
    "\(drawingStamp.counter)@\(drawingStamp.actor.uuidString.lowercased())"
  }
}

struct MacRootView: View {
  @Environment(TetradAppModel.self) private var model
  @State private var watcher: DirectoryWatcher?

  var body: some View {
    TetradRootView()
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
}

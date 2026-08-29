import SwiftUI
import TetradCore

private struct PreviewKey: Hashable {
  let pageID: UUID
  let drawingStamp: VersionStamp
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
      .task(id: previewKey) {
        guard let page = model.activePage else { return }
        try? PagePreviewWriter.write(page, to: model.store.previewURL(page.id))
      }
  }

  private var previewKey: PreviewKey? {
    model.activePage.map {
      PreviewKey(pageID: $0.id, drawingStamp: $0.drawingStamp)
    }
  }
}

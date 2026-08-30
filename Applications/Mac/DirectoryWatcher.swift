import Foundation

final class DirectoryWatcher: @unchecked Sendable {
  private let urls: [URL]
  private let onChange: @MainActor () -> Void
  private let queue = DispatchQueue(label: "com.amirtlinov.notebook.file-watch")
  private var sources: [DispatchSourceFileSystemObject] = []
  private var debounce: DispatchWorkItem?

  init(urls: [URL], onChange: @escaping @MainActor () -> Void) {
    self.urls = urls
    self.onChange = onChange
  }

  func start() {
    queue.sync { startOnQueue() }
  }

  func stop() {
    queue.sync {
      debounce?.cancel()
      debounce = nil
      sources.forEach { $0.cancel() }
      sources = []
    }
  }

  deinit {
    stop()
  }

  private func startOnQueue() {
    guard sources.isEmpty else { return }
    for url in urls {
      let descriptor = open(url.path, O_EVTONLY)
      guard descriptor >= 0 else { continue }
      let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: descriptor,
        eventMask: [.write, .rename, .extend, .attrib],
        queue: queue
      )
      source.setEventHandler { [weak self] in
        self?.scheduleChange()
      }
      source.setCancelHandler {
        close(descriptor)
      }
      sources.append(source)
      source.resume()
    }
  }

  private func scheduleChange() {
    debounce?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      debounce = nil
      Task { @MainActor in onChange() }
    }
    debounce = work
    queue.asyncAfter(deadline: .now() + 0.04, execute: work)
  }
}

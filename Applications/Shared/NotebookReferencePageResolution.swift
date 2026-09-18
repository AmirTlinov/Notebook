import Foundation

/// A Show command may outlive its camera animation while WebKit finds a block's
/// physical sheet. Only that command may finish the pending page adjustment.
@MainActor
final class NotebookReferencePageResolution {
  private var task: Task<Void, Never>?
  private var generation: UInt64 = 0
  private(set) var requestID: UUID?
  private(set) var documentID: UUID?

  func cancel() {
    generation &+= 1
    requestID = nil
    documentID = nil
    task?.cancel(); task = nil
  }

  func start(requestID: UUID, documentID: UUID, isCurrent: @escaping () -> Bool,
    resolve: @escaping () -> Int?, apply: @escaping (Int) -> Void) {
    cancel()
    self.requestID = requestID
    self.documentID = documentID
    let expectedGeneration = generation
    task = Task { @MainActor [weak self] in
      defer { self?.finish(requestID: requestID, generation: expectedGeneration) }
      let deadline = ContinuousClock.now + .seconds(8)
      while ContinuousClock.now < deadline {
        do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
        guard let self, !Task.isCancelled, generation == expectedGeneration,
          self.requestID == requestID, isCurrent() else { return }
        guard let page = resolve() else { continue }
        guard generation == expectedGeneration, self.requestID == requestID else { return }
        apply(page)
        return
      }
    }
  }

  private func finish(requestID: UUID, generation: UInt64) {
    guard self.generation == generation, self.requestID == requestID else { return }
    task = nil; self.requestID = nil; documentID = nil
  }

  isolated deinit { task?.cancel() }
}


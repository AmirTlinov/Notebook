import Foundation
import QuartzCore
import Metal

/// The canvas's sole outstanding drawable demand, shared by live drawing and
/// private frame preparation. A cancelled worker keeps its physical pool slot.
@MainActor
final class InkCanvasDrawableAcquisition {
  struct Cut: Equatable {
    let source, content: UInt64
    let preparation: UUID
    let staging: UUID?
    let target: ObjectIdentifier
    let size: CGSize
    let indices: [Int]
  }
  enum Poll {
    case pending
    case ready([any CAMetalDrawable])
    case failed
  }
  private var current: (cut: Cut, request: SceneMetalDrawableRequest)?
  private var activePreparations = 0
  var isPending: Bool { activePreparations > 0 || (current.map { !$0.request.isDrained } ?? false) }

  func poll(_ cut: Cut, pools: @autoclosure () -> [SceneMetalDrawableRequest.Pool],
    completed: @escaping @MainActor @Sendable (Bool) -> Void) -> Poll {
    if let current, current.cut != cut { cancel() }
    if let current {
      guard current.request.isDrained else { return .pending }
      self.current = nil
      if current.request.isCancelled { return poll(cut, pools: pools(), completed: completed) }
      if let values = current.request.takeAll() { return .ready(values) }
      return .failed
    }
    let request = SceneMetalDrawableRequest(pools: pools())
    current = (cut, request)
    request.start { [weak self, weak request] in
      guard let self, let request, self.current?.request === request else { return }
      if request.isCancelled || request.hasFailed { self.current = nil }
      completed(request.hasFailed)
    }
    return .pending
  }

  func acquire(_ cut: Cut, pools: [SceneMetalDrawableRequest.Pool],
    isCurrent: @MainActor () -> Bool) async throws -> [any CAMetalDrawable] {
    activePreparations += 1
    defer { activePreparations -= 1 }
    cancel()
    if let request = current?.request {
      await withCheckedContinuation { continuation in request.whenDrained { continuation.resume() } }
    }
    try Task.checkCancellation()
    guard isCurrent() else { throw CancellationError() }
    let request = SceneMetalDrawableRequest(pools: pools)
    current = (cut, request)
    defer { if current?.request === request { current = nil } }
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in request.start { continuation.resume() } }
    } onCancel: { request.revoke() }
    try Task.checkCancellation()
    guard current?.request === request, !request.isCancelled else { throw CancellationError() }
    guard let values = request.takeAll() else { throw SceneRenderError.resourceLimit }
    return values
  }

  func cancel() {
    guard let request = current?.request else { return }
    if request.cancel() { current = nil }
  }
  func whenDrained(_ callback: @escaping @MainActor @Sendable () -> Void) {
    guard let request = current?.request else { callback(); return }
    request.whenDrained(callback)
  }
  isolated deinit { current?.request.cancel() }
}

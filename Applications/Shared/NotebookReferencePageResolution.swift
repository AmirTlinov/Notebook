import Foundation

/// Resolves an addressed block from the admitted document layout. Its lifetime
/// belongs to the Show request; camera completion and layout are independent
/// events, and neither a polling interval nor a deadline defines readiness.
@MainActor
final class NotebookReferencePageResolution {
  private struct Request {
    let id: UUID
    let documentID: UUID
    let isCurrent: () -> Bool
    let resolve: () -> Int?
    let apply: (Int) -> Void
  }
  private var request: Request?
  private var observer: UUID?
  var requestID: UUID? { request?.id }
  var documentID: UUID? { request?.documentID }

  func cancel() {
    request = nil
    if let observer { DocumentRenderRegistry.shared.removeLiveObserver(observer) }
    observer = nil
  }

  func start(requestID: UUID, documentID: UUID, isCurrent: @escaping () -> Bool,
    resolve: @escaping () -> Int?, apply: @escaping (Int) -> Void) {
    cancel()
    request = Request(id: requestID, documentID: documentID, isCurrent: isCurrent, resolve: resolve, apply: apply)
    observer = DocumentRenderRegistry.shared.observeLive(documentID: documentID) { [weak self] in self?.advance() }
    advance()
  }

  func advance() {
    guard let request else { return }
    guard request.isCurrent() else { cancel(); return }
    guard let page = request.resolve(), self.request?.id == request.id else { return }
    // Retire before callback: applying this page may synchronously start a new Show.
    cancel()
    request.apply(page)
  }

  isolated deinit { if let observer { DocumentRenderRegistry.shared.removeLiveObserver(observer) } }
}

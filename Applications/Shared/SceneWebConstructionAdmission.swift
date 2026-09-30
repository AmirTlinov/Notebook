import Foundation
#if os(iOS)
  import UIKit
#endif

/// The scene's short constructor allowance ends after an opportunity to commit
/// the resulting native content. Browser navigation has its own lifetime.
@MainActor final class SceneWebConstructionAdmission {
  private let interactive: Bool
  private let onAvailable: @MainActor () -> Void
  private var held: Set<UUID> = []
  private var finished: Set<UUID> = []
  private var committed: Set<UUID> = []
  private var deferredCompletion: Task<Void, Never>?
  #if os(iOS)
    private var updateLink: UIUpdateLink?
    private weak var updateScene: UIWindowScene?
  #endif

  var count: Int { held.count }
  var canConstruct: Bool { held.count < 2 }
  init(interactive: Bool, onAvailable: @escaping @MainActor () -> Void) {
    self.interactive = interactive; self.onAvailable = onAvailable
  }

  func reserve(_ id: UUID) {
    guard canConstruct && !held.contains(id) else {
      fatalError("Web constructor allowance exceeded: \(held.count), duplicate: \(held.contains(id))")
    }
    held.insert(id)
  }

  func finish(_ id: UUID) {
    guard held.contains(id), finished.insert(id).inserted else { return }
    #if os(iOS)
      if interactive, let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
        .first(where: { $0.activationState == .foregroundActive }) {
        if updateLink == nil || updateScene !== scene {
          updateLink?.isEnabled = false
          let link = UIUpdateLink(windowScene: scene)
          link.isEnabled = false
          link.addAction(to: .beforeCATransactionCommit) { [weak self] _, _ in
            guard let self else { return }
            committed = finished
          }
          link.addAction(to: .afterUpdateComplete) { [weak self] _, _ in self?.completeCommitted() }
          link.requiresContinuousUpdates = true
          updateLink = link
          updateScene = scene
        }
        updateLink?.isEnabled = true
        return
      }
    #endif
    // Headless work and AppKit have no UIKit update phase. Their continuation
    // still leaves the constructor stack; it never waits for remote readiness.
    guard deferredCompletion == nil else { return }
    deferredCompletion = Task { @MainActor [weak self] in
      guard let self else { return }
      deferredCompletion = nil; committed = finished; completeCommitted()
    }
  }

  func abandon(_ id: UUID) {
    // A constructed, retired view has already consumed this UI opportunity.
    // Cancellation before construction can return its allowance immediately.
    guard !finished.contains(id) else { return }
    held.remove(id)
  }

  private func completeCommitted() {
    guard !committed.isEmpty else { return }
    held.subtract(committed); finished.subtract(committed); committed.removeAll(keepingCapacity: true)
    #if os(iOS)
      if finished.isEmpty { updateLink?.isEnabled = false }
    #endif
    onAvailable()
  }

  isolated deinit {
    deferredCompletion?.cancel()
    #if os(iOS)
      updateLink?.isEnabled = false
    #endif
  }
}

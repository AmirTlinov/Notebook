import Foundation
#if os(iOS)
  import UIKit
#endif

/// The application's short constructor allowance follows its actual mounted
/// scene roots. Remote navigation and running browsers have separate lifetimes.
@MainActor final class SceneWebConstructionAdmission {
  private let interactive: Bool
  private let onAvailable: @MainActor (Int) -> Void
  private var held: Set<UUID> = []
  private var finished: Set<UUID> = []
  private var deferredCompletion: Task<Void, Never>?
  #if os(iOS)
    @MainActor private final class SceneOpportunity {
      weak var scene: UIWindowScene?
      var roots: Set<UUID> = []
      var active: Bool
      var link: UIUpdateLink?
      var generation = UUID()
      var committed: Set<UUID> = []
      init(scene: UIWindowScene) {
        self.scene = scene; active = scene.activationState == .foregroundActive
      }
      func endUpdateLifetime() {
        active = false; link?.isEnabled = false; link = nil
        generation = UUID(); committed.removeAll()
      }
    }
    private var requiresScene = false
    private var scenes: [ObjectIdentifier: SceneOpportunity] = [:]
    private var roots: [UUID: ObjectIdentifier] = [:]
    private let notifications: NotificationCenter
    private var observers: [NSObjectProtocol] = []
  #endif

  var count: Int { held.count }
  var availableCount: Int {
    #if os(iOS)
      if requiresScene && !scenes.values.contains(where: { $0.active }) { return 0 }
    #endif
    return max(0, 2 - held.count)
  }
  var canConstruct: Bool { availableCount > 0 }
  init(interactive: Bool, notifications: NotificationCenter = .default,
    onAvailable: @escaping @MainActor (Int) -> Void) {
    self.interactive = interactive; self.onAvailable = onAvailable
    #if os(iOS)
      self.notifications = notifications
      if interactive {
        for (name, active) in [(UIScene.didActivateNotification, true),
          (UIScene.willDeactivateNotification, false), (UIScene.didDisconnectNotification, false)] {
          observers.append(notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            guard let scene = note.object as? UIWindowScene else { return }
            MainActor.assumeIsolated {
              self?.setSceneActive(scene, active: active)
            }
          })
        }
      }
    #endif
  }

  #if os(iOS)
    func requireSceneLifetime() { requiresScene = true }

    /// The permanent native root supplies this identity before page/model load.
    func setSceneRoot(_ root: UUID, scene: UIWindowScene?) {
      let previous = availableCount
      requiresScene = true
      if let old = roots.removeValue(forKey: root), let opportunity = scenes[old] {
        opportunity.roots.remove(root)
        if opportunity.roots.isEmpty { opportunity.endUpdateLifetime(); scenes[old] = nil }
      }
      if let scene {
        let key = ObjectIdentifier(scene)
        let opportunity = scenes[key] ?? SceneOpportunity(scene: scene)
        opportunity.roots.insert(root); scenes[key] = opportunity; roots[root] = key
        if opportunity.active { configureLink(opportunity) }
      }
      finishEndedUILifetime()
      publishAvailability(after: previous)
    }

    private func setSceneActive(_ scene: UIWindowScene, active: Bool) {
      guard let opportunity = scenes[ObjectIdentifier(scene)], opportunity.scene === scene else { return }
      let previous = availableCount
      if active {
        opportunity.active = true; configureLink(opportunity)
      } else { opportunity.endUpdateLifetime() }
      finishEndedUILifetime()
      publishAvailability(after: previous)
    }

    private func configureLink(_ opportunity: SceneOpportunity) {
      guard opportunity.link == nil, let scene = opportunity.scene else { return }
      let generation = opportunity.generation
      let link = UIUpdateLink(windowScene: scene)
      link.isEnabled = false
      link.addAction(to: .beforeCATransactionCommit) { [weak self, weak opportunity] _, _ in
        guard let self, let opportunity, opportunity.active,
          opportunity.generation == generation else { return }
        opportunity.committed = finished
      }
      link.addAction(to: .afterUpdateComplete) { [weak self, weak opportunity] _, _ in
        guard let self, let opportunity, opportunity.active,
          opportunity.generation == generation else { return }
        complete(opportunity.committed)
      }
      link.requiresContinuousUpdates = true
      opportunity.link = link; link.isEnabled = !finished.isEmpty
    }

    private func finishEndedUILifetime() {
      guard requiresScene, !scenes.values.contains(where: { $0.active }) else { return }
      // There can be no further update in this lifetime. Finish only already
      // constructed work; queued and unconstructed owners keep their lifetime.
      complete(finished)
    }
  #endif

  func reserve(_ id: UUID) {
    guard canConstruct && !held.contains(id) else {
      fatalError("Web constructor allowance exceeded: \(held.count), duplicate: \(held.contains(id))")
    }
    held.insert(id)
  }

  func finish(_ id: UUID) {
    guard held.contains(id), finished.insert(id).inserted else { return }
    #if os(iOS)
      if requiresScene {
        finishEndedUILifetime()
        for opportunity in scenes.values where opportunity.active { opportunity.link?.isEnabled = !finished.isEmpty }
        return
      }
    #endif
    // Standalone/headless owners and AppKit leave the constructor stack without
    // inventing a UIKit phase or waiting for remote browser readiness.
    guard deferredCompletion == nil else { return }
    deferredCompletion = Task { @MainActor [weak self] in
      guard let self else { return }
      deferredCompletion = nil; complete(finished)
    }
  }

  func abandon(_ id: UUID) {
    guard !finished.contains(id) else { return }
    held.remove(id)
  }

  private func complete(_ ids: Set<UUID>) {
    let completed = ids.intersection(finished)
    guard !completed.isEmpty else { return }
    let previous = availableCount
    held.subtract(completed); finished.subtract(completed)
    #if os(iOS)
      for opportunity in scenes.values {
        opportunity.committed.subtract(completed)
        if finished.isEmpty { opportunity.link?.isEnabled = false }
      }
    #endif
    publishAvailability(after: previous)
  }

  private func publishAvailability(after previous: Int) {
    if availableCount > previous { onAvailable(previous) }
  }

  isolated deinit {
    deferredCompletion?.cancel()
    #if os(iOS)
      for opportunity in scenes.values { opportunity.link?.isEnabled = false }
      for observer in observers { notifications.removeObserver(observer) }
    #endif
  }
}

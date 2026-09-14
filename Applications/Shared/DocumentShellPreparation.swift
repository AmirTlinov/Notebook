import Foundation
import WebKit
#if os(iOS)
import UIKit
#endif

/// One unused, body-free runtime belongs to the application, within the same
/// WebKit admission pool as real paper. Used document runtimes never return.
@MainActor
final class DocumentShellPreparation {
  struct Observation {
    let event: String
    let shellID: UUID
    let leaseID: UUID
    let webIdentity: String?
    let commonRuntimeReady: Bool
  }
  private struct Entry {
    let id = UUID()
    let coordinator: DocumentWebCoordinator
    let host: DocumentWebHost
    let leaseID: UUID
  }
  private let resources: SceneRenderResources
  private var entry: Entry?
  private var deferredAdmission: UInt64?
  private var failedThisForeground = false
  private var memoryObserver: NSObjectProtocol?
  private(set) var isStopped = false
  var onTransition: (Observation) -> Void = { _ in }
  var unusedCoordinator: DocumentWebCoordinator? { entry?.coordinator }

  init(resources: SceneRenderResources) {
    precondition(resources.documentShellPreparation == nil)
    self.resources = resources
    resources.documentShellPreparation = self
    #if os(iOS)
      memoryObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
        object: nil, queue: .main) { [weak self] _ in
          Task { @MainActor [weak self] in self?.retireUnused(suspendUntilAdmissionChanges: true) }
        }
    #endif
  }

  /// The model supplies the actual installed/foreground/idle opportunity.
  /// A refused optional grant retries only after capacity has improved.
  func prepareIfIdle() {
    guard !isStopped, !failedThisForeground, entry == nil,
      deferredAdmission != resources.webAdmissionGeneration else { return }
    guard let lease = resources.tryAcquireIdleWebSurface() else {
      deferredAdmission = resources.webAdmissionGeneration; return
    }
    deferredAdmission = nil
    let renderer = DocumentWebCoordinator(resources: resources, onRenderReady: .init { _ in },
      onPageLayout: { _ in }, onSourceChange: { _ in .targetMissing }, onStateChange: { _, _ in nil })
    let next = Entry(coordinator: renderer, host: DocumentWebHost(), leaseID: lease.id)
    entry = next
    renderer.onCommonRuntimeReady = { [weak self, weak renderer] in
      guard let self, let renderer, let current = entry, current.coordinator === renderer else { return }
      observe("ready", current)
    }
    renderer.onSurfaceRetirement = { [weak self, weak renderer] _ in
      guard let self, let renderer, let current = entry, current.coordinator === renderer else { return }
      // The renderer already owns native/source retirement and lease release.
      // Removing our host here cannot resurrect a failed optional preparation.
      entry = nil; failedThisForeground = true
      observe("failed", current)
    }
    renderer.prepareEmptyShell(in: next.host, lease: lease)
    lease.offerIdleReclamation { [weak self] in self?.retireUnused() }
    observe("started", next)
  }

  /// Retain the whole preparation host until the caller has synchronously
  /// configured and mounted this same coordinator in its real current host.
  @discardableResult
  func adoptForCurrentPage(_ adopt: (DocumentWebCoordinator) -> Void) -> Bool {
    guard !isStopped, let current = entry, current.coordinator.canAdoptEmptyShell else { return false }
    entry = nil
    current.coordinator.offerIdleReclamation(nil)
    current.coordinator.claimEmptyShell()
    observe("adopted", current)
    adopt(current.coordinator)
    withExtendedLifetime(current) { }
    return true
  }

  func retireUnused(suspendUntilAdmissionChanges: Bool = false) {
    guard let current = entry else {
      if suspendUntilAdmissionChanges { deferredAdmission = resources.webAdmissionGeneration }
      return
    }
    entry = nil
    current.coordinator.invalidate()
    current.host.removeSurface()
    if suspendUntilAdmissionChanges { deferredAdmission = resources.webAdmissionGeneration }
    observe("retired", current)
  }

  func allowPreparationAfterForeground() {
    deferredAdmission = nil; failedThisForeground = false
  }

  func stop() {
    guard !isStopped else { return }
    isStopped = true
    retireUnused()
    if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver); self.memoryObserver = nil }
    if resources.documentShellPreparation === self { resources.documentShellPreparation = nil }
    onTransition = { _ in }
  }

  private func observe(_ event: String, _ value: Entry) {
    onTransition(.init(event: event, shellID: value.id, leaseID: value.leaseID,
      webIdentity: value.coordinator.webView.map { String(describing: ObjectIdentifier($0)) },
      commonRuntimeReady: value.coordinator.commonRuntimeReady))
  }

  isolated deinit { stop() }
}

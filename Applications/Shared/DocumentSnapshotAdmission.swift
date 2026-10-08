import Foundation

/// A caller revokes its own snapshot claim synchronously, before its MainActor
/// cancellation callback can reach the shared physical producer.
final class DocumentSnapshotClaim: @unchecked Sendable {
  let purpose: @MainActor () -> ScenePreparationPurpose
  @MainActor weak var admission: DocumentSnapshotAdmission?
  private let lock = NSLock()
  private var cancelled = false
  @MainActor init(purpose: @escaping @MainActor () -> ScenePreparationPurpose) { self.purpose = purpose }
  func cancel() { lock.lock(); cancelled = true; lock.unlock() }
  var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// Admission belongs to the existing exact reader job. A required borrower
/// promotes that job for its remaining lifetime; an optional caller cannot
/// demote it, renew a revoked generation, or retire its live WebKit producer.
@MainActor
final class DocumentSnapshotAdmission {
  private let optionalGeneration: UInt64
  private var claims: [ObjectIdentifier: DocumentSnapshotClaim] = [:]
  private var required = false
  private(set) var submitted = false
  private(set) var withdrawn = false

  init(resources: SceneRenderResources) {
    optionalGeneration = resources.optionalPreparationGeneration
  }

  func add(_ claim: DocumentSnapshotClaim) throws {
    guard !withdrawn, !claim.isCancelled else { throw CancellationError() }
    claims[ObjectIdentifier(claim)] = claim
    claim.admission = self
    if claim.purpose() == .required { required = true }
  }

  func remove(_ claim: DocumentSnapshotClaim) {
    claims[ObjectIdentifier(claim)] = nil
    if claim.admission === self { claim.admission = nil }
  }

  func permitsCapture(resources: SceneRenderResources) -> Bool {
    guard !withdrawn else { return false }
    if required || submitted { return true }
    var hasActiveClaim = false
    for claim in claims.values where !claim.isCancelled {
      hasActiveClaim = true
      if claim.purpose() == .required { required = true; return true }
    }
    return hasActiveClaim && resources.allowsOptionalPreparation
      && resources.optionalPreparationGeneration == optionalGeneration
  }

  func requireCapture(resources: SceneRenderResources) throws {
    guard permitsCapture(resources: resources) else { throw CancellationError() }
  }

  /// Once physically submitted, the same reservation owns every snapshot/draw
  /// callback through completion. Pressure only withdraws unsubmitted work.
  func submit(resources: SceneRenderResources) throws {
    try requireCapture(resources: resources)
    submitted = true
  }

  func withdrawIfUnneeded(resources: SceneRenderResources) -> Bool {
    guard !submitted, !withdrawn, !permitsCapture(resources: resources) else { return false }
    withdrawn = true
    return true
  }

  /// Source replacement/retirement ends this exact job independently from
  /// pressure. A successor waits for its existing reader handle to drain.
  func retire() { withdrawn = true }
}

import Foundation
import NotebookCore

/// A terminal activation keeps its canonical origin, never a view's temporary
/// interaction flags or an earlier SwiftUI page-count projection.
@MainActor
struct DocumentLinkOrigin {
  let source: DocumentSourceSnapshot
  let state: DocumentStateSnapshot
  let runtimeID: UUID
  let generation: UInt64
  let renderToken: String
  let pageIndex: Int
  let presentationEpoch: UInt64

  var documentID: UUID { source.message.documentID }

  func hasSamePresentation(as other: Self) -> Bool {
    source === other.source && state === other.state && runtimeID == other.runtimeID
      && generation == other.generation && renderToken == other.renderToken
      && pageIndex == other.pageIndex && presentationEpoch == other.presentationEpoch
  }
}

@MainActor
struct DocumentLinkActivation {
  let origin: DocumentLinkOrigin
  let destination: DocumentLinkDestination
  private let externalAuthority: ExternalAuthority?

  init(origin: DocumentLinkOrigin, destination: DocumentLinkDestination) {
    self.origin = origin; self.destination = destination; externalAuthority = nil
  }

  /// Only a native input owner calls this after admitting a real contact. A
  /// href resolver and a page-world message never confer external authority.
  static func admitted(origin: DocumentLinkOrigin, destination: DocumentLinkDestination,
    admittedAt: ContinuousClock.Instant = .now, isCurrent: @escaping @MainActor () -> Bool) -> Self {
    .init(origin: origin, destination: destination,
      externalAuthority: .init(admittedAt: admittedAt, isCurrent: isCurrent))
  }

  private init(origin: DocumentLinkOrigin, destination: DocumentLinkDestination,
    externalAuthority: ExternalAuthority) {
    self.origin = origin; self.destination = destination; self.externalAuthority = externalAuthority
  }

  /// Consume at the stable model's external-open boundary, after its current
  /// document/presence checks. Copies of this value share the same one-shot.
  func consumeExternalAuthority() -> Bool { externalAuthority?.consume() == true }

  @MainActor private final class ExternalAuthority {
    let admittedAt: ContinuousClock.Instant
    let isCurrent: @MainActor () -> Bool
    private var consumed = false
    init(admittedAt: ContinuousClock.Instant, isCurrent: @escaping @MainActor () -> Bool) {
      self.admittedAt = admittedAt; self.isCurrent = isCurrent
    }
    func consume() -> Bool {
      guard !consumed else { return false }
      consumed = true
      return admittedAt.duration(to: .now) <= .seconds(10) && isCurrent()
    }
  }
}

/// Captured by the native presentation owner while new input is admitted.
/// Completion checks its physical installation, independent of later policy.
@MainActor
struct DocumentLinkAdmission {
  let origin: DocumentLinkOrigin
  let isCurrent: @MainActor () -> Bool
  let admittedAt: ContinuousClock.Instant
  init(origin: DocumentLinkOrigin, admittedAt: ContinuousClock.Instant = .now,
    isCurrent: @escaping @MainActor () -> Bool) {
    self.origin = origin; self.admittedAt = admittedAt; self.isCurrent = isCurrent
  }
}

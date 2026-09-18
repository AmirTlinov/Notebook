import Foundation

/// A transient request, never evidence that its page has been reached.
struct DocumentPageNavigationRequest: Equatable {
  static let maximumPageIndex = 100_000
  let id: UUID
  let documentID: UUID
  let sourceRevision: String
  let pageIndex: Int
}

struct DocumentPageLanding {
  let controllerID: UUID
  let documentID: UUID
  let sourceRevision: String
  let revision: UInt64
  let pageIndex: Int
  let requestID: UUID?
}

@MainActor
struct PageTurnPreparationFailure {
  enum Kind: Equatable { case resourceLimit, snapshotPending, preparationFailed }
  let id = UUID()
  var kind: Kind = .preparationFailed
  let message: String
  let retry: @MainActor () -> Void
}

@MainActor
struct DocumentPageNavigationStatus {
  enum Phase: Equatable { case preparing, transitioning, failed }
  let controllerID: UUID
  let documentID: UUID
  let sourceRevision: String
  let revision: UInt64
  let requestID: UUID?
  let target: Int?
  let phase: Phase?
  let failure: PageTurnPreparationFailure?
}

/// The model receives facts from the currently bound native controller. These
/// callbacks do not make SwiftUI, presence or the renderer another turn owner.
@MainActor
struct DocumentPageNavigationCallbacks {
  let bind: (UUID, UUID, String) -> Void
  let unbind: (UUID) -> Void
  let landed: (DocumentPageLanding) -> Void
  let status: (DocumentPageNavigationStatus) -> Void
}

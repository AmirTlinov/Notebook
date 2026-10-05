import Foundation
import NotebookCore
import Observation

/// One device's pending request and the exact native controller admitted to
/// complete it. Revisions belong to that binding and disappear with it.
@MainActor @Observable
final class DocumentPageNavigation {
  private struct Binding {
    let id: UUID
    let documentID: UUID
    let source: String
    var landingRevision: UInt64 = 0
    var statusRevision: UInt64 = 0
  }
  private(set) var request: DocumentPageNavigationRequest?
  private(set) var status: DocumentPageNavigationStatus?
  @ObservationIgnored private var binding: Binding?

  static func sourceRevision(_ document: DocumentDocument) -> String {
    "\(document.contentStamp.actor):\(document.contentStamp.counter)"
  }

  /// Returns whether a new preparation was requested. Presence changes only
  /// when the mounted controller reports its actual landing.
  func select(_ page: Int, documentID: UUID, source: String, currentPage: Int) -> Bool {
    if page == currentPage, request == nil { if status != nil { status = nil }; return false }
    if request?.pageIndex == page, request?.documentID == documentID, request?.sourceRevision == source { return false }
    status = nil
    request = .init(id: UUID(), documentID: documentID, sourceRevision: source, pageIndex: page)
    return true
  }

  func bind(_ id: UUID, documentID: UUID, source: String) {
    guard binding?.id != id || binding?.documentID != documentID || binding?.source != source else { return }
    binding = .init(id: id, documentID: documentID, source: source)
  }

  func unbind(_ id: UUID) { if binding?.id == id { binding = nil } }

  func accepts(_ id: UUID, documentID: UUID, source: String) -> Bool {
    binding?.id == id && binding?.documentID == documentID && binding?.source == source
  }

  func landed(_ landing: DocumentPageLanding) -> Bool {
    guard accepts(landing.controllerID, documentID: landing.documentID, source: landing.sourceRevision),
      let binding, landing.revision > binding.landingRevision,
      (0...DocumentPageNavigationRequest.maximumPageIndex).contains(landing.pageIndex) else { return false }
    self.binding?.landingRevision = landing.revision
    // A remains a real landing after B supersedes it; it cannot clear B.
    if request?.id == landing.requestID { cancel() }
    return true
  }

  func receive(_ value: DocumentPageNavigationStatus) {
    guard accepts(value.controllerID, documentID: value.documentID, source: value.sourceRevision),
      let binding, value.revision > binding.statusRevision else { return }
    self.binding?.statusRevision = value.revision
    guard value.requestID == request?.id else { return }
    status = value.target == nil ? nil : value
  }

  func cancel() {
    // Replayed readiness must not invalidate Observation through nil -> nil.
    if request != nil { request = nil }
    if status != nil { status = nil }
  }

  func ownerChanged() { cancel(); binding = nil }

  func validate(_ documents: [UUID: DocumentDocument]) {
    if let request, documents[request.documentID].map(Self.sourceRevision) != request.sourceRevision { cancel() }
    if let binding, documents[binding.documentID].map(Self.sourceRevision) != binding.source {
      self.binding = nil
      if status != nil { status = nil }
    }
  }
}

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
  let id: UUID
  let kind: Kind
  let requiresCapture: Bool
  let message: String
  let retry: @MainActor () -> Void

  init(id: UUID = UUID(), kind: Kind = .preparationFailed, requiresCapture: Bool = false, message: String,
    retry: @escaping @MainActor () -> Void) {
    self.id = id; self.kind = kind; self.requiresCapture = requiresCapture
    self.message = message; self.retry = retry
  }
}

/// A missing first frame is ordinary waiting. Only an explicit failure from
/// the currently mounted page can pause its caller and expose the owner's Retry.
@MainActor
enum PageTurnPreparationState {
  case waiting, ready, failed(PageTurnPreparationFailure)
  var isReady: Bool { if case .ready = self { true } else { false } }
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
  #if os(iOS)
  var retainSource: () -> DocumentTurnSourceLease? = { nil }
  var resolveSourceLanding: (DocumentTurnSourceLease, Int) async throws -> Int = { _, page in page }
  #endif
}

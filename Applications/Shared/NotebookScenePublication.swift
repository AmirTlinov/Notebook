import Foundation
import NotebookCore
import Observation

/// Owns the lifetime from one immutable scene demand to its admitted geometry.
/// Input and peer owners grant publication; they never take over its worker.
@MainActor @Observable
final class NotebookScenePublication {
  enum Installation {
    case full
    case coverage(loadsDocument: Bool, preservesDocumentDraft: Bool)
    var isCoverageOnly: Bool { if case .coverage = self { return true }; return false }
  }

  private(set) var sourceHeader: NotebookWorkspaceHeader?
  private(set) var sourceGeneration: UInt64 = 0
  private(set) var pinnedElementSources: [EditableElementReference: NotebookNativeElementSource] = [:]

  /// Every completed read installs its header, frontier and bounded bodies in
  /// one MainActor segment. A durable header-only observation never enters
  /// this boundary, and an older callback cannot roll the source cut back.
  @discardableResult
  func install(_ state: NotebookSceneState, as mode: Installation,
    bodies: (_ mode: Installation) -> Void) -> Bool {
    if let previous = sourceHeader {
      guard previous.workspaceID == state.header.workspaceID,
        state.header.cursor >= previous.cursor else { return false }
    }
    sourceHeader = state.header
    pinnedElementSources = state.pinnedElementSources
    bodies(mode)
    sourceGeneration &+= 1
    return true
  }

  private struct Input: Sendable {
    let workspace: WorkspaceIndex
    let hierarchy: BoardHierarchy
    let paperSizes: [UUID: WorkspaceItemGeometry]
  }
  private enum Content {
    case requested(Input)
    case prepared(WorkspaceSceneIndex, [UUID: BoardPortalCamera])
  }
  private struct Request {
    let id: UInt64
    let coverageOnly: Bool
    var content: Content
  }
  private struct Result: Sendable {
    let index: WorkspaceSceneIndex
    let portals: [UUID: BoardPortalCamera]
    let began: ContinuousClock.Instant?
    let ended: ContinuousClock.Instant?
  }
  private struct Job {
    let request: UInt64
    let task: Task<Result, Never>
  }

  private(set) var index: WorkspaceSceneIndex?
  private(set) var portals: [UUID: BoardPortalCamera] = [:]
  private(set) var indexGeneration: UInt64 = 0
  private(set) var publicationGeneration: UInt64 = 0
  private(set) var isPending = false
  @ObservationIgnored private(set) var isCoverageOnly = false
  @ObservationIgnored private var request: Request?
  @ObservationIgnored private var nextRequest: UInt64 = 0
  @ObservationIgnored private var driver: Task<Void, Never>?
  @ObservationIgnored var onPrepared: (() -> Void)?
  private let actorID: UUID

  init(actorID: UUID) { self.actorID = actorID }

  func prepare(workspace: WorkspaceIndex, hierarchy: BoardHierarchy,
    paperSizes: [UUID: WorkspaceItemGeometry], coverageOnly: Bool) {
    nextRequest &+= 1
    request = .init(id: nextRequest, coverageOnly: coverageOnly,
      content: .requested(.init(workspace: workspace, hierarchy: hierarchy, paperSizes: paperSizes)))
    isPending = true; isCoverageOnly = coverageOnly
    observe("scene_index_requested", request: nextRequest)
    guard driver == nil else { return }
    // Dispatch the first accepted cut now. Once shown, synchronous edits share
    // the next UI delivery entry and only the newest immutable input is built.
    let first = index == nil ? makeJob() : nil
    driver = Task { [weak self] in
      var pending = first
      if pending == nil {
        guard let self, !Task.isCancelled else { return }
        pending = makeJob()
      }
      guard var job = pending else {
        self?.driver = nil
        self?.onPrepared?()
        return
      }
      while true {
        // Cancellation before the first UI entry still joins the dispatched
        // worker. The caller draining this driver owns that complete lifetime.
        let result = await job.task.value
        guard let self else { return }
        if let began = result.began, let ended = result.ended {
          observe("scene_index_began", request: job.request, at: began)
          observe("scene_index_ended", request: job.request, at: ended)
          observe("scene_index_delivered", request: job.request)
        }
        guard !Task.isCancelled else { return }
        if request?.id == job.request {
          request?.content = .prepared(result.index, result.portals)
          driver = nil
          onPrepared?()
          return
        }
        // An addressed read may already have supplied the newer prepared cut.
        guard let next = makeJob() else {
          driver = nil
          onPrepared?()
          return
        }
        job = next
      }
    }
  }

  func accept(_ index: WorkspaceSceneIndex, hierarchy: BoardHierarchy, coverageOnly: Bool) {
    nextRequest &+= 1
    request = .init(id: nextRequest, coverageOnly: coverageOnly,
      content: .prepared(index, Dictionary(uniqueKeysWithValues: hierarchy.boards.map { ($0.id, $0.portalCamera) })))
    isPending = true; isCoverageOnly = coverageOnly
    onPrepared?()
  }

  func publish(if permitsChange: (_ coverageOnly: Bool) -> Bool) {
    guard let request, case .prepared(let candidate, let portals) = request.content else { return }
    let accepted = candidate.retainingSourceGeneration(from: index)
    let changed = index?.generationID != accepted.generationID
    guard !changed || permitsChange(request.coverageOnly) else { return }
    self.portals = portals; index = accepted
    if changed { indexGeneration &+= 1 }
    self.request = nil; isPending = false
    publicationGeneration &+= 1
    observe("scene_index_published", request: request.id)
  }

  func updatePortalCamera(_ camera: BoardPortalCamera, boardID: UUID) { portals[boardID] = camera }

  /// Returns the owned driver so app shutdown can join it with its other reads.
  /// A late completed worker cannot publish or clear a subsequently started job.
  func cancel() -> Task<Void, Never>? {
    let pending = driver
    pending?.cancel(); driver = nil
    request = nil; isPending = false
    return pending
  }

  private func makeJob() -> Job? {
    guard let request, case .requested(let input) = request.content else { return nil }
    let previous = index
    let observes = NotebookNavigationObservation.onWebPreparation != nil
    let dispatched: ContinuousClock.Instant? = observes ? .now : nil
    let task = Task.detached(priority: .utility) {
      let began: ContinuousClock.Instant? = observes ? .now : nil
      let portals = Dictionary(uniqueKeysWithValues: input.hierarchy.boards.map { ($0.id, $0.portalCamera) })
      let index = WorkspaceSceneIndex(workspace: input.workspace, hierarchy: input.hierarchy,
        paperSizes: input.paperSizes, reusing: previous)
      let ended: ContinuousClock.Instant? = observes ? .now : nil
      return Result(index: index, portals: portals, began: began, ended: ended)
    }
    if let dispatched { observe("scene_index_dispatched", request: request.id, at: dispatched) }
    return .init(request: request.id, task: task)
  }

  private func observe(_ event: String, request: UInt64, at time: ContinuousClock.Instant? = nil) {
    guard NotebookNavigationObservation.onWebPreparation != nil else { return }
    NotebookNavigationObservation.webPreparation(event, ownerID: actorID, sourceID: String(request), at: time ?? .now)
  }
}

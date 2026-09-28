import NotebookCore
import SwiftUI
import UIKit

@MainActor @Observable
final class CameraGestureSnapshot {
  let id=UUID()
  let presence: SessionPresence
  var rollback: SessionPresence?
  var continuesPartialPassage = false
  @ObservationIgnored var interruptedPortal: (UUID, BoardPortalCamera)?
  let trajectory: CameraGestureTrajectory
  let entry: NotebookZoomPassage?
  let exit: NotebookZoomPassage?
  var passage: NotebookZoomPassage?
  var documentPageIndex: Int
  @ObservationIgnored var choseDirection = false
  @ObservationIgnored var latestCamera: SpatialCamera
  @ObservationIgnored var preparedItem = false
  @ObservationIgnored var magnification:CGFloat = 1
  @ObservationIgnored var centroid:CGPoint
  @ObservationIgnored var paperReadiness: PageTurnPreparationSource?
  var partialProgress: Double? {
    guard continuesPartialPassage, let passage else { return nil }
    let span = log(passage.openScale / passage.closedScale)
    guard span.isFinite, span > 0 else { return presence.openProgress }
    return min(1, max(0, presence.openProgress + log(max(0.001, Double(magnification))) / span))
  }
  var passageCamera:SpatialCamera? { passage.map { $0.camera(from:trajectory,magnification:magnification,centroid:centroid) } }
  init(presence:SessionPresence,trajectory:CameraGestureTrajectory,entry:NotebookZoomPassage?,exit:NotebookZoomPassage?) {
    self.presence=presence;self.trajectory=trajectory;self.entry=entry;self.exit=exit;latestCamera=presence.camera;centroid=trajectory.startingCentroid;documentPageIndex=presence.documentPageIndex
  }
  var preparation: SessionPresence? {
    guard let passage,let camera=passageCamera else { return nil }
    return passage.presentation(camera:camera,viewport:presence.viewport,page:documentPageIndex)
  }
}

@MainActor @Observable
final class WorkspaceSettlement {
  let id=UUID()
  let origin:SessionPresence
  let target:SessionPresence
  let handoff:SessionPresence?
  let approach:SessionPresence?
  @ObservationIgnored private(set) var approached = false
  var isApproaching:Bool { approach != nil && !approached }
  var destination:SessionPresence { approached ? target : approach ?? target }
  var stageDuration:TimeInterval { approach == nil ? duration : duration / 2 }
  var preparation:SessionPresence { handoff ?? target }
  @ObservationIgnored var paperReadiness: PageTurnPreparationSource?
  var cameraIsMoving = false
  let duration:TimeInterval
  let bounce:Double
  let navigationID:UUID?
  let portal:(UUID,BoardPortalCamera)?
  private var completion:(()->Void)?
  private(set) var outcome: SceneCameraSettlement.Outcome?
  @ObservationIgnored var started=false
  init(origin:SessionPresence,target:SessionPresence,handoff:SessionPresence?,approach:SessionPresence?,duration:TimeInterval,bounce:Double,navigationID:UUID?,
    portal:(UUID,BoardPortalCamera)?,completion:@escaping ()->Void) {
    self.origin=origin;self.target=target;self.handoff=handoff;self.approach=approach;self.duration=duration;self.bounce=bounce;self.navigationID=navigationID
    self.portal=portal;self.completion=completion
  }
  func resolve(_ outcome: SceneCameraSettlement.Outcome) {
    guard self.outcome == nil else { return }
    self.outcome = outcome
    let callback = completion; completion = nil; paperReadiness = nil
    if outcome == .completed { callback?() }
  }
  func finishApproach() { approached=true;started=false;cameraIsMoving=false }
}

enum WorkspaceNavigationState {
  case idle, interacting(CameraGestureSnapshot), settling(WorkspaceSettlement)
}

/// Owns the entire camera transition: preparation, movement, handoff, interruption
/// and waiters. SwiftUI supplies semantic destinations and renders this state.
@MainActor @Observable
final class WorkspaceCameraOwner {
  private(set) var state = WorkspaceNavigationState.idle
  private(set) var failure: PageTurnPreparationFailure?
  private(set) var panStart: SessionPresence?
  private(set) var activePageTurns: Set<UUID> = []
  @ObservationIgnored private weak var model: NotebookAppModel?
  @ObservationIgnored private let movement = SceneCameraSettlement()
  @ObservationIgnored private var readiness: (PageTurnPreparationSource, UUID)?
  @ObservationIgnored private var idleWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
  @ObservationIgnored private var advanceTask: Task<Void, Never>?
  var gesture: CameraGestureSnapshot? { if case .interacting(let value) = state { value } else { nil } }
  var settling: Bool { if case .settling = state { true } else { false } }
  var isIdle: Bool { if case .idle = state { panStart == nil && activePageTurns.isEmpty } else { false } }
  var contentGestureActive: Bool { settling || gesture.map { $0.presence.mode == .page || $0.presence.mode == .document } == true }
  var id: UUID? { switch state { case .idle: nil; case .interacting(let value): value.id; case .settling(let value): value.id } }

  func attach(_ model: NotebookAppModel) { self.model = model }
  func detach() {
    model = nil
    interrupt(outcome: .cancelled, settlesPose: false)
    panStart = nil; activePageTurns.removeAll(); model = nil
    finishWaiters(false)
  }
  func beginPan(_ presence: SessionPresence?) { panStart = presence }
  func endPan() { panStart = nil; notifyIdle() }
  func pageTurnChanged(owner: UUID, active: Bool) {
    if active { activePageTurns.insert(owner) } else { activePageTurns.remove(owner) }
    notifyIdle()
  }
  func beginGesture(_ snapshot: CameraGestureSnapshot) {
    endCurrent(outcome: .superseded, settlesPose: false, notifyingIdle: false)
    failure = nil
    panStart = nil; state = .interacting(snapshot)
    observe(snapshot.paperReadiness)
  }
  func finishGesture() {
    guard gesture != nil else { return }
    clearReadiness(); state = .idle; notifyIdle()
  }

  func bindPaperReadiness(itemID: UUID, transitionID: UUID?, source: PageTurnPreparationSource) {
    guard transitionID == id else { return }
    switch state {
    case .interacting(let snapshot):
      guard snapshot.passage?.itemID == itemID else { return }; snapshot.paperReadiness = source
    case .settling(let pending):
      guard pending.target.focusedItemID == itemID else { return }; pending.paperReadiness = source
    case .idle: return
    }
    observe(source)
    preparationChanged()
  }
  private func observe(_ source: PageTurnPreparationSource?) {
    if let source, readiness?.0 === source { return }
    clearReadiness()
    if let source { readiness = (source, source.observe { [weak self] in self?.preparationChanged() }) }
  }
  private func clearReadiness() {
    if let (source, token) = readiness { source.removeObserver(token) }
    readiness = nil; advanceTask?.cancel(); advanceTask = nil
  }
  /// Coalesces actual owner events after native layout completes. This is not a
  /// retry clock: without a new source/cohort event there is no further work.
  func preparationChanged() {
    guard advanceTask == nil else { return }
    advanceTask = Task { @MainActor [weak self] in
      guard !Task.isCancelled, let self else { return }
      advanceTask = nil; advance()
    }
  }
  func hasPreparedSurface(_ target: SessionPresence, refinesDetails: Bool = false) -> Bool {
    guard let model, let cohort = model.compositionTiles.published,
      cohort.plan.presentations[.board(target.boardID)] != nil else { return false }
    if let item = target.focusedItemID {
      guard cohort.plan.allowsLive(.item(item), in: .board(target.boardID)) else { return false }
      if (model.workspace?.item(id: item)?.kind ?? cohort.frame.index.item(id: item)?.kind) == .board,
        target.openProgress > 0 { return cohort.plan.presentations[.board(item)] != nil }
      if target.mode == .page || target.mode == .document {
        switch state {
        case .settling(let pending): return pending.paperReadiness?.state(refinesDetails: refinesDetails).isReady == true
        case .interacting(let snapshot): return snapshot.paperReadiness?.state(refinesDetails: false).isReady == true
        case .idle: return false
        }
      }
    }
    return true
  }
  private func isPrepared(_ pending: WorkspaceSettlement) -> Bool {
    if pending.isApproaching { return hasPreparedSurface(pending.destination) }
    let stationary = model?.presence.map { $0.boardID == pending.target.boardID
      && $0.camera == pending.target.camera && $0.viewport == pending.target.viewport } == true
    return hasPreparedSurface(pending.preparation, refinesDetails: stationary)
      && hasPreparedSurface(pending.target, refinesDetails: stationary)
  }
  func cancelUnavailable(_ pending: WorkspaceSettlement) {
    guard current(pending), let model else { return }
    finish(pending, .cancelled)
    model.cancelRequestedNavigation()
    model.updatePresence(pending.origin, settled: true)
    model.showCue("Переход отменён: объект больше недоступен.")
  }
  private func advance() {
    guard let model else { return }
    if case .settling(let pending) = state, !pending.started {
      if pending.paperReadiness?.isRetired == true { cancelUnavailable(pending); return }
      if let item = pending.preparation.focusedItemID, model.isItemBeingDeleted(item) { cancelUnavailable(pending); return }
      if case .failed(let failure) = pending.paperReadiness?.state(refinesDetails: false) {
        let target = pending.target, duration = pending.duration, bounce = pending.bounce
        let portal = pending.portal, handoff = pending.handoff, origin = pending.origin
        finish(pending, .failed)
        model.updatePresence(origin, settled: true)
        model.cancelRequestedNavigation()
        self.failure = .init(id: failure.id, kind: failure.kind, message: failure.message) { [weak self, weak model] in
          guard let self, let model, self.failure?.id == failure.id else { return }
          self.failure = nil; failure.retry()
          if target.mode == .document, let document = target.focusedItemID {
            model.selectItem(document)
            model.prepareDocumentOpening(document, pageIndex: target.documentPageIndex,
              boardID: target.boardID, restoreReading: false)
          }
          settle(to: target, duration: duration, bounce: bounce, navigationID: nil,
            portal: portal, handoff: handoff, rollback: origin, completion: {})
        }
        return
      }
      if isPrepared(pending) { start(pending) }
      else if model.compositionTiles.failure != nil || model.persistenceFailure != nil {
        finish(pending, .failed)
        model.updatePresence(pending.origin, settled: true)
        model.cancelRequestedNavigation()
        model.showCue("Не удалось подготовить переход. Исходное место сохранено; попробуйте ещё раз.")
      }
    } else if let snapshot = gesture, let passage = snapshot.passage, let camera = snapshot.passageCamera,
      passage.returningPortal != nil, passage.progress(camera: camera) < 1 {
      let shown = passage.presentation(camera: camera, viewport: snapshot.presence.viewport)
      if hasPreparedSurface(shown), model.presence?.boardID != shown.boardID { model.updatePresence(shown, settled: false) }
    }
  }

  @discardableResult
  func interrupt(outcome: SceneCameraSettlement.Outcome = .cancelled, settlesPose: Bool = true) -> SessionPresence? {
    endCurrent(outcome: outcome, settlesPose: settlesPose, notifyingIdle: true)
  }
  @discardableResult
  private func endCurrent(outcome: SceneCameraSettlement.Outcome, settlesPose: Bool,
    notifyingIdle: Bool) -> SessionPresence? {
    let pose: SessionPresence?
    switch state {
    case .idle: pose = nil
    case .interacting: pose = model?.presence
    case .settling(let pending): pose = pending.started || pending.approached ? model?.presence : pending.origin
    }
    let pending: WorkspaceSettlement? = if case .settling(let value) = state { value } else { nil }
    state = .idle; clearReadiness()
    movement.cancel(outcome: outcome); pending?.resolve(outcome)
    if let pose, settlesPose { model?.updatePresence(pose, settled: true) }
    if notifyingIdle { notifyIdle() }
    return pose
  }
  private func current(_ pending: WorkspaceSettlement) -> Bool {
    if case .settling(let active) = state { active === pending } else { false }
  }
  private func finish(_ pending: WorkspaceSettlement, _ outcome: SceneCameraSettlement.Outcome) {
    guard current(pending) else { return }
    state = .idle; clearReadiness(); movement.cancel(outcome: outcome)
    pending.resolve(outcome); notifyIdle()
  }
  private func closedApproach(to target: SessionPresence, from origin: SessionPresence) -> SessionPresence? {
    guard let model, target.mode == .page || target.mode == .document, let item = target.focusedItemID else { return nil }
    let positionsClosedDocument = target.mode == .document && origin.openProgress == 0
      && (origin.boardID != target.boardID || origin.camera != target.camera || origin.viewport != target.viewport)
    if !positionsClosedDocument, origin.boardID == target.boardID,
      let center = model.boardHierarchy?.focusedCenter(of: item, in: target.boardID) {
      let rect = model.itemGeometry(item).screenFrame(center: center, camera: origin.camera, viewport: origin.viewport)
      if rect.x < origin.viewport.x, rect.y < origin.viewport.y, rect.x + rect.width > 0, rect.y + rect.height > 0 { return nil }
    }
    return .init(boardID: target.boardID, mode: .cover, camera: target.camera, viewport: target.viewport,
      focusedItemID: item, openProgress: 0, documentPageIndex: target.documentPageIndex,
      selectedItemID: target.selectedItemID, notebookPageID: target.notebookPageID)
  }
  func settle(to target: SessionPresence, duration: TimeInterval, bounce: Double, navigationID: UUID?,
    portal: (UUID, BoardPortalCamera)?, handoff: SessionPresence?, rollback: SessionPresence?, completion: @escaping () -> Void) {
    guard let model, let origin = model.presence else { return }
    let destination: SessionPresence
    if target.mode == .page, target.notebookPageID == nil, let item = target.focusedItemID, item == origin.selectedItemID {
      destination = target.selecting(itemID: item, pageID: origin.notebookPageID)
    } else { destination = target }
    endCurrent(outcome: .superseded, settlesPose: false, notifyingIdle: false); panStart = nil; failure = nil
    let pending = WorkspaceSettlement(origin: rollback ?? origin, target: destination, handoff: handoff,
      approach: closedApproach(to: destination, from: origin), duration: duration, bounce: bounce,
      navigationID: navigationID, portal: portal, completion: completion)
    state = .settling(pending)
    model.updatePresence(origin, settled: false)
    if isPrepared(pending) { start(pending) }
  }
  private func start(_ pending: WorkspaceSettlement) {
    guard current(pending), !pending.started, let model, let actual = model.presence else { return }
    pending.started = true
    let approaching = pending.isApproaching
    var start = actual.boardID == pending.target.boardID ? actual : pending.handoff ?? actual
    if approaching {
      start = .init(boardID: start.boardID, mode: start.focusedItemID == nil ? .board : .cover,
        camera: start.camera, viewport: start.viewport, focusedItemID: start.focusedItemID, openProgress: 0,
        documentPageIndex: start.documentPageIndex, selectedItemID: start.selectedItemID, notebookPageID: start.notebookPageID)
    }
    if start != actual { model.updatePresence(start, settled: false) }
    let target = pending.destination
    let retainsNotebook = start.mode == .page && target.mode == .page && start.focusedItemID == target.focusedItemID
    let destination = retainsNotebook ? target.selecting(itemID: start.selectedItemID, pageID: start.notebookPageID) : target
    pending.cameraIsMoving = start.camera != destination.camera || start.boardID != destination.boardID || start.viewport != destination.viewport
    movement.start(from: start, to: destination, duration: pending.stageDuration, bounce: pending.bounce,
      navigationID: pending.navigationID) { [weak self, weak pending, weak model] presence, settled in
      guard let self, let pending, let model, current(pending) else { return }
      var transaction = Transaction(); transaction.disablesAnimations = true
      withTransaction(transaction) {
        let sample = retainsNotebook ? presence.selecting(itemID: model.presence?.selectedItemID, pageID: model.presence?.notebookPageID) : presence
        model.updatePresence(sample, settled: settled && !approaching)
      }
    } completion: { [weak self, weak pending, weak model] outcome in
      guard let self, let pending, current(pending) else { return }
      guard outcome == .completed else {
        finish(pending, outcome)
        if outcome == .failed { model?.updatePresence(pending.origin, settled: true) }
        return
      }
      if approaching { pending.finishApproach(); advance() }
      else { finish(pending, .completed) }
    }
  }

  func waitUntilIdle() async -> Bool {
    while !Task.isCancelled, model != nil {
      if isIdle { return true }
      let token = UUID()
      let completed = await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
          if Task.isCancelled || model == nil { continuation.resume(returning: false) }
          else if isIdle { continuation.resume(returning: true) }
          else { idleWaiters[token] = continuation }
        }
      } onCancel: { Task { @MainActor [weak self] in self?.idleWaiters.removeValue(forKey: token)?.resume(returning: false) } }
      guard completed else { return false }
      // An idle event can be followed by a new gesture/settlement before this
      // continuation resumes. Rejoin that owner instead of admitting navigation
      // on an obsolete event; only another owner event can wake it again.
    }
    return false
  }
  private func notifyIdle() { if isIdle, model != nil { finishWaiters(true) } }
  private func finishWaiters(_ completed: Bool) {
    let waiters = idleWaiters.values; idleWaiters.removeAll()
    for waiter in waiters { waiter.resume(returning: completed) }
  }
  isolated deinit { movement.cancel(); clearReadiness(); finishWaiters(false) }
}

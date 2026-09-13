import Foundation
import NotebookCore
import Observation

/// The foreground iPad owns the lifetime of a transient explanation. Camera
/// samples still belong to SessionPresence and the scene's existing settlement.
@MainActor @Observable
final class NotebookPresentationPlayer {
  struct Stage: Identifiable {
    let id = UUID()
    let requestID: UUID
    let step: NotebookPresentationStep
  }
  private(set) var stage: Stage?
  private(set) var isFading = false
  @ObservationIgnored var currentView: (() -> (UUID, PresenceEnvelope)?)?
  @ObservationIgnored var isInputActive: (() -> Bool)?
  @ObservationIgnored var moveCamera: ((SpatialCamera, Double) -> Bool)?
  @ObservationIgnored var stopCamera: (() -> Void)?
  @ObservationIgnored var reply: ((NotebookPresentationReceipt, UUID) -> Void)?
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var active: (NotebookPresentationRequest, UUID)?
  @ObservationIgnored private var stepIndex = 0
  @ObservationIgnored private var renderedStage: UUID?
  @ObservationIgnored private var history: [UUID: (String, NotebookPresentationReceipt)] = [:]
  @ObservationIgnored private var order: [UUID] = []
  var isActive: Bool { active != nil }

  func receive(_ message: NotebookPresentationMessage, peer: UUID, now: Date = Date()) {
    switch message {
    case .receipt: return
    case .cancel(let id, let session):
      guard currentView?()?.1.sessionID == session else { return }
      if active?.0.id == id, active?.1 == peer { interrupt("cancelled") }
      else { reply?(.init(id: id, status: .interrupted, reason: "cancelled_before_start"), peer) }
    case .play(let request, let expiry):
      guard request.isValid, let digest = try? NotebookPresentationRelay.digest(request) else {
        reply?(.init(id: request.id, status: .rejected, reason: "invalid_presentation"), peer); return
      }
      if let previous = history[request.id] {
        reply?(previous.0 == digest ? previous.1 : .init(id: request.id, status: .rejected, reason: "presentation_id_conflict"), peer)
        return
      }
      let current = currentView?()
      let reason: String?
      if expiry < now || expiry.timeIntervalSince(now) > 6 { reason = "expired" }
      else if current?.0 != request.view.deviceID || current?.1.sessionID != request.view.sessionID
        || current?.1.sequence != request.view.sequence || current?.1.phase != .settled { reason = "view_changed" }
      else if moveCamera == nil { reason = "scene_not_visible" }
      else if isInputActive?() != false { reason = "input_active" }
      else if active != nil { reason = "presentation_busy" }
      else { reason = nil }
      let receipt = NotebookPresentationReceipt(id: request.id, status: reason == nil ? .sent : .rejected, reason: reason)
      history[request.id] = (digest, receipt); order.append(request.id)
      while order.count > 64 { history.removeValue(forKey: order.removeFirst()) }
      reply?(receipt, peer)
      guard reason == nil else { return }
      active = (request, peer)
      task = Task { [weak self] in await self?.play(request) }
    }
  }

  func rendered(_ id: UUID) { if stage?.id == id { renderedStage = id } }
  func failed(_ id: UUID) { if stage?.id == id { finish(.rejected, reason: "svg_render_failed") } }

  private func play(_ request: NotebookPresentationRequest) async {
    do {
      for (index, step) in request.steps.enumerated() {
        try Task.checkCancellation()
        guard active?.0.id == request.id, isInputActive?() == false,
          let presence = currentView?()?.1.presence else { interrupt("input_active"); return }
        stepIndex = index; isFading = false; renderedStage = nil
        let next = Stage(requestID: request.id, step: step)
        stage = next
        if let camera = step.camera ?? step.focus?.fittedCamera(viewport: presence.viewport) {
          guard moveCamera?(camera, step.transition) == true else { finish(.rejected, reason: "camera_unavailable"); return }
        }
        if step.svg != nil {
          let deadline = ContinuousClock.now.advanced(by: .seconds(3))
          while renderedStage != next.id {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { finish(.rejected, reason: "svg_not_ready"); return }
            try await Task.sleep(for: .milliseconds(20))
          }
        }
        publish(.playing)
        try await Task.sleep(for: .seconds(step.duration - 0.25))
        isFading = true
        try await Task.sleep(for: .milliseconds(250))
      }
      finish(.completed)
    } catch { /* The explicit interruption already published the final receipt. */ }
  }

  func interrupt(_ reason: String = "human_input") {
    guard active != nil else { return }
    finish(.interrupted, reason: reason)
  }

  func disconnected(_ peer: UUID) {
    if active?.1 == peer { interrupt("connection_lost") }
  }

  private func publish(_ status: NotebookPresentationReceipt.Status, reason: String? = nil) {
    guard let (request, peer) = active else { return }
    let receipt = NotebookPresentationReceipt(id: request.id, status: status, step: stepIndex, reason: reason)
    history[request.id]?.1 = receipt
    reply?(receipt, peer)
  }

  private func finish(_ status: NotebookPresentationReceipt.Status, reason: String? = nil) {
    publish(status, reason: reason)
    task?.cancel(); task = nil
    stopCamera?()
    stage = nil; renderedStage = nil; isFading = false; active = nil
  }
}

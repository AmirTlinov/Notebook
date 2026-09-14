import Foundation
import os

/// One configured page attempt, independent from historical source preparation.
/// Native phase values are elapsed milliseconds from configuredAt (system uptime).
/// Browser observations retain their separate per-call elapsed clock.
struct DocumentPagePreparationIdentity: Codable, Equatable {
  let requestID: UUID
  let attemptID: UUID
  let coordinatorID: UUID
  let documentID: UUID
  let generation: String
  let runtimeID: UUID
  let sourceKey: String
  let stateKey: String
  let token: String
  let pageIndex: Int
  let configuredAt: TimeInterval
}

@MainActor
final class DocumentPagePreparationTrace {
  enum Stage: String, CaseIterable, Hashable {
    case payloadConfiguredAt, mountAt, admissionRequestedAt, admittedAt, admissionReusedAt
    case shellNavigationFinishedAt, shellReadyMessageAt, shellReusedAt, frameTaskAt
    case preparedPageStartAt, preparedPageReadyAt, pageSourceEncodedAt, stateEncodedAt
    case frameEncodedAt, frameEvaluationStartAt, frameEvaluationReturnedAt
    case renderStartedAt, renderedAt, pageReceiptRequestedAt, pageReceiptReturnedAt, layoutReceiptAcceptedAt
    case canonicalReadyAt, canonicalReusedAt
  }
  let identity: DocumentPagePreparationIdentity
  private let now: @MainActor () -> TimeInterval
  private(set) var phasesMS: [String: Double] = [:]
  // Browser clocks describe elapsed work inside one render/receipt call, not
  // native uptime or system frames. Native geometry is an occlusion upper
  // bound: sibling views and compositor visibility are not inferred from it.
  private(set) var browserPhasesMS: [String: Double] = [:]
  private(set) var browserStates: [String: [String: Double]] = [:]
  private(set) var nativeVisibility: [String: [String: Double]] = [:]
  static let browserPhaseNames: Set<String> = [
    "render_enter", "render_fragmentDOM", "render_images", "render_install",
    "render_programs", "render_state", "render_complete",
    "receipt_enter", "receipt_setPage", "receipt_raf1", "receipt_raf2", "receipt_complete"
  ]
  static let visibilityStages: Set<Stage> = [
    .preparedPageStartAt, .frameEvaluationStartAt, .renderedAt,
    .pageReceiptRequestedAt, .pageReceiptReturnedAt
  ]
  init(identity: DocumentPagePreparationIdentity,
    now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
    self.identity = identity; self.now = now
  }
  func mark(_ stage: Stage) {
    guard phasesMS[stage.rawValue] == nil else { return }
    let elapsed = (now() - identity.configuredAt) * 1_000
    guard elapsed.isFinite, elapsed >= 0 else { return }
    phasesMS[stage.rawValue] = elapsed
  }
  func recordBrowserPhases(_ phases: [String: Double], attemptID: UUID) {
    guard attemptID == identity.attemptID, phases.count <= Self.browserPhaseNames.count,
      phases.allSatisfy({ Self.browserPhaseNames.contains($0.key) && $0.value.isFinite && $0.value >= 0 }) else { return }
    for (name, elapsed) in phases where browserPhasesMS[name] == nil { browserPhasesMS[name] = elapsed }
  }
  func recordBrowserStates(_ states: [String: [String: Double]], attemptID: UUID) {
    let stages: Set<String> = ["fonts_before", "fonts_after", "render_enter", "receipt_enter", "receipt_raf1", "receipt_raf2"]
    let fields: Set<String> = ["documentHidden", "documentReadyState", "sourcePreparationConnected"]
    guard attemptID == identity.attemptID, states.count <= stages.count,
      states.allSatisfy({ stages.contains($0.key) && $0.value.count <= fields.count
        && $0.value.allSatisfy({ fields.contains($0.key) && $0.value.isFinite }) }) else { return }
    for (stage, value) in states where browserStates[stage] == nil { browserStates[stage] = value }
  }
  func recordNativeVisibility(_ value: [String: Double], at stage: Stage) {
    guard Self.visibilityStages.contains(stage), nativeVisibility[stage.rawValue] == nil,
      value.count <= 32, value.allSatisfy({ $0.key.utf8.count <= 64 && $0.value.isFinite }) else { return }
    nativeVisibility[stage.rawValue] = value
  }
}

/// Profiling observes the ordinary document owners; it cannot make a page
/// ready, request pixels, perform layout, or change navigation.
@MainActor
final class DocumentPresentationRecorder {
  enum Cause: String, Codable { case open, page }
  struct LandingAttempt: Codable, Equatable {
    enum Stage: String, Codable { case preparing, capturing, completed, cancelled, failed }
    let identity: DocumentPagePreparationIdentity
    var stage: Stage
    var observedAt: TimeInterval
    var captureStartedAt: TimeInterval?
    var phasesMS: [String: Double]
    var browserPhasesMS: [String: Double]
    var browserStates: [String: [String: Double]]
    var nativeVisibility: [String: [String: Double]]
  }
  struct Record: Codable, Equatable {
    let id: UUID
    let documentID: UUID
    let pageIndex: Int
    let cause: Cause
    let requestedAt: TimeInterval
    var demandedAt: TimeInterval?
    var contentReadyAt: TimeInterval?
    var installedAt: TimeInterval?
    var sourceToken: String?
    var sourcePreparationPhasesMS: [String: Double]?
    var sourcePreparationMeasurement: Int?
    var pagePreparationPhasesMS: [String: Double]?
    var pagePreparationIdentity: DocumentPagePreparationIdentity?
    var pagePreparationBrowserPhasesMS: [String: Double]?
    var pagePreparationBrowserStates: [String: [String: Double]]?
    var pagePreparationNativeVisibility: [String: [String: Double]]?
    var landingAttempts: [LandingAttempt] = []
    var failure: String?
    var observationIntervalMS = 5
    var requestToInstalledMS: Double? { installedAt.map { ($0 - requestedAt) * 1_000 } }
    var demandToContentReadyMS: Double? {
      guard let demandedAt, let contentReadyAt else { return nil }
      return (contentReadyAt - demandedAt) * 1_000
    }
    var isFinished: Bool { installedAt != nil || failure != nil }
  }

  let enabled: Bool
  private(set) var records: [Record] = []
  private let now: @MainActor () -> TimeInterval
  private let signposter = OSSignposter(subsystem: "com.amirtlinov.notebook", category: "DocumentPresentation")
  private var intervals: [UUID: OSSignpostIntervalState] = [:]
  private var observers: [UUID: Task<Void, Never>] = [:]
  private var generations: [UUID: UUID] = [:]

  init(enabled: Bool, now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
    self.enabled = enabled; self.now = now
  }

  /// A repeated publication of one pending request is the same request. A
  /// later reopening after completion always gets a new identity.
  @discardableResult
  func request(documentID: UUID, pageIndex: Int, cause: Cause) -> UUID? {
    guard enabled, pageIndex >= 0 else { return nil }
    if let pending = records.last(where: { $0.documentID == documentID && !$0.isFinished }) {
      if pending.pageIndex == pageIndex { return pending.id }
      finish(pending.id, failure: "superseded")
    }
    let id = UUID()
    records.append(.init(id: id, documentID: documentID, pageIndex: pageIndex, cause: cause, requestedAt: now()))
    intervals[id] = signposter.beginInterval("DocumentRequestToInstalled", id: signposter.makeSignpostID(),
      "request=\(id.uuidString, privacy: .public) document=\(documentID.uuidString, privacy: .public) page=\(pageIndex)")
    while records.count > 64 { let old = records.removeFirst(); finishInterval(old.id); observers.removeValue(forKey: old.id)?.cancel(); generations[old.id] = nil }
    return id
  }

  func demand(documentID: UUID, pageIndex: Int, token: String) {
    guard let index = pendingIndex(documentID, pageIndex) else { return }
    if let old = records[index].sourceToken, old != token {
      finish(records[index].id, failure: "source_changed"); return
    }
    if records[index].demandedAt == nil {
      records[index].demandedAt = now(); records[index].sourceToken = token
      let id = records[index].id.uuidString
      signposter.emitEvent("DocumentContentDemand", "request=\(id, privacy: .public)")
    }
  }

  func preparationRequestID(documentID: UUID, pageIndex: Int, token: String) -> UUID? {
    guard let index = pendingIndex(documentID, pageIndex), records[index].sourceToken == token else { return nil }
    return records[index].id
  }

  /// A destination is prepared before the page controller can make it current.
  /// Keep those attempts on the original action, including cancelled captures;
  /// none of these observations certifies native installation or input.
  func observeLanding(_ trace: DocumentPagePreparationTrace?, stage: LandingAttempt.Stage) {
    guard let trace, let index = pendingIndex(trace.identity.documentID, trace.identity.pageIndex),
      records[index].id == trace.identity.requestID, records[index].sourceToken == trace.identity.token else { return }
    let existing = records[index].landingAttempts.firstIndex { $0.identity.attemptID == trace.identity.attemptID }
    if let existing, [.completed, .cancelled, .failed].contains(records[index].landingAttempts[existing].stage) { return }
    let time = now()
    let captureStarted = existing.flatMap { records[index].landingAttempts[$0].captureStartedAt }
      ?? (stage == .capturing ? time : nil)
    let attempt = LandingAttempt(identity: trace.identity, stage: stage, observedAt: time,
      captureStartedAt: captureStarted, phasesMS: trace.phasesMS, browserPhasesMS: trace.browserPhasesMS,
      browserStates: trace.browserStates, nativeVisibility: trace.nativeVisibility)
    if let existing { records[index].landingAttempts[existing] = attempt }
    else {
      records[index].landingAttempts.append(attempt)
      if records[index].landingAttempts.count > 8 { records[index].landingAttempts.removeFirst() }
    }
  }

  func contentReady(documentID: UUID, pageIndex: Int, token: String,
    sourcePreparationPhasesMS: [String: Double] = [:], sourcePreparationMeasurement: Int? = nil,
    pagePreparation: DocumentPagePreparationTrace? = nil) {
    guard let index = pendingIndex(documentID, pageIndex), records[index].sourceToken == token,
      records[index].contentReadyAt == nil else { return }
    records[index].contentReadyAt = now()
    records[index].sourcePreparationPhasesMS = sourcePreparationPhasesMS.isEmpty ? nil : sourcePreparationPhasesMS
    records[index].sourcePreparationMeasurement = sourcePreparationMeasurement
    if let pagePreparation, pagePreparation.identity.requestID == records[index].id,
      pagePreparation.identity.documentID == documentID, pagePreparation.identity.pageIndex == pageIndex,
      pagePreparation.identity.token == token {
      records[index].pagePreparationPhasesMS = pagePreparation.phasesMS
      records[index].pagePreparationIdentity = pagePreparation.identity
      records[index].pagePreparationBrowserPhasesMS = pagePreparation.browserPhasesMS.isEmpty ? nil : pagePreparation.browserPhasesMS
      records[index].pagePreparationBrowserStates = pagePreparation.browserStates.isEmpty ? nil : pagePreparation.browserStates
      records[index].pagePreparationNativeVisibility = pagePreparation.nativeVisibility.isEmpty ? nil : pagePreparation.nativeVisibility
    }
    let id = records[index].id.uuidString
    signposter.emitEvent("DocumentCanonicalContentReady", "request=\(id, privacy: .public)")
  }

  /// The callback must be the existing native installation proof, captured
  /// weakly. Polling targets a 5 ms interval; MainActor scheduling can delay
  /// observation further. That delay remains in request-to-observed-install time.
  func observeInstallation(documentID: UUID, pageIndex: Int, token: String,
    isInstalled: @escaping @MainActor () -> Bool,
    publish: @escaping @MainActor (String) -> Void) {
    guard let index = pendingIndex(documentID, pageIndex), records[index].sourceToken == token else {
      if enabled, let latest = records.last(where: { $0.documentID == documentID && $0.pageIndex == pageIndex }) { publish(encode(latest)) }
      return
    }
    let id = records[index].id
    observers.removeValue(forKey: id)?.cancel()
    let generation = UUID(); generations[id] = generation
    publish(encode(records[index]))
    observers[id] = Task { @MainActor [weak self] in
      guard let self else { return }
      let deadline = ContinuousClock.now + .seconds(30)
      while !Task.isCancelled, generations[id] == generation,
        let index = records.firstIndex(where: { $0.id == id && !$0.isFinished }) {
        if isInstalled() {
          records[index].installedAt = now(); finishInterval(id)
          publish(encode(records[index])); break
        }
        if ContinuousClock.now >= deadline {
          finish(id, failure: "installation_timeout")
          if let record = records.first(where: { $0.id == id }) { publish(encode(record)) }
          break
        }
        do { try await Task.sleep(for: .milliseconds(5)) } catch { break }
      }
      if generations[id] == generation { observers[id] = nil; generations[id] = nil }
    }
  }

  func cancel(documentID: UUID, failure: String = "navigation_cancelled") {
    for record in records where record.documentID == documentID && !record.isFinished { finish(record.id, failure: failure) }
  }

  private func pendingIndex(_ documentID: UUID, _ pageIndex: Int) -> Int? {
    guard enabled else { return nil }
    return records.lastIndex { $0.documentID == documentID && $0.pageIndex == pageIndex && !$0.isFinished }
  }
  private func finish(_ id: UUID, failure: String) {
    if let index = records.firstIndex(where: { $0.id == id && !$0.isFinished }) { records[index].failure = failure }
    finishInterval(id); observers.removeValue(forKey: id)?.cancel(); generations[id] = nil
  }
  private func finishInterval(_ id: UUID) {
    if let interval = intervals.removeValue(forKey: id) { signposter.endInterval("DocumentRequestToInstalled", interval) }
  }
  private func encode(_ record: Record) -> String {
    (try? JSONEncoder().encode(record)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
  }
  isolated deinit { observers.values.forEach { $0.cancel() }; for interval in intervals.values { signposter.endInterval("DocumentRequestToInstalled", interval) } }
}

import CoreFoundation
import QuartzCore
import UIKit
import XCTest

/// A bounded, passive observer for one diagnostic scenario. It requests no
/// updates and changes no presentation, frame-rate or event-dispatch policy.
@MainActor final class NotebookSchedulingObservation {
  struct Event: Codable {
    let stage: String
    let uptime: TimeInterval
    let deliveryUICycle: Int
    let deliveryRunLoopPass: Int
    let owner: String?
    let source: String?
    let modelTime: TimeInterval?
    let deadline: TimeInterval?
    let targetPresentation: TimeInterval?
    let immediatePresentationExpected: Bool?
    let performingLowLatencyPhases: Bool?
  }
  struct Report: Codable {
    let format: Int
    let scenario: String
    let processID: Int32
    let originUptime: TimeInterval
    let measurementEndedUptime: TimeInterval
    let droppedEvents: Int
    let events: [Event]
  }
  let origin = CACurrentMediaTime()
  private(set) var events: [Event] = []
  private(set) var droppedEvents = 0
  private var cycle = 0
  private var runLoopPass = 0
  private var ended: TimeInterval?
  private let link: UIUpdateLink
  private var observer: CFRunLoopObserver?

  init(scene: UIWindowScene) {
    link = UIUpdateLink(windowScene: scene)
    events.reserveCapacity(4096)
    let phases: [(String, UIUpdateActionPhase)] = [
      ("ui_before_event", .beforeEventDispatch), ("ui_after_event", .afterEventDispatch),
      ("ui_before_display_link", .beforeCADisplayLinkDispatch),
      ("ui_after_display_link", .afterCADisplayLinkDispatch),
      ("ui_before_ca_commit", .beforeCATransactionCommit),
      ("ui_after_ca_commit", .afterCATransactionCommit),
      ("ui_before_low_latency_event", .beforeLowLatencyEventDispatch),
      ("ui_after_low_latency_event", .afterLowLatencyEventDispatch),
      ("ui_before_low_latency_commit", .beforeLowLatencyCATransactionCommit),
      ("ui_after_low_latency_commit", .afterLowLatencyCATransactionCommit),
      ("ui_complete", .afterUpdateComplete)
    ]
    for (stage, phase) in phases {
      link.addAction(to: phase) { [weak self] _, info in
        guard let self else { return }
        if stage == "ui_before_event" { cycle += 1 }
        record(stage, modelTime: info.modelTime, deadline: info.completionDeadlineTime,
          target: info.estimatedPresentationTime,
          immediate: info.isImmediatePresentationExpected, lowLatency: info.isPerformingLowLatencyPhases)
      }
    }
    // Default passive policy remains intact, including low-latency input.
    link.isEnabled = true
    let activities: CFRunLoopActivity = [.entry, .beforeSources, .beforeWaiting, .afterWaiting, .exit]
    observer = CFRunLoopObserverCreateWithHandler(nil, activities.rawValue, true, 0) { [weak self] _, activity in
      MainActor.assumeIsolated {
        guard let self else { return }
        let stage: String
        switch activity {
        case .entry: stage = "runloop_entry"
        case .beforeSources: self.runLoopPass += 1; stage = "runloop_before_sources"
        case .beforeWaiting: stage = "runloop_before_wait"
        case .afterWaiting: stage = "runloop_after_wait"
        case .exit: stage = "runloop_exit"
        default: return
        }
        self.record(stage)
      }
    }
    if let observer { CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes) }
  }

  func record(_ stage: String, at uptime: TimeInterval = CACurrentMediaTime(),
    owner: String? = nil, source: String? = nil, modelTime: TimeInterval? = nil,
    deadline: TimeInterval? = nil, target: TimeInterval? = nil,
    immediate: Bool? = nil, lowLatency: Bool? = nil) {
    guard ended == nil else { return }
    guard events.count < 4096 else { droppedEvents += 1; return }
    events.append(.init(stage: stage, uptime: uptime, deliveryUICycle: cycle,
      deliveryRunLoopPass: runLoopPass, owner: owner, source: source,
      modelTime: modelTime, deadline: deadline, targetPresentation: target,
      immediatePresentationExpected: immediate, performingLowLatencyPhases: lowLatency))
  }

  func stop() {
    guard ended == nil else { return }
    ended = CACurrentMediaTime()
    link.isEnabled = false
    if let observer { CFRunLoopObserverInvalidate(observer) }
    observer = nil
  }

  func attachment(scenario: String) throws -> XCTAttachment {
    precondition(ended != nil, "Encoding and attachment work follow the measured scenario")
    let report = Report(format: 1, scenario: scenario, processID: ProcessInfo.processInfo.processIdentifier,
      originUptime: origin, measurementEndedUptime: ended!, droppedEvents: droppedEvents, events: events)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let attachment = XCTAttachment(data: try encoder.encode(report), uniformTypeIdentifier: "public.json")
    attachment.name = "Scheduling-\(scenario)"; attachment.lifetime = .keepAlways
    return attachment
  }

  isolated deinit { stop() }
}

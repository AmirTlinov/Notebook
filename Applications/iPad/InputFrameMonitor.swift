import OSLog
import UIKit

/// Opt-in evidence for real page Pencil input. This owner observes the existing
/// input/Metal callbacks; it neither schedules frames nor acknowledges content.
@MainActor
final class InputFrameMonitor {
  struct Surface: Codable, Equatable, Sendable { let id: UUID; let pageID: UUID }
  enum Phase: String, Codable, Sendable { case began, moved, ended, cancelled, estimated }
  enum SampleKind: String, Codable, Sendable { case actual, coalesced, estimatedCorrection }
  enum EndReason: String, Codable, Sendable { case lift, cancelled, retired }
  struct Measurement: Codable, Sendable {
    let timestamp: TimeInterval
    let index: Int
    let kind: SampleKind
    let replacesSample: Bool
  }
  struct Input: Codable, Sendable {
    let id: UInt64
    let surface: Surface
    let phase: Phase
    let entered: TimeInterval
    var returned: TimeInterval?
    var sourceID: UUID?
    var tool: DrawingTool?
    var contact: InkCanvasView.ContactFrame?
    var samples: [Measurement] = []
    var omittedSamples = 0

    mutating func accept(_ measurement: Measurement, sourceID: UUID, tool: DrawingTool) {
      self.sourceID = sourceID; self.tool = tool
      // A newly accepted measurement needs a projection of its own. An earlier
      // projection in this same handler cannot acknowledge the changed tail.
      contact = nil
      if samples.count < 64 { samples.append(measurement) } else { omittedSamples += 1 }
    }
  }
  struct Frame: Codable, Sendable {
    let surface: Surface
    let id: UUID
    let contact: InkCanvasView.ContactFrame
    let tile, tileCount: Int
    let osPresented: TimeInterval?
    let simulatorCompletion: Bool?
    let delivered: TimeInterval
    let timing: InkContactFrameTiming?
  }
  struct Activity: Codable, Sendable { let mode: String; let began, ended: TimeInterval }
  enum Event: Codable, Sendable {
    case input(Input)
    case frame(Frame)
    case contactEnded(UUID, EndReason, TimeInterval)
    case surfaceDetached(Surface, TimeInterval)
    case activity(Activity)

    var cost: Int {
      if case .input(let input) = self { return max(1, input.samples.count) }
      return 1
    }
    var samples: Int {
      if case .input(let input) = self { return input.samples.count + input.omittedSamples }
      return 0
    }
  }
  struct Outcome: Codable, Sendable {
    enum Unresolved: String, Codable, Sendable {
      case noProjectedFrame, awaitingOSReceipt, contactEnded, surfaceDetached, captureEnded
    }
    let inputID: UInt64
    var frameID: UUID?
    var presentedRevision: UInt64?
    var osPresented: TimeInterval?
    var unresolved: Unresolved?
  }
  struct Metadata: Codable, Sendable {
    let scope: String
    let startedAt: Date
    let build: String
    let operatingSystem: String
    let testProcess: Bool
    let mediaTime, systemUptime: TimeInterval
  }
  struct Report: Codable, Sendable {
    let version: Int
    let metadata: Metadata
    let events: [Event]
    let outcomes: [Outcome]
    let droppedEvents, droppedSamples, writeFailures: Int
    let lastBoundary: Event?
    let stoppedAt: TimeInterval?
  }
  private struct Capture: Sendable {
    var events: [Event] = []
    var cost = 0
    var droppedEvents = 0
    var droppedSamples = 0
    var writeFailures = 0
  }
  private static let signposter = OSSignposter(subsystem: "com.amirtlinov.notebook", category: "Input")
  private static let logger = Logger(subsystem: "com.amirtlinov.notebook", category: "Input")
  private let root: URL
  private let metadata: Metadata
  private var activity: (mode: String, began: TimeInterval)?
  private var span: OSSignpostIntervalState?
  private var nextInput: UInt64 = 0
  private var pending: [Event] = []
  private var pendingCost = 0
  private var droppedEvents = 0
  private var droppedSamples = 0
  private var lastBoundary: Event?
  private var stoppedAt: TimeInterval?
  private var capture = Capture()
  private var writeTask: Task<Void, Never>?
  private var flushRequested = false
  private var checkpointRequested = false
  private var lateFlushesRemaining = 0
  private(set) var writeFailure: String?

  init(root: URL) {
    self.root = root
    metadata = .init(scope: "pencil/page", startedAt: Date(),
      build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
      operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
      testProcess: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil,
      mediaTime: CACurrentMediaTime(), systemUptime: ProcessInfo.processInfo.systemUptime)
    pending.reserveCapacity(128)
  }

  func begin(mode: String) {
    guard activity == nil, stoppedAt == nil else { return }
    activity = (mode, CACurrentMediaTime())
    lateFlushesRemaining = 0
    span = Self.signposter.beginInterval("ContactToCommit")
  }
  func end() {
    guard let activity else { return }
    self.activity = nil
    lateFlushesRemaining = 2
    if let span { Self.signposter.endInterval("ContactToCommit", span); self.span = nil }
    append(.activity(.init(mode: activity.mode, began: activity.began, ended: CACurrentMediaTime())), flush: true)
  }
  func beginInput(on surface: Surface, phase: Phase) -> Input {
    nextInput += 1
    return .init(id: nextInput, surface: surface, phase: phase, entered: CACurrentMediaTime())
  }
  func record(_ input: Input) {
    guard !input.samples.isEmpty || input.omittedSamples > 0 else { return }
    append(.input(input), flush: false)
  }
  func record(_ receipt: InkCanvasView.ContactFrameResolution, on surface: Surface) {
    let osTime: TimeInterval?, simulator: Bool?
    switch receipt.completion {
    case .osPresentation(let time): osTime = time; simulator = nil
    case .simulatorCommandCompletion(let completed): osTime = nil; simulator = completed
    }
    let saveLateReceipt = activity == nil && lateFlushesRemaining > 0
    if saveLateReceipt { lateFlushesRemaining -= 1 }
    append(.frame(.init(surface: surface, id: receipt.frameID, contact: receipt.contact,
      tile: receipt.tile, tileCount: receipt.tileCount, osPresented: osTime, simulatorCompletion: simulator,
      delivered: CACurrentMediaTime(), timing: receipt.timing)), flush: saveLateReceipt)
  }
  func contactEnded(_ source: UUID, reason: EndReason) {
    let boundary = Event.contactEnded(source, reason, CACurrentMediaTime())
    lastBoundary = boundary
    append(boundary, flush: true)
  }
  func detach(_ surface: Surface) {
    let boundary = Event.surfaceDetached(surface, CACurrentMediaTime())
    lastBoundary = boundary
    append(boundary, flush: true)
  }
  func finish() async {
    end()
    stoppedAt = CACurrentMediaTime()
    await checkpoint()
  }
  func checkpoint() async {
    flush(checkpoint: true)
    await writeTask?.value
  }

  private func append(_ event: Event, flush immediately: Bool) {
    guard stoppedAt == nil else { return }
    // Bound both producer backlog and the complete capture. A blocked writer
    // cannot turn a long contact into unbounded diagnostic memory or silent loss.
    if pendingCost + event.cost <= 32_768 {
      pending.append(event); pendingCost += event.cost
    } else {
      droppedEvents += 1; droppedSamples += event.samples
    }
    if immediately { flush() }
  }
  private func flush(checkpoint: Bool = false) {
    flushRequested = true
    checkpointRequested = checkpointRequested || checkpoint
    guard writeTask == nil, activity == nil || checkpointRequested else { return }
    writeTask = Task { [weak self] in
      guard let self else { return }
      // A new contact can start before this scheduled task gets its actor turn.
      // Keep the dirty capture until the next idle boundary; only an explicit
      // background/shutdown checkpoint joins the writer irrespective of input.
      while flushRequested && (activity == nil || checkpointRequested) {
        flushRequested = false
        checkpointRequested = false
        let events = pending, previous = capture, lostEvents = droppedEvents, lostSamples = droppedSamples
        let boundary = lastBoundary, stopped = stoppedAt, root = root, metadata = metadata
        pending = []; pending.reserveCapacity(128); pendingCost = 0
        droppedEvents = 0; droppedSamples = 0
        let result = await Task.detached(priority: .utility) {
          var capture = previous
          capture.droppedEvents += lostEvents; capture.droppedSamples += lostSamples
          for event in events {
            if capture.cost + event.cost <= 32_768 {
              capture.events.append(event); capture.cost += event.cost
              if case .input(let input) = event { capture.droppedSamples += input.omittedSamples }
            } else {
              capture.droppedEvents += 1; capture.droppedSamples += event.samples
            }
          }
          do {
            let directory = root.appendingPathComponent("runtime", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let report = Report(version: 2, metadata: metadata, events: capture.events,
              outcomes: Self.resolve(capture.events, stopped: stopped != nil),
              droppedEvents: capture.droppedEvents, droppedSamples: capture.droppedSamples,
              writeFailures: capture.writeFailures, lastBoundary: boundary, stoppedAt: stopped)
            try JSONEncoder().encode(report).write(to: directory.appendingPathComponent("pencil-input.json"), options: .atomic)
            return (capture, nil as String?)
          } catch {
            capture.writeFailures += 1
            return (capture, error.localizedDescription)
          }
        }.value
        capture = result.0; writeFailure = result.1
        if let failure = result.1 { Self.logger.error("Input diagnostic was not saved: \(failure)") }
      }
      writeTask = nil
    }
  }

  /// Pure report reduction, called only by the utility writer. No frontier or
  /// receipt retained here can influence rendering, input admission, or storage.
  nonisolated static func resolve(_ events: [Event], stopped: Bool = false) -> [Outcome] {
    struct Group {
      let frame: Frame
      var tiles: [Int: TimeInterval] = [:]
    }
    struct Key: Hashable { let surface, source: UUID }
    struct Shown { let frame: Frame; let time: TimeInterval }
    var groups: [UUID: Group] = [:]
    var inputs: [Input] = [], ended = Set<UUID>(), detached = Set<UUID>()
    for event in events {
      switch event {
      case .input(let input): inputs.append(input)
      case .contactEnded(let source, _, _): ended.insert(source)
      case .surfaceDetached(let surface, _): detached.insert(surface.id)
      case .activity: break
      case .frame(let frame):
        guard frame.tileCount > 0, (0..<frame.tileCount).contains(frame.tile),
          let time = frame.osPresented, time.isFinite, time > 0 else { continue }
        var group = groups[frame.id] ?? .init(frame: frame)
        guard group.frame.surface == frame.surface, group.frame.contact == frame.contact,
          group.frame.tileCount == frame.tileCount else { continue }
        group.tiles[frame.tile] = time; groups[frame.id] = group
      }
    }
    var shown: [Key: [Shown]] = [:]
    for group in groups.values where group.tiles.count == group.frame.tileCount {
      guard let time = group.tiles.values.max() else { continue }
      shown[.init(surface: group.frame.surface.id, source: group.frame.contact.sourceID), default: []]
        .append(.init(frame: group.frame, time: time))
    }
    // A suffix minimum gives the first actual presentation at or after each
    // revision, without rescanning the complete capture for every input batch.
    var ordered: [Key: [Shown]] = [:], suffix: [Key: [Shown]] = [:]
    for (key, values) in shown {
      let sorted = values.sorted { $0.frame.contact.revision < $1.frame.contact.revision }
      ordered[key] = sorted
      var best = sorted, current = sorted.last!
      for index in sorted.indices.reversed() {
        if sorted[index].time < current.time { current = sorted[index] }
        best[index] = current
      }
      suffix[key] = best
    }
    return inputs.map { input in
      var result = Outcome(inputID: input.id)
      guard let contact = input.contact, contact.sourceID == input.sourceID else {
        result.unresolved = .noProjectedFrame; return result
      }
      let key = Key(surface: input.surface.id, source: contact.sourceID)
      let candidates = ordered[key] ?? []
      var low = 0, high = candidates.count
      while low < high {
        let middle = (low + high) / 2
        if candidates[middle].frame.contact.revision < contact.revision { low = middle + 1 } else { high = middle }
      }
      if let best = suffix[key], low < best.count {
        result.frameID = best[low].frame.id; result.presentedRevision = best[low].frame.contact.revision
        result.osPresented = best[low].time
      } else {
        result.unresolved = stopped ? .captureEnded : detached.contains(input.surface.id) ? .surfaceDetached
          : ended.contains(contact.sourceID) ? .contactEnded : .awaitingOSReceipt
      }
      return result
    }
  }
}

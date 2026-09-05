import NotebookCore
import OSLog
import UIKit

@MainActor
final class InputFrameMonitor: NSObject {
  private struct Sample: Codable, Sendable {
    let endedAt: Date
    let mode: String
    let build: String
    let durationMS: Double
    let cadence: InputFrameSummary
    let firstServiceLatencyMS: Double?
    let lastServiceToEndMS: Double?
  }

  private struct HistorySample: Codable, Sendable {
    let endedAt: Date
    let build: String
    let tapToMountMS: Double
  }

  private static let signposter = OSSignposter(subsystem: "com.amirtlinov.notebook", category: "Input")
  private var span: OSSignpostIntervalState?
  private let root: URL
  private var displayLink: CADisplayLink?
  private var frames = InputFrameStatistics()
  private var beganAt = 0.0
  private var firstServiceAt: Double?
  private var lastServiceAt: Double?
  private var mode = "unknown"
  private var pending: Sample?
  private var pendingHistory: HistorySample?
  private var writeTask: Task<Void, Never>?
  @MainActor private final class Callback: NSObject {
    weak var monitor: InputFrameMonitor?
    init(_ monitor: InputFrameMonitor) { self.monitor = monitor }
    @objc func frame(_ link: CADisplayLink) { monitor?.frame(link) }
  }

  init(root: URL) { self.root = root }
  isolated deinit { displayLink?.invalidate(); writeTask?.cancel() }

  func begin(mode: String) {
    guard displayLink == nil else { return }
    self.mode = mode
    frames = .init()
    beganAt = CACurrentMediaTime()
    firstServiceAt = nil; lastServiceAt = nil
    span = Self.signposter.beginInterval("ContactToCommit")
    let link = CADisplayLink(target: Callback(self), selector: #selector(Callback.frame))
    // This probe owns neither a renderer nor a display confirmation. Its
    // interval is recorded as scheduling evidence, not as presented FPS.
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  private func frame(_ link: CADisplayLink) {
    let now = CACurrentMediaTime()
    if firstServiceAt == nil { firstServiceAt = now }
    lastServiceAt = now
    frames.record(timestamp: link.timestamp, expectedInterval: link.targetTimestamp - link.timestamp)
  }

  func end() {
    guard let displayLink else { return }
    displayLink.invalidate()
    self.displayLink = nil
    if let span { Self.signposter.endInterval("ContactToCommit", span); self.span = nil }
    let endedAt = CACurrentMediaTime()
    let sample = Sample(endedAt: Date(), mode: mode,
      build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
      durationMS: (endedAt - beganAt) * 1000, cadence: frames.summary,
      firstServiceLatencyMS: firstServiceAt.map { ($0 - beganAt) * 1000 },
      lastServiceToEndMS: (endedAt - (lastServiceAt ?? beganAt)) * 1000)
    // A blocked tap can finish without two display callbacks. It is still
    // evidence; omitting it would hide precisely the longest interface stalls.
    pending = sample
    flush()
  }

  func recordHistoryMount(durationMS: Double) {
    pendingHistory = .init(endedAt: Date(),
      build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown", tapToMountMS: durationMS)
    flush()
  }

  private func flush() {
    guard writeTask == nil else { return }
    writeTask = Task { [weak self] in
      guard let self else { return }
      while pending != nil || pendingHistory != nil {
        let sample = pending, history = pendingHistory
        pending = nil; pendingHistory = nil
        let root = root
        await Task.detached(priority: .utility) {
          if let sample {
            let url = root.appendingPathComponent("runtime/input-frames.json")
            var samples = (try? JSONDecoder().decode([Sample].self, from: Data(contentsOf: url))) ?? []
            samples.append(sample)
            try? JSONEncoder().encode(Array(samples.suffix(64))).write(to: url, options: .atomic)
          }
          if let history {
            let url = root.appendingPathComponent("runtime/collaboration-ui.json")
            var samples = (try? JSONDecoder().decode([HistorySample].self, from: Data(contentsOf: url))) ?? []
            samples.append(history)
            try? JSONEncoder().encode(Array(samples.suffix(32))).write(to: url, options: .atomic)
          }
        }.value
      }
      writeTask = nil
    }
  }
}

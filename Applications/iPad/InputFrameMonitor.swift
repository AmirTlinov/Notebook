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
  }

  private static let signposter = OSSignposter(subsystem: "com.amirtlinov.notebook", category: "Input")
  private var span: OSSignpostIntervalState?
  private let root: URL
  private var displayLink: CADisplayLink?
  private var frames = InputFrameStatistics()
  private var beganAt = 0.0
  private var mode = "unknown"
  private var pending: Sample?
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
    span = Self.signposter.beginInterval("ContactToCommit")
    let link = CADisplayLink(target: Callback(self), selector: #selector(Callback.frame))
    // This probe owns neither a renderer nor a display confirmation. Its
    // interval is recorded as scheduling evidence, not as presented FPS.
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  private func frame(_ link: CADisplayLink) {
    frames.record(timestamp: link.timestamp, expectedInterval: link.targetTimestamp - link.timestamp)
  }

  func end() {
    guard let displayLink else { return }
    displayLink.invalidate()
    self.displayLink = nil
    if let span { Self.signposter.endInterval("ContactToCommit", span); self.span = nil }
    let sample = Sample(endedAt: Date(), mode: mode,
      build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
      durationMS: (CACurrentMediaTime() - beganAt) * 1000, cadence: frames.summary)
    guard sample.cadence.totalIntervals > 0 else { return }
    pending = sample
    guard writeTask == nil else { return }
    writeTask = Task { [weak self] in
      guard let self else { return }
      let url = root.appendingPathComponent("runtime/input-frames.json")
      while let sample = pending {
        pending = nil
        await Task.detached(priority: .utility) {
          var samples = (try? JSONDecoder().decode([Sample].self, from: Data(contentsOf: url))) ?? []
          samples.append(sample)
          try? JSONEncoder().encode(Array(samples.suffix(64))).write(to: url, options: .atomic)
        }.value
      }
      writeTask = nil
    }
  }
}

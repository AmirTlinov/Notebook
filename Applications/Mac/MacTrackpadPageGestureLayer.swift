import AppKit
import SwiftUI

/// Converts one physical horizontal trackpad sequence into the same samples
/// used by the iPad recognizer. Momentum events are consumed: after release,
/// PageMotionController is the only owner of speed and destination.
struct MacTrackpadPageGestureLayer: NSViewRepresentable {
  let isEnabled: Bool
  let onNavigation: (PageNavigationPhase) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(isEnabled: isEnabled, onNavigation: onNavigation)
  }

  func makeNSView(context: Context) -> MacGestureAnchorView {
    let view = MacGestureAnchorView()
    view.onWindowChange = { [weak coordinator = context.coordinator] window in
      coordinator?.install(in: window)
    }
    return view
  }

  func updateNSView(_ view: MacGestureAnchorView, context: Context) {
    context.coordinator.isEnabled = isEnabled
    context.coordinator.onNavigation = onNavigation
    context.coordinator.install(in: view.window)
  }

  static func dismantleNSView(
    _ view: MacGestureAnchorView,
    coordinator: Coordinator
  ) {
    coordinator.uninstall()
  }

  @MainActor
  final class Coordinator {
    var isEnabled: Bool {
      didSet {
        guard oldValue && !isEnabled else { return }
        cancelActiveSequence()
      }
    }
    var onNavigation: (PageNavigationPhase) -> Void

    private weak var window: NSWindow?
    private var monitor: Any?
    private var sequence = MacTrackpadPageSequence()
    private var syntheticEndTask: Task<Void, Never>?
    private var consumesMomentum = false

    init(
      isEnabled: Bool,
      onNavigation: @escaping (PageNavigationPhase) -> Void
    ) {
      self.isEnabled = isEnabled
      self.onNavigation = onNavigation
    }

    isolated deinit {
      if let monitor { NSEvent.removeMonitor(monitor) }
      syntheticEndTask?.cancel()
    }

    func install(in window: NSWindow?) {
      guard self.window !== window || monitor == nil else { return }
      uninstall()
      guard let window else { return }
      self.window = window
      monitor = NSEvent.addLocalMonitorForEvents(
        matching: .scrollWheel
      ) { [weak self, weak window] event in
        guard let self, let window, event.window === window else { return event }
        return self.handle(event)
      }
    }

    func uninstall() {
      cancelActiveSequence()
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
      window = nil
      consumesMomentum = false
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
      guard isEnabled, event.hasPreciseScrollingDeltas else { return event }

      let translationDelta = -event.scrollingDeltaX
      let verticalDelta = -event.scrollingDeltaY
      let isMomentum = !event.momentumPhase.isEmpty

      if isMomentum {
        guard consumesMomentum
          || abs(translationDelta) > abs(verticalDelta)
        else { return event }
        if sequence.isActive { endActiveSequence() }
        if event.momentumPhase.contains(.ended)
          || event.momentumPhase.contains(.cancelled)
        {
          consumesMomentum = false
        }
        return nil
      }

      if event.phase.contains(.cancelled) {
        guard sequence.isActive else { return event }
        cancelActiveSequence()
        consumesMomentum = true
        return nil
      }

      let ownsHorizontalMotion = sequence.isActive
        || (abs(translationDelta) > 0.05
          && abs(translationDelta) > abs(verticalDelta))
      guard ownsHorizontalMotion else { return event }

      let sample = sequence.append(
        translationDelta: translationDelta,
        timestamp: event.timestamp,
        gripY: window.map { normalizedGripY(event, in: $0) } ?? 0.5
      )
      if sequence.sampleCount == 1 {
        onNavigation(.began(sample))
      } else {
        onNavigation(.changed(sample))
      }

      if event.phase.contains(.ended) {
        endActiveSequence()
        consumesMomentum = true
      } else {
        scheduleSyntheticEnd()
      }
      return nil
    }

    private func normalizedGripY(_ event: NSEvent, in window: NSWindow) -> CGFloat {
      let bounds = window.contentView?.bounds ?? .zero
      guard bounds.height > 0 else { return 0.5 }
      let localY = event.locationInWindow.y - bounds.minY
      return min(max(1 - localY / bounds.height, 0), 1)
    }

    private func scheduleSyntheticEnd() {
      syntheticEndTask?.cancel()
      syntheticEndTask = Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(80))
        guard !Task.isCancelled, let self, sequence.isActive else { return }
        endActiveSequence()
      }
    }

    private func endActiveSequence() {
      syntheticEndTask?.cancel()
      syntheticEndTask = nil
      guard let sample = sequence.currentSample else { return }
      sequence.reset()
      onNavigation(.ended(sample))
    }

    private func cancelActiveSequence() {
      syntheticEndTask?.cancel()
      syntheticEndTask = nil
      guard sequence.isActive else { return }
      sequence.reset()
      onNavigation(.cancelled)
    }
  }
}

/// A small value owner keeps event-rate noise out of the page controller and
/// makes velocity measurable without relying on AppKit's separate momentum.
struct MacTrackpadPageSequence {
  private struct Sample {
    let timestamp: TimeInterval
    let translation: CGFloat
  }

  private static let velocityWindow: TimeInterval = 0.08
  private var samples: [Sample] = []
  private(set) var translation: CGFloat = 0
  private(set) var velocity: CGFloat = 0
  private(set) var gripY: CGFloat = 0.5
  private(set) var sampleCount = 0

  var isActive: Bool { sampleCount > 0 }
  var currentSample: PageNavigationSample? {
    guard isActive else { return nil }
    return PageNavigationSample(
      translation: translation,
      velocity: velocity,
      gripY: gripY
    )
  }

  mutating func append(
    translationDelta: CGFloat,
    timestamp: TimeInterval,
    gripY: CGFloat = 0.5
  ) -> PageNavigationSample {
    if sampleCount == 0 { self.gripY = min(max(gripY, 0), 1) }
    translation += translationDelta
    sampleCount += 1
    samples.append(Sample(timestamp: timestamp, translation: translation))
    samples.removeAll { timestamp - $0.timestamp > Self.velocityWindow }
    if let first = samples.first,
      let last = samples.last,
      last.timestamp - first.timestamp > 0.001
    {
      velocity = (last.translation - first.translation)
        / (last.timestamp - first.timestamp)
    } else {
      velocity = 0
    }
    return PageNavigationSample(
      translation: translation,
      velocity: velocity,
      gripY: self.gripY
    )
  }

  mutating func reset() {
    samples.removeAll(keepingCapacity: true)
    translation = 0
    velocity = 0
    gripY = 0.5
    sampleCount = 0
  }
}

@MainActor
final class MacGestureAnchorView: NSView {
  var onWindowChange: ((NSWindow?) -> Void)?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    onWindowChange?(window)
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }
}

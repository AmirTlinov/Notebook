import Metal
import QuartzCore

/// Simulator has no drawable presentation callback. Its GPU completion can
/// advance local interactions, but can never supply a display timestamp.
enum MetalFrameCompletion: Sendable {
  case displayed(TimeInterval)
  case simulatorRendered
  case discarded

  static var reportsDisplayTime: Bool {
    #if targetEnvironment(simulator)
      false
    #else
      true
    #endif
  }

  var permitsProgress: Bool {
    switch self {
    case .displayed(let time): time.isFinite && time > 0
    case .simulatorRendered: true
    case .discarded: false
    }
  }

  var presentationTime: TimeInterval? {
    if case .displayed(let time) = self, permitsProgress { return time }
    return nil
  }

  /// A nil command is only for an already GPU-completed staged frame. Its
  /// caller presents synchronously before returning to the main actor.
  @MainActor static func observe(_ drawable: any CAMetalDrawable,
    after command: (any MTLCommandBuffer)?,
    _ handler: @escaping @Sendable (MetalFrameCompletion) -> Void) {
    #if targetEnvironment(simulator)
      if let command {
        command.addCompletedHandler { command in
          handler(command.status == .completed ? .simulatorRendered : .discarded)
        }
      } else {
        Task { @MainActor in handler(.simulatorRendered) }
      }
    #else
      drawable.addPresentedHandler { drawable in
        let time = drawable.presentedTime
        handler(time.isFinite && time > 0 ? .displayed(time) : .discarded)
      }
    #endif
  }
}

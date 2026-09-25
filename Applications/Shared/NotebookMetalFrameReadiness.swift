import Foundation
import Metal
import QuartzCore

/// Metal Simulator has no OS presentation receipt in its SDK. It can advance
/// UI readiness after submitted GPU work, but must never manufacture a display
/// timestamp, FPS sample, or touch-to-photon receipt from that completion.
enum NotebookMetalFrameReadiness: Sendable {
  case osPresentation(TimeInterval)
  case simulatorCommandCompletion(Bool)

  var presentedTime:TimeInterval? {
    if case .osPresentation(let time)=self, isReady { return time };return nil
  }
  var isReady:Bool {
    switch self {
    case .osPresentation(let time): return time.isFinite && time > 0
    case .simulatorCommandCompletion(let completed): return completed
    }
  }

  /// A nil command is only for a staged drawable whose GPU work already
  /// completed. Its owner presents it in this same actor transaction.
  @MainActor static func observe(_ drawable:any CAMetalDrawable,
    commandBuffer:(any MTLCommandBuffer)?,
    ready:@escaping @MainActor @Sendable (Self)->Void) {
    #if targetEnvironment(simulator)
    if let commandBuffer {
      commandBuffer.addCompletedHandler { command in
        let completed=command.status == .completed
        Task { @MainActor in ready(.simulatorCommandCompletion(completed)) }
      }
    } else {
      Task { @MainActor in ready(.simulatorCommandCompletion(true)) }
    }
    #else
    drawable.addPresentedHandler { drawable in
      let time=drawable.presentedTime
      Task { @MainActor in ready(.osPresentation(time)) }
    }
    #endif
  }
}

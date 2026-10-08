import Darwin
import Dispatch
import Foundation

#if os(iOS)
  import UIKit
#endif

/// Purpose belongs to the requesting owner; execution priority is independent.
enum ScenePreparationPurpose: Equatable, Sendable { case required, optional }

enum SceneMemoryPressureLevel: String, Codable, Sendable { case normal, warning, critical }

struct SceneProcessMemory: Codable, Sendable {
  let residentBytes: UInt64?
  let physicalFootprintBytes: UInt64?

  /// One event sample of this process, never an estimate of WebContent memory.
  static func sample() -> Self {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return .init(residentBytes: status == KERN_SUCCESS ? info.resident_size : nil,
      physicalFootprintBytes: status == KERN_SUCCESS ? info.phys_footprint : nil)
  }
}

/// The pool ledger and kernel measurements retain their different meanings.
struct SceneMemoryPressureDiagnostic: Codable, Sendable {
  let event: SceneMemoryPressureLevel
  let uptime: TimeInterval
  let processID: Int32
  let process: SceneProcessMemory
  let ledgerResidentBytes: Int
  let ledgerReservedBytes: Int
  let ledgerPinnedBytes: Int
  let activeWebSurfaceCount: Int
  let pendingWebRequestCount: Int
}

/// OS binding only. The shared pool owns policy, admission and reclamation.
@MainActor
final class SceneMemoryPressureAdapter {
  private let source: DispatchSourceMemoryPressure
  private weak var resources: SceneRenderResources?
  #if os(iOS)
    private var warningObserver: NSObjectProtocol?
  #endif

  init(resources: SceneRenderResources) {
    self.resources = resources
    source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
    source.setEventHandler { [weak self] in
      MainActor.assumeIsolated { self?.receiveEvent() }
    }
    #if os(iOS)
      warningObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
        object: nil, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.resources?.handleMemoryPressure(.warning) }
        }
    #endif
    source.resume()
  }

  private func receiveEvent() {
    let flags = source.data
    let level: SceneMemoryPressureLevel
    if flags.contains(.critical) { level = .critical }
    else if flags.contains(.warning) { level = .warning }
    else if flags.contains(.normal) { level = .normal }
    else { return }
    resources?.handleMemoryPressure(level)
  }

  isolated deinit {
    source.cancel()
    #if os(iOS)
      if let warningObserver { NotificationCenter.default.removeObserver(warningObserver) }
    #endif
  }
}

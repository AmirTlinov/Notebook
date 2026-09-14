#if os(iOS)
import Foundation
import MachO
import SwiftUI
import UIKit

/// Diagnostic metadata only. It neither declares UI ready nor drives the app.
struct NotebookSystemTraceIdentitySurface: UIViewRepresentable {
  func makeUIView(context: Context) -> UIView {
    let view = UIView(frame: .zero)
    view.isUserInteractionEnabled = false
    if let value = NotebookSystemTraceIdentity.value {
      view.isAccessibilityElement = true
      view.accessibilityIdentifier = "notebook-system-trace-identity"
      view.accessibilityLabel = "System trace process identity"
      view.accessibilityValue = value
    }
    return view
  }
  func updateUIView(_ view: UIView, context: Context) {}
}

@MainActor private enum NotebookSystemTraceIdentity {
  struct Record: Encodable {
    let format = 1
    let sessionID: UUID
    let launchID: UUID
    let pid: Int32
    let bundleID: String
    let executableUUID: String
    let executablePath: String
    let reportedUptime: TimeInterval
  }

  // One identity per application process, independent of SwiftUI reconstruction.
  static let value: String? = {
    guard Bundle.main.bundleIdentifier == "com.amirtlinov.notebook.acceptance",
      ProcessInfo.processInfo.environment["NOTEBOOK_ACCEPTANCE_MANIFEST"] != nil,
      let raw = ProcessInfo.processInfo.environment["NOTEBOOK_TRACE_SESSION_ID"],
      let session = UUID(uuidString: raw), let header = _dyld_get_image_header(0),
      header.pointee.magic == MH_MAGIC_64, header.pointee.sizeofcmds <= 1_048_576,
      let path = _dyld_get_image_name(0) else { return nil }
    let base = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
    var offset = 0
    for _ in 0..<header.pointee.ncmds {
      guard offset + MemoryLayout<load_command>.size <= Int(header.pointee.sizeofcmds) else { return nil }
      let pointer = base.advanced(by: offset)
      let command = pointer.load(as: load_command.self)
      guard command.cmdsize >= MemoryLayout<load_command>.size,
        offset + Int(command.cmdsize) <= Int(header.pointee.sizeofcmds) else { return nil }
      if command.cmd == LC_UUID {
        guard command.cmdsize >= MemoryLayout<uuid_command>.size else { return nil }
        let uuid = UUID(uuid: pointer.load(as: uuid_command.self).uuid)
        let record = Record(sessionID: session, launchID: UUID(), pid: ProcessInfo.processInfo.processIdentifier,
          bundleID: Bundle.main.bundleIdentifier!, executableUUID: uuid.uuidString,
          executablePath: String(cString: path), reportedUptime: ProcessInfo.processInfo.systemUptime)
        guard let data = try? JSONEncoder().encode(record) else { return nil }
        return String(data: data, encoding: .utf8)
      }
      offset += Int(command.cmdsize)
    }
    return nil
  }()
}
#endif

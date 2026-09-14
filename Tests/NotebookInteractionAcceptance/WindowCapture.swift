import Foundation
import AppKit
import ScreenCaptureKit
import CoreGraphics
import CoreImage
import CoreMedia
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import Darwin

struct CaptureFailure: LocalizedError {
  let text: String
  init(_ text: String) { self.text = text }
  var errorDescription: String? { text }
}

func jsonData(_ value: [String: Any]) throws -> Data {
  try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted])
}
func writeJSON(_ value: [String: Any], to url: URL) throws {
  try jsonData(value).write(to: url, options: .atomic)
}
func rect(_ value: CGRect) -> [String: Double] {
  ["x": value.minX, "y": value.minY, "width": value.width, "height": value.height]
}
func captureClock() -> [String: Any] {
  var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
  let before = mach_absolute_time(), uptime = ProcessInfo.processInfo.systemUptime, after = mach_absolute_time()
  return ["name": "mach_absolute_time", "numer": timebase.numer, "denom": timebase.denom,
    "machBefore": String(before), "systemUptimeSeconds": uptime, "machAfter": String(after)]
}

/// Every screen callback and PNG encode runs on one bounded serial queue. Slow
/// encoding may increase gaps; all display timestamps/gaps remain in the record.
/// No duplicate/synthetic frame is manufactured to cover a missing callback.
final class Output: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
  let queue = DispatchQueue(label: "NotebookAcceptance.window-capture", qos: .userInitiated)
  private let lock = NSLock()
  private let directory: URL
  private let file: FileHandle
  private let context = CIContext(options: [.cacheIntermediates: false])
  private var count = 0, complete = 0
  private var pngBytes = 0
  private var errorText: String?
  private var lastDisplay: UInt64?
  private var maxDisplayGap: UInt64 = 0
  private var reachedBudget = false
  private let windowID: UInt32
  private let sessionID: String

  init(directory: URL, windowID: UInt32, sessionID: String) throws {
    self.directory = directory; self.windowID = windowID; self.sessionID = sessionID
    let log = directory.appendingPathComponent("frames.ndjson")
    guard FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
      throw CaptureFailure("Cannot create frame journal")
    }
    file = try FileHandle(forWritingTo: log)
  }

  func stream(_ stream: SCStream, didStopWithError error: any Error) {
    lock.lock(); defer { lock.unlock() }; errorText = error.localizedDescription
  }

  func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .screen else { return }
    lock.lock(); defer { lock.unlock() }
    guard !reachedBudget else { return }
    count += 1
    if count > 4_000 || pngBytes > 1_024 * 1_024 * 1_024 {
      reachedBudget = true; errorText = "Capture budget exceeded (4000 callbacks or 1 GiB PNG)"; return
    }
    let received = mach_absolute_time()
    let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
    let info = attachments?.first ?? [:]
    let status = (info[.status] as? NSNumber)?.intValue
    let displayed = (info[.displayTime] as? NSNumber)?.uint64Value
    var value: [String: Any] = ["format": 1, "sequence": count, "sessionID": sessionID,
      "windowID": windowID, "receivedMach": String(received),
      "status": status ?? -1, "sampleValid": buffer.isValid,
      "samplePresentationSeconds": buffer.presentationTimeStamp.seconds]
    if let displayed {
      value["displayMach"] = String(displayed)
      if let lastDisplay, displayed >= lastDisplay {
        let gap = displayed - lastDisplay; value["displayGapTicks"] = String(gap)
        maxDisplayGap = max(maxDisplayGap, gap)
      }
      lastDisplay = displayed
      if received >= displayed { value["deliveryDelayTicks"] = String(received - displayed) }
    }
    for (key, name) in [(SCStreamFrameInfo.contentRect, "contentRect"), (.screenRect, "screenRect"), (.boundingRect, "boundingRect")] {
      if let dictionary = info[key] as? NSDictionary, let rectangle = CGRect(dictionaryRepresentation: dictionary as CFDictionary) {
        value[name] = rect(rectangle)
      }
    }
    for (key, name) in [(SCStreamFrameInfo.scaleFactor, "scaleFactor"), (.contentScale, "contentScale")] {
      if let number = info[key] as? NSNumber { value[name] = number.doubleValue }
    }
    do {
      if status == SCFrameStatus.complete.rawValue, buffer.isValid,
        let displayed, displayed > 0, let pixel = buffer.imageBuffer {
        let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel)
        guard width > 0, height > 0, width * height <= 16_000_000 else { throw CaptureFailure("Frame dimensions exceed capture budget") }
        let ci = CIImage(cvPixelBuffer: pixel)
        guard let image = context.createCGImage(ci, from: CGRect(x: 0, y: 0, width: width, height: height)) else {
          throw CaptureFailure("Cannot read delivered frame pixels")
        }
        let name = String(format: "frame-%06d.png", count)
        let url = directory.appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
          throw CaptureFailure("Cannot create PNG destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CaptureFailure("Cannot finish PNG") }
        let bytes = try Data(contentsOf: url)
        pngBytes += bytes.count; complete += 1
        value["png"] = name; value["width"] = width; value["height"] = height
        value["pngSHA256"] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        if complete == 1 {
          try writeJSON(["format": 1, "status": "started", "sessionID": sessionID,
            "windowID": windowID, "firstDisplayMach": String(displayed), "firstPNG": name],
            to: directory.appendingPathComponent("started.json"))
        }
      }
      var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]); data.append(10)
      try file.write(contentsOf: data)
    } catch { errorText = error.localizedDescription }
  }

  func finish() throws -> [String: Any] {
    queue.sync {}
    lock.lock(); defer { lock.unlock() }
    try file.synchronize(); try file.close()
    return ["callbacks": count, "completePNGs": complete, "pngBytes": pngBytes,
      "maxDisplayGapTicks": String(maxDisplayGap), "error": errorText as Any? ?? NSNull(),
      "budgetExceeded": reachedBudget, "measured": false,
      "scope": "Actual Simulator window-server frames; no physical iPad/FPS/latency verdict"]
  }
}

@main @MainActor struct WindowCapture {
  static func main() async {
    do { try await run() }
    catch {
      let value: [String: Any] = ["format": 1, "status": "unmeasured", "error": error.localizedDescription,
        "permissionRequested": false, "clock": captureClock()]
      if let data = try? jsonData(value) { FileHandle.standardError.write(data); FileHandle.standardError.write(Data("\n".utf8)) }
      exit(2)
    }
  }

  static func run() async throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let mode = args.first, mode == "inventory" || mode == "capture" else {
      throw CaptureFailure("Usage: WindowCapture inventory | capture WINDOW_ID SIMULATOR_PID SESSION_UUID ABSOLUTE_NEW_OUTPUT SECONDS")
    }
    // A false preflight is terminal; never call CGRequestScreenCaptureAccess or
    // a picker/shareable-content API which could ask for a new permission.
    guard CGPreflightScreenCaptureAccess() else { throw CaptureFailure("Screen capture preflight denied; capture is unmeasured") }
    // A console entry point does not initialize AppKit's WindowServer connection.
    // SCContentFilter needs that connection even when enumeration succeeds.
    precondition(pthread_main_np() != 0, "AppKit capture initialization requires the main OS thread")
    _ = NSApplication.shared
    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    let candidates = content.windows.filter { $0.owningApplication?.bundleIdentifier == "com.apple.iphonesimulator" }
    if mode == "inventory" {
      let windows: [[String: Any]] = candidates.map { window in
        ["windowID": window.windowID, "title": window.title ?? "", "frame": rect(window.frame),
          "pid": window.owningApplication!.processID, "bundleID": window.owningApplication!.bundleIdentifier,
          "onScreen": window.isOnScreen, "layer": window.windowLayer]
      }
      FileHandle.standardOutput.write(try jsonData(["format": 1, "screenCapturePreflight": true,
        "permissionRequested": false, "windows": windows, "clock": captureClock()])); return
    }
    guard args.count == 6, let windowID = UInt32(args[1]), let pid = Int32(args[2]), pid > 0,
      let session = UUID(uuidString: args[3]), args[4].hasPrefix("/"),
      let seconds = Double(args[5]), seconds >= 1, seconds <= 60 else { throw CaptureFailure("Invalid bounded capture arguments") }
    let directory = URL(fileURLWithPath: args[4], isDirectory: true)
    guard !FileManager.default.fileExists(atPath: directory.path) else { throw CaptureFailure("Capture output must be new; existing evidence cannot be overwritten") }
    guard let window = candidates.first(where: { $0.windowID == windowID && $0.owningApplication?.processID == pid }),
      window.isOnScreen else {
      throw CaptureFailure("Exact requested on-screen Simulator window/PID is unavailable")
    }
    guard window.frame.width > 100, window.frame.height > 100 else {
      throw CaptureFailure("Simulator window is too small for measurement: \(window.frame.width) by \(window.frame.height) points")
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    precondition(pthread_main_np() != 0, "Screen capture filter creation requires the main OS thread")
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let config = SCStreamConfiguration()
    config.width = Int((filter.contentRect.width * Double(filter.pointPixelScale)).rounded(.up))
    config.height = Int((filter.contentRect.height * Double(filter.pointPixelScale)).rounded(.up))
    guard config.width * config.height <= 16_000_000 else { throw CaptureFailure("Simulator window exceeds pixel budget") }
    config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
    config.queueDepth = 4; config.showsCursor = false; config.capturesAudio = false
    config.captureMicrophone = false; config.ignoreShadowsSingleWindow = true
    config.captureDynamicRange = .SDR; config.pixelFormat = kCVPixelFormatType_32BGRA
    let output = try Output(directory: directory, windowID: windowID, sessionID: session.uuidString)
    let stream = SCStream(filter: filter, configuration: config, delegate: output)
    try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
    var record: [String: Any] = ["format": 1, "sessionID": session.uuidString, "windowID": windowID,
      "simulatorPID": pid, "simulatorBundleID": "com.apple.iphonesimulator", "windowTitle": window.title ?? "",
      "windowFrame": rect(window.frame), "contentRect": rect(filter.contentRect), "pointPixelScale": filter.pointPixelScale,
      "width": config.width, "height": config.height, "requestedHz": 60, "requestedDurationSeconds": seconds,
      "audio": false, "microphone": false, "cursor": false, "screenCapturePreflight": true,
      "permissionRequested": false, "startClock": captureClock(), "status": "starting",
      "displayTimeSemantics": "SCStreamFrameInfo.displayTime: mach absolute time when frame was displayed by window server"]
    try writeJSON(record, to: directory.appendingPathComponent("capture.json"))
    do {
      try await stream.startCapture()
      let deadline = ProcessInfo.processInfo.systemUptime + seconds
      var cancelled = false
      while ProcessInfo.processInfo.systemUptime < deadline {
        let cancel = directory.deletingLastPathComponent().appendingPathComponent("cancel.json")
        if let data = try? Data(contentsOf: cancel), data.count <= 1024,
          let message = try? JSONSerialization.jsonObject(with: data) as? [String: String],
          message["sessionID"]?.lowercased() == session.uuidString.lowercased(), message["status"] == "cancelled" {
          cancelled = true; break
        }
        let stop = directory.appendingPathComponent("stop.json")
        if let data = try? Data(contentsOf: stop), data.count <= 1024,
          let message = try? JSONSerialization.jsonObject(with: data) as? [String: String],
          message["sessionID"]?.lowercased() == session.uuidString.lowercased(), message["status"] == "ui_ended" { break }
        try await Task.sleep(for: .milliseconds(50))
      }
      try await stream.stopCapture()
      record["result"] = try output.finish(); record["status"] = cancelled ? "unmeasured" : "captured_unassessed"; record["endClock"] = captureClock()
      if cancelled { record["error"] = "The UI runner cancelled this measurement session" }
      try writeJSON(record, to: directory.appendingPathComponent("capture.json"))
    } catch {
      let original = error
      try? await stream.stopCapture()
      record["result"] = try? output.finish(); record["status"] = "unmeasured"
      record["error"] = original.localizedDescription; record["endClock"] = captureClock()
      try? writeJSON(record, to: directory.appendingPathComponent("capture.json"))
      throw original
    }
  }
}

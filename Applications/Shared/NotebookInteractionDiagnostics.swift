#if os(iOS)
import Foundation
import Darwin
import UIKit
import WebKit

/// Acceptance observation, not an input or presentation owner. No gesture is
/// delayed, cancelled, replayed or claimed here. DOM timestamps are never a
/// claim that the window server displayed the resulting pixels.
@MainActor enum NotebookInteractionDiagnostics {
  private final class Runtime {
    weak var webView: WKWebView?
    let elementID: String
    let token: String
    var ready: Bool
    init(webView: WKWebView, elementID: String, token: String, ready: Bool) {
      self.webView = webView; self.elementID = elementID; self.token = token; self.ready = ready
    }
  }
  private struct Contact { let id: UUID; let runtime: Runtime? }
  private static var runtimes: [ObjectIdentifier: Runtime] = [:]
  private static var contacts: [ObjectIdentifier: Contact] = [:]
  private static var recorder: Recorder? = Recorder.configured()

  static var script: String { recorder?.script ?? "" }

  static func bind(_ webView: WKWebView, elementID: String, token: String, ready: Bool) {
    guard let recorder else { return }
    let key = ObjectIdentifier(webView)
    let runtime: Runtime
    if let existing = runtimes[key], existing.webView === webView, existing.token == token {
      runtime = existing; runtime.ready = ready
    } else {
      runtime = Runtime(webView: webView, elementID: elementID, token: token, ready: ready)
      runtimes[key] = runtime
    }
    recorder.append(["kind": "runtime", "runtime": identity(runtime)])
  }

  static func retire(_ webView: WKWebView) {
    guard let recorder, let runtime = runtimes.removeValue(forKey: ObjectIdentifier(webView)) else { return }
    recorder.append(["kind": "retire", "runtime": identity(runtime)])
  }

  static func contact(_ touch: UITouch, phase: String) {
    guard let recorder else { return }
    let key = ObjectIdentifier(touch)
    let contact: Contact
    if phase == "began" {
      var current = touch.view
      var runtime: Runtime?
      while let view = current {
        if let web = view as? WKWebView, let value = runtimes[ObjectIdentifier(web)], value.webView === web {
          runtime = value; break
        }
        current = view.superview
      }
      contact = Contact(id: UUID(), runtime: runtime); contacts[key] = contact
    } else {
      guard let existing = contacts[key] else { return }
      contact = existing
    }
    let point = touch.location(in: touch.window)
    var value: [String: Any] = ["kind": "contact", "contactID": contact.id.uuidString,
      "phase": phase, "touchUptimeSeconds": touch.timestamp, "touchType": touch.type.rawValue,
      "windowPoint": [point.x, point.y]]
    if let runtime = contact.runtime { value["runtime"] = identity(runtime) }
    recorder.append(value)
    if phase == "ended" || phase == "cancelled" { contacts[key] = nil }
  }

  static func abandon(_ identifiers: Set<ObjectIdentifier>) {
    guard let recorder else { return }
    for key in identifiers {
      if let contact = contacts.removeValue(forKey: key) {
        recorder.append(["kind": "contact_abandoned", "contactID": contact.id.uuidString,
          "reason": "Observer lifetime ended without an observed touch end"])
      }
    }
  }

  static func dom(_ object: [String: Any], webView: WKWebView, elementID: String, token: String, ready: Bool) {
    guard let recorder, let runtime = runtimes[ObjectIdentifier(webView)], runtime.webView === webView,
      runtime.token == token, runtime.elementID == elementID,
      let payload = object["observation"] as? [String: Any],
      JSONSerialization.isValidJSONObject(payload), let data = try? JSONSerialization.data(withJSONObject: payload),
      data.count <= 16_384 else { return }
    recorder.append(["kind": "dom", "runtime": identity(runtime), "readyAtReceipt": ready,
      "observation": payload])
  }

  private static func identity(_ runtime: Runtime) -> [String: Any] {
    var value: [String: Any] = ["elementID": runtime.elementID, "loadToken": runtime.token, "ready": runtime.ready]
    if let web = runtime.webView, let window = web.window {
      let corners = [CGPoint.zero, CGPoint(x: web.bounds.width, y: 0),
        CGPoint(x: 0, y: web.bounds.height), CGPoint(x: web.bounds.width, y: web.bounds.height)]
      value["windowCorners"] = corners.map { point -> [Double] in
        let p = web.convert(point, to: window); return [Double(p.x), Double(p.y)]
      }
      value["webBounds"] = [Double(web.bounds.width), Double(web.bounds.height)]
      value["windowBounds"] = [Double(window.bounds.width), Double(window.bounds.height)]
      value["windowScreenScale"] = window.screen.scale
    }
    return value
  }

  @MainActor private final class Recorder {
    let script: String
    private let sink: Sink
    private let launchID = UUID()
    private var sequence = 0
    private var bytes = 0
    private var stopped = false
    private let sessionID: UUID

    private init(session: UUID, directory: URL, selectors: [String], configuration: NotebookAcceptanceConfiguration) throws {
      sessionID = session
      sink = try Sink(url: directory.appendingPathComponent("\(session.uuidString.lowercased())-\(launchID.uuidString.lowercased()).ndjson"))
      let encoded = try JSONSerialization.data(withJSONObject: selectors)
      script = NotebookInteractionScript.source(selectorsJSON: String(decoding: encoded, as: UTF8.self))
      var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
      let before = mach_absolute_time(), uptime = ProcessInfo.processInfo.systemUptime, after = mach_absolute_time()
      append(["kind": "identity", "pid": ProcessInfo.processInfo.processIdentifier,
        "bundleID": configuration.bundleID, "workspaceID": configuration.workspaceID.uuidString,
        "acceptanceRunID": configuration.runID.uuidString, "sourceRevision": configuration.sourceRevision,
        "simulatorUDID": ProcessInfo.processInfo.environment["SIMULATOR_UDID"] ?? "unavailable",
        "executablePath": Bundle.main.executableURL?.path ?? "unavailable",
        "clock": ["name": "mach_absolute_time", "numer": timebase.numer, "denom": timebase.denom,
          "machBefore": String(before), "systemUptimeSeconds": uptime, "machAfter": String(after)],
        "selectors": selectors, "displayMeasured": false])
    }

    static func configured() -> Recorder? {
      #if targetEnvironment(simulator)
      let environment = ProcessInfo.processInfo.environment
      guard let raw = environment["NOTEBOOK_INTERACTION_SESSION_ID"], let session = UUID(uuidString: raw),
        let manifest = environment[NotebookAcceptanceConfiguration.environmentKey], manifest.hasPrefix("/"),
        let size = try? FileManager.default.attributesOfItem(atPath: manifest)[.size] as? Int,
        size > 0, size <= 16_384, let data = try? Data(contentsOf: URL(fileURLWithPath: manifest)),
        let config = try? JSONDecoder().decode(NotebookAcceptanceConfiguration.self, from: data), config.role == .iPad else { return nil }
      let enabled = (Bundle.main.object(forInfoDictionaryKey: "NotebookAcceptanceEnabled") as? Bool) == true
        || (Bundle.main.object(forInfoDictionaryKey: "NotebookAcceptanceEnabled") as? String) == "YES"
      guard (try? config.validate(bundle: Bundle.main.bundleIdentifier, enabled: enabled)) != nil else { return nil }
      let selectorData = Data((environment["NOTEBOOK_INTERACTION_SELECTORS"] ?? "[]").utf8)
      guard selectorData.count <= 2_048, let selectors = try? JSONDecoder().decode([String].self, from: selectorData),
        selectors.count <= 8, selectors.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else { return nil }
      let directory = config.rootURL.deletingLastPathComponent().appendingPathComponent("interaction-diagnostics", isDirectory: true)
      return try? Recorder(session: session, directory: directory, selectors: selectors, configuration: config)
      #else
      return nil
      #endif
    }

    func append(_ payload: [String: Any]) {
      guard !stopped else { return }
      if sequence >= 10_000 || bytes >= 8 * 1_024 * 1_024 {
        stopped = true; sink.append(Data("{\"kind\":\"truncated\",\"reason\":\"diagnostic budget exceeded\"}\n".utf8)); return
      }
      sequence += 1
      var record = payload
      record["format"] = 1; record["sequence"] = sequence
      record["sessionID"] = sessionID.uuidString; record["launchID"] = launchID.uuidString
      record["receiptMach"] = String(mach_absolute_time())
      guard var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
      data.append(10); bytes += data.count; sink.append(data)
    }
  }

  /// The bounded journal has one serial writer; file I/O never runs in a touch
  /// callback. Data is copied before dispatch and the sink owns its handle.
  private final class Sink: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Notebook.interaction-diagnostics", qos: .utility)
    private let handle: FileHandle
    init(url: URL) throws {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
        throw CocoaError(.fileWriteUnknown)
      }
      handle = try FileHandle(forWritingTo: url)
    }
    func append(_ data: Data) { queue.async { [self] in try? handle.write(contentsOf: data) } }
  }
}
#endif

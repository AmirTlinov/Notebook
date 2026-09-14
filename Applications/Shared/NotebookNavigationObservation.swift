import Foundation
import NotebookCore
import Darwin

/// Private acceptance observation only. No contact, navigation, persistence,
/// camera, source content or completion is created or changed by this recorder.
@MainActor enum NotebookNavigationObservation {
  private static let recorder = Recorder.configured()
  static var enabled: Bool { recorder?.sink.accepting == true }

  static func record(_ stage: String, model: NotebookAppModel,
    reference: CollaborationReference? = nil, fields: [String: JSONValue] = [:]) {
    guard enabled else { return }
    let request = reference ?? model.requestedReference
    let presence = model.presence
    var value: [String: JSONValue] = ["kind": .string("navigation"), "stage": .string(stage),
      "modelID": .string(String(describing: ObjectIdentifier(model))),
      "generation": .string(String(model.navigationGeneration)),
      "requestID": uuid(request?.id), "pendingRequestID": uuid(model.requestedReference?.id),
      "returnID": uuid(model.requestedReturn?.id), "historyCount": .number(Double(model.returnPlaces.count)),
      "targetID": uuid(request?.target.id), "targetKind": request.map { .string($0.target.kind.rawValue) } ?? .null,
      "phase": .string(model.presencePhase.rawValue), "inputActive": .bool(model.inputGate.isActive),
      "pencilActive": .bool(model.inputGate.hasActivePencil),
      "pencilGeneration": .string(String(model.inputGate.pencilGeneration)),
      "stopped": .bool(model.shutdownPhase == .stopped), "taskCancelled": .bool(Task.isCancelled),
      "boardID": uuid(presence?.boardID), "focusedItemID": uuid(presence?.focusedItemID),
      "selectedItemID": uuid(presence?.selectedItemID),
      "mode": presence.map { .string($0.mode.rawValue) } ?? .null]
    if let presence {
      value["camera"] = .object(["tileX": .string(String(presence.camera.center.tileX)),
        "tileY": .string(String(presence.camera.center.tileY)), "localX": .number(presence.camera.center.localX),
        "localY": .number(presence.camera.center.localY), "scale": .number(presence.camera.scale),
        "viewportWidth": .number(presence.viewport.x), "viewportHeight": .number(presence.viewport.y)])
    }
    value["detail"] = .object(fields)
    recorder?.append(value)
  }
  /// Physical page owners do not retain an application model. Their lifecycle
  /// uses the same private session and monotonic clock as accepted navigation.
  static func recordDocument(_ stage: String, ownerID: UUID, documentID: UUID?,
    fields: [String: JSONValue] = [:]) {
    guard enabled else { return }
    recorder?.append(["kind": .string("document_navigation"), "stage": .string(stage),
      "ownerID": uuid(ownerID), "documentID": uuid(documentID),
      "uptime": .number(ProcessInfo.processInfo.systemUptime),
      "taskCancelled": .bool(Task.isCancelled), "detail": .object(fields)])
  }
  private static func uuid(_ id: UUID?) -> JSONValue { id.map { .string($0.uuidString) } ?? .null }

  @MainActor private final class Recorder {
    let sink: Sink
    let sessionID: UUID
    let launchID = UUID()
    private var sequence = 0
    init(session: UUID, configuration: NotebookAcceptanceConfiguration) {
      sessionID = session
      let directory = configuration.rootURL.deletingLastPathComponent().appendingPathComponent("navigation-observations", isDirectory: true)
      sink = Sink(url: directory.appendingPathComponent("\(session.uuidString.lowercased())-\(launchID.uuidString.lowercased()).ndjson"))
      var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
      let before = mach_absolute_time(), uptime = ProcessInfo.processInfo.systemUptime, after = mach_absolute_time()
      append(["kind": .string("identity"), "observer": .string("navigation"),
        "bundleID": .string(configuration.bundleID), "workspaceID": uuid(configuration.workspaceID),
        "acceptanceRunID": uuid(configuration.runID), "sourceRevision": .string(configuration.sourceRevision),
        "pid": .number(Double(ProcessInfo.processInfo.processIdentifier)),
        "simulatorUDID": .string(ProcessInfo.processInfo.environment["SIMULATOR_UDID"] ?? "unavailable"),
        "clock": .object(["name": .string("mach_absolute_time"), "numer": .number(Double(timebase.numer)),
          "denom": .number(Double(timebase.denom)), "machBefore": .string(String(before)),
          "systemUptimeSeconds": .number(uptime), "machAfter": .string(String(after))]),
        "displayMeasured": .bool(false), "textRecorded": .bool(false),
        "limits": .object(["records": .number(4096), "bytes": .number(4 * 1024 * 1024), "pending": .number(128)])])
    }
    static func configured() -> Recorder? {
      #if targetEnvironment(simulator)
      let environment = ProcessInfo.processInfo.environment
      guard let raw = environment["NOTEBOOK_NAVIGATION_OBSERVATION_SESSION_ID"], let session = UUID(uuidString: raw),
        session.uuidString != "00000000-0000-0000-0000-000000000000",
        let manifest = environment[NotebookAcceptanceConfiguration.environmentKey], manifest.hasPrefix("/"),
        let size = try? FileManager.default.attributesOfItem(atPath: manifest)[.size] as? Int,
        size > 0, size <= 16_384, let data = try? Data(contentsOf: URL(fileURLWithPath: manifest)),
        let config = try? JSONDecoder().decode(NotebookAcceptanceConfiguration.self, from: data), config.role == .iPad else { return nil }
      let enabled = (Bundle.main.object(forInfoDictionaryKey: "NotebookAcceptanceEnabled") as? Bool) == true
        || (Bundle.main.object(forInfoDictionaryKey: "NotebookAcceptanceEnabled") as? String) == "YES"
      let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).resolvingSymlinksInPath().path + "/"
      guard (try? config.validate(bundle: Bundle.main.bundleIdentifier, enabled: enabled)) != nil,
        config.rootURL.resolvingSymlinksInPath().path.hasPrefix(home),
        URL(fileURLWithPath: manifest).resolvingSymlinksInPath().path.hasPrefix(home) else { return nil }
      return Recorder(session: session, configuration: config)
      #else
      return nil
      #endif
    }
    func append(_ value: [String: JSONValue]) {
      sequence += 1
      var record = value
      record["format"] = .number(1); record["sequence"] = .number(Double(sequence))
      record["sessionID"] = uuid(sessionID); record["launchID"] = uuid(launchID)
      record["receiptMach"] = .string(String(mach_absolute_time()))
      sink.append(.object(record))
    }
  }

  /// Encoding and all file operations run on this queue. The small locked
  /// mailbox bounds pending work; overload is explicit and never stalls input.
  private final class Sink: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Notebook.navigation-observations", qos: .utility)
    private let lock = NSLock()
    private let url: URL
    private var pending = 0, dropped = 0, totalDropped = 0
    private var stopped = false
    private var handle: FileHandle?
    private var bytes = 0, records = 0
    init(url: URL) { self.url = url }
    var accepting: Bool { lock.lock(); defer { lock.unlock() }; return !stopped }
    func append(_ record: JSONValue) {
      lock.lock()
      guard !stopped else { lock.unlock(); return }
      guard pending < 128 else { dropped += 1; totalDropped += 1; lock.unlock(); return }
      pending += 1
      let skipped = dropped; dropped = 0
      lock.unlock()
      queue.async { [self] in
        defer { lock.lock(); pending -= 1; lock.unlock() }
        guard accepting else { return }
        do {
          if handle == nil {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
            handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
          }
          var payload = record
          if case .object(var fields) = record {
            lock.lock(); let droppedCount = totalDropped; lock.unlock()
            if skipped > 0 { fields["droppedBefore"] = .number(Double(skipped)) }
            fields["totalDroppedAtWrite"] = .number(Double(droppedCount)); payload = .object(fields)
          }
          var data = try JSONEncoder().encode(payload); data.append(10)
          guard records < 4_096, bytes + data.count <= 4 * 1_024 * 1_024 else {
            try handle?.write(contentsOf: Data("{\"kind\":\"truncated\",\"reason\":\"diagnostic budget exceeded\"}\n".utf8))
            lock.lock(); stopped = true; lock.unlock(); return
          }
          try handle?.write(contentsOf: data); records += 1; bytes += data.count
        } catch { lock.lock(); stopped = true; lock.unlock() }
      }
    }
  }
}

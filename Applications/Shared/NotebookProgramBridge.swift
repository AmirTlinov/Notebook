import Foundation
import NotebookCore
import WebKit

/// A writer refusal for an obsolete causal basis is not an I/O failure. The
/// old heap has no remaining publication rights and need not pin a closing UI.
enum NotebookProgramCheckpointError: LocalizedError, Equatable {
  case superseded
  var errorDescription: String? { "program_superseded" }
}

/// A selected frame borrows the existing paused owner, never another executor.
/// Its lifetime belongs to the current attention's retained visual sources.
@MainActor
final class NotebookProgramAttentionPause {
  let value: JSONValue
  let isCurrent: @MainActor () -> Bool
  private var continuation: (@MainActor @Sendable () async -> Void)?
  init(value: JSONValue, isCurrent: @escaping @MainActor () -> Bool,
    resume: @escaping @MainActor @Sendable () async -> Void) {
    self.value = value; self.isCurrent = isCurrent; continuation = resume
  }
  func release() {
    guard let resume = continuation else { return }; continuation = nil
    Task { @MainActor in await resume() }
  }
  isolated deinit {
    if let resume = continuation { Task { @MainActor in await resume() } }
  }
}

/// One source for the public browser API; transport remains with each surface.
enum NotebookProgramBridge {
  static let script: String = {
    guard let url = Bundle.main.url(forResource: "notebook-program", withExtension: "js", subdirectory: "WebResources")
      ?? Bundle.main.url(forResource: "notebook-program", withExtension: "js"),
      let source = try? String(contentsOf: url, encoding: .utf8) else {
      // Missing resources must fail preparation, never install a different API.
      return "throw new Error('notebook_program_bridge_missing');"
    }
    return source
  }()

  static let documentScript: String = {
    guard let url = Bundle.main.url(forResource: "document-program", withExtension: "js", subdirectory: "WebResources")
      ?? Bundle.main.url(forResource: "document-program", withExtension: "js"),
      let source = try? String(contentsOf: url, encoding: .utf8) else {
      return "throw new Error('notebook_document_program_bridge_missing');"
    }
    return source
  }()

  @MainActor static func document(block: DocumentBlock, stateJSON: String, token: String,
    package: NotebookProgramPackage, origin: URL, stateCredit: Int = 0) throws -> NotebookProgramAssets.Document {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let configuration: JSONValue = .object(["blockID": .string(block.id), "token": .string(token), "requiresReady": .bool(true), "stateCredit": .number(Double(stateCredit))])
    let json = String(decoding: try encoder.encode(configuration), as: UTF8.self).replacingOccurrences(of: "<", with: "\\u003c")
    return .init(before: """
      <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
      <meta http-equiv="Content-Security-Policy" content="\(NotebookProgramAssets.policy(origin: origin))">
      <style>html,body{margin:0;min-height:100%;background:transparent;color:#171713;font-family:-apple-system,BlinkMacSystemFont,sans-serif}*{box-sizing:border-box}</style>
      \(NotebookProgramAssets.style(package, origin: origin))
      <script>\(script)
      \(documentScript)
      installNotebookDocumentProgram({...\(json),state:\(stateJSON)},createNotebookProgram);</script>
      </head><body>
      """, after: "\(NotebookProgramAssets.script(package, origin: origin))</body></html>")
  }

  @MainActor
  static func semanticSelection(controller: String, expectedToken: String? = nil, in web: WKWebView) async -> ProgramSemanticSelection? {
    guard let value = try? await lifecycle("semanticSelection", controller: controller, expectedToken: expectedToken, in: web), value != .null,
      let selected = try? value.decode(ProgramSemanticSelection.self),
      (try? selected.validate()) != nil else { return nil }
    return selected
  }

  /// One native deadline owns every awaited browser request. WebKit's own
  /// timers may be parked; a late callback has no remaining publication rights.
  /// The in-page deadline also refuses a call queued behind a blocked author.
  @MainActor
  static func request(_ operation: String, script: String, arguments: [String: Any] = [:],
    expectedToken: String? = nil, in web: WKWebView, timeout: Duration = .milliseconds(4500),
    onTimeout: (@MainActor () -> Void)? = nil) async throws -> JSONValue {
    var arguments = arguments
    let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
    arguments["_notebookRequestExpiresAt"] = Date().addingTimeInterval(seconds).timeIntervalSince1970 * 1000
    arguments["_notebookExpectedToken"] = expectedToken ?? ""
    return try await withCheckedThrowingContinuation { continuation in
      var completed = false
      let deadline = Task { @MainActor in
        do { try await Task.sleep(for: timeout) } catch { return }
        guard !completed else { return }; completed = true
        onTimeout?()
        continuation.resume(throwing: SceneRenderError.snapshotPending("program_\(operation)_timeout"))
      }
      web.callAsyncJavaScript("""
        try {
          if(Date.now()>=_notebookRequestExpiresAt) throw new Error('program_\(operation)_timeout');
          if(_notebookExpectedToken!=='' && (typeof notebookLoadToken==='undefined' || notebookLoadToken!==_notebookExpectedToken)) throw new Error('program_superseded');
          const value=await (async()=>{\(script)})();
          return {ok:true,value:value??null};
        } catch(error) { return {ok:false,message:String(error).slice(0,1024)}; }
        """, arguments: arguments, in: nil, in: .page) { result in
        guard !completed else { return }; completed = true; deadline.cancel()
        switch result {
        case .success(let value):
          do {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
            let reply = try JSONDecoder().decode(JSONValue.self, from: data)
            if reply["ok"] == .bool(false), case .string(let message) = reply["message"] {
              if message.contains("program_superseded") { throw NotebookProgramCheckpointError.superseded }
              if message.contains("program_\(operation)_timeout") {
                throw SceneRenderError.snapshotPending("program_\(operation)_timeout")
              }
              throw CollaborationError("program_runtime_error", "\(operation): \(message)")
            }
            guard reply["ok"] == .bool(true), let value = reply["value"] else {
              throw CollaborationError("program_runtime_error", "\(operation): invalid browser reply")
            }
            continuation.resume(returning: value)
          } catch { continuation.resume(throwing: error) }
        case .failure(let error): continuation.resume(throwing: error)
        }
      }
    }
  }

  @MainActor
  static func lifecycle(_ operation: String, controller: String, argument: JSONValue? = nil, expectedToken: String? = nil, in web: WKWebView) async throws -> JSONValue {
    let encoded = String(decoding: try JSONEncoder().encode(argument ?? .null), as: UTF8.self)
    return try await request(operation,
      script: "return hasArgument ? await window[controller][operation](JSON.parse(argument)) : await window[controller][operation]();",
      arguments: ["controller": controller, "operation": operation, "argument": encoded, "hasArgument": argument != nil],
      expectedToken: expectedToken, in: web, onTimeout: {
        web.callAsyncJavaScript("if(expectedToken!=='' && (typeof notebookLoadToken==='undefined' || notebookLoadToken!==expectedToken))return false;return window[controller]?.cancelLifecycle?.();",
          arguments: ["controller": controller, "expectedToken": expectedToken ?? ""], in: nil, in: .page, completionHandler: nil)
      })
  }

}

/// A true admission owns its completion through the durable FIFO, including
/// disk retry. The receipt names the written causal state, never a later read.
struct NotebookProgramStateCompletion: Sendable {
  let admittedBytes: Int?
  let sourceBasis: NotebookProgramStateBasis?
  private let complete: @Sendable (NotebookProgramStateBasis?) -> Void
  init(admittedBytes: Int? = nil, sourceBasis: NotebookProgramStateBasis? = nil,
    _ complete: @escaping @Sendable (NotebookProgramStateBasis?) -> Void) {
    self.admittedBytes = admittedBytes; self.sourceBasis = sourceBasis; self.complete = complete
  }
  func callAsFunction(_ basis: NotebookProgramStateBasis?) { complete(basis) }
}
typealias NotebookProgramStateWriter = (JSONValue, NotebookProgramStateCompletion) -> Bool

/// The scene allocator owns credit; this owner only moves already admitted
/// immutable revisions. Presentation may skip frames, authored commits cannot.
@MainActor
final class NotebookProgramStateTransfer {
  struct Snapshot: Decodable, Equatable, Sendable {
    let revision: String
    let units: Int
    let cost: Int
    var isValid: Bool {
      units >= 0 && units <= (Int.max - 64) / 8 && cost >= units * 8 + 64
    }
  }
  typealias Read = @MainActor (String, Int) async throws -> String
  typealias Acknowledge = @MainActor (String) async throws -> Void
  private let resources: SceneRenderResources
  private var credit: [RasterReservation] = []
  private final class StateRead {
    let descriptor: Snapshot
    var chunks: [String] = []
    var offset = 0
    var value: JSONValue?
    var revoked = false
    init(_ descriptor: Snapshot) { self.descriptor = descriptor }
  }
  private final class Pending {
    let descriptor: Snapshot
    let state: StateRead
    let borrow: WebSurfaceBorrow?
    let read: Read
    let acknowledge: Acknowledge
    let accept: @MainActor (JSONValue, UInt64) async throws -> Void
    let onFailure: @MainActor (Error) -> Void
    var next: Pending?
    var accepted = false
    init(_ descriptor: Snapshot, borrow: WebSurfaceBorrow?, read: @escaping Read,
      acknowledge: @escaping Acknowledge, accept: @escaping @MainActor (JSONValue, UInt64) async throws -> Void,
      onFailure: @escaping @MainActor (Error) -> Void) {
      self.descriptor = descriptor; state = StateRead(descriptor); self.borrow = borrow; self.read = read
      self.acknowledge = acknowledge; self.accept = accept; self.onFailure = onFailure
    }
  }
  private var head: Pending?
  private var last: Pending?
  private var tail: Task<Void, Never>?
  private var checkpointRead: StateRead?
  private var checkpointReservation: RasterReservation?
  var hasPendingCheckpoint: Bool { checkpointRead != nil }
  private var pendingCost = 0
  private var lastRevision: UInt64 = 0
  private var failure: Error?
  private var revoked = false
  var hasFailure: Bool { failure != nil && !revoked }
  private var capacityObserver: NSObjectProtocol?
  private var requestedCredit: (bytes: Int, send: @MainActor (Int) -> Void)?
  let initialCredit: Int
  var admittedCreditBytes: Int { credit.reduce(0) { $0 + $1.byteCount } }

  init(resources: SceneRenderResources, grantsInitialCredit: Bool = true) {
    self.resources = resources
    let available = resources.rasterAdmission
    // Start with one existing resource-read window, or the currently free
    // fraction of it. A larger model requests actual additional admission.
    let bytes = grantsInitialCredit ? max(0, min(1_024 * 1_024, available.byteLimit - available.heldBytes,
      available.passiveByteLimit - available.pinnedBytes - available.passiveReservedBytes)) : 0
    if bytes > 0, let reservation = resources.reserveDerivedBytes(bytes, priority: .passive) {
      credit = [reservation]; initialCredit = bytes
    } else { initialCredit = 0 }
  }

  func requestCredit(_ bytes: Int, send: @escaping @MainActor (Int) -> Void) {
    guard !revoked, bytes > 0, bytes <= resources.passiveByteLimit else { return }
    if let reservation = resources.reserveDerivedBytes(bytes, priority: .passive) {
      credit.append(reservation); requestedCredit = nil
      if let capacityObserver { NotificationCenter.default.removeObserver(capacityObserver); self.capacityObserver = nil }
      send(bytes); return
    }
    requestedCredit = (bytes, send)
    guard capacityObserver == nil else { return }
    capacityObserver = NotificationCenter.default.addObserver(forName: SceneRenderResources.didGainRasterAdmission,
      object: resources, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, let request = self.requestedCredit else { return }
          self.requestCredit(request.bytes, send: request.send)
        }
      }
  }

  func receive(_ descriptor: Snapshot, retaining borrow: WebSurfaceBorrow? = nil, read: @escaping Read, acknowledge: @escaping Acknowledge,
    accept: @escaping @MainActor (JSONValue, UInt64) async throws -> Void, onFailure: @escaping @MainActor (Error) -> Void) {
    guard !revoked, descriptor.isValid, let revision = UInt64(descriptor.revision), revision == lastRevision + 1,
      descriptor.cost <= credit.reduce(0, { $0 + $1.byteCount }) - pendingCost else {
      borrow?.release(); onFailure(SceneRenderError.snapshotPending("program_state_descriptor")); return
    }
    lastRevision = revision; pendingCost += descriptor.cost
    let item = Pending(descriptor, borrow: borrow, read: read, acknowledge: acknowledge, accept: accept, onFailure: onFailure)
    if let last { last.next = item } else { head = item }
    last = item
    startIfNeeded()
  }

  private func startIfNeeded() {
    guard !revoked, tail == nil, failure == nil, head != nil else { return }
    tail = Task { @MainActor [self] in
      defer { tail = nil; if revoked { releasePending() } }

      while let item = head {
        do {
          let value = try await Self.pull(item.state, read: item.read)
          guard !revoked else { return }
          if !item.accepted {
            // Disk retry remains with the existing durable writer. This stage
            // has no browser deadline and is never repeated after success.
            try await item.accept(value, UInt64(item.descriptor.revision)!)
            item.accepted = true
          }
          guard !revoked else { return }
          try await item.acknowledge(item.descriptor.revision)
          head = item.next
          if head == nil { last = nil }
          item.next = nil; item.borrow?.release(); pendingCost -= item.descriptor.cost
        } catch {
          if revoked { return }
          if error is NotebookProgramCheckpointError {
            revoke(); failure = error; item.onFailure(error); return
          }
          // Keep the exact head, its completed windows, accepted write, heap
          // borrow and credit. Later true commits cannot overtake or disappear.
          failure = error; item.onFailure(error); return
        }
      }
    }
  }

  /// Only an explicit owner Retry resumes a failed transport stage.
  func retry() {
    guard !revoked, failure != nil else { return }
    failure = nil
    startIfNeeded()
  }

  /// Replacement/deletion revokes publication, unlike a transport failure.
  /// An already entered durable accept is joined, never cancelled or replayed.
  func revoke() {
    revoked = true; failure = nil
    head?.state.revoked = true
    requestedCredit = nil
    if let capacityObserver { NotificationCenter.default.removeObserver(capacityObserver); self.capacityObserver = nil }
    checkpointRead?.revoked = true
    checkpointRead = nil; checkpointReservation = nil
    if tail == nil { releasePending() }
  }

  private func releasePending() {
    while let item = head {
      head = item.next; item.next = nil; item.borrow?.release()
      pendingCost -= item.descriptor.cost
    }
    last = nil
  }

  func drain() async throws {
    await tail?.value
    if let failure { throw failure }
  }

  /// Readiness is a presentation promise, not state admission. Closing a
  /// not-yet-ready heap must also join descriptors still crossing WebKit IPC,
  /// before the native FIFO can be treated as empty.
  @discardableResult
  func finishAccepted(controller: String, expectedToken: String? = nil, in web: WKWebView) async throws -> Bool {
    let closed = try await NotebookProgramBridge.request("close_commits", script: """
      if(expectedToken!=='' && typeof notebookLoadToken!=='undefined' && notebookLoadToken!==expectedToken) throw new Error('program_superseded');
      const owner=window[controller];
      if(!owner)return false;
      owner.setCommitEnabled(false);return true;
      """, arguments: ["controller": controller, "expectedToken": expectedToken ?? ""], in: web)
    let hasHeap = closed == .bool(true)
    if hasHeap {
      _ = try await NotebookProgramBridge.lifecycle("drainCommits", controller: controller, expectedToken: expectedToken, in: web)
    } else {
      // No author has run in this navigation. Cancel it before a later load
      // could admit its first commit beyond the closing boundary.
      web.stopLoading()
    }
    try await drain()
    return hasHeap
  }

  @MainActor final class Checkpoint {
    let value: JSONValue
    let admittedBytes: Int
    private let owner: NotebookProgramStateTransfer
    private var reservation: RasterReservation?
    init(value: JSONValue, admittedBytes: Int, owner: NotebookProgramStateTransfer, reservation: RasterReservation?) {
      self.value = value; self.admittedBytes = admittedBytes; self.owner = owner; self.reservation = reservation
    }
    func release() { reservation?.release(); reservation = nil }
    isolated deinit { reservation?.release() }
  }

  func checkpoint(_ descriptor: Snapshot, read: @escaping Read) async throws -> Checkpoint {
    try await drain()
    guard !revoked else { throw NotebookProgramCheckpointError.superseded }
    guard descriptor.isValid else { throw SceneRenderError.snapshotPending("program_state_descriptor") }
    if let checkpointRead {
      guard checkpointRead.descriptor == descriptor else { throw SceneRenderError.snapshotPending("program_checkpoint_changed") }
    } else {
      let additional = descriptor.cost - credit.reduce(0, { $0 + $1.byteCount })
      checkpointReservation = additional > 0 ? try await resources.acquirePassiveDerivedBytes(additional) : nil
      checkpointRead = StateRead(descriptor)
    }
    let reservation = checkpointReservation
    defer { withExtendedLifetime(reservation) {} }
    let value = try await Self.pull(checkpointRead!, read: read)
    guard !revoked else { throw NotebookProgramCheckpointError.superseded }
    let snapshot = Checkpoint(value: value, admittedBytes: descriptor.cost, owner: self, reservation: reservation)
    checkpointRead = nil; checkpointReservation = nil
    return snapshot
  }

  private static func pull(_ state: StateRead, read: Read) async throws -> JSONValue {
    guard !state.revoked else { throw NotebookProgramCheckpointError.superseded }
    if let value = state.value { return value }
    while state.offset < state.descriptor.units {
      let chunk = try await read(state.descriptor.revision, state.offset), count = chunk.utf16.count
      guard !state.revoked else { throw NotebookProgramCheckpointError.superseded }
      guard count > 0, count <= 262_144, count <= state.descriptor.units - state.offset else {
        throw SceneRenderError.snapshotPending("program_state_window")
      }
      state.chunks.append(chunk); state.offset += count
    }
    let value = try await decode(state.chunks)
    guard !state.revoked else { throw NotebookProgramCheckpointError.superseded }
    state.value = value; state.chunks.removeAll()
    return value
  }

  private static func decode(_ chunks: [String]) async throws -> JSONValue {
    // Each browser reply is bounded; only the immutable completed revision is
    // joined and decoded away from the input actor.
    try await Task.detached(priority: .userInitiated) {
      try JSONDecoder().decode(JSONValue.self, from: Data(chunks.joined().utf8))
    }.value
  }

  isolated deinit {
    checkpointReservation?.release()
    if let capacityObserver { NotificationCenter.default.removeObserver(capacityObserver) }
    for reservation in credit { reservation.release() }
  }
}

extension NotebookProgramBridge {
  @MainActor static func stateSnapshot(_ descriptor: JSONValue) throws -> NotebookProgramStateTransfer.Snapshot {
    try descriptor.decode(NotebookProgramStateTransfer.Snapshot.self)
  }
  @MainActor static func readState(_ revision: String, offset: Int, controller: String, expectedToken: String? = nil, in web: WKWebView) async throws -> String {
    let result = try await request("state_read", script: "return window[controller].readSnapshot({revision,offset});",
      arguments: ["controller": controller, "revision": revision, "offset": offset], expectedToken: expectedToken, in: web)
    guard case .string(let text) = result else { throw SceneRenderError.snapshotPending("program_state_window") }
    return text
  }
  @MainActor static func acknowledgeState(_ revision: String, controller: String, expectedToken: String? = nil, in web: WKWebView) async throws {
    _ = try await request("state_ack", script: "window[controller].acknowledgeSnapshot(revision);return true;",
      arguments: ["controller": controller, "revision": revision], expectedToken: expectedToken, in: web)
  }
  @MainActor static func grantStateCredit(_ bytes: Int, controller: String, expectedToken: String? = nil, in web: WKWebView) {
    web.callAsyncJavaScript("""
      if(expectedToken!=='' && (typeof notebookLoadToken==='undefined' || notebookLoadToken!==expectedToken)) return false;
      window[controller].grantStateCredit(bytes);return true;
      """, arguments: ["controller": controller, "bytes": bytes, "expectedToken": expectedToken ?? ""], in: nil, in: .page, completionHandler: nil)
  }
}

/// One admitted immutable external state, shared by paper pages until their
/// bounded transfer completes. Encoding and complexity measurement are off the
/// input actor; the existing scene allocator, not a model-size limit, admits it.
@MainActor
final class NotebookProgramStateEncoding {
  let json: String
  let htmlJSON: String
  private let windows: [String]
  private let units: Int
  private let reservation: RasterReservation

  private init(json: String, htmlJSON: String, windows: [String], units: Int, reservation: RasterReservation) {
    self.json = json; self.htmlJSON = htmlJSON; self.windows = windows; self.units = units; self.reservation = reservation
  }

  static func prepare(_ value: JSONValue, resources: SceneRenderResources, forHTML: Bool = false) async throws -> NotebookProgramStateEncoding {
    let bytes = try await Task.detached(priority: .userInitiated) { try allocationBytes(value, forHTML: forHTML) }.value
    let reservation = try await resources.acquirePassiveDerivedBytes(bytes)
    do {
      let encoded = try await Task.detached(priority: .userInitiated) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value), json = String(decoding: data, as: UTF8.self)
        var windows: [String] = [], start = 0
        while start < data.count {
          var end = min(data.count, start + 262_144)
          // Every UTF-8 window is also <=262144 UTF-16 units; preserve a scalar.
          while end < data.count, data[end] & 0xc0 == 0x80 { end -= 1 }
          windows.append(String(decoding: data[start..<end], as: UTF8.self)); start = end
        }
        return (json, windows, json.utf16.count, forHTML ? json.replacingOccurrences(of: "<", with: "\\u003c") : json)
      }.value
      try Task.checkCancellation()
      return .init(json: encoded.0, htmlJSON: encoded.3, windows: encoded.1, units: encoded.2, reservation: reservation)
    } catch { reservation.release(); throw error }
  }

  func send(controller: String, revision: String = "", expectedToken: String? = nil, in web: WKWebView) async throws -> Bool {
    let transfer = UUID().uuidString
    var offset = 0, accepted = false
    do {
      for text in windows {
        try Task.checkCancellation()
        let result = try await NotebookProgramBridge.request("state_apply",
          script: "return await window[controller].receiveStateWindow({transfer,offset,units,text,revision});",
          arguments: ["controller": controller, "transfer": transfer, "offset": offset, "units": units,
            "text": text, "revision": revision], expectedToken: expectedToken, in: web)
        accepted = result == .bool(true)
        guard accepted else { return false }
        offset += text.utf16.count
      }
      return accepted
    } catch {
      web.callAsyncJavaScript("if(expectedToken!=='' && (typeof notebookLoadToken==='undefined' || notebookLoadToken!==expectedToken))return false;return window[controller].receiveStateWindow({transfer,cancel:true});",
        arguments: ["controller": controller, "transfer": transfer, "expectedToken": expectedToken ?? ""], in: nil, in: .page, completionHandler: nil)
      throw error
    }
  }

  nonisolated private static func allocationBytes(_ value: JSONValue, forHTML: Bool) throws -> Int {
    var bytes = 0, nodes = 0, htmlEscapes = 0
    func add(_ count: Int) throws {
      guard count >= 0, bytes <= (Int.max - count) else { throw SceneRenderError.resourceLimit }
      bytes += count
    }
    func string(_ value: String) throws {
      try add(2)
      for byte in value.utf8 {
        try add(byte < 32 ? 6 : (byte == 34 || byte == 92 ? 2 : 1))
        if forHTML, byte == 60 { htmlEscapes += 1 }
      }
    }
    func visit(_ value: JSONValue) throws {
      guard nodes < Int.max / 64 else { throw SceneRenderError.resourceLimit }; nodes += 1
      switch value {
      case .null: try add(4)
      case .bool: try add(5)
      case .number: try add(32)
      case .string(let value): try string(value)
      case .array(let values):
        try add(2 + values.count)
        for value in values { try visit(value) }
      case .object(let values):
        try add(2 + values.count * 2)
        for (key, value) in values { try string(key); try visit(value) }
      }
    }
    try visit(value)
    guard bytes <= (Int.max - nodes * 64) / 8 else { throw SceneRenderError.resourceLimit }
    let base = bytes * 8 + nodes * 64
    guard htmlEscapes <= (Int.max - base) / 10 else { throw SceneRenderError.resourceLimit }
    return max(1, base + htmlEscapes * 10)
  }

  isolated deinit { reservation.release() }
}

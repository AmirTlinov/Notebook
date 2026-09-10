import Foundation
import NotebookCore

/// The metadata surface cannot run/resume a model. The desktop surface cannot take ownership.
actor CodexRPC {
  enum Surface { case desktop, metadata }
  let surface: Surface
  private let channel: CodexChannel
  private var clientID: String?
  private var pending: [String: Pending] = [:]
  private var failure: CodexBridgeError?
  private var onBroadcast: (@Sendable (JSONValue) async throws -> Void)?
  private var onDisconnect: (@Sendable (CodexBridgeError) async -> Void)?
  private struct Pending {
    let method: String
    let owner: String?
    let continuation: CheckedContinuation<JSONValue, Error>
    let timer: Task<Void, Never>
  }
  private static let metadataMethods: Set<String> = ["initialize", "account/read", "thread/list", "thread/turns/list",
    "thread/start", "thread/inject_items", "thread/name/set", "thread/unsubscribe"]

  init(channel: CodexChannel, surface: Surface) { self.channel = channel; self.surface = surface }

  func start(onBroadcast: (@Sendable (JSONValue) async throws -> Void)? = nil,
    onDisconnect: (@Sendable (CodexBridgeError) async -> Void)? = nil) async throws {
    self.onBroadcast = onBroadcast; self.onDisconnect = onDisconnect
    channel.start(receive: { [weak self] in try await self?.receive($0) }, ended: { [weak self] in await self?.ended($0) })
    switch surface {
    case .desktop:
      let result = try await request("initialize", params: .object(["clientType": .string("notebook-sidecar")]))
      guard let id = result["clientId"]?.string, !id.isEmpty else { throw CodexBridgeError.invalidResponse }
      clientID = id
    case .metadata:
      _ = try await request("initialize", params: .object([
        "clientInfo": .object(["name": .string("notebook-desktop-metadata"), "version": .string("1")]),
        "capabilities": .object(["experimentalApi": .bool(true)])]))
      try await channel.send(.object(["method": .string("initialized")]))
    }
  }

  func request(_ method: String, params: JSONValue, owner: String? = nil) async throws -> JSONValue {
    guard surface == .desktop ? CodexDesktopProtocol.versions[method] != nil : Self.metadataMethods.contains(method) else {
      throw CodexBridgeError.unsupportedRequest
    }
    if surface == .metadata, method == "account/read", params != .object(["refreshToken": .bool(false)]) {
      throw CodexBridgeError.invalidInput
    }
    if let failure { throw failure }
    guard pending.count < 16 else { throw CodexBridgeError.busy }
    let id = UUID().uuidString
    var frame: [String: JSONValue] = ["method": .string(method), "params": params]
    switch surface {
    case .metadata: frame["id"] = .string(id)
    case .desktop:
      frame["type"] = .string("request"); frame["requestId"] = .string(id)
      frame["sourceClientId"] = .string(clientID ?? "initializing-client")
      frame["version"] = .number(Double(CodexDesktopProtocol.versions[method]!))
      frame["timeoutMs"] = .number(10_000)
      if let owner { frame["targetClientId"] = .string(owner) }
    }
    let packet = JSONValue.object(frame)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let timer = Task { [weak self] in
          try? await Task.sleep(for: .seconds(12))
          if !Task.isCancelled { await self?.fail(id, .timeout) }
        }
        pending[id] = Pending(method: method, owner: owner, continuation: continuation, timer: timer)
        Task { [weak self, channel] in
          do { try await channel.send(packet) }
          catch { await self?.fail(id, error as? CodexBridgeError ?? .disconnected) }
        }
      }
    } onCancel: { Task { await self.fail(id, .disconnected) } }
  }

  func discover(threadID: String) async throws -> String {
    let result = try await request("thread-owner-discovery", params: .object([
      "hostId": .string("local"), "conversationId": .string(threadID)]))
    guard result["supportsUntrustedAppInput"] == .bool(true), let owner = result["_owner"]?.string,
      owner != clientID else { throw CodexBridgeError.wrongOwner }
    return owner
  }

  func follow(threadID: String, owner: String, enabled: Bool) async throws {
    guard surface == .desktop, let clientID else { throw CodexBridgeError.invalidResponse }
    try await channel.send(.object(["type": .string("broadcast"),
      "method": .string("thread-stream-following-changed"), "version": .number(1),
      "sourceClientId": .string(clientID), "targetClientIds": .array([.string(owner)]),
      "params": .object(["hostId": .string("local"), "conversationId": .string(threadID), "following": .bool(enabled)])]))
  }

  func stop() async {
    channel.stop(); await ended(.disconnected); await channel.waitForExit()
  }

  private func receive(_ frame: JSONValue) async throws {
    if surface == .desktop, frame["type"] == .string("client-discovery-request") {
      guard let id = frame["requestId"]?.string else { throw CodexBridgeError.invalidResponse }
      try await channel.send(.object(["type": .string("client-discovery-response"), "requestId": .string(id),
        "response": .object(["canHandle": .bool(false)])]))
      return
    }
    if surface == .desktop, frame["type"] == .string("broadcast") {
      try await onBroadcast?(frame); return
    }
    let id = (surface == .desktop ? frame["requestId"] : frame["id"])?.string
    guard let id, let waiting = pending[id] else {
      // Metadata helper has no active turns and must never accept tool/approval requests.
      if surface == .metadata, frame["id"] != nil, frame["method"] != nil { throw CodexBridgeError.unsupportedRequest }
      return
    }
    if surface == .desktop {
      guard frame["type"] == .string("response") else { throw CodexBridgeError.invalidResponse }
      if frame["resultType"] == .string("error") {
        let error = frame["error"]?.string ?? ""
        fail(id, error.contains("version-mismatch") ? .incompatibleVersion : error.contains("no-client-found") ? .unavailable : .invalidResponse)
        return
      }
      guard frame["method"] == .string(waiting.method), frame["resultType"] == .string("success"),
        let handler = frame["handledByClientId"]?.string, !handler.isEmpty,
        waiting.owner == nil || waiting.owner == handler,
        var result = frame["result"]?.object else { throw CodexBridgeError.wrongOwner }
      if waiting.method == "initialize", result["clientId"] != .string(handler) { throw CodexBridgeError.wrongOwner }
      if waiting.method == "thread-owner-discovery" { result["_owner"] = .string(handler) }
      complete(id, .object(result))
    } else {
      if frame["error"] != nil { fail(id, .invalidResponse); return }
      guard let result = frame["result"], result.object != nil else { throw CodexBridgeError.invalidResponse }
      complete(id, result)
    }
  }

  private func complete(_ id: String, _ value: JSONValue) {
    guard let request = pending.removeValue(forKey: id) else { return }
    request.timer.cancel(); request.continuation.resume(returning: value)
  }
  private func fail(_ id: String, _ error: CodexBridgeError) {
    guard let request = pending.removeValue(forKey: id) else { return }
    request.timer.cancel(); request.continuation.resume(throwing: error)
  }
  private func ended(_ error: CodexBridgeError) async {
    guard failure == nil else { return }
    failure = error
    for id in Array(pending.keys) { fail(id, error) }
    await onDisconnect?(error)
  }
}

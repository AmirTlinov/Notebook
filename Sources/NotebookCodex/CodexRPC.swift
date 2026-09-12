import Foundation
import NotebookCore

/// One documented JSONL connection. Native requests keep their string or integer IDs.
actor CodexRPC {
  private let channel: CodexChannel
  private var pending: [String: Pending] = [:]
  private var failure: CodexBridgeError?
  private var onEvent: (@Sendable (JSONValue) async throws -> Void)?
  private var onDisconnect: (@Sendable (CodexBridgeError) async -> Void)?
  private struct Pending {
    let continuation: CheckedContinuation<JSONValue, Error>
    let timer: Task<Void, Never>?
  }
  init(channel: CodexChannel) { self.channel = channel }

  func start(onEvent: (@Sendable (JSONValue) async throws -> Void)? = nil,
    onDisconnect: (@Sendable (CodexBridgeError) async -> Void)? = nil) async throws {
    self.onEvent = onEvent; self.onDisconnect = onDisconnect
    channel.start(receive: { [weak self] in try await self?.receive($0) }, ended: { [weak self] in await self?.ended($0) })
    _ = try await request("initialize", params: .object([
      "clientInfo": .object(["name": .string("notebook"), "version": .string("1")]),
      "capabilities": .object(["experimentalApi": .bool(true)])]))
    try await channel.send(.object(["method": .string("initialized")]))
  }

  func request(_ method: String, params: JSONValue, timeout: Duration? = .seconds(12)) async throws -> JSONValue {
    if let failure { throw failure }
    guard pending.count < 16 else { throw CodexBridgeError.busy }
    let id = UUID().uuidString
    let packet = JSONValue.object(["id": .string(id), "method": .string(method), "params": params])
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let timer = timeout.map { duration in Task { [weak self] in
          try? await Task.sleep(for: duration)
          if !Task.isCancelled { await self?.fail(id, .timeout) }
        } }
        pending[id] = Pending(continuation: continuation, timer: timer)
        Task { [weak self, channel] in
          do { try await channel.send(packet) }
          catch { await self?.fail(id, error as? CodexBridgeError ?? .disconnected) }
        }
      }
    } onCancel: { Task { await self.fail(id, .disconnected) } }
  }

  func respond(id: JSONValue, result: JSONValue) async throws {
    if let failure { throw failure }
    try await channel.send(.object(["id": id, "result": result]))
  }

  func stop() async {
    channel.stop(); await ended(.disconnected); await channel.waitForExit()
  }

  private func receive(_ frame: JSONValue) async throws {
    if frame["method"] != nil { try await onEvent?(frame); return }
    guard let id = frame["id"]?.string, pending[id] != nil else { return }
    if let error = frame["error"] {
      let message = error["message"]?.string ?? ""
      fail(id, message.contains("already has an active writer") ? .externalOwnerUnavailable : .invalidResponse)
      return
    }
    guard let result = frame["result"] else { throw CodexBridgeError.invalidResponse }
    guard let waiting = pending.removeValue(forKey: id) else { return }
    waiting.timer?.cancel(); waiting.continuation.resume(returning: result)
  }
  private func fail(_ id: String, _ error: CodexBridgeError) {
    guard let request = pending.removeValue(forKey: id) else { return }
    request.timer?.cancel(); request.continuation.resume(throwing: error)
  }
  private func ended(_ error: CodexBridgeError) async {
    guard failure == nil else { return }
    failure = error
    for id in Array(pending.keys) { fail(id, error) }
    await onDisconnect?(error)
  }
}

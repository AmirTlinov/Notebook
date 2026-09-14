import Foundation
import NotebookScriptProtocol
import NotebookCore

/// The host owns the absolute deadline even when launchd has not reached the
/// sandboxed service's main(). A late OS/service callback can settle only once.
final class NotebookWorkerReplyGate: @unchecked Sendable {
  private let lock = NSLock()
  private var callback: CheckedContinuation<NotebookWorkerReply, Never>?
  private var watchdog: DispatchWorkItem?
  init(_ callback: CheckedContinuation<NotebookWorkerReply, Never>) { self.callback = callback }
  func arm(deadline: ContinuousClock.Instant, reply: NotebookWorkerReply, expired: @escaping @Sendable () -> Void) {
    let task = DispatchWorkItem { [weak self] in
      if self?.finish(reply) == true { expired() }
    }
    let armed = lock.withLock { () -> Bool in
      guard callback != nil else { return false }; watchdog = task; return true
    }
    guard armed else { return }
    let duration = ContinuousClock.now.duration(to: deadline).components
    let seconds = max(0, Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds, execute: task)
  }
  @discardableResult func finish(_ reply: NotebookWorkerReply) -> Bool {
    let (callback, watchdog) = lock.withLock {
      let value = (self.callback, self.watchdog); self.callback = nil; self.watchdog = nil; return value
    }
    watchdog?.cancel()
    callback?.resume(returning: reply)
    return callback != nil
  }
}

/// The connection is accessed only on its worker's serial XPC queue. The
/// unchecked boundary moves this handle between the lock and that queue;
/// it does not claim that arbitrary NSXPCConnection use is Sendable.
private final class NotebookWorkerConnection: @unchecked Sendable {
  let value: NSXPCConnection
  init(_ value: NSXPCConnection) { self.value = value }
}

final class NotebookXPCWorker: NSObject, NotebookScriptBrokerProtocol, @unchecked Sendable {
  typealias Host = @Sendable (NotebookWorkerCall) async -> NotebookWorkerReply
  private let serviceName: String
  private let host: Host
  private let lock = NSLock()
  private let queue = DispatchQueue(label: "Notebook.Script.XPC", qos: .userInitiated)
  private var connection: NotebookWorkerConnection?
  private var pending: NotebookWorkerReplyGate?
  private var stopped: NotebookWorkerReply?

  init(serviceName: String, host: @escaping Host) {
    self.host = host; self.serviceName = serviceName
    super.init()
  }

  func execute(_ request: NotebookWorkerRequest,
    deadline: ContinuousClock.Instant = .now + .seconds(30),
    timeoutCode: String = "script_timeout") async -> NotebookWorkerReply {
    guard let bytes = try? JSONEncoder().encode(request) else { return .init(code: "invalid_script") }
    return await exchange(deadline: deadline, timeoutCode: timeoutCode) { remote, reply in
      remote.execute(bytes) { data in
        guard data.count <= 32*1024*1024 else { reply.finish(.init(code: "resource_limit")); return }
        reply.finish((try? JSONDecoder().decode(NotebookWorkerReply.self, from: data)) ?? .init(code: "invalid_worker_reply"))
      }
    }
  }

  func cancel(_ id: UUID) {
    stop(.init(code: "run_cancelled", message: NotebookStore.scriptCancellationError.message), cancelling: id)
  }
  func compile(_ request: NotebookCompilerRequest,
    deadline: ContinuousClock.Instant = .now + .seconds(120)) async -> NotebookWorkerReply {
    guard let bytes = try? JSONEncoder().encode(request), bytes.count <= 32*1024*1024 else {
      return .init(code: "resource_limit", message: "Печатный исходник превышает допустимый размер.")
    }
    return await exchange(deadline: deadline, timeoutCode: "export_timeout", unavailableCode: "compiler_unavailable") { remote, reply in
      remote.compile(bytes) { data in
        guard data.count <= 32*1024*1024 else { reply.finish(.init(code: "resource_limit")); return }
        reply.finish((try? JSONDecoder().decode(NotebookWorkerReply.self, from: data)) ?? .init(code: "invalid_worker_reply"))
      }
    }
  }
  func invalidate() { stop(.init(code: "script_worker_unavailable", message: "Соединение с изолированным исполнителем закрыто.")) }

  private func exchange(deadline: ContinuousClock.Instant, timeoutCode: String,
    unavailableCode: String = "script_worker_unavailable",
    send: @escaping @Sendable (NotebookScriptServiceProtocol, NotebookWorkerReplyGate) -> Void) async -> NotebookWorkerReply {
    await withCheckedContinuation { continuation in
      let reply = NotebookWorkerReplyGate(continuation)
      let refusal = lock.withLock { () -> NotebookWorkerReply? in
        if let stopped { return stopped }
        guard pending == nil else { return .init(code: "worker_busy") }
        pending = reply; return nil
      }
      if let refusal { reply.finish(refusal); return }
      let timeout = NotebookWorkerReply(code: timeoutCode, message: "Истёк срок изолированного исполнения, включая запуск сервиса.")
      reply.arm(deadline: deadline, reply: timeout) { [weak self] in self?.stop(timeout) }
      // Creation/proxy dispatch must never hold MainActor or the writer while
      // macOS starts a sandbox container. The host watchdog is independent.
      queue.async { [self] in
        guard ContinuousClock.now < deadline else { if reply.finish(timeout) { stop(timeout) }; return }
        guard let connection = openConnection() else { return }
        guard let remote = connection.remoteObjectProxyWithErrorHandler({ _ in
          reply.finish(.init(code: unavailableCode, message: "Изолированный исполнитель Notebook недоступен."))
        }) as? NotebookScriptServiceProtocol else {
          reply.finish(.init(code: unavailableCode)); return
        }
        guard lock.withLock({ stopped == nil }) else { return }
        send(remote, reply)
      }
    }
  }

  private func openConnection() -> NSXPCConnection? {
    guard lock.withLock({ stopped == nil }) else { return nil }
    let value = NSXPCConnection(serviceName: serviceName)
    value.remoteObjectInterface = NSXPCInterface(with: NotebookScriptServiceProtocol.self)
    value.exportedInterface = NSXPCInterface(with: NotebookScriptBrokerProtocol.self)
    value.exportedObject = self
    let opened = lock.withLock { () -> Bool in
      guard stopped == nil else { return false }; connection = NotebookWorkerConnection(value); return true
    }
    guard opened else { value.invalidate(); value.exportedObject = nil; return nil }
    value.resume()
    return value
  }

  private func stop(_ reason: NotebookWorkerReply, cancelling id: UUID? = nil) {
    let (connection, reply, reason) = lock.withLock {
      if stopped == nil { stopped = reason }
      let value = (self.connection, pending, stopped!)
      self.connection = nil; pending = nil
      return value
    }
    reply?.finish(reason)
    guard let connection else { return }
    // NSXPC teardown is best effort. It cannot delay the host's terminal
    // result if macOS itself is still waiting before the service enters main.
    queue.async {
      let value = connection.value
      if let id, let remote = value.remoteObjectProxyWithErrorHandler({ _ in }) as? NotebookScriptServiceProtocol {
        remote.cancel(id.uuidString.lowercased(), withReply: {})
      }
      value.invalidate(); value.exportedObject = nil
    }
  }

  func call(_ request: Data, withReply reply: @escaping (Data) -> Void) {
    let box = BrokerReply(reply)
    guard request.count <= 44*1024*1024, let call = try? JSONDecoder().decode(NotebookWorkerCall.self, from: request),
      call.arguments.count <= 32*1024*1024 else {
      box.send(.init(code: "invalid_sdk_call")); return
    }
    Task { box.send(await host(call)) }
  }
}

private final class BrokerReply: @unchecked Sendable {
  let reply: (Data) -> Void
  init(_ reply: @escaping (Data) -> Void) { self.reply = reply }
  func send(_ value: NotebookWorkerReply) { reply((try? JSONEncoder().encode(value)) ?? Data("{}".utf8)) }
}

/// Independent from user-run admission. The previous normalization can finish
/// even when its caller is cancelled, without holding a SQLite transaction.
actor NotebookMarkupQueue {
  private let serviceName: String
  private var tail: Task<JSONValue, Error>?
  private var tailID: UUID?
  init(serviceName: String) { self.serviceName = serviceName }
  func normalize(_ arguments: JSONValue) async throws -> JSONValue {
    let id = UUID()
    let previous = tail, serviceName = serviceName
    let task = Task<JSONValue, Error> {
      _ = try? await previous?.value
      let worker = NotebookXPCWorker(serviceName: serviceName) { _ in .init(code: "host_unavailable") }
      defer { worker.invalidate() }
      let reply = await worker.execute(.init(id: UUID(), code: "", arguments: try JSONEncoder().encode(arguments)),
        deadline: .now + .seconds(8), timeoutCode: "normalization_timeout")
      if let code = reply.code { throw CollaborationError(code, reply.message ?? "Доверенная нормализация не завершилась.") }
      guard let value = reply.value else { throw CollaborationError("normalization_failed", "Нет результата нормализации.") }
      return try JSONDecoder().decode(JSONValue.self, from: value)
    }
    tail = task
    tailID = id
    // A completed Task retains its result. Drop only our own final tail: a
    // later normalization may already be waiting on it while this awaits.
    defer { if tailID == id { tail = nil; tailID = nil } }
    return try await task.value
  }

  /// Export is a distinct persisted job and connection. Waiting for its PDF
  /// does not hold the normalization tail or a user script's wall budget.
  func compile(id: UUID, source: String, assets: [NotebookCompilerAsset] = []) async throws -> NotebookCompilerResult {
    let worker = NotebookXPCWorker(serviceName: serviceName) { _ in .init(code: "host_unavailable") }
    defer { worker.invalidate() }
    let reply = await worker.compile(.init(id: id, source: source, assets: assets))
    if let code = reply.code { throw CollaborationError(code, reply.message ?? "Экспорт не завершился.") }
    guard let value = reply.value else { throw CollaborationError("export_failed", "Нет результата компиляции.") }
    let result = try JSONDecoder().decode(NotebookCompilerResult.self, from: value)
    guard result.pdf.count <= 16*1024*1024, result.pdf.starts(with: Data("%PDF-".utf8)) else {
      throw CollaborationError("invalid_artifact", "Компилятор не вернул допустимый PDF.")
    }
    return result
  }
}

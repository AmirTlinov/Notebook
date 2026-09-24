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
  func compileTypeScript(_ request: NotebookTypeScriptRequest,
    deadline: ContinuousClock.Instant = .now + .seconds(10)) async -> NotebookWorkerReply {
    guard let bytes = try? JSONEncoder().encode(request), bytes.count <= 2*1024*1024 else { return .init(code: "resource_limit") }
    return await exchange(deadline: deadline, timeoutCode: "typescript_timeout", unavailableCode: "compiler_unavailable") { remote, reply in
      remote.compileTypeScript(bytes) { data in
        // Source-map Data and then the result Data are both base64 encoded.
        // This is only the internal compiler envelope, not an MCP output limit.
        guard data.count <= 4*1024*1024 else { reply.finish(.init(code: "resource_limit")); return }
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

/// A normalization is cancellable preparation, not an accepted native write.
/// The run owns both waiting descriptors and the one active XPC operation.
protocol NotebookMarkupWorker: Sendable {
  func execute(_ request: NotebookWorkerRequest, deadline: ContinuousClock.Instant, timeoutCode: String) async -> NotebookWorkerReply
  func cancel(_ id: UUID)
  func invalidate()
}
extension NotebookXPCWorker: NotebookMarkupWorker {}

actor NotebookMarkupQueue {
  private struct Job {
    let runID: UUID
    let effectID: UUID
    let arguments: JSONValue
    let continuation: CheckedContinuation<JSONValue, Error>
  }
  private let makeWorker: @Sendable () -> any NotebookMarkupWorker
  private var runID: UUID?
  private var waiting: [Job] = []
  private var active: (job: Job, worker: any NotebookMarkupWorker)?

  init(serviceName: String) {
    makeWorker = { NotebookXPCWorker(serviceName: serviceName) { _ in .init(code: "host_unavailable") } }
  }
  init(makeWorker: @escaping @Sendable () -> any NotebookMarkupWorker) { self.makeWorker = makeWorker }

  func beginRun(_ id: UUID) {
    if let previous = runID { endRun(previous) }
    runID = id
  }

  func endRun(_ id: UUID) {
    guard runID == id else { return }
    runID = nil
    let pending = waiting; waiting.removeAll()
    for job in pending { job.continuation.resume(throwing: NotebookStore.scriptCancellationError) }
    if let active {
      self.active = nil
      active.worker.cancel(active.job.effectID)
      active.worker.invalidate()
      active.job.continuation.resume(throwing: NotebookStore.scriptCancellationError)
    }
  }

  func normalize(runID: UUID, effectID: UUID, arguments: JSONValue) async throws -> JSONValue {
    guard self.runID == runID else { throw NotebookStore.scriptCancellationError }
    return try await withCheckedThrowingContinuation { continuation in
      waiting.append(.init(runID: runID, effectID: effectID, arguments: arguments, continuation: continuation))
      drive()
    }
  }

  private func drive() {
    guard active == nil, !waiting.isEmpty else { return }
    let job = waiting.removeFirst(), worker = makeWorker()
    active = (job, worker)
    Task {
      let result: Result<JSONValue, Error>
      do {
        let reply = await worker.execute(.init(id: job.effectID, code: "", arguments: try JSONEncoder().encode(job.arguments)),
          deadline: .now + .seconds(8), timeoutCode: "normalization_timeout")
        if let code = reply.code { throw CollaborationError(code, reply.message ?? "Доверенная нормализация не завершилась.") }
        guard let value = reply.value else { throw CollaborationError("normalization_failed", "Нет результата нормализации.") }
        result = .success(try JSONDecoder().decode(JSONValue.self, from: value))
      } catch { result = .failure(error) }
      worker.invalidate()
      finish(job, result: result)
    }
  }

  private func finish(_ job: Job, result: Result<JSONValue, Error>) {
    // endRun already settled a cancelled continuation. A late service reply
    // cannot settle it again or consume a new run's active operation.
    guard active?.job.runID == job.runID, active?.job.effectID == job.effectID else { return }
    active = nil
    job.continuation.resume(with: result)
    drive()
  }
}

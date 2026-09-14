import CQuickJS
import Foundation
import NotebookScriptProtocol

/// One interpreter, owned by one serial worker queue. Host operations always
/// suspend through a promise; they never block the interpreter or the writer.
public final class NotebookQuickJSEngine: @unchecked Sendable {
  public typealias Host = @Sendable (String, Data, @escaping @Sendable (NotebookWorkerReply) -> Void) -> Void
  private let queue = DispatchQueue(label: "Notebook.Script.interpreter", qos: .userInitiated)
  private let lock = NSLock()
  private var runtime: OpaquePointer?
  private var completed = false
  private var cancellationRequested = false
  private let bootstrap: String
  private let host: Host
  private let maximumArguments: Int
  private let maximumResultBytes: Int
  private var completion: (@Sendable (NotebookWorkerReply) -> Void)?
  private var idlePolls = 0

  public init(bootstrap: String, maximumArguments: Int = 1_048_576, maximumResultBytes: Int = 1_048_576, host: @escaping Host) {
    self.bootstrap = bootstrap; self.host = host; self.maximumArguments = maximumArguments; self.maximumResultBytes = maximumResultBytes
  }

  public func start(code: String, arguments: Data, completion: @escaping @Sendable (NotebookWorkerReply) -> Void) {
    queue.async { [self] in
      guard self.completion == nil, !completed, code.utf8.count <= 262_144, arguments.count <= maximumArguments,
        let arguments = String(data: arguments, encoding: .utf8) else {
        completion(.init(code: "resource_limit", message: "Source or arguments exceed the documented limit.")); return
      }
      self.completion = completion
      let opaque = Unmanaged.passUnretained(self).toOpaque()
      let created = nq_create(128*1024*1024, 1024*1024, 5, { opaque, sequence, method, json in
        guard let opaque, let method, let json else { return }
        let owner = Unmanaged<NotebookQuickJSEngine>.fromOpaque(opaque).takeUnretainedValue()
        owner.invoke(sequence: sequence, method: String(cString: method), arguments: Data(String(cString: json).utf8))
      }, opaque)
      lock.withLock {
        runtime = created
        if cancellationRequested, let created { nq_cancel(created) }
      }
      guard let created else { finish(.init(code: "resource_limit", message: "QuickJS allocation failed.")); return }
      nq_set_result_limit(created, maximumResultBytes)
      guard nq_bootstrap(created, bootstrap) == 0, nq_start(created, code, arguments) == 0 else {
        fail(created); return
      }
      pump()
    }
  }

  /// The C interrupt flag is atomic. This queue is intentionally independent
  /// from the serial interpreter, which may currently be executing a loop.
  public func cancel() {
    lock.withLock {
      cancellationRequested = true
      if let runtime { nq_cancel(runtime) }
    }
    // An outstanding host promise otherwise leaves the interpreter asleep
    // until the host answers. Interrupting must not depend on that reply.
    queue.async { [self] in pump() }
  }

  private func invoke(sequence: UInt64, method: String, arguments: Data) {
    host(method, arguments) { [weak self] reply in
      guard let self else { return }
      self.queue.async { [self] in
        guard !completed, let runtime else { return }
        let data = reply.value ?? (try? JSONEncoder().encode(reply)) ?? Data("null".utf8)
        guard data.count <= 32*1024*1024, let text = String(data: data, encoding: .utf8) else {
          finish(.init(code: "resource_limit", message: "Host response exceeded its bounded payload.")); return
        }
        guard nq_resolve(runtime, sequence, text, reply.code == nil ? 0 : 1) == 0 else { fail(runtime); return }
        idlePolls = 0; pump()
      }
    }
  }

  private func pump() {
    guard !completed, let runtime else { return }
    switch nq_pump(runtime) {
    case 1:
      guard let string = nq_result(runtime) else { fail(runtime); return }
      let data = Data(String(cString: string).utf8); nq_free_string(string)
      finish(.init(value: data))
    case -1: fail(runtime)
    default:
      // A promise with no host work may have another bounded job turn. It may
      // also be deliberately unresolved; the service's wall watchdog owns it.
      if nq_pending(runtime) == 0 {
        idlePolls += 1
        queue.asyncAfter(deadline: .now() + .milliseconds(1)) { [weak self] in self?.pump() }
      }
    }
  }

  private func fail(_ runtime: OpaquePointer) {
    let text = nq_error(runtime)
    let message = text.map { String(cString: $0) } ?? "QuickJS resource limit"
    if let text { nq_free_string(text) }
    finish(.init(code: message.contains("interrupted") || message == "cancelled" ? "script_interrupted" : "script_failed",
      message: String(message.prefix(4096))))
  }

  private func finish(_ result: NotebookWorkerReply) {
    guard !completed else { return }; completed = true
    lock.withLock { if let runtime { nq_destroy(runtime); self.runtime = nil } }
    let callback = completion; completion = nil; callback?(result)
  }
}

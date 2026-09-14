import Foundation
import NotebookScriptProtocol
import Darwin

private final class DataReply: @unchecked Sendable {
  let reply: (Data) -> Void
  init(_ reply: @escaping (Data) -> Void) { self.reply = reply }
}

public final class NotebookScriptService: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
  public enum Mode: Sendable { case user, markup }
  private let mode: Mode
  private let bootstrap: String
  public init(mode: Mode, bootstrap: String) { self.mode = mode; self.bootstrap = bootstrap }

  public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
    let worker = Session(connection: connection, mode: mode, bootstrap: bootstrap)
    connection.exportedInterface = NSXPCInterface(with: NotebookScriptServiceProtocol.self)
    connection.exportedObject = worker
    connection.remoteObjectInterface = NSXPCInterface(with: NotebookScriptBrokerProtocol.self)
    connection.invalidationHandler = { worker.invalidate() }
    connection.resume(); return true
  }
}

private final class Session: NSObject, NotebookScriptServiceProtocol, @unchecked Sendable {
  let connection: NSXPCConnection
  let mode: NotebookScriptService.Mode
  let bootstrap: String
  let lock = NSLock()
  var activeID: UUID?
  var engine: NotebookQuickJSEngine?
  var compilation: Task<Void, Never>?
  var sequence: UInt64 = 0

  init(connection: NSXPCConnection, mode: NotebookScriptService.Mode, bootstrap: String) {
    self.connection = connection; self.mode = mode; self.bootstrap = bootstrap
  }

  func execute(_ request: Data, withReply reply: @escaping (Data) -> Void) {
    let reply = DataReply(reply)
    guard request.count <= (mode == .user ? 2 : 44)*1024*1024, let value = try? JSONDecoder().decode(NotebookWorkerRequest.self, from: request),
      lock.withLock({ if activeID != nil { return false }; activeID = value.id; sequence = 0; return true }) else {
      respond(.init(code: "worker_busy", message: "The Mac coordinator owns admission."), reply); return
    }
    let code: String
    switch mode {
    case .user: code = value.code
    case .markup:
      // The trusted service never evaluates request.code. Its only source is
      // the bundled parser; request.arguments contains data, not instructions.
      guard value.code.isEmpty else {
        lock.withLock { activeID = nil }; respond(.init(code: "invalid_markup_request"), reply); return
      }
      code = "return globalThis.notebookMarkup(args);"
    }
    let worker = NotebookQuickJSEngine(bootstrap: bootstrap, maximumArguments: (mode == .user ? 1 : 32)*1024*1024,
      // The data-only reply base64-encodes these JSON bytes once more. Reserve
      // envelope space under the transport's 32 MiB limit before evaluation.
      maximumResultBytes: mode == .user ? 262_144 : 23*1024*1024) { [weak self] method, args, done in
      guard let self, self.mode == .user else { done(.init(code: "host_unavailable")); return }
      let call = self.lock.withLock { () -> NotebookWorkerCall in
        self.sequence += 1
        return .init(runID: value.id, sequence: self.sequence, method: method, arguments: args)
      }
      guard let data = try? JSONEncoder().encode(call),
        let broker = self.connection.remoteObjectProxyWithErrorHandler({ _ in done(.init(code: "broker_disconnected")) }) as? NotebookScriptBrokerProtocol else {
        done(.init(code: "broker_disconnected")); return
      }
      broker.call(data) { bytes in
        done((try? JSONDecoder().decode(NotebookWorkerReply.self, from: bytes)) ?? .init(code: "invalid_broker_reply"))
      }
    }
    lock.withLock { engine = worker }
    // Hard wall watchdog is outside the interpreter. If interrupted C/native
    // work does not return, this terminates only this sandboxed service.
    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + (mode == .user ? 30 : 8)) { [weak self] in
      guard let self, self.lock.withLock({ self.activeID == value.id }) else { return }
      NotebookSandboxedTeXCompiler.terminateChildren()
      _exit(70)
    }
    worker.start(code: code, arguments: value.arguments) { [weak self] result in
      guard let self else { return }
      self.lock.withLock { self.engine = nil; self.activeID = nil }
      self.respond(result, reply)
    }
  }

  func compile(_ request: Data, withReply reply: @escaping (Data) -> Void) {
    let reply = DataReply(reply)
    guard mode == .markup else { respond(.init(code: "compiler_unavailable"), reply); return }
    guard request.count <= 32*1024*1024,
      let value = try? JSONDecoder().decode(NotebookCompilerRequest.self, from: request),
      value.source.utf8.count <= 4*1024*1024 else {
      respond(.init(code: "resource_limit", message: "Печатный исходник превышает 4 МиБ."), reply); return
    }
    lock.withLock {
      guard activeID == nil else { respond(.init(code: "worker_busy"), reply); return }
      activeID = value.id
      // A separate XPC connection owns each compiler. It never joins the
      // serial parser queue or a user-run admission queue.
      compilation = Task { [weak self] in
        let result = await NotebookSandboxedTeXCompiler.compile(value)
        guard let self else { return }
        self.lock.withLock { self.compilation = nil; self.activeID = nil }
        self.respond(result, reply)
      }
    }
  }

  func cancel(_ runID: String, withReply reply: @escaping () -> Void) {
    let (worker, compiler) = lock.withLock {
      activeID?.uuidString.lowercased() == runID.lowercased() ? (engine, compilation) : (nil, nil)
    }
    worker?.cancel(); compiler?.cancel(); reply()
    if worker != nil {
      DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
        guard let self, self.lock.withLock({ self.activeID?.uuidString.lowercased() == runID.lowercased() }) else { return }
        NotebookSandboxedTeXCompiler.terminateChildren()
        _exit(71)
      }
    }
  }
  func invalidate() {
    let (worker, compiler) = lock.withLock { (engine, compilation) }
    worker?.cancel(); compiler?.cancel()
  }
  private func respond(_ value: NotebookWorkerReply, _ reply: DataReply) {
    reply.reply((try? JSONEncoder().encode(value)) ?? Data("{}".utf8))
  }
}

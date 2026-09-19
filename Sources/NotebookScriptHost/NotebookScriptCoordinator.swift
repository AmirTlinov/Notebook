import Foundation
import NotebookCore
import NotebookScriptProtocol

/// One instance belongs to the existing Mac application owner. MCP processes
/// only attach through IPC; no sidecar owns an interpreter, journal or queue.
@MainActor
public final class NotebookScriptCoordinator {
  public typealias Command = @Sendable (NotebookCommand) async throws -> JSONValue
  public typealias Persistence = @Sendable (@escaping @Sendable (NotebookStore) throws -> JSONValue) async throws -> JSONValue
  public typealias CanonicalExport = @MainActor (DocumentDocument, UUID) async throws -> NotebookExportPublication
  let canonicalExport: CanonicalExport
  let command: Command
  let persistence: Persistence
  let markup: NotebookMarkupQueue
  let userServiceName: String
  let markupServiceName: String
  let workingDirectory: URL
  var initialization: Task<Void, Error>?
  var waiting: [NotebookScriptRun] = []
  var active: UUID?
  var worker: NotebookXPCWorker?
  var runningTask: Task<Void, Never>?
  var cancelled = Set<UUID>()
  var finishedWorkers = Set<UUID>()
  var acceptedCalls = 0
  var effectTasks: [UUID: Task<JSONValue, Error>] = [:]
  var inFlightEffects = 0
  var effectDrainWaiters: [CheckedContinuation<Void, Never>] = []
  var exportTasks: [UUID: Task<Void, Never>] = [:]
  var closing = false
  private var admissions = 0
  private var admissionWaiters: [CheckedContinuation<Void, Never>] = []

  /// A client attachment, not a run result cache. Registration precedes the
  /// async journal read, so a terminal write cannot fall into a read/wait gap.
  @MainActor final class RunCompletionWaiter {
    var result: Result<Void, Error>?
    var continuation: CheckedContinuation<Void, Error>?
    var deadlineTask: Task<Void, Never>?

    func finish(_ value: Result<Void, Error>) {
      guard result == nil else { return }
      result = value
      deadlineTask?.cancel(); deadlineTask = nil
      continuation?.resume(with: value); continuation = nil
    }

    func value() async throws {
      if let result { return try result.get() }
      try await withCheckedThrowingContinuation { continuation = $0 }
    }
  }
  var completionWaiters: [UUID: [UUID: RunCompletionWaiter]] = [:]

  public init(command: @escaping Command, persistence: @escaping Persistence, workingDirectory: URL,
    canonicalExport: @escaping CanonicalExport = { _, _ in throw CollaborationError("print_owner_unavailable", "Владелец печатного макета недоступен.") },
    userServiceName: String = NotebookScriptServiceNames.user,
    markupServiceName: String = NotebookScriptServiceNames.markup) {
    self.canonicalExport = canonicalExport
    self.command = command; self.persistence = persistence; self.workingDirectory = workingDirectory
    self.userServiceName = userServiceName; self.markupServiceName = markupServiceName
    markup = NotebookMarkupQueue(serviceName: markupServiceName)
  }

  /// The Mac owner awaits recovery before publishing IPC readiness. Status
  /// reads remain pure and never start recovery, a worker or a compiler.
  public func start() async throws {
    guard !closing else { throw CollaborationError("owner_unavailable", "Mac завершает работу.") }
    try await initialize()
    guard !closing else { throw CollaborationError("owner_unavailable", "Mac завершает работу.") }
  }

  public func handle(_ request: NotebookScriptRequest) async throws -> JSONValue {
    guard request.apiVersion == 2 else { throw CollaborationError("api_version_mismatch", "Нужен согласованный MCP API v2; исторические runs читаются через resume v2.") }
    let deadline = ContinuousClock.now + .milliseconds(request.waitMilliseconds ?? 1000)
    guard !closing || request.op == .resume else { throw CollaborationError("owner_unavailable", "Mac завершает работу; новые программы не принимаются.") }
    try await initialize()
    guard !closing || request.op == .resume else { throw CollaborationError("owner_unavailable", "Mac завершает работу; новые программы не принимаются.") }
    guard (0...4000).contains(request.waitMilliseconds ?? 1000), (request.afterSequence ?? 0) >= 0 else {
      throw CollaborationError("invalid_script_request", "wait_ms ограничен четырьмя секундами, after_seq неотрицателен.")
    }
    switch request.op {
    case .start:
      try await enqueue(request)
    case .resume:
      let ids = try await persistence { try .encode($0.terminalScriptEffectsForRecovery(request.runID)) }.decode([UUID].self)
      for id in ids { _ = try await reconcileEffect(runID: request.runID, id: id) }
    case .cancel:
      waiting.removeAll { $0.id == request.runID }
      if active == request.runID { cancelled.insert(request.runID); worker?.cancel(request.runID) }
      try await cancelRun(request.runID)
    }
    return try await readRunAfterCompletion(request, deadline: deadline)
  }

  private func readRunAfterCompletion(_ request: NotebookScriptRequest, deadline: ContinuousClock.Instant) async throws -> JSONValue {
    try Task.checkCancellation()
    guard ContinuousClock.now < deadline else {
      return try await persistence { try $0.scriptRunPage(request.runID, after: request.afterSequence ?? 0) }
    }
    let token = UUID(), waiter = RunCompletionWaiter(), runID = request.runID
    completionWaiters[runID, default: [:]][token] = waiter
    waiter.deadlineTask = Task { @concurrent [weak self] in
      do { try await Task.sleep(until: deadline, clock: .continuous) }
      catch { return }
      await self?.releaseCompletionWaiter(runID, token: token, result: .success(()))
    }
    return try await withTaskCancellationHandler {
      defer { releaseCompletionWaiter(runID, token: token, result: .success(())) }
      try Task.checkCancellation()
      let page = try await persistence { try $0.scriptRunPage(runID, after: request.afterSequence ?? 0) }
      guard ["queued", "running"].contains(page.string("status") ?? "") else { return page }
      try await waiter.value()
      try Task.checkCancellation()
      return try await persistence { try $0.scriptRunPage(runID, after: request.afterSequence ?? 0) }
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.releaseCompletionWaiter(runID, token: token, result: .failure(CancellationError()))
      }
    }
  }

  private func releaseCompletionWaiter(_ runID: UUID, token: UUID, result: Result<Void, Error>) {
    let waiter = completionWaiters[runID]?.removeValue(forKey: token)
    if completionWaiters[runID]?.isEmpty == true { completionWaiters[runID] = nil }
    waiter?.finish(result)
  }

  private func didFinishRun(_ id: UUID) {
    guard let clients = completionWaiters.removeValue(forKey: id) else { return }
    for client in clients.values { client.finish(.success(())) }
  }

  private func cancelRun(_ id: UUID) async throws {
    let run = try await persistence { try .encode($0.requestScriptRunCancellation(id)) }.decode(NotebookScriptRun.self)
    // Running cancellation is only a request: accepted effects still drain.
    if run.isTerminal { didFinishRun(id) }
  }

  func finishRun(_ id: UUID, state: NotebookScriptRun.State, result: JSONValue? = nil, error: JSONValue? = nil) async throws {
    let run = try await persistence { try .encode($0.setScriptRunState(id, state: state, result: result, error: error)) }.decode(NotebookScriptRun.self)
    if run.isTerminal { didFinishRun(id) }
  }

  public func context(_ request: NotebookScriptContextRequest) async throws -> JSONValue {
    guard request.apiVersion == 2 else { throw CollaborationError("api_version_mismatch", "Нужен согласованный MCP API v2.") }
    if request.method == "help" { return try NotebookScriptAPI.documentation(request.arguments.string("topic")) }
    guard NotebookScriptAPI.readMethods.contains(request.method) else {
      throw CollaborationError("read_method_required", "Изменения выполняются через notebook_execute и устойчивый key.")
    }
    return try await read(method: request.method, arguments: request.arguments)
  }

  public func shutdown() async {
    closing = true
    let pending = waiting; waiting.removeAll()
    for run in pending {
      try? await cancelRun(run.id)
    }
    if let active {
      cancelled.insert(active); worker?.cancel(active)
      try? await cancelRun(active)
    }
    if admissions > 0 {
      await withCheckedContinuation { admissionWaiters.append($0) }
    }
    await runningTask?.value
    for task in exportTasks.values { await task.value }
    worker?.invalidate(); worker = nil
  }

  private func enqueue(_ request: NotebookScriptRequest) async throws {
    admissions += 1
    defer {
      admissions -= 1
      if admissions == 0 {
        let waiters = admissionWaiters; admissionWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
      }
    }
    let identity = request.language == .typescript ? NotebookTypeScriptPreparation.bundledIdentity : nil
    let value = try await persistence {
      try .encode($0.admitScriptRun(request, compilerVersion: identity?.compilerVersion, sdkVersion: identity?.sdkVersion))
    }.decode(NotebookScriptRun.self)
    // Shutdown/cancel may run while the native admission reply is in flight.
    // The durable state, not this earlier queued snapshot, owns execution.
    if closing {
      if !value.isTerminal { try await finishRun(value.id, state: .cancelled) }
      return
    }
    if !value.isTerminal, active != value.id, !waiting.contains(where: { $0.id == value.id }) {
      waiting.append(value); drive()
    }
  }

  private func initialize() async throws {
    if let initialization { return try await initialization.value }
    let access = persistence
    let task = Task<Void, Error> { [self] in
      _ = try await access { try $0.interruptUnfinishedScriptExports(); return .null }
      var after: UUID?
      while true {
        let cursor = after
        let page = try await access { try .encode($0.unfinishedScriptEffects(after: cursor)) }.decode([NotebookScriptEffectAddress].self)
        for address in page { _ = try await reconcileEffect(runID: address.runID, id: address.effectID) }
        guard let last = page.last, page.count == 64 else { break }
        after = last.effectID
      }
      let runs = try await access { try .encode($0.unfinishedScriptRuns()) }.decode([NotebookScriptRun].self)
      for run in runs {
        // No JavaScript continuation or source replay is inferred after an
        // owner restart. Existing native effects remain inspectable by ID.
        try await finishRun(run.id, state: .interrupted,
          error: .object(["code": .string("owner_restarted"), "message": .string("Attach reads existing receipts; code is never replayed.")]))
        // Older unfinished runs can predate the global recovery index. Once
        // interrupted they cannot dispatch anything, so their bounded local
        // index can be reconciled here, before IPC opens, without replay.
        let ids = try await access { try .encode($0.terminalScriptEffectsForRecovery(run.id)) }.decode([UUID].self)
        for id in ids { _ = try await reconcileEffect(runID: run.id, id: id) }
      }
    }
    initialization = task
    try await task.value
  }

  private func drive() {
    guard !closing, active == nil, !waiting.isEmpty else { return }
    let run = waiting.removeFirst(); active = run.id; acceptedCalls = 0
    runningTask = Task { [weak self] in await self?.perform(run) }
  }

  private func perform(_ run: NotebookScriptRun) async {
    let deadline = ContinuousClock.now + .seconds(30)
    do {
      let admitted = try await persistence { try .encode($0.setScriptRunState(run.id, state: .running)) }.decode(NotebookScriptRun.self)
      guard admitted.state == .running, !cancelled.contains(run.id), !closing else { throw CancellationError() }
      var code = admitted.code
      var sourceMap: NotebookTypeScriptSourceMap?
      if admitted.language == .typescript {
        guard let version = admitted.compilerVersion, let sdk = admitted.sdkVersion else {
          throw CollaborationError("compiler_unavailable", "У допущенной программы нет закреплённого компилятора и SDK.")
        }
        // Preparation has its own connection, not the normalization queue or
        // a native write transaction. The same run cancellation owns both phases.
        let compiler = NotebookXPCWorker(serviceName: markupServiceName) { _ in .init(code: "host_unavailable") }
        worker = compiler
        let reply = await compiler.compileTypeScript(.init(id: run.id, source: admitted.code, compilerVersion: version, sdkVersion: sdk),
          deadline: min(deadline, .now + .seconds(10)))
        compiler.invalidate(); worker = nil
        // A late compiler reply never resurrects a cancelled/shutting-down run.
        guard active == run.id, !cancelled.contains(run.id), !closing else { throw CancellationError() }
        if let code = reply.code { throw CollaborationError(code, reply.message ?? code) }
        guard let bytes = reply.value else { throw CollaborationError("invalid_compiler_reply", "Компилятор не вернул JavaScript.") }
        let prepared = try JSONDecoder().decode(NotebookTypeScriptResult.self, from: bytes)
        guard prepared.compilerVersion == version, prepared.sdkVersion == sdk, prepared.javaScript.utf8.count <= 262_144 else {
          throw CollaborationError("invalid_compiler_reply", "Результат подготовки не соответствует допущенной программе.")
        }
        sourceMap = try NotebookTypeScriptSourceMap(data: prepared.sourceMap)
        code = prepared.javaScript
      }
      guard !cancelled.contains(run.id), !closing else { throw CancellationError() }
      let service = NotebookXPCWorker(serviceName: userServiceName) { [weak self] call in
        guard let self else { return .init(code: "owner_unavailable") }
        return await self.host(call)
      }
      worker = service
      let reply = await service.execute(.init(id: run.id, code: code, arguments: try JSONEncoder().encode(admitted.arguments)), deadline: deadline)
      finishedWorkers.insert(run.id)
      // Accepted commits outlive cancellation/disconnection of the worker.
      await drainAcceptedEffects()
      let wasCancelled = cancelled.contains(run.id)
      let result = try reply.value.map { try JSONDecoder().decode(JSONValue.self, from: $0) }
      let state: NotebookScriptRun.State = wasCancelled ? .cancelled : reply.code == nil ? .completed : .failed
      let error = wasCancelled ? try JSONValue.encode(NotebookStore.scriptCancellationError)
        : reply.code.map { JSONValue.object(["code": .string($0), "message": .string(sourceMap?.map(reply.message ?? $0) ?? reply.message ?? $0)]) }
      try await finishRun(run.id, state: state, result: result, error: error)
      service.invalidate()
    } catch {
      let value = Self.error(error)
      let state: NotebookScriptRun.State = cancelled.contains(run.id) ? .cancelled : .failed
      try? await finishRun(run.id, state: state, error: value)
    }
    worker?.invalidate(); worker = nil; active = nil; effectTasks.removeAll(); cancelled.remove(run.id); finishedWorkers.remove(run.id); runningTask = nil; drive()
  }

  func drainAcceptedEffects() async {
    guard inFlightEffects > 0 else { return }
    await withCheckedContinuation { effectDrainWaiters.append($0) }
  }

  func beginEffectCall() { inFlightEffects += 1 }
  func endEffectCall() {
    inFlightEffects -= 1
    if inFlightEffects == 0 {
      let waiters = effectDrainWaiters; effectDrainWaiters.removeAll()
      for waiter in waiters { waiter.resume() }
    }
  }

  func host(_ call: NotebookWorkerCall) async -> NotebookWorkerReply {
    do {
      guard active == call.runID, !cancelled.contains(call.runID), !finishedWorkers.contains(call.runID) else { throw CollaborationError("run_cancelled", "Новые операции после завершения не принимаются.") }
      acceptedCalls += 1
      guard acceptedCalls <= 1024 else { throw CollaborationError("sdk_call_limit", "Одна программа делает до 1024 вызовов SDK.") }
      let arguments = try JSONDecoder().decode(JSONValue.self, from: call.arguments)
      let value: JSONValue
      switch call.method {
      case "emit", "emitImage":
        if call.method == "emitImage" {
          let descriptor = arguments["artifact"] ?? .null
          try validateImage(descriptor)
          let image = try await send(["command": .string("scriptArtifact"), "artifact": descriptor])
          guard let base64 = image.string("data"), let png = Data(base64Encoded: base64), let hash = image.string("sha256") else {
            throw CollaborationError("invalid_artifact", "Владелец не вернул проверенные пиксели.")
          }
          value = try await persistence { try .encode($0.appendScriptImageEvent(call.runID, png: png, expectedSHA256: hash)) }
        } else {
          value = try await persistence { try .encode($0.appendScriptEvent(call.runID, kind: "value", value: arguments["value"] ?? .null)) }
        }
      case "id":
        guard let key = arguments.string("key"), !key.isEmpty, key.utf8.count <= 120 else { throw CollaborationError("invalid_key", "id получает непустой key до 120 байт.") }
        value = .string(NotebookStore.submissionID(call.runID, suffix: "id:" + key).uuidString.lowercased())
      case "transaction", "undo", "point", "present", "cancelPresentation", "export":
        // Own this accepted wire call before even the async effect method can
        // suspend; no coroutine/admission reply gap may escape terminal drain.
        beginEffectCall()
        defer { endEffectCall() }
        value = try await effect(runID: call.runID, method: call.method, arguments: arguments, trackedByHost: true)
      default:
        guard NotebookScriptAPI.readMethods.contains(call.method) else { throw CollaborationError("unknown_sdk_method", "Используйте методы из notebook_context(help).") }
        value = try await read(method: call.method, arguments: arguments)
      }
      return .init(value: try JSONEncoder().encode(value))
    } catch { return .init(value: try? JSONEncoder().encode(Self.error(error)), code: (error as? CollaborationError)?.code ?? "operation_failed", message: error.localizedDescription) }
  }

  static func error(_ error: Error) -> JSONValue {
    if let error = error as? CollaborationError { return (try? .encode(error)) ?? .null }
    return .object(["code": .string("operation_failed"), "message": .string(error.localizedDescription)])
  }
}

extension JSONValue {
  func string(_ key: String) -> String? { if case .string(let value) = self[key] { value } else { nil } }
  func array(_ key: String) -> [JSONValue] { if case .array(let value) = self[key] { value } else { [] } }
  func number(_ key: String) -> Double? { if case .number(let value) = self[key] { value } else { nil } }
  var fields: [String: JSONValue] { if case .object(let value) = self { value } else { [:] } }
}

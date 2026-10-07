import Foundation
import Darwin

public enum NotebookIPC {
  public static let version = 1
  public static let maximumFrameBytes = 32 * 1_024 * 1_024
  /// Ordinary handlers and suspended panel observations retain separate
  /// admission windows. A frame has no domain quota before typed decoding.
  public static let maximumConnections = 8
  public static let maximumWaitingConnections = 16
  public static let maximumUnclassifiedConnections = 8
  public static let requestTimeout: TimeInterval = 30
  public static var defaultSocketURL: URL {
    URL(fileURLWithPath: "/tmp/notebook-\(geteuid())/bridge.sock")
  }

  public static func decodeCommand(_ data: Data) throws -> NotebookCommand {
    let allowed = Set(NotebookCommand.CodingKeys.allCases.map(\.rawValue))
    guard data.count <= maximumFrameBytes,
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(object.keys).isSubset(of: allowed) else {
      throw CollaborationError("invalid_command", "Команда содержит только типизированные поля Notebook; выбор хранилища не допускается.")
    }
    do { return try JSONDecoder().decode(NotebookCommand.self, from: data) }
    catch { throw CollaborationError("invalid_command", "Команда не соответствует протоколу Notebook.") }
  }
}

private struct IPCRequest: Codable, Sendable {
  let version: Int
  let id: UUID
  let request: JSONValue
}
private struct IPCResponse: Codable, Sendable {
  let version: Int
  let id: UUID
  let result: JSONValue?
  let error: CollaborationError?
  init(version: Int, id: UUID, result: JSONValue?, error: CollaborationError?) {
    self.version = version; self.id = id; self.result = result; self.error = error
  }
  enum CodingKeys: String, CodingKey { case version, id, result, error }
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    version = try values.decode(Int.self, forKey: .version); id = try values.decode(UUID.self, forKey: .id)
    result = values.contains(.result) ? try values.decode(JSONValue.self, forKey: .result) : nil
    error = try values.decodeIfPresent(CollaborationError.self, forKey: .error)
  }
}

/// A local client cannot open a NotebookStore. The installed Mac helper owns every command.
public struct NotebookIPCClient: Sendable {
  public let socketURL: URL
  public init(socketURL: URL = NotebookIPC.defaultSocketURL) { self.socketURL = socketURL }

  public func send(_ command: NotebookCommand, requestID: UUID = UUID()) throws -> JSONValue {
    try SocketIO.validateDirectory(socketURL.deletingLastPathComponent(), create: false)
    try SocketIO.validateSocket(socketURL)
    let fd = try SocketIO.makeSocket()
    defer { close(fd) }
    try SocketIO.connect(fd, url: socketURL)
    try SocketIO.authenticate(fd)
    let packet = IPCRequest(version: NotebookIPC.version, id: requestID, request: try .encode(command))
    try SocketIO.writeFrame(try JSONEncoder().encode(packet), fd: fd)
    let response = try JSONDecoder().decode(IPCResponse.self, from: SocketIO.readFrame(fd: fd))
    guard response.version == NotebookIPC.version, response.id == requestID else {
      throw CollaborationError("ipc_protocol", "Ответ принадлежит другой версии протокола или запросу.")
    }
    if let error = response.error { throw error }
    guard let result = response.result else { throw CollaborationError("ipc_protocol", "Ответ не содержит результата.") }
    return result
  }
}

/// Transport admission is bounded independently from the writer queue. A timed-out accepted
/// operation retains its slot until the owner finishes, so slow storage cannot grow detached work.
public final class NotebookIPCServer: @unchecked Sendable {
  public typealias Handler = @Sendable (NotebookCommand) async throws -> JSONValue
  public let socketURL: URL
  private let handler: Handler
  private let lock = NSLock()
  private struct DrainWaiter {
    let started: ContinuousClock.Instant
    let continuation: CheckedContinuation<Duration, Never>
  }
  private var accepting = false
  private var drainedAt: ContinuousClock.Instant?
  private var drainWaiters: [DrainWaiter] = []
  private var listener: Int32 = -1
  private var socketIdentity: SocketIO.Identity?
  private var stopped = false
  private enum Admission: Equatable { case unclassified, command, panelChanges }
  private struct AdmittedJob {
    let job: IPCJob
    var admission: Admission
  }
  private var jobs: [UUID: AdmittedJob] = [:]
  private let acceptQueue = DispatchQueue(label: "Notebook.IPC.accept", qos: .userInitiated)
  private let workerQueue: DispatchQueue
  private let requestExecutor: IPCRequestExecutor
  private let requestTimeout: Duration

  public convenience init(socketURL: URL = NotebookIPC.defaultSocketURL, handler: @escaping Handler) {
    self.init(socketURL: socketURL,
      workerQueue: DispatchQueue(label: "Notebook.IPC.requests", qos: .userInitiated, attributes: .concurrent), handler: handler)
  }

  init(socketURL: URL, workerQueue: DispatchQueue,
    requestQueue: DispatchQueue = .init(label: "Notebook.IPC.handler", qos: .userInitiated),
    requestTimeout: Duration = .seconds(NotebookIPC.requestTimeout),
    handler: @escaping Handler) {
    self.socketURL = socketURL; self.handler = handler; self.workerQueue = workerQueue
    self.requestTimeout = requestTimeout
    requestExecutor = IPCRequestExecutor(queue: requestQueue)
  }

  var activeConnectionCount: Int { lock.withLock { jobs.count } }
  var acceptedHandlerCount: Int { lock.withLock { jobs.values.filter { $0.job.hasPendingHandler }.count } }
  var cancelledHandlerCount: Int { lock.withLock { jobs.values.filter { $0.job.ownedHandler?.isCancelled == true }.count } }
  var waitingConnectionCount: Int { lock.withLock { connectionCountLocked(.panelChanges) } }
  var commandConnectionCount: Int { lock.withLock { connectionCountLocked(.command) } }
  var unclassifiedConnectionCount: Int { lock.withLock { connectionCountLocked(.unclassified) } }
  private func connectionCountLocked(_ admission: Admission) -> Int {
    jobs.values.filter { $0.admission == admission }.count
  }

  public func start() throws {
    try start(afterAddressCheck: nil)
  }

  func start(afterAddressCheck: (() throws -> Void)?, beforeAddressPublication: ((URL) throws -> Void)? = nil) throws {
    try lock.withLock {
      guard listener < 0, !stopped else { throw CollaborationError("ipc_lifecycle", "Этот сервер уже запущен или завершён.") }
      try SocketIO.validateDirectory(socketURL.deletingLastPathComponent(), create: true)
      try SocketIO.removeStaleSocket(socketURL)
      try afterAddressCheck?()
      let fd = try SocketIO.makeSocket()
      var boundIdentity: SocketIO.Identity?
      var privateURL: URL?
      do {
        let binding = try SocketIO.bindPrivate(fd, beside: socketURL)
        privateURL = binding
        boundIdentity = try SocketIO.Identity(binding)
        let backlog = NotebookIPC.maximumConnections + NotebookIPC.maximumWaitingConnections + NotebookIPC.maximumUnclassifiedConnections
        guard chmod(binding.path, 0o600) == 0, listen(fd, Int32(backlog)) == 0 else {
          throw SocketIO.failure("Не удалось защитить локальный сокет.")
        }
        try beforeAddressPublication?(binding)
        guard boundIdentity?.matchesSocket(at: binding) == true else {
          throw SocketIO.failure("Владелец подготовленного IPC адреса изменился.")
        }
        try SocketIO.validateSocket(binding)
        // A strict client sees either absence or this protected, listening inode.
        // Exclusive publication cannot replace an owner which won the address check.
        guard renamex_np(binding.path, socketURL.path, UInt32(RENAME_EXCL)) == 0 else {
          if errno == EEXIST { throw SocketIO.ownerRunning() }
          throw SocketIO.failure("Не удалось опубликовать локальный IPC адрес.")
        }
        listener = fd; socketIdentity = boundIdentity
      } catch {
        close(fd)
        if let privateURL { boundIdentity?.removeSocket(at: privateURL) }
        throw error
      }
      accepting = true
      acceptQueue.async { [self] in
        defer { finishAccepting() }
        acceptConnections(fd)
      }
    }
  }

  public func stop() {
    let closing = lock.withLock {
      stopped = true
      let fd = listener; listener = -1
      if fd >= 0 {
        shutdown(fd, SHUT_RDWR); close(fd)
        socketIdentity?.removeSocket(at: socketURL); socketIdentity = nil
      }
      return jobs.values.map(\.job)
    }
    // Cancellation handlers may call their domain owner. Do not invoke them
    // under the transport registry lock.
    for job in closing { job.shutdown() }
    let completion = lock.withLock {
      jobs = jobs.filter { !$0.value.job.finished }
      return drainCompletionLocked()
    }
    resumeDrain(completion)
  }

  /// Closing a socket does not cancel an already accepted store command. The
  /// application awaits this boundary before flushing and releasing its writer.
  /// The final transport/handler release records completion under the owner's
  /// lock. No notification queue or caller executor can move that timestamp.
  @discardableResult public func stopAndDrain() async -> Duration {
    let started = ContinuousClock.now
    stop()
    let handlers = lock.withLock { jobs.values.compactMap { $0.job.ownedHandler } }
    for handler in handlers { await handler.value }
    return await withCheckedContinuation { continuation in
      let completed: ContinuousClock.Instant? = lock.withLock {
        if let drainedAt { return drainedAt }
        drainWaiters.append(.init(started: started, continuation: continuation))
        return nil
      }
      if let completed { continuation.resume(returning: max(.zero, started.duration(to: completed))) }
    }
  }

  deinit { stop() }

  private func acceptConnections(_ listeningFD: Int32) {
    while lock.withLock({ !stopped && listener == listeningFD }) {
      let fd = accept(listeningFD, nil, nil)
      if fd < 0 { if errno == EINTR { continue }; return }
      do { try SocketIO.configure(fd); try SocketIO.authenticate(fd) }
      catch { close(fd); continue }
      let id = UUID(), job = IPCJob(fd: fd)
      let accepted = lock.withLock {
        guard !stopped, connectionCountLocked(.unclassified) < NotebookIPC.maximumUnclassifiedConnections else { return false }
        jobs[id] = .init(job: job, admission: .unclassified); return true
      }
      guard accepted else { close(fd); continue }
      workerQueue.async { [weak self] in self?.serve(id: id, job: job) }
    }
  }

  private func serve(id: UUID, job: IPCJob) {
    // Stop owns an admitted socket even before its worker gets a queue slot.
    // A cancelled pending closure must never touch a reused descriptor.
    guard job.beginWorker() else { return }
    defer {
      job.finishWorker()
      releaseFinishedJob(id, job: job)
    }
    var requestID = UUID()
    do {
      let bytes = try SocketIO.readFrame(fd: job.fd)
      let envelope = try JSONDecoder().decode(IPCRequest.self, from: bytes)
      requestID = envelope.id
      guard envelope.version == NotebookIPC.version else {
        throw CollaborationError("ipc_protocol", "Обновите согласованную пару Notebook и MCP.")
      }
      let command = try NotebookIPC.decodeCommand(JSONEncoder().encode(envelope.request))
      // Only this validated observation may suspend in the waiting quota. An
      // ordinary command cannot borrow it by attaching a panelChanges field.
      let readCommand: NotebookReadCommand?
      if command.command == .panelChanges { readCommand = try NotebookReadCommand(command) }
      else { readCommand = try? NotebookReadCommand(command) }
      let pureRead = readCommand != nil
      let admission: Admission = command.command == .panelChanges ? .panelChanges : .command
      let admitted = try lock.withLock {
        guard !stopped, jobs[id]?.job === job else { return false }
        let limit = admission == .panelChanges ? NotebookIPC.maximumWaitingConnections : NotebookIPC.maximumConnections
        guard connectionCountLocked(admission) < limit else {
          throw CollaborationError("ipc_busy", "Окно одновременных IPC запросов заполнено. Повторите запрос после завершения текущих.")
        }
        try job.beginHandler(pureRead: pureRead, executor: requestExecutor,
          operation: { [handler] in try await handler(command) }, finished: { [self] in
            releaseFinishedJob(id, job: job)
          })
        jobs[id]?.admission = admission
        return true
      }
      guard admitted else { throw CollaborationError("owner_unavailable", "Notebook завершает работу.") }
      // The accepted request does not wait for a spare cooperative-pool
      // thread occupied by synchronous Core work. Actor isolation still owns
      // the actual writer; this executor supplies only its runnable threads.
      guard try job.waitForHandler(until: .now + requestTimeout), let result = job.result else {
        throw CollaborationError("ipc_timeout", "Владелец ещё завершает принятый запрос. Проверьте тот же ID хода; тайм-аут не означает отмену записи.")
      }
      try write(result.get(), error: nil, id: requestID, fd: job.fd)
    } catch {
      let detail = (error as? CollaborationError) ?? CollaborationError("ipc_protocol", "Некорректный или незавершённый IPC запрос.")
      try? write(nil, error: detail, id: requestID, fd: job.fd)
    }
  }

  private func write(_ value: JSONValue?, error: CollaborationError?, id: UUID, fd: Int32) throws {
    let response = IPCResponse(version: NotebookIPC.version, id: id, result: value, error: error)
    try SocketIO.writeFrame(JSONEncoder().encode(response), fd: fd)
  }
  private func releaseFinishedJob(_ id: UUID, job: IPCJob) {
    let completion: DrainCompletion? = lock.withLock {
      guard jobs[id]?.job === job, job.finished else { return nil }
      jobs.removeValue(forKey: id)
      return drainCompletionLocked()
    }
    resumeDrain(completion)
  }

  private func finishAccepting() {
    let completion = lock.withLock {
      accepting = false
      return drainCompletionLocked()
    }
    resumeDrain(completion)
  }

  private typealias DrainCompletion = (ContinuousClock.Instant, [DrainWaiter])

  private func drainCompletionLocked() -> DrainCompletion? {
    guard stopped, !accepting, jobs.isEmpty, drainedAt == nil else { return nil }
    let completed = ContinuousClock.now
    drainedAt = completed
    let waiters = drainWaiters; drainWaiters.removeAll()
    return (completed, waiters)
  }

  private func resumeDrain(_ completion: DrainCompletion?) {
    guard let (completed, waiters) = completion else { return }
    for waiter in waiters {
      waiter.continuation.resume(returning: max(.zero, waiter.started.duration(to: completed)))
    }
  }
}

/// Part of the server lifetime, distinct from blocking socket workers. A task
/// retains its executor through suspension; shutdown drains that same handler.
private final class IPCRequestExecutor: TaskExecutor {
  let queue: DispatchQueue
  init(queue: DispatchQueue) { self.queue = queue }
  func enqueue(_ job: consuming ExecutorJob) {
    let job = UnownedJob(job)
    queue.async { [self] in job.runSynchronously(on: asUnownedTaskExecutor()) }
  }
}

private final class IPCJob: @unchecked Sendable {
  private enum WorkerPhase { case pending, running, finished }
  let fd: Int32
  private let lock = NSLock()
  private var workerPhase = WorkerPhase.pending
  private var handlerFinished = true
  private var response: Result<JSONValue, CollaborationError>?
  private var handlerTask: Task<Void, Never>?
  private var handlerJoinTask: Task<Void, Never>?
  private var pureRead = false
  private var withdrawn = false
  private var events: Int32 = -1
  init(fd: Int32) { self.fd = fd }
  var finished: Bool { lock.withLock { workerPhase == .finished && handlerFinished } }
  var hasPendingHandler: Bool { lock.withLock { !handlerFinished } }
  var result: Result<JSONValue, CollaborationError>? { lock.withLock { response } }
  var ownedHandler: Task<Void, Never>? { lock.withLock { handlerTask } }
  func beginWorker() -> Bool {
    lock.withLock {
      guard workerPhase == .pending else { return false }
      workerPhase = .running
      return true
    }
  }
  func beginHandler(pureRead: Bool, executor: IPCRequestExecutor,
    operation: @escaping @Sendable () async throws -> JSONValue,
    finished: @escaping @Sendable () -> Void) throws {
    try lock.withLock {
      let queue = kqueue()
      guard queue >= 0 else { throw SocketIO.failure("Не удалось наблюдать срок IPC запроса.") }
      var changes = [
        kevent64_s(ident: UInt64(fd), filter: Int16(EVFILT_WRITE), flags: UInt16(EV_ADD | EV_CLEAR), fflags: 0, data: 0, udata: 0, ext: (0, 0)),
        kevent64_s(ident: 1, filter: Int16(EVFILT_USER), flags: UInt16(EV_ADD | EV_CLEAR), fflags: 0, data: 0, udata: 0, ext: (0, 0)),
      ]
      guard Darwin.kevent64(queue, &changes, Int32(changes.count), nil, 0, 0, nil) == 0 else {
        close(queue); throw SocketIO.failure("Не удалось зарегистрировать IPC запрос.")
      }
      events = queue; self.pureRead = pureRead; handlerFinished = false
      let producer = Task(executorPreference: executor, priority: .userInitiated) { [self] in
        // Acquiring the same lock puts registration before the first handler
        // await, including an already disconnected or stopped request.
        let cancelled = lock.withLock { withdrawn && self.pureRead }
        let response: Result<JSONValue, CollaborationError>
        do {
          if cancelled { throw CancellationError() }
          if pureRead { try Task.checkCancellation() }
          response = .success(try await operation())
        } catch {
          response = .failure((error as? CollaborationError) ?? .init("operation_failed", error.localizedDescription))
        }
        recordResponse(response)
      }
      handlerTask = producer
      // This continuation belongs to the same admitted job and executor. A
      // producer callback is not its task/lease completion: join first, then
      // release the response, descriptor and charged transport slot.
      handlerJoinTask = Task(executorPreference: executor, priority: .userInitiated) { [self] in
        await producer.value
        finishHandler(); finished()
      }
    }
  }
  /// A write-half-close is a valid request. Only a disconnected response
  /// reader, owner Stop, or this job's deadline withdraws a pure observation.
  func waitForHandler(until deadline: ContinuousClock.Instant) throws -> Bool {
    while true {
      if lock.withLock({ handlerFinished }) { return true }
      if lock.withLock({ withdrawn }) { return false }
      let remaining = ContinuousClock.now.duration(to: deadline)
      if remaining <= .zero { withdraw(); return false }
      let parts = remaining.components
      var timeout = timespec(tv_sec: Int(parts.seconds), tv_nsec: Int(parts.attoseconds / 1_000_000_000))
      var event = kevent64_s()
      let queue = lock.withLock { events }
      let count = Darwin.kevent64(queue, nil, 0, &event, 1, 0, &timeout)
      if count < 0 && errno == EINTR { continue }
      guard count >= 0 else { withdraw(); throw SocketIO.failure("Наблюдение IPC запроса прервано.") }
      if count == 0 { withdraw(); return false }
      if event.filter == Int16(EVFILT_WRITE), event.flags & UInt16(EV_EOF | EV_ERROR) != 0 {
        withdraw(); return false
      }
    }
  }
  private func withdraw() {
    let task = lock.withLock { () -> Task<Void, Never>? in
      withdrawn = true
      return pureRead ? handlerTask : nil
    }
    task?.cancel()
  }
  private func wakeLocked() {
    guard events >= 0 else { return }
    var event = kevent64_s(ident: 1, filter: Int16(EVFILT_USER), flags: 0, fflags: UInt32(NOTE_TRIGGER), data: 0, udata: 0, ext: (0, 0))
    _ = Darwin.kevent64(events, &event, 1, nil, 0, 0, nil)
  }
  private func closeEventsIfFinishedLocked() {
    guard workerPhase == .finished, handlerFinished else { return }
    if events >= 0 { close(events); events = -1 }
    response = nil; handlerTask = nil; handlerJoinTask = nil
  }
  private func recordResponse(_ value: Result<JSONValue, CollaborationError>) {
    lock.withLock { if workerPhase != .finished { response = value } }
  }
  private func finishHandler() {
    lock.withLock { handlerFinished = true; wakeLocked(); closeEventsIfFinishedLocked() }
  }
  func finishWorker() {
    lock.withLock {
      guard workerPhase != .finished else { return }
      close(fd); workerPhase = .finished
      closeEventsIfFinishedLocked()
    }
  }
  func shutdown() {
    withdraw()
    lock.withLock {
      switch workerPhase {
      case .pending: close(fd); workerPhase = .finished
      case .running: Darwin.shutdown(fd, SHUT_RDWR)
      case .finished: break
      }
      wakeLocked()
    }
  }
}

enum SocketIO {
  struct Identity {
    let device: dev_t
    let inode: ino_t
    init(_ url: URL) throws {
      var info = stat()
      guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == geteuid() else {
        throw failure("Не удалось проверить созданный IPC сокет.")
      }
      device = info.st_dev; inode = info.st_ino
    }
    func matchesSocket(at url: URL) -> Bool {
      var info = stat()
      return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFSOCK
        && info.st_uid == geteuid() && info.st_dev == device && info.st_ino == inode
    }
    func removeSocket(at url: URL) {
      guard matchesSocket(at: url) else { return }
      _ = unlink(url.path)
    }
  }
  static func failure(_ message: String) -> CollaborationError { .init("ipc_unavailable", message) }
  static func ownerRunning() -> CollaborationError {
    .init("ipc_owner_running", "Notebook уже запущен; подключитесь к действующему владельцу.")
  }
  static func makeSocket() throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw failure("Не удалось открыть локальный IPC.") }
    do { try configure(fd); return fd } catch { close(fd); throw error }
  }
  static func configure(_ fd: Int32) throws {
    var timeout = timeval(tv_sec: Int(NotebookIPC.requestTimeout + 5), tv_usec: 0)
    var one: Int32 = 1
    guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
      setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
      setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
      setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
      throw failure("Не удалось ограничить время локального IPC.")
    }
  }
  static func authenticate(_ fd: Int32) throws {
    var uid: uid_t = 0, gid: gid_t = 0
    guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else {
      throw CollaborationError("ipc_unauthorized", "Локальный IPC принимает только текущего пользователя.")
    }
  }
  static func validateDirectory(_ url: URL, create: Bool) throws {
    guard url.isFileURL, url.path.hasPrefix("/") else { throw failure("Сокет требует абсолютный локальный адрес.") }
    if create && mkdir(url.path, 0o700) < 0 && errno != EEXIST { throw failure("Не удалось создать закрытый каталог IPC.") }
    var info = stat()
    guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
      info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else {
      throw CollaborationError("ipc_unauthorized", "Каталог IPC должен принадлежать пользователю с правами 0700, без символической ссылки.")
    }
  }
  static func validateSocket(_ url: URL) throws {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { throw failure("Notebook helper не запущен. Откройте Notebook на Mac.") }
    guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == geteuid(), info.st_mode & 0o777 == 0o600 else {
      throw CollaborationError("ipc_unauthorized", "IPC сокет должен принадлежать пользователю с правами 0600.")
    }
  }
  static func removeStaleSocket(_ url: URL) throws {
    var info = stat()
    guard lstat(url.path, &info) == 0 else {
      guard errno == ENOENT else { throw failure("Не удалось проверить адрес IPC.") }; return
    }
    try validateSocket(url)
    let probe = try makeSocket(); defer { close(probe) }
    guard fcntl(probe, F_SETFL, O_NONBLOCK) == 0 else { throw failure("Не удалось проверить владельца IPC.") }
    var address = try address(url)
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard result < 0 && errno == ECONNREFUSED else { throw ownerRunning() }
    var current = stat()
    guard lstat(url.path, &current) == 0, current.st_dev == info.st_dev, current.st_ino == info.st_ino,
      unlink(url.path) == 0 else { throw failure("Владелец адреса IPC изменился.") }
  }
  static func address(_ url: URL) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let bytes = Array(url.path.utf8CString)
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw failure("Адрес IPC слишком длинный.") }
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
      bytes.withUnsafeBytes { source in destination.copyBytes(from: source) }
    }
    return address
  }
  static func connect(_ fd: Int32, url: URL) throws {
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw failure("Не удалось ограничить соединение IPC.") }
    defer { _ = fcntl(fd, F_SETFL, flags) }
    var address = try address(url)
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    if result == 0 { return }
    guard errno == EINPROGRESS else { throw failure("Notebook helper не отвечает на локальном IPC.") }
    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    guard poll(&descriptor, 1, Int32(NotebookIPC.requestTimeout * 1_000)) > 0 else { throw failure("Соединение с Notebook helper не завершено вовремя.") }
    var error: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
    guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { throw failure("Notebook helper не отвечает на локальном IPC.") }
  }
  static func bind(_ fd: Int32, url: URL) throws {
    var address = try address(url)
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard result == 0 else {
      if errno == EADDRINUSE { throw ownerRunning() }
      throw failure("Не удалось занять локальный IPC адрес.")
    }
  }
  static func bindPrivate(_ fd: Int32, beside url: URL) throws -> URL {
    _ = try address(url)
    let directory = url.deletingLastPathComponent()
    let available = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1 - directory.path.utf8.count - 1
    guard available > 0 else { throw failure("Адрес IPC слишком длинный.") }
    // A near-limit canonical path may leave only one or two filename bytes.
    // Keep the private binding in the same directory without extending sun_path.
    let names: [String]
    if available <= 2 {
      names = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").shuffled()
        .map { (available == 2 ? "." : "") + String($0) }
    } else {
      names = (0..<32).map { _ in "." + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(min(32, available - 1))) }
    }
    for name in names {
      let binding = directory.appendingPathComponent(name)
      if binding.path == url.path { continue }
      do { try bind(fd, url: binding); return binding }
      catch let error as CollaborationError where error.code == "ipc_owner_running" { continue }
    }
    throw failure("Не удалось подготовить закрытый IPC адрес.")
  }
  static func readFrame(fd: Int32) throws -> Data {
    let prefix = try readExactly(4, fd: fd)
    let length = prefix.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    guard length > 0, length <= NotebookIPC.maximumFrameBytes else {
      throw CollaborationError("resource_limit", "IPC сообщение должно занимать от 1 байта до 32 МиБ.")
    }
    return try readExactly(Int(length), fd: fd)
  }
  static func readExactly(_ count: Int, fd: Int32) throws -> Data {
    var data = Data(count: count)
    let deadline = Date().addingTimeInterval(NotebookIPC.requestTimeout)
    let success = data.withUnsafeMutableBytes { buffer -> Bool in
      var offset = 0
      while offset < count, Date() < deadline {
        let n = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), count - offset)
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { return false }; offset += n
      }
      return offset == count
    }
    guard success else { throw failure("IPC сообщение не завершено в отведённое время.") }
    return data
  }
  static func writeFrame(_ data: Data, fd: Int32) throws {
    guard !data.isEmpty, data.count <= NotebookIPC.maximumFrameBytes else {
      throw CollaborationError("resource_limit", "Ответ превышает 32 МиБ. Запросите меньшую область.")
    }
    var length = UInt32(data.count).bigEndian
    var frame = withUnsafeBytes(of: &length) { Data($0) }; frame.append(data)
    let deadline = Date().addingTimeInterval(NotebookIPC.requestTimeout)
    let success = frame.withUnsafeBytes { buffer -> Bool in
      var offset = 0
      while offset < buffer.count, Date() < deadline {
        let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { return false }; offset += n
      }
      return offset == buffer.count
    }
    guard success else { throw failure("Клиент не принял ответ IPC в отведённое время.") }
  }
}

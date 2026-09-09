import Foundation
import Darwin

public enum NotebookIPC {
  public static let version = 1
  public static let maximumFrameBytes = 32 * 1_024 * 1_024
  public static let maximumConnections = 8
  public static let requestTimeout: TimeInterval = 30
  public static var defaultSocketURL: URL {
    URL(fileURLWithPath: "/tmp/notebook-\(geteuid())/bridge.sock")
  }

  public static func decodeCommand(_ data: Data) throws -> NotebookCommand {
    let allowed: Set<String> = ["command", "query", "limit", "action", "actionID", "target", "elementID",
      "reference", "expectedRevision", "region", "worldOrigin", "pageIndex", "placement", "contextID",
      "replyTo", "references", "queries", "expectedCursor", "artifact", "export"]
    guard data.count <= maximumFrameBytes,
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(object.keys).isSubset(of: allowed) else {
      throw CollaborationError("invalid_command", "Команда содержит только типизированные поля Notebook; пути и корень не принимаются.")
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
  private let lifetime = DispatchGroup()
  private var listener: Int32 = -1
  private var stopped = false
  private var jobs: [UUID: IPCJob] = [:]
  private let acceptQueue = DispatchQueue(label: "Notebook.IPC.accept", qos: .utility)
  private let workerQueue = DispatchQueue(label: "Notebook.IPC.requests", qos: .utility, attributes: .concurrent)

  public init(socketURL: URL = NotebookIPC.defaultSocketURL, handler: @escaping Handler) {
    self.socketURL = socketURL; self.handler = handler
  }

  var activeConnectionCount: Int { lock.withLock { jobs.count } }

  public func start() throws {
    try lock.withLock {
      guard listener < 0, !stopped else { throw CollaborationError("ipc_lifecycle", "Этот сервер уже запущен или завершён.") }
      try SocketIO.validateDirectory(socketURL.deletingLastPathComponent(), create: true)
      try SocketIO.removeStaleSocket(socketURL)
      let fd = try SocketIO.makeSocket()
      do {
        try SocketIO.bind(fd, url: socketURL)
        guard chmod(socketURL.path, 0o600) == 0, listen(fd, Int32(NotebookIPC.maximumConnections)) == 0 else {
          throw SocketIO.failure("Не удалось защитить локальный сокет.")
        }
        listener = fd
      } catch { close(fd); try? FileManager.default.removeItem(at: socketURL); throw error }
      lifetime.enter()
      acceptQueue.async { [self] in
        defer { lifetime.leave() }
        acceptConnections(fd)
      }
    }
  }

  public func stop() {
    let fd: Int32 = lock.withLock {
      stopped = true
      let previous = listener; listener = -1
      for job in jobs.values { job.shutdown() }
      return previous
    }
    if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd); try? FileManager.default.removeItem(at: socketURL) }
  }

  /// Closing a socket does not cancel an already accepted store command. The
  /// application awaits this boundary before flushing and releasing its writer.
  public func stopAndDrain() async {
    stop()
    await withCheckedContinuation { continuation in
      lifetime.notify(queue: .global(qos: .utility)) { continuation.resume() }
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
        guard !stopped, jobs.count < NotebookIPC.maximumConnections else { return false }
        lifetime.enter()
        jobs[id] = job; return true
      }
      guard accepted else { close(fd); continue }
      workerQueue.async { [self] in serve(id: id, job: job) }
    }
  }

  private func serve(id: UUID, job: IPCJob) {
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
      let admitted = lock.withLock {
        guard !stopped, jobs[id] === job else { return false }
        job.beginHandler()
        return true
      }
      guard admitted else { throw CollaborationError("owner_unavailable", "Notebook завершает работу.") }
      Task { [self] in
        let response: Result<JSONValue, CollaborationError>
        do { response = .success(try await handler(command)) }
        catch { response = .failure((error as? CollaborationError) ?? .init("operation_failed", error.localizedDescription)) }
        job.finishHandler(response)
        releaseFinishedJob(id, job: job)
      }
      guard job.completion.wait(timeout: .now() + NotebookIPC.requestTimeout) == .success,
        let result = job.result else {
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
    lock.withLock {
      guard jobs[id] === job, job.finished else { return }
      jobs.removeValue(forKey: id)
      lifetime.leave()
    }
  }
}

private final class IPCJob: @unchecked Sendable {
  let fd: Int32
  let completion = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var workerFinished = false
  private var handlerFinished = true
  private var response: Result<JSONValue, CollaborationError>?
  init(fd: Int32) { self.fd = fd }
  var finished: Bool { lock.withLock { workerFinished && handlerFinished } }
  var result: Result<JSONValue, CollaborationError>? { lock.withLock { response } }
  func beginHandler() { lock.withLock { handlerFinished = false } }
  func finishHandler(_ value: Result<JSONValue, CollaborationError>) {
    lock.withLock { response = value; handlerFinished = true }; completion.signal()
  }
  func finishWorker() { lock.withLock { close(fd); workerFinished = true } }
  func shutdown() { lock.withLock { if !workerFinished { Darwin.shutdown(fd, SHUT_RDWR) } } }
}

enum SocketIO {
  static func failure(_ message: String) -> CollaborationError { .init("ipc_unavailable", message) }
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
    guard result < 0 && errno == ECONNREFUSED else { throw failure("Этим IPC адресом уже владеет запущенный Notebook helper.") }
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
    guard result == 0 else { throw failure("Не удалось занять локальный IPC адрес.") }
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

import Foundation
import Network
import NotebookCore

/// HTTPS only; redirects cannot carry a routing capability to another origin.
private final class NotebookRelayHTTPDelegate: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

enum NotebookRelayHTTP {
  struct Ticket: Decodable, Sendable { let ticket: String; let expiresAt: Double }
  struct Enrollment: Decodable, Sendable { let clientCapability: String? }

  static func request<T: Decodable & Sendable>(_ route: NotebookRelayRoute, role: String, action: String, as: T.Type) async throws -> T {
    guard route.isValid, ["host", "client"].contains(role), ["ticket", "enable", "revoke"].contains(action) else { throw NotebookTransportError.authenticationRequired }
    var request = URLRequest(url: route.endpoint.appendingPathComponent("v1/routes/\(route.route.uuidString.lowercased())/\(action)"))
    request.httpMethod = "POST"; request.timeoutInterval = 12
    request.setValue("Basic " + Data((role + ":" + route.capability).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
    let session = URLSession(configuration: configuration, delegate: NotebookRelayHTTPDelegate(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (bytes, response) = try await session.bytes(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw NotebookTransportError.authenticationRequired }
    var data = Data()
    for try await byte in bytes {
      guard data.count < 4096 else { throw NotebookTransportError.frameTooLarge }
      data.append(byte)
    }
    return try JSONDecoder().decode(T.self, from: data)
  }

  static func ticket(_ route: NotebookRelayRoute, role: String) async throws -> String {
    let result = try await request(route, role: role, action: "ticket", as: Ticket.self)
    guard result.ticket.utf8.count == 43, result.expiresAt > Date().timeIntervalSince1970,
      result.expiresAt <= Date().timeIntervalSince1970 + 180 else { throw NotebookTransportError.authenticationRequired }
    return result.ticket
  }

  static func parameters(keys: [NotebookTransportTLS.Key], route: NotebookRelayRoute, ticket: String) throws -> NWParameters {
    guard route.isValid, let host = route.endpoint.host else { throw NotebookTransportError.authenticationRequired }
    let parameters = try NotebookTransportTLS.parameters(keys: keys)
    parameters.includePeerToPeer = false
    var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: .init(host), port: 443), tlsOptions: NWProtocolTLS.Options())
    proxy.allowFailover = false
    proxy.applyCredential(username: "client", password: ticket)
    let context = NWParameters.PrivacyContext(description: "Notebook authenticated relay")
    context.disableLogging(); context.proxyConfigurations = [proxy]; parameters.setPrivacyContext(context)
    return parameters
  }
}

/// Only the carrier changes: the loopback listener still receives the exact
/// existing PSK/TLS stream, hello, credits and journal. No inner plaintext here.
@MainActor
final class NotebookRelayUplink {
  private let route: NotebookRelayRoute
  private let port: NWEndpoint.Port
  private let queue = DispatchQueue(label: "Notebook.Relay.carrier")
  private var worker: Task<Void, Never>?
  private var tunnels: [UUID: (NWConnection, NWConnection, Task<Void, Never>)] = [:]
  private var waiting: NWConnection?

  init(route: NotebookRelayRoute, port: NWEndpoint.Port) { self.route = route; self.port = port }

  func start() {
    guard worker == nil else { return }
    worker = Task { [weak self] in
      var failures = 0
      while !Task.isCancelled {
        guard let self else { return }
        var connectingLocal: NWConnection?
        do {
          guard tunnels.count < 2 else { try await Task.sleep(for: .seconds(1)); continue }
          let ticket = try await NotebookRelayHTTP.ticket(route, role: "host")
          try Task.checkCancellation()
          let remote = NWConnection(host: .init(route.endpoint.host!), port: 443, using: .tls)
          waiting = remote
          try await NotebookRelayIO.start(remote, queue: queue)
          let auth = Data(("host:" + ticket).utf8).base64EncodedString()
          let header = "CONNECT \(route.tunnelHost):443 HTTP/1.1\r\nHost: \(route.tunnelHost):443\r\nProxy-Authorization: Basic \(auth)\r\n\r\n"
          try await NotebookRelayIO.send(Data(header.utf8), on: remote)
          let tail = try await NotebookRelayIO.connected(remote)
          try Task.checkCancellation()
          let local = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
          connectingLocal = local
          try await NotebookRelayIO.start(local, queue: queue)
          if !tail.isEmpty { try await NotebookRelayIO.send(tail, on: local) }
          let id = UUID()
          let pump = Task { [weak self] in
            await NotebookRelayIO.pipe(remote, local)
            self?.tunnels.removeValue(forKey: id)
          }
          tunnels[id] = (remote, local, pump); connectingLocal = nil; waiting = nil; failures = 0
        } catch {
          connectingLocal?.cancel(); waiting?.cancel(); waiting = nil
          if Task.isCancelled { return }
          failures = min(5, failures + 1)
          do { try await Task.sleep(for: .seconds(Double(1 << failures))) } catch { return }
        }
      }
    }
  }

  func stop() {
    worker?.cancel(); worker = nil; waiting?.cancel(); waiting = nil
    for (remote, local, task) in tunnels.values { task.cancel(); remote.cancel(); local.cancel() }
    tunnels.removeAll()
  }
}

/// Bounded asynchronous pumps. At most one 32 KiB write per direction is queued.
enum NotebookRelayIO {
  private final class Completion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    func finish(_ result: Result<Void, Error>) {
      let value = lock.withLock { let value = continuation; continuation = nil; return value }
      value?.resume(with: result)
    }
  }
  static func start(_ connection: NWConnection, queue: DispatchQueue) async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let done = Completion(continuation)
        connection.stateUpdateHandler = { state in
          switch state {
          case .ready: done.finish(.success(()))
          case .failed(let error), .waiting(let error): done.finish(.failure(error)); connection.cancel()
          case .cancelled: done.finish(.failure(NotebookTransportError.disconnected))
          default: break
          }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 12) { done.finish(.failure(NotebookTransportError.disconnected)) }
      }
    } onCancel: { connection.cancel() }
  }
  static func send(_ data: Data, on connection: NWConnection) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      connection.send(content: data, completion: .contentProcessed { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      })
    }
  }
  static func read(_ connection: NWConnection, maximum: Int = 32 * 1024) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, _, error in
        if let error { continuation.resume(throwing: error) }
        else if let data, !data.isEmpty { continuation.resume(returning: data) }
        else { continuation.resume(throwing: NotebookTransportError.disconnected) }
      }
    }
  }
  static func connected(_ connection: NWConnection) async throws -> Data {
    let timeout = Task { try await Task.sleep(for: .seconds(55)); connection.cancel() }
    defer { timeout.cancel() }
    var data = Data()
    while data.count <= 8192 {
      data.append(try await read(connection, maximum: 4096))
      if let end = data.range(of: Data("\r\n\r\n".utf8)) {
        guard String(decoding: data[..<end.lowerBound], as: UTF8.self).hasPrefix("HTTP/1.1 200 ") else { throw NotebookTransportError.authenticationRequired }
        return Data(data[end.upperBound...])
      }
    }
    throw NotebookTransportError.frameTooLarge
  }
  static func pipe(_ first: NWConnection, _ second: NWConnection) async {
    await withTaskCancellationHandler {
      await withTaskGroup(of: Void.self) { group in
        for (source, target) in [(first, second), (second, first)] {
          group.addTask {
            do { while !Task.isCancelled { try await send(read(source), on: target) } } catch { }
            source.cancel(); target.cancel()
          }
        }
        await group.waitForAll()
      }
    } onCancel: { first.cancel(); second.cancel() }
  }
}

import Foundation
import Network
import OSLog
import TetradCore

private typealias TetradWireProtocol = Coder<
  WireMessage,
  WireMessage,
  NetworkJSONCoder
>

struct WireSendQueue {
  private var storage: [WireMessage] = []
  private var head = 0

  var isEmpty: Bool { head == storage.count }
  var messages: [WireMessage] { Array(storage[head...]) }

  mutating func enqueue(_ message: WireMessage) {
    if case .presence = message,
      head < storage.count,
      case .presence = storage[storage.count - 1]
    {
      storage[storage.count - 1] = message
    } else {
      storage.append(message)
    }
  }

  mutating func takeFirst() -> WireMessage? {
    guard head < storage.count else { return nil }
    let message = storage[head]
    head += 1
    if head >= 64, head * 2 >= storage.count {
      storage.removeFirst(head)
      head = 0
    }
    return message
  }
}

@MainActor
private final class OrderedWireSender {
  private let connection: NetworkConnection<TetradWireProtocol>
  private var queue = WireSendQueue()
  private var drainTask: Task<Void, Never>?
  private var isStopped = false

  init(connection: NetworkConnection<TetradWireProtocol>) {
    self.connection = connection
  }

  func enqueue(_ message: WireMessage) {
    guard !isStopped else { return }
    queue.enqueue(message)
    guard drainTask == nil else { return }
    drainTask = Task { [weak self] in
      await self?.drain()
    }
  }

  func cancel() {
    isStopped = true
    drainTask?.cancel()
    drainTask = nil
    queue = WireSendQueue()
  }

  private func drain() async {
    while !Task.isCancelled, let message = queue.takeFirst() {
      do {
        try await connection.send(message)
      } catch {
        isStopped = true
        queue = WireSendQueue()
        break
      }
    }
    drainTask = nil
    if !isStopped, !queue.isEmpty { enqueueNextDrain() }
  }

  private func enqueueNextDrain() {
    guard drainTask == nil else { return }
    drainTask = Task { [weak self] in
      await self?.drain()
    }
  }
}

@MainActor
final class NearbySync {
  enum Role {
    case macListener
    case iPadConnector
  }

  var onMessage: ((WireMessage) -> Void)?
  var onConnect: (() -> Void)?

  private let role: Role
  private let peerName: String
  private var listenerTask: Task<Void, Never>?
  private var browserTask: Task<Void, Never>?
  private var connections: [String: NetworkConnection<TetradWireProtocol>] = [:]
  private var senders: [String: OrderedWireSender] = [:]
  private var requestedEndpoints = Set<String>()
  private let logger = Logger(
    subsystem: "com.amirtlinov.tetrad",
    category: "NearbySync"
  )

  init(role: Role, peerName: String) {
    self.role = role
    self.peerName = peerName
  }

  func start() {
    guard listenerTask == nil, browserTask == nil else { return }
    switch role {
    case .macListener:
      startListener()
    case .iPadConnector:
      startBrowser()
    }
  }

  private func startListener() {
    listenerTask = Task { [weak self] in
      guard let self else { return }
      do {
        let listener = try NetworkListener(
          for: .bonjour(name: "mac-\(peerName)", type: "_tetrad._tcp"),
          using: wireParameters()
        )
        .onStateUpdate { [logger] _, state in
          logger.info("Listener: \(String(describing: state), privacy: .public)")
        }
        try await listener.run { [weak self] connection in
          guard let self else { return }
          await accept(connection)
        }
      } catch {
        logger.error("Listener stopped: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  private func startBrowser() {
    browserTask = Task { [weak self] in
      guard let self else { return }
      let parameters = NWParameters.tcp
      parameters.includePeerToPeer = true
      parameters.acceptLocalOnly = true
      let browser = NetworkBrowser(
        for: .bonjour("_tetrad._tcp"),
        using: parameters
      )
      .onStateUpdate { [logger] _, state in
        logger.info("Browser: \(String(describing: state), privacy: .public)")
      }
      do {
        try await browser.run { [weak self] endpoints in
          guard let self else { return }
          logger.info("Discovered \(endpoints.count, privacy: .public) endpoint(s)")
          for endpoint in endpoints where endpoint.name.hasPrefix("mac-") {
            await connect(to: endpoint)
          }
        }
      } catch {
        logger.error("Browser stopped: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  func send(_ message: WireMessage) {
    for sender in senders.values {
      sender.enqueue(message)
    }
  }

  private func connect(to endpoint: Bonjour.Endpoint) async {
    guard requestedEndpoints.insert(endpoint.id).inserted else { return }
    defer { requestedEndpoints.remove(endpoint.id) }
    while !Task.isCancelled {
      let connection = NetworkConnection(
        to: endpoint,
        using: wireParameters()
      )
      .onStateUpdate { [logger] _, state in
        logger.info("Outgoing connection: \(String(describing: state), privacy: .public)")
      }
      await accept(connection)
      guard !Task.isCancelled else { return }
      try? await Task.sleep(for: .seconds(1))
    }
  }

  private func accept(_ connection: NetworkConnection<TetradWireProtocol>) async {
    let id = connection.id
    guard connections[id] == nil else { return }
    logger.info("Opening connection \(id, privacy: .public)")
    connections[id] = connection
    senders[id] = OrderedWireSender(connection: connection)
    onConnect?()
    do {
      for try await message in connection.messages {
        onMessage?(message.content)
      }
    } catch {
      logger.error("Connection \(id, privacy: .public) stopped: \(error.localizedDescription, privacy: .public)")
    }
    senders[id]?.cancel()
    senders[id] = nil
    connections[id] = nil
  }

  private func wireParameters() -> NWParametersBuilder<TetradWireProtocol> {
    .parameters {
      Coder(WireMessage.self, using: .json) {
        TCP().noDelay(true).keepalive(
          idleTimeInSeconds: 2,
          count: 3,
          intervalInSeconds: 2
        )
      }
    }
    .peerToPeerIncluded(true)
    .localOnly(true)
    .serviceClass(.responsiveData)
  }
}

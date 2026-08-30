import Foundation
import Network
import OSLog
import NotebookCore

private typealias NotebookWireProtocol = Coder<
  WireMessage,
  WireMessage,
  NetworkJSONCoder
>

struct PresenceSequenceTracker {
  private var latestBySession: [UUID: UInt64] = [:]

  mutating func accepts(_ envelope: PresenceEnvelope) -> Bool {
    guard envelope.isValid,
      envelope.sequence > latestBySession[envelope.sessionID, default: 0]
    else { return false }
    latestBySession[envelope.sessionID] = envelope.sequence
    return true
  }
}

struct WireSendQueue {
  private var storage: [WireMessage] = []
  private var head = 0

  var isEmpty: Bool { head == storage.count }
  var messages: [WireMessage] {
    guard head < storage.count else { return [] }
    return Array(storage[head...])
  }

  mutating func enqueue(_ message: WireMessage) {
    if case .presence(let incoming) = message,
      incoming.phase == .active,
      head < storage.count,
      case .presence(let pending) = storage[storage.count - 1],
      pending.phase == .active,
      pending.sessionID == incoming.sessionID
    {
      storage[storage.count - 1] = message
    } else if case .drawing(let incomingPageID, _, _) = message,
      head < storage.count,
      case .drawing(let pendingPageID, _, _) = storage[storage.count - 1],
      pendingPageID == incomingPageID
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
  private let connection: NetworkConnection<NotebookWireProtocol>
  private var queue = WireSendQueue()
  private var drainTask: Task<Void, Never>?
  private var isStopped = false

  init(connection: NetworkConnection<NotebookWireProtocol>) {
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
  var onDisconnect: (() -> Void)?

  private let role: Role
  private let peerName: String
  private var listenerTask: Task<Void, Never>?
  private var browserTask: Task<Void, Never>?
  private var endpointTasks: [String: Task<Void, Never>] = [:]
  private var connections: [String: NetworkConnection<NotebookWireProtocol>] = [:]
  private var senders: [String: OrderedWireSender] = [:]
  private let logger = Logger(
    subsystem: "com.amirtlinov.notebook",
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
      while !Task.isCancelled {
        do {
          let listener = try NetworkListener(
            for: .bonjour(name: "mac-\(peerName)", type: "_notebook._tcp"),
            using: wireParameters()
          )
          .onStateUpdate { [logger] _, state in
            logger.info("Listener: \(String(describing: state), privacy: .public)")
          }
          try await listener.run { [weak self] connection in
            guard let self else { return }
            Task { [weak self] in
              await self?.accept(connection)
            }
          }
        } catch {
          logger.error("Listener stopped: \(error.localizedDescription, privacy: .public)")
        }
        guard !Task.isCancelled else { return }
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  private func startBrowser() {
    browserTask = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        parameters.acceptLocalOnly = true
        let browser = NetworkBrowser(
          for: .bonjour("_notebook._tcp"),
          using: parameters
        )
        .onStateUpdate { [logger] _, state in
          logger.info("Browser: \(String(describing: state), privacy: .public)")
        }
        do {
          try await browser.run { [weak self] endpoints in
            guard let self else { return }
            discovered(Array(endpoints))
          }
        } catch {
          logger.error("Browser stopped: \(error.localizedDescription, privacy: .public)")
        }
        cancelEndpointTasks()
        guard !Task.isCancelled else { return }
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  func send(_ message: WireMessage) {
    for sender in senders.values {
      sender.enqueue(message)
    }
  }

  private func discovered(_ endpoints: [Bonjour.Endpoint]) {
    let available = Dictionary(
      uniqueKeysWithValues: endpoints
        .filter { $0.name.hasPrefix("mac-") }
        .map { ($0.id, $0) }
    )
    logger.info("Discovered \(available.count, privacy: .public) Mac endpoint(s)")

    let removed = endpointTasks.keys.filter { available[$0] == nil }
    for id in removed {
      endpointTasks[id]?.cancel()
      endpointTasks[id] = nil
    }
    for (id, endpoint) in available where endpointTasks[id] == nil {
      endpointTasks[id] = Task { [weak self] in
        await self?.maintainConnection(to: endpoint)
      }
    }
  }

  private func cancelEndpointTasks() {
    for task in endpointTasks.values { task.cancel() }
    endpointTasks.removeAll()
  }

  private func maintainConnection(to endpoint: Bonjour.Endpoint) async {
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

  private func accept(_ connection: NetworkConnection<NotebookWireProtocol>) async {
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
    if connections.isEmpty { onDisconnect?() }
  }

  private func wireParameters() -> NWParametersBuilder<NotebookWireProtocol> {
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

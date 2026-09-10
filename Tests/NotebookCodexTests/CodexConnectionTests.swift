import Darwin
import Foundation
import Testing
import NotebookCore
@testable import NotebookCodex

private final class Peer: @unchecked Sendable {
  let root: URL
  let endpoint: URL
  let listener: Int32
  init() throws {
    root = URL(fileURLWithPath: "/tmp").appendingPathComponent("codex-wire-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    endpoint = root.appendingPathComponent("ipc.sock")
    listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let path = Array(endpoint.path.utf8) + [0]
    guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw CodexBridgeError.unsafeEndpoint }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard result == 0, listen(listener, 1) == 0, chmod(endpoint.path, 0o600) == 0 else { throw CodexBridgeError.unavailable }
  }
  deinit { Darwin.close(listener); try? FileManager.default.removeItem(at: root) }

  func serve(_ handler: @escaping @Sendable (Int32) throws -> Void) async throws {
    try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
      DispatchQueue.global().async { [self] in
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else { done.resume(throwing: CodexBridgeError.unavailable); return }
        defer { Darwin.close(fd) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        do { try handler(fd); done.resume() } catch { done.resume(throwing: error) }
      }
    }
  }
  static func read(_ fd: Int32) throws -> JSONValue {
    func exact(_ size: Int) throws -> Data {
      var data = Data(), bytes = [UInt8](repeating: 0, count: size)
      while data.count < size {
        let count = Darwin.read(fd, &bytes, size - data.count)
        guard count > 0 else { throw CodexBridgeError.disconnected }
        data.append(contentsOf: bytes.prefix(count))
      }
      return data
    }
    let prefix = try exact(4)
    let count = prefix.enumerated().reduce(0) { $0 | (Int($1.element) << (8 * $1.offset)) }
    guard count > 0, count <= CodexDesktopProtocol.frameLimit else { throw CodexBridgeError.invalidFrame }
    return try JSONDecoder().decode(JSONValue.self, from: exact(count))
  }
  static func write(_ fd: Int32, _ value: JSONValue) throws {
    let data = try CodexFrames.encode(value, framing: .length)
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        guard count > 0 else { throw CodexBridgeError.disconnected }
        offset += count
      }
    }
  }
  static func response(_ fd: Int32, to request: JSONValue, owner: String = "client", result: JSONValue) throws {
    try write(fd, .object(["type": .string("response"), "method": request["method"]!, "requestId": request["requestId"]!,
      "resultType": .string("success"), "handledByClientId": .string(owner), "result": result]))
  }
}

@Suite("Same-user desktop transport and bounded RPC")
struct CodexConnectionTests {
  @Test func endpointMustBePrivateSocket() throws {
    let peer = try Peer()
    let channel = try CodexChannel.connect(peer.endpoint)
    channel.start(receive: { _ in }, ended: { _ in }); channel.stop()
    chmod(peer.endpoint.path, 0o666)
    #expect(throws: CodexBridgeError.unsafeEndpoint) { try CodexChannel.connect(peer.endpoint) }
    chmod(peer.endpoint.path, 0o600); chmod(peer.root.path, 0o777)
    #expect(throws: CodexBridgeError.unsafeEndpoint) { try CodexChannel.connect(peer.endpoint) }
  }

  @Test func missingAndSymlinkEndpointsReject() throws {
    let peer = try Peer(), link = peer.root.appendingPathComponent("link.sock")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: peer.endpoint)
    #expect(throws: CodexBridgeError.unsafeEndpoint) { try CodexChannel.connect(link) }
    #expect(throws: CodexBridgeError.unsafeEndpoint) { try CodexChannel.connect(peer.root.appendingPathComponent("missing")) }
  }

  @Test func discoveryNeverClaimsOwnership() async throws {
    let peer = try Peer()
    async let server: Void = peer.serve { fd in
      let initialize = try Peer.read(fd)
      try Peer.write(fd, .object(["type": .string("client-discovery-request"), "requestId": .string("discovery")]))
      let refusal = try Peer.read(fd)
      #expect(refusal["response"]?["canHandle"] == .bool(false))
      try Peer.response(fd, to: initialize, result: .object(["clientId": .string("client")]))
      let discovery = try Peer.read(fd)
      #expect(discovery["version"] == .number(1)); #expect(discovery["sourceClientId"] == .string("client"))
      try Peer.response(fd, to: discovery, owner: "desktop", result: .object(["supportsUntrustedAppInput": .bool(true)]))
    }
    let rpc = CodexRPC(channel: try CodexChannel.connect(peer.endpoint), surface: .desktop)
    try await rpc.start()
    #expect(try await rpc.discover(threadID: UUID().uuidString) == "desktop")
    await rpc.stop(); try await server
  }

  @Test func wrongInitializeOwnerFails() async throws {
    let peer = try Peer()
    async let server: Void = peer.serve { fd in
      let request = try Peer.read(fd)
      try Peer.response(fd, to: request, owner: "wrong", result: .object(["clientId": .string("client")]))
    }
    let rpc = CodexRPC(channel: try CodexChannel.connect(peer.endpoint), surface: .desktop)
    await #expect(throws: CodexBridgeError.wrongOwner) { try await rpc.start() }
    await rpc.stop(); try await server
  }

  @Test func targetedResponseCannotComeFromAnotherOwner() async throws {
    let peer = try Peer()
    async let server: Void = peer.serve { fd in
      try Peer.response(fd, to: Peer.read(fd), result: .object(["clientId": .string("client")]))
      let request = try Peer.read(fd)
      try Peer.response(fd, to: request, owner: "different-owner", result: .object(["ok": .bool(true)]))
    }
    let rpc = CodexRPC(channel: try CodexChannel.connect(peer.endpoint), surface: .desktop)
    try await rpc.start()
    await #expect(throws: CodexBridgeError.wrongOwner) {
      try await rpc.request("thread-follower-interrupt-turn", params: .object([:]), owner: "desktop")
    }
    await rpc.stop(); try await server
  }

  @Test func metadataSurfaceCannotExecuteOrResume() async throws {
    let peer = try Peer()
    let channel = try CodexChannel.connect(peer.endpoint)
    let rpc = CodexRPC(channel: channel, surface: .metadata)
    channel.start(receive: { _ in }, ended: { _ in })
    for method in ["turn/start", "thread/resume", "thread/fork", "account/login/start", "account/logout", "account/login/cancel", "account/chatgptAuthTokens/refresh", "config/value/write"] {
      await #expect(throws: CodexBridgeError.unsupportedRequest) { try await rpc.request(method, params: .object([:])) }
    }
    for params: JSONValue in [.object([:]), .object(["refreshToken": .bool(true)]),
      .object(["refreshToken": .bool(false), "account": .string("another")])] {
      await #expect(throws: CodexBridgeError.invalidInput) { try await rpc.request("account/read", params: params) }
    }
    await rpc.stop()
  }

  @Test func peerClosureCompletesPendingRequest() async throws {
    let peer = try Peer()
    async let server: Void = peer.serve { fd in
      try Peer.response(fd, to: Peer.read(fd), result: .object(["clientId": .string("client")]))
      _ = try Peer.read(fd)
    }
    let rpc = CodexRPC(channel: try CodexChannel.connect(peer.endpoint), surface: .desktop)
    try await rpc.start()
    await #expect(throws: CodexBridgeError.disconnected) { try await rpc.discover(threadID: UUID().uuidString) }
    await rpc.stop(); try await server
  }
}

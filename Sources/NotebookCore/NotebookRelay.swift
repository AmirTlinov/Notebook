import Foundation

/// Routing capability, not a Notebook pair key or a Codex credential.
/// Stored only in the device Keychain and delivered over an already trusted pair.
public struct NotebookRelayRoute: Codable, Equatable, Sendable {
  public let endpoint: URL
  public let route: UUID
  public let capability: String
  public init(endpoint: URL, route: UUID, capability: String) {
    self.endpoint = endpoint; self.route = route; self.capability = capability
  }
  public var isValid: Bool {
    endpoint.scheme == "https" && endpoint.host?.isEmpty == false && endpoint.user == nil && endpoint.password == nil
      && endpoint.port == nil && (endpoint.path.isEmpty || endpoint.path == "/")
      && endpoint.query == nil && endpoint.fragment == nil && endpoint.absoluteString.utf8.count <= 256
      && capability.utf8.count == 43 && capability.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
  }
  public var tunnelHost: String { route.uuidString.lowercased() + ".notebook" }
}

public struct NotebookRelayAdvertisement: Codable, Equatable, Sendable {
  public let credentialID: UUID
  public let route: NotebookRelayRoute?
  public init(credentialID: UUID, route: NotebookRelayRoute?) { self.credentialID = credentialID; self.route = route }
}

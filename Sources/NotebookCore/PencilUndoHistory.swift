import Foundation

/// A completed contact owns only the UUIDs it added, never the whole surface.
public struct PencilUndoHistory: Sendable {
  public struct Domain: Codable, Hashable, Sendable {
    public let kind: CollaborationTarget.Kind
    public let id: UUID
    public init(_ target: CollaborationTarget) { kind = target.kind; id = target.id }
    public init?(surface: SurfaceID) {
      guard let owner = surface.ownerID, let kind = CollaborationTarget.Kind(rawValue: surface.kind.rawValue) else { return nil }
      self.kind = kind; id = owner
    }
    public var key: String { kind.rawValue + ":" + id.uuidString.lowercased() }
    public static func page(_ id: UUID) -> Self { .init(.init(kind: .page, id: id)) }
    public static func board(_ id: UUID) -> Self { .init(.init(kind: .board, id: id)) }
    public static func cover(_ id: UUID) -> Self { .init(.init(kind: .cover, id: id)) }
    public static func document(_ id: UUID) -> Self { .init(.init(kind: .document, id: id)) }
    public static func codeFragment(_ id: UUID) -> Self { .init(.init(kind: .codeFragment, id: id)) }
  }
  private let capacity: Int
  public enum Entry: Codable, Equatable, Sendable { case ink(Set<UUID>), command(UUID) }
  private var contributions: [Domain: [Entry]] = [:]

  public init(capacity: Int = 32) {
    precondition(capacity > 0)
    self.capacity = capacity
  }

  public mutating func recordAction(domain: Domain, actionID: UUID) {
    var history = contributions[domain, default: []]
    guard !history.contains(.ink([actionID])) else { return }
    history.append(.ink([actionID]))
    contributions[domain] = Array(history.suffix(capacity))
  }

  public func lastContribution(for domain: Domain) -> Set<UUID>? {
    if case .ink(let ids) = contributions[domain]?.last { return ids }; return nil
  }
  public func lastCommand(for domain: Domain) -> UUID? {
    if case .command(let id) = contributions[domain]?.last { return id }; return nil
  }
  public mutating func recordCommand(domain: Domain, actionID: UUID) {
    var history = contributions[domain, default: []]
    guard !history.contains(.command(actionID)) else { return }
    history.append(.command(actionID)); contributions[domain] = Array(history.suffix(capacity))
  }
  public mutating func didUndoCommand(domain: Domain, actionID: UUID) {
    contributions[domain]?.removeAll { $0 == .command(actionID) }
  }

  public mutating func didRemoveContribution(_ ids: Set<UUID>, for domain: Domain) {
    guard var history = contributions[domain], let index = history.lastIndex(of: .ink(ids)) else { return }
    history.remove(at: index)
    contributions[domain] = history
  }

  /// A scene read restores only bounded identities in the writer's saved order.
  /// It carries no material, pixels or alternate inverse implementation.
  public func entries(for domain: Domain) -> [Entry] { contributions[domain] ?? [] }
  public mutating func restore(_ entries: [Entry], for domain: Domain) {
    contributions[domain] = Array(entries.suffix(capacity))
  }

  public mutating func discardChanges(for domain: Domain) {
    contributions[domain] = nil
  }
}

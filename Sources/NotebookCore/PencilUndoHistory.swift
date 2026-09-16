import Foundation

/// A completed contact owns only the UUIDs it added, never the whole surface.
public struct PencilUndoHistory: Sendable {
  private let capacity: Int
  private enum Entry: Equatable, Sendable { case ink(Set<UUID>), command(UUID) }
  private var contributions: [UUID: [Entry]] = [:]

  public init(capacity: Int = 32) {
    precondition(capacity > 0)
    self.capacity = capacity
  }

  public mutating func recordAction(ownerID: UUID, actionID: UUID) {
    var history = contributions[ownerID, default: []]
    history.append(.ink([actionID]))
    contributions[ownerID] = Array(history.suffix(capacity))
  }

  public func lastContribution(for ownerID: UUID) -> Set<UUID>? {
    if case .ink(let ids) = contributions[ownerID]?.last { return ids }; return nil
  }
  public func lastCommand(for ownerID: UUID) -> UUID? {
    if case .command(let id) = contributions[ownerID]?.last { return id }; return nil
  }
  public func hasHistory(for ownerID: UUID) -> Bool { contributions[ownerID]?.isEmpty == false }
  public mutating func recordCommand(ownerID: UUID, actionID: UUID) {
    var history = contributions[ownerID, default: []]
    history.append(.command(actionID)); contributions[ownerID] = Array(history.suffix(capacity))
  }
  public mutating func didUndoCommand(ownerID: UUID, actionID: UUID) {
    contributions[ownerID]?.removeAll { $0 == .command(actionID) }
  }

  public mutating func didRemoveContribution(_ ids: Set<UUID>, for ownerID: UUID) {
    guard var history = contributions[ownerID], let index = history.lastIndex(of: .ink(ids)) else { return }
    history.remove(at: index)
    contributions[ownerID] = history.isEmpty ? nil : history
  }

  public mutating func discardChanges(for ownerID: UUID) {
    contributions[ownerID] = nil
  }
}

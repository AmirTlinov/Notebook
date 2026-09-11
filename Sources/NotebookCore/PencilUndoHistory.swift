import Foundation

/// A completed contact owns only the UUIDs it added, never the whole surface.
public struct PencilUndoHistory: Sendable {
  private let capacity: Int
  private var contributions: [UUID: [Set<UUID>]] = [:]

  public init(capacity: Int = 32) {
    precondition(capacity > 0)
    self.capacity = capacity
  }

  public mutating func recordAction(ownerID: UUID, actionID: UUID) {
    var history = contributions[ownerID, default: []]
    history.append([actionID])
    contributions[ownerID] = Array(history.suffix(capacity))
  }

  public func lastContribution(for ownerID: UUID) -> Set<UUID>? { contributions[ownerID]?.last }

  public mutating func didRemoveContribution(_ ids: Set<UUID>, for ownerID: UUID) {
    guard var history = contributions[ownerID], let index = history.lastIndex(of: ids) else { return }
    history.remove(at: index)
    contributions[ownerID] = history.isEmpty ? nil : history
  }

  public mutating func discardChanges(for ownerID: UUID) {
    contributions[ownerID] = nil
  }
}

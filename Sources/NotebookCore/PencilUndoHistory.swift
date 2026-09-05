import Foundation

/// A completed contact owns only the UUIDs it added, never the whole page.
public struct PencilUndoHistory: Sendable {
  private let capacity: Int
  private var contributions: [UUID: [Set<UUID>]] = [:]

  public init(capacity: Int = 32) {
    precondition(capacity > 0)
    self.capacity = capacity
  }

  public mutating func recordAction(pageID: UUID, actionID: UUID) {
    var history = contributions[pageID, default: []]
    history.append([actionID])
    contributions[pageID] = Array(history.suffix(capacity))
  }

  public func lastContribution(for pageID: UUID) -> Set<UUID>? { contributions[pageID]?.last }

  public mutating func didRemoveContribution(_ ids: Set<UUID>, for pageID: UUID) {
    guard var history = contributions[pageID], history.last == ids else { return }
    history.removeLast()
    contributions[pageID] = history.isEmpty ? nil : history
  }

  public mutating func discardChanges(for pageID: UUID) {
    contributions[pageID] = nil
  }
}

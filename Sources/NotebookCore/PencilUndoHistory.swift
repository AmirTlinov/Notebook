import Foundation

/// A completed contact owns only the UUIDs it added, never the whole page.
public struct PencilUndoHistory: Sendable {
  private let capacity: Int
  private var contributions: [UUID: [Set<UUID>]] = [:]

  public init(capacity: Int = 32) {
    precondition(capacity > 0)
    self.capacity = capacity
  }

  public mutating func recordAction(pageID: UUID, before: Data, after: Data) {
    guard let old = try? PageInkDrawing.decode(before),
      let new = try? PageInkDrawing.decode(after) else { return }
    let added = Set(new.activeActions.map(\.id)).subtracting(old.actions.map(\.id))
    guard !added.isEmpty else { return }
    var history = contributions[pageID, default: []]
    history.append(added)
    contributions[pageID] = Array(history.suffix(capacity))
  }

  public mutating func removeLastChange(for pageID: UUID, from data: Data) -> Data? {
    guard let drawing = try? PageInkDrawing.decode(data),
      var history = contributions[pageID], let ids = history.popLast(),
      let result = try? drawing.removing(ids).dataRepresentation() else { return nil }
    contributions[pageID] = history.isEmpty ? nil : history
    return result
  }

  public mutating func discardChanges(for pageID: UUID) {
    contributions[pageID] = nil
  }
}

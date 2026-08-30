import Foundation

public struct PencilUndoHistory: Sendable {
  private let capacity: Int
  private var snapshots: [UUID: [Data]] = [:]

  public init(capacity: Int = 32) {
    precondition(capacity > 0)
    self.capacity = capacity
  }

  public mutating func recordAction(
    pageID: UUID,
    before: Data,
    after: Data
  ) {
    guard before != after else { return }

    var pageSnapshots = snapshots[pageID, default: []]
    pageSnapshots.append(before)
    if pageSnapshots.count > capacity {
      pageSnapshots.removeFirst(pageSnapshots.count - capacity)
    }
    snapshots[pageID] = pageSnapshots
  }

  public mutating func removeLastChange(for pageID: UUID) -> Data? {
    guard var pageSnapshots = snapshots[pageID],
          let previous = pageSnapshots.popLast() else {
      return nil
    }
    snapshots[pageID] = pageSnapshots.isEmpty ? nil : pageSnapshots
    return previous
  }

  public mutating func discardChanges(for pageID: UUID) {
    snapshots[pageID] = nil
  }
}

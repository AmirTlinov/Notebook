import Foundation

public struct PencilUndoHistory: Sendable {
  private let capacity: Int
  private var pendingStarts: [UUID: Data] = [:]
  private var snapshots: [UUID: [Data]] = [:]

  public init(capacity: Int = 32) {
    precondition(capacity > 0)
    self.capacity = capacity
  }

  public mutating func observeChange(
    pageID: UUID,
    before: Data,
    after: Data,
    settled: Bool
  ) {
    if before != after, pendingStarts[pageID] == nil {
      pendingStarts[pageID] = before
    }

    guard settled, let start = pendingStarts.removeValue(forKey: pageID) else {
      return
    }
    guard start != after else { return }

    var pageSnapshots = snapshots[pageID, default: []]
    pageSnapshots.append(start)
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
    pendingStarts[pageID] = nil
    snapshots[pageID] = pageSnapshots.isEmpty ? nil : pageSnapshots
    return previous
  }
}

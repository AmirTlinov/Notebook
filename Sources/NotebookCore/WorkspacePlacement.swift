import Foundation

/// One explicit location of one item. A stack anchor is fixed when its UUID is
/// created; removing another member never authors a replacement location here.
public struct WorkspacePlacementPose: Codable, Equatable, Sendable {
  public let center: WorldPoint
  public let zIndex: Int
  public let stackID: UUID?
  public let stackOrder: Int

  public init(center: WorldPoint, zIndex: Int, stackID: UUID? = nil, stackOrder: Int = 0) {
    self.center = center; self.zIndex = zIndex; self.stackID = stackID; self.stackOrder = stackOrder
  }

  var isValid: Bool {
    center.isValid && zIndex >= 0 && stackOrder >= 0 && (stackID != nil || stackOrder == 0)
  }
}

/// Authored heads retain their own observations. Joining two received states
/// cannot make a mechanical display decision look like a new human movement.
public struct WorkspacePlacementHead: Codable, Equatable, Sendable {
  public let pose: WorkspacePlacementPose?
  public let version: ContentFieldVersion
}

public struct WorkspacePlacement: Codable, Equatable, Identifiable, Sendable {
  public let itemID: UUID
  public let heads: [WorkspacePlacementHead]
  public var id: UUID { itemID }
  public var winner: WorkspacePlacementHead {
    heads.max { a, b in
      a.version.human == b.version.human ? a.version.stamp < b.version.stamp : !a.version.human
    }!
  }
  public var pose: WorkspacePlacementPose? { winner.pose }
  public var stamp: VersionStamp { winner.version.stamp }

  /// Whether this register contains or causally follows every accepted head.
  /// A different concurrent winner is still an observation, not a lost command.
  public func hasObserved(_ previous: Self) -> Bool {
    itemID == previous.itemID && previous.heads.allSatisfy { head in
      heads.contains { Self.includes($0.version, head.version) }
    }
  }

  init(itemID: UUID, heads: [WorkspacePlacementHead]) {
    self.itemID = itemID; self.heads = heads
  }

  private enum CodingKeys: String, CodingKey { case itemID, heads }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    itemID = try values.decode(UUID.self, forKey: .itemID)
    heads = try values.decode([WorkspacePlacementHead].self, forKey: .heads)
    try validate()
  }

  static func authored(itemID: UUID, pose: WorkspacePlacementPose?, stamp: VersionStamp,
    human: Bool, previous: Self?) throws -> Self {
    if let previous { try previous.validate() }
    var observed: [String: UInt64] = [:]
    for head in previous?.heads ?? [] {
      for (actor, counter) in head.version.observed { observed[actor] = max(observed[actor] ?? 0, counter) }
    }
    if previous != nil, let old = observed[stamp.actor.uuidString.lowercased()], stamp.counter <= old {
      throw NotebookStorageError.transactionConflict
    }
    observed[stamp.actor.uuidString.lowercased()] = stamp.counter
    let value = Self(itemID: itemID, heads: [.init(pose: pose,
      version: .init(stamp: stamp, human: human, observed: observed))])
    try value.validate(); return value
  }

  func validate() throws {
    guard !heads.isEmpty, heads.count <= 256,
      heads.allSatisfy({ head in
        (head.pose?.isValid ?? true) && head.version.isValid
          && head.version.observed[head.version.stamp.actor.uuidString.lowercased()] == head.version.stamp.counter
          && head.version.observed.allSatisfy { actor, counter in
            UUID(uuidString: actor)?.uuidString.lowercased() == actor && counter <= head.version.stamp.counter
          }
      }), try Self.frontier(heads) == heads else {
      throw NotebookStorageError.invalidTransaction("placement register")
    }
  }

  func merging(_ other: Self) throws -> Self {
    guard itemID == other.itemID else { throw NotebookStorageError.invalidTransaction("placement identity") }
    try validate(); try other.validate()
    return Self(itemID: itemID, heads: try Self.frontier(heads + other.heads))
  }

  private static func frontier(_ input: [WorkspacePlacementHead]) throws -> [WorkspacePlacementHead] {
    guard input.count <= 512 else { throw NotebookStorageError.limitExceeded("placement_frontier") }
    var dots: [VersionStamp: WorkspacePlacementHead] = [:]
    for head in input {
      if let previous = dots[head.version.stamp], previous != head { throw NotebookStorageError.transactionConflict }
      dots[head.version.stamp] = head
    }
    let values = Array(dots.values)
    var retained: [WorkspacePlacementHead] = []
    for head in values {
      var dominated = false
      for other in values where head.version.stamp != other.version.stamp {
        if includes(other.version, head.version) {
          guard !includes(head.version, other.version) else { throw NotebookStorageError.invalidTransaction("placement causal cycle") }
          dominated = true
        }
      }
      if !dominated { retained.append(head) }
    }
    guard retained.count <= 256 else { throw NotebookStorageError.limitExceeded("placement_frontier") }
    return retained.sorted { $0.version.stamp < $1.version.stamp }
  }

  private static func includes(_ a: ContentFieldVersion, _ b: ContentFieldVersion) -> Bool {
    a.observed[b.stamp.actor.uuidString.lowercased()].map { $0 >= b.stamp.counter } ?? false
  }

  func authoredPreference(human: Bool, since previous: Self?) -> Self {
    let old = Set(previous?.heads.map { $0.version.stamp } ?? [])
    return Self(itemID: itemID, heads: heads.map { head in
      guard !old.contains(head.version.stamp) else { return head }
      return .init(pose: head.pose, version: .init(stamp: head.version.stamp, human: human, observed: head.version.observed))
    })
  }
}

/// Derived physical presentation. Singleton and capacity overflow retain their
/// authored stack intent and are merely displayed as free cards at its anchor.
struct WorkspacePlacementLayout: Equatable, Sendable {
  let freeItems: [FreeItemPlacement]
  let stacks: [WorkspaceItemStack]

  init(_ placements: [WorkspacePlacement]) {
    let live = placements.filter { $0.pose != nil }
    var free = live.filter { $0.pose?.stackID == nil }.map { value in
      FreeItemPlacement(itemID: value.id, center: value.pose!.center, zIndex: value.pose!.zIndex, stamp: value.stamp)
    }
    let groups = Dictionary(grouping: live.filter { $0.pose?.stackID != nil }, by: { $0.pose!.stackID! })
    var stacks: [WorkspaceItemStack] = []
    for (id, members) in groups {
      let ordered = members.sorted {
        let a = $0.pose!, b = $1.pose!
        if a.stackOrder != b.stackOrder { return a.stackOrder < b.stackOrder }
        if $0.stamp != $1.stamp { return $0.stamp > $1.stamp }
        return $0.id.uuidString < $1.id.uuidString
      }
      let retained = Array(ordered.prefix(WorkspaceItemStack.maximumItemCount))
      if retained.count >= 2 {
        let anchor = retained[0].pose!
        stacks.append(.init(id: id, center: anchor.center, zIndex: anchor.zIndex,
          itemIDs: retained.map(\.id), stamp: retained.map(\.stamp).max()!))
      }
      for value in ordered.dropFirst(retained.count >= 2 ? retained.count : 0) {
        free.append(.init(itemID: value.id, center: value.pose!.center, zIndex: value.pose!.zIndex, stamp: value.stamp))
      }
    }
    freeItems = free.sorted { $0.id.uuidString < $1.id.uuidString }
    self.stacks = stacks.sorted { $0.id.uuidString < $1.id.uuidString }
  }
}

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

  public var retainedPayloadBytes: Int {
    MemoryLayout<Self>.stride + heads.capacity * MemoryLayout<WorkspacePlacementHead>.stride
      + heads.reduce(0) { $0 + $1.version.retainedPayloadBytes }
  }

  public func writeFootprint() throws -> ContentFieldVersion.WriteFootprint {
    var heads = ContentFieldVersion.WriteFootprint.array
    for head in self.heads {
      var value = ContentFieldVersion.WriteFootprint.object
      if let pose = head.pose { try value.field("pose", Self.poseWriteFootprint(includesStackID: pose.stackID != nil)) }
      try value.field("version", head.version.writeFootprint())
      try heads.element(value)
    }
    var value = ContentFieldVersion.WriteFootprint.object
    try value.field("itemID", .uuid); try value.field("heads", heads)
    return value
  }

  /// A successor keeps the existing source or authors one head observing its
  /// actors and the local dot. Authorship refuses a 257th actor before insertion.
  public func authoredResultWriteBound() throws -> (retainedBytes: Int, footprint: ContentFieldVersion.WriteFootprint) {
    let actors = min(256, heads.reduce(1) { $0 + $1.version.observed.count })
    let retained = MemoryLayout<Self>.stride + 2 * MemoryLayout<WorkspacePlacementHead>.stride
      + MemoryLayout<ContentFieldVersion>.stride
      + (actors * 2 + 1) * (MemoryLayout<String>.stride + MemoryLayout<UInt64>.stride + 32) + actors * 72
    var head = ContentFieldVersion.WriteFootprint.object
    try head.field("pose", Self.poseWriteFootprint(includesStackID: true))
    try head.field("version", ContentFieldVersion.authoredWriteFootprint(actorCount: actors))
    var heads = ContentFieldVersion.WriteFootprint.array; try heads.element(head)
    var value = ContentFieldVersion.WriteFootprint.object
    try value.field("itemID", .uuid); try value.field("heads", heads)
    return (retained, value)
  }

  private static func poseWriteFootprint(includesStackID: Bool) throws -> ContentFieldVersion.WriteFootprint {
    var center = ContentFieldVersion.WriteFootprint.object
    for key in ["tileX", "tileY", "localX", "localY"] { try center.field(key, .number) }
    var value = ContentFieldVersion.WriteFootprint.object
    try value.field("center", center); try value.field("zIndex", .number); try value.field("stackOrder", .number)
    if includesStackID { try value.field("stackID", .uuid) }
    return value
  }

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
    let actor = stamp.actor.uuidString.lowercased()
    var observed = try previous?.authoredObservations(adding: actor) ?? [:]
    if previous != nil, let old = observed[actor], stamp.counter <= old {
      throw NotebookStorageError.transactionConflict
    }
    observed[actor] = stamp.counter
    let value = Self(itemID: itemID, heads: [.init(pose: pose,
      version: .init(stamp: stamp, human: human, observed: observed))])
    try value.validate(); return value
  }

  public func requireAuthoredActorRoom(_ actor: UUID) throws {
    try validate()
    _ = try authoredObservations(adding: actor.uuidString.lowercased())
  }

  private func authoredObservations(adding actor: String) throws -> [String: UInt64] {
    var observed: [String: UInt64] = [:]
    for head in heads {
      for (actor, counter) in head.version.observed {
        guard observed[actor] != nil || observed.count < 256 else {
          throw NotebookStorageError.limitExceeded("placement_observers")
        }
        observed[actor] = max(observed[actor] ?? 0, counter)
      }
    }
    guard observed[actor] != nil || observed.count < 256 else {
      throw NotebookStorageError.limitExceeded("placement_observers")
    }
    return observed
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

/// The same pose reducer serves a displayed drop and the durable placement
/// owner. A preview retains at most the two captured stacks, never board bodies
/// or fabricated causal heads. Its global painter maximum comes from the board.
public struct WorkspacePlacementDraft: Sendable {
  public let poses: [UUID: WorkspacePlacementPose]

  public static func requiresTargetAuthorship(_ targetID: UUID, afterMoving moving: Set<UUID>,
    sources: [WorkspacePlacement]) -> Bool {
    !WorkspacePlacementLayout(sources.filter { !moving.contains($0.id) }).stacks
      .contains { $0.itemIDs.contains(targetID) }
  }

  public init(placements: [WorkspacePlacement], moving itemID: UUID, to center: WorldPoint,
    onto targetID: UUID?, highestZIndex: Int, stackID: UUID, stackIDIsAvailable: Bool = true) throws {
    guard (1...10).contains(placements.count), Set(placements.map(\.id)).count == placements.count,
      placements.first(where: { $0.id == itemID })?.pose != nil,
      center.isValid, let destination = WorkspacePlacementDrop.movingPose(to: center, highestZIndex: highestZIndex) else {
      throw NotebookStorageError.invalidTransaction("placement draft source")
    }
    var result = Dictionary(uniqueKeysWithValues: placements.compactMap { value in value.pose.map { (value.id, $0) } })
    result[itemID] = destination
    if let targetID {
      guard targetID != itemID else { throw NotebookStorageError.invalidTransaction("placement draft target") }
      let projected = placements.map { value -> WorkspacePlacement in
        guard value.id == itemID else { return value }
        let winning = value.winner.version
        return .init(itemID: itemID, heads: value.heads.map {
          $0.version == winning ? .init(pose: destination, version: $0.version) : $0
        })
      }
      let layout = WorkspacePlacementLayout(projected)
      let stack = layout.stacks.first { $0.itemIDs.contains(targetID) }
      let target = layout.freeItems.first { $0.id == targetID }
      let maxOrder = projected.filter { $0.pose?.stackID == stack?.id && stack != nil }
        .compactMap { $0.pose?.stackOrder }.max() ?? 0
      guard let stacked = WorkspacePlacementDrop.stackPoses(moving: itemID, movingPose: destination,
        onto: targetID, target: target, stack: stack, maximumStackOrder: maxOrder,
        stackID: stackID, stackIDIsAvailable: stackIDIsAvailable) else {
        throw NotebookStorageError.invalidTransaction("placement draft stack")
      }
      result.merge(stacked) { _, next in next }
    }
    poses = result
  }
}

enum WorkspacePlacementDrop {
  static func movingPose(to center: WorldPoint, highestZIndex: Int) -> WorkspacePlacementPose? {
    guard center.isValid, highestZIndex < Int.max else { return nil }
    return .init(center: center, zIndex: highestZIndex + 1)
  }

  static func stackPoses(moving movingID: UUID, movingPose: WorkspacePlacementPose,
    onto targetID: UUID, target: FreeItemPlacement?, stack: WorkspaceItemStack?, maximumStackOrder: Int,
    stackID: UUID, stackIDIsAvailable: Bool) -> [UUID: WorkspacePlacementPose]? {
    guard movingID != targetID else { return nil }
    if let stack {
      guard stack.itemIDs.count < WorkspaceItemStack.maximumItemCount, maximumStackOrder < Int.max else { return nil }
      return [movingID: .init(center: stack.center, zIndex: stack.zIndex, stackID: stack.id,
        stackOrder: maximumStackOrder + 1)]
    }
    guard let target, stackIDIsAvailable, max(movingPose.zIndex, target.zIndex) < Int.max else { return nil }
    let z = max(movingPose.zIndex, target.zIndex) + 1
    return [targetID: .init(center: target.center, zIndex: z, stackID: stackID, stackOrder: 0),
      movingID: .init(center: target.center, zIndex: z, stackID: stackID, stackOrder: 1)]
  }
}

/// Derived physical presentation. Singleton and capacity overflow retain their
/// authored stack intent and are merely displayed as free cards at its anchor.
struct WorkspacePlacementLayout: Equatable, Sendable {
  let freeItems: [FreeItemPlacement]
  let stacks: [WorkspaceItemStack]
  let highestZIndex: Int

  init(_ placements: [WorkspacePlacement]) {
    var highest = 0
    let live = placements.filter {
      guard let pose = $0.pose else { return false }
      highest = max(highest, pose.zIndex); return true
    }
    highestZIndex = highest
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

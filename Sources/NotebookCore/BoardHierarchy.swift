import Foundation
import CryptoKit

public struct BoardNode: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public private(set) var board: BoardDocument
  /// The child camera seen through this node's portal, expressed in the
  /// portal's canonical 834 x 1194 viewport. It is independent from board
  /// content so moving a notebook and leaving the board can converge.
  public private(set) var portalCamera: BoardPortalCamera
  public private(set) var portalStamp: VersionStamp

  public init(
    id: UUID,
    board: BoardDocument,
    portalCamera: BoardPortalCamera = BoardPortalCamera(),
    portalStamp: VersionStamp? = nil
  ) {
    self.id = id
    self.board = board
    self.portalCamera = portalCamera
    self.portalStamp = portalStamp
      ?? VersionStamp(counter: 0, actor: board.stamp.actor)
  }

  mutating func replace(with board: BoardDocument) {
    self.board = board
  }

  mutating func replacePortal(
    camera: BoardPortalCamera,
    stamp: VersionStamp
  ) {
    portalCamera = camera
    portalStamp = stamp
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case board
    case portalCamera
    case portalStamp
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    board = try container.decode(BoardDocument.self, forKey: .board)
    portalCamera = try container.decodeIfPresent(
      BoardPortalCamera.self,
      forKey: .portalCamera
    ) ?? BoardPortalCamera()
    portalStamp = try container.decodeIfPresent(
      VersionStamp.self,
      forKey: .portalStamp
    ) ?? VersionStamp(counter: 0, actor: board.stamp.actor)
  }
}

/// The flat durable tree of infinite boards. A non-root board has the same UUID
/// as the board item placed in its one parent. The flat representation keeps
/// decoding and validation bounded by item count rather than nesting depth.
public struct BoardHierarchy: Codable, Equatable, Sendable {
  public static let formatVersion = 1

  public let format: Int
  public let rootBoardID: UUID
  public private(set) var boards: [BoardNode]
  public private(set) var stamp: VersionStamp

  public init(
    rootBoardID: UUID,
    boards: [BoardNode],
    stamp: VersionStamp
  ) {
    format = Self.formatVersion
    self.rootBoardID = rootBoardID
    self.boards = boards
    self.stamp = stamp
  }

  public static func initial(
    rootBoardID: UUID,
    itemIDs: [UUID],
    actor: UUID
  ) -> Self {
    Self(
      rootBoardID: rootBoardID,
      boards: [
        BoardNode(
          id: rootBoardID,
          board: BoardDocument.initial(itemIDs: itemIDs, actor: actor)
        )
      ],
      stamp: VersionStamp(counter: 0, actor: actor)
    )
  }

  public func board(_ boardID: UUID) -> BoardDocument? {
    boards.first(where: { $0.id == boardID })?.board
  }

  /// A portal's sources are its whole reachable subtree, without repeatedly
  /// scanning the flat archive for every child in a deep chain.
  public func descendantBoardIDs(including root: UUID) -> Set<UUID> {
    let indexed = Dictionary(uniqueKeysWithValues: boards.map { ($0.id, $0.board) })
    guard indexed[root] != nil else { return [] }
    var result: Set<UUID> = [root], pending = [root]
    while let id = pending.popLast(), let board = indexed[id] {
      for child in board.itemIDs where indexed[child] != nil && result.insert(child).inserted {
        pending.append(child)
      }
    }
    return result
  }

  public func portalCamera(_ boardID: UUID) -> BoardPortalCamera? {
    boards.first(where: { $0.id == boardID })?.portalCamera
  }

  public var itemIDs: [UUID] {
    boards.flatMap { $0.board.itemIDs }
  }

  /// Identity of the complete converged tree. The Lamport clock orders local
  /// mutations; this frontier names every independently merged content and
  /// portal owner, including insertion and removal of a board.
  public var revision: String {
    let nodes = boards.sorted { $0.id.uuidString < $1.id.uuidString }
    let rows = nodes.map { node in
      "\(node.id.uuidString.lowercased()):"
        + "\(node.board.stamp.counter)@\(node.board.stamp.actor.uuidString.lowercased()):"
        + "\(node.portalStamp.counter)@\(node.portalStamp.actor.uuidString.lowercased())"
    }
    let source = (["board-v1", rootBoardID.uuidString.lowercased()] + rows)
      .joined(separator: "\n") + "\n"
    return SHA256.hash(data: Data(source.utf8))
      .map { String(format: "%02x", $0) }.joined()
  }

  public func parentBoardID(of boardID: UUID) -> UUID? {
    guard boardID != rootBoardID else { return nil }
    return boards.first(where: { $0.board.itemIDs.contains(boardID) })?.id
  }

  /// Names the one board that owns an item's portal. For nested boards this is
  /// their parent; for notebooks and documents it is their current board.
  public func ownerBoardID(of itemID: UUID) -> UUID? {
    boards.first(where: { $0.board.itemIDs.contains(itemID) })?.id
  }

  public func path(to boardID: UUID) -> [UUID]? {
    guard board(boardID) != nil else { return nil }
    let parents = parentMap()
    var reversed = [boardID]
    var cursor = boardID
    var seen = Set<UUID>()
    while cursor != rootBoardID {
      guard seen.insert(cursor).inserted,
        let parent = parents[cursor]
      else { return nil }
      reversed.append(parent)
      cursor = parent
    }
    return reversed.reversed()
  }

  public func focusedCenter(
    of itemID: UUID,
    in boardID: UUID
  ) -> WorldPoint? {
    board(boardID)?.focusedCenter(of: itemID)
  }

  /// Builds a short-lived publication bridge for an older catalog. Missing
  /// items receive a valid root placement; missing board portals also receive
  /// an empty child board, so either catalog can be read between atomic files.
  @discardableResult
  public mutating func placeMissingItems(
    _ items: [WorkspaceItem],
    actor: UUID
  ) -> Bool {
    let owned = Set(boards.flatMap { $0.board.itemIDs })
    let missing = items.filter { !owned.contains($0.id) }
    guard !missing.isEmpty else { return false }
    var changed = false
    for (offset, item) in missing.enumerated() {
      let center = WorldPoint(
        x: Double(offset % 3 - 1) * WorkspaceItemGeometry.notebook.width * 1.28,
        y: Double(offset / 3) * WorkspaceItemGeometry.notebook.height * 1.18
      )
      if item.kind == .board {
        changed = createBoard(
          item.id,
          in: rootBoardID,
          near: center,
          actor: actor
        ) || changed
      } else {
        changed = addItem(
          item.id,
          to: rootBoardID,
          near: center,
          actor: actor
        ) || changed
      }
    }
    return changed
  }

  @discardableResult
  public mutating func createBoard(
    _ boardID: UUID,
    in parentBoardID: UUID,
    near center: WorldPoint,
    actor: UUID
  ) -> Bool {
    guard boardID != rootBoardID,
      board(boardID) == nil,
      let parentIndex = index(of: parentBoardID),
      let next = stamp.advanced(by: actor)
    else { return false }
    var parent = boards[parentIndex].board
    guard parent.addItem(boardID, near: center, actor: actor) else {
      return false
    }
    boards[parentIndex].replace(with: parent)
    boards.append(
      BoardNode(
        id: boardID,
        board: BoardDocument.initial(itemIDs: [], actor: actor)
      )
    )
    stamp = next
    return true
  }

  @discardableResult
  public mutating func addItem(
    _ itemID: UUID,
    to boardID: UUID,
    near center: WorldPoint,
    actor: UUID
  ) -> Bool {
    mutateBoard(boardID, actor: actor) {
      $0.addItem(itemID, near: center, actor: actor)
    }
  }

  @discardableResult
  public mutating func moveItem(
    _ itemID: UUID,
    in boardID: UUID,
    to center: WorldPoint,
    actor: UUID
  ) -> Bool {
    mutateBoard(boardID, actor: actor) {
      $0.moveItem(itemID, to: center, actor: actor)
    }
  }

  /// Remembers the exact child view shown by its parent portal. The camera is
  /// canonical presentation state; board content keeps its own revision.
  @discardableResult
  public mutating func updatePortalCamera(
    _ camera: BoardPortalCamera,
    for boardID: UUID,
    actor: UUID
  ) -> Bool {
    guard boardID != rootBoardID,
      camera.isValid,
      let boardIndex = index(of: boardID),
      boards[boardIndex].portalCamera != camera
    else { return false }
    let counter = max(stamp.counter, boards[boardIndex].portalStamp.counter)
    guard counter < VersionStamp.maximumCounter else { return false }
    let next = VersionStamp(counter: counter + 1, actor: actor)
    boards[boardIndex].replacePortal(camera: camera, stamp: next)
    stamp = next
    return true
  }

  @discardableResult
  public mutating func createStack(
    moving movingID: UUID,
    onto targetID: UUID,
    in boardID: UUID,
    actor: UUID
  ) -> UUID? {
    guard let boardIndex = index(of: boardID),
      let next = stamp.advanced(by: actor)
    else { return nil }
    var board = boards[boardIndex].board
    guard let stackID = board.createStack(
      moving: movingID,
      onto: targetID,
      actor: actor
    ) else { return nil }
    boards[boardIndex].replace(with: board)
    stamp = next
    return stackID
  }

  @discardableResult
  public mutating func unstackItem(
    _ itemID: UUID,
    in boardID: UUID,
    at center: WorldPoint,
    actor: UUID
  ) -> Bool {
    mutateBoard(boardID, actor: actor) {
      $0.unstackItem(itemID, at: center, actor: actor)
    }
  }

  /// A board portal can leave only after its child board is empty. This makes
  /// deletion local and visible instead of silently destroying a hidden tree.
  @discardableResult
  public mutating func deleteItem(
    _ itemID: UUID,
    from boardID: UUID,
    kind: WorkspaceItemKind,
    spatialInk: SpatialInkJournal,
    actor: UUID
  ) -> Bool {
    if kind == .board {
      guard isEmpty(itemID, spatialInk: spatialInk)
      else { return false }
    }
    guard mutateBoard(boardID, actor: actor, mutation: {
      $0.deleteItem(itemID, actor: actor)
    }) else { return false }
    if kind == .board,
      let childIndex = index(of: itemID)
    {
      boards.remove(at: childIndex)
    }
    return true
  }

  public func isEmpty(_ boardID: UUID, spatialInk: SpatialInkJournal) -> Bool {
    guard let board = board(boardID) else { return false }
    return board.itemIDs.isEmpty && board.elements.isEmpty
      && !spatialInk.containsEditableInk(on: .board(boardID))
  }

  @discardableResult
  public mutating func upsertElement(
    _ element: SpatialElement,
    in boardID: UUID,
    expected: VersionStamp?,
    actor: UUID
  ) -> Bool {
    mutateBoard(boardID, actor: actor) {
      $0.upsertElement(element, expected: expected, actor: actor)
    }
  }

  @discardableResult
  public mutating func removeElements(
    ids: Set<String>,
    from boardID: UUID,
    actor: UUID
  ) -> Int {
    guard let boardIndex = index(of: boardID),
      let next = stamp.advanced(by: actor)
    else { return 0 }
    var board = boards[boardIndex].board
    let removed = board.removeElements(ids: ids, actor: actor)
    guard removed > 0 else { return 0 }
    boards[boardIndex].replace(with: board)
    stamp = next
    return removed
  }

  @discardableResult
  public mutating func merge(
    _ other: Self,
    items: [WorkspaceItem]
  ) -> Bool {
    guard rootBoardID == other.rootBoardID,
      other.isValid(items: items)
    else {
      return false
    }
    // The incoming hierarchy owns topology for the incoming catalog. A local
    // node can still win independently when both sides name the same items.
    // This preserves a newer edit in board B while board A adds or removes an
    // item and changes the catalog boundary.
    var candidate = other
    for index in candidate.boards.indices {
      let incoming = candidate.boards[index]
      guard let current = boards.first(where: { $0.id == incoming.id }) else {
        continue
      }
      var resolved = incoming
      if Set(current.board.itemIDs) == Set(incoming.board.itemIDs) {
        var content = current.board
        _ = content.merge(incoming.board, itemIDs: Set(incoming.board.itemIDs))
        resolved.replace(with: content)
      }
      if incoming.portalStamp < current.portalStamp {
        resolved.replacePortal(
          camera: current.portalCamera,
          stamp: current.portalStamp
        )
      }
      candidate.boards[index] = resolved
    }
    if candidate.stamp < stamp { candidate.stamp = stamp }
    if !candidate.isValid(items: items) {
      candidate = other
      if candidate.stamp < stamp { candidate.stamp = stamp }
    }
    guard candidate != self, candidate.isValid(items: items) else {
      return false
    }
    self = candidate
    return true
  }

  public func isValid(items: [WorkspaceItem]) -> Bool {
    guard format == Self.formatVersion,
      rootBoardID != UUID.zero,
      stamp.counter <= VersionStamp.maximumCounter,
      !boards.isEmpty
    else { return false }
    let boardIDs = boards.map(\.id)
    guard Set(boardIDs).count == boardIDs.count,
      board(rootBoardID) != nil
    else { return false }

    let itemIDs = items.map(\.id)
    let ownedItemIDs = boards.flatMap { $0.board.itemIDs }
    guard Set(itemIDs).count == itemIDs.count,
      ownedItemIDs.count == itemIDs.count,
      Set(ownedItemIDs) == Set(itemIDs)
    else { return false }

    let nestedBoardIDs = Set(items.compactMap {
      $0.kind == .board ? $0.id : nil
    })
    guard Set(boardIDs) == nestedBoardIDs.union([rootBoardID]) else {
      return false
    }

    for node in boards {
      let localIDs = Set(node.board.itemIDs)
      guard node.board.isValid(itemIDs: localIDs),
        node.portalCamera.isValid,
        node.portalStamp.counter <= VersionStamp.maximumCounter,
        !(stamp < node.portalStamp)
      else { return false }
      for element in node.board.elements {
        if element.surface.kind == .board {
          guard element.surface == .board(node.id) else { return false }
        } else if element.surface.kind == .cover {
          guard element.surface.ownerID.map(localIDs.contains) == true else {
            return false
          }
        }
      }
    }

    let parents = parentMap()
    guard nestedBoardIDs.allSatisfy({ parents[$0] != nil }) else {
      return false
    }
    var proven = Set([rootBoardID])
    for boardID in nestedBoardIDs where !proven.contains(boardID) {
      var cursor = boardID
      var chain: [UUID] = []
      var seen = Set<UUID>()
      while !proven.contains(cursor) {
        guard seen.insert(cursor).inserted,
          let parent = parents[cursor]
        else { return false }
        chain.append(cursor)
        cursor = parent
      }
      proven.formUnion(chain)
    }
    return true
  }

  private func parentMap() -> [UUID: UUID] {
    let boardIDs = Set(boards.map(\.id))
    var result: [UUID: UUID] = [:]
    for node in boards {
      for itemID in node.board.itemIDs where boardIDs.contains(itemID) {
        result[itemID] = node.id
      }
    }
    return result
  }

  private func index(of boardID: UUID) -> Int? {
    boards.firstIndex(where: { $0.id == boardID })
  }

  @discardableResult
  private mutating func mutateBoard(
    _ boardID: UUID,
    actor: UUID,
    mutation: (inout BoardDocument) -> Bool
  ) -> Bool {
    guard let boardIndex = index(of: boardID),
      let next = stamp.advanced(by: actor)
    else { return false }
    var board = boards[boardIndex].board
    guard mutation(&board) else { return false }
    boards[boardIndex].replace(with: board)
    stamp = next
    return true
  }
}

private extension UUID {
  static let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
}

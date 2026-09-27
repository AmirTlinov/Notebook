import Foundation

final class SpatialInkActionToken: @unchecked Sendable {}

/// One immutable journal root owns both painter order and addressed lookup.
/// Retained scene/contact snapshots share unchanged nodes, not a copied array.
final class SpatialInkActionStorage: @unchecked Sendable {
  let order: InkActionMapNode<Int, SpatialInkAction>?
  let ids: InkActionMapNode<UUID, Int>?
  let eraserIndex:InkReadSetBoundsIndex
  let count: Int
  let isValid: Bool
  let token = SpatialInkActionToken()
  let predecessorToken: SpatialInkActionToken?

  init(_ actions: [SpatialInkAction]) {
    let identifiers = actions.enumerated().map { ($0.element.id, $0.offset) }.sorted { $0.0 < $1.0 }
    order = InkActionMapNode.balanced(actions.enumerated().map { ($0.offset, $0.element) }, 0, actions.count)
    ids = InkActionMapNode.balanced(identifiers, 0, identifiers.count)
    eraserIndex=InkReadSetBoundsIndex(spatial:actions)
    count = actions.count
    isValid = zip(identifiers, identifiers.dropFirst()).allSatisfy { $0.0.0 != $0.1.0 }
      && actions.allSatisfy(\.isValid)
    predecessorToken = nil
  }

  private init(order: InkActionMapNode<Int, SpatialInkAction>?, ids: InkActionMapNode<UUID, Int>?,
    count: Int, isValid: Bool, predecessorToken: SpatialInkActionToken,eraserIndex:InkReadSetBoundsIndex) {
    self.order = order; self.ids = ids; self.count = count
    self.isValid = isValid; self.predecessorToken = predecessorToken;self.eraserIndex=eraserIndex
  }

  var actions: [SpatialInkAction] {
    var values: [SpatialInkAction] = []
    values.reserveCapacity(count); order?.values(into: &values)
    return values
  }

  var orderedActions: InkActionSequence<Int, SpatialInkAction> { .init(root: order) }

  func action(_ id: UUID) -> SpatialInkAction? {
    ids?.value(for: id).flatMap { order?.value(for: $0) }
  }

  func appending(_ action: SpatialInkAction) -> SpatialInkActionStorage {
    let key = action.id
    var index=eraserIndex;index.append(action)
    return .init(order: order?.inserting(count, action) ?? .init(count, action),
      ids: ids?.inserting(key, count) ?? .init(key, count), count: count + 1, isValid: isValid, predecessorToken: token,eraserIndex:index)
  }

  func replacing(_ action: SpatialInkAction) -> SpatialInkActionStorage {
    guard let position = ids?.value(for: action.id) else { return self }
    return .init(order: order?.inserting(position, action), ids: ids, count: count, isValid: isValid, predecessorToken: token,eraserIndex:eraserIndex)
  }

  func hasSameActionStates(as other: SpatialInkActionStorage) -> Bool {
    if self === other { return true }
    guard count == other.count else { return false }
    // A successor is created only for an appended action or a changed gate.
    // Retain its token, never the predecessor root or an unbounded lineage.
    if predecessorToken === other.token || other.predecessorToken === token { return false }
    // Independently admitted windows still need their exact membership/state
    // comparison. A shared global journal clock is not that proof.
    return zip(orderedActions, other.orderedActions).allSatisfy { a, b in
      a.id == b.id && a.stamp == b.stamp && a.stateStamp == b.stateStamp && a.isActive == b.isActive
    }
  }
}

import Foundation

final class SpatialInkActionToken: @unchecked Sendable {}

/// One immutable journal root owns both painter order and addressed lookup.
/// Retained scene/contact snapshots share unchanged nodes, not a copied array.
final class SpatialInkActionStorage: @unchecked Sendable {
  let order: InkActionMapNode<Int, SpatialInkAction>?
  let ids: InkActionMapNode<UUID, Int>?
  let contactIndex:InkContactBoundsIndex
  let count: Int
  let retainedPayloadBytes: Int
  let isValid: Bool
  let token = SpatialInkActionToken()
  let predecessorToken: SpatialInkActionToken?

  init(_ actions: [SpatialInkAction]) {
    let identifiers = actions.enumerated().map { ($0.element.id, $0.offset) }.sorted { $0.0 < $1.0 }
    let valid = zip(identifiers, identifiers.dropFirst()).allSatisfy { $0.0.0 != $0.1.0 }
      && actions.allSatisfy(\.isValid)
    order = InkActionMapNode.balanced(actions.enumerated().map { ($0.offset, $0.element) }, 0, actions.count)
    ids = InkActionMapNode.balanced(identifiers, 0, identifiers.count)
    contactIndex=valid ? InkContactBoundsIndex(spatial:actions):.init()
    count = actions.count
    retainedPayloadBytes = actions.reduce(128) { $0 + $1.retainedPayloadBytes + 192 }+contactIndex.retainedMetadataBytes
    isValid = valid
    predecessorToken = nil
  }

  private init(order: InkActionMapNode<Int, SpatialInkAction>?, ids: InkActionMapNode<UUID, Int>?,
    count: Int, retainedPayloadBytes:Int, isValid: Bool, predecessorToken: SpatialInkActionToken,contactIndex:InkContactBoundsIndex) {
    self.order = order; self.ids = ids; self.count = count
    self.isValid = isValid; self.predecessorToken = predecessorToken;self.contactIndex=contactIndex
    self.retainedPayloadBytes=retainedPayloadBytes
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
    var index=contactIndex;index.append(action)
    return .init(order: order?.inserting(count, action) ?? .init(count, action),
      ids: ids?.inserting(key, count) ?? .init(key, count), count: count + 1,
      retainedPayloadBytes:retainedPayloadBytes+action.retainedPayloadBytes+192
        + index.retainedMetadataBytes-contactIndex.retainedMetadataBytes,
      isValid: isValid, predecessorToken: token,contactIndex:index)
  }

  func replacing(_ action: SpatialInkAction) -> SpatialInkActionStorage {
    guard let position = ids?.value(for: action.id) else { return self }
    var index=contactIndex;index.setActive(action.isActive,for:[action.id])
    return .init(order: order?.inserting(position, action), ids: ids, count: count,
      // Every replacement changes only the visibility gate of this identity.
      retainedPayloadBytes:retainedPayloadBytes+index.retainedMetadataBytes-contactIndex.retainedMetadataBytes,
      isValid: isValid, predecessorToken: token,contactIndex:index)
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

/// The shared measured/predicted tail. Coincident samples replace their last
/// normalized point; only its neighbour and the changed suffix are rebuilt.
public struct IncrementalInkGeometry: Sendable {
  public private(set) var nodes: [InkRenderGeometry.Node] = []
  public private(set) var rebuiltPointCount = 0
  public private(set) var rebuiltNodeStart = 0
  private var normalized: [InkStrokeGeometry.RenderPoint] = []
  private var rawToNormalized: [Int] = []

  public init() {}

  public mutating func update(count: Int, changedFrom: Int,
    point: (Int) -> InkStrokeGeometry.RenderPoint,
    forEach: (Range<Int>, (InkStrokeGeometry.RenderPoint) -> Void) -> Void) {
    let oldCount = normalized.count
    let start = max(0, min(changedFrom, rawToNormalized.count, count))
    var changed: Int
    if start == 0 {
      normalized.removeAll(keepingCapacity: true)
      rawToNormalized.removeAll(keepingCapacity: true)
      changed = 0
    } else {
      let last = rawToNormalized[start - 1], restored = point(start - 1)
      changed = normalized[last] == restored ? last + 1 : last
      normalized.removeSubrange((last + 1)...)
      normalized[last] = restored
      rawToNormalized.removeSubrange(start...)
    }
    forEach(start..<count) { next in
      if let last = normalized.last, InkStrokeGeometry.areCoincident(last, next) {
        changed = min(changed, normalized.count - 1)
        normalized[normalized.count - 1] = next
      } else { normalized.append(next) }
      rawToNormalized.append(normalized.count - 1)
    }
    rebuiltNodeStart = max(0, min(changed, oldCount) - 1)
    nodes.removeSubrange(min(rebuiltNodeStart, nodes.count)...)
    for i in rebuiltNodeStart..<normalized.count {
      nodes.append(InkRenderGeometry.node(at: i, in: normalized))
    }
    rebuiltPointCount = normalized.count - rebuiltNodeStart
  }
}

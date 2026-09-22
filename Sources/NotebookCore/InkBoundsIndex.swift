import CoreGraphics
import Foundation

/// Immutable, disposable acceleration of vector content. Leaf order is paint
/// order, never spatial traversal order. No pixel state or content authority.
public struct InkBoundsIndex: Sendable {
  private struct Node: Sendable {
    let bounds: CGRect
    let left: Int
    let right: Int
    let leaf: Int
  }
  private let nodes: [Node]
  public var byteCount: Int { nodes.count * MemoryLayout<Node>.stride }
  public var bounds: CGRect { nodes.first?.bounds ?? .null }
  public init(_ bounds: [CGRect]) {
    var nodes: [Node] = []
    nodes.reserveCapacity(max(0, bounds.count * 2 - 1))
    func build(_ ids: [Int]) -> Int {
      let id = nodes.count, box = ids.reduce(CGRect.null) { $0.union(bounds[$1]) }
      nodes.append(.init(bounds: box, left: -1, right: -1, leaf: -1))
      if ids.count == 1 { nodes[id] = .init(bounds: box, left: -1, right: -1, leaf: ids[0]) }
      else {
        let horizontal = box.width >= box.height
        let ordered = ids.sorted {
          let a = horizontal ? bounds[$0].midX : bounds[$0].midY
          let b = horizontal ? bounds[$1].midX : bounds[$1].midY
          return a == b ? $0 < $1 : a < b
        }
        let middle = ordered.count / 2
        let left = build(Array(ordered[..<middle])), right = build(Array(ordered[middle...]))
        nodes[id] = .init(bounds: box, left: left, right: right, leaf: -1)
      }
      return id
    }
    if !bounds.isEmpty { _ = build(Array(bounds.indices)) }
    self.nodes = nodes
  }
  public func query(_ area: CGRect) -> (indices: [Int], visitedNodes: Int) {
    let result=query(area,limit:.max)
    return (result.indices,result.visitedNodes)
  }
  public func query(_ area: CGRect, limit: Int)
    -> (indices: [Int], visitedNodes: Int, overflow: Bool) {
    precondition(limit > 0)
    guard !nodes.isEmpty, !area.isNull else { return ([], 0, false) }
    var pending = [0], found: [Int] = [], visited = 0, overflow=false
    while let id = pending.popLast() {
      let node = nodes[id]; visited += 1
      // Closed bounds also admit an exact edge/point contact.
      guard node.bounds.maxX >= area.minX, node.bounds.minX <= area.maxX,
        node.bounds.maxY >= area.minY, node.bounds.minY <= area.maxY else { continue }
      if node.leaf >= 0 {
        if found.count == limit { overflow=true;break }
        found.append(node.leaf)
      }
      else { pending.append(node.right); pending.append(node.left) }
    }
    return (found.sorted(), visited, overflow)
  }
}

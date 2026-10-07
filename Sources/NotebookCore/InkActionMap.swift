/// Immutable action order and UUID indexes shared by page and spatial ink.
/// Updates copy only the search path; captured roots keep their exact source.
/// Only ink/index subtree metadata is derived here; content stays immutable.
protocol InkActionTreeSummary: Sendable {
  associatedtype Value: Sendable
  init(value: Value, left: Self?, right: Self?)
}
struct InkActionEmptySummary<Element: Sendable>: InkActionTreeSummary {
  typealias Value = Element
  init(value: Element, left: Self?, right: Self?) {}
}
typealias InkActionMapNode<Key: Comparable & Sendable, Value: Sendable> =
  InkActionTreeNode<Key, Value, InkActionEmptySummary<Value>>

final class InkActionTreeNode<Key: Comparable & Sendable, Value: Sendable, Summary: InkActionTreeSummary>: @unchecked Sendable where Summary.Value == Value {
  let key: Key
  let value: Value
  let left: InkActionTreeNode?
  let right: InkActionTreeNode?
  let height: Int
  let count: Int
  let summary: Summary

  // Header, child references, height/count and allocator alignment beyond
  // the fixed value fields. Indirect payload belongs to the content owner.
  static var retainedNodeBytes: Int {
    MemoryLayout<Key>.stride+MemoryLayout<Value>.stride+MemoryLayout<Summary>.stride+64
  }

  init(_ key: Key, _ value: Value, left: InkActionTreeNode? = nil, right: InkActionTreeNode? = nil) {
    self.key=key;self.value=value;self.left=left;self.right=right
    height=max(left?.height ?? 0,right?.height ?? 0)+1
    count=(left?.count ?? 0)+(right?.count ?? 0)+1
    summary = .init(value:value,left:left?.summary,right:right?.summary)
  }

  func value(for key: Key) -> Value? {
    if key == self.key { return value }
    return key < self.key ? left?.value(for:key) : right?.value(for:key)
  }

  func inserting(_ key: Key, _ value: Value) -> InkActionTreeNode {
    if key == self.key { return .init(key,value,left:left,right:right) }
    let node: InkActionTreeNode
    if key < self.key { node = .init(self.key,self.value,left:left?.inserting(key,value) ?? .init(key,value),right:right) }
    else { node = .init(self.key,self.value,left:left,right:right?.inserting(key,value) ?? .init(key,value)) }
    return node.balanced()
  }

  func removing(_ key:Key)->InkActionTreeNode? {
    if key < self.key {
      guard let left else {return self}
      return InkActionTreeNode(self.key,value,left:left.removing(key),right:right).balanced()
    }
    if key > self.key {
      guard let right else {return self}
      return InkActionTreeNode(self.key,value,left:left,right:right.removing(key)).balanced()
    }
    guard let left else {return right}
    guard let right else {return left}
    var successor=right
    while let next=successor.left {successor=next}
    return InkActionTreeNode(successor.key,successor.value,left:left,right:right.removing(successor.key)).balanced()
  }

  private func balanced() -> InkActionTreeNode {
    let balance=(left?.height ?? 0)-(right?.height ?? 0)
    if balance > 1,let left {
      let child=(left.left?.height ?? 0) >= (left.right?.height ?? 0) ? left : left.rotatedLeft()
      return InkActionTreeNode(key,value,left:child,right:right).rotatedRight()
    }
    if balance < -1,let right {
      let child=(right.right?.height ?? 0) >= (right.left?.height ?? 0) ? right : right.rotatedRight()
      return InkActionTreeNode(key,value,left:left,right:child).rotatedLeft()
    }
    return self
  }

  private func rotatedLeft() -> InkActionTreeNode {
    guard let right else { return self }
    return .init(right.key,right.value,left:.init(key,value,left:left,right:right.left),right:right.right)
  }

  private func rotatedRight() -> InkActionTreeNode {
    guard let left else { return self }
    return .init(left.key,left.value,left:left.left,right:.init(key,value,left:left.right,right:right))
  }

  func values(into result: inout [Value]) {
    left?.values(into:&result);result.append(value);right?.values(into:&result)
  }

  func last(where predicate: (Value) -> Bool) -> Value? {
    if let found = right?.last(where: predicate) { return found }
    if predicate(value) { return value }
    return left?.last(where: predicate)
  }

  func values(from lowerBound: Key, into result: inout [Value]) {
    if key >= lowerBound {
      left?.values(from:lowerBound,into:&result)
      result.append(value)
    }
    right?.values(from:lowerBound,into:&result)
  }

  static func balanced(_ entries: [(Key,Value)], _ lower: Int, _ upper: Int) -> InkActionTreeNode? {
    guard lower < upper else { return nil }
    let middle=lower+(upper-lower)/2,entry=entries[middle]
    return .init(entry.0,entry.1,left:balanced(entries,lower,middle),right:balanced(entries,middle+1,upper))
  }
}

/// A captured action index shares immutable search paths with its successors.
/// This narrow value API keeps the tree implementation inside the ink domain.
public struct InkActionMap<Key: Comparable & Sendable, Value: Sendable>: Sendable {
  private var root: InkActionMapNode<Key, Value>?

  public init() {}
  public init(entries: [(Key, Value)]) {
    let ordered = entries.sorted { $0.0 < $1.0 }
    if ordered.count > 1 {
      for index in 1..<ordered.count { precondition(ordered[index - 1].0 != ordered[index].0) }
    }
    root = InkActionMapNode.balanced(ordered, 0, ordered.count)
  }
  public var count: Int { root?.count ?? 0 }
  public var isEmpty: Bool { root == nil }
  public subscript(_ key: Key) -> Value? {
    get { root?.value(for: key) }
    set {
      if let newValue { root = root?.inserting(key, newValue) ?? .init(key, newValue) }
      else if root?.value(for: key) != nil { root = root?.removing(key) }
    }
  }
  public var values: Values { .init(root: root) }

  /// Each traversal walks the captured root once, retaining only its search path.
  public struct Values: Sequence, Sendable {
    public typealias Element = Value
    private let root: InkActionMapNode<Key, Value>?
    fileprivate init(root: InkActionMapNode<Key, Value>?) { self.root = root }
    public var count: Int { root?.count ?? 0 }
    public var underestimatedCount: Int { count }
    public var isEmpty: Bool { root == nil }
    public var first: Value? {
      var node = root
      while let left = node?.left { node = left }
      return node?.value
    }
    public struct Iterator: IteratorProtocol {
      private var base: InkActionSequence<Key, Value>.Iterator
      fileprivate init(root: InkActionMapNode<Key, Value>?) { base = .init(root) }
      public mutating func next() -> Value? { base.next() }
    }
    public func makeIterator() -> Iterator { .init(root: root) }
  }
}

extension InkActionMap: Equatable where Value: Equatable {
  public static func == (lhs: Self, rhs: Self) -> Bool {
    func same(_ a: InkActionMapNode<Key, Value>?, _ b: InkActionMapNode<Key, Value>?) -> Bool {
      if a === b { return true }
      guard let a, let b, a.count == b.count else { return false }
      if a.key == b.key {
        return a.value == b.value && same(a.left, b.left) && same(a.right, b.right)
      }
      // Equal maps can have different AVL shapes after insertion/removal.
      // Shared shape/path equality above handles ordinary pose replacements.
      var left: [InkActionMapNode<Key, Value>] = [], right: [InkActionMapNode<Key, Value>] = []
      func descend(_ root: InkActionMapNode<Key, Value>?, into path: inout [InkActionMapNode<Key, Value>]) {
        var node = root
        while let current = node { path.append(current); node = current.left }
      }
      func next(_ path: inout [InkActionMapNode<Key, Value>]) -> InkActionMapNode<Key, Value>? {
        guard let node = path.popLast() else { return nil }
        descend(node.right, into: &path)
        return node
      }
      descend(a, into: &left); descend(b, into: &right)
      while let x = next(&left) {
        guard let y = next(&right), x.key == y.key, x.value == y.value else { return false }
      }
      return right.isEmpty
    }
    return same(lhs.root, rhs.root)
  }
}

/// Iteration retains only its current search path, not a second action array.
struct InkActionSequence<Key: Comparable & Sendable, Value: Sendable>: Sequence, Sendable {
  let root: InkActionMapNode<Key, Value>?
  struct Iterator: IteratorProtocol {
    private var path: [InkActionMapNode<Key, Value>] = []
    init(_ root: InkActionMapNode<Key, Value>?) { descend(root) }
    private mutating func descend(_ root: InkActionMapNode<Key, Value>?) {
      var node = root
      while let current = node { path.append(current); node = current.left }
    }
    mutating func next() -> Value? {
      guard let node = path.popLast() else { return nil }
      descend(node.right)
      return node.value
    }
  }
  func makeIterator() -> Iterator { .init(root) }
}

/// Immutable action order and UUID indexes shared by page and spatial ink.
/// Updates copy only the search path; captured roots keep their exact source.
final class InkActionMapNode<Key: Comparable & Sendable, Value: Sendable>: @unchecked Sendable {
  let key: Key
  let value: Value
  let left: InkActionMapNode?
  let right: InkActionMapNode?
  let height: Int

  init(_ key: Key, _ value: Value, left: InkActionMapNode? = nil, right: InkActionMapNode? = nil) {
    self.key=key;self.value=value;self.left=left;self.right=right
    height=max(left?.height ?? 0,right?.height ?? 0)+1
  }

  func value(for key: Key) -> Value? {
    if key == self.key { return value }
    return key < self.key ? left?.value(for:key) : right?.value(for:key)
  }

  func inserting(_ key: Key, _ value: Value) -> InkActionMapNode {
    if key == self.key { return .init(key,value,left:left,right:right) }
    let node: InkActionMapNode
    if key < self.key { node = .init(self.key,self.value,left:left?.inserting(key,value) ?? .init(key,value),right:right) }
    else { node = .init(self.key,self.value,left:left,right:right?.inserting(key,value) ?? .init(key,value)) }
    return node.balanced()
  }

  func removing(_ key:Key)->InkActionMapNode? {
    if key < self.key {
      guard let left else {return self}
      return InkActionMapNode(self.key,value,left:left.removing(key),right:right).balanced()
    }
    if key > self.key {
      guard let right else {return self}
      return InkActionMapNode(self.key,value,left:left,right:right.removing(key)).balanced()
    }
    guard let left else {return right}
    guard let right else {return left}
    var successor=right
    while let next=successor.left {successor=next}
    return InkActionMapNode(successor.key,successor.value,left:left,right:right.removing(successor.key)).balanced()
  }

  private func balanced() -> InkActionMapNode {
    let balance=(left?.height ?? 0)-(right?.height ?? 0)
    if balance > 1,let left {
      let child=(left.left?.height ?? 0) >= (left.right?.height ?? 0) ? left : left.rotatedLeft()
      return InkActionMapNode(key,value,left:child,right:right).rotatedRight()
    }
    if balance < -1,let right {
      let child=(right.right?.height ?? 0) >= (right.left?.height ?? 0) ? right : right.rotatedRight()
      return InkActionMapNode(key,value,left:left,right:child).rotatedLeft()
    }
    return self
  }

  private func rotatedLeft() -> InkActionMapNode {
    guard let right else { return self }
    return .init(right.key,right.value,left:.init(key,value,left:left,right:right.left),right:right.right)
  }

  private func rotatedRight() -> InkActionMapNode {
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

  static func balanced(_ entries: [(Key,Value)], _ lower: Int, _ upper: Int) -> InkActionMapNode? {
    guard lower < upper else { return nil }
    let middle=lower+(upper-lower)/2,entry=entries[middle]
    return .init(entry.0,entry.1,left:balanced(entries,lower,middle),right:balanced(entries,middle+1,upper))
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

import CryptoKit
import Foundation

/// The hash names these canonical bytes, not a surrounding storage fragment.
/// A branch has equally high children, packed left to right in groups of 32.
struct NotebookPageOrderNode: Codable, Equatable, Sendable {
  let format: Int
  let height: Int
  let count: Int
  let pages: [UUID]
  let children: [String]

  init(format: Int = 1, height: Int, count: Int, pages: [UUID] = [], children: [String] = []) {
    self.format = format; self.height = height; self.count = count
    self.pages = pages; self.children = children
  }

  func canonicalData() throws -> Data {
    try validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(self)
  }

  var hash: String { get throws { pageOrderHash(try canonicalData()) } }

  /// Checks the node itself. A complete admission also verifies each child's
  /// hash, expected height/count, and global page identity in materialize.
  func validate() throws {
    guard format == 1, (0...NotebookPageOrderVector.maximumHeight).contains(height),
      (0...NotebookPageOrderVector.maximumPages).contains(count),
      count <= NotebookPageOrderVector.capacity(height: height) else {
      throw NotebookStorageError.invalidTransaction("page order node metadata")
    }
    if height == 0 {
      guard children.isEmpty, pages.count == count, pages.count <= NotebookPageOrderVector.width,
        Set(pages).count == pages.count else {
        throw NotebookStorageError.invalidTransaction("page order leaf")
      }
    } else {
      let capacity = NotebookPageOrderVector.capacity(height: height - 1)
      guard count > 0, pages.isEmpty, (1...NotebookPageOrderVector.width).contains(children.count),
        children.count == (count - 1) / capacity + 1,
        children.allSatisfy(validPageOrderHash), Set(children).count == children.count else {
        throw NotebookStorageError.invalidTransaction("page order branch")
      }
    }
  }
}

/// One canonical persistent vector serves both pure catalog values and SQL.
/// Append borrows an already admitted root; the membership owner rejects a new
/// UUID already present in the prefix or tombstones without walking that prefix.
enum NotebookPageOrderVector {
  static let maximumPages = 1_000_000
  static let maximumNodes = 131_072
  static let maximumBytes = 64 * 1024 * 1024
  static let maximumNodeBytes = 4_096
  fileprivate static let width = 32
  fileprivate static let maximumHeight = 3

  fileprivate static func capacity(height: Int) -> Int {
    // Callers validate height before multiplication; height 3 holds 1,048,576.
    var capacity = width
    for _ in 0..<height { capacity *= width }
    return capacity
  }

  static func build(_ pages: [UUID], write: (NotebookPageOrderNode) throws -> String) throws -> String {
    guard pages.count <= maximumPages else { throw NotebookStorageError.limitExceeded("page_order_pages") }
    guard Set(pages).count == pages.count else { throw NotebookStorageError.invalidTransaction("duplicate page order identity") }
    var budget = WriteBudget()
    if pages.isEmpty { return try budget.write(.init(height: 0, count: 0), using: write) }
    var level: [(hash: String, count: Int)] = []
    for start in stride(from: 0, to: pages.count, by: width) {
      let values = Array(pages[start..<min(start + width, pages.count)])
      level.append((try budget.write(.init(height: 0, count: values.count, pages: values), using: write), values.count))
    }
    var height = 0
    while level.count > 1 {
      height += 1
      var next: [(hash: String, count: Int)] = []
      for start in stride(from: 0, to: level.count, by: width) {
        let children = level[start..<min(start + width, level.count)]
        let count = children.reduce(0) { $0 + $1.count }
        next.append((try budget.write(.init(height: height, count: count, children: children.map(\.hash)), using: write), count))
      }
      level = next
    }
    return level[0].hash
  }

  /// No left sibling is read. Its validity belongs to the admitted immutable
  /// root. Only the changed right spine is copied; old blobs remain untouched.
  static func append(to root: String, pageID: UUID,
    read: (String) throws -> NotebookPageOrderNode,
    write: (NotebookPageOrderNode) throws -> String) throws -> String {
    let nodes = try rightSpine(root, read: read)
    let original = nodes[root]!
    guard original.count < maximumPages else { throw NotebookStorageError.limitExceeded("page_order_pages") }
    var path: [(hash: String, node: NotebookPageOrderNode)] = [], cursor = root
    while let node = nodes[cursor] {
      path.append((cursor, node))
      guard let last = node.children.last else { break }
      cursor = last
    }
    let leaf = path.removeLast()
    guard !leaf.node.pages.contains(pageID) else { throw NotebookStorageError.invalidTransaction("duplicate page order identity") }
    var budget = WriteBudget()
    var replacement: String
    var overflow: String?
    if leaf.node.count < width {
      replacement = try budget.write(.init(height: 0, count: leaf.node.count + 1, pages: leaf.node.pages + [pageID]), using: write)
    } else {
      replacement = leaf.hash
      overflow = try budget.write(.init(height: 0, count: 1, pages: [pageID]), using: write)
    }
    for ancestor in path.reversed() {
      var children = ancestor.node.children
      children[children.count - 1] = replacement
      if let next = overflow, children.count == width {
        // Every child was full; carry one equally high right sibling upward.
        replacement = ancestor.hash
        overflow = try budget.write(.init(height: ancestor.node.height, count: 1, children: [next]), using: write)
      } else {
        if let next = overflow { children.append(next) }
        replacement = try budget.write(.init(height: ancestor.node.height, count: ancestor.node.count + 1, children: children), using: write)
        overflow = nil
      }
    }
    if let next = overflow {
      return try budget.write(.init(height: original.height + 1, count: original.count + 1, children: [replacement, next]), using: write)
    }
    return replacement
  }

  /// Full admission: iterative, globally unique, and bounded before output is
  /// expanded. A repeated nonempty subtree would repeat its UUIDs, so it fails.
  static func materialize(_ root: String, read: (String) throws -> NotebookPageOrderNode) throws -> [UUID] {
    var budget = ReadBudget()
    let first = try budget.read(root, using: read)
    try validateRoot(first)
    var pending = [(hash: root, height: first.height, count: first.count)]
    var visited = Set<String>(), identities = Set<UUID>(), pages: [UUID] = []
    pages.reserveCapacity(first.count)
    while let expected = pending.popLast() {
      guard visited.insert(expected.hash).inserted else { throw NotebookStorageError.invalidTransaction("repeated page order subtree") }
      let node = try budget.read(expected.hash, using: read)
      guard node.height == expected.height, node.count == expected.count else {
        throw NotebookStorageError.invalidTransaction("page order child metadata")
      }
      if node.height == 0 {
        for page in node.pages {
          guard identities.insert(page).inserted else { throw NotebookStorageError.invalidTransaction("duplicate page order identity") }
          pages.append(page)
        }
      } else {
        let capacity = capacity(height: node.height - 1)
        for index in node.children.indices.reversed() {
          let count = index == node.children.count - 1 ? node.count - index * capacity : capacity
          pending.append((node.children[index], node.height - 1, count))
        }
      }
    }
    guard pages.count == first.count else { throw NotebookStorageError.invalidTransaction("page order count") }
    return pages
  }

  /// Resolves one slot of an admitted root without reading its siblings. The
  /// visited path still proves the expected child height, count and raw hash.
  static func pageID(at index: Int, in root: String,
    read: (String) throws -> NotebookPageOrderNode) throws -> UUID? {
    guard index >= 0 else { return nil }
    var budget = ReadBudget()
    var node = try budget.read(root, using: read), offset = index
    try validateRoot(node)
    guard offset < node.count else { return nil }
    while node.height > 0 {
      let capacity = capacity(height: node.height - 1), childIndex = offset / capacity
      let expectedCount = childIndex == node.children.count - 1 ? node.count - childIndex * capacity : capacity
      let child = try budget.read(node.children[childIndex], using: read)
      guard child.height == node.height - 1, child.count == expectedCount else {
        throw NotebookStorageError.invalidTransaction("page order child metadata")
      }
      node = child; offset %= capacity
    }
    return node.pages[offset]
  }

  /// Diffs admitted values by their canonical intervals. Equal subtrees at the
  /// same offset are immutable proof, not a reason to read their old prefix.
  /// The membership owner separately validates removed slots and total count.
  static func visitChangedPages(from oldRoot: String?, to newRoot: String,
    read: (String) throws -> NotebookPageOrderNode,
    visit: (Int, UUID) throws -> Void) throws {
    var budget = ReadBudget()
    let newNode = try budget.read(newRoot, using: read)
    try validateRoot(newNode)
    let newReference = Subtree(hash: newRoot, height: newNode.height, count: newNode.count)
    var oldReference: Subtree?
    if let oldRoot {
      let oldNode = try budget.read(oldRoot, using: read)
      try validateRoot(oldNode)
      oldReference = Subtree(hash: oldRoot, height: oldNode.height, count: oldNode.count)
    }
    var pending: [(old: Subtree?, new: Subtree, offset: Int)] = [(oldReference, newReference, 0)]
    var work = 0, emitted = 0
    while let pair = pending.popLast() {
      work += 1
      guard work <= maximumNodes else { throw NotebookStorageError.limitExceeded("page_order_diff_work") }
      if let old = pair.old, old.hash == pair.new.hash {
        guard old == pair.new else { throw NotebookStorageError.invalidTransaction("page order child metadata") }
        continue
      }
      let next = try budget.read(pair.new, using: read)
      let previous = try pair.old.map { try budget.read($0, using: read) }
      if let previous, previous.height > next.height {
        pending.append((subtree(previous, at: 0), pair.new, pair.offset))
      } else if next.height == 0 {
        for (index, page) in next.pages.enumerated() {
          if let previous, previous.pages.indices.contains(index), previous.pages[index] == page { continue }
          guard emitted < maximumPages else { throw NotebookStorageError.limitExceeded("page_order_diff_pages") }
          try visit(pair.offset + index, page); emitted += 1
        }
      } else {
        let capacity = capacity(height: next.height - 1)
        for index in next.children.indices.reversed() {
          let oldChild: Subtree?
          if let previous, previous.height == next.height {
            oldChild = previous.children.indices.contains(index) ? subtree(previous, at: index) : nil
          } else { oldChild = index == 0 ? pair.old : nil }
          pending.append((oldChild, subtree(next, at: index), pair.offset + index * capacity))
        }
      }
    }
  }

  static func rightSpine(_ root: String, read: (String) throws -> NotebookPageOrderNode) throws -> [String: NotebookPageOrderNode] {
    var budget = ReadBudget(), cursor = root
    var expected: (height: Int, count: Int)?
    while true {
      let node = try budget.read(cursor, using: read)
      if let expected {
        guard node.height == expected.height, node.count == expected.count else {
          throw NotebookStorageError.invalidTransaction("page order child metadata")
        }
      } else { try validateRoot(node) }
      guard let last = node.children.last else { return budget.nodes }
      expected = (node.height - 1, node.count - (node.children.count - 1) * capacity(height: node.height - 1))
      cursor = last
    }
  }

  private static func validateRoot(_ node: NotebookPageOrderNode) throws {
    guard node.height == 0 || node.count > capacity(height: node.height - 1) else {
      throw NotebookStorageError.invalidTransaction("page order root height")
    }
  }

  private struct Subtree: Equatable {
    let hash: String
    let height: Int
    let count: Int
  }

  private static func subtree(_ node: NotebookPageOrderNode, at index: Int) -> Subtree {
    let capacity = capacity(height: node.height - 1)
    let count = index == node.children.count - 1 ? node.count - index * capacity : capacity
    return .init(hash: node.children[index], height: node.height - 1, count: count)
  }

  private struct ReadBudget {
    var nodes: [String: NotebookPageOrderNode] = [:]
    var bytes = 0

    mutating func read(_ reference: Subtree, using read: (String) throws -> NotebookPageOrderNode) throws -> NotebookPageOrderNode {
      let node = try self.read(reference.hash, using: read)
      guard node.height == reference.height, node.count == reference.count else {
        throw NotebookStorageError.invalidTransaction("page order child metadata")
      }
      return node
    }

    mutating func read(_ hash: String, using read: (String) throws -> NotebookPageOrderNode) throws -> NotebookPageOrderNode {
      guard validPageOrderHash(hash) else { throw NotebookStorageError.invalidTransaction("page order hash") }
      if let node = nodes[hash] { return node }
      guard nodes.count < maximumNodes else { throw NotebookStorageError.limitExceeded("page_order_nodes") }
      let node = try read(hash), data = try node.canonicalData()
      guard data.count <= maximumNodeBytes, data.count <= maximumBytes - bytes else {
        throw NotebookStorageError.limitExceeded("page_order_bytes")
      }
      guard pageOrderHash(data) == hash else { throw NotebookStorageError.blobHashMismatch }
      bytes += data.count; nodes[hash] = node
      return node
    }
  }

  private struct WriteBudget {
    var nodes = 0
    var bytes = 0

    mutating func write(_ node: NotebookPageOrderNode, using write: (NotebookPageOrderNode) throws -> String) throws -> String {
      let data = try node.canonicalData()
      guard nodes < maximumNodes else { throw NotebookStorageError.limitExceeded("page_order_nodes") }
      guard data.count <= maximumNodeBytes, data.count <= maximumBytes - bytes else { throw NotebookStorageError.limitExceeded("page_order_bytes") }
      let expected = pageOrderHash(data)
      guard try write(node) == expected else { throw NotebookStorageError.blobHashMismatch }
      nodes += 1; bytes += data.count
      return expected
    }
  }
}

private func validPageOrderHash(_ hash: String) -> Bool {
  hash.utf8.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}

private func pageOrderHash(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

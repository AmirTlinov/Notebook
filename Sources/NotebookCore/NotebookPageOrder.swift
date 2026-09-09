import Foundation

/// One authored value keeps its original causal context. Joining observations
/// never turns a derived, displayed sequence into that author's value.
struct NotebookPageOrderHead: Codable, Equatable, Sendable {
  let version: ContentFieldVersion
  let valueRoot: String
}

/// The pageIDs field owns both its immutable authored frontier and its derived
/// visible value. SQL positions are an address index of the latter, not clocks.
struct NotebookPageOrderRegister: Codable, Equatable, Sendable {
  let format: Int
  let heads: [NotebookPageOrderHead]
  let visibleRoot: String

  init(heads: [NotebookPageOrderHead], visibleRoot: String) {
    format = 1; self.heads = heads; self.visibleRoot = visibleRoot
  }

  static func validHash(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  func validate() throws {
    guard format == 1, Self.validHash(visibleRoot), !heads.isEmpty, heads.count <= 256,
      heads.allSatisfy({ head in
        head.version.isValid && Self.validHash(head.valueRoot)
          && head.version.observed[head.version.stamp.actor.uuidString.lowercased()] == head.version.stamp.counter
          && head.version.observed.allSatisfy({ key, counter in
            UUID(uuidString: key)?.uuidString.lowercased() == key && counter <= head.version.stamp.counter
          })
      }), try Self.frontier(heads) == heads else {
      throw NotebookStorageError.invalidTransaction("page order register")
    }
  }

  /// Context is immutable on an authored head. Only a new edit can observe
  /// the whole frontier and replace it with a causally following head.
  static func authored(root: String, stamp: VersionStamp, human: Bool,
    previous: Self?) throws -> Self {
    if let previous { try previous.validate() }
    var observed: [String: UInt64] = [:]
    for head in previous?.heads ?? [] {
      for (actor, counter) in head.version.observed { observed[actor] = max(observed[actor] ?? 0, counter) }
    }
    if previous != nil, let known = observed[stamp.actor.uuidString.lowercased()], stamp.counter <= known {
      throw NotebookStorageError.transactionConflict
    }
    observed[stamp.actor.uuidString.lowercased()] = stamp.counter
    let version = ContentFieldVersion(stamp: stamp, human: human, observed: observed)
    let result = Self(heads: [.init(version: version, valueRoot: root)], visibleRoot: root)
    try result.validate(); return result
  }

  private static func includes(_ left: ContentFieldVersion, _ right: ContentFieldVersion) -> Bool {
    guard let counter = left.observed[right.stamp.actor.uuidString.lowercased()] else { return false }
    return counter >= right.stamp.counter
  }

  static func frontier(_ input: [NotebookPageOrderHead]) throws -> [NotebookPageOrderHead] {
    guard input.count <= 512 else { throw NotebookStorageError.limitExceeded("page_order_frontier") }
    var dots: [String: NotebookPageOrderHead] = [:]
    for head in input {
      guard head.version.isValid, validHash(head.valueRoot) else { throw NotebookStorageError.invalidTransaction("page order head") }
      let dot = head.version.stamp.actor.uuidString.lowercased() + ":" + String(head.version.stamp.counter)
      if let previous = dots[dot], previous != head { throw NotebookStorageError.transactionConflict }
      dots[dot] = head
    }
    let unique = Array(dots.values)
    var retained: [NotebookPageOrderHead] = []
    for candidate in unique {
      var dominated = false
      for other in unique where candidate.version.stamp != other.version.stamp {
        if includes(other.version, candidate.version) {
          guard !includes(candidate.version, other.version) else { throw NotebookStorageError.invalidTransaction("page order causal cycle") }
          dominated = true
        }
      }
      if !dominated { retained.append(candidate) }
    }
    guard retained.count <= 256 else { throw NotebookStorageError.limitExceeded("page_order_frontier") }
    return retained.sorted { $0.version.stamp < $1.version.stamp }
  }

  var winner: NotebookPageOrderHead {
    heads.max { a, b in
      a.version.human == b.version.human ? a.version.stamp < b.version.stamp : !a.version.human
    }!
  }

  var fieldVersion: ContentFieldVersion {
    var observed: [String: UInt64] = [:]
    for head in heads { for (actor, counter) in head.version.observed { observed[actor] = max(observed[actor] ?? 0, counter) } }
    return .init(stamp: winner.version.stamp, human: winner.version.human, observed: observed)
  }

  /// This is the one pure order policy used by snapshots and SQL replication.
  /// The vector normal form makes equivalent merges share one content root.
  static func normalize(_ inputs: [Self], live: Set<UUID>,
    read: (String) throws -> NotebookPageOrderNode,
    write: (NotebookPageOrderNode) throws -> String) throws -> (register: Self, pages: [UUID]) {
    guard !inputs.isEmpty, !live.isEmpty, live.count <= NotebookPageOrderVector.maximumPages else {
      throw NotebookStorageError.invalidTransaction("page order membership")
    }
    for input in inputs { try input.validate() }
    let heads = try frontier(inputs.flatMap(\.heads))
    let provisional = Self(heads: heads, visibleRoot: inputs[0].visibleRoot)
    // Every surviving head is validated, including a concurrent losing value.
    // A corrupt ignored suggestion is not admitted into durable provenance.
    var cache: [String: NotebookPageOrderNode] = [:], bytes = 0, visits = 0
    func checkedRead(_ hash: String) throws -> NotebookPageOrderNode {
      if let node = cache[hash] { return node }
      let node = try read(hash)
      bytes += try node.canonicalData().count
      guard cache.count < 131_072, bytes <= 64 * 1024 * 1024 else { throw NotebookStorageError.limitExceeded("page_order_merge_nodes") }
      cache[hash] = node; return node
    }
    var preferred: [UUID] = [], validated = Set<String>()
    for head in heads where validated.insert(head.valueRoot).inserted {
      let count = try checkedRead(head.valueRoot).count
      guard count <= 4_000_000 - visits else { throw NotebookStorageError.limitExceeded("page_order_merge_work") }
      visits += count
      let value = try NotebookPageOrderVector.materialize(head.valueRoot, read: checkedRead)
      if head.valueRoot == provisional.winner.valueRoot { preferred = value }
    }
    let result = preferred.filter(live.contains)
      + live.subtracting(preferred).sorted { $0.uuidString < $1.uuidString }
    let root = try NotebookPageOrderVector.build(result, write: write)
    return (Self(heads: heads, visibleRoot: root), result)
  }
}

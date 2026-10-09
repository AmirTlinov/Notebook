import Foundation

/// One received context belongs to the register, not its displayed author.
/// Concurrent values must survive a display choice: a later causal successor
/// can remove that winner and expose a previously non-winning human edit.
public struct ContentFieldVersion: Codable, Equatable, Sendable {
  public let stamp: VersionStamp
  public let human: Bool
  public let observed: [String: UInt64]
  private var heads: [ContentFieldHead]?

  /// A scalar admission can reject retained register bodies without visiting
  /// them when its contract accepts only a compact causal comparison token.
  public var hasRetainedAlternatives: Bool { heads != nil }

  /// Concurrent authored alternatives remain owned even when another value is
  /// displayed. Admission must include their bodies without exposing or copying
  /// the private causal frontier.
  public var retainedHeadsBytes:Int {
    guard let heads else { return 0 }
    return heads.capacity * MemoryLayout<ContentFieldHead>.stride
      + heads.reduce(0) { $0 + ($1.value?.retainedPayloadBytes ?? 0) }
  }
  public var retainedPayloadBytes:Int {
    MemoryLayout<Self>.stride + observed.capacity * (MemoryLayout<String>.stride + MemoryLayout<UInt64>.stride + 32)
      + observed.keys.reduce(0) { $0 + $1.utf8.count * 2 } + retainedHeadsBytes
  }

  /// Integer-only accounting of the clock's Codable representation. It does
  /// not encode a body or construct a second JSON tree during admission.
  public struct WriteFootprint: Equatable, Sendable {
    public let wireBytes: Int
    public let tokens: Int
    public var decodingBytes: Int { wireBytes * 8 + tokens * 512 }

    public init(wireBytes: Int, tokens: Int) throws {
      let limit = NotebookNativeWriteAllowance.maximumExecutionBytes
      guard wireBytes >= 0, tokens >= 0, wireBytes <= limit / 8,
        tokens <= (limit - wireBytes * 8) / 512 else {
        throw NotebookStorageError.limitExceeded("placement_metadata_memory")
      }
      self.wireBytes = wireBytes; self.tokens = tokens
    }

    static var object: Self { try! .init(wireBytes: 2, tokens: 1) }
    static var array: Self { object }
    static var number: Self { try! .init(wireBytes: 32, tokens: 1) }
    static var boolean: Self { try! .init(wireBytes: 5, tokens: 1) }
    static var uuid: Self { try! .init(wireBytes: 38, tokens: 1) }

    static func string(_ value: String) throws -> Self {
      var bytes = 2
      let limit = NotebookNativeWriteAllowance.maximumExecutionBytes / 8
      for byte in value.utf8 {
        let next = byte < 0x20 ? 6 : byte == 34 || byte == 92 || byte == 47 ? 2 : 1
        guard bytes <= limit - next else { throw NotebookStorageError.limitExceeded("placement_metadata_memory") }
        bytes += next
      }
      return try .init(wireBytes: bytes, tokens: 1)
    }

    mutating func field(_ key: String, _ value: Self) throws {
      let key = try Self.string(key)
      self = try .init(wireBytes: wireBytes + key.wireBytes + value.wireBytes + 2,
        tokens: tokens + 1 + value.tokens)
    }

    mutating func element(_ value: Self) throws {
      self = try .init(wireBytes: wireBytes + value.wireBytes + 1, tokens: tokens + value.tokens)
    }

    static func stamp() throws -> Self {
      var value = object
      try value.field("counter", number); try value.field("actor", uuid)
      return value
    }

    static func json(_ source: JSONValue, depth: Int = 0) throws -> Self {
      guard depth <= NotebookJSONAdmission.maximumDepth else { throw NotebookStorageError.limitExceeded("placement_metadata_depth") }
      switch source {
      case .null: return try .init(wireBytes: 4, tokens: 1)
      case .bool: return boolean
      case .number: return number
      case .string(let value): return try string(value)
      case .array(let values):
        var value = array
        for child in values { try value.element(json(child, depth: depth + 1)) }
        return value
      case .object(let values):
        var value = object
        for (key, child) in values { try value.field(key, json(child, depth: depth + 1)) }
        return value
      }
    }
  }

  public func writeFootprint() throws -> WriteFootprint {
    var observations = WriteFootprint.object
    for actor in observed.keys { try observations.field(actor, .number) }
    var value = WriteFootprint.object
    try value.field("stamp", .stamp()); try value.field("human", .boolean)
    try value.field("observed", observations)
    if let heads {
      var alternatives = WriteFootprint.array
      for head in heads {
        var alternative = WriteFootprint.object
        try alternative.field("stamp", .stamp()); try alternative.field("human", .boolean)
        try alternative.field("hasValue", .boolean)
        if let body = head.value { try alternative.field("value", .json(body)) }
        try alternatives.element(alternative)
      }
      try value.field("heads", alternatives)
    }
    return value
  }

  static func authoredWriteFootprint(actorCount: Int) throws -> WriteFootprint {
    guard (0...256).contains(actorCount) else { throw NotebookStorageError.limitExceeded("placement_observers") }
    var observations = WriteFootprint.object
    for _ in 0..<actorCount {
      // Valid placement actor keys are canonical UUID strings.
      observations = try .init(wireBytes: observations.wireBytes + 38 + 32 + 2,
        tokens: observations.tokens + 2)
    }
    var value = WriteFootprint.object
    try value.field("stamp", .stamp()); try value.field("human", .boolean)
    try value.field("observed", observations)
    return value
  }

  init(stamp: VersionStamp, human: Bool, previous: ContentFieldVersion? = nil) {
    var observed = previous?.observed ?? [:]
    observed[stamp.actor.uuidString.lowercased()] = stamp.counter
    self.init(stamp: stamp, human: human, observed: observed)
  }

  init(stamp: VersionStamp, human: Bool, observed: [String: UInt64]) {
    self.stamp = stamp; self.human = human; self.observed = observed; heads = nil
  }

  var isValid: Bool {
    guard stamp.counter <= VersionStamp.maximumCounter && observed.count <= 256,
      observed.allSatisfy({ UUID(uuidString: $0.key) != nil && $0.value <= VersionStamp.maximumCounter }) else { return false }
    guard let heads else { return true }
    guard !heads.isEmpty, heads.count <= 256,
      heads.allSatisfy({ $0.isValid && includes($0.stamp) }),
      Set(heads.map(\.stamp)).count == heads.count,
      heads == heads.sorted(by: { $0.stamp < $1.stamp }),
      let winner = Self.winner(heads) else { return false }
    return winner.stamp == stamp && winner.human == human
  }

  public func includes(_ other: Self) -> Bool {
    includes(other.stamp)
  }

  private func includes(_ dot: VersionStamp) -> Bool {
    observed[dot.actor.uuidString.lowercased()].map { $0 >= dot.counter } ?? false
  }

  private var authoredHeads: [ContentFieldHead] {
    heads ?? [.init(stamp: stamp, human: human, value: nil, hasValue: false)]
  }

  private func binding(_ value: JSONValue?) -> Self {
    var bound = self
    bound.heads = authoredHeads.map { head in
      guard head.stamp == stamp, !head.hasValue else { return head }
      var head = head; head.value = value; head.hasValue = true; return head
    }
    return bound
  }

  /// A removed member has no displayed payload in which to keep this value.
  /// Its existence clock owns removal; its source is still this author's value.
  func retainingValue(_ value: JSONValue?) -> Self { binding(value) }

  var retainedContentValues: [JSONValue] { authoredHeads.compactMap { $0.hasValue ? $0.value : nil } }

  /// The ordinary (non-concurrent) version remains a compact clock. Only a
  /// genuine frontier retains values; the visible value alone cannot represent it.
  func resolving(value: JSONValue?, with other: Self, incomingValue: JSONValue?) throws -> (value: JSONValue?, version: Self) {
    let left = binding(value), right = other.binding(incomingValue)
    let retained = try left.frontier(with: right)
    guard let winner = Self.winner(retained), winner.hasValue else { throw NotebookStorageError.invalidTransaction("content author value missing") }
    return (winner.value, left.joined(right, retained: retained, winner: winner, retainSingleValue: false))
  }

  func joining(_ other: Self) throws -> Self {
    let retained = try frontier(with: other)
    guard let winner = Self.winner(retained) else { throw NotebookStorageError.transactionConflict }
    return joined(other, retained: retained, winner: winner, retainSingleValue: true)
  }

  private func joined(_ other: Self, retained: [ContentFieldHead], winner: ContentFieldHead, retainSingleValue: Bool) -> Self {
    var observations = observed
    for (actor, counter) in other.observed { observations[actor] = max(observations[actor] ?? 0, counter) }
    var result = Self(stamp: winner.stamp, human: winner.human, observed: observations)
    if retained.count > 1 || (retainSingleValue && winner.hasValue) {
      result.heads = retained
    }
    return result
  }

  private static func winner(_ heads: [ContentFieldHead]) -> ContentFieldHead? {
    heads.max { a, b in a.human == b.human ? a.stamp < b.stamp : !a.human }
  }

  private func frontier(with other: Self) throws -> [ContentFieldHead] {
    let left = authoredHeads, right = other.authoredHeads
    guard left.count <= 256, right.count <= 256 else { throw NotebookStorageError.limitExceeded("content_frontier") }
    let a = Dictionary(left.map { ($0.stamp, $0) }, uniquingKeysWith: { first, _ in first })
    let b = Dictionary(right.map { ($0.stamp, $0) }, uniquingKeysWith: { first, _ in first })
    guard a.count == left.count, b.count == right.count else {
      throw NotebookStorageError.invalidTransaction("duplicate content author")
    }
    var retained: [ContentFieldHead] = []
    for dot in Set(a.keys).union(b.keys) {
      switch (a[dot], b[dot]) {
      case (.some(let old), .some(let incoming)):
        guard old.human == incoming.human,
          !old.hasValue || !incoming.hasValue || old.value == incoming.value else {
          throw NotebookStorageError.invalidTransaction("content author value changed")
        }
        retained.append(old.hasValue ? old : incoming)
      case (.some(let head), .none):
        // Seen but absent means superseded. A displayed winner does not
        // inherit authorship of every dot received by its replica.
        if !other.includes(dot) { retained.append(head) }
      case (.none, .some(let head)):
        if !includes(dot) { retained.append(head) }
      case (.none, .none): break
      }
    }
    guard retained.count <= 256 else { throw NotebookStorageError.limitExceeded("content_frontier") }
    return retained.sorted { $0.stamp < $1.stamp }
  }
}

private struct ContentFieldHead: Codable, Equatable, Sendable {
  let stamp: VersionStamp
  let human: Bool
  var value: JSONValue?
  var hasValue: Bool
  var isValid: Bool {
    stamp.counter <= VersionStamp.maximumCounter && (value?.isValid ?? true)
  }
}

public struct CollaborativeContent: Codable, Equatable, Sendable {
  static let maximumFieldCount = 100_000
  public private(set) var fields: [String: ContentFieldVersion] = [:]

  public init() {}
  init(fields: [String: ContentFieldVersion]) { self.fields = fields }

  mutating func recordField(_ key: String, stamp: VersionStamp, human: Bool) {
    fields[key] = .init(stamp: stamp, human: human, previous: fields[key])
  }

  mutating func joinField(_ key: String, version: ContentFieldVersion) throws {
    fields[key] = try fields[key].map { try $0.joining(version) } ?? version
  }

  mutating func setPageOrderVersion(_ key: String, register: NotebookPageOrderRegister) {
    fields[key] = register.fieldVersion
  }

  /// Materialize implicit clocks before the aggregate Lamport frontier moves
  /// without a content edit. Existing causal field owners remain unchanged.
  mutating func materializeVersions(in value: JSONValue, fallback: VersionStamp) {
    let version=ContentFieldVersion(stamp:fallback,human:true)
    for key in contentFields(value).keys where fields[key] == nil { fields[key]=version }
  }

  var isValid: Bool {
    isValid(maximumFields: Self.maximumFieldCount)
  }

  func isValid(maximumFields: Int) -> Bool {
    fields.count <= maximumFields && fields.allSatisfy { key, value in
      key.utf8.count <= 2048 && value.isValid
    }
  }

  mutating func record(before: JSONValue, after: JSONValue, beforeStamp: VersionStamp,
    stamp: VersionStamp, human: Bool) {
    let a = contentFields(before), b = contentFields(after)
    let documentSources = before["files"] != nil || after["files"] != nil
    func equal(_ lhs: JSONValue?, _ rhs: JSONValue?) -> Bool {
      documentSources ? DocumentFile.sourceValuesAreEqual(lhs, rhs) : lhs == rhs
    }
    guard !equal(.object(a), .object(b)) else { return }
    var adopted: Set<String> = []
    for key in Set(a.keys).union(b.keys) {
      let previous = fields[key] ?? .init(stamp: beforeStamp, human: true)
      let changed = !equal(a[key], b[key])
      if let exists = memberExistenceField(key), a[exists] == .bool(true), b[exists] == nil {
        fields[key] = previous.retainingValue(a[key])
      } else if changed {
        fields[key] = .init(stamp: stamp, human: human, previous: previous)
      } else if fields[key] == nil { fields[key] = previous }
      if changed, b[key] != nil {
        // Each changed address names its own existence ancestors. Discover
        // them here rather than searching every flat field for every member.
        var prefix = key[...]
        while let slash = prefix.lastIndex(of: "/") {
          let exists = String(prefix[...slash]) + "exists"
          if b[exists] != nil { adopted.insert(exists) }
          prefix = prefix[..<slash]
        }
      }
    }
    // A hand editing a member also adopts its existence. A concurrent removal
    // then leaves that complete member available rather than a partial object.
    for key in adopted {
      fields[key] = .init(stamp: stamp, human: human,
        previous: fields[key] ?? .init(stamp: beforeStamp, human: true))
    }
  }

  static func merge(local: JSONValue, incoming: JSONValue,
    localState: Self?, incomingState: Self?, localStamp: VersionStamp,
    incomingStamp: VersionStamp, includeOrder: Bool = true) throws -> (value: JSONValue, state: Self) {
    let a = contentFields(local), b = contentFields(incoming)
    var result: [String: JSONValue] = [:]
    var metadata = Self()
    var keys = Set(a.keys).union(b.keys).union(localState?.fields.keys ?? Dictionary<String, ContentFieldVersion>().keys)
      .union(incomingState?.fields.keys ?? Dictionary<String, ContentFieldVersion>().keys)
    if !includeOrder { keys.subtract(["elements/order"]) }
    for key in keys {
      // No field and no authored clock is no observation, not a counter-zero
      // deletion by the sender. A real removal carries its existence version.
      if a[key] == nil && localState?.fields[key] == nil {
        metadata.fields[key] = incomingState?.fields[key] ?? .init(stamp: incomingStamp, human: true)
        result[key] = b[key]; continue
      }
      if b[key] == nil && incomingState?.fields[key] == nil {
        metadata.fields[key] = localState?.fields[key] ?? .init(stamp: localStamp, human: true)
        result[key] = a[key]; continue
      }
      let av = localState?.fields[key] ?? .init(stamp: localStamp, human: true)
      let bv = incomingState?.fields[key] ?? .init(stamp: incomingStamp, human: true)
      let resolved = try av.resolving(value: a[key], with: bv, incomingValue: b[key])
      metadata.fields[key] = resolved.version
      // A cleared optional field is an authored absence. Removed members keep
      // their payload in the original field versions, not in a display fallback.
      result[key] = resolved.value
    }
    for key in keys {
      if let exists = memberExistenceField(key), result[exists] != .bool(true) {
        metadata.fields[key] = metadata.fields[key]?.retainingValue(result[key])
      }
    }
    let base = localStamp > incomingStamp ? local : incoming
    let value = rebuildContent(base: base, fields: result)
    // Membership can append concurrent survivors to the chosen author's
    // sequence. That derived display order is not a new value by that author.
    for name in ["elements"] where includeOrder && value[name] != nil {
      let key = fieldKey([name, "order"])
      let displayed = JSONValue.array(value[name]!.array.compactMap(\.memberIdentity).map(JSONValue.string))
      if displayed != result[key] { metadata.fields[key] = metadata.fields[key]?.retainingValue(result[key]) }
    }
    return (value, metadata)
  }
}

private func memberExistenceField(_ key: String) -> String? {
  let parts = key.split(separator: "/", omittingEmptySubsequences: false)
  guard parts.count >= 3, (parts[0] == "elements" || parts[0] == "files"), parts[2] != "exists" else { return nil }
  return parts[0] + "/" + parts[1] + "/exists"
}

func mergedContentStamp(local: JSONValue, incoming: JSONValue, result: JSONValue,
  localStamp: VersionStamp, incomingStamp: VersionStamp) -> VersionStamp {
  let frontier = max(localStamp, incomingStamp)
  let owner = localStamp > incomingStamp ? local : incoming
  let before = JSONValue.object(contentFields(owner)), after = JSONValue.object(contentFields(result))
  let equal = owner["files"] != nil || result["files"] != nil
    ? DocumentFile.sourceValuesAreEqual(before, after) : before == after
  guard !equal else { return frontier }
  return frontier.advanced(by: frontier.actor) ?? frontier
}

func fieldKey(_ parts: [String]) -> String {
  parts.map { $0.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1") }.joined(separator: "/")
}

/// The winning author orders its surviving members; concurrent additions
/// follow in canonical address order. Both full and addressed merges use it.
func contentMemberOrder(preferred: [String], escapedMembers: [String]) -> [String] {
  let members = Set(escapedMembers), preferredKeys = Set(preferred.map { fieldKey([$0]) })
  return preferred.filter { members.contains(fieldKey([$0])) }
    + members.subtracting(preferredKeys).sorted().map {
      $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
    }
}

func contentFields(_ value: JSONValue) -> [String: JSONValue] {
  var result: [String: JSONValue] = [:]
  for (name, property) in value.object where !["collaboration", "stamp", "agentStamp", "contentStamp", "drawingStamp", "drawingData", "format", "id", "size", "paperSize", "placements"].contains(name) {
    if ["elements", "files"].contains(name) {
      if name == "elements" { result[fieldKey([name, "order"])] = .array(property.array.compactMap(\.memberIdentity).map(JSONValue.string)) }
      for item in property.array {
        guard let id = item.memberIdentity else { continue }
        result[fieldKey([name, id, "exists"])] = .bool(true)
        var content: [String: JSONValue] = [:]
        for (field, val) in item.object {
          if (name == "files" ? ["source", "resource"] : ["source", "html", "kind", "programPackage"]).contains(field) { content[field] = val }
          else if field == "graphic" {
            for (part, value) in val.object {
              if part == "connection" {
                for (field, value) in value.object { result[fieldKey([name, id, "graphic", part, field])] = value }
              } else { result[fieldKey([name, id, "graphic", part])] = value }
            }
          }
          else { result[fieldKey([name, id, field])] = val }
        }
        if !content.isEmpty { result[fieldKey([name, id, "content"])] = .object(content) }
      }
    } else { result[fieldKey([name])] = property }
  }
  return result
}

/// A reconstruction-local body, discarded after the resolved snapshot is
/// materialized. Causal versions and retained alternatives stay in fields.
private struct ContentMemberBody {
  var exists = false
  var values: [String: JSONValue] = [:]
  var graphic: [String: JSONValue] = [:]
  var connection: [String: JSONValue] = [:]

  mutating func include(_ field: String, value: JSONValue) {
    if field == "exists" { exists = value == .bool(true) }
    else if field == "content" {
      for (part, value) in value.object { values[part] = value }
    } else if field.hasPrefix("graphic/connection/") {
      connection[String(field.dropFirst("graphic/connection/".count))] = value
    } else if field.hasPrefix("graphic/") {
      graphic[String(field.dropFirst("graphic/".count))] = value
    } else { values[field] = value }
  }

  var value: JSONValue {
    var result = values, graphic = graphic
    if !connection.isEmpty { graphic["connection"] = .object(connection) }
    if !graphic.isEmpty { result["graphic"] = .object(graphic) }
    return .object(result)
  }
}

private func rebuildContent(base: JSONValue, fields: [String: JSONValue]) -> JSONValue {
  var members: [String: [String: ContentMemberBody]] = [:]
  for (key, value) in fields {
    let parts = key.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0] == "elements" || parts[0] == "files" else { continue }
    members[String(parts[0]), default: [:]][String(parts[1]), default: .init()]
      .include(String(parts[2]), value: value)
  }
  // Detach the root dictionary once, including snapshots with many scalars.
  var result = base.object
  for name in base.object.keys where !["collaboration", "stamp", "agentStamp", "contentStamp", "drawingStamp", "drawingData", "format", "id", "size", "paperSize", "placements"].contains(name) {
    if ["elements", "files"].contains(name) {
      let collection = members[name] ?? [:]
      let ids = collection.compactMap { $0.value.exists ? $0.key : nil }
      let preferred = fields[fieldKey([name, "order"])]?.array.compactMap(\.string) ?? []
      let order = contentMemberOrder(preferred: preferred, escapedMembers: ids)
      result[name] = .array(order.compactMap { collection[fieldKey([$0])]?.value })
    } else if let value = fields[fieldKey([name])] { result[name] = value }
  }
  return .object(result)
}

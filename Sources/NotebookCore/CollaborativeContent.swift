import Foundation

/// The received frontier is distinct from each immutable author's context.
/// Concurrent values must survive a display choice: a later causal successor
/// can remove that winner and expose a previously non-winning human edit.
public struct ContentFieldVersion: Codable, Equatable, Sendable {
  public let stamp: VersionStamp
  public let human: Bool
  public let observed: [String: UInt64]
  private var heads: [ContentFieldHead]?

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
      heads.allSatisfy({ $0.isValid && $0.observed.allSatisfy { (observed[$0.key] ?? 0) >= $0.value } }),
      let canonical = try? Self.frontier(heads), canonical == heads,
      let winner = Self.winner(heads) else { return false }
    return winner.stamp == stamp && winner.human == human
  }

  public func includes(_ other: Self) -> Bool {
    observed[other.stamp.actor.uuidString.lowercased()].map { $0 >= other.stamp.counter } ?? false
  }

  private var authoredHeads: [ContentFieldHead] {
    heads ?? [.init(stamp: stamp, human: human, observed: observed, value: nil, hasValue: false)]
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

  /// The ordinary (non-concurrent) version remains a compact clock. Only a
  /// genuine frontier retains values; the visible value alone cannot represent it.
  func resolving(value: JSONValue?, with other: Self, incomingValue: JSONValue?) throws -> (value: JSONValue?, version: Self) {
    let left = binding(value), right = other.binding(incomingValue)
    let retained = try Self.frontier(left.authoredHeads + right.authoredHeads)
    guard let winner = Self.winner(retained), winner.hasValue else { throw NotebookStorageError.invalidTransaction("content author value missing") }
    return (winner.value, left.joined(right, retained: retained, winner: winner, retainSingleValue: false))
  }

  func joining(_ other: Self) throws -> Self {
    let retained = try Self.frontier(authoredHeads + other.authoredHeads)
    guard let winner = Self.winner(retained) else { throw NotebookStorageError.transactionConflict }
    return joined(other, retained: retained, winner: winner, retainSingleValue: true)
  }

  private func joined(_ other: Self, retained: [ContentFieldHead], winner: ContentFieldHead, retainSingleValue: Bool) -> Self {
    var observations = observed
    for (actor, counter) in other.observed { observations[actor] = max(observations[actor] ?? 0, counter) }
    var result = Self(stamp: winner.stamp, human: winner.human, observed: observations)
    if retained.count > 1 || winner.observed != observations || (retainSingleValue && winner.hasValue) {
      result.heads = retained
    }
    return result
  }

  private static func winner(_ heads: [ContentFieldHead]) -> ContentFieldHead? {
    heads.max { a, b in a.human == b.human ? a.stamp < b.stamp : !a.human }
  }

  private static func frontier(_ input: [ContentFieldHead]) throws -> [ContentFieldHead] {
    guard input.count <= 512 else { throw NotebookStorageError.limitExceeded("content_frontier") }
    var dots: [VersionStamp: ContentFieldHead] = [:]
    for head in input {
      if let old = dots[head.stamp] {
        guard old.human == head.human, old.observed == head.observed else {
          throw NotebookStorageError.invalidTransaction("content author context changed")
        }
        guard !old.hasValue || !head.hasValue || old.value == head.value else {
          throw NotebookStorageError.invalidTransaction("content author value changed")
        }
        if !old.hasValue { dots[head.stamp] = head }
      } else { dots[head.stamp] = head }
    }
    let values = Array(dots.values)
    let retained = try values.filter { head in
      for other in values where other.stamp != head.stamp {
        if other.includes(head) {
          guard !head.includes(other) else { throw NotebookStorageError.invalidTransaction("content causal cycle") }
          return false
        }
      }
      return true
    }.sorted { $0.stamp < $1.stamp }
    guard retained.count <= 256 else { throw NotebookStorageError.limitExceeded("content_frontier") }
    return retained
  }
}

private struct ContentFieldHead: Codable, Equatable, Sendable {
  let stamp: VersionStamp
  let human: Bool
  let observed: [String: UInt64]
  var value: JSONValue?
  var hasValue: Bool
  var isValid: Bool {
    stamp.counter <= VersionStamp.maximumCounter && observed.count <= 256
      && observed.allSatisfy { UUID(uuidString: $0.key) != nil && $0.value <= VersionStamp.maximumCounter }
      && (value?.isValid ?? true)
  }
  func includes(_ other: Self) -> Bool {
    observed[other.stamp.actor.uuidString.lowercased()].map { $0 >= other.stamp.counter } ?? false
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
    for key in contentFields(value).keys where fields[key] == nil {
      fields[key] = .init(stamp: fallback, human: true)
    }
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
    guard a != b else { return }
    for key in Set(a.keys).union(b.keys) {
      let previous = fields[key] ?? .init(stamp: beforeStamp, human: true)
      if let exists = memberExistenceField(key), a[exists] == .bool(true), b[exists] == nil {
        fields[key] = previous.retainingValue(a[key])
      } else if a[key] != b[key] {
        fields[key] = .init(stamp: stamp, human: human, previous: previous)
      } else if fields[key] == nil { fields[key] = previous }
    }
    // A hand editing a member also adopts its existence. A concurrent removal
    // then leaves that complete member available rather than a partial object.
    for key in b.keys where key.hasSuffix("/exists") {
      let prefix = String(key.dropLast("exists".count))
      if b.keys.contains(where: { $0.hasPrefix(prefix) && a[$0] != b[$0] }) {
        fields[key] = .init(stamp: stamp, human: human,
          previous: fields[key] ?? .init(stamp: beforeStamp, human: true))
      }
    }
  }

  static func merge(local: JSONValue, incoming: JSONValue,
    localState: Self?, incomingState: Self?, localStamp: VersionStamp,
    incomingStamp: VersionStamp) throws -> (value: JSONValue, state: Self) {
    let a = contentFields(local), b = contentFields(incoming)
    var result: [String: JSONValue] = [:]
    var metadata = Self()
    let keys = Set(a.keys).union(b.keys).union(localState?.fields.keys ?? Dictionary<String, ContentFieldVersion>().keys)
      .union(incomingState?.fields.keys ?? Dictionary<String, ContentFieldVersion>().keys)
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
      // Absence of a field on a removed member is owned by its existence clock.
      // Surviving members retain their complete payload during a concurrent edit.
      if key.hasSuffix("/exists") {
        result[key] = resolved.value
      } else {
        result[key] = resolved.value ?? a[key] ?? b[key]
        if result[key] != resolved.value {
          metadata.fields[key] = resolved.version.retainingValue(resolved.value)
        }
      }
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
    for name in ["elements", "blocks"] where value[name] != nil {
      let key = fieldKey([name, "order"])
      let displayed = JSONValue.array(value[name]!.array.compactMap(\.memberIdentity).map(JSONValue.string))
      if displayed != result[key] { metadata.fields[key] = metadata.fields[key]?.retainingValue(result[key]) }
    }
    return (value, metadata)
  }
}

private func memberExistenceField(_ key: String) -> String? {
  let parts = key.split(separator: "/", omittingEmptySubsequences: false)
  guard parts.count == 3, (parts[0] == "elements" || parts[0] == "blocks"), parts[2] != "exists" else { return nil }
  return parts[0] + "/" + parts[1] + "/exists"
}

func mergedContentStamp(local: JSONValue, incoming: JSONValue, result: JSONValue,
  localStamp: VersionStamp, incomingStamp: VersionStamp) -> VersionStamp {
  let frontier = max(localStamp, incomingStamp)
  let owner = localStamp > incomingStamp ? local : incoming
  guard contentFields(owner) != contentFields(result) else { return frontier }
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

private func contentFields(_ value: JSONValue) -> [String: JSONValue] {
  var result: [String: JSONValue] = [:]
  for (name, property) in value.object where !["collaboration", "stamp", "agentStamp", "contentStamp", "drawingStamp", "drawingData", "format", "id", "size", "paperSize", "placements"].contains(name) {
    if ["elements", "blocks"].contains(name) {
      result[fieldKey([name, "order"])] = .array(property.array.compactMap(\.memberIdentity).map(JSONValue.string))
      for item in property.array {
        guard let id = item.memberIdentity else { continue }
        result[fieldKey([name, id, "exists"])] = .bool(true)
        var content: [String: JSONValue] = [:]
        for (field, val) in item.object {
          if ["source", "html", "kind"].contains(field) { content[field] = val }
          else { result[fieldKey([name, id, field])] = val }
        }
        if !content.isEmpty { result[fieldKey([name, id, "content"])] = .object(content) }
      }
    } else { result[fieldKey([name])] = property }
  }
  return result
}

private func rebuildContent(base: JSONValue, fields: [String: JSONValue]) -> JSONValue {
  var result = base
  for name in base.object.keys where !["collaboration", "stamp", "agentStamp", "contentStamp", "drawingStamp", "drawingData", "format", "id", "size", "paperSize", "placements"].contains(name) {
    if ["elements", "blocks"].contains(name) {
      let prefix = fieldKey([name]) + "/"
      let existing = fields.keys.filter { $0.hasPrefix(prefix) && $0.hasSuffix("/exists") && fields[$0] == .bool(true) }
      let ids = existing.map { String($0.dropFirst(prefix.count).dropLast("/exists".count)) }
      let preferred = fields[fieldKey([name, "order"])]?.array.compactMap(\.string) ?? []
      let order = contentMemberOrder(preferred: preferred, escapedMembers: ids)
      let old = base[name]?.array ?? []
      let items: [JSONValue] = order.map { id in
        let memberPrefix = fieldKey([name, id]) + "/"
        var object = old.first { $0.memberIdentity == id }?.object ?? [:]
        for (key, val) in fields where key.hasPrefix(memberPrefix) {
          let field = String(key.dropFirst(memberPrefix.count))
          if field == "content" { for (part, value) in val.object { object[part] = value } }
          else if field != "exists" { object[field] = val }
        }
        return .object(object)
      }
      result = result.setting(name, .array(items))
    } else if let value = fields[fieldKey([name])] { result = result.setting(name, value) }
  }
  return result
}

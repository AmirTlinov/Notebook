import Foundation

/// Causal field clocks let two devices retain independent edits. A concurrent
/// human edit owns its field over an agent suggestion based on the older value.
public struct ContentFieldVersion: Codable, Equatable, Sendable {
  public let stamp: VersionStamp
  public let human: Bool
  public let observed: [String: UInt64]

  init(stamp: VersionStamp, human: Bool, previous: ContentFieldVersion? = nil) {
    self.stamp = stamp
    self.human = human
    var observed = previous?.observed ?? [:]
    observed[stamp.actor.uuidString.lowercased()] = stamp.counter
    self.observed = observed
  }

  var isValid: Bool {
    stamp.counter <= VersionStamp.maximumCounter && observed.count <= 256
      && observed.allSatisfy { UUID(uuidString: $0.key) != nil && $0.value <= VersionStamp.maximumCounter }
  }

  func includes(_ other: Self) -> Bool {
    (observed[other.stamp.actor.uuidString.lowercased()] ?? 0) >= other.stamp.counter
  }

  func wins(over other: Self) -> Bool {
    let follows = includes(other), precedes = other.includes(self)
    if follows != precedes { return follows }
    if human != other.human { return human }
    return stamp > other.stamp
  }

  func joining(_ other: Self) -> Self {
    let winner = wins(over: other) ? self : other
    var observations = observed
    for (actor, counter) in other.observed { observations[actor] = max(observations[actor] ?? 0, counter) }
    return .init(stamp: winner.stamp, human: winner.human, observed: observations)
  }

  init(stamp: VersionStamp, human: Bool, observed: [String: UInt64]) {
    self.stamp = stamp; self.human = human; self.observed = observed
  }
}

public struct CollaborativeContent: Codable, Equatable, Sendable {
  public private(set) var fields: [String: ContentFieldVersion] = [:]

  public init() {}

  mutating func recordField(_ key: String, stamp: VersionStamp, human: Bool) {
    fields[key] = .init(stamp: stamp, human: human, previous: fields[key])
  }

  mutating func joinField(_ key: String, version: ContentFieldVersion) {
    fields[key] = fields[key].map { $0.joining(version) } ?? version
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
    isValid(maximumFields: 100_000)
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
      if a[key] != b[key] {
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
    incomingStamp: VersionStamp) -> (value: JSONValue, state: Self) {
    let a = contentFields(local), b = contentFields(incoming)
    var result: [String: JSONValue] = [:]
    var metadata = Self()
    let keys = Set(a.keys).union(b.keys).union(localState?.fields.keys ?? Dictionary<String, ContentFieldVersion>().keys)
      .union(incomingState?.fields.keys ?? Dictionary<String, ContentFieldVersion>().keys)
    for key in keys {
      let av = localState?.fields[key] ?? .init(
        stamp: a[key] == nil ? .init(counter: 0, actor: localStamp.actor) : localStamp, human: true)
      let bv = incomingState?.fields[key] ?? .init(
        stamp: b[key] == nil ? .init(counter: 0, actor: incomingStamp.actor) : incomingStamp, human: true)
      let useLocal = av.wins(over: bv)
      metadata.fields[key] = av.joining(bv)
      // Absence of a field on a removed member is owned by its existence clock.
      // Surviving members retain their complete payload during a concurrent edit.
      if key.hasSuffix("/exists") {
        result[key] = useLocal ? a[key] : b[key]
      } else {
        result[key] = (useLocal ? a[key] : b[key]) ?? (useLocal ? b[key] : a[key])
      }
    }
    let base = localStamp > incomingStamp ? local : incoming
    return (rebuildContent(base: base, fields: result), metadata)
  }
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

private func contentFields(_ value: JSONValue) -> [String: JSONValue] {
  var result: [String: JSONValue] = [:]
  for (name, property) in value.object where !["collaboration", "stamp", "agentStamp", "contentStamp", "drawingStamp", "drawingData", "format", "id", "size", "paperSize"].contains(name) {
    if ["elements", "blocks", "freeItems", "stacks"].contains(name) {
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
  for name in base.object.keys where !["collaboration", "stamp", "agentStamp", "contentStamp", "drawingStamp", "drawingData", "format", "id", "size", "paperSize"].contains(name) {
    if ["elements", "blocks", "freeItems", "stacks"].contains(name) {
      let prefix = fieldKey([name]) + "/"
      let existing = fields.keys.filter { $0.hasPrefix(prefix) && $0.hasSuffix("/exists") && fields[$0] == .bool(true) }
      let ids = existing.map { String($0.dropFirst(prefix.count).dropLast("/exists".count)) }
      let preferred = fields[fieldKey([name, "order"])]?.array.compactMap(\.string) ?? []
      let order = preferred.filter { ids.contains(fieldKey([$0])) }
        + ids.filter { !preferred.map({ fieldKey([$0]) }).contains($0) }.sorted().map {
          $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
        }
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

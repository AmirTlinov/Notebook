import Foundation
import NotebookCore

/// The desktop owns the full conversation. Its wire snapshot can include years of
/// tool output; decode only the native control state and an indexed display tail.
/// Omitted item slots retain their indices so later Immer patches keep their address.
struct CodexWireProjection: Decodable {
  static let tail = 128
  static let largeFrameKey = CodingUserInfoKey(rawValue: "notebookLargeDesktopFrame")!
  static let marker = "notebookDisplayProjection"
  let value: JSONValue
  struct Key: CodingKey {
    let stringValue: String
    var intValue: Int? { Int(stringValue) }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { self.init(String(intValue)) }
  }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Key.self)
    let method = try c.decodeIfPresent(String.self, forKey: Key("method"))
    if method != "thread-stream-state-changed" {
      guard decoder.userInfo[Self.largeFrameKey] as? Bool != true else { throw CodexBridgeError.invalidFrame }
      value = try JSONValue(from: decoder); return
    }
    var fields = try Self.object(decoder, keys: ["type", "method", "version", "sourceClientId"])
    let params = try c.superDecoder(forKey: Key("params"))
    let p = try params.container(keyedBy: Key.self)
    var body = try Self.object(params, keys: ["hostId", "conversationId"])
    let change = try p.superDecoder(forKey: Key("change"))
    let cc = try change.container(keyedBy: Key.self)
    var delta = try Self.object(change, keys: ["type", "revision", "baseRevision"])
    if delta["type"] == .string("snapshot") {
      delta["conversationState"] = try Self.state(cc.superDecoder(forKey: Key("conversationState")), path: [])
    } else if delta["type"] == .string("patches") {
      var patches = try cc.nestedUnkeyedContainer(forKey: Key("patches")), projected: [JSONValue] = []
      guard (patches.count ?? 4097) <= 4096 else { throw CodexBridgeError.historyLimit }
      while !patches.isAtEnd {
        let d = try patches.superDecoder(), patch = try d.container(keyedBy: Key.self)
        let path = try patch.decode([JSONValue].self, forKey: Key("path"))
        guard path.count <= 64 else { throw CodexBridgeError.invalidResponse }
        if !Self.retainedPath(path) { continue }
        var result = try Self.object(d, keys: ["op", "path"])
        if patch.contains(Key("value")) { result["value"] = try Self.state(patch.superDecoder(forKey: Key("value")), path: path) }
        projected.append(.object(result))
      }
      delta["patches"] = .array(projected)
    } else { throw CodexBridgeError.invalidResponse }
    body["change"] = .object(delta); fields["params"] = .object(body)
    fields[Self.marker] = .bool(true); value = .object(fields)
  }

  private static let stateKeys: Set<String> = ["id", "hostId", "title", "resumeState", "threadRuntimeStatus", "requests", "turns", "turnHistory"]
  private static let turnKeys: Set<String> = ["id", "turnId", "status", "items"]
  private static let itemKeys: Set<String> = ["id", "type", "clientId", "text", "phase", "content", "command", "status", "exitCode", "aggregatedOutput", "changes", "tool", "server", "namespace", "query", "path", "completed", "error", "message", "name"]

  static func retainedPath(_ path: [JSONValue]) -> Bool {
    guard let first = path.first?.string else { return path.isEmpty }
    guard stateKeys.contains(first) else { return false }
    if first == "turnHistory" {
      if path.count > 1, !["kind", "history"].contains(path[1].string ?? "") { return false }
      if path.count > 2, path[1] == .string("history"), !["entitiesByKey", "islands"].contains(path[2].string ?? "") { return false }
    }
    let suffix = turnSuffix(path)
    if let suffix, let field = suffix.first?.string {
      guard turnKeys.contains(field) else { return false }
      if field == "items", suffix.count > 2, let key = suffix[2].string { return itemKeys.contains(key) }
    }
    return true
  }
  private static func turnSuffix(_ path: [JSONValue]) -> [JSONValue]? {
    if path.first == .string("turns"), path.count >= 2 { return Array(path.dropFirst(2)) }
    if path.count >= 4, path[0] == .string("turnHistory"), path[1] == .string("history"), path[2] == .string("entitiesByKey") { return Array(path.dropFirst(4)) }
    return nil
  }

  static func state(_ decoder: Decoder, path: [JSONValue]) throws -> JSONValue {
    if try decoder.singleValueContainer().decodeNil() { return .null }
    if path.first == .string("requests") {
      let value = try JSONValue(from: decoder)
      guard try JSONEncoder().encode(value).count <= 65_536 else { throw CodexBridgeError.historyLimit }
      return value
    }
    if path.isEmpty { return try selected(decoder, keys: stateKeys, path: path) }
    if let suffix = turnSuffix(path) {
      if suffix.isEmpty { return try selected(decoder, keys: turnKeys, path: path) }
      if suffix.first == .string("items") {
        if suffix.count == 1 {
          var c = try decoder.unkeyedContainer(); guard let count = c.count, count <= 100_000 else { throw CodexBridgeError.historyLimit }
          var values: [JSONValue] = []; values.reserveCapacity(count)
          while !c.isAtEnd {
            let index = c.currentIndex, d = try c.superDecoder()
            values.append(try item(d, retainingContent: index >= max(0, count - tail)))
          }
          return .array(values)
        }
        if suffix.count == 2 { return try item(decoder) }
      }
      return try bounded(decoder)
    }
    if path == [.string("turns")] {
      var c = try decoder.unkeyedContainer(); guard (c.count ?? 4097) <= 4096 else { throw CodexBridgeError.historyLimit }
      var values: [JSONValue] = []
      while !c.isAtEnd { let index = c.currentIndex; values.append(try state(c.superDecoder(), path: path + [.number(Double(index))])) }
      return .array(values)
    }
    if path == [.string("turnHistory")] { return try selected(decoder, keys: ["kind", "history"], path: path) }
    if path == [.string("turnHistory"), .string("history")] { return try selected(decoder, keys: ["entitiesByKey", "islands"], path: path) }
    if path == [.string("turnHistory"), .string("history"), .string("entitiesByKey")] {
      let c = try decoder.container(keyedBy: Key.self); guard c.allKeys.count <= 4096 else { throw CodexBridgeError.historyLimit }
      return try selected(decoder, keys: Set(c.allKeys.map(\.stringValue)), path: path)
    }
    return try bounded(decoder)
  }

  private static func selected(_ decoder: Decoder, keys: Set<String>, path: [JSONValue]) throws -> JSONValue {
    let c = try decoder.container(keyedBy: Key.self)
    var values: [String: JSONValue] = [:]
    for key in c.allKeys where keys.contains(key.stringValue) {
      values[key.stringValue] = try state(c.superDecoder(forKey: key), path: path + [.string(key.stringValue)])
    }
    return .object(values)
  }
  private static func item(_ decoder: Decoder, retainingContent: Bool = true) throws -> JSONValue {
    let c = try decoder.container(keyedBy: Key.self)
    let type = try c.decode(String.self, forKey: Key("type"))
    if !retainingContent && type != "userMessage" { return .null }
    var keys = retainingContent ? itemKeys : ["id", "type", "clientId"]
    // Private reasoning and hidden input context are not display content.
    if type == "reasoning" { keys = ["id", "type"] }
    var values: [String: JSONValue] = [:]
    for key in c.allKeys where keys.contains(key.stringValue) {
      values[key.stringValue] = try bounded(c.superDecoder(forKey: key))
    }
    return .object(values)
  }
  private static func object(_ decoder: Decoder, keys: Set<String>) throws -> [String: JSONValue] {
    let c = try decoder.container(keyedBy: Key.self)
    var result: [String: JSONValue] = [:]
    for key in c.allKeys where keys.contains(key.stringValue) { result[key.stringValue] = try c.decode(JSONValue.self, forKey: key) }
    return result
  }
  private static func bounded(_ decoder: Decoder) throws -> JSONValue {
    let value = try JSONValue(from: decoder)
    return trim(value)
  }
  private static func trim(_ value: JSONValue) -> JSONValue {
    switch value {
    case .string(let text): return .string(String(text.prefix(16_385)))
    case .array(let values): return .array(values.map(trim))
    case .object(let fields): return .object(fields.mapValues(trim))
    default: return value
    }
  }

  /// Each array edit moves the tail boundary by at most one; full replacements
  /// already arrive projected. Release the departed slot without scanning content.
  static func pruneAfterPatch(_ value: JSONValue) -> JSONValue {
    func turn(_ value: JSONValue) -> JSONValue {
      guard case .object(var fields) = value, case .array(var items) = fields["items"],
        items.count > tail, items[items.count - tail - 1] != .null else { return value }
      items[items.count - tail - 1] = identity(items[items.count - tail - 1]); fields["items"] = .array(items); return .object(fields)
    }
    guard case .object(var state) = value else { return value }
    if case .array(let turns) = state["turns"] { state["turns"] = .array(turns.map(turn)) }
    if case .object(var history) = state["turnHistory"], case .object(var body) = history["history"],
      case .object(let entities) = body["entitiesByKey"] {
      body["entitiesByKey"] = .object(entities.mapValues(turn)); history["history"] = .object(body); state["turnHistory"] = .object(history)
    }
    return .object(state)
  }

  /// Whole-item edits must preserve array indexing without restoring discarded
  /// history. An insertion shifts the boundary; removals still reach the owner.
  static func replacement(_ value: JSONValue?, operation: String, path: [JSONValue], in state: JSONValue) -> JSONValue? {
    guard operation != "remove", let i = path.firstIndex(of: .string("items")), path.count == i + 2,
      let index = path[i + 1].integer, let items = itemArray(path, in: state) else { return value }
    let count = items.count + (operation == "add" ? 1 : 0)
    return index < max(0, count - tail) ? value.map(identity) : value
  }

  /// Accepted user IDs are control state, not disposable display history.
  private static func identity(_ value: JSONValue) -> JSONValue {
    guard value["type"] == .string("userMessage"), let fields = value.object else { return .null }
    return .object(fields.filter { ["id", "type", "clientId"].contains($0.key) })
  }

  private static func itemArray(_ path: [JSONValue], in state: JSONValue) -> [JSONValue]? {
    guard let i = path.firstIndex(of: .string("items")) else { return nil }
    var owner = state
    for component in path.prefix(i) {
      if let key = component.string, let next = owner[key] { owner = next }
      else if let index = component.integer, let array = owner.array, index < array.count { owner = array[index] }
      else { return nil }
    }
    return owner["items"]?.array
  }

  /// A patch into an intentionally omitted historical item does not rehydrate it.
  static func omits(_ path: [JSONValue], in state: JSONValue) -> Bool {
    guard let i = path.firstIndex(of: .string("items")), i + 1 < path.count, let index = path[i + 1].integer else { return false }
    guard let items = itemArray(path, in: state) else { return false }
    if path.count > i + 2, index < max(0, items.count - tail) {
      return !(path.count == i + 3 && index < items.count && items[index]["type"] == .string("userMessage")
        && ["id", "type", "clientId"].contains(path[i + 2].string ?? ""))
    }
    if index < items.count, items[index]["type"] == .string("reasoning"), path.count > i + 2 { return true }
    return false
  }
}

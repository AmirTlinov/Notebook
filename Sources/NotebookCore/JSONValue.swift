import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public subscript(_ key: String) -> JSONValue? {
    guard case .object(let values) = self else { return nil }
    return values[key]
  }

  public var objectFields: [String: JSONValue] { if case .object(let value) = self { value } else { [:] } }
  public var arrayValues: [JSONValue] { if case .array(let value) = self { value } else { [] } }
  public var stringValue: String? { if case .string(let value) = self { value } else { nil } }
  /// Retained semantic allocation, including collection capacity. Counting a
  /// value does not encode another tree; small wire tokens can own large arrays.
  public var retainedPayloadBytes:Int { MemoryLayout<Self>.stride + retainedBufferBytes }
  private var retainedBufferBytes:Int {
    switch self {
    case .null,.bool,.number:return 0
    case .string(let value):return value.utf8.count * 2
    case .array(let values):
      return values.capacity * MemoryLayout<Self>.stride + values.reduce(0) { $0 + $1.retainedBufferBytes }
    case .object(let values):
      return values.capacity * (MemoryLayout<String>.stride + MemoryLayout<Self>.stride + 32)
        + values.reduce(0) { $0 + $1.key.utf8.count * 2 + $1.value.retainedBufferBytes }
    }
  }
  var object: [String: JSONValue] { objectFields }
  var array: [JSONValue] { arrayValues }
  var string: String? { stringValue }
  public func setting(_ key: String, _ value: JSONValue?) -> JSONValue {
    var result = object
    result[key] = value
    return .object(result)
  }

  public static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
  }

  /// Reconstitutes the typed owner and runs that owner's decoding checks.
  public func decode<T: Decodable>(_ type: T.Type) throws -> T {
    try decode(type,sharing:.init())
  }
  func decode<T: Decodable>(_ type: T.Type, sharing: InkRelationDecoding) throws -> T {
    try InkRelationDecoding.decoder(sharing:sharing).decode(type, from: JSONEncoder().encode(self))
  }

  public var isValid: Bool {
    switch self {
    case .null, .bool, .string:
      true
    case .number(let value):
      value.isFinite
    case .array(let values):
      values.allSatisfy(\.isValid)
    case .object(let values):
      values.values.allSatisfy(\.isValid)
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    // Ink samples are predominantly numbers. JSONDecoder distinguishes JSON
    // numbers from booleans; do not construct a type-mismatch error per sample
    // coordinate before taking the numeric path.
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null:
      try container.encodeNil()
    case .bool(let value):
      try container.encode(value)
    case .number(let value):
      try container.encode(value)
    case .string(let value):
      try container.encode(value)
    case .array(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    }
  }
}

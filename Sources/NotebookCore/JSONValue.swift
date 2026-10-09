import Foundation

#if DEBUG
/// Counts actual codec work on the synchronous source writer. Observing bytes
/// borrows the buffer already required by the codec; it never encodes a sample.
enum NotebookDocumentCodecObservation {
  enum Phase: String, Sendable { case documentDecode, documentEncode, filesEncode }
  struct Sample: Sendable {
    let phase: Phase
    let encodedBytes: Int
  }
  private final class Box {
    let observer: @Sendable (Sample) -> Void
    init(_ observer: @escaping @Sendable (Sample) -> Void) { self.observer = observer }
  }
  private static let key = "notebook.document-codec.debug-observer"
  static func withObserver<T>(_ observer: @escaping @Sendable (Sample) -> Void,
    operation: () throws -> T) rethrows -> T {
    let thread = Thread.current, previous = thread.threadDictionary[key]
    thread.threadDictionary[key] = Box(observer)
    defer {
      if let previous { thread.threadDictionary[key] = previous }
      else { thread.threadDictionary.removeObject(forKey: key) }
    }
    return try operation()
  }
  static var observer: (@Sendable (Sample) -> Void)? {
    (Thread.current.threadDictionary[key] as? Box)?.observer
  }
}
#endif

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
    let data = try JSONEncoder().encode(value)
    #if DEBUG
    if T.self == DocumentDocument.self || T.self == [DocumentFile].self,
      let observer = NotebookDocumentCodecObservation.observer {
      let phase: NotebookDocumentCodecObservation.Phase = T.self == DocumentDocument.self ? .documentEncode : .filesEncode
      observer(.init(phase: phase, encodedBytes: data.count))
    }
    #endif
    return try JSONDecoder().decode(JSONValue.self, from: data)
  }

  /// Reconstitutes the typed owner and runs that owner's decoding checks.
  public func decode<T: Decodable>(_ type: T.Type) throws -> T {
    try decode(type,sharing:.init())
  }
  func decode<T: Decodable>(_ type: T.Type, sharing: InkRelationDecoding) throws -> T {
    let data = try JSONEncoder().encode(self)
    #if DEBUG
    if type == DocumentDocument.self, let observer = NotebookDocumentCodecObservation.observer {
      observer(.init(phase: .documentDecode, encodedBytes: data.count))
    }
    #endif
    return try InkRelationDecoding.decoder(sharing:sharing).decode(type, from: data)
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
    #if canImport(ObjectiveC)
    // Foundation's failed scalar/container probes can retain autoreleased
    // errors until the surrounding app event ends. A decoded member owns its
    // Swift value; temporary probes need not survive the rest of a large tree.
    self = try autoreleasepool { try Self.decodedValue(from: decoder) }
    #else
    self = try Self.decodedValue(from: decoder)
    #endif
  }

  private static func decodedValue(from decoder: Decoder) throws -> Self {
    let container = try decoder.singleValueContainer()
    // Ink samples are predominantly numbers. JSONDecoder distinguishes JSON
    // numbers from booleans; do not construct a type-mismatch error per sample
    // coordinate before taking the numeric path.
    if container.decodeNil() {
      return .null
    } else if let value = try? container.decode(Double.self) {
      return .number(value)
    } else if let value = try? container.decode(Bool.self) {
      return .bool(value)
    } else if let value = try? container.decode(String.self) {
      return .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      return .array(value)
    } else {
      return .object(try container.decode([String: JSONValue].self))
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

import Foundation

/// The native queue retains at most 32 MiB while one accepted command uses
/// this finish credit. A prepared owner may tighten it, never enlarge it.
public struct NotebookNativeWriteAllowance: Sendable {
  public static let maximumSourceBytes = 32 * 1_024 * 1_024
  public static let maximumExecutionBytes = 160 * 1_024 * 1_024
  public let executionBytes: Int

  public init(executionBytes: Int = maximumExecutionBytes) {
    self.executionBytes = executionBytes
  }

  func readAllowance() throws -> NotebookSQLReadAllowance {
    guard executionBytes > 0, executionBytes <= Self.maximumExecutionBytes else {
      throw Self.refusal()
    }
    // Returned SQL buffers and rows have separate credit from decoded trees.
    // The remaining tenth pays the 4 MiB ink cache, TEMP cache and SQL/codec
    // bookkeeping at the maximum. All three shares shrink with the command.
    let source = executionBytes / 10, allocations = executionBytes / 5 * 4
    return .init(rows: min(65_536, source / 64), bytes: source,
      valueBytes: min(8 * 1_024 * 1_024, source), reason: "resource_limit",
      jsonDecodeBytes: allocations)
  }

  static func refusal() -> CollaborationError {
    .init("resource_limit", "Изменение превышает допустимую память. Уменьшите объём действия.")
  }
}

extension NotebookStore {
  /// The transaction owns the allowance. Nested readers and writers borrow
  /// its remaining credit and its refusal latch; no phase renews a budget.
  public func withNativeWriteAllowance<T>(_ allowance: NotebookNativeWriteAllowance = .init(),
    _ body: () throws -> T) throws -> T {
    do { return try commandTransaction(readAllowance: allowance.readAllowance(), body) }
    catch NotebookStorageError.limitExceeded { throw NotebookNativeWriteAllowance.refusal() }
  }
}

extension NotebookSQLConnection {
  /// Charge a retained value before typed decoding, projection copies or a
  /// codec roundtrip. Walking keys/scalars creates no second JSON tree.
  func admitNativeJSONPhase(_ value: JSONValue, copies: Int = 1) throws {
    try admitNativeAllocation(copies: copies) { try $0.value(value) }
  }

  func admitNativeFragmentCodec(_ rows: [NotebookStoredFragment], copies: Int = 1) throws {
    try admitNativeAllocation(copies: copies) { meter in
      try meter.count(rows.capacity, stride: MemoryLayout<NotebookStoredFragment>.stride)
      for row in rows {
        try meter.string(row.address); try meter.string(row.file)
        try meter.string(row.parent ?? ""); try meter.string(row.collection); try meter.string(row.member)
        try meter.value(row.value)
        for collection in row.collections { for key in collection.path { try meter.string(key) } }
        for path in row.inkBodies { for key in path { try meter.string(key) } }
      }
    }
  }

  private func admitNativeAllocation(copies: Int, _ measure: (inout NativeJSONPhase) throws -> Void) throws {
    guard copies > 0, copies <= 16 else { throw NotebookStorageError.limitExceeded("resource_limit") }
    var meter = NativeJSONPhase(limit: NotebookNativeWriteAllowance.maximumExecutionBytes / copies,
      observesCancellation: !writable)
    do { try measure(&meter) }
    catch NotebookStorageError.limitExceeded {
      // Latch even a refusal caught by a caller in this transaction.
      try admitJSONAllocation(bytes: NotebookNativeWriteAllowance.maximumExecutionBytes + 1)
      throw NotebookStorageError.limitExceeded("resource_limit")
    }
    try admitJSONAllocation(bytes: meter.bytes * copies)
  }
}

private struct NativeJSONPhase {
  let limit: Int
  let observesCancellation: Bool
  var bytes = 0
  private var visited = 0

  mutating func add(_ count: Int) throws {
    guard count >= 0, count <= limit - bytes else { throw NotebookStorageError.limitExceeded("resource_limit") }
    bytes += count
  }

  mutating func count(_ count: Int, stride: Int) throws {
    guard count >= 0, count <= (limit - bytes) / stride else { throw NotebookStorageError.limitExceeded("resource_limit") }
    try add(count * stride)
  }

  mutating func string(_ value: String) throws {
    try add(512 + 16)
    // Borrow existing UTF-8. A bridged string is counted without allocating
    // a full buffer before its admission.
    if value.isContiguousUTF8 {
      let borrowed = try value.utf8.withContiguousStorageIfAvailable { utf8 -> Bool in
        var index = 0
        while index < utf8.count {
          if observesCancellation, index & 4095 == 0 { try Task.checkCancellation() }
          let byte = utf8[index]
          // JSON's worst escaping, transient wire buffers and String capacity.
          try add(byte < 0x20 ? 48 : byte == 34 || byte == 92 || byte == 47 ? 16 : 8)
          index += 1
        }
        return true
      }
      if borrowed == true { return }
    }
    var index = 0
    for byte in value.utf8 {
      if observesCancellation, index & 4095 == 0 { try Task.checkCancellation() }
      try add(byte < 0x20 ? 48 : byte == 34 || byte == 92 || byte == 47 ? 16 : 8)
      index += 1
    }
  }

  mutating func value(_ value: JSONValue, depth: Int = 0) throws {
    guard depth <= NotebookJSONAdmission.maximumDepth else { throw NotebookStorageError.limitExceeded("json_decode_depth") }
    visited += 1
    if observesCancellation, visited & 255 == 0 { try Task.checkCancellation() }
    try add(512 + 192)
    switch value {
    case .null, .bool, .number: break
    case .string(let value): try string(value)
    case .array(let values):
      try count(values.capacity, stride: MemoryLayout<JSONValue>.stride)
      for value in values { try self.value(value, depth: depth + 1) }
    case .object(let values):
      try count(values.capacity, stride: MemoryLayout<String>.stride + MemoryLayout<JSONValue>.stride + 32)
      for (key, value) in values { try string(key); try self.value(value, depth: depth + 1) }
    }
  }
}

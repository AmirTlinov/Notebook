import Foundation
import NotebookCore

/// Only the addressed value, clock and source identity enter the FIFO. A
/// loaded journal may copy its record headers for display after this admission.
enum NotebookDocumentStateWriteAdmission {
  struct Source: Sendable {
    let value: JSONValue
    let previous: DocumentStateRecord?
    let journalCapacity: Int?
    let programID: String
    let path: String
    let basis: String

    func inlineCost() throws -> NotebookPersistenceAdmission.Cost? {
      try NotebookDocumentStateWriteAdmission.inlineCost(value: value, previous: previous, journalCapacity: journalCapacity,
        programID: programID, path: path, sourceBasis: basis)
    }
    func measuredCost() throws -> NotebookPersistenceAdmission.Cost {
      try NotebookDocumentStateWriteAdmission.cost(value: value, previous: previous, journalCapacity: journalCapacity,
        programID: programID, path: path, sourceBasis: basis)
    }
  }

  static let preparationMaximum = NotebookPersistenceAdmission.Cost(
    payloadBytes: 32 * 1_024 * 1_024, completionBytes: NotebookDocumentStateWriteAllowance.maximumExecutionBytes)

  /// A bounded header walk keeps ordinary counters synchronous. Larger bodies
  /// are measured by the already reserved preparation worker before retention.
  static func inlineCost(value: JSONValue, previous: DocumentStateRecord?, journalCapacity: Int?,
    programID: String, path: String, sourceBasis: String) throws -> NotebookPersistenceAdmission.Cost? {
    if let version = previous?.valueVersion,
      version.hasRetainedAlternatives || version.observed.count > 16 { return nil }
    var remaining = 64
    func small(_ value: JSONValue) -> Bool {
      remaining -= 1
      guard remaining >= 0 else { return false }
      switch value {
      case .string(let value): return value.utf8.count <= 4_096
      case .array(let values): return values.count <= remaining && values.allSatisfy(small)
      case .object(let values): return values.count <= remaining
        && values.allSatisfy { $0.key.utf8.count <= 256 && small($0.value) }
      default: return true
      }
    }
    guard small(value), previous.map({ small($0.value) }) ?? true else { return nil }
    return try cost(value: value, previous: previous, journalCapacity: journalCapacity,
      programID: programID, path: path, sourceBasis: sourceBasis)
  }

  static func cost(value: JSONValue, previous: DocumentStateRecord?, journalCapacity: Int?,
    programID: String, path: String, sourceBasis: String) throws -> NotebookPersistenceAdmission.Cost {
    let maximum = NotebookDocumentStateWriteAllowance.maximumExecutionBytes
    let resident = value.retainedPayloadBytes
    let clock = previous?.valueVersion.retainedPayloadBytes ?? 0
    let scalars = programID.utf8.count + path.utf8.count + sourceBasis.utf8.count
    guard resident <= 32 * 1_024 * 1_024, clock <= maximum / 8, scalars <= maximum / 16,
      (journalCapacity ?? 0) >= 0, (journalCapacity ?? 0) <= maximum / MemoryLayout<DocumentStateRecord>.stride / 2 else { throw refusal() }
    let metadata = 16 * 1_024 + clock * 8 + scalars * 16
    let payload = resident + metadata
    let incoming = try decodeCost(value)
    let stored = try previous.map { try decodeCost($0.value) } ?? 0
    let display = (journalCapacity ?? 0) * MemoryLayout<DocumentStateRecord>.stride * 2
    // An evicted source has no observed stored value to size. Its exact FIFO
    // cut retains the bounded maximum; a loaded source uses its actual extent.
    let finish = journalCapacity == nil ? maximum : max(1_024 * 1_024, max(incoming, stored) * 2 + metadata, display)
    guard finish <= maximum, payload <= preparationMaximum.bytes - finish else { throw refusal() }
    return .init(payloadBytes: payload, completionBytes: finish)
  }

  private static func decodeCost(_ value: JSONValue) throws -> Int {
    let limit = NotebookDocumentStateWriteAllowance.maximumExecutionBytes / 2
    var cost = 0
    func add(_ bytes: Int) throws {
      guard bytes >= 0, bytes <= limit - cost else { throw refusal() }
      cost += bytes
    }
    func string(_ value: String) throws {
      let bytes = value.utf8
      guard bytes.count <= (limit - cost - 16) / 8 else { throw refusal() }
      // The admitted string already owns its backing. Count escaping in its
      // UTF-8 buffer, then check the aggregate once, without per-byte throws.
      let extra = bytes.withContiguousStorageIfAvailable { buffer in
        var count = 0, offset = 0
        let zero = SIMD32<UInt8>(repeating: 0)
        while offset + 32 <= buffer.count {
          let values = UnsafeRawPointer(buffer.baseAddress!).loadUnaligned(fromByteOffset: offset, as: SIMD32<UInt8>.self)
          let escaped = (values .== SIMD32(repeating: 34)) .| (values .== SIMD32(repeating: 92)) .| (values .== SIMD32(repeating: 47))
          let weights = zero.replacing(with: SIMD32(repeating: 5), where: values .< SIMD32(repeating: 32))
            .replacing(with: SIMD32(repeating: 1), where: escaped)
          count += Int(weights.wrappedSum())
          offset += 32
        }
        for byte in buffer[offset...] { count += byte < 32 ? 5 : byte == 34 || byte == 92 || byte == 47 ? 1 : 0 }
        return count
      } ?? bytes.reduce(0) { $0 + ($1 < 32 ? 5 : $1 == 34 || $1 == 92 || $1 == 47 ? 1 : 0) }
      try add(16 + (bytes.count + extra) * 8)
    }
    func visit(_ value: JSONValue, depth: Int = 0) throws {
      guard depth < 128 else { throw refusal() }
      try add(512 + 256)
      switch value {
      case .null, .bool, .number: break
      case .string(let value): try string(value)
      case .array(let values):
        try add(values.count * 8)
        for value in values { try visit(value, depth: depth + 1) }
      case .object(let values):
        try add(values.count * 16)
        for (key, value) in values { try string(key); try visit(value, depth: depth + 1) }
      }
    }
    try visit(value)
    return cost
  }

  static func refusal() -> CollaborationError {
    .init("resource_limit", "Сохранение состояния заполнено. Повторите после предыдущих записей.")
  }
}

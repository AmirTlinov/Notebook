import Foundation

/// Explicit observational export, not a storage or renderer representation.
/// The directory stays metadata-only. A request for measured points has a
/// separate expansion bound even when a million-event source occupies 4 KiB.
private struct InkReadBudget {
  var remaining = 32_768
  let database: NotebookSQLConnection?

  init(borrowing database: NotebookSQLConnection?) {
    // Native publication retains its accepted input and its writer allowance.
    // Only observational output borrows the foreign reader's allocation lease.
    self.database = database?.writable == false ? database : nil
  }

  func admit(bytes: Int) throws { try database?.admitJSONAllocation(bytes: bytes) }

  mutating func fields(_ measurements: InkMeasurements) throws -> (samples: JSONValue, relations: JSONValue) {
    guard measurements.count <= remaining else { throw NotebookStorageError.limitExceeded("ink_measurement_read") }
    remaining -= measurements.count
    // A compact repeated body may describe thousands of samples. Charge the
    // flat array, the JSON encoder/decoder maps and retained response before
    // materializing it. A paper sample has a point and six scalar fields; a
    // world sample also has the four tiled-coordinate fields. These bounds
    // include the later snapshot encoding, not just the short relation bytes.
    try admit(bytes: 4_096 + measurements.count * (16 * 1_024 + MemoryLayout<SpatialInkSample>.stride)
      + measurements.storage.root.worldEvents * 8 * 1_024)
    return try (.encode(measurements.materialized()), .encode(measurements))
  }
}

extension NotebookPageInkActionRead {
  func measuredReadProjection(in database: NotebookSQLConnection) throws -> JSONValue {
    var budget=InkReadBudget(borrowing: database)
    try budget.admit(bytes: 8_192)
    let fields=try budget.fields(action.samples)
    let value=try JSONValue.encode(action).setting("samples",fields.samples).setting("relations",fields.relations)
    return try .object(["header":.encode(header),"action":value])
  }
}

extension SpatialInkJournal {
  func measuredReadProjection(in database: NotebookSQLConnection) throws -> JSONValue {
    var budget=InkReadBudget(borrowing: database)
    try budget.admit(bytes: 8_192 + actions.count * 8_192)
    let actions=try actions.map { action -> JSONValue in
      try budget.admit(bytes: action.spans.count * 8_192)
      let spans=try action.spans.map { span -> JSONValue in
        let fields=try budget.fields(span.samples)
        return try JSONValue.encode(span).setting("samples",fields.samples).setting("relations",fields.relations)
      }
      return try JSONValue.encode(action).setting("spans",.array(spans))
    }
    return try JSONValue.encode(self).setting("actions",.array(actions))
  }
}

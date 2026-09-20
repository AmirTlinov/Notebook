import Foundation

/// Explicit observational export, not a storage or renderer representation.
/// The directory stays metadata-only. A request for measured points has a
/// separate expansion bound even when a million-event source occupies 4 KiB.
private struct InkReadBudget {
  var remaining = 32_768
  mutating func fields(_ measurements: InkMeasurements) throws -> (samples: JSONValue, relations: JSONValue) {
    guard measurements.count <= remaining else { throw NotebookStorageError.limitExceeded("ink_measurement_read") }
    remaining -= measurements.count
    return try (.encode(measurements.materialized()), .encode(measurements))
  }
}

extension NotebookPageInkActionRead {
  func measuredReadProjection() throws -> JSONValue {
    var budget=InkReadBudget()
    let fields=try budget.fields(action.samples)
    let value=try JSONValue.encode(action).setting("samples",fields.samples).setting("relations",fields.relations)
    return try .object(["header":.encode(header),"action":value])
  }
}

extension SpatialInkJournal {
  func measuredReadProjection() throws -> JSONValue {
    var budget=InkReadBudget()
    let actions=try actions.map { action -> JSONValue in
      let spans=try action.spans.map { span -> JSONValue in
        let fields=try budget.fields(span.samples)
        return try JSONValue.encode(span).setting("samples",fields.samples).setting("relations",fields.relations)
      }
      return try JSONValue.encode(action).setting("spans",.array(spans))
    }
    return try JSONValue.encode(self).setting("actions",.array(actions))
  }
}

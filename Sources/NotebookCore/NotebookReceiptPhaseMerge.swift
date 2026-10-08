import Foundation

/// A saved original may acquire one Undo phase. Conflicting originals or Undo
/// cuts require reconciliation; receipt delivery cannot choose between them.
enum NotebookReceiptPhaseMerge {
  private enum Selection: Equatable { case previous, incoming }

  static func merging(_ incoming: CollaborationReceipt, into previous: CollaborationReceipt?) throws -> CollaborationReceipt {
    guard incoming.id == incoming.action.id else { throw conflict() }
    guard let previous else { return incoming }
    let selected = try selection(previous, incoming)
    let samePhase = (previous.undo == nil) == (incoming.undo == nil)
    let oldHash = try samePhase ? collaborationHash(previous) : collaborationHash(OriginalReceipt(previous))
    let nextHash = try samePhase ? collaborationHash(incoming) : collaborationHash(OriginalReceipt(incoming))
    guard oldHash == nextHash else { throw conflict() }
    return selected == .previous ? previous : incoming
  }

  /// The envelope already owns a typed incoming receipt; do not decode it again.
  static func merging(_ incoming: CollaborationReceipt, into previous: JSONValue?,
    database: NotebookSQLConnection) throws -> JSONValue {
    guard incoming.id == incoming.action.id else { throw conflict() }
    guard let previous else {
      try admitEncoding(incoming, database: database)
      return try .encode(incoming)
    }
    try database.admitNativeJSONPhase(previous)
    let saved = try previous.decode(CollaborationReceipt.self)
    let selected = try selection(saved, incoming)
    let samePhase = (saved.undo == nil) == (incoming.undo == nil)
    try database.admitNativeJSONPhase(previous)
    let oldHash = try samePhase ? collaborationHash(previous) : collaborationHash(OriginalJSON(previous))
    try admitEncoding(incoming, database: database)
    let nextHash = try samePhase ? collaborationHash(incoming) : collaborationHash(OriginalReceipt(incoming))
    guard oldHash == nextHash else { throw conflict() }
    if selected == .previous { return previous }
    try admitEncoding(incoming, database: database)
    return try .encode(incoming)
  }

  static func merging(_ incoming: JSONValue, into previous: JSONValue?,
    database: NotebookSQLConnection) throws -> JSONValue {
    try database.admitNativeJSONPhase(incoming)
    return try merging(incoming, receipt: incoming.decode(CollaborationReceipt.self), into: previous, database: database)
  }

  private static func selection(_ previous: CollaborationReceipt, _ incoming: CollaborationReceipt) throws -> Selection {
    guard previous.id == previous.action.id, incoming.id == incoming.action.id,
      previous.id == incoming.id, previous.action == incoming.action,
      previous.createdAt == incoming.createdAt, previous.changes == incoming.changes,
      previous.requestFingerprint == incoming.requestFingerprint, previous.author == incoming.author,
      previous.redoOf == incoming.redoOf, previous.lifecycleInverse == incoming.lifecycleInverse,
      previous.lifecycleChanges == incoming.lifecycleChanges else { throw conflict() }
    if let oldUndo = previous.undo, let nextUndo = incoming.undo {
      guard oldUndo == nextUndo, previous.revisions == incoming.revisions else { throw conflict() }
      return .previous
    }
    if previous.undo != nil { return .previous }
    if incoming.undo != nil { return .incoming }
    guard previous.revisions == incoming.revisions else { throw conflict() }
    return .previous
  }

  private static func merging(_ incoming: JSONValue, receipt: CollaborationReceipt,
    into previous: JSONValue?, database: NotebookSQLConnection) throws -> JSONValue {
    guard receipt.id == receipt.action.id else { throw conflict() }
    guard let previous else { return incoming }
    try database.admitNativeJSONPhase(previous)
    let saved = try previous.decode(CollaborationReceipt.self)
    let selected = try selection(saved, receipt)
    // Canonical encoding distinguishes signed zero and includes unknown JSON.
    // Charge the existing cut before allocating either encoding buffer.
    try database.admitNativeJSONPhase(previous)
    let samePhase = (saved.undo == nil) == (receipt.undo == nil)
    let oldHash = try samePhase ? collaborationHash(previous) : collaborationHash(OriginalJSON(previous))
    try database.admitNativeJSONPhase(incoming)
    let nextHash = try samePhase ? collaborationHash(incoming) : collaborationHash(OriginalJSON(incoming))
    guard oldHash == nextHash else { throw conflict() }
    return selected == .previous ? previous : incoming
  }

  /// Views share the retained original; neither constructs a filtered JSON tree.
  private struct OriginalJSON: Encodable {
    let value: JSONValue
    init(_ value: JSONValue) { self.value = value }
    private struct Key: CodingKey {
      let stringValue: String
      var intValue: Int? { nil }
      init(_ value: String) { stringValue = value }
      init?(stringValue: String) { self.init(stringValue) }
      init?(intValue: Int) { return nil }
    }
    func encode(to encoder: Encoder) throws {
      guard case .object(let fields) = value else { throw NotebookReceiptPhaseMerge.conflict() }
      var container = encoder.container(keyedBy: Key.self)
      for (key, value) in fields where key != "undo" && key != "revisions" {
        try container.encode(value, forKey: Key(key))
      }
    }
  }

  private struct OriginalReceipt: Encodable {
    let id: UUID
    let action: CollaborationAction
    let createdAt: Date
    let changes: [CollaborationFieldChange]
    let requestFingerprint: String?
    let author: SharedContextEntry.Author?
    let lifecycleInverse: NotebookLifecycleInverseReference?
    let lifecycleChanges: [NotebookLifecycleChange]?
    let redoOf: UUID?
    init(_ receipt: CollaborationReceipt) {
      id = receipt.id; action = receipt.action; createdAt = receipt.createdAt; changes = receipt.changes
      requestFingerprint = receipt.requestFingerprint; author = receipt.author
      lifecycleInverse = receipt.lifecycleInverse; lifecycleChanges = receipt.lifecycleChanges; redoOf = receipt.redoOf
    }
  }

  /// Existing integer-only clock/JSON accounting pays typed framing before
  /// encoding. Values and causal heads are visited without a measuring copy.
  private static func admitEncoding(_ receipt: CollaborationReceipt, database: NotebookSQLConnection) throws {
    typealias Cost = ContentFieldVersion.WriteFootprint
    do {
      var cost = Cost.object
      func frame() throws {
        if !database.writable { try Task.checkCancellation() }
        try cost.element(.init(wireBytes: 1_024, tokens: 64))
      }
      func string(_ value: String?) throws {
        if !database.writable { try Task.checkCancellation() }
        if let value { try cost.element(.string(value)) }
      }
      func path(_ value: [CollaborationPathComponent]) throws {
        try cost.element(.array)
        for member in value {
          try cost.element(.init(wireBytes: 64, tokens: 8))
          switch member { case .field(let key), .member(let key): try string(key); case .order: break }
        }
      }
      func expectation(_ value: CollaborationExpectation) throws {
        try frame(); try string(value.revision); try string(value.stateRevision); try string(value.sourceRevision)
        try string(value.inkRevision); try string(value.lifecycleRevision)
      }
      func change(_ value: CollaborationFieldChange) throws {
        try frame(); try string(value.file); try path(value.path)
        if let body = value.before { try cost.element(.json(body, depth: 3)) }
        if let body = value.after { try cost.element(.json(body, depth: 3)) }
        if let version = value.beforeVersion { try cost.element(version.writeFootprint()) }
        if let version = value.afterVersion { try cost.element(version.writeFootprint()) }
      }
      func inverse(_ value: NotebookLifecycleInverseReference?) throws {
        if let value { try frame(); try string(value.rootHash) }
      }
      func item(_ value: NotebookItemHeader?) throws {
        if let value { try frame(); try string(value.title) }
      }
      try frame(); try string(receipt.requestFingerprint); try inverse(receipt.lifecycleInverse)
      try frame(); try string(receipt.action.summary)
      for _ in receipt.action.additionalOwners ?? [] { try frame() }
      for reference in receipt.action.references {
        try frame(); try string(reference.elementID); try string(reference.revision); try string(reference.label)
      }
      for value in receipt.action.expected { try expectation(value) }
      for operation in receipt.action.operations {
        try frame(); try string(operation.id)
        try cost.element(.json(.object(operation.values), depth: 4))
      }
      for value in receipt.revisions { try expectation(value) }
      for value in receipt.changes { try change(value) }
      for value in receipt.lifecycleChanges ?? [] {
        try frame(); try item(value.beforeItem); try item(value.afterItem)
      }
      if let undo = receipt.undo {
        try frame(); try inverse(undo.restorationInverse)
        for value in undo.preserved { try change(value) }
        for value in undo.restorations ?? [] {
          try frame(); try string(value.file); try path(value.path)
          try cost.element(value.writtenVersion.writeFootprint())
          if let version = value.restoredVersion { try cost.element(version.writeFootprint()) }
        }
        for value in undo.redoGates ?? [] {
          try frame(); try string(value.file); try path(value.path)
          try cost.element(value.writtenVersion.writeFootprint())
        }
        for value in undo.dependencies ?? [] {
          try frame(); try string(value.file); try path(value.path); try path(value.dependsOn)
        }
        for value in undo.lifecycleChanges ?? [] { try frame(); try item(value.item) }
        for _ in undo.preservedLifecycle ?? [] { try frame() }
      }
      try database.admitJSONAllocation(bytes: cost.decodingBytes)
    } catch let error as NotebookStorageError {
      if case .limitExceeded = error {
        try database.admitJSONAllocation(bytes: NotebookNativeWriteAllowance.maximumExecutionBytes + 1)
      }
      throw error
    }
  }

  private static func conflict() -> CollaborationError {
    .init("action_id_conflict", "Разные исходные ходы или завершённые отмены имеют одинаковый ID.")
  }
}

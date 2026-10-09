import Foundation

/// One locally authored receipt carries its already encoded value through the
/// synchronous physical writer. Incoming values still enter through decoding.
struct NotebookReceiptPublication {
  let receipt: CollaborationReceipt
  let value: JSONValue
  let sourceDigest: NotebookActionReadModel.Field.SourceDigest?
  private let encodedDeliveryVersion: String?
  private let hasExactTypedScalars: Bool
  var file: String { "collaboration/actions/" + receipt.id.uuidString.lowercased() + ".json" }

  init(_ receipt: CollaborationReceipt) throws {
    self.receipt = receipt
    hasExactTypedScalars = Self.hasExactTypedScalars(receipt)
    sourceDigest = hasExactTypedScalars ? try .original(receipt) : nil
    if sourceDigest != nil, try Self.hasCanonicalCompactMetadata(receipt) {
      let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      var version: String?
      value = try .encode(receipt, using: encoder, observingEncodedData: { data in
        version = notebookActionDeliveryVersion(canonicalReceiptBytes: data, actionID: receipt.id)
      })
      encodedDeliveryVersion = version
    } else {
      value = try .encode(receipt)
      encodedDeliveryVersion = nil
    }
  }

  /// A bound view of this same material, created only for an unchanged whole
  /// root. The index attaches it to the hash written by the physical writer.
  struct Root {
    fileprivate let publication: NotebookReceiptPublication
    let hash: String
    var receipt: CollaborationReceipt { publication.receipt }
    var value: JSONValue { publication.value }
    var sourceDigest: NotebookActionReadModel.Field.SourceDigest? { publication.sourceDigest }
    func deliveryVersion() throws -> String {
      try publication.encodedDeliveryVersion ?? notebookActionDeliveryVersion(value)
    }
    var address: String { publication.file + "#" }
  }

  func root(for fragment: NotebookStoredFragment, hash: String) -> Root? {
    guard hasExactTypedScalars, fragment.file == file, fragment.address == file + "#", fragment.parent == nil,
      fragment.collection.isEmpty, fragment.member.isEmpty, fragment.position == 0,
      fragment.collections.isEmpty, fragment.inkBodies.isEmpty,
      Self.matches(value, fragment.value) else { return nil }
    return .init(publication: self, hash: hash)
  }

  /// Original source receipts have typed integers in references, inverse counts
  /// and field clocks; submitted and retained values are JSONValue numbers.
  /// Equal numeric values need not have equal integer/Double JSON spellings.
  private static func hasCanonicalCompactMetadata(_ receipt: CollaborationReceipt) throws -> Bool {
    guard receipt.undo == nil, receipt.lifecycleChanges?.isEmpty ?? true,
      receipt.action.references.allSatisfy({ $0.worldOrigin == nil }) else { return false }
    let encoder = JSONEncoder()
    var counters = Set<UInt64>()
    func counter(_ value: UInt64) throws -> Bool {
      if counters.contains(value) { return true }
      // Bound additional scalar work; other receipts retain canonical value hashing.
      guard counters.count < 512,
        try encoder.encode(value) == encoder.encode(Double(value)) else { return false }
      counters.insert(value); return true
    }
    func version(_ value: ContentFieldVersion?) throws -> Bool {
      guard let value else { return true }
      guard value.isValid else { return false }
      return try value.allCountersSatisfy(counter)
    }
    if let inverse = receipt.lifecycleInverse,
      try encoder.encode(inverse.recordCount) != encoder.encode(Double(inverse.recordCount)) { return false }
    for reference in receipt.action.references {
      if let index = reference.pageIndex,
        try encoder.encode(index) != encoder.encode(Double(index)) { return false }
    }
    for field in receipt.changes {
      guard try version(field.beforeVersion), try version(field.afterVersion) else { return false }
    }
    return true
  }

  /// JSONValue carries numbers as Double. A typed integer that rounds there
  /// must still go through the existing decoder, including its overflow error.
  /// WorldPoint's initial encoding already proves its bounded tile integers.
  private static func hasExactTypedScalars(_ receipt: CollaborationReceipt) -> Bool {
    let maximum = Int(VersionStamp.maximumCounter)
    func integer(_ value: Int?) -> Bool { value.map { (-maximum...maximum).contains($0) } ?? true }
    func version(_ value: ContentFieldVersion?) -> Bool { value?.isValid ?? true }
    func change(_ value: CollaborationFieldChange) -> Bool {
      version(value.beforeVersion) && version(value.afterVersion)
    }
    guard receipt.action.references.allSatisfy({ integer($0.pageIndex) }),
      integer(receipt.lifecycleInverse?.recordCount), receipt.changes.allSatisfy(change),
      receipt.lifecycleChanges?.allSatisfy({ integer($0.beforeItem?.pageCount) && integer($0.afterItem?.pageCount) }) ?? true else {
      return false
    }
    guard let undo = receipt.undo else { return true }
    return integer(undo.restored) && integer(undo.restorationInverse?.recordCount)
      && undo.preserved.allSatisfy(change)
      && (undo.restorations?.allSatisfy({ version($0.writtenVersion) && version($0.restoredVersion) }) ?? true)
      && (undo.redoGates?.allSatisfy({ version($0.writtenVersion) }) ?? true)
      && (undo.lifecycleChanges?.allSatisfy({ integer($0.item?.pageCount) }) ?? true)
  }

  /// A publication binding needs literal keys and values, including source
  /// stored under expectedText or changes.before/after. JSONValue's semantic
  /// equality also accepts canonically equivalent strings and signed zero.
  private static func matches(_ left: JSONValue, _ right: JSONValue) -> Bool {
    switch (left, right) {
    case (.null, .null): return true
    case (.bool(let left), .bool(let right)): return left == right
    case (.number(let left), .number(let right)): return left.bitPattern == right.bitPattern
    case (.string(let left), .string(let right)): return DocumentFile.sourcesAreEqual(left, right)
    case (.array(let left), .array(let right)):
      return left.count == right.count && zip(left, right).allSatisfy { matches($0, $1) }
    case (.object(let left), .object(let right)):
      guard left.count == right.count else { return false }
      return zip(left.keys.sorted(), right.keys.sorted()).allSatisfy { leftKey, rightKey in
        DocumentFile.sourcesAreEqual(leftKey, rightKey) && matches(left[leftKey]!, right[rightKey]!)
      }
    default: return false
    }
  }
}

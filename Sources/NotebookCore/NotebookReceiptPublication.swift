import Foundation

/// One locally authored receipt carries its already encoded value through the
/// synchronous physical writer. Incoming values still enter through decoding.
struct NotebookReceiptPublication {
  let receipt: CollaborationReceipt
  let value: JSONValue
  let sourceDigest: NotebookActionReadModel.Field.SourceDigest?
  private let hasExactTypedScalars: Bool
  var file: String { "collaboration/actions/" + receipt.id.uuidString.lowercased() + ".json" }

  init(_ receipt: CollaborationReceipt) throws {
    self.receipt = receipt
    value = try .encode(receipt)
    hasExactTypedScalars = Self.hasExactTypedScalars(receipt)
    sourceDigest = hasExactTypedScalars ? try .original(receipt) : nil
  }

  /// A bound view of this same material, created only for an unchanged whole
  /// root. The index attaches it to the hash written by the physical writer.
  struct Root {
    fileprivate let publication: NotebookReceiptPublication
    let hash: String
    var receipt: CollaborationReceipt { publication.receipt }
    var value: JSONValue { publication.value }
    var sourceDigest: NotebookActionReadModel.Field.SourceDigest? { publication.sourceDigest }
    var address: String { publication.file + "#" }
  }

  func root(for fragment: NotebookStoredFragment, hash: String) -> Root? {
    guard hasExactTypedScalars, fragment.file == file, fragment.address == file + "#", fragment.parent == nil,
      fragment.collection.isEmpty, fragment.member.isEmpty, fragment.position == 0,
      fragment.collections.isEmpty, fragment.inkBodies.isEmpty,
      Self.matches(value, fragment.value) else { return nil }
    return .init(publication: self, hash: hash)
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

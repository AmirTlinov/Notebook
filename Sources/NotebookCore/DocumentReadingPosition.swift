import Foundation

/// An address in content, not in the current pagination. The compact node
/// fingerprint survives preceding insertions; the block text offset supplies
/// a deterministic fallback when that particular text has been edited.
public struct DocumentReadingAnchor: Codable, Equatable, Sendable {
  public let blockID: String
  public let nodeID: String
  public let textOffset: Int
  public let offset: Int
  public let blockOrder: [String]

  public init(blockID: String, nodeID: String, textOffset: Int, offset: Int, blockOrder: [String]) {
    self.blockID = blockID; self.nodeID = nodeID; self.textOffset = textOffset
    self.offset = offset; self.blockOrder = blockOrder
  }

  public var isValid: Bool {
    !blockID.isEmpty && blockID.utf16.count <= 120 && (nodeID.isEmpty || nodeID.utf8.count == 16)
      && nodeID.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
      && textOffset >= 0 && textOffset <= Int(Int32.max)
      && offset >= 0 && offset <= Int(Int32.max) - textOffset
      && blockOrder.count <= DocumentDocument.maximumBlockCount
      && Set(blockOrder).count == blockOrder.count && blockOrder.contains(blockID)
      && blockOrder.allSatisfy { !$0.isEmpty && $0.utf16.count <= 120 }
  }
}

/// Device-local reading state uses the same sole SQLite writer as presence.
/// A camera is relative to the book, so moving the item does not lose the place.
public struct DocumentReadingPosition: Codable, Equatable, Sendable {
  public let documentID: UUID
  public let sourceStamp: VersionStamp
  public let anchor: DocumentReadingAnchor
  public let zoomRatio: Double
  public let centerOffset: SpatialPoint

  public init(documentID: UUID, sourceStamp: VersionStamp, anchor: DocumentReadingAnchor,
    zoomRatio: Double, centerOffset: SpatialPoint) {
    self.documentID = documentID; self.sourceStamp = sourceStamp; self.anchor = anchor
    self.zoomRatio = zoomRatio; self.centerOffset = centerOffset
  }

  public var isValid: Bool {
    anchor.isValid && sourceStamp.counter <= VersionStamp.maximumCounter
      && zoomRatio.isFinite && zoomRatio > 0
      && centerOffset.x.isFinite && centerOffset.y.isFinite
  }
}

extension NotebookStore {
  private func documentReadingPath(_ id: UUID) -> String {
    "local/document-reading/\(id.uuidString.lowercased()).json"
  }

  public func readDocumentReadingPosition(_ documentID: UUID) throws -> DocumentReadingPosition? {
    guard let value = try storedValue(documentReadingPath(documentID))?.decode(DocumentReadingPosition.self) else { return nil }
    guard value.documentID == documentID, value.isValid else {
      throw NotebookStorageError.corruptRecord(documentReadingPath(documentID))
    }
    return value
  }

  public func saveDocumentReadingPosition(_ position: DocumentReadingPosition) throws {
    guard position.isValid else { throw NotebookStorageError.corruptRecord(documentReadingPath(position.documentID)) }
    try prepare()
    try withMutationLock {
      guard try readItemHeader(position.documentID)?.kind == .document else { return }
      try publishCollaboration(writes: [documentReadingPath(position.documentID): try .encode(position)])
    }
  }
}

import Foundation

/// Versions and metadata, without element, block, state or ink bodies. All
/// addressed reads borrow the caller's WAL snapshot rather than refreshing it.
public struct NotebookContentHeader: Codable, Equatable, Sendable {
  public let target: CollaborationTarget
  public let contentStamp: VersionStamp
  public let stateStamp: VersionStamp?
  public let inkStamp: VersionStamp?
  public let size: PageSize?
}

public struct NotebookContentPreview: Codable, Equatable, Sendable {
  public let id: String
  public let kind: String
  public let preview: String
}

public struct NotebookContentPreviewPage: Codable, Equatable, Sendable {
  public let items: [NotebookContentPreview]
  public let complete: Bool
}

public struct NotebookPageElementRead: Codable, Equatable, Sendable {
  public let header: NotebookContentHeader
  public let element: AgentElement
  public let graphicResolution: JSONValue?
}

extension NotebookStore {
  public func readPresenceIfAvailable() throws -> SessionPresence? {
    try readTransaction { _ in
      try hasStoredValue("last-context.json") ? loadPresence() : nil
    }
  }

  public func readContentHeader(target: CollaborationTarget) throws -> NotebookContentHeader {
    try readTransaction { _ in
      let file: String
      switch target.kind {
      case .page:
        guard try ownerItemID(ofPage: target.id) != nil else {
          throw CollaborationError("target_missing", "Лист отсутствует.", target: target)
        }
        file = pageFile(target.id)
      case .document:
        guard try readItemHeader(target.id)?.kind == .document else {
          throw CollaborationError("target_missing", "Документ отсутствует.", target: target)
        }
        file = documentFile(target.id)
      default: throw CollaborationError("invalid_reference", "Нужен адрес листа или документа.", target: target)
      }
      let roots = [(file + "#", false)] + (target.kind == .document ? [(stateFile(target.id) + "#", false)] : [])
      let rows = try boundedStoredFragments(roots, maximumCount: 2, maximumBytes: 262_144, budget: "content_header_read")
      guard let root = rows.first, root.address == file + "#",
        root.value["id"]?.string.flatMap(UUID.init(uuidString:)) == target.id else {
        throw NotebookStorageError.corruptRecord(file)
      }
      if target.kind == .page {
        guard root.value["format"] == .number(Double(PageDocument.formatVersion)),
          let size = try root.value["size"]?.decode(PageSize.self), size.isValid,
          let ink = try root.value["drawingStamp"]?.decode(VersionStamp.self), ink.counter <= VersionStamp.maximumCounter,
          let content = try root.value["agentStamp"]?.decode(VersionStamp.self), content.counter <= VersionStamp.maximumCounter else {
          throw NotebookStorageError.corruptRecord(file)
        }
        return .init(target: target, contentStamp: content, stateStamp: nil, inkStamp: ink, size: size)
      }
      let document = try NotebookRecordCodec.decode([root], root: root.address).decode(DocumentDocument.self)
      guard document.isValid, let stateRoot = rows.last, stateRoot.address == stateFile(target.id) + "#" else {
        throw NotebookStorageError.corruptRecord(file)
      }
      let state = try documentStateHeader(stateRoot, id: target.id)
      return .init(target: target, contentStamp: document.contentStamp, stateStamp: state.stamp, inkStamp: nil, size: nil)
    }
  }

  public func readPageElementSnapshot(pageID: UUID, elementID: String) throws -> NotebookPageElementRead? {
    try readTransaction { _ in
      let target = CollaborationTarget(kind: .page, id: pageID)
      let header = try readContentHeader(target: target)
      guard let element = try readPageElement(pageID: pageID, elementID: elementID) else { return nil }
      guard PageDocument.elementsAreValid([element], in: header.size!) else {
        throw NotebookStorageError.corruptRecord("page element")
      }
      let resolution = try element.graphic == nil ? nil : readGraphicResolution(target: target, elementID: elementID).readProjection()
      return .init(header: header, element: element, graphicResolution: resolution)
    }
  }

  /// Select through record_order first. The limit applies to actual reads, not
  /// a prefix of an already decoded document. Preview never reads block state.
  public func readContentPreviews(target: CollaborationTarget, limit: Int = 32) throws -> NotebookContentPreviewPage {
    guard (1...32).contains(limit) else { throw NotebookStorageError.limitExceeded("content_preview_read") }
    return try readTransaction { _ in
      _ = try readContentHeader(target: target)
      let file = target.kind == .page ? pageFile(target.id) : documentFile(target.id)
      let collection = target.kind == .page ? "elements" : "blocks"
      let addresses = try currentSQL!.rows("SELECT address FROM records WHERE parent=? AND collection=? ORDER BY position,member LIMIT ?",
        [.text(file + "#"), .text(collection), .integer(Int64(limit + 1))]).map { $0[0].text! }
      let rows = try boundedStoredFragments(addresses.prefix(limit).map { ($0, false) }, maximumCount: 32,
        maximumBytes: 4 * 1_024 * 1_024, budget: "content_preview_read")
      let items = try rows.map { row -> NotebookContentPreview in
        guard let id = row.value["id"]?.string, let kind = row.value["kind"]?.string, let source = row.value["source"]?.string else {
          throw NotebookStorageError.corruptRecord(row.address)
        }
        return .init(id: id, kind: kind, preview: String(source.prefix(160)))
      }
      return .init(items: items, complete: addresses.count <= limit)
    }
  }
}

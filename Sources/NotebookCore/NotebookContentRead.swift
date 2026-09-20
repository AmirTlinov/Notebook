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

public struct NotebookPageElementRead: Codable, Equatable, Sendable {
  public let header: NotebookContentHeader
  public let element: AgentElement
  public let graphicResolution: JSONValue?
  public let appearance: JSONValue
}

extension NotebookStore {
  public func presenceGeneration() throws -> String {
    try readTransaction { _ in
      try currentSQL!.rows("SELECT value FROM metadata WHERE key='presence_generation'").first?[0].text ?? "0"
    }
  }

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
      let resolution = try element.graphic == nil ? nil : readGraphicResolution(target: target, elementID: elementID)
      let frame = resolution?.layout?.frame ?? element.frame
      let appearance = try NotebookElementAppearance.readProjection(graphic: element.graphic, layout: resolution?.layout,
        size: .init(width: frame.width, height: frame.height),
        erasures: readElementErasures(on: .page(pageID), elementID: elementID))
      return try .init(header: header, element: element, graphicResolution: resolution?.readProjection(), appearance: appearance)
    }
  }

}

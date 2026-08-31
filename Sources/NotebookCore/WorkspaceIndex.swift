import Foundation

public enum WorkspaceItemKind: String, Codable, Equatable, Sendable {
  case notebook
  case document
}

public struct WorkspaceItem: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let kind: WorkspaceItemKind
  public internal(set) var title: String
  public internal(set) var pageIDs: [UUID]

  public init(
    id: UUID = UUID(),
    kind: WorkspaceItemKind,
    title: String,
    pageIDs: [UUID] = []
  ) {
    precondition(
      (kind == .notebook && !pageIDs.isEmpty)
        || (kind == .document && pageIDs.isEmpty)
    )
    self.id = id
    self.kind = kind
    self.title = title
    self.pageIDs = pageIDs
  }

  public static func notebook(
    id: UUID = UUID(),
    title: String,
    pageIDs: [UUID]
  ) -> Self {
    Self(id: id, kind: .notebook, title: title, pageIDs: pageIDs)
  }

  public static func document(
    id: UUID = UUID(),
    title: String
  ) -> Self {
    Self(id: id, kind: .document, title: title)
  }

  var isValid: Bool {
    switch kind {
    case .notebook:
      !pageIDs.isEmpty
    case .document:
      pageIDs.isEmpty
    }
  }
}

public struct WorkspaceIndex: Codable, Equatable, Sendable {
  public static let formatVersion = 2
  public static let maximumTitleLength = 240

  public let format: Int
  public private(set) var items: [WorkspaceItem]
  public private(set) var selectedItemID: UUID
  public private(set) var selectedPageID: UUID?
  public private(set) var stamp: VersionStamp

  public init(
    items: [WorkspaceItem],
    selectedItemID: UUID,
    selectedPageID: UUID?,
    stamp: VersionStamp
  ) {
    precondition(!items.isEmpty)
    format = Self.formatVersion
    self.items = items
    self.selectedItemID = selectedItemID
    self.selectedPageID = selectedPageID
    self.stamp = stamp
    precondition(isValid)
  }

  public static func initial(
    actor: UUID,
    pageSize: PageSize,
    itemID: UUID = UUID(),
    pageID: UUID = UUID()
  ) -> (index: Self, page: PageDocument) {
    let item = WorkspaceItem.notebook(
      id: itemID,
      title: "",
      pageIDs: [pageID]
    )
    return (
      Self(
        items: [item],
        selectedItemID: itemID,
        selectedPageID: pageID,
        stamp: VersionStamp(counter: 0, actor: actor)
      ),
      PageDocument(id: pageID, size: pageSize, actor: actor)
    )
  }

  private var selectedItemIndex: Int {
    items.firstIndex { $0.id == selectedItemID } ?? 0
  }

  public var selectedItem: WorkspaceItem {
    items[selectedItemIndex]
  }

  public var selectedPageIndex: Int? {
    guard let selectedPageID else { return nil }
    return selectedItem.pageIDs.firstIndex(of: selectedPageID)
  }

  @discardableResult
  public mutating func selectItem(
    _ itemID: UUID,
    pageID: UUID? = nil,
    actor: UUID
  ) -> Bool {
    guard let item = items.first(where: { $0.id == itemID }),
      let nextStamp = stamp.advanced(by: actor)
    else { return false }

    let selectedPage: UUID?
    switch item.kind {
    case .notebook:
      guard let candidate = pageID ?? item.pageIDs.first,
        item.pageIDs.contains(candidate)
      else { return false }
      selectedPage = candidate
    case .document:
      guard pageID == nil else { return false }
      selectedPage = nil
    }

    guard selectedItemID != itemID || selectedPageID != selectedPage else {
      return false
    }
    selectedItemID = itemID
    selectedPageID = selectedPage
    stamp = nextStamp
    return true
  }

  @discardableResult
  public mutating func createNotebook(
    title: String,
    actor: UUID,
    pageSize: PageSize,
    itemID: UUID = UUID(),
    pageID: UUID = UUID()
  ) -> (item: WorkspaceItem, page: PageDocument)? {
    let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized.utf16.count <= Self.maximumTitleLength,
      !items.contains(where: { $0.id == itemID }),
      !items.flatMap(\.pageIDs).contains(pageID),
      let nextStamp = stamp.advanced(by: actor)
    else { return nil }
    let page = PageDocument(id: pageID, size: pageSize, actor: actor)
    let item = WorkspaceItem.notebook(
      id: itemID,
      title: normalized,
      pageIDs: [pageID]
    )
    items.append(item)
    selectedItemID = itemID
    selectedPageID = pageID
    stamp = nextStamp
    return (item, page)
  }

  @discardableResult
  public mutating func createDocument(
    title: String,
    actor: UUID,
    documentID: UUID = UUID()
  ) -> WorkspaceItem? {
    let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized.utf16.count <= Self.maximumTitleLength,
      !items.contains(where: { $0.id == documentID }),
      let nextStamp = stamp.advanced(by: actor)
    else { return nil }
    let item = WorkspaceItem.document(id: documentID, title: normalized)
    items.append(item)
    selectedItemID = documentID
    selectedPageID = nil
    stamp = nextStamp
    return item
  }

  /// Removes one item and moves selection to its nearest neighbour. The board
  /// always retains one writable item.
  @discardableResult
  public mutating func deleteItem(
    _ itemID: UUID,
    actor: UUID
  ) -> WorkspaceItem? {
    guard items.count > 1,
      let removedIndex = items.firstIndex(where: { $0.id == itemID }),
      let nextStamp = stamp.advanced(by: actor)
    else { return nil }

    let removed = items.remove(at: removedIndex)
    if selectedItemID == itemID {
      let replacement = items[min(removedIndex, items.count - 1)]
      selectedItemID = replacement.id
      selectedPageID = replacement.pageIDs.first
    }
    stamp = nextStamp
    return removed
  }

  var isValid: Bool {
    guard format == Self.formatVersion,
      !items.isEmpty,
      stamp.counter <= VersionStamp.maximumCounter
    else { return false }

    let itemIDs = items.map(\.id)
    let pageIDs = items.flatMap(\.pageIDs)
    guard Set(itemIDs).count == itemIDs.count,
      Set(pageIDs).count == pageIDs.count,
      items.allSatisfy({
        $0.isValid && $0.title.utf16.count <= Self.maximumTitleLength
      }),
      let selected = items.first(where: { $0.id == selectedItemID })
    else { return false }

    switch selected.kind {
    case .notebook:
      guard let selectedPageID else { return false }
      return selected.pageIDs.contains(selectedPageID)
    case .document:
      return selectedPageID == nil
    }
  }

  @discardableResult
  public mutating func turnPage(
    by direction: Int,
    actor: UUID,
    pageSize: PageSize
  ) -> PageDocument? {
    precondition(direction == -1 || direction == 1)
    guard selectedItem.kind == .notebook,
      let selectedPageID,
      let nextStamp = stamp.advanced(by: actor)
    else { return nil }
    let itemIndex = selectedItemIndex
    guard let pageIndex = items[itemIndex].pageIDs.firstIndex(of: selectedPageID)
    else { return nil }
    let target = pageIndex + direction
    if target >= 0 && target < items[itemIndex].pageIDs.count {
      self.selectedPageID = items[itemIndex].pageIDs[target]
      stamp = nextStamp
      return nil
    }
    guard direction > 0 else { return nil }
    let page = PageDocument(size: pageSize, actor: actor)
    items[itemIndex].pageIDs.append(page.id)
    self.selectedPageID = page.id
    stamp = nextStamp
    return page
  }

  public mutating func merge(_ other: Self) -> Bool {
    guard stamp < other.stamp, other.isValid else { return false }
    items = other.items
    selectedItemID = other.selectedItemID
    selectedPageID = other.selectedPageID
    stamp = other.stamp
    return true
  }

  private enum CodingKeys: String, CodingKey {
    case format
    case items
    case selectedItemID
    case selectedPageID
    case stamp
    case notebooks
    case legacySelectedNotebookID = "selectedNotebookID"
  }

  private struct LegacyNotebook: Codable {
    let id: UUID
    let title: String
    let pageIDs: [UUID]
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let storedFormat = try container.decode(Int.self, forKey: .format)
    switch storedFormat {
    case Self.formatVersion:
      format = Self.formatVersion
      items = try container.decode([WorkspaceItem].self, forKey: .items)
      selectedItemID = try container.decode(UUID.self, forKey: .selectedItemID)
      selectedPageID = try container.decodeIfPresent(UUID.self, forKey: .selectedPageID)
      stamp = try container.decode(VersionStamp.self, forKey: .stamp)
    case 1:
      let notebooks = try container.decode(
        [LegacyNotebook].self,
        forKey: .notebooks
      )
      format = Self.formatVersion
      items = notebooks.map {
        WorkspaceItem.notebook(id: $0.id, title: $0.title, pageIDs: $0.pageIDs)
      }
      selectedItemID = try container.decode(
        UUID.self,
        forKey: .legacySelectedNotebookID
      )
      selectedPageID = try container.decode(UUID.self, forKey: .selectedPageID)
      stamp = try container.decode(VersionStamp.self, forKey: .stamp)
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .format,
        in: container,
        debugDescription: "Unsupported workspace format: \(storedFormat)"
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.formatVersion, forKey: .format)
    try container.encode(items, forKey: .items)
    try container.encode(selectedItemID, forKey: .selectedItemID)
    try container.encodeIfPresent(selectedPageID, forKey: .selectedPageID)
    try container.encode(stamp, forKey: .stamp)
  }
}

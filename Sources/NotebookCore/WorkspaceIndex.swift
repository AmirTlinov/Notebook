import Foundation

public enum WorkspaceRoot {
  public static let boardID = UUID(
    uuidString: "7E7A0000-0000-4000-8000-000000000003"
  )!
}

public enum WorkspaceItemKind: String, Codable, Equatable, Sendable {
  case notebook
  case document
  case board
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
        || ((kind == .document || kind == .board) && pageIDs.isEmpty)
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

  public static func board(
    id: UUID = UUID(),
    title: String
  ) -> Self {
    Self(id: id, kind: .board, title: title)
  }

  var isValid: Bool {
    switch kind {
    case .notebook:
      !pageIDs.isEmpty
    case .document, .board:
      pageIDs.isEmpty
    }
  }
}

/// The exact durable consequence of selecting a notebook sheet. Existing
/// sheets return only their identity; selecting the one provisional sheet at
/// the end also returns the new page that must be published before the index.
public struct WorkspacePageSelection: Equatable, Sendable {
  public let itemID: UUID
  public let pageIndex: Int
  public let pageID: UUID
  public let createdPage: PageDocument?

  public init(
    itemID: UUID,
    pageIndex: Int,
    pageID: UUID,
    createdPage: PageDocument?
  ) {
    self.itemID = itemID
    self.pageIndex = pageIndex
    self.pageID = pageID
    self.createdPage = createdPage
  }
}

public struct WorkspaceIndex: Codable, Equatable, Sendable {
  public static let formatVersion = 3
  public static let maximumTitleLength = 240

  public let format: Int
  public let rootBoardID: UUID
  public private(set) var items: [WorkspaceItem]
  /// Derived addresses belong to the same catalog value as their sources.
  /// Page edits keep their item slot; only membership changes these addresses.
  private var itemPositions: [UUID: Int]
  public private(set) var selectedItemID: UUID
  public private(set) var selectedPageID: UUID?
  public private(set) var stamp: VersionStamp
  public private(set) var collaboration: CollaborativeContent
  public private(set) var selectionVersion: ContentFieldVersion

  public init(
    items: [WorkspaceItem],
    selectedItemID: UUID,
    selectedPageID: UUID?,
    stamp: VersionStamp,
    rootBoardID: UUID = WorkspaceRoot.boardID
  ) {
    precondition(!items.isEmpty)
    format = Self.formatVersion
    self.rootBoardID = rootBoardID
    self.items = items
    itemPositions = Self.makeItemPositions(items)
    self.selectedItemID = selectedItemID
    self.selectedPageID = selectedPageID
    self.stamp = stamp
    collaboration = CollaborativeContent()
    selectionVersion = .init(stamp: stamp, human: true)
    recordChanges(from: nil, human: true)
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

  private static func makeItemPositions(_ items: [WorkspaceItem]) -> [UUID: Int] {
    Dictionary(items.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
  }

  public func item(id: UUID) -> WorkspaceItem? {
    itemPositions[id].map { items[$0] }
  }

  private var selectedItemIndex: Int {
    itemPositions[selectedItemID] ?? 0
  }

  public var selectedItem: WorkspaceItem {
    items[selectedItemIndex]
  }

  public var selectedPageIndex: Int? {
    guard let selectedPageID else { return nil }
    return selectedItem.pageIDs.firstIndex(of: selectedPageID)
  }

  /// A prepared mutation can await its durable publication while the person
  /// continues elsewhere. Reserve its clock before yielding so the next
  /// intent cannot reuse that actor/counter. No field value or owner changes.
  @discardableResult
  public mutating func observeCausalFrontier(_ frontier: VersionStamp) -> Bool {
    guard frontier.counter <= VersionStamp.maximumCounter, stamp < frontier else { return false }
    stamp = frontier
    return true
  }

  @discardableResult
  public mutating func selectItem(
    _ itemID: UUID,
    pageID: UUID? = nil,
    actor: UUID
  ) -> Bool {
    guard let item = item(id: itemID),
      let nextStamp = stamp.advanced(by: actor)
    else { return false }

    let selectedPage: UUID?
    switch item.kind {
    case .notebook:
      guard let candidate = pageID ?? item.pageIDs.first,
        item.pageIDs.contains(candidate)
      else { return false }
      selectedPage = candidate
    case .document, .board:
      guard pageID == nil else { return false }
      selectedPage = nil
    }

    guard selectedItemID != itemID || selectedPageID != selectedPage else {
      return false
    }
    selectedItemID = itemID
    selectedPageID = selectedPage
    stamp = nextStamp
    selectionVersion = .init(stamp: nextStamp, human: true, previous: selectionVersion)
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
      itemPositions[itemID] == nil,
      !items.flatMap(\.pageIDs).contains(pageID),
      let nextStamp = stamp.advanced(by: actor)
    else { return nil }
    let page = PageDocument(id: pageID, size: pageSize, actor: actor)
    let item = WorkspaceItem.notebook(
      id: itemID,
      title: normalized,
      pageIDs: [pageID]
    )
    itemPositions[item.id] = items.count
    items.append(item)
    selectedItemID = itemID
    selectedPageID = pageID
    stamp = nextStamp
    recordCreatedItem(item)
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
      itemPositions[documentID] == nil,
      let nextStamp = stamp.advanced(by: actor)
    else { return nil }
    let item = WorkspaceItem.document(id: documentID, title: normalized)
    itemPositions[item.id] = items.count
    items.append(item)
    selectedItemID = documentID
    selectedPageID = nil
    stamp = nextStamp
    recordCreatedItem(item)
    return item
  }

  @discardableResult
  public mutating func createBoard(
    title: String,
    actor: UUID,
    boardID: UUID = UUID()
  ) -> WorkspaceItem? {
    let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized.utf16.count <= Self.maximumTitleLength,
      boardID != rootBoardID,
      itemPositions[boardID] == nil,
      let nextStamp = stamp.advanced(by: actor)
    else { return nil }
    let item = WorkspaceItem.board(id: boardID, title: normalized)
    itemPositions[item.id] = items.count
    items.append(item)
    selectedItemID = boardID
    selectedPageID = nil
    stamp = nextStamp
    recordCreatedItem(item)
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
      let removedIndex = itemPositions[itemID],
      let nextStamp = stamp.advanced(by: actor)
    else { return nil }

    let changesSelection = selectedItemID == itemID
    let removed = items.remove(at: removedIndex)
    itemPositions[itemID] = nil
    for position in removedIndex..<items.count { itemPositions[items[position].id] = position }
    if selectedItemID == itemID {
      let replacement = items[min(removedIndex, items.count - 1)]
      selectedItemID = replacement.id
      selectedPageID = replacement.pageIDs.first
    }
    stamp = nextStamp
    collaboration.recordField(Self.itemField(itemID, "exists"), stamp: stamp, human: true)
    collaboration.recordField("items/order", stamp: stamp, human: true)
    if changesSelection { selectionVersion = .init(stamp: stamp, human: true, previous: selectionVersion) }
    return removed
  }

  var isValid: Bool {
    guard format == Self.formatVersion,
      !items.isEmpty,
      stamp.counter <= VersionStamp.maximumCounter,
      selectionVersion.isValid, collaboration.isValid(maximumFields: 1_000_000)
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
    case .document, .board:
      return selectedPageID == nil
    }
  }

  @discardableResult
  public mutating func selectPage(
    at pageIndex: Int,
    in itemID: UUID,
    actor: UUID,
    pageSize: PageSize
  ) -> WorkspacePageSelection? {
    guard pageIndex >= 0,
      selectedItemID == itemID,
      selectedItem.kind == .notebook,
      let selectedPageID
    else { return nil }
    let itemIndex = selectedItemIndex
    guard let currentIndex = items[itemIndex].pageIDs.firstIndex(
      of: selectedPageID
    ),
      pageIndex != currentIndex,
      pageIndex <= items[itemIndex].pageIDs.count,
      let nextStamp = stamp.advanced(by: actor)
    else { return nil }

    if pageIndex < items[itemIndex].pageIDs.count {
      let pageID = items[itemIndex].pageIDs[pageIndex]
      self.selectedPageID = pageID
      stamp = nextStamp
      selectionVersion = .init(stamp: stamp, human: true, previous: selectionVersion)
      return WorkspacePageSelection(
        itemID: itemID,
        pageIndex: pageIndex,
        pageID: pageID,
        createdPage: nil
      )
    }

    let page = PageDocument(size: pageSize, actor: actor)
    items[itemIndex].pageIDs.append(page.id)
    self.selectedPageID = page.id
    stamp = nextStamp
    collaboration.recordField(Self.itemField(itemID, "exists"), stamp: stamp, human: true)
    collaboration.recordField(Self.itemField(itemID, "pageIDs"), stamp: stamp, human: true)
    collaboration.recordField(Self.pageField(itemID, page.id), stamp: stamp, human: true)
    selectionVersion = .init(stamp: stamp, human: true, previous: selectionVersion)
    return WorkspacePageSelection(
      itemID: itemID,
      pageIndex: pageIndex,
      pageID: page.id,
      createdPage: page
    )
  }

  public mutating func merge(_ other: Self) -> Bool {
    guard let resolved = try? merging(other), resolved != self else { return false }
    self = resolved
    return true
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.format == rhs.format && lhs.rootBoardID == rhs.rootBoardID
      && lhs.items == rhs.items && lhs.selectedItemID == rhs.selectedItemID
      && lhs.selectedPageID == rhs.selectedPageID && lhs.stamp == rhs.stamp
      && lhs.collaboration == rhs.collaboration && lhs.selectionVersion == rhs.selectionVersion
  }

  private enum CodingKeys: String, CodingKey {
    case format
    case items
    case selectedItemID
    case selectedPageID
    case stamp
    case collaboration
    case selectionVersion
    case rootBoardID
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
      rootBoardID = try container.decode(UUID.self, forKey: .rootBoardID)
      items = try container.decode([WorkspaceItem].self, forKey: .items)
      selectedItemID = try container.decode(UUID.self, forKey: .selectedItemID)
      selectedPageID = try container.decodeIfPresent(UUID.self, forKey: .selectedPageID)
      stamp = try container.decode(VersionStamp.self, forKey: .stamp)
    case 2:
      format = Self.formatVersion
      rootBoardID = WorkspaceRoot.boardID
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
      rootBoardID = WorkspaceRoot.boardID
      guard notebooks.allSatisfy({ !$0.pageIDs.isEmpty }) else {
        throw DecodingError.dataCorruptedError(forKey: .notebooks, in: container, debugDescription: "A notebook requires a page.")
      }
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
    itemPositions = Self.makeItemPositions(items)
    selectionVersion = try container.decodeIfPresent(ContentFieldVersion.self, forKey: .selectionVersion) ?? .init(stamp: stamp, human: true)
    collaboration = try container.decodeIfPresent(CollaborativeContent.self, forKey: .collaboration) ?? CollaborativeContent()
    if !container.contains(.collaboration) { recordChanges(from: nil, human: true) }
    guard isValid else {
      throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid workspace owner."))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.formatVersion, forKey: .format)
    try container.encode(rootBoardID, forKey: .rootBoardID)
    try container.encode(items, forKey: .items)
    try container.encode(selectedItemID, forKey: .selectedItemID)
    try container.encodeIfPresent(selectedPageID, forKey: .selectedPageID)
    try container.encode(stamp, forKey: .stamp)
    try container.encode(collaboration, forKey: .collaboration)
    try container.encode(selectionVersion, forKey: .selectionVersion)
  }

  private static func itemField(_ id: UUID, _ field: String) -> String {
    fieldKey(["items", id.uuidString.lowercased(), field])
  }

  private static func pageField(_ itemID: UUID, _ pageID: UUID) -> String {
    fieldKey(["items", itemID.uuidString.lowercased(), "pageIDs", pageID.uuidString.lowercased()])
  }

  private mutating func recordCreatedItem(_ item: WorkspaceItem) {
    for field in ["exists", "title", "kind", "pageIDs"] {
      collaboration.recordField(Self.itemField(item.id, field), stamp: stamp, human: true)
    }
    for page in item.pageIDs {
      collaboration.recordField(Self.pageField(item.id, page), stamp: stamp, human: true)
    }
    collaboration.recordField("items/order", stamp: stamp, human: true)
    selectionVersion = .init(stamp: stamp, human: true, previous: selectionVersion)
  }

  /// Native selection records one field; agent operations and undo use this
  /// same owner's comparison to record only the catalog fields they changed.
  mutating func recordChanges(from previous: Self?, human: Bool) {
    collaboration = previous?.collaboration ?? CollaborativeContent()
    let oldIDs = previous?.items.map(\.id) ?? []
    let ids = items.map(\.id)
    if oldIDs != ids { collaboration.recordField("items/order", stamp: stamp, human: human) }
    selectionVersion = previous?.selectionVersion ?? .init(stamp: stamp, human: human)
    if previous?.selectedItemID != selectedItemID || previous?.selectedPageID != selectedPageID {
      selectionVersion = .init(stamp: stamp, human: human, previous: selectionVersion)
    }
    for id in Set(oldIDs).union(ids) {
      let old = previous?.item(id: id), new = item(id: id)
      guard old != new else { continue }
      collaboration.recordField(Self.itemField(id, "exists"), stamp: stamp, human: human)
      guard let new else { continue }
      if old?.title != new.title { collaboration.recordField(Self.itemField(id, "title"), stamp: stamp, human: human) }
      if old?.kind != new.kind { collaboration.recordField(Self.itemField(id, "kind"), stamp: stamp, human: human) }
      if old?.pageIDs != new.pageIDs {
        collaboration.recordField(Self.itemField(id, "pageIDs"), stamp: stamp, human: human)
        let oldPages = Set(old?.pageIDs ?? []), newPages = Set(new.pageIDs)
        for page in oldPages.symmetricDifference(newPages) {
          collaboration.recordField(Self.pageField(id, page), stamp: stamp, human: human)
        }
      }
    }
  }

  public func merging(_ other: Self) throws -> Self {
    guard isValid, other.isValid, rootBoardID == other.rootBoardID else {
      throw CollaborationError("invalid_content", "Каталоги должны принадлежать одному корню.")
    }
    if self == other { return self }
    func incomingOwns(_ field: String) -> Bool {
      if field == "selection" { return other.selectionVersion.wins(over: selectionVersion) }
      guard let incoming = other.collaboration.fields[field] else { return false }
      guard let current = collaboration.fields[field] else { return true }
      return incoming.wins(over: current)
    }
    var byID: [UUID: WorkspaceItem] = [:]
    for id in Set(items.map(\.id)).union(other.items.map(\.id)) {
      let local = item(id: id), incoming = other.item(id: id)
      let exists = incomingOwns(Self.itemField(id, "exists")) ? incoming != nil : local != nil
      guard exists else { continue }
      guard var resolved = local ?? incoming else { continue }
      if let local, let incoming {
        guard local.kind == incoming.kind else {
          throw CollaborationError("invalid_content", "UUID предмета не меняет вид владельца.")
        }
        resolved.title = incomingOwns(Self.itemField(id, "title")) ? incoming.title : local.title
        let localPages = Set(local.pageIDs), incomingPages = Set(incoming.pageIDs)
        let live = localPages.union(incomingPages).filter { page in
          incomingOwns(Self.pageField(id, page)) ? incomingPages.contains(page) : localPages.contains(page)
        }
        let preferred = incomingOwns(Self.itemField(id, "pageIDs")) ? incoming.pageIDs : local.pageIDs
        resolved.pageIDs = preferred.filter(live.contains) + live.subtracting(preferred).sorted { $0.uuidString < $1.uuidString }
      }
      byID[id] = resolved
    }
    guard !byID.isEmpty else {
      throw CollaborationError("workspace_conflict", "Независимые удаления требуют сохранить хотя бы один доступный предмет.")
    }
    let preferred = incomingOwns("items/order") ? other.items : items
    let preferredIDs = preferred.map(\.id)
    let order = preferredIDs.filter { byID[$0] != nil }
      + Set(byID.keys).subtracting(preferredIDs).sorted { $0.uuidString < $1.uuidString }
    let selected = incomingOwns("selection") ? other : self
    let selectedID = byID[selected.selectedItemID] == nil ? order[0] : selected.selectedItemID
    let selectedItem = byID[selectedID]!
    let selectedPage = selected.selectedPageID.flatMap { selectedItem.pageIDs.contains($0) ? $0 : nil }
      ?? selectedItem.pageIDs.first
    let frontier = max(stamp, other.stamp)
    var result = self
    result.items = order.compactMap { byID[$0] }
    result.itemPositions = Self.makeItemPositions(result.items)
    result.selectedItemID = selectedID
    result.selectedPageID = selectedPage
    result.stamp = frontier
    result.selectionVersion = selectionVersion.joining(other.selectionVersion)
    for (key, version) in other.collaboration.fields { result.collaboration.joinField(key, version: version) }
    let newest = stamp > other.stamp ? self : other
    if result.items != newest.items || selectedID != newest.selectedItemID || selectedPage != newest.selectedPageID {
      result.stamp = frontier.advanced(by: frontier.actor) ?? frontier
    }
    guard result.isValid else { throw CollaborationError("invalid_content", "Слияние каталога должно сохранить уникальных владельцев листов.") }
    return result
  }
}

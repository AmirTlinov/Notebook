import Foundation

public struct Notebook: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let title: String
  public internal(set) var pageIDs: [UUID]

  public init(id: UUID = UUID(), title: String, pageIDs: [UUID]) {
    precondition(!pageIDs.isEmpty)
    self.id = id
    self.title = title
    self.pageIDs = pageIDs
  }
}

public struct WorkspaceIndex: Codable, Equatable, Sendable {
  public static let formatVersion = 1

  public let format: Int
  public private(set) var notebooks: [Notebook]
  public private(set) var selectedNotebookID: UUID
  public private(set) var selectedPageID: UUID
  public private(set) var stamp: VersionStamp

  public init(
    notebooks: [Notebook],
    selectedNotebookID: UUID,
    selectedPageID: UUID,
    stamp: VersionStamp
  ) {
    precondition(!notebooks.isEmpty)
    format = Self.formatVersion
    self.notebooks = notebooks
    self.selectedNotebookID = selectedNotebookID
    self.selectedPageID = selectedPageID
    self.stamp = stamp
    precondition(isValid)
  }

  public static func initial(
    actor: UUID,
    pageSize: PageSize,
    notebookID: UUID = UUID(),
    pageID: UUID = UUID()
  ) -> (index: Self, page: PageDocument) {
    let notebook = Notebook(
      id: notebookID,
      title: "Тетрадь 1",
      pageIDs: [pageID]
    )
    return (
      Self(
        notebooks: [notebook],
        selectedNotebookID: notebookID,
        selectedPageID: pageID,
        stamp: VersionStamp(counter: 0, actor: actor)
      ),
      PageDocument(id: pageID, size: pageSize, actor: actor)
    )
  }

  private var selectedNotebookIndex: Int {
    notebooks.firstIndex { $0.id == selectedNotebookID } ?? 0
  }

  public var selectedNotebook: Notebook {
    notebooks[selectedNotebookIndex]
  }

  public var selectedPageIndex: Int {
    selectedNotebook.pageIDs.firstIndex(of: selectedPageID) ?? 0
  }

  var isValid: Bool {
    guard format == Self.formatVersion,
      !notebooks.isEmpty,
      stamp.counter <= VersionStamp.maximumCounter
    else { return false }

    let notebookIDs = notebooks.map(\.id)
    let pageIDs = notebooks.flatMap(\.pageIDs)
    guard Set(notebookIDs).count == notebookIDs.count,
      Set(pageIDs).count == pageIDs.count,
      notebooks.allSatisfy({
        !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && !$0.pageIDs.isEmpty
      })
    else { return false }

    return notebooks.first(where: { $0.id == selectedNotebookID })?
      .pageIDs.contains(selectedPageID) == true
  }

  @discardableResult
  public mutating func turnPage(
    by direction: Int,
    actor: UUID,
    pageSize: PageSize
  ) -> PageDocument? {
    precondition(direction == -1 || direction == 1)
    guard let nextStamp = stamp.advanced(by: actor) else { return nil }
    let notebookIndex = selectedNotebookIndex
    let pageIndex = selectedPageIndex
    let target = pageIndex + direction
    if target >= 0 && target < notebooks[notebookIndex].pageIDs.count {
      selectedPageID = notebooks[notebookIndex].pageIDs[target]
      stamp = nextStamp
      return nil
    }
    guard direction > 0 else { return nil }
    let page = PageDocument(size: pageSize, actor: actor)
    notebooks[notebookIndex].pageIDs.append(page.id)
    selectedPageID = page.id
    stamp = nextStamp
    return page
  }

  @discardableResult
  public mutating func changeNotebook(
    by direction: Int,
    actor: UUID,
    pageSize: PageSize
  ) -> PageDocument? {
    precondition(direction == -1 || direction == 1)
    guard let nextStamp = stamp.advanced(by: actor) else { return nil }
    let target = selectedNotebookIndex + direction
    if target >= 0 && target < notebooks.count {
      selectedNotebookID = notebooks[target].id
      selectedPageID = notebooks[target].pageIDs[0]
      stamp = nextStamp
      return nil
    }
    guard direction > 0 else { return nil }
    let page = PageDocument(size: pageSize, actor: actor)
    let notebook = Notebook(
      title: "Тетрадь \(notebooks.count + 1)",
      pageIDs: [page.id]
    )
    notebooks.append(notebook)
    selectedNotebookID = notebook.id
    selectedPageID = page.id
    stamp = nextStamp
    return page
  }

  public mutating func merge(_ other: Self) -> Bool {
    guard stamp < other.stamp, other.isValid else { return false }
    notebooks = other.notebooks
    selectedNotebookID = other.selectedNotebookID
    selectedPageID = other.selectedPageID
    stamp = other.stamp
    return true
  }
}

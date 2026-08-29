import Foundation

public struct Notebook: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public var title: String
  public var pageIDs: [UUID]

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
  public var notebooks: [Notebook]
  public var selectedNotebookID: UUID
  public var selectedPageID: UUID
  public var stamp: VersionStamp

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
    precondition(isSelectionValid)
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

  public var selectedNotebookIndex: Int {
    notebooks.firstIndex { $0.id == selectedNotebookID } ?? 0
  }

  public var selectedNotebook: Notebook {
    notebooks[selectedNotebookIndex]
  }

  public var selectedPageIndex: Int {
    selectedNotebook.pageIDs.firstIndex(of: selectedPageID) ?? 0
  }

  public var isSelectionValid: Bool {
    notebooks.first(where: { $0.id == selectedNotebookID })?
      .pageIDs.contains(selectedPageID) == true
  }

  @discardableResult
  public mutating func turnPage(
    by direction: Int,
    actor: UUID,
    pageSize: PageSize
  ) -> PageDocument? {
    precondition(direction == -1 || direction == 1)
    let notebookIndex = selectedNotebookIndex
    let pageIndex = selectedPageIndex
    let target = pageIndex + direction
    if target >= 0 && target < notebooks[notebookIndex].pageIDs.count {
      selectedPageID = notebooks[notebookIndex].pageIDs[target]
      stamp = stamp.advanced(by: actor)
      return nil
    }
    guard direction > 0 else { return nil }
    let page = PageDocument(size: pageSize, actor: actor)
    notebooks[notebookIndex].pageIDs.append(page.id)
    selectedPageID = page.id
    stamp = stamp.advanced(by: actor)
    return page
  }

  @discardableResult
  public mutating func changeNotebook(
    by direction: Int,
    actor: UUID,
    pageSize: PageSize
  ) -> PageDocument? {
    precondition(direction == -1 || direction == 1)
    let target = selectedNotebookIndex + direction
    if target >= 0 && target < notebooks.count {
      selectedNotebookID = notebooks[target].id
      selectedPageID = notebooks[target].pageIDs[0]
      stamp = stamp.advanced(by: actor)
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
    stamp = stamp.advanced(by: actor)
    return page
  }

  public mutating func merge(_ other: Self) -> Bool {
    guard stamp < other.stamp, other.isSelectionValid else { return false }
    notebooks = other.notebooks
    selectedNotebookID = other.selectedNotebookID
    selectedPageID = other.selectedPageID
    stamp = other.stamp
    return true
  }
}

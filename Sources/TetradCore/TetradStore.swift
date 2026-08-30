import Foundation

public struct TetradStore: Sendable {
  private static let lockName = ".mutation-lock"

  public let root: URL

  public init(root: URL) {
    self.root = root
  }

  public static var defaultRoot: URL {
    FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    )[0].appendingPathComponent("Tetrad", isDirectory: true)
  }

  public var indexURL: URL {
    root.appendingPathComponent("workspace.json")
  }

  public var pagesURL: URL {
    root.appendingPathComponent("pages", isDirectory: true)
  }

  private var previewsURL: URL {
    root.appendingPathComponent("previews", isDirectory: true)
  }

  public func pageURL(_ id: UUID) -> URL {
    pagesURL.appendingPathComponent(id.uuidString.lowercased() + ".json")
  }

  public func previewURL(_ id: UUID) -> URL {
    previewsURL.appendingPathComponent(id.uuidString.lowercased() + ".png")
  }

  public func previewRevisionURL(_ id: UUID) -> URL {
    previewsURL.appendingPathComponent(id.uuidString.lowercased() + ".revision")
  }

  public func prepare() throws {
    try FileManager.default.createDirectory(
      at: pagesURL,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: previewsURL,
      withIntermediateDirectories: true
    )
  }

  public func loadOrCreate(
    actor: UUID,
    pageSize: PageSize,
    initialNotebookID: UUID = UUID(),
    initialPageID: UUID = UUID()
  ) throws -> (WorkspaceIndex, [UUID: PageDocument]) {
    try prepare()
    if FileManager.default.fileExists(atPath: indexURL.path) {
      let index = try loadIndex()
      let pages = try Dictionary(
        uniqueKeysWithValues: index.notebooks
          .flatMap(\.pageIDs)
          .map { id in (id, try loadPage(id)) }
      )
      return (index, pages)
    }
    let initial = WorkspaceIndex.initial(
      actor: actor,
      pageSize: pageSize,
      notebookID: initialNotebookID,
      pageID: initialPageID
    )
    try savePage(initial.page)
    try saveIndex(initial.index)
    return (initial.index, [initial.page.id: initial.page])
  }

  public func loadIndex() throws -> WorkspaceIndex {
    let index = try decoder.decode(
      WorkspaceIndex.self,
      from: Data(contentsOf: indexURL)
    )
    guard index.isValid else { throw corruptFile(at: indexURL) }
    return index
  }

  public func loadPage(_ id: UUID) throws -> PageDocument {
    let page = try decoder.decode(
      PageDocument.self,
      from: Data(contentsOf: pageURL(id))
    )
    guard page.id == id, page.isValid else {
      throw corruptFile(at: pageURL(id))
    }
    return page
  }

  public func saveIndex(_ index: WorkspaceIndex) throws {
    guard index.isValid else { throw corruptFile(at: indexURL) }
    try prepare()
    try withMutationLock {
      try encoder.encode(index).write(to: indexURL, options: [.atomic])
    }
  }

  public func savePage(_ page: PageDocument) throws {
    guard page.isValid else { throw corruptFile(at: pageURL(page.id)) }
    try prepare()
    try withMutationLock {
      try writePage(page)
    }
  }

  /// Saves both independent streams without allowing a stale writer to erase
  /// a newer Pencil drawing or a newer agent layer.
  @discardableResult
  public func saveMergedPage(_ page: PageDocument) throws -> PageDocument {
    guard page.isValid else { throw corruptFile(at: pageURL(page.id)) }
    try prepare()
    return try withMutationLock {
      var resolved = page
      let url = pageURL(page.id)
      if FileManager.default.fileExists(atPath: url.path) {
        let disk = try decoder.decode(
          PageDocument.self,
          from: Data(contentsOf: url)
        )
        guard disk.id == page.id,
          disk.size == page.size,
          disk.isValid
        else {
          throw corruptFile(at: url)
        }
        _ = resolved.merge(disk)
      }
      try writePage(resolved)
      return resolved
    }
  }

  private func writePage(_ page: PageDocument) throws {
    try encoder.encode(page).write(to: pageURL(page.id), options: [.atomic])
  }

  private func corruptFile(at url: URL) -> CocoaError {
    CocoaError(
      .fileReadCorruptFile,
      userInfo: [NSFilePathErrorKey: url.path]
    )
  }

  private func withMutationLock<T>(_ operation: () throws -> T) throws -> T {
    let lockURL = root.appendingPathComponent(Self.lockName, isDirectory: true)
    let fileManager = FileManager.default
    var acquired = false
    for _ in 0..<200 {
      do {
        try fileManager.createDirectory(
          at: lockURL,
          withIntermediateDirectories: false
        )
        acquired = true
        break
      } catch let error as CocoaError
        where error.code == .fileWriteFileExists
      {
        if let values = try? lockURL.resourceValues(forKeys: [.contentModificationDateKey]),
           let date = values.contentModificationDate,
           Date().timeIntervalSince(date) > 15 {
          try? fileManager.removeItem(at: lockURL)
          continue
        }
        Thread.sleep(forTimeInterval: 0.003)
      } catch {
        throw error
      }
    }
    guard acquired else {
      throw CocoaError(.fileWriteUnknown)
    }
    defer { try? fileManager.removeItem(at: lockURL) }
    return try operation()
  }

  private var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  private var decoder: JSONDecoder {
    JSONDecoder()
  }
}

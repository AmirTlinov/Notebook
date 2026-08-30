import Foundation

public struct NotebookStore: Sendable {
  private static let lockName = ".mutation-lock"
  private static let legacyDirectoryName = "Tetrad"

  public let root: URL

  public init(root: URL) {
    self.root = root
  }

  public static var defaultRoot: URL {
    applicationSupportRoot.appendingPathComponent("Notebook", isDirectory: true)
  }

  private static var applicationSupportRoot: URL {
    FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    )[0]
  }

  private static var legacyDefaultRoot: URL {
    applicationSupportRoot.appendingPathComponent(
      legacyDirectoryName,
      isDirectory: true
    )
  }

  public var indexURL: URL {
    root.appendingPathComponent("workspace.json")
  }

  public var pagesURL: URL {
    root.appendingPathComponent("pages", isDirectory: true)
  }

  public var boardURL: URL {
    root.appendingPathComponent("board.json")
  }

  public var spatialInkURL: URL {
    root.appendingPathComponent("spatial-ink.json")
  }

  public var presenceURL: URL {
    root.appendingPathComponent("last-context.json")
  }

  public var currentViewPreviewURL: URL {
    previewsURL.appendingPathComponent("current-view.png")
  }

  public var currentViewRevisionURL: URL {
    previewsURL.appendingPathComponent("current-view.revision")
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
    if root.standardizedFileURL == Self.defaultRoot.standardizedFileURL {
      try Self.migrateLegacyStore(
        from: Self.legacyDefaultRoot,
        to: root
      )
    }
    try FileManager.default.createDirectory(
      at: pagesURL,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: previewsURL,
      withIntermediateDirectories: true
    )
  }

  static func migrateLegacyStore(
    from legacyRoot: URL,
    to currentRoot: URL,
    fileManager: FileManager = .default
  ) throws {
    guard
      !fileManager.fileExists(atPath: currentRoot.path),
      fileManager.fileExists(atPath: legacyRoot.path)
    else { return }

    try fileManager.createDirectory(
      at: currentRoot.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    do {
      try fileManager.moveItem(at: legacyRoot, to: currentRoot)
    } catch {
      guard fileManager.fileExists(atPath: currentRoot.path) else { throw error }
    }
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
    let board = BoardDocument.initial(
      notebookIDs: [initialNotebookID],
      actor: actor
    )
    try saveWorkspaceBundle(
      index: initial.index,
      page: initial.page,
      board: board
    )
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

  public func loadOrCreateBoard(
    workspace: WorkspaceIndex,
    actor: UUID
  ) throws -> BoardDocument {
    try prepare()
    let notebookIDs = Set(workspace.notebooks.map(\.id))
    if FileManager.default.fileExists(atPath: boardURL.path) {
      let board = try decoder.decode(
        BoardDocument.self,
        from: Data(contentsOf: boardURL)
      )
      guard board.isValid(notebookIDs: notebookIDs) else {
        throw corruptFile(at: boardURL)
      }
      return board
    }
    let board = BoardDocument.initial(
      notebookIDs: workspace.notebooks.map(\.id),
      actor: actor
    )
    try saveBoard(board, notebookIDs: notebookIDs)
    return board
  }

  public func loadBoard(notebookIDs: Set<UUID>) throws -> BoardDocument {
    let board = try decoder.decode(
      BoardDocument.self,
      from: Data(contentsOf: boardURL)
    )
    guard board.isValid(notebookIDs: notebookIDs) else {
      throw corruptFile(at: boardURL)
    }
    return board
  }

  public func loadOrCreateSpatialInk(actor: UUID) throws -> SpatialInkJournal {
    try prepare()
    if FileManager.default.fileExists(atPath: spatialInkURL.path) {
      return try loadSpatialInk()
    }
    let journal = SpatialInkJournal(
      stamp: VersionStamp(counter: 0, actor: actor)
    )
    try saveSpatialInk(journal)
    return journal
  }

  public func loadSpatialInk() throws -> SpatialInkJournal {
    let journal = try decoder.decode(
      SpatialInkJournal.self,
      from: Data(contentsOf: spatialInkURL)
    )
    guard journal.isValid else { throw corruptFile(at: spatialInkURL) }
    return journal
  }

  public func loadPresence() throws -> SessionPresence {
    let presence = try decoder.decode(
      SessionPresence.self,
      from: Data(contentsOf: presenceURL)
    )
    guard presence.isValid else { throw corruptFile(at: presenceURL) }
    return presence
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

  public func saveBoard(
    _ board: BoardDocument,
    notebookIDs: Set<UUID>
  ) throws {
    guard board.isValid(notebookIDs: notebookIDs) else {
      throw corruptFile(at: boardURL)
    }
    try prepare()
    try withMutationLock {
      try encoder.encode(board).write(to: boardURL, options: [.atomic])
    }
  }

  @discardableResult
  public func saveMergedBoard(
    _ board: BoardDocument,
    notebookIDs: Set<UUID>
  ) throws -> BoardDocument {
    guard board.isValid(notebookIDs: notebookIDs) else {
      throw corruptFile(at: boardURL)
    }
    try prepare()
    return try withMutationLock {
      var resolved = board
      if FileManager.default.fileExists(atPath: boardURL.path) {
        let disk = try decoder.decode(
          BoardDocument.self,
          from: Data(contentsOf: boardURL)
        )
        guard disk.isValid(notebookIDs: notebookIDs) else {
          throw corruptFile(at: boardURL)
        }
        _ = resolved.merge(disk, notebookIDs: notebookIDs)
      }
      try encoder.encode(resolved).write(to: boardURL, options: [.atomic])
      return resolved
    }
  }

  public func saveSpatialInk(_ journal: SpatialInkJournal) throws {
    guard journal.isValid else { throw corruptFile(at: spatialInkURL) }
    try prepare()
    try withMutationLock {
      try encoder.encode(journal).write(to: spatialInkURL, options: [.atomic])
    }
  }

  @discardableResult
  public func saveMergedSpatialInk(
    _ journal: SpatialInkJournal
  ) throws -> SpatialInkJournal {
    guard journal.isValid else { throw corruptFile(at: spatialInkURL) }
    try prepare()
    return try withMutationLock {
      var resolved = journal
      if FileManager.default.fileExists(atPath: spatialInkURL.path) {
        let disk = try decoder.decode(
          SpatialInkJournal.self,
          from: Data(contentsOf: spatialInkURL)
        )
        guard disk.isValid else { throw corruptFile(at: spatialInkURL) }
        _ = resolved.merge(disk)
      }
      try encoder.encode(resolved).write(
        to: spatialInkURL,
        options: [.atomic]
      )
      return resolved
    }
  }

  public func savePresence(_ presence: SessionPresence) throws {
    guard presence.isValid else { throw corruptFile(at: presenceURL) }
    try prepare()
    try withMutationLock {
      try encoder.encode(presence).write(to: presenceURL, options: [.atomic])
    }
  }

  /// Creation publishes dependencies first and the catalog last. Readers that
  /// discover the notebook through the catalog can therefore also read its
  /// page and board placement.
  public func saveWorkspaceBundle(
    index: WorkspaceIndex,
    page: PageDocument,
    board: BoardDocument
  ) throws {
    let notebookIDs = Set(index.notebooks.map(\.id))
    guard index.isValid, page.isValid,
      board.isValid(notebookIDs: notebookIDs),
      index.notebooks.flatMap(\.pageIDs).contains(page.id)
    else { throw corruptFile(at: indexURL) }
    try prepare()
    try withMutationLock {
      let indexData = try encoder.encode(index)
      let pageData = try encoder.encode(page)
      let boardData = try encoder.encode(board)
      try pageData.write(to: pageURL(page.id), options: [.atomic])
      try boardData.write(to: boardURL, options: [.atomic])
      try indexData.write(to: indexURL, options: [.atomic])
    }
  }

  /// Deletion publishes the smaller catalog first. During the following file
  /// writes an older board may contain an invisible orphan, but no reader can
  /// discover a notebook whose pages are already gone.
  public func deleteWorkspaceBundle(
    index: WorkspaceIndex,
    board: BoardDocument,
    pageIDs: [UUID]
  ) throws {
    let notebookIDs = Set(index.notebooks.map(\.id))
    guard index.isValid,
      board.isValid(notebookIDs: notebookIDs)
    else { throw corruptFile(at: indexURL) }
    try prepare()
    try withMutationLock {
      try encoder.encode(index).write(to: indexURL, options: [.atomic])
      try encoder.encode(board).write(to: boardURL, options: [.atomic])
      for pageID in pageIDs {
        try? FileManager.default.removeItem(at: pageURL(pageID))
        try? FileManager.default.removeItem(at: previewURL(pageID))
        try? FileManager.default.removeItem(at: previewRevisionURL(pageID))
      }
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
      if FileManager.default.fileExists(atPath: indexURL.path) {
        let index = try decoder.decode(
          WorkspaceIndex.self,
          from: Data(contentsOf: indexURL)
        )
        guard index.isValid,
          index.notebooks.contains(where: { $0.pageIDs.contains(page.id) })
        else {
          throw CocoaError(
            .fileNoSuchFile,
            userInfo: [NSFilePathErrorKey: pageURL(page.id).path]
          )
        }
      }
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

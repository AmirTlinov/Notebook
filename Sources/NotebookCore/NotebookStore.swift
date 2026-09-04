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

  public var documentsURL: URL {
    root.appendingPathComponent("documents", isDirectory: true)
  }

  public var documentStatesURL: URL {
    root.appendingPathComponent("document-states", isDirectory: true)
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

  public func documentURL(_ id: UUID) -> URL {
    documentsURL.appendingPathComponent(id.uuidString.lowercased() + ".json")
  }

  public func documentStateURL(_ id: UUID) -> URL {
    documentStatesURL.appendingPathComponent(id.uuidString.lowercased() + ".json")
  }

  public func previewURL(_ id: UUID) -> URL {
    previewsURL.appendingPathComponent(id.uuidString.lowercased() + ".png")
  }

  public func previewInkURL(_ id: UUID) -> URL {
    previewsURL.appendingPathComponent(id.uuidString.lowercased() + ".ink.png")
  }

  public func previewVisionReceiptURL(_ id: UUID) -> URL {
    previewsURL.appendingPathComponent(id.uuidString.lowercased() + ".vision.json")
  }

  public func previewRegionsURL(_ id: UUID) -> URL {
    previewsURL.appendingPathComponent(
      id.uuidString.lowercased() + ".regions",
      isDirectory: true
    )
  }

  public func previewVisionHistoryURL(_ id: UUID) -> URL {
    previewsURL.appendingPathComponent(
      id.uuidString.lowercased() + ".vision-history",
      isDirectory: true
    )
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
      at: documentsURL,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: documentStatesURL,
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
      // Decoding format 1 performs the one-time semantic migration. Writing
      // the decoded owner here removes the replaced path immediately.
      try saveIndex(index)
      var pages: [UUID: PageDocument] = [:]
      for id in index.items.flatMap(\.pageIDs)
      where FileManager.default.fileExists(atPath: pageURL(id).path) {
        pages[id] = try loadPage(id)
      }
      return (index, pages)
    }
    let initial = WorkspaceIndex.initial(
      actor: actor,
      pageSize: pageSize,
      itemID: initialNotebookID,
      pageID: initialPageID
    )
    let board = BoardHierarchy.initial(
      rootBoardID: initial.index.rootBoardID,
      itemIDs: [initialNotebookID],
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
  ) throws -> BoardHierarchy {
    try prepare()
    if FileManager.default.fileExists(atPath: boardURL.path) {
      let data = try Data(contentsOf: boardURL)
      if let hierarchy = try? decoder.decode(BoardHierarchy.self, from: data),
        hierarchy.isValid(items: workspace.items)
      {
        return hierarchy
      }
      var legacy = try decoder.decode(BoardDocument.self, from: data)
      _ = legacy.reconcileItems(workspace.items.map(\.id), actor: actor)
      let hierarchy = BoardHierarchy(
        rootBoardID: workspace.rootBoardID,
        boards: [BoardNode(id: workspace.rootBoardID, board: legacy)],
        stamp: legacy.stamp
      )
      guard hierarchy.isValid(items: workspace.items) else {
        throw corruptFile(at: boardURL)
      }
      try saveBoard(hierarchy, items: workspace.items)
      return hierarchy
    }
    let board = BoardHierarchy.initial(
      rootBoardID: workspace.rootBoardID,
      itemIDs: workspace.items.map(\.id),
      actor: actor
    )
    try saveBoard(board, items: workspace.items)
    return board
  }

  private func storedFormat(in data: Data) -> Int? {
    struct FormatEnvelope: Decodable { let format: Int }
    return try? decoder.decode(FormatEnvelope.self, from: data).format
  }

  public func loadBoard(items: [WorkspaceItem]) throws -> BoardHierarchy {
    let board = try decoder.decode(
      BoardHierarchy.self,
      from: Data(contentsOf: boardURL)
    )
    guard board.isValid(items: items) else {
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

  public func loadDocument(_ id: UUID) throws -> DocumentDocument {
    let document = try decoder.decode(
      DocumentDocument.self,
      from: Data(contentsOf: documentURL(id))
    )
    guard document.id == id, document.isValid else {
      throw corruptFile(at: documentURL(id))
    }
    return document
  }

  public func loadDocumentState(_ id: UUID) throws -> DocumentStateJournal {
    let journal = try decoder.decode(
      DocumentStateJournal.self,
      from: Data(contentsOf: documentStateURL(id))
    )
    guard journal.id == id, journal.isValid else {
      throw corruptFile(at: documentStateURL(id))
    }
    return journal
  }

  public func loadAvailableDocuments(
    workspace: WorkspaceIndex
  ) throws -> (
    documents: [UUID: DocumentDocument],
    states: [UUID: DocumentStateJournal]
  ) {
    try prepare()
    var documents: [UUID: DocumentDocument] = [:]
    var states: [UUID: DocumentStateJournal] = [:]
    for item in workspace.items where item.kind == .document {
      if FileManager.default.fileExists(atPath: documentURL(item.id).path) {
        documents[item.id] = try loadDocument(item.id)
      }
      if FileManager.default.fileExists(atPath: documentStateURL(item.id).path) {
        states[item.id] = try loadDocumentState(item.id)
      }
    }
    return (documents, states)
  }

  public func saveIndex(_ index: WorkspaceIndex) throws {
    guard index.isValid else { throw corruptFile(at: indexURL) }
    try prepare()
    try withMutationLock {
      try encoder.encode(index).write(to: indexURL, options: [.atomic])
    }
  }

  /// Persists a page landing without putting filesystem latency on the hand.
  /// The caller may run this off the main actor. Under the store lock the
  /// newest catalog wins, and a newly created page is written before the first
  /// catalog that can expose it.
  @discardableResult
  public func saveWorkspaceSelection(
    index: WorkspaceIndex,
    createdPage: PageDocument?
  ) throws -> WorkspaceIndex {
    guard index.isValid else { throw corruptFile(at: indexURL) }
    if let createdPage {
      guard createdPage.isValid,
        index.items.contains(where: { $0.pageIDs.contains(createdPage.id) })
      else { throw corruptFile(at: indexURL) }
    }
    try prepare()
    return try withMutationLock {
      var resolved = index
      if FileManager.default.fileExists(atPath: indexURL.path) {
        let disk = try decoder.decode(
          WorkspaceIndex.self,
          from: Data(contentsOf: indexURL)
        )
        guard disk.isValid else { throw corruptFile(at: indexURL) }
        _ = resolved.merge(disk)
      }
      if let createdPage,
        resolved.items.contains(where: { $0.pageIDs.contains(createdPage.id) })
      {
        try writePage(createdPage)
      }
      try encoder.encode(resolved).write(to: indexURL, options: [.atomic])
      return resolved
    }
  }

  public func saveBoard(
    _ board: BoardHierarchy,
    items: [WorkspaceItem]
  ) throws {
    guard board.isValid(items: items) else {
      throw corruptFile(at: boardURL)
    }
    try prepare()
    try withMutationLock {
      try encoder.encode(board).write(to: boardURL, options: [.atomic])
    }
  }

  @discardableResult
  public func saveMergedBoard(
    _ board: BoardHierarchy,
    items: [WorkspaceItem]
  ) throws -> BoardHierarchy {
    guard board.isValid(items: items) else {
      throw corruptFile(at: boardURL)
    }
    try prepare()
    return try withMutationLock {
      var resolved = board
      if FileManager.default.fileExists(atPath: boardURL.path) {
        let disk = try decoder.decode(
          BoardHierarchy.self,
          from: Data(contentsOf: boardURL)
        )
        guard disk.isValid(items: items) else {
          throw corruptFile(at: boardURL)
        }
        _ = resolved.merge(disk, items: items)
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
    board: BoardHierarchy
  ) throws {
    guard index.isValid, page.isValid,
      board.isValid(items: index.items),
      index.items.flatMap(\.pageIDs).contains(page.id)
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

  /// A document is discoverable only after its source, state and placement
  /// exist. This is the same dependency-first publication as a notebook page.
  public func saveDocumentWorkspaceBundle(
    index: WorkspaceIndex,
    document: DocumentDocument,
    state: DocumentStateJournal,
    board: BoardHierarchy
  ) throws {
    guard index.isValid,
      document.isValid,
      state.isValid,
      document.id == state.id,
      index.items.contains(where: {
        $0.id == document.id && $0.kind == .document
      }),
      board.isValid(items: index.items)
    else { throw corruptFile(at: indexURL) }
    try prepare()
    try withMutationLock {
      try encoder.encode(document).write(
        to: documentURL(document.id),
        options: [.atomic]
      )
      try encoder.encode(state).write(
        to: documentStateURL(state.id),
        options: [.atomic]
      )
      try encoder.encode(board).write(to: boardURL, options: [.atomic])
      try encoder.encode(index).write(to: indexURL, options: [.atomic])
    }
  }

  /// A nested board becomes discoverable only after both its portal placement
  /// and its empty child owner exist. The hierarchy is written before the
  /// catalog that names the portal.
  public func saveBoardWorkspaceBundle(
    index: WorkspaceIndex,
    board: BoardHierarchy,
    boardID: UUID
  ) throws {
    guard index.isValid,
      index.items.contains(where: {
        $0.id == boardID && $0.kind == .board
      }),
      board.board(boardID) != nil,
      board.isValid(items: index.items)
    else { throw corruptFile(at: indexURL) }
    try prepare()
    try withMutationLock {
      try encoder.encode(board).write(to: boardURL, options: [.atomic])
      try encoder.encode(index).write(to: indexURL, options: [.atomic])
    }
  }

  /// Deletion publishes the smaller catalog first. During the following file
  /// write an older board may contain an invisible orphan, but no reader can
  /// discover an item whose content is already gone.
  public func deleteWorkspaceBundle(
    index: WorkspaceIndex,
    board: BoardHierarchy,
    pageIDs: [UUID],
    documentIDs: [UUID] = []
  ) throws {
    guard index.isValid,
      board.isValid(items: index.items)
    else { throw corruptFile(at: indexURL) }
    try prepare()
    try withMutationLock {
      try encoder.encode(index).write(to: indexURL, options: [.atomic])
      try encoder.encode(board).write(to: boardURL, options: [.atomic])
      removeContentFiles(pageIDs: pageIDs, documentIDs: documentIDs)
    }
  }

  /// Publishes a catalog received from the peer without exposing a reference
  /// whose content or board owner is absent. Creation writes the board before
  /// the catalog; deletion writes the catalog before the smaller board. A
  /// snapshot that both adds and removes items passes through a temporary
  /// union board, so either catalog remains readable during the hand-off.
  public func publishRemoteWorkspace(
    index: WorkspaceIndex,
    board: BoardHierarchy,
    actor: UUID
  ) throws {
    let incomingItemIDs = Set(index.items.map(\.id))
    guard index.isValid,
      Set(board.itemIDs) == incomingItemIDs,
      board.isValid(items: index.items)
    else {
      throw corruptFile(at: indexURL)
    }
    try prepare()
    try withMutationLock {
      let current = try decoder.decode(
        WorkspaceIndex.self,
        from: Data(contentsOf: indexURL)
      )
      guard current.isValid else { throw corruptFile(at: indexURL) }
      let currentItemIDs = Set(current.items.map(\.id))
      let added = incomingItemIDs.subtracting(currentItemIDs)
      let removed = currentItemIDs.subtracting(incomingItemIDs)

      if !added.isEmpty && !removed.isEmpty {
        var bridge = board
        let placed = bridge.placeMissingItems(
          current.items,
          actor: actor
        )
        guard (placed || currentItemIDs.isSubset(of: Set(bridge.itemIDs))),
          bridge.isValid(items: current.items + index.items.filter {
            !currentItemIDs.contains($0.id)
          })
        else { throw corruptFile(at: boardURL) }
        try encoder.encode(bridge).write(to: boardURL, options: [.atomic])
        try encoder.encode(index).write(to: indexURL, options: [.atomic])
        try encoder.encode(board).write(to: boardURL, options: [.atomic])
      } else if !removed.isEmpty {
        try encoder.encode(index).write(to: indexURL, options: [.atomic])
        try encoder.encode(board).write(to: boardURL, options: [.atomic])
      } else {
        try encoder.encode(board).write(to: boardURL, options: [.atomic])
        try encoder.encode(index).write(to: indexURL, options: [.atomic])
      }

      let incomingPageIDs = Set(index.items.flatMap(\.pageIDs))
      let removedPageIDs = current.items.flatMap(\.pageIDs).filter {
        !incomingPageIDs.contains($0)
      }
      let incomingDocumentIDs = Set(index.items.compactMap { item in
        item.kind == .document ? item.id : nil
      })
      let removedDocumentIDs = current.items.compactMap { item in
        item.kind == .document && !incomingDocumentIDs.contains(item.id)
          ? item.id
          : nil
      }
      removeContentFiles(
        pageIDs: removedPageIDs,
        documentIDs: removedDocumentIDs
      )
    }
  }

  public func saveDocument(_ document: DocumentDocument) throws {
    guard document.isValid else { throw corruptFile(at: documentURL(document.id)) }
    try prepare()
    try withMutationLock {
      try encoder.encode(document).write(
        to: documentURL(document.id),
        options: [.atomic]
      )
    }
  }

  @discardableResult
  public func saveMergedDocument(
    _ document: DocumentDocument
  ) throws -> DocumentDocument {
    guard document.isValid else { throw corruptFile(at: documentURL(document.id)) }
    try prepare()
    return try withMutationLock {
      let index = try decoder.decode(
        WorkspaceIndex.self,
        from: Data(contentsOf: indexURL)
      )
      guard index.isValid,
        index.items.contains(where: {
          $0.id == document.id && $0.kind == .document
        })
      else { throw CocoaError(.fileNoSuchFile) }
      var resolved = document
      let url = documentURL(document.id)
      if FileManager.default.fileExists(atPath: url.path) {
        let disk = try decoder.decode(DocumentDocument.self, from: Data(contentsOf: url))
        guard disk.id == document.id, disk.isValid else { throw corruptFile(at: url) }
        _ = resolved.merge(disk)
      }
      try encoder.encode(resolved).write(to: url, options: [.atomic])
      return resolved
    }
  }

  public func saveDocumentState(_ state: DocumentStateJournal) throws {
    guard state.isValid else { throw corruptFile(at: documentStateURL(state.id)) }
    try prepare()
    try withMutationLock {
      try encoder.encode(state).write(
        to: documentStateURL(state.id),
        options: [.atomic]
      )
    }
  }

  @discardableResult
  public func saveMergedDocumentState(
    _ state: DocumentStateJournal
  ) throws -> DocumentStateJournal {
    guard state.isValid else { throw corruptFile(at: documentStateURL(state.id)) }
    try prepare()
    return try withMutationLock {
      let index = try decoder.decode(
        WorkspaceIndex.self,
        from: Data(contentsOf: indexURL)
      )
      guard index.isValid,
        index.items.contains(where: {
          $0.id == state.id && $0.kind == .document
        })
      else { throw CocoaError(.fileNoSuchFile) }
      var resolved = state
      let url = documentStateURL(state.id)
      if FileManager.default.fileExists(atPath: url.path) {
        let disk = try decoder.decode(
          DocumentStateJournal.self,
          from: Data(contentsOf: url)
        )
        guard disk.id == state.id, disk.isValid else { throw corruptFile(at: url) }
        _ = resolved.merge(disk)
      }
      try encoder.encode(resolved).write(to: url, options: [.atomic])
      return resolved
    }
  }

  private func removeContentFiles(
    pageIDs: [UUID],
    documentIDs: [UUID]
  ) {
    for pageID in pageIDs {
      try? FileManager.default.removeItem(at: pageURL(pageID))
      try? FileManager.default.removeItem(at: previewURL(pageID))
      try? FileManager.default.removeItem(at: previewInkURL(pageID))
      try? FileManager.default.removeItem(at: previewVisionReceiptURL(pageID))
      try? FileManager.default.removeItem(at: previewRegionsURL(pageID))
      try? FileManager.default.removeItem(at: previewVisionHistoryURL(pageID))
    }
    for documentID in documentIDs {
      try? FileManager.default.removeItem(at: documentURL(documentID))
      try? FileManager.default.removeItem(at: documentStateURL(documentID))
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
          index.items.contains(where: { $0.pageIDs.contains(page.id) })
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

import Foundation
import Darwin

public enum NotebookStoreError: Error {
  case boardContainsContent(UUID)
  case workspaceChanged
}

public struct NotebookStore: Sendable {
  private static let lockName = ".mutation.lock"
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
    for url in [collaborationURL, collaborationActionsURL, renderRequestsURL, targetPreviewsURL, deviceReceiptsURL, runtimeURL] {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
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
    return try withMutationLock {
      if FileManager.default.fileExists(atPath: indexURL.path) {
        let index = try loadIndex()
        var pages: [UUID: PageDocument] = [:]
        for id in index.items.flatMap(\.pageIDs)
        where FileManager.default.fileExists(atPath: pageURL(id).path) {
          pages[id] = try loadPage(id)
        }
        return (index, pages)
      }
      let initial = WorkspaceIndex.initial(actor: actor, pageSize: pageSize,
        itemID: initialNotebookID, pageID: initialPageID)
      let board = BoardHierarchy.initial(rootBoardID: initial.index.rootBoardID,
        itemIDs: [initialNotebookID], actor: actor)
      _ = try publishWorkspace(index: initial.index, board: board, pages: [initial.page])
      return (initial.index, [initial.page.id: initial.page])
    }
  }

  public func loadIndex() throws -> WorkspaceIndex {
    let data = try Data(contentsOf: indexURL)
    guard let index = try? decoder.decode(WorkspaceIndex.self, from: data) else { throw corruptFile(at: indexURL) }
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
      _ = try publishWorkspace(index: index)
    }
  }

  /// Persists a page landing without putting filesystem latency on the hand.
  /// The caller may run this off the main actor. Under the store lock the
  /// selection and membership converge independently. A new sheet and its
  /// catalog entry use the same recoverable publication.
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
      try publishWorkspace(index: index, pages: createdPage.map { [$0] } ?? []).index
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
      let current = try loadIndex()
      return try publishWorkspace(index: current, board: board).board
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
      let data = try encoder.encode(presence)
      guard (try? Data(contentsOf: presenceURL)) != data else { return }
      try data.write(to: presenceURL, options: [.atomic])
    }
  }

  /// Creation merges durable catalog fields and publishes its page, placement
  /// and catalog entry in one recoverable transaction.
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
      _ = try publishWorkspace(index: index, board: board, pages: [page])
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
      _ = try publishWorkspace(index: index, board: board, documents: [document], states: [state])
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
      _ = try publishWorkspace(index: index, board: board)
    }
  }

  /// Deletion rechecks the considered membership and hidden board content,
  /// then publishes explicit removals with the smaller catalog and tree.
  @discardableResult
  public func deleteWorkspaceBundle(
    expectedIndex: WorkspaceIndex,
    index: WorkspaceIndex,
    board: BoardHierarchy,
    pageIDs: [UUID],
    documentIDs: [UUID] = []
  ) throws -> BoardHierarchy {
    guard index.isValid,
      board.isValid(items: index.items)
    else { throw corruptFile(at: indexURL) }
    try prepare()
    return try withMutationLock {
      let current = try loadIndex()
      guard current.rootBoardID == expectedIndex.rootBoardID,
        current.items == expectedIndex.items else { throw NotebookStoreError.workspaceChanged }
      let resolved = try loadBoard(items: current.items)
      let ink = FileManager.default.fileExists(atPath: spatialInkURL.path)
        ? try loadSpatialInk()
        : SpatialInkJournal(stamp: VersionStamp(counter: 0, actor: current.stamp.actor))
      let retained = Set(index.items.map(\.id))
      for item in current.items where item.kind == .board && !retained.contains(item.id) {
        guard resolved.isEmpty(item.id, spatialInk: ink) else {
          throw NotebookStoreError.boardContainsContent(item.id)
        }
      }
      let removedPages = Set(current.items.flatMap(\.pageIDs)).subtracting(index.items.flatMap(\.pageIDs))
      let removedDocuments = Set(current.items.filter { $0.kind == .document }.map(\.id))
        .subtracting(index.items.filter { $0.kind == .document }.map(\.id))
      guard removedPages == Set(pageIDs), removedDocuments == Set(documentIDs) else {
        throw corruptFile(at: indexURL)
      }
      return try publishWorkspace(index: index, board: board).board
    }
  }

  /// Receives catalog and tree through the same causal transaction as native
  /// creation. Dependencies must already exist; missing items are not deletions.
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
      _ = try publishWorkspace(index: index, board: board)
    }
  }

  /// The existing collaboration publisher owns every multi-file catalog cut.
  /// This method runs under its mutation lock, rereads the durable owners and
  /// prepares all dependencies before the one recoverable publication decision.
  private func publishWorkspace(index: WorkspaceIndex, board: BoardHierarchy? = nil,
    pages: [PageDocument] = [], documents: [DocumentDocument] = [], states: [DocumentStateJournal] = []) throws
    -> (index: WorkspaceIndex, board: BoardHierarchy) {
    let current = FileManager.default.fileExists(atPath: indexURL.path) ? try loadIndex() : nil
    let resolved = try current.map { try $0.merging(index) } ?? index
    let currentBoard = try current.map { try loadBoard(items: $0.items) }
    guard var resolvedBoard = currentBoard ?? board else { throw corruptFile(at: boardURL) }
    if let board { resolvedBoard = try resolvedBoard.merging(board, items: resolved.items) }
    guard resolved.isValid, resolvedBoard.isValid(items: resolved.items) else { throw corruptFile(at: boardURL) }
    var writes: [String: JSONValue] = [:]
    if resolved != current { writes["workspace.json"] = try .encode(resolved) }
    if resolvedBoard != currentBoard { writes["board.json"] = try .encode(resolvedBoard) }
    let livePages = Set(resolved.items.flatMap(\.pageIDs))
    let liveDocuments = Set(resolved.items.filter { $0.kind == .document }.map(\.id))
    for var page in pages where livePages.contains(page.id) {
      if FileManager.default.fileExists(atPath: pageURL(page.id).path) {
        let old = try loadPage(page.id)
        guard old.size == page.size else { throw corruptFile(at: pageURL(page.id)) }
        _ = page.merge(old)
        if page == old { continue }
      }
      writes["pages/\(page.id.uuidString.lowercased()).json"] = try .encode(page)
    }
    for var document in documents where liveDocuments.contains(document.id) {
      if FileManager.default.fileExists(atPath: documentURL(document.id).path) {
        let old = try loadDocument(document.id)
        guard old.paperSize == document.paperSize else { throw corruptFile(at: documentURL(document.id)) }
        _ = document.merge(old)
        if document == old { continue }
      }
      writes["documents/\(document.id.uuidString.lowercased()).json"] = try .encode(document)
    }
    for var state in states where liveDocuments.contains(state.id) {
      if FileManager.default.fileExists(atPath: documentStateURL(state.id).path) {
        let old = try loadDocumentState(state.id)
        _ = state.merge(old)
        if state == old { continue }
      }
      writes["document-states/\(state.id.uuidString.lowercased()).json"] = try .encode(state)
    }
    let dependencies = livePages.map { "pages/\($0.uuidString.lowercased()).json" }
      + liveDocuments.flatMap { ["documents/\($0.uuidString.lowercased()).json", "document-states/\($0.uuidString.lowercased()).json"] }
    guard dependencies.allSatisfy({ writes[$0] != nil || FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }) else {
      throw CollaborationError("dependency_missing", "Публикация каталога требует содержание всех доступных владельцев.")
    }
    let removedPages = Set(current?.items.flatMap(\.pageIDs) ?? []).subtracting(livePages)
    let removedDocuments = Set(current?.items.filter { $0.kind == .document }.map(\.id) ?? []).subtracting(liveDocuments)
    let removals = removedPages.map { "pages/\($0.uuidString.lowercased()).json" }
      + removedDocuments.flatMap { ["documents/\($0.uuidString.lowercased()).json", "document-states/\($0.uuidString.lowercased()).json"] }
    try publishCollaboration(writes: writes, removals: removals)
    removePagePreviews(Array(removedPages))
    return (resolved, resolvedBoard)
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

  private func removePagePreviews(_ pageIDs: [UUID]) {
    for pageID in pageIDs {
      for url in [previewURL(pageID), previewInkURL(pageID), previewVisionReceiptURL(pageID),
        previewRegionsURL(pageID), previewVisionHistoryURL(pageID)] {
        try? FileManager.default.removeItem(at: url)
      }
    }
  }

  public func migratePageInk(page: PageDocument, data: Data) throws -> PageDocument {
    try withMutationLock {
      var current = try loadPage(page.id)
      guard current.drawingData == page.drawingData else { return current }
      guard PageInkDrawing.needsMigration(current.drawingData) else { return current }
      let backup = root.appendingPathComponent("migrations/before-ink-v1/pages",isDirectory:true)
      try FileManager.default.createDirectory(at:backup,withIntermediateDirectories:true)
      let original = backup.appendingPathComponent(page.id.uuidString.lowercased() + ".json")
      if !FileManager.default.fileExists(atPath:original.path) {
        try Data(contentsOf:pageURL(page.id)).write(to:original,options:.atomic)
      }
      try current.migrateInkRepresentation(data)
      try writePage(current)
      return current
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
        if resolved == disk { return resolved }
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

  func withMutationLock<T>(_ operation: () throws -> T) throws -> T {
    // The kernel owns exclusion and releases it when a process exits. Reading
    // a completed cut leaves directory entries intact, so a file watcher sees
    // content publication rather than the act of observation itself.
    let descriptor = open(root.appendingPathComponent(Self.lockName).path,O_CREAT | O_RDWR,0o600)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
    defer { close(descriptor) }
    let deadline = ProcessInfo.processInfo.systemUptime + 4
    while flock(descriptor,LOCK_EX | LOCK_NB) != 0 {
      try Task.checkCancellation()
      guard errno == EWOULDBLOCK || errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
      guard ProcessInfo.processInfo.systemUptime < deadline else {
        throw CollaborationError("publication_pending", "Завершается публикация предыдущего хода. Повторите чтение.")
      }
      Thread.sleep(forTimeInterval:0.005)
    }
    defer { flock(descriptor,LOCK_UN) }
    try recoverCollaborationTransaction()
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

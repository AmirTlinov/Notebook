import Foundation
import Darwin

public enum NotebookStoreError: Error {
  case boardContainsContent(UUID)
  case workspaceChanged
}

public struct NotebookStore: Sendable {
  let storageFault: (@Sendable (NotebookStorageFault) throws -> Void)?

  public let root: URL

  public init(root: URL) {
    self.root = root
    storageFault = nil
  }

  init(root: URL, storageFault: @escaping @Sendable (NotebookStorageFault) throws -> Void) {
    self.root = root; self.storageFault = storageFault
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
    try prepareDatabase()
    for url in [previewsURL, targetPreviewsURL] {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
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
      if (try hasStoredValue(at: indexURL)) {
        let index = try loadIndex()
        var pages: [UUID: PageDocument] = [:]
        if let id = index.selectedPageID, try hasStoredValue(pageFile(id)) {
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
    let data = try storedData(at: indexURL)
    guard var index = try? decoder.decode(WorkspaceIndex.self, from: data) else { throw corruptFile(at: indexURL) }
    guard index.isValid else { throw corruptFile(at: indexURL) }
    if let presence = try? loadPresence(), let id = presence.selectedItemID {
      _ = index.selectItem(id, pageID: presence.notebookPageID, actor: index.stamp.actor)
    }
    return index
  }

  public func loadOrCreateBoard(workspace: WorkspaceIndex, actor: UUID) throws -> BoardHierarchy {
    if try hasStoredValue("board.json") { return try loadBoard(items: workspace.items) }
    let board = BoardHierarchy.initial(rootBoardID: workspace.rootBoardID,
      itemIDs: workspace.items.map(\.id), actor: actor)
    try saveBoard(board, items: workspace.items)
    return board
  }

  public func loadBoard(items: [WorkspaceItem]) throws -> BoardHierarchy {
    let board = try decoder.decode(
      BoardHierarchy.self,
      from: storedData(at: boardURL)
    )
    guard board.isValid(items: items) else {
      throw corruptFile(at: boardURL)
    }
    return board
  }

  public func loadOrCreateSpatialInk(actor: UUID) throws -> SpatialInkJournal {
    try prepare()
    if (try hasStoredValue(at: spatialInkURL)) {
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
      from: storedData(at: spatialInkURL)
    )
    guard journal.isValid else { throw corruptFile(at: spatialInkURL) }
    return journal
  }

  public func loadPresence() throws -> SessionPresence {
    let presence = try decoder.decode(
      SessionPresence.self,
      from: storedData(at: presenceURL)
    )
    guard presence.isValid else { throw corruptFile(at: presenceURL) }
    return presence
  }

  public func loadPage(_ id: UUID) throws -> PageDocument {
    let page = try decoder.decode(
      PageDocument.self,
      from: storedData(at: pageURL(id))
    )
    guard page.id == id, page.isValid else {
      throw corruptFile(at: pageURL(id))
    }
    return page
  }

  public func loadDocument(_ id: UUID) throws -> DocumentDocument {
    let document = try decoder.decode(
      DocumentDocument.self,
      from: storedData(at: documentURL(id))
    )
    guard document.id == id, document.isValid else {
      throw corruptFile(at: documentURL(id))
    }
    return document
  }

  public func loadDocumentState(_ id: UUID) throws -> DocumentStateJournal {
    let journal = try decoder.decode(
      DocumentStateJournal.self,
      from: storedData(at: documentStateURL(id))
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
      if (try hasStoredValue(at: documentURL(item.id))) {
        documents[item.id] = try loadDocument(item.id)
      }
      if (try hasStoredValue(at: documentStateURL(item.id))) {
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
      if let createdPage { _ = try publishWorkspace(index: index, pages: [createdPage]) }
      if let presence = try? loadPresence() {
        try savePresence(presence.selecting(itemID: index.selectedItemID, pageID: index.selectedPageID))
      }
      return index
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
      try publishCollaboration(writes: ["board.json": try .encode(board)])
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
      try publishCollaboration(writes: ["spatial-ink.json": try .encode(journal)])
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
      if (try hasStoredValue(at: spatialInkURL)) {
        let disk = try decoder.decode(
          SpatialInkJournal.self,
          from: storedData(at: spatialInkURL)
        )
        guard disk.isValid else { throw corruptFile(at: spatialInkURL) }
        _ = resolved.merge(disk)
      }
      try publishCollaboration(writes: ["spatial-ink.json": try .encode(resolved)])
      return resolved
    }
  }

  public func savePresence(_ presence: SessionPresence) throws {
    guard presence.isValid else { throw corruptFile(at: presenceURL) }
    try prepare()
    try withMutationLock {
      try publishCollaboration(writes: ["last-context.json": try .encode(presence)])
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
      let ink = (try hasStoredValue(at: spatialInkURL))
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
    let current = (try hasStoredValue(at: indexURL)) ? try loadIndex() : nil
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
      if (try hasStoredValue(at: pageURL(page.id))) {
        let old = try loadPage(page.id)
        guard old.size == page.size else { throw corruptFile(at: pageURL(page.id)) }
        _ = page.merge(old)
        if page == old { continue }
      }
      writes["pages/\(page.id.uuidString.lowercased()).json"] = try .encode(page)
    }
    for var document in documents where liveDocuments.contains(document.id) {
      if (try hasStoredValue(at: documentURL(document.id))) {
        let old = try loadDocument(document.id)
        guard old.paperSize == document.paperSize else { throw corruptFile(at: documentURL(document.id)) }
        _ = document.merge(old)
        if document == old { continue }
      }
      writes["documents/\(document.id.uuidString.lowercased()).json"] = try .encode(document)
    }
    for var state in states where liveDocuments.contains(state.id) {
      if (try hasStoredValue(at: documentStateURL(state.id))) {
        let old = try loadDocumentState(state.id)
        _ = state.merge(old)
        if state == old { continue }
      }
      writes["document-states/\(state.id.uuidString.lowercased()).json"] = try .encode(state)
    }
    let dependencies = livePages.map { "pages/\($0.uuidString.lowercased()).json" }
      + liveDocuments.flatMap { ["documents/\($0.uuidString.lowercased()).json", "document-states/\($0.uuidString.lowercased()).json"] }
    guard try dependencies.allSatisfy({ try writes[$0] != nil || hasStoredValue(at: root.appendingPathComponent($0)) }) else {
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
      try publishCollaboration(writes: [documentFile(document.id): try .encode(document)])
    }
  }

  @discardableResult
  public func saveMergedDocument(
    _ document: DocumentDocument
  ) throws -> DocumentDocument {
    guard document.isValid else { throw corruptFile(at: documentURL(document.id)) }
    try prepare()
    return try withMutationLock {
      guard try readItemHeader(document.id)?.kind == .document else { throw CocoaError(.fileNoSuchFile) }
      var resolved = document
      let url = documentURL(document.id)
      if (try hasStoredValue(at: url)) {
        let disk = try decoder.decode(DocumentDocument.self, from: storedData(at: url))
        guard disk.id == document.id, disk.isValid else { throw corruptFile(at: url) }
        _ = resolved.merge(disk)
      }
      try publishCollaboration(writes: [logicalAddress(url): try .encode(resolved)])
      return resolved
    }
  }

  public func saveDocumentState(_ state: DocumentStateJournal) throws {
    guard state.isValid else { throw corruptFile(at: documentStateURL(state.id)) }
    try prepare()
    try withMutationLock {
      try publishCollaboration(writes: [stateFile(state.id): try .encode(state)])
    }
  }

  @discardableResult
  public func saveMergedDocumentState(
    _ state: DocumentStateJournal
  ) throws -> DocumentStateJournal {
    guard state.isValid else { throw corruptFile(at: documentStateURL(state.id)) }
    try prepare()
    return try withMutationLock {
      guard try readItemHeader(state.id)?.kind == .document else { throw CocoaError(.fileNoSuchFile) }
      var resolved = state
      let url = documentStateURL(state.id)
      if (try hasStoredValue(at: url)) {
        let disk = try decoder.decode(
          DocumentStateJournal.self,
          from: storedData(at: url)
        )
        guard disk.id == state.id, disk.isValid else { throw corruptFile(at: url) }
        _ = resolved.merge(disk)
      }
      try publishCollaboration(writes: [logicalAddress(url): try .encode(resolved)])
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
      if try hasStoredValue("workspace.json"), try ownerItemID(ofPage: page.id) == nil {
        throw CocoaError(.fileNoSuchFile)
      }
      var resolved = page
      let url = pageURL(page.id)
      if (try hasStoredValue(at: url)) {
        let disk = try decoder.decode(
          PageDocument.self,
          from: storedData(at: url)
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
    try publishCollaboration(writes: [pageFile(page.id): try .encode(page)])
  }

  private func corruptFile(at url: URL) -> CocoaError {
    CocoaError(
      .fileReadCorruptFile,
      userInfo: [NSFilePathErrorKey: url.path]
    )
  }

  func withMutationLock<T>(_ operation: () throws -> T) throws -> T {
    try commandTransaction(operation)
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

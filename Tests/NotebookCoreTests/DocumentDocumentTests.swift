import Foundation
import Testing
@testable import NotebookCore

private let legacyActor = UUID(
  uuidString: "00000000-0000-4000-8000-000000000001"
)!
private let legacyItemID = UUID(
  uuidString: "00000000-0000-4000-8000-000000000002"
)!
private let legacyPageID = UUID(
  uuidString: "00000000-0000-4000-8000-000000000003"
)!

@Test("Старый каталог тетрадей становится единым каталогом рабочих элементов")
func legacyWorkspaceDecodesAsVersionTwo() throws {
  let data = try JSONSerialization.data(withJSONObject: [
    "format": 1,
    "notebooks": [[
      "id": legacyItemID.uuidString,
      "title": "Старая тетрадь",
      "pageIDs": [legacyPageID.uuidString]
    ]],
    "selectedNotebookID": legacyItemID.uuidString,
    "selectedPageID": legacyPageID.uuidString,
    "stamp": ["counter": 4, "actor": legacyActor.uuidString]
  ])

  let workspace = try JSONDecoder().decode(WorkspaceIndex.self, from: data)

  #expect(workspace.format == WorkspaceIndex.formatVersion)
  #expect(workspace.items == [
    .notebook(
      id: legacyItemID,
      title: "Старая тетрадь",
      pageIDs: [legacyPageID]
    )
  ])
  #expect(workspace.selectedItemID == legacyItemID)
  #expect(workspace.selectedPageID == legacyPageID)

  let encoded = try JSONEncoder().encode(workspace)
  let object = try #require(
    JSONSerialization.jsonObject(with: encoded) as? [String: Any]
  )
  #expect(object["format"] as? Int == 2)
  #expect(object["items"] != nil)
  #expect(object["notebooks"] == nil)
}

@Test("Старая доска и присутствие получают нового владельца itemID")
func legacySpatialOwnersDecodeAsVersionTwo() throws {
  let stamp: [String: Any] = [
    "counter": 2,
    "actor": legacyActor.uuidString
  ]
  let world: [String: Any] = [
    "tileX": 0,
    "tileY": 0,
    "localX": 12.0,
    "localY": 34.0
  ]
  let boardData = try JSONSerialization.data(withJSONObject: [
    "format": 1,
    "freeNotebooks": [[
      "notebookID": legacyItemID.uuidString,
      "center": world,
      "zIndex": 1,
      "stamp": stamp
    ]],
    "stacks": [],
    "elements": [],
    "stamp": stamp
  ])
  let presenceData = try JSONSerialization.data(withJSONObject: [
    "format": 1,
    "mode": "page",
    "camera": ["center": world, "scale": 0.7],
    "viewport": ["x": 834.0, "y": 1_194.0],
    "focusedNotebookID": legacyItemID.uuidString,
    "openProgress": 1.0
  ])

  let board = try JSONDecoder().decode(BoardDocument.self, from: boardData)
  let presence = try JSONDecoder().decode(
    SessionPresence.self,
    from: presenceData
  )

  #expect(board.format == BoardDocument.formatVersion)
  #expect(board.freeItems.map(\.itemID) == [legacyItemID])
  #expect(presence.format == SessionPresence.formatVersion)
  #expect(presence.focusedItemID == legacyItemID)
  #expect(presence.documentPageIndex == 0)
}

@Test("Присутствие до пагинации документа открывается на первом листе")
func versionTwoPresenceDefaultsToFirstDocumentPage() throws {
  let data = try JSONSerialization.data(withJSONObject: [
    "format": 2,
    "mode": "document",
    "camera": [
      "center": [
        "tileX": 0,
        "tileY": 0,
        "localX": 0.0,
        "localY": 0.0
      ],
      "scale": 1.0
    ],
    "viewport": ["x": 834.0, "y": 1_194.0],
    "focusedItemID": legacyItemID.uuidString,
    "openProgress": 1.0
  ])

  let presence = try JSONDecoder().decode(SessionPresence.self, from: data)

  #expect(presence.format == SessionPresence.formatVersion)
  #expect(presence.documentPageIndex == 0)
}

@Test("Старая доска возвращает отсутствующие тетради из каталога")
func legacyBoardRestoresMissingCatalogItems() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = NotebookStore(root: root)
  try store.prepare()

  let itemIDs = (0..<6).map { _ in UUID() }
  let pageIDs = (0..<6).map { _ in UUID() }
  let workspace = WorkspaceIndex(
    items: zip(itemIDs, pageIDs).map { itemID, pageID in
      .notebook(id: itemID, title: "", pageIDs: [pageID])
    },
    selectedItemID: itemIDs[5],
    selectedPageID: pageIDs[5],
    stamp: VersionStamp(counter: 6, actor: legacyActor)
  )
  let world: [String: Any] = [
    "tileX": 0,
    "tileY": 0,
    "localX": 0.0,
    "localY": 0.0
  ]
  let stamp: [String: Any] = [
    "counter": 0,
    "actor": legacyActor.uuidString
  ]
  let legacyBoard = try JSONSerialization.data(withJSONObject: [
    "format": 1,
    "freeNotebooks": [[
      "notebookID": itemIDs[0].uuidString,
      "center": world,
      "zIndex": 0,
      "stamp": stamp
    ]],
    "stacks": [],
    "elements": [],
    "stamp": stamp
  ])
  try legacyBoard.write(to: store.boardURL, options: .atomic)

  let board = try store.loadOrCreateBoard(
    workspace: workspace,
    actor: legacyActor
  )

  #expect(Set(board.itemIDs) == Set(itemIDs))
  #expect(board.placement(of: itemIDs[0])?.center == .zero)
  let persisted = try JSONSerialization.jsonObject(
    with: Data(contentsOf: store.boardURL)
  ) as? [String: Any]
  #expect(persisted?["format"] as? Int == BoardDocument.formatVersion)
  #expect(persisted?["freeItems"] != nil)
  #expect(persisted?["freeNotebooks"] == nil)
}

@Test("Незавершённый сетевой пакет открывает каталог и ждёт содержимое")
func incompleteNetworkBundleCanResumeAfterLaunch() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = NotebookStore(root: root)
  let first = try store.loadOrCreate(
    actor: legacyActor,
    pageSize: PageSize(width: 834, height: 1_194),
    initialNotebookID: legacyItemID,
    initialPageID: legacyPageID
  )
  var workspace = first.0
  let missingCreation = workspace.createNotebook(
    title: "Ждёт сеть",
    actor: legacyActor,
    pageSize: first.1[legacyPageID]!.size
  )
  let missing = try #require(missingCreation)
  try store.saveIndex(workspace)

  let reopened = try store.loadOrCreate(
    actor: UUID(),
    pageSize: first.1[legacyPageID]!.size
  )

  #expect(reopened.0 == workspace)
  #expect(reopened.1[legacyPageID] != nil)
  #expect(reopened.1[missing.page.id] == nil)
}

@Test("Документ выбирается без тетрадного листа")
func documentSelectionHasNoNotebookPage() throws {
  let initial = WorkspaceIndex.initial(
    actor: legacyActor,
    pageSize: PageSize(width: 834, height: 1_194),
    itemID: legacyItemID,
    pageID: legacyPageID
  )
  var workspace = initial.index
  let creation = workspace.createDocument(
    title: "Доказательство",
    actor: legacyActor
  )
  let document = try #require(creation)

  #expect(document.kind == .document)
  #expect(workspace.selectedItemID == document.id)
  #expect(workspace.selectedPageID == nil)
  #expect(workspace.isValid)
  #expect(workspace.turnPage(
    by: 1,
    actor: legacyActor,
    pageSize: initial.page.size
  ) == nil)
}

@Test("Формат бумаги хранит настоящие пропорции A4 и Letter")
func documentPaperSizesHavePhysicalDimensions() {
  #expect(abs(DocumentPaperSize.a4.widthPoints - 595.275590551) < 0.000_001)
  #expect(abs(DocumentPaperSize.a4.heightPoints - 841.88976378) < 0.000_001)
  #expect(abs(DocumentPaperSize.a4.marginPoints - 70.8661417323) < 0.000_001)
  #expect(DocumentPaperSize.letter.widthPoints == 612)
  #expect(DocumentPaperSize.letter.heightPoints == 792)
  #expect(DocumentPaperSize.letter.marginPoints == 72)
  #expect(DocumentPaperSize.a4.heightPoints / DocumentPaperSize.a4.widthPoints > 1.41)
  #expect(DocumentPaperSize.letter.heightPoints / DocumentPaperSize.letter.widthPoints < 1.30)
}

@Test("Старый бесконечный документ мигрирует в A4")
func legacyDocumentDecodesAsPaginatedA4() throws {
  let current = DocumentDocument(
    id: legacyItemID,
    actor: legacyActor,
    paperSize: .letter,
    blocks: [.markdown(id: "body", source: "# Старый документ")]
  )
  let encoded = try JSONEncoder().encode(current)
  var object = try #require(
    JSONSerialization.jsonObject(with: encoded) as? [String: Any]
  )
  object["format"] = 1
  object["paperSize"] = nil

  let legacy = try JSONSerialization.data(withJSONObject: object)
  let decoded = try JSONDecoder().decode(DocumentDocument.self, from: legacy)

  #expect(decoded.format == DocumentDocument.formatVersion)
  #expect(decoded.paperSize == .a4)
  #expect(decoded.blocks == current.blocks)
  let migrated = try #require(
    JSONSerialization.jsonObject(
      with: JSONEncoder().encode(decoded)
    ) as? [String: Any]
  )
  #expect(migrated["format"] as? Int == 2)
  #expect(migrated["paperSize"] as? String == "a4")
}

@Test("Новый формат всегда называет размер бумаги")
func currentDocumentRequiresPaperSize() throws {
  let current = DocumentDocument(id: legacyItemID, actor: legacyActor)
  var object = try #require(
    JSONSerialization.jsonObject(
      with: JSONEncoder().encode(current)
    ) as? [String: Any]
  )
  object["paperSize"] = nil
  let malformed = try JSONSerialization.data(withJSONObject: object)

  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(DocumentDocument.self, from: malformed)
  }
}

@Test("Размер бумаги выбирается при создании и не меняется с содержимым")
func documentPaperSizeIsCreationOwned() {
  let id = UUID()
  var a4 = DocumentDocument(id: id, actor: legacyActor, paperSize: .a4)
  var letter = DocumentDocument(id: id, actor: legacyActor, paperSize: .letter)
  let advanced = letter.replaceBlockSource(
    id: "body",
    source: "Новая версия",
    actor: UUID()
  )
  #expect(advanced)

  let merged = a4.merge(letter)
  #expect(!merged)
  #expect(a4.paperSize == .a4)
  #expect(a4.blocks.first?.source == "")
}

@Test("Исходник документа и состояние интерактива сходятся независимо")
func documentSourceAndInteractiveStateMergeIndependently() {
  let documentID = UUID()
  let stateActor = UUID(
    uuidString: "00000000-0000-4000-8000-000000000010"
  )!
  let contentActor = UUID(
    uuidString: "00000000-0000-4000-8000-000000000020"
  )!
  var source = DocumentDocument(
    id: documentID,
    actor: legacyActor,
    blocks: [
      .markdown(id: "body", source: "# Черновик"),
      .interactive(id: "counter", html: "<button>0</button>")
    ]
  )
  var remoteSource = source
  var state = DocumentStateJournal(id: documentID, actor: legacyActor)
  var remoteState = state

  let sourceChanged = remoteSource.replaceBlockSource(
    id: "body",
    source: "# Чистовой текст",
    actor: contentActor
  )
  let stateChanged = remoteState.commit(
    blockID: "counter",
    value: .object(["count": .number(3)]),
    actor: stateActor
  )

  let sourceMerged = source.merge(remoteSource)
  let stateMerged = state.merge(remoteState)
  #expect(sourceChanged)
  #expect(stateChanged)
  #expect(sourceMerged)
  #expect(stateMerged)
  #expect(source.blocks.first?.source == "# Чистовой текст")
  #expect(state.value(for: "counter") == .object(["count": .number(3)]))
}

@Test("Редактор спокойно отклоняет исходник больше документного контракта")
func oversizedDocumentEditDoesNotTrap() {
  var document = DocumentDocument(id: UUID(), actor: legacyActor)
  let original = document

  let changed = document.replaceBlockSource(
    id: "body",
    source: String(
      repeating: "a",
      count: DocumentBlock.maximumSourceLength + 1
    ),
    actor: legacyActor
  )

  #expect(!changed)
  #expect(document == original)
}

@Test("Состояние отклоняет block ID длиннее общего Swift и MCP контракта")
func oversizedDocumentStateIDDoesNotEnterJournal() {
  var journal = DocumentStateJournal(id: UUID(), actor: legacyActor)

  let changed = journal.commit(
    blockID: String(repeating: "a", count: 121),
    value: .number(1),
    actor: legacyActor
  )

  #expect(!changed)
  #expect(journal.records.isEmpty)
  #expect(journal.stamp.counter == 0)
}

@Test("Хранилище публикует и удаляет один полный документный пакет")
func storePublishesAndDeletesDocumentBundle() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = NotebookStore(root: root)
  let loaded = try store.loadOrCreate(
    actor: legacyActor,
    pageSize: PageSize(width: 834, height: 1_194),
    initialNotebookID: legacyItemID,
    initialPageID: legacyPageID
  )
  var workspace = loaded.0
  var board = try store.loadOrCreateBoard(
    workspace: workspace,
    actor: legacyActor
  )
  let creation = workspace.createDocument(title: "Отчёт", actor: legacyActor)
  let item = try #require(creation)
  let document = DocumentDocument(
    id: item.id,
    actor: legacyActor,
    blocks: [.markdown(id: "body", source: "# Отчёт")]
  )
  let state = DocumentStateJournal(id: item.id, actor: legacyActor)
  let added = board.addItem(item.id, near: .zero, actor: legacyActor)
  #expect(added)

  try store.saveDocumentWorkspaceBundle(
    index: workspace,
    document: document,
    state: state,
    board: board
  )

  #expect(try store.loadDocument(item.id) == document)
  #expect(try store.loadDocumentState(item.id) == state)
  #expect(FileManager.default.fileExists(atPath: store.documentURL(item.id).path))

  let deletion = workspace.deleteItem(item.id, actor: legacyActor)
  let removed = try #require(deletion)
  let removedFromBoard = board.deleteItem(item.id, actor: legacyActor)
  #expect(removedFromBoard)
  try store.deleteWorkspaceBundle(
    index: workspace,
    board: board,
    pageIDs: removed.pageIDs,
    documentIDs: [removed.id]
  )

  #expect(!FileManager.default.fileExists(atPath: store.documentURL(item.id).path))
  #expect(!FileManager.default.fileExists(
    atPath: store.documentStateURL(item.id).path
  ))
}

@Test("Сетевой снимок одновременно добавляет и удаляет без осиротевших файлов")
func remoteMixedCatalogPublicationCleansReplacedContent() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = NotebookStore(root: root)
  let loaded = try store.loadOrCreate(
    actor: legacyActor,
    pageSize: PageSize(width: 834, height: 1_194),
    initialNotebookID: legacyItemID,
    initialPageID: legacyPageID
  )
  var current = loaded.0
  var currentBoard = try store.loadOrCreateBoard(
    workspace: current,
    actor: legacyActor
  )
  let documentCreation = current.createDocument(
    title: "Старый документ",
    actor: legacyActor
  )
  let documentItem = try #require(documentCreation)
  let addedDocument = currentBoard.addItem(
    documentItem.id,
    near: WorldPoint(x: 900, y: 0),
    actor: legacyActor
  )
  #expect(addedDocument)
  let oldDocument = DocumentDocument(id: documentItem.id, actor: legacyActor)
  let oldState = DocumentStateJournal(id: documentItem.id, actor: legacyActor)
  try store.saveDocumentWorkspaceBundle(
    index: current,
    document: oldDocument,
    state: oldState,
    board: currentBoard
  )

  var incoming = current
  var incomingBoard = currentBoard
  let deletion = incoming.deleteItem(documentItem.id, actor: legacyActor)
  let removed = try #require(deletion)
  let deletedFromBoard = incomingBoard.deleteItem(
    documentItem.id,
    actor: legacyActor
  )
  #expect(deletedFromBoard)
  let notebookCreation = incoming.createNotebook(
    title: "Новая тетрадь",
    actor: legacyActor,
    pageSize: loaded.1[legacyPageID]!.size
  )
  let newNotebook = try #require(notebookCreation)
  let addedNotebook = incomingBoard.addItem(
    newNotebook.item.id,
    near: WorldPoint(x: -900, y: 0),
    actor: legacyActor
  )
  #expect(addedNotebook)
  try store.savePage(newNotebook.page)

  try store.publishRemoteWorkspace(
    index: incoming,
    board: incomingBoard,
    actor: legacyActor
  )

  #expect(removed.id == documentItem.id)
  #expect(try store.loadIndex() == incoming)
  #expect(Set(try store.loadBoard(
    itemIDs: Set(incoming.items.map(\.id))
  ).itemIDs) == Set(incoming.items.map(\.id)))
  #expect(!FileManager.default.fileExists(
    atPath: store.documentURL(documentItem.id).path
  ))
  #expect(!FileManager.default.fileExists(
    atPath: store.documentStateURL(documentItem.id).path
  ))
}

@Test("Квитанция текущего документа связывает PNG с исходником и состоянием")
func currentViewReceiptOwnsDocumentRevisions() {
  let documentID = UUID()
  let workspace = WorkspaceIndex(
    items: [.document(id: documentID, title: "Документ")],
    selectedItemID: documentID,
    selectedPageID: nil,
    stamp: VersionStamp(counter: 0, actor: legacyActor)
  )
  let board = BoardDocument.initial(itemIDs: [documentID], actor: legacyActor)
  let ink = SpatialInkJournal(
    stamp: VersionStamp(counter: 0, actor: legacyActor)
  )
  let document = DocumentDocument(id: documentID, actor: legacyActor)
  let state = DocumentStateJournal(id: documentID, actor: legacyActor)
  let presence = SessionPresence(
    mode: .document,
    camera: SpatialCamera(scale: 0.7),
    viewport: SpatialPoint(x: 834, y: 1_194),
    focusedItemID: documentID,
    openProgress: 1
  )
  let receipt = CurrentViewReceipt(
    workspace: workspace,
    board: board,
    spatialInk: ink,
    presence: presence,
    renderViewport: presence.viewport,
    page: nil,
    document: document,
    documentState: state,
    pngSHA256: String(repeating: "a", count: 64)
  )

  #expect(receipt.isValid)
  #expect(receipt.document?.documentID == documentID)
  #expect(receipt.document?.contentStamp == document.contentStamp)
  #expect(receipt.document?.stateStamp == state.stamp)
}

@Test("Wire переносит исходник и состояние документа как разных владельцев")
func documentWireMessagesRoundTrip() throws {
  let id = UUID()
  let document = DocumentDocument(id: id, actor: legacyActor)
  var state = DocumentStateJournal(id: id, actor: legacyActor)
  let committed = state.commit(
    blockID: "counter",
    value: .number(1),
    actor: legacyActor
  )
  #expect(committed)
  let encoder = JSONEncoder()
  let decoder = JSONDecoder()

  for message in [WireMessage.document(document), .documentState(state)] {
    let decoded = try decoder.decode(
      WireMessage.self,
      from: encoder.encode(message)
    )
    #expect(decoded == message)
  }
}

@Test("Mac просит страницу документа, не становясь владельцем presence")
func documentPageSelectionRequestRoundTrips() throws {
  let request = DocumentPageSelectionRequest(
    documentID: UUID(),
    pageIndex: 7
  )
  let message = WireMessage.documentPageSelection(request)
  let encoded = try JSONEncoder().encode(message)
  let decoded = try JSONDecoder().decode(WireMessage.self, from: encoded)

  #expect(request.isValid)
  #expect(decoded == message)
  #expect(
    !DocumentPageSelectionRequest(
      documentID: request.documentID,
      pageIndex: -1
    ).isValid
  )
}

import Foundation

/// The wire names domain owners. Neither commands nor reads can select a store or a file path.
public struct NotebookCommand: Codable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case apply, undo, action, actions, continuations, search, contexts, point, delivery
    case referenceStatus, reference, placement, render, pageVision, read, artifact, publishExport
  }
  public var command: Kind
  public var query: String?
  public var limit: Int?
  public var action: CollaborationAction?
  public var actionID: UUID?
  public var target: CollaborationTarget?
  public var elementID: String?
  public var reference: CollaborationReference?
  public var expectedRevision: String?
  public var region: PageRect?
  public var worldOrigin: WorldPoint?
  public var pageIndex: Int?
  public var placement: CollaborationPlacementRequest?
  public var contextID: UUID?
  public var replyTo: UUID?
  public var references: [CollaborationReference]?
  public var queries: [NotebookReadQuery]?
  public var expectedCursor: String?
  public var artifact: NotebookArtifactRequest?
  public var export: NotebookExportPublication?

  public init(command: Kind) { self.command = command }

  /// These commands can commit or enqueue work; the Mac owner orders them with native intents.
  public var changesStore: Bool {
    switch command {
    case .apply, .undo, .point, .placement, .render, .pageVision, .publishExport: true
    default: false
    }
  }
}

public struct NotebookReadBounds: Codable, Sendable {
  public var anchor: WorldPoint
  public var region: PageRect
  func validated() throws -> WorkspaceSpatialBounds {
    guard anchor.isValid, region.x.isFinite, region.y.isFinite,
      region.width.isFinite, region.height.isFinite, region.width > 0, region.height > 0,
      abs(region.x) <= 10_000_000, abs(region.y) <= 10_000_000,
      region.width <= 10_000_000, region.height <= 10_000_000 else {
      throw CollaborationError("invalid_region", "Область чтения задаётся точным адресом и конечной рамкой до 10 миллионов points.")
    }
    return .init(origin: anchor.offsetBy(x: region.x, y: region.y), width: region.width, height: region.height)
  }
}

public struct NotebookReadQuery: Codable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case workspaceHeader, itemHeaders, itemHeader, workingSet, sceneWindow, scenePaintOrder
    case page, document, documentState, documentBlock, boardItem, boardElement, ownerBoard, notebookPages, notebookDirectory, notebookPosition, spatialInk, presence
    case attentionEvidence, contexts, contextEntries, actions, currentViewReceipt, pageVisionReceipt, targetRenderReceipt
    case renderRequests, delivery, actionSnapshots, runtime
  }
  public var kind: Kind
  public var id: UUID?
  public var after: UUID?
  public var referenceID: UUID?
  public var revision: String?
  public var limit: Int?
  public var itemIDs: [UUID]?
  public var pageIDs: [UUID]?
  public var boardIDs: [UUID]?
  public var surfaces: [SurfaceID]?
  public var pinnedIDs: [UUID]?
  public var bounds: NotebookReadBounds?
  public var coverID: UUID?
  public var paintCursor: String?
  public var pageIndex: Int?
  public var pages: [NotebookPageReadTarget]?
  public var itemID: UUID?
  public var visibleRoot: String?
  public var contextID: UUID?
  public var elementID: String?
  public init(kind: Kind, id: UUID? = nil, revision: String? = nil, limit: Int? = nil) {
    self.kind = kind; self.id = id; self.revision = revision; self.limit = limit
  }
}

/// Invoked by the application's existing persistence queue, never a second writer thread.
/// A synchronous read batch owns one SQLite snapshot; its cursor also fences staged MCP reads.
public struct NotebookCommandDispatcher: Sendable {
  public let store: NotebookStore
  public init(store: NotebookStore) { self.store = store }

  public func handle(_ request: NotebookCommand) throws -> JSONValue {
    do {
      if request.changesStore {
        return try store.commandTransaction(readAllowance: .agentCommand) { try execute(request) }
      }
      return try store.readTransaction { snapshot in
        try snapshot.currentSQL!.limitReads(.agentCommand)
        return try NotebookCommandDispatcher(store: snapshot).execute(request)
      }
    }
    catch let error as NotebookStorageError {
      switch error {
      case .limitExceeded: throw CollaborationError("resource_limit", "Запрос превышает конечное окно чтения Notebook.")
      case .transactionConflict: throw CollaborationError("read_conflict", "Содержание изменилось во время чтения.")
      case .legacyStoreRequiresConversion: throw CollaborationError("conversion_required", "Старое хранилище требует явного преобразования до запуска Notebook.")
      case .unsupportedFormat: throw CollaborationError("unsupported_format", "Обновите согласованную пару Notebook.")
      case .corruptRecord, .invalidTransaction, .readOnlyTransaction, .blobMissing, .blobHashMismatch:
        throw CollaborationError("storage_error", "Владелец отклонил некорректное или незавершённое содержимое.")
      }
    } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
      throw CollaborationError("target_missing", "Адресованный владелец ещё не опубликован или отсутствует.")
    }
  }

  private func execute(_ request: NotebookCommand) throws -> JSONValue {
    switch request.command {
    case .apply:
      guard let action = request.action else { throw invalid("invalid_action", "Нужен законченный ход.") }
      return try .encode(store.applyCollaborationAction(action, actor: store.collaborationActorID(), waitForInput: 0))
    case .undo:
      return try .encode(store.undoCollaborationAction(required(request.actionID), actor: store.collaborationActorID(), waitForInput: 0))
    case .action: return try .encode(store.collaborationAction(required(request.actionID)))
    case .actions: return try .encode(store.collaborationActions(afterID: nil, contextID: request.contextID, limit: boundedLimit(request.limit)))
    case .continuations: return try .encode(store.collaborationContinuations(required(request.actionID)))
    case .search:
      guard (request.query?.utf8.count ?? 0) <= 2_000 else { throw invalid("invalid_query", "Запрос поиска слишком длинный.") }
      return try .encode(store.search(request.query ?? "", limit: boundedLimit(request.limit)))
    case .contexts: return try .encode(store.sharedContexts(contextID: request.contextID, limit: boundedLimit(request.limit)))
    case .point:
      return try .encode(store.appendContext(references: request.references ?? [], author: .agent,
        actor: store.collaborationActorID(), contextID: request.contextID, replyTo: request.replyTo))
    case .delivery: return try delivery(required(request.actionID))
    case .referenceStatus:
      guard let reference = request.reference else { throw invalid("invalid_reference", "Нужна рассмотренная ссылка.") }
      return try .encode(store.referenceStatus(reference))
    case .reference:
      guard let target = request.target else { throw invalid("invalid_reference", "Нужен владелец указания.") }
      return .object(["revision": .string(try store.referenceRevision(target: target, elementID: request.elementID))])
    case .placement:
      guard let placement = request.placement else { throw invalid("invalid_placement", "Нужен пакет размещения.") }
      return try .encode(store.suggestCollaborationPlacement(placement))
    case .render:
      guard let target = request.target, let revision = request.expectedRevision else {
        throw invalid("invalid_reference", "Нужны владелец и прочитанная версия.")
      }
      return try .encode(store.requestTargetRender(target: target, expectedRevision: revision,
        region: request.region, worldOrigin: request.worldOrigin, pageIndex: request.pageIndex ?? 0))
    case .pageVision:
      guard let target = request.target, target.kind == .page, let revision = request.expectedRevision else {
        throw invalid("invalid_reference", "Нужны лист и версия рассмотренных чернил.")
      }
      return try .encode(store.requestPageVision(pageID: target.id, expectedRevision: revision))
    case .read:
      let queries = request.queries ?? []
      guard queries.count <= 128 else { throw invalid("resource_limit", "Один запрос читает до 128 адресованных владельцев.") }
      guard queries.filter({ $0.kind == .contexts }).count <= 1,
        queries.filter({ $0.kind == .contextEntries }).count <= 1 else {
        throw invalid("resource_limit", "Один срез читает один каталог фрагментов и одну страницу истории.")
      }
      let pages = Set(queries.flatMap { query in (query.kind == .page ? query.id.map { [$0] } ?? [] : []) + (query.pageIDs ?? []) })
      let heavy = Set(queries.flatMap { query in
        ([.document, .documentState, .documentBlock, .boardItem].contains(query.kind) ? query.id.map { [$0] } ?? [] : [])
          + (query.itemIDs ?? []) + (query.boardIDs ?? [])
      })
      let windowPages = queries.filter { $0.kind == .notebookPages }.reduce(0) { $0 + ($1.pages?.count ?? 0) }
      guard queries.filter({ $0.kind == .documentBlock }).count <= 4 else {
        throw invalid("resource_limit", "Один срез читает до четырёх блоков документа по 4 МиБ каждый.")
      }
      guard pages.count + windowPages <= 4, heavy.count <= 8, queries.filter({ $0.kind == .attentionEvidence }).count <= 4 else { throw invalid("resource_limit", "Один срез удерживает до четырёх листов и восьми тяжёлых владельцев.") }
      return try store.readTransaction { snapshot in
        let cursor = String(try snapshot.currentReadCursor())
        guard request.expectedCursor == nil || request.expectedCursor == cursor else {
          throw invalid("read_conflict", "Содержание изменилось во время чтения. Повторите законченный запрос.")
        }
        let reader = NotebookCommandDispatcher(store: snapshot)
        return .object(["cursor": .string(cursor), "values": .array(try queries.map(reader.read))])
      }
    case .artifact:
      guard let artifact = request.artifact else { throw invalid("invalid_artifact", "Нужен адрес производного изображения.") }
      return try .encode(store.authorizedArtifact(artifact))
    case .publishExport:
      guard let value = request.export else { throw invalid("invalid_artifact", "Нужен законченный печатный результат.") }
      return try .encode(store.publishDocumentExport(value))
    }
  }

  private func read(_ query: NotebookReadQuery) throws -> JSONValue {
    switch query.kind {
    case .workspaceHeader: return try .encode(store.workspaceHeader())
    case .itemHeaders: return try .encode(store.readItemHeaders(after: query.after, limit: query.limit ?? 128))
    case .itemHeader: return try .encode(store.readItemHeader(required(query.id)))
    case .workingSet:
      let set = try store.readWorkingSet(itemIDs: query.itemIDs ?? [], pageIDs: query.pageIDs ?? [],
        boardIDs: query.boardIDs ?? [], surfaces: query.surfaces ?? [])
      return .object(["header": try .encode(set.header), "items": try .encode(set.items), "boards": try .encode(set.boards),
        "pages": try keyed(set.pages), "documents": try keyed(set.documents), "states": try keyed(set.states), "ink": try .encode(set.ink)])
    case .sceneWindow:
      guard let bounds = query.bounds else { throw invalid("invalid_region", "Нужна физическая область сцены.") }
      let window = try store.readSceneWindow(boardID: required(query.id), bounds: bounds.validated(),
        limit: query.limit ?? 128, pinnedIDs: query.pinnedIDs ?? [])
      return .object(["header": try .encode(window.header), "boardID": try .encode(window.boardID),
        "items": try .encode(window.items.compactMap { try store.readItemHeader($0.id) }), "boards": try .encode(window.boards), "documentPaper": try keyed(window.documentPaper),
        "pageCounts": try keyed(window.pageCounts), "totalMatches": .number(Double(window.totalMatches)), "truncated": .bool(window.truncated)])
    case .scenePaintOrder:
      guard let bounds = query.bounds else { throw invalid("invalid_region", "Нужна конечная область чтения.") }
      var cursor: NotebookScenePaintCursor?
      if let encoded = query.paintCursor {
        guard encoded.utf8.count <= 4_096, let data = Data(base64Encoded: encoded),
          let value = try? JSONDecoder().decode(NotebookScenePaintCursor.self, from: data),
          value.address.utf8.count <= 1_024, value.boundsHash.count == 64,
          value.boundsHash.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
          (0...4).contains(value.layer), value.zIndex.isFinite else {
          throw invalid("invalid_cursor", "Курсор принадлежит завершённому чтению этой области.")
        }
        cursor = value
      }
      let page = try store.readScenePaintOrder(boardID: required(query.id), coverID: query.coverID,
        bounds: bounds.validated(), after: cursor, limit: query.limit ?? 32)
      // The opaque cursor preserves UInt64 exactly; JavaScript never rounds it.
      return .object(["revision": .string(String(page.revision)), "entries": try .encode(page.entries),
        "nextCursor": try page.next.map { .string(try JSONEncoder().encode($0).base64EncodedString()) } ?? .null])
    case .page: return try .encode(store.loadPage(required(query.id)))
    case .document: return try .encode(store.loadDocument(required(query.id)))
    case .documentState: return try .encode(store.loadDocumentState(required(query.id)))
    case .documentBlock:
      guard let blockID = query.elementID else { throw invalid("invalid_reference", "Нужен ID блока документа.") }
      return try .encode(store.readDocumentBlock(documentID: required(query.id), blockID: blockID))
    case .boardItem: return try .encode(store.readBoardItem(required(query.id)))
    case .boardElement:
      guard let elementID = query.elementID, elementID.utf8.count <= 120 else { throw invalid("invalid_reference", "Нужен ID элемента.") }
      return try .encode(store.readSpatialElement(boardID: required(query.id), elementID: elementID))
    case .ownerBoard: return try .encode(store.ownerBoardID(of: required(query.id)))
    case .notebookPages:
      return try .encode(store.readNotebookPageWindow(itemID: required(query.id), pages: query.pages ?? [],
        expectedVisibleRoot: query.visibleRoot))
    case .notebookDirectory:
      return try .encode(store.readNotebookPageDirectory(itemID: required(query.id), from: query.pageIndex ?? 0,
        limit: query.limit ?? 32, expectedVisibleRoot: query.visibleRoot))
    case .notebookPosition:
      let pageID = try required(query.id)
      guard let itemID = try query.itemID ?? store.ownerItemID(ofPage: pageID) else { return .null }
      return try .encode(store.resolveNotebookPage(pageID, in: itemID, expectedVisibleRoot: query.visibleRoot))
    case .spatialInk: return try .encode(store.readSpatialInk(surfaces: query.surfaces ?? []))
    case .presence: return try .encode(store.loadPresence())
    case .attentionEvidence: return try .encode(store.attentionEvidence(contextID: required(query.id), referenceID: required(query.referenceID)))
    case .contexts: return try .encode(store.sharedContexts(contextID: query.id, limit: query.limit ?? 32, afterContextID: query.after, expectedCursor: query.revision))
    case .contextEntries: return try .encode(store.sharedContextPage(contextID: required(query.id), afterEntryID: query.after, expectedCursor: query.revision, limit: query.limit ?? 32))
    case .actions: return try .encode(store.collaborationActions(afterID: query.after, contextID: query.contextID, limit: boundedLimit(query.limit)))
    case .currentViewReceipt: return try .encode(store.loadCurrentViewReceipt())
    case .pageVisionReceipt: return try .encode(store.loadPageVisionReceipt(required(query.id), revision: query.revision))
    case .targetRenderReceipt: return try .encode(store.loadTargetRenderReceipt(required(query.id)))
    case .renderRequests: return try .encode(store.targetRenderRequests())
    case .delivery: return try delivery(required(query.id))
    case .actionSnapshots: return try .encode(store.loadActionSnapshots(required(query.id)))
    case .runtime: return try .encode(store.loadRuntimeStatus())
    }
  }

  private func delivery(_ id: UUID) throws -> JSONValue {
    let receipt = try store.storedValue("collaboration/delivery/" + id.uuidString.lowercased() + ".json")?.decode(DeviceActionReceipt.self)
    return try .encode(receipt.map { [$0] } ?? [])
  }
  private func keyed<T: Encodable>(_ values: [UUID: T]) throws -> JSONValue {
    .object(try Dictionary(uniqueKeysWithValues: values.map { (id, value) in (id.uuidString.lowercased(), try JSONValue.encode(value)) }))
  }
  private func required(_ id: UUID?) throws -> UUID {
    guard let id else { throw invalid("invalid_reference", "Нужен устойчивый ID владельца.") }; return id
  }
  private func boundedLimit(_ value: Int?) throws -> Int {
    let value = value ?? 20
    guard (1...100).contains(value) else { throw invalid("invalid_limit", "Чтение возвращает от 1 до 100 результатов.") }
    return value
  }
  private func invalid(_ code: String, _ message: String) -> CollaborationError { .init(code, message) }
}

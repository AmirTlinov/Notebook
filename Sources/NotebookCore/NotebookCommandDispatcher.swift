import Foundation
import CryptoKit

/// The wire names domain owners, never a store. Only the typed local program
/// import capability accepts source files; browser/QuickJS commands cannot.
public struct NotebookCommand: Codable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case apply, admitAction, prepareAction, commitAction, undo, action, actions, continuations, search, contexts, point, delivery
    case referenceStatus, referenceStatuses, actionDetails, reference, placement, render, pageVision, read, artifact, publishExport, presentation
    case script, scriptContext, scriptArtifact, importProgram
  }
  public var command: Kind
  public var query: String?
  public var filters: NotebookSearchFilters?
  public var next: String?
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
  public var presentation: NotebookPresentationRequest?
  public var cancel: Bool?
  public var fingerprint: String?
  public var script: NotebookScriptRequest?
  public var scriptContext: NotebookScriptContextRequest?
  public var actionPage: NotebookActionDetailsPage?
  public var scriptEffect: NotebookScriptEffectAddress?
  public var readSnapshots: Bool?
  public var programImport: NotebookProgramImportRequest?

  enum CodingKeys: String, CodingKey, CaseIterable {
    case command, query, filters, next, limit, action, actionID, target, elementID, reference
    case expectedRevision, region, worldOrigin, pageIndex, placement, contextID
    case replyTo, references, queries, expectedCursor, artifact, export, presentation, cancel, fingerprint, script, scriptContext, actionPage, scriptEffect, readSnapshots, programImport
  }

  public init(command: Kind) { self.command = command }

  /// These commands can commit or enqueue work; the Mac owner orders them with native intents.
  public var changesStore: Bool {
    switch command {
    case .apply, .admitAction, .commitAction, .undo, .point, .placement, .render, .pageVision, .publishExport: true
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
    case observation, workspaceHeader, itemHeaders, itemHeader, itemLifecycle, workingSet, sceneWindow, scenePaintOrder
    case page, pageHeader, pageElement, pageInkActions, pageInkAction, documentHeader, document, documentState, documentBlock, boardItem, boardElement, boardContentRevision, ownerBoard, notebookPages, notebookDirectory, notebookPosition, spatialInk, presence
    case attentionEvidence, contexts, contextEntries, actions, currentViewReceipt, pageVisionReceipt, targetRenderReceipt
    case renderRequests, delivery, actionSnapshots, runtime, selection, codeFragment, codeFragments
  }
  public var kind: Kind
  public var scope: NotebookObservationScope?
  public var since: String?
  public var next: String?
  public var file: NotebookFileAddress?
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
      // Export owns preparation before its final writer transaction. Wrapping
      // it here would hold SQLite while hashing and staging image/PDF bytes.
      if request.command == .publishExport { return try execute(request) }
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
    case .script, .scriptContext, .importProgram:
      throw invalid("script_owner_unavailable", "Программы обслуживает координатор установленного Mac-помощника.")
    case .scriptArtifact:
      guard let artifact = request.artifact else { throw invalid("invalid_artifact", "Нужен точный адрес изображения.") }
      if artifact.kind == .attention {
        guard let contextID = artifact.contextID, let referenceID = artifact.referenceID,
          let source = try store.attentionEvidence(contextID: contextID, referenceID: referenceID),
          let image = source.image, image.sha256 == artifact.expectedSHA256 else {
          throw invalid("artifact_missing", "Исходные пиксели внимания ещё не доставлены.")
        }
        try image.validate(reference: source.reference)
        return .object(["data": .string(image.png.base64EncodedString()), "mimeType": .string("image/png"), "sha256": .string(image.sha256)])
      }
      let receipt = try store.authorizedArtifact(artifact)
      let bytes = try Data(contentsOf: URL(fileURLWithPath: receipt.path), options: .mappedIfSafe)
      guard bytes.count == receipt.byteCount, bytes.count <= 16 * 1024 * 1024,
        SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == receipt.sha256 else {
        throw invalid("invalid_snapshot", "Изображение изменилось после проверки квитанции.")
      }
      return .object(["data": .string(bytes.base64EncodedString()), "mimeType": .string(receipt.mimeType), "sha256": .string(receipt.sha256)])
    case .presentation:
      throw invalid("presentation_unavailable", "Временный показ выполняет открытый iPad через установленный Mac-помощник, не хранилище.")
    case .apply:
      guard let action = request.action else { throw invalid("invalid_action", "Нужен законченный ход.") }
      return try .encode(store.applyCollaborationAction(action, actor: store.collaborationActorID(), waitForInput: 0))
    case .admitAction:
      guard let action = request.action else { throw invalid("invalid_action", "Нужен исходный ход.") }
      let admission = try store.admitCollaborationSubmission(action)
      return .object(["state": .string(admission.state.rawValue), "fingerprint": .string(admission.fingerprint),
        "receipt": admission.receipt.map(NotebookStore.actionCompletion) ?? .null])
    case .prepareAction:
      guard let fingerprint = request.fingerprint else { throw invalid("invalid_action", "Нужна исходная идентичность хода.") }
      return try .encode(store.prepareCollaborationSubmission(required(request.actionID), fingerprint: fingerprint))
    case .commitAction:
      guard let action = request.action, let fingerprint = request.fingerprint else { throw invalid("invalid_action", "Нужен нормализованный ход с исходной идентичностью.") }
      return try store.completeScriptAction(request.scriptEffect, receipt: store.commitCollaborationSubmission(action, fingerprint: fingerprint, actor: store.collaborationActorID()), method: "transaction")
    case .undo:
      return try store.completeScriptAction(request.scriptEffect, receipt: store.undoCollaborationAction(required(request.actionID), actor: store.collaborationActorID(), waitForInput: 0), method: "undo")
    case .action: return try .encode(store.collaborationAction(required(request.actionID)))
    case .actions: return try .encode(store.collaborationActions(afterID: nil, contextID: request.contextID, limit: boundedLimit(request.limit)))
    case .continuations: return try .encode(store.collaborationContinuations(required(request.actionID)))
    case .actionDetails:
      guard request.actionID != nil || request.actionPage?.section == nil else {
        throw invalid("action_required", "Раздел квитанции требует actionID.")
      }
      if request.actionPage?.section != nil, request.readSnapshots == true, request.actionPage?.actionVersion == nil {
        throw invalid("action_version_required", "Продолжение раздела требует actionVersion исходного результата.")
      }
      let limit = min(50, try boundedLimit(request.limit))
      if let next = request.next, let id = request.actionID, let version = request.actionPage?.actionVersion {
        return try .encode(NotebookSnapshot(data: store.actionResultPage(id, version: version, next: next),
          basis: store.readBasis(targets: []), cursor: String(store.currentReadCursor())))
      }
      let receipts = try request.actionID.map { id in [try request.actionPage?.actionVersion.map { try store.actionVersionModel(id, version: $0) } ?? store.actionReadModel(id)] }
        ?? store.actionReadModels(afterID: request.actionPage?.after, contextID: request.contextID, limit: limit)
      let details = try receipts.map { receipt -> JSONValue in
        var detail = try store.actionDetails(receipt, page: request.actionPage).object
        if request.actionID == nil {
          detail["nextActionID"] = receipts.count == limit ? receipts.last.map { .string($0.id.uuidString.lowercased()) } : .null
        }
        detail["actionVersion"] = .string(receipt.actionVersion)
        return .object(detail)
      }
      if request.readSnapshots == true {
        return try .encode(NotebookSnapshot(data: request.actionID == nil ? .array(details) : details.first ?? .null,
          basis: store.readBasis(targets: []), coverage: .init(complete: request.actionID != nil || receipts.count < limit), cursor: String(store.currentReadCursor())))
      }
      return .array(details)
    case .search:
      guard (request.query?.utf8.count ?? 0) <= 2_000 else { throw invalid("invalid_query", "Запрос поиска слишком длинный.") }
      let found = try store.search(request.query ?? "", limit: boundedLimit(request.limit), filters: request.filters ?? .init(), next: request.next)
      if request.readSnapshots == true {
        return try .encode(NotebookSnapshot(data: .object(["results": .encode(found.results), "total": .number(Double(found.total))]),
          basis: store.readBasis(targets: found.results.map(\.target)), coverage: found.coverage, cursor: String(store.currentReadCursor())))
      }
      return try .encode(found)
    case .contexts: return try .encode(store.sharedContexts(contextID: request.contextID, limit: boundedLimit(request.limit)))
    case .point:
      if let id = request.actionID {
        return try store.appendScriptPoint(id, references: request.references ?? [],
          contextID: request.contextID, replyTo: request.replyTo, actor: store.collaborationActorID())
      }
      return try .encode(store.appendContext(references: request.references ?? [], author: .agent,
        actor: store.collaborationActorID(), contextID: request.contextID, replyTo: request.replyTo))
    case .delivery: return try delivery(required(request.actionID))
    case .referenceStatus:
      guard let reference = request.reference else { throw invalid("invalid_reference", "Нужна рассмотренная ссылка.") }
      let data = try JSONValue.encode(store.referenceStatus(reference, prepareRender: false))
      if request.readSnapshots == true { return try .encode(NotebookSnapshot(data: data, basis: store.readBasis(targets: []), cursor: String(store.currentReadCursor()))) }
      return data
    case .referenceStatuses:
      guard let references = request.references, references.count <= 256 else {
        throw invalid("resource_limit", "Один срез проверяет до 256 ссылок.")
      }
      return .array(try references.map { try .encode(store.referenceStatus($0, prepareRender: false)) })
    case .reference:
      guard let target = request.target else { throw invalid("invalid_reference", "Нужен владелец указания.") }
      let data = JSONValue.object(["target": try .encode(target), "revision": .string(try store.referenceRevision(target: target, elementID: request.elementID))])
      if request.readSnapshots == true { return try .encode(NotebookSnapshot(data: data, basis: store.readBasis(targets: [target], includeSource: true), cursor: String(store.currentReadCursor()))) }
      return data
    case .placement:
      guard let placement = request.placement else { throw invalid("invalid_placement", "Нужен пакет размещения.") }
      let proposal = try store.suggestCollaborationPlacement(placement)
      if request.readSnapshots == true {
        return try .encode(NotebookSnapshot(data: JSONValue.encode(proposal).setting("expected", nil),
          basis: .init(workspaceID: store.workspaceHeader().workspaceID, owners: proposal.expected), cursor: String(store.currentReadCursor())))
      }
      return try .encode(proposal)
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
      let queries = try (request.queries ?? []).map { try store.resolveReadContinuation($0) }
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
      guard queries.filter({ [.documentBlock, .pageElement, .pageInkAction].contains($0.kind) }).count <= 4 else {
        throw invalid("resource_limit", "Один срез читает до четырёх адресных элементов, блоков или штрихов по 4 МиБ каждый.")
      }
      guard pages.count + windowPages <= 4, heavy.count <= 8, queries.filter({ $0.kind == .attentionEvidence }).count <= 4 else { throw invalid("resource_limit", "Один срез удерживает до четырёх листов и восьми тяжёлых владельцев.") }
      return try store.readTransaction { snapshot in
        let cursor = String(try snapshot.currentReadCursor())
        guard request.expectedCursor == nil || request.expectedCursor == cursor else {
          throw invalid("read_conflict", "Содержание изменилось во время чтения. Повторите законченный запрос.")
        }
        let reader = NotebookCommandDispatcher(store: snapshot)
        if request.readSnapshots == true {
          return .array(try queries.map { query in
            let data = try reader.read(query)
            return try .encode(NotebookSnapshot(data: data, basis: snapshot.queryBasis(query, data: data),
              coverage: snapshot.queryCoverage(query, data: data), cursor: cursor))
          })
        }
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
    case .itemLifecycle: return try .encode(store.readItemLifecycle(required(query.id)))
    case .workingSet:
      let set = try store.readWorkingSet(itemIDs: query.itemIDs ?? [], pageIDs: query.pageIDs ?? [],
        boardIDs: query.boardIDs ?? [], surfaces: query.surfaces ?? [])
      return .object(["header": try .encode(set.header), "items": try .encode(set.items), "boards": .array(try set.boards.map(boardReadProjection)),
        "pages": .object(try Dictionary(uniqueKeysWithValues:set.pages.map { ($0.key.uuidString.lowercased(),try $0.value.graphicReadProjection()) })),
        "documents": try keyed(set.documents), "states": try keyed(set.states), "ink": try .encode(set.ink)])
    case .sceneWindow:
      guard let bounds = query.bounds else { throw invalid("invalid_region", "Нужна физическая область сцены.") }
      let window = try store.readSceneWindow(boardID: required(query.id), bounds: bounds.validated(),
        limit: query.limit ?? 128, pinnedIDs: query.pinnedIDs ?? [])
      return .object(["header": try .encode(window.header), "boardID": try .encode(window.boardID),
        "items": try .encode(window.items.compactMap { try store.readItemHeader($0.id) }), "boards": .array(try window.boards.map(boardReadProjection)),
        "boardContentRevisions": try keyed(window.boardContentRevisions), "documentPaper": try keyed(window.documentPaper),
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
    case .codeFragment: return try .encode(store.codeAnnotation(required(query.id)))
    case .codeFragments:
      guard let file = query.file else { throw invalid("invalid_reference", "Нужен адрес файла на компьютере.") }
      return try .encode(store.codeFragments(file: file, after: query.after, limit: query.limit ?? 64))
    case .page: return try store.loadPage(required(query.id)).graphicReadProjection()
    case .observation:
      guard let scope = query.scope else { throw invalid("invalid_observation", "Нужна scope наблюдения.") }
      return try .encode(store.observeContent(scope: scope, since: query.since, next: query.next, limit: query.limit ?? 32))
    case .pageHeader: return try .encode(store.readContentHeader(target: .init(kind: .page, id: required(query.id))))
    case .documentHeader: return try .encode(store.readContentHeader(target: .init(kind: .document, id: required(query.id))))
    case .pageElement:
      guard let elementID = query.elementID else { throw invalid("invalid_reference", "Нужен ID элемента листа.") }
      return try .encode(store.readPageElementSnapshot(pageID: required(query.id), elementID: elementID))
    case .pageInkActions:
      return try .encode(store.readPageInkActions(pageID: required(query.id), after: query.after, limit: query.limit ?? 32))
    case .pageInkAction:
      guard let rawID = query.elementID, let actionID = UUID(uuidString: rawID) else {
        throw invalid("invalid_reference", "Нужен UUID исходного штриха листа.")
      }
      return try .encode(store.readPageInkAction(pageID: required(query.id), actionID: actionID))
    case .document: return try .encode(store.loadDocument(required(query.id)))
    case .documentState: return try .encode(store.loadDocumentState(required(query.id)))
    case .documentBlock:
      guard let blockID = query.elementID else { throw invalid("invalid_reference", "Нужен ID блока документа.") }
      return try .encode(store.readDocumentBlock(documentID: required(query.id), blockID: blockID))
    case .boardItem:
      guard let node = try store.readBoardItem(required(query.id)) else { return .null }
      return try boardReadProjection(node)
    case .boardContentRevision: return try .encode(store.boardContentRevision(required(query.id)))
    case .boardElement:
      guard let elementID = query.elementID, elementID.utf8.count <= 120 else { throw invalid("invalid_reference", "Нужен ID элемента.") }
      let boardID = try required(query.id)
      guard let element = try store.readSpatialElement(boardID:boardID,elementID:elementID) else { return .null }
      return try elementReadProjection(element,boardID:boardID)
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
    case .presence: return try .encode(store.readObservedPresenceIfAvailable())
    case .selection: return try .encode(store.readSelectionPublication())
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

  /// Thin readers consume Core's physical layout, not a second placement
  /// resolver. These computed fields exist only in read responses; canonical
  /// placement intents remain intact for native decoding and are the sole
  /// durable owner of an item's position.
  private func boardReadProjection(_ node: BoardNode) throws -> JSONValue {
    guard case .object(var value) = try JSONValue.encode(node),
      case .object(var board) = value["board"] else {
      throw NotebookStorageError.corruptRecord("board read projection")
    }
    board["freeItems"] = try .encode(node.board.freeItems)
    board["stacks"] = try .encode(node.board.stacks)
    board["elements"] = .array(try node.board.elements.map { try elementReadProjection($0,boardID:node.id) })
    value["board"] = .object(board)
    return .object(value)
  }

  private func elementReadProjection(_ element: SpatialElement, boardID: UUID) throws -> JSONValue {
    var value = try JSONValue.encode(element)
    let layout: NotebookGraphicLayout?
    if element.graphic != nil, let owner = element.surface.ownerID {
      let target = CollaborationTarget(kind:element.surface.kind == .cover ? .cover : .board,id:owner,boardID:boardID)
      let resolution = try store.readGraphicResolution(target:target,elementID:element.id)
      value = try value.setting("graphicResolution",resolution.readProjection()); layout = resolution.layout
    } else { layout = nil }
    let frame = layout?.frame ?? .init(x:element.frame.x,y:element.frame.y,width:element.frame.width,height:element.frame.height)
    return try value.setting("appearance",NotebookElementAppearance(graphic:element.graphic,layout:layout,
      size:.init(width:frame.width,height:frame.height),erasures:store.readElementErasures(on:element.surface,elementID:element.id)).readProjection())
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

import Foundation

private struct CollaborationTransaction: Codable {
  let writes: [String: JSONValue]
  let removals: [String]
}

extension NotebookStore {
  public var collaborationURL: URL { root.appendingPathComponent("collaboration", isDirectory: true) }
  public var collaborationActionsURL: URL { collaborationURL.appendingPathComponent("actions", isDirectory: true) }
  private var pendingCollaborationURL: URL { collaborationURL.appendingPathComponent("pending.json") }

  public func collaborationActorID() throws -> UUID {
    try prepare()
    return try withMutationLock {
      let url = root.appendingPathComponent("mcp-actor.txt")
      if let text = try? String(contentsOf: url, encoding: .utf8),
        let id = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines)) { return id }
      let actor = UUID()
      try actor.uuidString.lowercased().write(to: url, atomically: true, encoding: .utf8)
      return actor
    }
  }

  public func collaborationActions() throws -> [CollaborationReceipt] {
    try prepare()
    return try withMutationLock { try loadCollaborationActions() }
  }

  private func loadCollaborationActions() throws -> [CollaborationReceipt] {
    guard FileManager.default.fileExists(atPath: collaborationActionsURL.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(at: collaborationActionsURL,
      includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.map {
        try JSONDecoder().decode(CollaborationReceipt.self, from: Data(contentsOf: $0))
      }.sorted { $0.createdAt > $1.createdAt }
  }

  public func collaborationAction(_ id: UUID) throws -> CollaborationReceipt {
    try prepare()
    return try withMutationLock { try loadAction(id) }
  }

  private func actionFile(_ id: UUID) -> String {
    "collaboration/actions/\(id.uuidString.lowercased()).json"
  }

  private func loadAction(_ id: UUID) throws -> CollaborationReceipt {
    let url = root.appendingPathComponent(actionFile(id))
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw CollaborationError("target_missing", "Ход не найден: \(id)")
    }
    return try JSONDecoder().decode(CollaborationReceipt.self, from: Data(contentsOf: url))
  }

  @discardableResult
  public func applyCollaborationAction(_ action: CollaborationAction, actor: UUID) throws -> CollaborationReceipt {
    try prepare()
    return try withMutationLock {
      if FileManager.default.fileExists(atPath: root.appendingPathComponent(actionFile(action.id)).path) {
        let previous = try loadAction(action.id)
        guard previous.action == action else {
          throw CollaborationError("action_id_conflict", "Этот ID уже принадлежит другому ходу.")
        }
        return previous
      }
      guard !action.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        action.summary.count <= 1000, (1...512).contains(action.operations.count),
        action.references.count <= 32 else {
        throw CollaborationError("invalid_action", "Ход содержит описание и от 1 до 512 операций.")
      }
      let before = try CollaborationWorkspace(store: self)
      for expectation in action.expected {
        let actual = try before.revision(of: expectation.target)
        guard actual == expectation.revision.lowercased() else {
          throw CollaborationError("revision_conflict", "Владелец изменился. Прочитайте его текущую версию.",
            target: expectation.target, expected: expectation.revision, actual: actual)
        }
      }
      var after = before
      var createdTargets = Set<CollaborationTarget>()
      for operation in action.operations {
        for target in try before.requiredExpectations(for: operation) {
          guard createdTargets.contains(target) || action.expected.contains(where: { $0.target == target }) else {
            throw CollaborationError("revision_required", "Для изменения нужна версия владельца.", target: target)
          }
        }
        try after.apply(operation, actor: actor)
        if let id = operation.id.flatMap(UUID.init(uuidString:)) {
          switch operation.kind {
          case .createBoard: createdTargets.insert(.init(kind: .board, id: id))
          case .createDocument: createdTargets.insert(.init(kind: .document, id: id))
          case .createNotebook:
            if let pageID = operation.values["pageID"]?.string.flatMap(UUID.init(uuidString:)) {
              createdTargets.insert(.init(kind: .page, id: pageID))
            }
          default: break
          }
          if [.createBoard, .createNotebook, .createDocument].contains(operation.kind) {
            createdTargets.insert(.init(kind: .cover, id: id, boardID: operation.target.id))
          }
        }
      }
      try after.recordFieldChanges(from: before, human: false)
      try after.validate()
      let changes = collaborationDiff(before.files, after.files)
      let receipt = CollaborationReceipt(id: action.id, action: action, createdAt: Date(),
        revisions: try after.changedTargets(from: before).map {
          CollaborationExpectation(target: $0, revision: try after.revision(of: $0))
        }, changes: changes)
      try commitCollaboration(before: before.files, after: after.files, receipt: receipt)
      return receipt
    }
  }

  @discardableResult
  public func undoCollaborationAction(_ id: UUID, actor: UUID) throws -> CollaborationReceipt {
    try prepare()
    return try withMutationLock {
      var receipt = try loadAction(id)
      if receipt.undo != nil { return receipt }
      let before = try CollaborationWorkspace(store: self)
      var after = before
      var preserved: [CollaborationFieldChange] = []
      let protected = before.protectedCreationChanges(in: receipt)
      var restored = 0
      for change in receipt.changes {
        let current = before.files[change.file]?.value(at: change.path[...])
        let version = collaborationFieldVersion(file: before.files[change.file], path: change.path)
        let stillOwned = change.afterVersion == nil || (version?.stamp == change.afterVersion?.stamp
          && version?.human == change.afterVersion?.human)
        guard !protected.contains(change.file),
          stillOwned,
          collaborationComparable(current) == collaborationComparable(change.after) else {
          preserved.append(change)
          continue
        }
        if let value = after.files[change.file] {
          after.files[change.file] = value.setting(at: change.path[...], to: change.before)
        } else if change.path.isEmpty {
          after.files[change.file] = change.before
        } else {
          preserved.append(change)
          continue
        }
        restored += 1
      }
      try after.restampChanges(from: before, actor: actor)
      try after.recordFieldChanges(from: before, human: true)
      // Dependencies of a created item are preserved as a group when a later
      // hand has adopted any of them; validation is the final ownership gate.
      try after.validate()
      receipt.undo = CollaborationUndoResult(restored: restored, preserved: preserved, completedAt: Date())
      receipt.revisions = try after.changedTargets(from: before).map {
        CollaborationExpectation(target: $0, revision: try after.revision(of: $0))
      }
      try commitCollaboration(before: before.files, after: after.files, receipt: receipt)
      return receipt
    }
  }

  private func commitCollaboration(before: [String: JSONValue], after: [String: JSONValue],
    receipt: CollaborationReceipt) throws {
    var writes = after.filter { before[$0.key] != $0.value }
    writes[actionFile(receipt.id)] = try .encode(receipt)
    let transaction = CollaborationTransaction(writes: writes, removals: before.keys.filter { after[$0] == nil })
    try FileManager.default.createDirectory(at: collaborationURL, withIntermediateDirectories: true)
    try JSONEncoder().encode(transaction).write(to: pendingCollaborationURL, options: .atomic)
    try recoverCollaborationTransaction()
  }

  /// The prepared file is the durable publication decision. Every store writer
  /// finishes it under the same lock before starting the next operation.
  func recoverCollaborationTransaction() throws {
    guard FileManager.default.fileExists(atPath: pendingCollaborationURL.path) else { return }
    let transaction = try JSONDecoder().decode(CollaborationTransaction.self,
      from: Data(contentsOf: pendingCollaborationURL))
    for path in transaction.writes.keys.sorted(by: { publicationOrder($0) < publicationOrder($1) }) {
      let url = try collaborationFileURL(path)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(transaction.writes[path]!).write(to: url, options: .atomic)
    }
    for path in transaction.removals {
      let url = try collaborationFileURL(path)
      if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    try FileManager.default.removeItem(at: pendingCollaborationURL)
  }

  private func collaborationFileURL(_ path: String) throws -> URL {
    let allowed = ["workspace.json", "board.json"].contains(path)
      || ["pages/", "documents/", "document-states/", "collaboration/actions/"].contains { path.hasPrefix($0) }
    guard allowed, !path.contains(".."), !path.hasPrefix("/"), path.hasSuffix(".json") else {
      throw CollaborationError("invalid_transaction", "Некорректный путь публикации.")
    }
    return root.appendingPathComponent(path)
  }

  private func publicationOrder(_ path: String) -> String {
    if path == "board.json" { return "1" }
    if path == "workspace.json" { return "2" }
    if path.hasPrefix("collaboration/") { return "3" + path }
    return "0" + path
  }

  public func collaborationSnapshot() throws -> [String: JSONValue] {
    try prepare()
    return try withMutationLock {
      var files = try CollaborationWorkspace(store: self).files
      files["last-context.json"] = try? .encode(loadPresence())
      files["spatial-ink.json"] = try .encode(loadSpatialInk())
      return files
    }
  }
}

private struct CollaborationWorkspace {
  var files: [String: JSONValue]
  let ink: SpatialInkJournal

  init(store: NotebookStore) throws {
    let workspace = try store.loadIndex()
    files = ["workspace.json": try .encode(workspace), "board.json": try .encode(store.loadBoard(items: workspace.items))]
    for item in workspace.items {
      for pageID in item.pageIDs { files[pageFile(pageID)] = try .encode(store.loadPage(pageID)) }
      if item.kind == .document {
        files[documentFile(item.id)] = try .encode(store.loadDocument(item.id))
        files[stateFile(item.id)] = try .encode(store.loadDocumentState(item.id))
      }
    }
    ink = try store.loadSpatialInk()
  }

  var workspace: WorkspaceIndex { get throws { try files["workspace.json"]!.decode(WorkspaceIndex.self) } }
  var hierarchy: BoardHierarchy { get throws { try files["board.json"]!.decode(BoardHierarchy.self) } }

  func boardID(for target: CollaborationTarget) throws -> UUID {
    if target.kind == .board { return target.id }
    guard target.kind == .cover, let boardID = target.boardID,
      try hierarchy.ownerBoardID(of: target.id) == boardID else {
      throw CollaborationError("target_missing", "Обложка должна принадлежать указанной доске.", target: target)
    }
    return boardID
  }

  func revision(of target: CollaborationTarget) throws -> String {
    switch target.kind {
    case .workspace:
      guard try workspace.rootBoardID == target.id else { throw missing(target) }
      return try workspace.stamp.revision
    case .board, .cover:
      guard let board = try hierarchy.board(boardID(for: target)) else { throw missing(target) }
      return board.stamp.revision
    case .page:
      guard let value = files[pageFile(target.id)] else { throw missing(target) }
      return try value.decode(PageDocument.self).agentStamp.revision
    case .document:
      guard let value = files[documentFile(target.id)] else { throw missing(target) }
      return try value.decode(DocumentDocument.self).contentStamp.revision
    }
  }

  func requiredExpectations(for operation: CollaborationOperation) throws -> [CollaborationTarget] {
    var targets = [operation.target]
    if [.createNotebook, .createDocument, .createBoard, .renameItem].contains(operation.kind) {
      targets.append(CollaborationTarget(kind: .workspace, id: try workspace.rootBoardID))
    }
    return Array(Set(targets))
  }

  mutating func apply(_ operation: CollaborationOperation, actor: UUID) throws {
    switch operation.kind {
    case .insertElement, .updateElement, .setElementState, .removeElement, .reorderElements:
      try editElements(operation, actor: actor)
    case .insertBlock, .updateBlock, .removeBlock, .reorderBlocks, .setPreamble, .replaceDocument:
      try editDocument(operation, actor: actor)
    case .createNotebook, .createDocument, .createBoard:
      try create(operation, actor: actor)
    case .renameItem:
      guard let id = operation.id, let title = operation.values["title"]?.string,
        title.count <= WorkspaceIndex.maximumTitleLength else { throw invalid("Нужно имя предмета.") }
      var value = files["workspace.json"]!
      guard operation.target.kind == .board, let itemID = UUID(uuidString: id),
        try hierarchy.ownerBoardID(of: itemID) == operation.target.id else { throw missing(operation.target) }
      let path: [CollaborationPathComponent] = [.field("items"), .member(id)]
      guard let item = value.value(at: path[...]) else { throw missing(operation.target) }
      if item["title"] == .string(title) { return }
      value = value.setting(at: path[...], to: item.setting("title", .string(title)))!
      files["workspace.json"] = try advancing(value, key: "stamp", actor: actor)
    case .moveItem:
      guard let id = operation.id.flatMap(UUID.init(uuidString:)), let center = operation.values["center"] else {
        throw invalid("Нужны ID предмета и его центр.")
      }
      var tree = try hierarchy
      guard try tree.moveItem(id, in: boardID(for: operation.target), to: center.decode(WorldPoint.self), actor: actor) else {
        throw invalid("Предмет должен быть свободным участником указанной доски.")
      }
      files["board.json"] = try .encode(tree)
    case .stackItems:
      guard let members = operation.values["itemIDs"] else { throw invalid("Нужны участники стопки.") }
      let ids = try members.decode([UUID].self)
      guard (2...5).contains(ids.count), Set(ids).count == ids.count else { throw invalid("В стопке от двух до пяти разных предметов.") }
      var tree = try hierarchy
      let boardID = try boardID(for: operation.target)
      for moving in ids.dropLast() {
        guard tree.createStack(moving: moving, onto: ids.last!, in: boardID, actor: actor) != nil else {
          throw invalid("Участники должны принадлежать указанной доске.")
        }
      }
      files["board.json"] = try .encode(tree)
    }
  }

  mutating func editElements(_ op: CollaborationOperation, actor: UUID) throws {
    let file: String
    var path: [CollaborationPathComponent] = []
    if op.target.kind == .page {
      file = pageFile(op.target.id)
    } else {
      let boardID = try boardID(for: op.target)
      file = "board.json"
      path = [.field("boards"), .member(boardID.uuidString), .field("board")]
    }
    guard let root = files[file], let owner = root.value(at: path[...]) else { throw missing(op.target) }
    var elements = owner["elements"]?.array ?? []
    let index = op.id.flatMap { id in elements.firstIndex { $0["id"]?.string == id } }
    switch op.kind {
    case .insertElement:
      guard index == nil, let id = op.id, !id.isEmpty, id.count <= 120,
        let kind = op.values["kind"]?.string, ["markdown", "web", "nativeText"].contains(kind),
        let frame = op.values["frame"], let source = op.values["source"] else { throw invalid("Новый элемент получает ID, вид, рамку и исходник.") }
      var value: [String: JSONValue] = ["id": .string(id), "kind": .string(kind), "frame": frame,
        "source": source, "html": op.values["html"] ?? source, "css": op.values["css"] ?? .string(""),
        "javaScript": op.values["javaScript"] ?? .string(""), "state": op.values["state"] ?? .object([:])]
      if op.target.kind != .page {
        let surface: SurfaceID = op.target.kind == .cover ? .cover(op.target.id) : .board(op.target.id)
        value["surface"] = try .encode(surface)
        value["stamp"] = owner["stamp"]
        value["textStyle"] = try .encode(NativeTextStyle.standard)
        value["worldOrigin"] = op.values["worldOrigin"]
      }
      elements.append(.object(value))
    case .updateElement, .setElementState:
      guard let index else { throw missing(op.target) }
      if op.target.kind == .cover || op.target.kind == .board {
        guard let surface = elements[index]["surface"],
          try surface.decode(SurfaceID.self) == (op.target.kind == .cover ? .cover(op.target.id) : .board(op.target.id)) else { throw missing(op.target) }
      }
      let allowed = op.kind == .setElementState ? Set(["state"]) : Set(["frame", "source", "html", "css", "javaScript", "worldOrigin", "textStyle"])
      guard !op.values.isEmpty, Set(op.values.keys).isSubset(of: allowed) else { throw invalid("Поля изменения принадлежат выбранной операции.") }
      for (key, value) in op.values { elements[index] = elements[index].setting(key, value) }
    case .removeElement:
      guard let index else { throw missing(op.target) }
      if op.target.kind != .page {
        let surface = try elements[index]["surface"]!.decode(SurfaceID.self)
        guard surface == (op.target.kind == .cover ? .cover(op.target.id) : .board(op.target.id)) else { throw missing(op.target) }
      }
      elements.remove(at: index)
    case .reorderElements:
      if op.target.kind == .page {
        elements = try reordered(elements, values: op.values)
      } else {
        let surface = op.target.kind == .cover ? SurfaceID.cover(op.target.id) : .board(op.target.id)
        let indices = try elements.indices.filter { try elements[$0]["surface"]!.decode(SurfaceID.self) == surface }
        let ordered = try reordered(indices.map { elements[$0] }, values: op.values)
        for (offset, index) in indices.enumerated() { elements[index] = ordered[offset] }
      }
    default: break
    }
    guard elements != owner["elements"]?.array else { return }
    var nextOwner = owner.setting("elements", .array(elements))
    nextOwner = try advancing(nextOwner, key: op.target.kind == .page ? "agentStamp" : "stamp", actor: actor)
    if op.target.kind != .page {
      let stamp = nextOwner["stamp"]!
      nextOwner = nextOwner.setting("elements", .array(elements.map { element in
        let old = owner["elements"]?.array.first { $0["id"] == element["id"] }
        return old == element ? element : element.setting("stamp", stamp)
      }))
    }
    files[file] = root.setting(at: path[...], to: nextOwner)
    if file == "board.json" { files[file] = try advancing(files[file]!, key: "stamp", actor: actor) }
  }

  mutating func editDocument(_ op: CollaborationOperation, actor: UUID) throws {
    guard op.target.kind == .document, let value = files[documentFile(op.target.id)] else { throw missing(op.target) }
    var blocks = value["blocks"]!.array
    let index = op.id.flatMap { id in blocks.firstIndex { $0["id"]?.string == id } }
    var next = value
    switch op.kind {
    case .insertBlock:
      guard index == nil, let id = op.id else { throw invalid("Новый блок получает свободный ID.") }
      let block = try completeBlock(op.values.merging(["id": .string(id)]) { _, new in new })
      if let afterID = op.values["afterID"]?.string {
        guard let anchor = blocks.firstIndex(where: { $0["id"]?.string == afterID }) else { throw invalid("Опорный блок найден в этом документе.") }
        blocks.insert(block, at: anchor + 1)
      } else { blocks.append(block) }
    case .updateBlock:
      guard let index else { throw missing(op.target) }
      let allowed: Set<String> = ["source", "html", "css", "javaScript", "height"]
      guard !op.values.isEmpty, Set(op.values.keys).isSubset(of: allowed) else { throw invalid("Обновление меняет исходник и оформление блока.") }
      for (key, field) in op.values { blocks[index] = blocks[index].setting(key, field) }
      if blocks[index]["kind"]?.string == "interactive" {
        if let html = op.values["html"] ?? op.values["source"] {
          blocks[index] = blocks[index].setting("source", html).setting("html", html)
        }
      }
    case .removeBlock:
      guard let index else { throw missing(op.target) }
      blocks.remove(at: index)
    case .reorderBlocks: blocks = try reordered(blocks, values: op.values)
    case .setPreamble:
      guard let preamble = op.values["preamble"]?.string else { throw invalid("Нужна преамбула.") }
      next = next.setting("preamble", .string(preamble))
    case .replaceDocument:
      guard let replacement = op.values["blocks"], let preamble = op.values["preamble"] else { throw invalid("Полная замена содержит блоки и преамбулу.") }
      blocks = try replacement.array.map { try completeBlock($0.object) }
      next = next.setting("preamble", preamble)
    default: break
    }
    next = next.setting("blocks", .array(blocks))
    guard next != value else { return }
    files[documentFile(op.target.id)] = try advancing(next, key: "contentStamp", actor: actor)
  }

  mutating func create(_ op: CollaborationOperation, actor: UUID) throws {
    guard op.target.kind == .board, let center = op.values["center"],
      let id = op.id.flatMap(UUID.init(uuidString:)) else { throw invalid("Создание получает ID предмета и центр на доске.") }
    var index = try workspace
    let selectedID = index.selectedItemID
    let selectedPage = index.selectedPageID
    var tree = try hierarchy
    let title = op.values["title"]?.string ?? ""
    switch op.kind {
    case .createNotebook:
      guard let pageID = op.values["pageID"]?.string.flatMap(UUID.init(uuidString:)),
        let created = index.createNotebook(title: title, actor: actor,
          pageSize: PageSize(width: 834, height: 1194), itemID: id, pageID: pageID) else { throw invalid("Нужны свободные ID тетради и первого листа.") }
      files[pageFile(pageID)] = try .encode(created.page)
      guard try tree.addItem(id, to: op.target.id, near: center.decode(WorldPoint.self), actor: actor) else { throw missing(op.target) }
    case .createDocument:
      guard let paper = op.values["paperSize"]?.string.flatMap(DocumentPaperSize.init(rawValue:)),
        index.createDocument(title: title, actor: actor, documentID: id) != nil else { throw invalid("Нужны свободный ID и формат a4 либо letter.") }
      let blocks = try (op.values["blocks"]?.array ?? []).map { try completeBlock($0.object).decode(DocumentBlock.self) }
      let candidate: JSONValue = .object(["format": .number(Double(DocumentDocument.formatVersion)),
        "id": .string(id.uuidString), "paperSize": .string(paper.rawValue),
        "preamble": op.values["preamble"] ?? .string(""), "blocks": try .encode(blocks),
        "contentStamp": try .encode(VersionStamp(counter: 0, actor: actor))])
      let document = try candidate.decode(DocumentDocument.self)
      files[documentFile(id)] = try .encode(document)
      files[stateFile(id)] = try .encode(DocumentStateJournal(id: id, actor: actor))
      guard try tree.addItem(id, to: op.target.id, near: center.decode(WorldPoint.self), actor: actor) else { throw missing(op.target) }
    case .createBoard:
      guard index.createBoard(title: title, actor: actor, boardID: id) != nil,
        try tree.createBoard(id, in: op.target.id, near: center.decode(WorldPoint.self), actor: actor) else { throw invalid("Нужен свободный ID дочерней доски.") }
    default: break
    }
    // Creation changes the catalogue; the human's camera and selection retain
    // their owner until they choose Show on the completed action.
    var indexJSON = try JSONValue.encode(index)
    indexJSON = indexJSON.setting("selectedItemID", .string(selectedID.uuidString))
      .setting("selectedPageID", selectedPage.map { .string($0.uuidString) })
    files["workspace.json"] = indexJSON
    files["board.json"] = try .encode(tree)
  }

  func validate() throws {
    let index = try workspace
    guard index.isValid, try hierarchy.isValid(items: index.items) else { throw invalid("Каждый предмет имеет одного владельца на доске.") }
    for item in index.items {
      for pageID in item.pageIDs {
        guard let value = files[pageFile(pageID)] else { throw invalid("Тетрадь содержит существующие листы.") }
        let page = try value.decode(PageDocument.self)
        guard page.id == pageID, page.isValid else { throw invalid("Элементы помещаются в физический лист.") }
      }
      if item.kind == .document {
        guard let document = files[documentFile(item.id)], let state = files[stateFile(item.id)],
          try document.decode(DocumentDocument.self).isValid,
          try state.decode(DocumentStateJournal.self).isValid else { throw invalid("Документ содержит согласованные блоки и состояние.") }
      }
    }
    for node in try hierarchy.boards {
      for element in node.board.elements where element.surface.kind == .cover {
        guard let id = element.surface.ownerID, let item = index.items.first(where: { $0.id == id }) else { throw invalid("Обложка принадлежит существующему предмету.") }
        let geometry: WorkspaceItemGeometry
        if item.kind == .document {
          geometry = .document(try files[documentFile(id)]!.decode(DocumentDocument.self).paperSize)
        } else { geometry = .notebook }
        guard element.frame.x >= 0, element.frame.y >= 0,
          element.frame.x + element.frame.width <= geometry.width,
          element.frame.y + element.frame.height <= geometry.height else { throw invalid("Элемент помещается в физическую обложку.") }
      }
    }
  }

  func changedTargets(from previous: Self) throws -> [CollaborationTarget] {
    var targets: [CollaborationTarget] = []
    if files["workspace.json"] != previous.files["workspace.json"] { targets.append(.init(kind: .workspace, id: try workspace.rootBoardID)) }
    let oldTree = try previous.hierarchy
    for node in try hierarchy.boards where node.board != oldTree.board(node.id) { targets.append(.init(kind: .board, id: node.id)) }
    for item in try workspace.items {
      for pageID in item.pageIDs where files[pageFile(pageID)] != previous.files[pageFile(pageID)] { targets.append(.init(kind: .page, id: pageID)) }
      if item.kind == .document, files[documentFile(item.id)] != previous.files[documentFile(item.id)] { targets.append(.init(kind: .document, id: item.id)) }
    }
    return targets
  }

  mutating func restampChanges(from previous: Self, actor: UUID) throws {
    for target in try changedTargets(from: previous) {
      switch target.kind {
      case .workspace: files["workspace.json"] = try advancing(files["workspace.json"]!, key: "stamp", actor: actor)
      case .page: files[pageFile(target.id)] = try advancing(files[pageFile(target.id)]!, key: "agentStamp", actor: actor)
      case .document: files[documentFile(target.id)] = try advancing(files[documentFile(target.id)]!, key: "contentStamp", actor: actor)
      case .board:
        let path: [CollaborationPathComponent] = [.field("boards"), .member(target.id.uuidString), .field("board")]
        let tree = files["board.json"]!
        if let board = tree.value(at: path[...]) {
          let next = try advancing(board, key: "stamp", actor: actor)
          files["board.json"] = tree.setting(at: path[...], to: next)
        }
      case .cover: break
      }
    }
    if files["board.json"] != previous.files["board.json"] { files["board.json"] = try advancing(files["board.json"]!, key: "stamp", actor: actor) }
  }

  mutating func recordFieldChanges(from previous: Self, human: Bool) throws {
    for target in try changedTargets(from: previous) where target.kind != .workspace {
      let file: String
      let path: [CollaborationPathComponent]
      let stampKey: String
      switch target.kind {
      case .page: file = pageFile(target.id); path = []; stampKey = "agentStamp"
      case .document: file = documentFile(target.id); path = []; stampKey = "contentStamp"
      case .board:
        file = "board.json"
        path = [.field("boards"), .member(target.id.uuidString), .field("board")]
        stampKey = "stamp"
      default: continue
      }
      guard let current = files[file]?.value(at: path[...]) else { continue }
      let old = previous.files[file]?.value(at: path[...]) ?? .object([:])
      let stamp = try current[stampKey]!.decode(VersionStamp.self)
      let beforeStamp = try old[stampKey]?.decode(VersionStamp.self) ?? stamp
      var metadata = try old["collaboration"]?.decode(CollaborativeContent.self) ?? CollaborativeContent()
      metadata.record(before: old, after: current, beforeStamp: beforeStamp, stamp: stamp, human: human)
      files[file] = files[file]!.setting(at: path[...], to: current.setting("collaboration", try .encode(metadata)))
    }
  }

  func protectedCreationChanges(in receipt: CollaborationReceipt) -> Set<String> {
    let created = receipt.action.operations.filter { [.createNotebook, .createDocument, .createBoard].contains($0.kind) }
    var result: Set<String> = []
    for op in created {
      guard let id = op.id.flatMap(UUID.init(uuidString:)) else { continue }
      let pageID = op.values["pageID"]?.string.flatMap(UUID.init(uuidString:))
      let owned = [documentFile(id), stateFile(id)] + (pageID.map { [pageFile($0)] } ?? [])
      let adoptedFile = receipt.changes.contains { change in
        owned.contains(change.file) && change.path.isEmpty
          && collaborationComparable(files[change.file]) != collaborationComparable(change.after)
      }
      let adoptedInk = ink.actions.contains { action in
        action.isActive && action.spans.contains { $0.surface.ownerID == id }
      }
      let child = try? hierarchy.board(id)
      let adoptedBoard = op.kind == .createBoard && (child?.elements.isEmpty == false || child?.itemIDs.isEmpty == false)
      if adoptedFile || adoptedInk || adoptedBoard {
        result.formUnion(owned + ["workspace.json", "board.json"])
      }
    }
    return result
  }
}

private func pageFile(_ id: UUID) -> String { "pages/\(id.uuidString.lowercased()).json" }
private func documentFile(_ id: UUID) -> String { "documents/\(id.uuidString.lowercased()).json" }
private func stateFile(_ id: UUID) -> String { "document-states/\(id.uuidString.lowercased()).json" }
private func missing(_ target: CollaborationTarget) -> CollaborationError { .init("target_missing", "Указанный владелец или элемент отсутствует.", target: target) }
private func invalid(_ message: String) -> CollaborationError { .init("invalid_operation", message) }
private func advancing(_ value: JSONValue, key: String, actor: UUID) throws -> JSONValue {
  let stamp = try value[key]!.decode(VersionStamp.self)
  guard let next = stamp.advanced(by: actor) else { throw invalid("Счётчик версий достиг предела.") }
  return value.setting(key, try .encode(next))
}
private func completeBlock(_ fields: [String: JSONValue]) throws -> JSONValue {
  guard let id = fields["id"]?.string, !id.isEmpty, id.count <= 120,
    let kind = fields["kind"]?.string, ["markdown", "latex", "interactive"].contains(kind) else { throw invalid("Блок имеет устойчивый ID и вид содержания.") }
  let source = fields["source"] ?? fields["html"] ?? .string("")
  return .object(["id": .string(id), "kind": .string(kind), "source": source,
    "html": kind == "interactive" ? (fields["html"] ?? source) : .string(""),
    "css": fields["css"] ?? .string(""), "javaScript": fields["javaScript"] ?? .string(""),
    "initialState": fields["initialState"] ?? .object([:]), "height": fields["height"] ?? .number(320)])
}
private func reordered(_ items: [JSONValue], values: [String: JSONValue]) throws -> [JSONValue] {
  guard let ids = values["ids"]?.array.compactMap(\.string), ids.count == items.count,
    Set(ids).count == ids.count, Set(ids) == Set(items.compactMap { $0["id"]?.string }) else { throw invalid("Порядок перечисляет каждый существующий ID ровно один раз.") }
  return ids.map { id in items.first { $0["id"]?.string == id }! }
}

private let versionFields: Set<String> = ["stamp", "agentStamp", "contentStamp", "portalStamp", "collaboration"]
private func collaborationComparable(_ value: JSONValue?) -> JSONValue? {
  guard let value else { return nil }
  switch value {
  case .object(let object): return .object(object.filter { !versionFields.contains($0.key) }.mapValues { collaborationComparable($0)! })
  case .array(let array): return .array(array.map { collaborationComparable($0)! })
  default: return value
  }
}
private func collaborationDiff(_ before: [String: JSONValue], _ after: [String: JSONValue]) -> [CollaborationFieldChange] {
  var result: [CollaborationFieldChange] = []
  func walk(_ file: String, _ path: [CollaborationPathComponent], _ a: JSONValue?, _ b: JSONValue?) {
    guard collaborationComparable(a) != collaborationComparable(b) else { return }
    if case .object(let left) = a, case .object(let right) = b {
      for key in Set(left.keys).union(right.keys).sorted() where !versionFields.contains(key) {
        walk(file, path + [.field(key)], left[key], right[key])
      }
    } else if case .array(let left) = a, case .array(let right) = b,
      left.allSatisfy({ $0.memberIdentity != nil }), right.allSatisfy({ $0.memberIdentity != nil }) {
      let leftMap = Dictionary(left.map { ($0.memberIdentity!, $0) }, uniquingKeysWith: { first, _ in first })
      let rightMap = Dictionary(right.map { ($0.memberIdentity!, $0) }, uniquingKeysWith: { first, _ in first })
      for id in Set(leftMap.keys).union(rightMap.keys).sorted() { walk(file, path + [.member(id)], leftMap[id], rightMap[id]) }
      let leftOrder: JSONValue = .array(left.compactMap(\.memberIdentity).map(JSONValue.string))
      let rightOrder: JSONValue = .array(right.compactMap(\.memberIdentity).map(JSONValue.string))
      if leftOrder != rightOrder {
        result.append(.init(file: file, path: path + [.order], before: leftOrder, after: rightOrder))
      }
    } else { result.append(.init(file: file, path: path, before: a, after: b)) }
  }
  for file in Set(before.keys).union(after.keys).sorted() { walk(file, [], before[file], after[file]) }
  for index in result.indices {
    result[index].afterVersion = collaborationFieldVersion(file: after[result[index].file], path: result[index].path)
  }
  return result
}

private func collaborationFieldVersion(file: JSONValue?, path: [CollaborationPathComponent]) -> ContentFieldVersion? {
  guard var owner = file else { return nil }
  var local = path
  if local.count >= 3, local[0] == .field("boards"), local[2] == .field("board") {
    guard let board = owner.value(at: local.prefix(3)) else { return nil }
    owner = board
    local = Array(local.dropFirst(3))
  }
  guard let first = local.first, case .field(let collection) = first else { return nil }
  var parts = [collection]
  if local.count > 1 {
    switch local[1] {
    case .order: parts.append("order")
    case .member(let id):
      parts.append(collaborationIdentity(id))
      if local.count > 2, case .field(let field) = local[2] {
        parts.append(["source", "html", "kind"].contains(field) ? "content" : field)
      } else { parts.append("exists") }
    case .field: return nil
    }
  }
  return try? owner["collaboration"]?["fields"]?[fieldKey(parts)]?.decode(ContentFieldVersion.self)
}

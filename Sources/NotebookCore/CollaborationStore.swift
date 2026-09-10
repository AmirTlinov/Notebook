import Foundation

extension NotebookStore {
  public var collaborationURL: URL { root.appendingPathComponent("collaboration", isDirectory: true) }
  public var collaborationActionsURL: URL { collaborationURL.appendingPathComponent("actions", isDirectory: true) }

  public func collaborationActorID() throws -> UUID {
    try commandTransaction {
      if let value = try storedValue("local/actor.json") { return try value.decode(UUID.self) }
      let actor = UUID()
      try publishRecords(writes: ["local/actor.json": try .encode(actor)])
      return actor
    }
  }

  public func collaborationActions() throws -> [CollaborationReceipt] {
    try prepare()
    return try readTransaction { _ in try loadCollaborationActions() }
  }

  private func loadCollaborationActions() throws -> [CollaborationReceipt] {
    try storedValues(prefix: "collaboration/actions/").map { try $0.decode(CollaborationReceipt.self) }
      .sorted { $0.createdAt > $1.createdAt }
  }

  public func collaborationAction(_ id: UUID) throws -> CollaborationReceipt {
    try prepare()
    return try readTransaction { _ in try loadAction(id) }
  }

  public func collaborationContinuations(_ id: UUID) throws -> [CollaborationContinuation] {
    try prepare()
    return try readTransaction { _ in
      let receipt = try loadAction(id)
      return receipt.continuations(in: try actionSourceProjection(receipt.action, receipt: receipt))
    }
  }

  private func actionFile(_ id: UUID) -> String {
    "collaboration/actions/\(id.uuidString.lowercased()).json"
  }

  private func loadAction(_ id: UUID) throws -> CollaborationReceipt {
    guard let value = try storedValue(actionFile(id)) else {
      throw CollaborationError("target_missing", "Ход не найден: \(id)")
    }
    return try value.decode(CollaborationReceipt.self)
  }

  @discardableResult
  public func applyCollaborationAction(_ action: CollaborationAction, actor: UUID, waitForInput: TimeInterval = 0) throws -> CollaborationReceipt {
    try waitingForInput(waitForInput) { try applyCollaborationActionImmediately(action, actor: actor) }
  }

  private func applyCollaborationActionImmediately(_ action: CollaborationAction, actor: UUID) throws -> CollaborationReceipt {
    try prepare()
    return try withMutationLock {
      if try hasStoredValue(actionFile(action.id)) {
        let previous = try loadAction(action.id)
        guard previous.action == action else {
          throw CollaborationError("action_id_conflict", "Этот ID уже принадлежит другому ходу.")
        }
        return previous
      }
      // Old receipts remain readable/idempotent, but their archived request ID
      // cannot authorize a new mutation after the embedded executor is removed.
      guard action.requestID == nil else {
        throw CollaborationError("archived_request", "Архивный запрос не может исполнять новые действия.")
      }
      guard !action.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        action.summary.count <= 1000, (1...512).contains(action.operations.count),
        action.references.count <= 32, (action.additionalOwners?.count ?? 0) <= 32 else {
        throw CollaborationError("invalid_action", "Ход содержит описание и от 1 до 512 операций.")
      }
      let contextReferences = try action.contextID.map { try self.contextReferences($0) }
      let before = try CollaborationWorkspace(files: actionSourceProjection(action, references: contextReferences ?? []))
      try requireIdleInput(for: action.operations.map(\.target))
      let scopeReferences = contextReferences ?? action.references
      for expectation in action.expected {
        let actual = try before.revision(of: expectation.target)
        if let expectedInk = expectation.inkRevision, try before.inkRevision(of: expectation.target) != expectedInk.lowercased() {
          throw CollaborationError("revision_conflict", "Чернила изменились. Рассмотрите поверхность заново.", target: expectation.target,
            expected: expectedInk, actual: try before.inkRevision(of: expectation.target))
        }
        if let expectedSource = expectation.sourceRevision {
          let source = try referenceRevision(target: expectation.target)
          guard source == expectedSource else {
            throw CollaborationError("revision_conflict", "Содержание и геометрия изменились. Рассчитайте место заново.", target:expectation.target,expected:expectedSource,actual:source)
          }
        }
        if let expectedState = expectation.stateRevision, try before.stateRevision(of:expectation.target) != expectedState.lowercased() {
          throw CollaborationError("revision_conflict", "Состояние блока изменилось.", target:expectation.target, expected:expectedState, actual:try before.stateRevision(of:expectation.target))
        }
        guard actual == expectation.revision.lowercased() else {
          throw CollaborationError("revision_conflict", "Владелец изменился. Прочитайте его текущую версию.",
            target: expectation.target, expected: expectation.revision, actual: actual)
        }
      }
      var after = before
      var createdTargets = Set<CollaborationTarget>()
      var inkPointCount = 0
      for operation in action.operations {
        if operation.kind == .appendInkStroke {
          inkPointCount += operation.values["points"]?.array.count ?? 0
          guard inkPointCount <= 100_000 else { throw invalid("Один ход содержит не более 100000 точек ручки.") }
          guard createdTargets.contains(operation.target) || action.expected.contains(where: {
            $0.target == operation.target && $0.inkRevision != nil
          }) else { throw CollaborationError("revision_required", "Для ручки нужна inkRevision: drawingRevision листа либо spatialInkRevision доски/обложки.", target: operation.target) }
        }
        for subject in try Self.compositionSubjects(operation, files: before.files) where !createdTargets.contains(subject.target) {
          try Self.requireCompositionScope(subject, references: scopeReferences, additionalOwners: action.additionalOwners ?? [], files: before.files)
        }
        for target in try before.requiredExpectations(for: operation) {
          guard createdTargets.contains(target) || action.expected.contains(where: { $0.target == target }) else {
            throw CollaborationError("revision_required", "Для изменения нужна версия владельца.", target: target)
          }
        }
        if operation.kind == .setBlockState, !action.expected.contains(where: { $0.target == operation.target && $0.stateRevision != nil }) {
          throw CollaborationError("revision_required", "Для состояния блока нужна stateRevision документа.", target:operation.target)
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
      try after.validate(scope: self)
      let changes = collaborationDiff(before.files, after.files).filter { !action.ownsInkField($0) }
      let receipt = CollaborationReceipt(id: action.id, action: action, createdAt: Date(),
        revisions: try after.changedTargets(from: before).map {
          CollaborationExpectation(target: $0, revision: try after.revision(of: $0), stateRevision: try after.stateRevision(of:$0),
            inkRevision: action.containsInk ? try after.inkRevision(of: $0) : nil)
        }, changes: changes)
      try commitCollaboration(before: before.files, after: after.files, receipt: receipt)
      return receipt
    }
  }

  @discardableResult
  public func undoCollaborationAction(_ id: UUID, actor: UUID, waitForInput: TimeInterval = 0) throws -> CollaborationReceipt {
    try waitingForInput(waitForInput) { try undoCollaborationActionImmediately(id, actor: actor) }
  }

  private func undoCollaborationActionImmediately(_ id: UUID, actor: UUID) throws -> CollaborationReceipt {
    try prepare()
    return try withMutationLock {
      var receipt = try loadAction(id)
      if receipt.undo != nil { return receipt }
      let before = try CollaborationWorkspace(files: actionSourceProjection(receipt.action, receipt: receipt))
      try requireIdleInput(for: receipt.action.operations.map(\.target))
      var after = before
      var preserved: [CollaborationFieldChange] = []
      let protected = try before.protectedCreationChanges(in: receipt, scope: self)
      var restored = 0
      for operation in receipt.action.operations where operation.kind == .appendInkStroke {
        if try after.undoInk(operation, actor: actor) { restored += 1 }
      }
      for change in receipt.changes {
        let current = before.files[change.file]?.value(at: change.path[...])
        let version = collaborationFieldVersion(file: before.files[change.file], path: change.path)
        let stillOwned = change.afterVersion == nil || (version?.stamp == change.afterVersion?.stamp
          && version?.human == change.afterVersion?.human)
        guard !protected.contains(change),
          stillOwned,
          collaborationComparable(current, file: change.file, path: change.path) == collaborationComparable(change.after, file: change.file, path: change.path) else {
          preserved.append(change)
          continue
        }
        if change.file.hasPrefix("document-states/"), change.before == nil, change.path.count == 2,
          change.path[0] == .field("records"), case .member(let blockID) = change.path[1],
          let documentID = UUID(uuidString:URL(fileURLWithPath:change.file).deletingPathExtension().lastPathComponent),
          let document = try? after.files[documentFile(documentID)]?.decode(DocumentDocument.self),
          let block = document.blocks.first(where: { $0.id == blockID }), let current {
          after.files[change.file] = after.files[change.file]?.setting(at:change.path[...],to:current.setting("value",block.initialState))
        } else if let value = after.files[change.file] {
          if change.file.hasPrefix("document-states/"), change.path.last == .order { continue }
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
      try after.validate(scope: self)
      receipt.undo = CollaborationUndoResult(restored: restored, preserved: preserved, completedAt: Date())
      receipt.revisions = try after.changedTargets(from: before).map {
        CollaborationExpectation(target: $0, revision: try after.revision(of: $0), stateRevision: try after.stateRevision(of:$0),
          inkRevision: receipt.action.containsInk ? try after.inkRevision(of: $0) : nil)
      }
      try commitCollaboration(before: before.files, after: after.files, receipt: receipt)
      return receipt
    }
  }

  private func commitCollaboration(before: [String: JSONValue], after: [String: JSONValue],
    receipt: CollaborationReceipt) throws {
    var writes = after.filter { before[$0.key] != $0.value }
    writes[actionFile(receipt.id)] = try .encode(receipt)
    let contextID = receipt.action.resolvedContextID
    let exists = try hasStoredValue(contextFile(contextID))
    if exists, receipt.action.contextID == nil {
      guard let entry = try sharedContextEntry(contextID: contextID, entryID: receipt.id),
        entry.author == .agent, entry.references == receipt.action.references else {
        throw CollaborationError("context_id_conflict", "ID самостоятельного хода уже принадлежит другому контексту.")
      }
    }
    if !exists {
      if receipt.action.contextID != nil { throw CollaborationError("context_missing", "Контекст хода не найден.") }
      let entry = SharedContextEntry(id: receipt.id, author: .agent, references: receipt.action.references, text: receipt.action.summary,
        stamp: .init(counter: 1, actor: receipt.id), createdAt: receipt.createdAt)
      writes[contextFile(receipt.action.resolvedContextID)] = try .encode(SharedContext(id: receipt.action.resolvedContextID, entries: [entry]))
    }
    // The command's catalogue/tree/ink are addressed projections. Publish only
    // fields changed from its baseline; unseen SQL members retain their owners.
    let projected = writes.filter { ["workspace.json", "board.json", "spatial-ink.json"].contains($0.key) }
    for file in projected.keys { writes[file] = nil }
    try publishCollaboration(writes: writes, removals: before.keys.filter { after[$0] == nil })
    for file in ["workspace.json", "board.json", "spatial-ink.json"] {
      if let old = before[file], let next = projected[file] {
        try publishProjectionEdits(file: file, before: old, after: next)
      }
    }
  }

  func publishCollaboration(writes: [String: JSONValue], removals: [String] = []) throws {
    try publishRecords(writes: writes, removals: removals)
  }

  public func collaborationContent() throws -> CollaborationContent {
    try prepare()
    return try readTransaction { _ in try loadCollaborationContent() }
  }

  private func loadCollaborationContent() throws -> CollaborationContent {
    let workspace = try loadIndex()
    return try CollaborationContent(workspace: workspace, hierarchy: loadBoard(items: workspace.items), ink: loadSpatialInk(),
      pages: workspace.items.flatMap(\.pageIDs).map(loadPage),
      documents: workspace.items.filter { $0.kind == .document }.map { try loadDocument($0.id) },
      states: workspace.items.filter { $0.kind == .document }.map { try loadDocumentState($0.id) })
  }

  /// Disk, memory and the received cut meet under the same recoverable commit.
  public func mergeCollaborationContent(_ incoming: CollaborationContent?,
    local: CollaborationContent? = nil, actions: [CollaborationReceipt] = [], contexts: [SharedContext] = [], selection: SharedContextSelection? = nil) throws -> CollaborationContent {
    try CollaborationEnvelope(content: incoming, actions: actions, contexts: contexts, selection: selection).validate()
    try local?.validate()
    try prepare()
    return try withMutationLock {
      let before = try loadCollaborationContent()
      var merged = before
      if let local { try merged.merge(local) }
      if let incoming { try merged.merge(incoming) }
      var writes: [String: JSONValue] = [:]
      var removals: [String] = []
      if merged != before {
        let files = try merged.sourceFiles()
        try CollaborationWorkspace(files: files).validate()
        let old = try before.sourceFiles()
        writes = files.filter { old[$0.key] != $0.value }
        removals = old.keys.filter { files[$0] == nil }
      }
      for incoming in actions {
        if let current = try? loadAction(incoming.id) {
          guard current.action == incoming.action else { throw CollaborationError("action_id_conflict", "Разные ходы имеют одинаковый ID.") }
          if current.undo != nil || current == incoming { continue }
        }
        writes[actionFile(incoming.id)] = try .encode(incoming)
      }
      let metadata = try contextWrites(contexts, selection: selection)
      writes.merge(metadata) { _, new in new }
      let known = Set(try readSharedContexts().map(\.id)).union(contexts.map(\.id))
      for receipt in actions where !known.contains(receipt.action.resolvedContextID) {
        guard receipt.action.contextID == nil else { throw CollaborationError("context_missing", "Ход должен поступить вместе со своим контекстом.") }
        let entry = SharedContextEntry(id: receipt.id, author: .agent, references: receipt.action.references, text: receipt.action.summary, stamp: .init(counter: 1, actor: receipt.id), createdAt: receipt.createdAt)
        writes[contextFile(receipt.action.resolvedContextID)] = try .encode(SharedContext(id: receipt.action.resolvedContextID, entries: [entry]))
      }
      try publishCollaboration(writes: writes, removals: removals)
      return merged
    }
  }

}

extension CollaborationReceipt {
  /// A receipt keeps the original contribution; these addresses name the fields
  /// whose current owner has continued it since publication.
  public func continuations(in files: [String:JSONValue]) -> [CollaborationContinuation] {
    guard undo == nil else { return [] }
    return changes.compactMap { change in
      let current = files[change.file]?.value(at:change.path[...])
      guard collaborationComparable(current, file: change.file, path: change.path) != collaborationComparable(change.after, file: change.file, path: change.path) else { return nil }
      let version = collaborationFieldVersion(file:files[change.file],path:change.path)
      return .init(file:change.file,path:change.path,author:current == nil ? .removed : version?.human == false ? .agent : .human)
    }
  }
}

private struct CollaborationCreationProtection {
  struct Address: Equatable {
    let file: String
    let path: [CollaborationPathComponent]

    init(_ file: String, _ path: [CollaborationPathComponent] = []) {
      self.file = file
      self.path = path.map { if case .member(let id) = $0 { .member(collaborationIdentity(id)) } else { $0 } }
    }

    func contains(_ other: Self) -> Bool { file == other.file && other.path.starts(with: path) }
  }

  let addresses: [Address]
  func contains(_ change: CollaborationFieldChange) -> Bool {
    let address = Address(change.file, change.path)
    return addresses.contains { $0.contains(address) }
  }
}

struct CollaborationWorkspace {
  var files: [String: JSONValue]
  init(files: [String: JSONValue]) { self.files = files }
  var ink: SpatialInkJournal { get throws { try files["spatial-ink.json"]!.decode(SpatialInkJournal.self) } }

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
    files["spatial-ink.json"] = try .encode(store.loadSpatialInk())
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

  func stateRevision(of target: CollaborationTarget) throws -> String? {
    guard target.kind == .document else { return nil }
    return try files[stateFile(target.id)]?.decode(DocumentStateJournal.self).stamp.revision
  }

  func inkRevision(of target: CollaborationTarget) throws -> String? {
    switch target.kind {
    case .page: return try files[pageFile(target.id)]?.decode(PageDocument.self).drawingStamp.revision
    case .board, .cover: return try files["spatial-ink.json"]?["stamp"]?.decode(VersionStamp.self).revision
    default: return nil
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
    case .appendInkStroke:
      try appendInk(operation, actor: actor)
    case .insertElement, .updateElement, .setElementState, .removeElement, .reorderElements:
      try editElements(operation, actor: actor)
    case .setBlockState:
      guard operation.target.kind == .document, let id = operation.id, let value = operation.values["state"],
        let raw = files[documentFile(operation.target.id)],
        try raw.decode(DocumentDocument.self).blocks.contains(where: { $0.id == id && $0.kind == .interactive }),
        let rawState = files[stateFile(operation.target.id)] else { throw missing(operation.target) }
      var state = try rawState.decode(DocumentStateJournal.self)
      _ = state.commit(blockID:id,value:value,actor:actor,human:false)
      files[stateFile(operation.target.id)] = try .encode(state)
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

  mutating func appendInk(_ operation: CollaborationOperation, actor: UUID) throws {
    let stroke = try CollaborationInkStroke(operation)
    let target = operation.target
    if target.kind == .page {
      guard let raw = files[pageFile(target.id)] else { throw missing(target) }
      var page = try raw.decode(PageDocument.self)
      guard stroke.region.isContained(in: page.size) else { throw invalid("Штрих целиком помещается в физический лист.") }
      let drawing = try PageInkDrawing.decode(page.drawingData)
      guard !drawing.actions.contains(where: { $0.id == stroke.id }) else { throw invalid("UUID штриха уже занят.") }
      let next = drawing.appending(stroke.pageAction)
      guard next != drawing, page.replaceDrawing(try next.dataRepresentation(), actor: actor) else { throw invalid("Не удалось добавить штрих.") }
      files[pageFile(target.id)] = try .encode(page)
    } else {
      guard try hierarchy.board(boardID(for: target)) != nil else { throw missing(target) }
      if target.kind == .cover {
        guard let item = try workspace.items.first(where: { $0.id == target.id }) else { throw missing(target) }
        let geometry = item.kind == .document
          ? WorkspaceItemGeometry.document(try files[documentFile(item.id)]!.decode(DocumentDocument.self).paperSize)
          : .notebook
        guard stroke.region.isContained(in: .init(width: geometry.width, height: geometry.height)) else {
          throw invalid("Штрих целиком помещается в физическую обложку.")
        }
      }
      var journal = try ink
      guard journal.append(tool: .pen, color: stroke.color, spans: [stroke.span(on: target)], actor: actor, id: stroke.id) != nil else {
        throw invalid("UUID штриха уже занят либо достигнут предел версии.")
      }
      files["spatial-ink.json"] = try .encode(journal)
    }
  }

  mutating func undoInk(_ operation: CollaborationOperation, actor: UUID) throws -> Bool {
    let stroke = try CollaborationInkStroke(operation)
    if operation.target.kind == .page {
      guard let raw = files[pageFile(operation.target.id)] else { return false }
      var page = try raw.decode(PageDocument.self)
      let drawing = try PageInkDrawing.decode(page.drawingData)
      guard let existing = drawing.actions.first(where: { $0.id == stroke.id }), existing.isActive,
        existing.tool == .pen, existing.color == stroke.color, existing.samples == stroke.samples else { return false }
      guard page.replaceDrawing(try drawing.removing([stroke.id]).dataRepresentation(), actor: actor) else { return false }
      files[pageFile(page.id)] = try .encode(page)
    } else {
      var journal = try ink
      guard let existing = journal.actions.first(where: { $0.id == stroke.id }),
        existing.tool == .pen, existing.color == stroke.color, existing.spans == [stroke.span(on: operation.target)],
        journal.deactivate(stroke.id, actor: actor) else { return false }
      files["spatial-ink.json"] = try .encode(journal)
    }
    return true
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
    files["workspace.json"] = try .encode(index)
    files["board.json"] = try .encode(tree)
  }

  func validate(scope: NotebookStore? = nil) throws {
    let index = try workspace
    guard try ink.isValid else { throw invalid("Журнал чернил должен быть завершён.") }
    guard index.isValid else { throw invalid("Каталог содержит допустимых владельцев.") }
    if scope == nil {
      guard try hierarchy.isValid(items: index.items) else { throw invalid("Каждый предмет имеет одного владельца на доске.") }
    } else {
      for node in try hierarchy.boards {
        guard node.board.isValid(itemIDs: Set(node.board.itemIDs)), node.portalCamera.isValid else { throw invalid("Доска содержит допустимые адресные изменения.") }
      }
    }
    for item in index.items {
      for pageID in item.pageIDs {
        guard let value = files[pageFile(pageID)] else {
          if let scope, try scope.hasStoredValue(pageFile(pageID)) { continue }
          throw invalid("Тетрадь содержит существующие листы.")
        }
        let page = try value.decode(PageDocument.self)
        guard page.id == pageID, page.isValid else { throw invalid("Элементы помещаются в физический лист.") }
      }
      if item.kind == .document {
        guard let document = files[documentFile(item.id)], try document.decode(DocumentDocument.self).isValid else { throw invalid("Документ содержит согласованные блоки.") }
        if let state = files[stateFile(item.id)] {
          guard try state.decode(DocumentStateJournal.self).isValid else { throw invalid("Документ содержит допустимое состояние.") }
        } else if let scope {
          guard try scope.hasStoredValue(stateFile(item.id)) else { throw invalid("Документ содержит существующее состояние.") }
        } else { throw invalid("Документ содержит существующее состояние.") }
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
      if item.kind == .document, (files[documentFile(item.id)] != previous.files[documentFile(item.id)] || files[stateFile(item.id)] != previous.files[stateFile(item.id)]) { targets.append(.init(kind: .document, id: item.id)) }
    }
    if files["spatial-ink.json"] != previous.files["spatial-ink.json"] {
      let oldInk = Dictionary(uniqueKeysWithValues: try previous.ink.actions.map { ($0.id, $0) })
      let tree = try hierarchy
      for action in try ink.actions where oldInk[action.id] != action {
        for span in action.spans {
          guard let id = span.surface.ownerID else { continue }
          let board = tree.ownerBoardID(of: id)
          guard span.surface.kind == .board ? tree.board(id) != nil : board != nil else { continue }
          let target = CollaborationTarget(kind: span.surface.kind == .board ? .board : .cover,
            id: id, boardID: span.surface.kind == .cover ? board : nil)
          if !targets.contains(target) { targets.append(target) }
        }
      }
    }
    return targets
  }

  mutating func restampChanges(from previous: Self, actor: UUID) throws {
    for target in try changedTargets(from: previous) {
      switch target.kind {
      case .workspace: files["workspace.json"] = try advancing(files["workspace.json"]!, key: "stamp", actor: actor)
      case .page:
        guard let page = files[pageFile(target.id)] else {
          throw invalid("Отмена не может оставить тетрадь без принадлежащего ей листа.")
        }
        if page["elements"] != previous.files[pageFile(target.id)]?["elements"] {
          files[pageFile(target.id)] = try advancing(page, key: "agentStamp", actor: actor)
        }
      case .document:
        guard let document = files[documentFile(target.id)] else {
          throw invalid("Отмена не может оставить предмет без принадлежащего ему документа.")
        }
        if document != previous.files[documentFile(target.id)] {
          files[documentFile(target.id)] = try advancing(document, key: "contentStamp", actor: actor)
        }
        if var value = files[stateFile(target.id)], let old = previous.files[stateFile(target.id)], value != old {
          let next = try old["stamp"]!.decode(VersionStamp.self).advanced(by:actor)!
          var records = value["records"]?.array ?? []
          for index in records.indices {
            let prior = old["records"]?.array.first { $0.memberIdentity == records[index].memberIdentity }
            guard let recordID = records[index].memberIdentity else { throw invalid("Состояние блока требует устойчивого ID.") }
            let recordPath: [CollaborationPathComponent] = [.field("records"), .member(recordID)]
            if collaborationComparable(prior, file: stateFile(target.id), path: recordPath)
              != collaborationComparable(records[index], file: stateFile(target.id), path: recordPath) {
              let previousVersion = try prior?["fieldVersion"]?.decode(ContentFieldVersion.self)
              records[index] = records[index].setting("stamp",try .encode(next)).setting("fieldVersion",try .encode(ContentFieldVersion(stamp:next,human:true,previous:previousVersion)))
            }
          }
          value = value.setting("records",.array(records)).setting("stamp",try .encode(next))
          files[stateFile(target.id)] = value
        }
      case .board:
        let path: [CollaborationPathComponent] = [.field("boards"), .member(target.id.uuidString), .field("board")]
        let tree = files["board.json"]!
        if let board = tree.value(at: path[...]) {
          guard board != previous.files["board.json"]?.value(at: path[...]) else { continue }
          let next = try advancing(board, key: "stamp", actor: actor)
          files["board.json"] = tree.setting(at: path[...], to: next)
        }
      case .cover: break
      }
    }
    if files["board.json"] != previous.files["board.json"] { files["board.json"] = try advancing(files["board.json"]!, key: "stamp", actor: actor) }
  }

  mutating func recordFieldChanges(from previous: Self, human: Bool) throws {
    if files["workspace.json"] != previous.files["workspace.json"] {
      var index = try workspace
      try index.recordChanges(from: previous.workspace, human: human)
      files["workspace.json"] = try .encode(index)
    }
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
      guard current != old else { continue }
      let stamp = try current[stampKey]!.decode(VersionStamp.self)
      let beforeStamp = try old[stampKey]?.decode(VersionStamp.self) ?? stamp
      var metadata = try old["collaboration"]?.decode(CollaborativeContent.self) ?? CollaborativeContent()
      let previousMetadata = metadata
      let oldContent = target.kind == .page ? old.setting("computations", nil) : old
      let newContent = target.kind == .page ? current.setting("computations", nil) : current
      metadata.record(before: oldContent, after: newContent, beforeStamp: beforeStamp, stamp: stamp, human: human)
      guard metadata != previousMetadata else { continue }
      files[file] = files[file]!.setting(at: path[...], to: current.setting("collaboration", try .encode(metadata)))
    }
  }

  fileprivate func protectedCreationChanges(in receipt: CollaborationReceipt, scope: NotebookStore) throws -> CollaborationCreationProtection {
    typealias Address = CollaborationCreationProtection.Address
    var created: [UUID: CollaborationOperation] = [:]
    for op in receipt.action.operations where [.createNotebook, .createDocument, .createBoard].contains(op.kind) {
      guard let id = op.id.flatMap(UUID.init(uuidString:)), created[id] == nil else {
        throw invalid("Квитанция создания перечисляет каждого нового владельца ровно один раз.")
      }
      created[id] = op
    }
    guard !created.isEmpty else { return .init(addresses: []) }
    let changes = receipt.changes.map { (Address($0.file, $0.path), $0) }
    func authored(_ address: Address) -> JSONValue? {
      guard let (parent, change) = changes.first(where: { $0.0.contains(address) }) else { return nil }
      return change.after?.value(at: Array(address.path.dropFirst(parent.path.count))[...])
    }
    func current(_ address: Address) -> JSONValue? { files[address.file]?.value(at: address.path[...]) }
    var owned: [UUID: [Address]] = [:]
    func own(_ address: Address, by id: UUID) {
      guard created[id] != nil, authored(address) != nil, !owned[id, default: []].contains(address) else { return }
      owned[id, default: []].append(address)
    }
    for (id, op) in created {
      own(Address("workspace.json", [.field("items"), .member(id.uuidString)]), by: id)
      switch op.kind {
      case .createNotebook:
        if let page = op.values["pageID"]?.string.flatMap(UUID.init(uuidString:)) { own(Address(pageFile(page)), by: id) }
      case .createDocument:
        own(Address(documentFile(id)), by: id); own(Address(stateFile(id)), by: id)
      case .createBoard: own(Address("board.json", [.field("boards"), .member(id.uuidString)]), by: id)
      default: break
      }
    }
    // Receipts may own a whole newly created node. Recover its authored
    // placements, not a fresh full hierarchy, and retain exact member addresses.
    var authoredTree = files["board.json"]
    for (address, change) in changes where address.file == "board.json" {
      authoredTree = authoredTree?.setting(at: address.path[...], to: change.after)
    }
    for tree in [authoredTree, files["board.json"]].compactMap({ $0 }) {
      for node in tree["boards"]?.array ?? [] {
        guard let boardID = node.memberIdentity else { continue }
        let base: [CollaborationPathComponent] = [.field("boards"), .member(boardID), .field("board")]
        for placement in node["board"]?["freeItems"]?.array ?? [] {
          guard let id = placement["itemID"]?.string.flatMap(UUID.init(uuidString:)) else { continue }
          own(Address("board.json", base + [.field("freeItems"), .member(id.uuidString)]), by: id)
        }
        for stack in node["board"]?["stacks"]?.array ?? [] {
          guard let stackID = stack.memberIdentity else { continue }
          for id in try stack["itemIDs"]?.decode([UUID].self) ?? [] {
            own(Address("board.json", base + [.field("stacks"), .member(stackID)]), by: id)
          }
        }
        for element in node["board"]?["elements"]?.array ?? [] {
          guard let elementID = element.memberIdentity, let surface = try element["surface"]?.decode(SurfaceID.self),
            surface.kind == .cover, let id = surface.ownerID else { continue }
          own(Address("board.json", base + [.field("elements"), .member(elementID)]), by: id)
        }
      }
    }
    var protected = Set<UUID>()
    for (id, op) in created {
      guard current(Address("workspace.json", [.field("items"), .member(id.uuidString)])) != nil else { continue }
      if (owned[id] ?? []).contains(where: { address in
        let value = current(address)
        if collaborationComparable(value, file: address.file, path: address.path)
          != collaborationComparable(authored(address), file: address.file, path: address.path) { return true }
        // Existence has its own causal owner: a human edit and later return to
        // the same visible value must not detach a retained item from its paper.
        guard let change = changes.first(where: { $0.0 == address })?.1, let expected = change.afterVersion else { return false }
        let version = collaborationFieldVersion(file: files[address.file], path: address.path)
        return version?.stamp != expected.stamp || version?.human != expected.human
      }) { protected.insert(id) }
      if op.kind == .createNotebook, try scope.pageCount(in: id) != 1 { protected.insert(id) }
      // The command projection contains the authored members, not every later
      // child. One indexed existence query detects outside adoption without
      // materializing an unbounded board or relying on its arbitrary first row.
      let node = Address("board.json", [.field("boards"), .member(id.uuidString)])
      let authoredNode = authored(node)
      var authoredChildren: [String] = []
      for collection in ["freeItems", "stacks", "elements"] {
        for member in authoredNode?["board"]?[collection]?.array ?? [] {
          if let identity = member.memberIdentity { authoredChildren.append("board.json#/boards/@" + id.uuidString.lowercased() + "/board/" + collection + "/@" + fieldKey([identity])) }
        }
      }
      let coverAddresses = (owned[id] ?? []).filter { $0.file == "board.json" && $0.path.count == 5 && $0.path[3] == .field("elements") }.map { address in
        guard case .member(let board) = address.path[1], case .member(let element) = address.path[4] else { preconditionFailure("Typed cover address") }
        return "board.json#/boards/@" + board + "/board/elements/@" + fieldKey([element])
      }
      let outside = try scope.sqlRead { database in
        func excluding(_ addresses: [String]) -> String { addresses.isEmpty ? "" : " AND address NOT IN (" + addresses.map { _ in "?" }.joined(separator: ",") + ")" }
        if op.kind == .createBoard,
          try !database.rows("SELECT 1 FROM records WHERE parent=? AND collection IN ('board/freeItems','board/stacks','board/elements')" + excluding(authoredChildren) + " LIMIT 1",
            [.text("board.json#/boards/@" + id.uuidString.lowercased())] + authoredChildren.map(NotebookSQLValue.text)).isEmpty { return true }
        return try !database.rows("SELECT 1 FROM spatial_entries WHERE kind='coverElement' AND owner_id=?" + excluding(coverAddresses) + " LIMIT 1",
          [.text(id.uuidString.lowercased())] + coverAddresses.map(NotebookSQLValue.text)).isEmpty
      }
      if outside { protected.insert(id) }
    }
    let contributedInk = Set(receipt.action.operations.filter { $0.kind == .appendInkStroke }.compactMap { $0.id.flatMap(UUID.init(uuidString:)) })
    for action in try ink.actions where action.isActive && !contributedInk.contains(action.id) {
      for span in action.spans { if let id = span.surface.ownerID, created[id] != nil { protected.insert(id) } }
    }
    let tree = try hierarchy
    // Closure follows actual physical dependencies. An adopted newly-created
    // node/stack is one receipt value, so its still-referenced created children
    // remain complete; independent creations on another placement are undoable.
    var pending = Array(protected)
    while let id = pending.popLast() {
      var required: Set<UUID> = []
      if let parent = tree.ownerBoardID(of: id), created[parent] != nil { required.insert(parent) }
      if created[id]?.kind == .createBoard, let board = tree.board(id) { required.formUnion(board.itemIDs.filter { created[$0] != nil }) }
      for address in owned[id] ?? [] where address.path.count == 5 && address.path[3] == .field("stacks") {
        required.formUnion(try current(address)?["itemIDs"]?.decode([UUID].self).filter { created[$0] != nil } ?? [])
      }
      for other in required where protected.insert(other).inserted { pending.append(other) }
    }
    var addresses: [Address] = []
    for id in protected {
      for address in owned[id] ?? [] {
        if !addresses.contains(address) { addresses.append(address) }
        if case .member? = address.path.last {
          let order = Address(address.file, Array(address.path.dropLast()) + [.order])
          if !addresses.contains(order) { addresses.append(order) }
        }
      }
    }
    return .init(addresses: addresses)
  }
}

func pageFile(_ id: UUID) -> String { "pages/\(id.uuidString.lowercased()).json" }
func documentFile(_ id: UUID) -> String { "documents/\(id.uuidString.lowercased()).json" }
func stateFile(_ id: UUID) -> String { "document-states/\(id.uuidString.lowercased()).json" }
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

/// Versions belong to exact domain objects, never to a spelling inside a
/// program's JSON. Diff, undo, adoption and continuation use this same owner.
private enum CollaborationValueOwner: Equatable {
  case workspace, workspaceItems, workspaceItem
  case hierarchy, boards, boardNode, board
  case page, pageElements, pageElement
  case document, blocks, block
  case stateJournal, stateRecords, stateRecord
  case inkJournal, inkActions, inkAction
  case placements, placement, stacks, stack, spatialElements, spatialElement
  case value, opaque

  init(file: String, path: [CollaborationPathComponent]) {
    let root: Self
    switch file {
    case "workspace.json": root = .workspace
    case "board.json": root = .hierarchy
    case "spatial-ink.json": root = .inkJournal
    default:
      let parts = file.split(separator: "/")
      if parts.count == 2, parts[1].hasSuffix(".json"), UUID(uuidString: String(parts[1].dropLast(5))) != nil {
        switch parts[0] {
        case "pages": root = .page
        case "documents": root = .document
        case "document-states": root = .stateJournal
        default: root = .value
        }
      } else { root = .value }
    }
    self = path.reduce(root) { $0.child($1) }
  }

  private func child(_ component: CollaborationPathComponent) -> Self {
    switch (self, component) {
    case (.workspace, .field("items")): .workspaceItems
    case (.workspaceItems, .member(_)): .workspaceItem
    case (.hierarchy, .field("boards")): .boards
    case (.boards, .member(_)): .boardNode
    case (.boardNode, .field("board")): .board
    case (.board, .field("freeItems")): .placements
    case (.placements, .member(_)): .placement
    case (.board, .field("stacks")): .stacks
    case (.stacks, .member(_)): .stack
    case (.board, .field("elements")): .spatialElements
    case (.spatialElements, .member(_)): .spatialElement
    case (.page, .field("elements")): .pageElements
    case (.pageElements, .member(_)): .pageElement
    case (.document, .field("blocks")): .blocks
    case (.blocks, .member(_)): .block
    case (.stateJournal, .field("records")): .stateRecords
    case (.stateRecords, .member(_)): .stateRecord
    case (.inkJournal, .field("actions")): .inkActions
    case (.inkActions, .member(_)): .inkAction
    case (.pageElement, .field("state")), (.spatialElement, .field("state")),
      (.block, .field("initialState")), (.stateRecord, .field("value")): .opaque
    case (.opaque, _): .opaque
    default: .value
    }
  }

  func ownsMetadata(_ key: String) -> Bool {
    switch (self, key) {
    case (.workspace, "stamp"), (.workspace, "collaboration"),
      (.workspace, "pageOrders"), (.workspace, "pageOrderNodes"), (.workspace, "isProjection"),
      (.hierarchy, "stamp"), (.boardNode, "portalStamp"), (.board, "stamp"), (.board, "collaboration"),
      (.page, "agentStamp"), (.page, "drawingStamp"), (.page, "collaboration"),
      (.document, "contentStamp"), (.document, "collaboration"),
      (.stateJournal, "stamp"), (.stateRecord, "stamp"), (.stateRecord, "fieldVersion"),
      (.inkJournal, "stamp"), (.inkAction, "stamp"), (.inkAction, "stateStamp"),
      (.placement, "stamp"), (.stack, "stamp"), (.spatialElement, "stamp"):
      true
    default: false
    }
  }

  func comparable(_ value: JSONValue) -> JSONValue {
    // These values contain no domain-owned descendants. In particular state,
    // initialState and record.value retain every nested key and array entry.
    if self == .value || self == .opaque || self == .workspaceItem || self == .pageElement || self == .block { return value }
    switch value {
    case .object(let object):
      var result: [String: JSONValue] = [:]
      for (key, value) in object where !ownsMetadata(key) { result[key] = child(.field(key)).comparable(value) }
      return .object(result)
    case .array(let values):
      return .array(values.map { child(.member($0.memberIdentity ?? "")).comparable($0) })
    default: return value
    }
  }
}

private func collaborationComparable(_ value: JSONValue?, file: String, path: [CollaborationPathComponent]) -> JSONValue? {
  let owner = CollaborationValueOwner(file: file, path: path)
  return value.map { owner.comparable($0) }
}
private func collaborationDiff(_ before: [String: JSONValue], _ after: [String: JSONValue]) -> [CollaborationFieldChange] {
  var result: [CollaborationFieldChange] = []
  func walk(_ file: String, _ path: [CollaborationPathComponent], _ a: JSONValue?, _ b: JSONValue?) {
    let owner = CollaborationValueOwner(file: file, path: path)
    guard a.map({ owner.comparable($0) }) != b.map({ owner.comparable($0) }) else { return }
    if owner == .opaque {
      result.append(.init(file: file, path: path, before: a, after: b))
    } else if case .object(let left) = a, case .object(let right) = b {
      for key in Set(left.keys).union(right.keys).sorted() where !owner.ownsMetadata(key) {
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
  if local.count >= 2, local[0] == .field("records"), case .member(let id) = local[1],
    let record = owner["records"]?.array.first(where: { $0.memberIdentity == id }) {
    return (try? record["fieldVersion"]?.decode(ContentFieldVersion.self))
      ?? (try? record["stamp"]?.decode(VersionStamp.self)).map { .init(stamp:$0,human:true) }
  }
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
        parts.append(collection != "items" && ["source", "html", "kind"].contains(field) ? "content" : field)
      } else { parts.append("exists") }
    case .field: return nil
    }
  }
  return try? owner["collaboration"]?["fields"]?[fieldKey(parts)]?.decode(ContentFieldVersion.self)
}

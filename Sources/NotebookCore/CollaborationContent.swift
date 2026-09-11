import Foundation

/// One completed cut of the existing content owners crosses the device link.
/// Their field merge rules preserve local edits before this cut is published.
public struct CollaborationContent: Codable, Equatable, Sendable {
  public var workspace: WorkspaceIndex
  public var hierarchy: BoardHierarchy
  public var ink: SpatialInkJournal
  public var pages: [PageDocument]
  public var documents: [DocumentDocument]
  public var states: [DocumentStateJournal]

  public init(workspace: WorkspaceIndex, hierarchy: BoardHierarchy, ink: SpatialInkJournal,
    pages: [PageDocument], documents: [DocumentDocument], states: [DocumentStateJournal]) {
    self.workspace = workspace; self.hierarchy = hierarchy; self.ink = ink
    self.pages = pages.sorted { $0.id.uuidString < $1.id.uuidString }
    self.documents = documents.sorted { $0.id.uuidString < $1.id.uuidString }
    self.states = states.sorted { $0.id.uuidString < $1.id.uuidString }
  }

  init(files: [String: JSONValue]) throws {
    guard let index = files["workspace.json"], let board = files["board.json"], let ink = files["spatial-ink.json"] else {
      throw CollaborationError("target_missing", "Снимок должен содержать каталог, доски и чернила.")
    }
    try self.init(workspace: index.decode(WorkspaceIndex.self), hierarchy: board.decode(BoardHierarchy.self), ink: ink.decode(SpatialInkJournal.self),
      pages: files.filter { $0.key.hasPrefix("pages/") }.map { try $0.value.decode(PageDocument.self) },
      documents: files.filter { $0.key.hasPrefix("documents/") }.map { try $0.value.decode(DocumentDocument.self) },
      states: files.filter { $0.key.hasPrefix("document-states/") }.map { try $0.value.decode(DocumentStateJournal.self) })
  }

  public func validate() throws {
    try validateOwners()
    let pageIDs = Set(workspace.items.flatMap(\.pageIDs))
    let documentIDs = Set(workspace.items.filter { $0.kind == .document }.map(\.id))
    let owners = Dictionary(uniqueKeysWithValues: workspace.items.flatMap { item in item.pageIDs.map { ($0, item.id) } })
    guard pages.allSatisfy({ page in (page.computations ?? []).allSatisfy { owners[page.id] == $0.source.notebookID } }),
      pages.allSatisfy({ pageIDs.contains($0.id) }),
      documents.allSatisfy({ documentIDs.contains($0.id) }),
      states.allSatisfy({ documentIDs.contains($0.id) }) else {
      throw CollaborationError("invalid_content", "Содержание принадлежит владельцам переданного каталога.")
    }
  }

  /// Offline import/checkpoint owns every body; replication may be partial.
  func validateComplete() throws {
    try validate(); try workspace.validatePageOrderWitness()
    let pageIDs = Set(workspace.items.flatMap(\.pageIDs))
    let documentIDs = Set(workspace.items.filter { $0.kind == .document }.map(\.id))
    guard pageIDs == Set(pages.map(\.id)), documentIDs == Set(documents.map(\.id)),
      documentIDs == Set(states.map(\.id)) else {
      throw NotebookStorageError.invalidTransaction("complete archive dependencies")
    }
  }

  private func validateOwners() throws {
    guard workspace.isValid, hierarchy.isValid(items: workspace.items), ink.isValid,
      Set(pages.map(\.id)).count == pages.count,
      Set(documents.map(\.id)).count == documents.count,
      Set(states.map(\.id)).count == states.count,
      pages.allSatisfy(\.isValid), documents.allSatisfy(\.isValid), states.allSatisfy(\.isValid) else {
      throw CollaborationError("invalid_content", "Срез содержит проверенных владельцев с уникальными ID.")
    }
  }

  public mutating func merge(_ incoming: Self) throws {
    try validate()
    try incoming.validate()
    var result = self
    try result.mergeValidated(incoming)
    try result.validate()
    self = result
  }

  /// Prepares an additive cross-archive import. The shared factory root is the
  /// only shared physical identity; importing a second incarnation of any item
  /// or stroke requires an explicit conflict decision, never an LWW guess.
  public func importingIndependent(_ other: Self, actor: UUID) throws -> Self {
    try validateComplete(); try other.validateComplete()
    let ours = Set(workspace.items.map(\.id) + pages.map(\.id))
    let theirs = Set(other.workspace.items.map(\.id) + other.pages.map(\.id))
    guard workspace.rootBoardID == other.workspace.rootBoardID, ours.isDisjoint(with: theirs),
      Set(ink.actions.map(\.id)).isDisjoint(with: other.ink.actions.map(\.id)),
      let root = hierarchy.boards.first(where: { $0.id == workspace.rootBoardID }),
      let incomingRoot = other.hierarchy.board(workspace.rootBoardID),
      let next = max(hierarchy.stamp, other.hierarchy.stamp).advanced(by: actor) else {
      throw CollaborationError("import_collision", "Архивы должны содержать независимые физические UUID.")
    }
    let combinedRoot = BoardNode(id: root.id, board: try root.board.importingIndependent(incomingRoot, actor: actor),
      portalCamera: root.portalCamera, portalStamp: root.portalStamp)
    let result = try Self(workspace: workspace.merging(other.workspace),
      hierarchy: .init(rootBoardID: root.id,
        boards: [combinedRoot] + hierarchy.boards.filter { $0.id != root.id } + other.hierarchy.boards.filter { $0.id != root.id },
        stamp: next),
      ink: .init(actions: ink.actions + other.ink.actions, stamp: max(ink.stamp, other.ink.stamp)),
      pages: pages + other.pages, documents: documents + other.documents, states: states + other.states)
    try result.validate()
    return result
  }

  private mutating func mergeValidated(_ incoming: Self) throws {
    workspace = try workspace.merging(incoming.workspace)
    hierarchy = try hierarchy.merging(incoming.hierarchy, items: workspace.items)
    if ink != incoming.ink { _ = ink.merge(incoming.ink) }
    var pages = Dictionary(uniqueKeysWithValues: self.pages.map { ($0.id, $0) })
    for other in incoming.pages where pages[other.id] != other {
      pages[other.id] = try pages[other.id].map { try $0.merging(other) } ?? other
    }
    var documents = Dictionary(uniqueKeysWithValues: self.documents.map { ($0.id, $0) })
    for other in incoming.documents {
      if let current = documents[other.id], current.paperSize != other.paperSize {
        throw CollaborationError("invalid_content", "UUID документа сохраняет формат бумаги.")
      }
    }
    for other in incoming.documents where documents[other.id] != other { if documents[other.id] != nil { _ = documents[other.id]!.merge(other) } else { documents[other.id] = other } }
    var states = Dictionary(uniqueKeysWithValues: self.states.map { ($0.id, $0) })
    for other in incoming.states where states[other.id] != other { if states[other.id] != nil { _ = states[other.id]!.merge(other) } else { states[other.id] = other } }
    let pageIDs = Set(workspace.items.flatMap(\.pageIDs))
    let documentIDs = Set(workspace.items.filter { $0.kind == .document }.map(\.id))
    self.pages = pages.values.filter { pageIDs.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString }
    self.documents = documents.values.filter { documentIDs.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString }
    self.states = states.values.filter { documentIDs.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString }
  }

  /// A publication carries only changed heavy owners; the receiver retains the
  /// rest of its completed cut. Initial connection carries the complete set.
  public func publication(since previous: Self?) throws -> Self {
    try validate()
    guard let previous else { return self }
    try previous.validate()
    let oldPages = Dictionary(uniqueKeysWithValues:previous.pages.map { ($0.id,$0) })
    let oldDocuments = Dictionary(uniqueKeysWithValues:previous.documents.map { ($0.id,$0) })
    let oldStates = Dictionary(uniqueKeysWithValues:previous.states.map { ($0.id,$0) })
    return .init(workspace:workspace,hierarchy:hierarchy,
      ink:ink == previous.ink ? SpatialInkJournal(stamp:.init(counter:0,actor:ink.stamp.actor)) : ink,
      pages:pages.filter { oldPages[$0.id] != $0 },documents:documents.filter { oldDocuments[$0.id] != $0 },
      states:states.filter { oldStates[$0.id] != $0 })
  }

  public func sourceFiles(including paths: Set<String>? = nil) throws -> [String: JSONValue] {
    try validateOwners()
    var files: [String: JSONValue] = [:]
    func include(_ path: String, _ value: some Encodable) throws {
      try Task.checkCancellation()
      if paths == nil || paths!.contains(path) { files[path] = try .encode(value) }
    }
    try include("workspace.json", workspace)
    try include("board.json", hierarchy)
    try include("spatial-ink.json", ink)
    for page in pages { try include("pages/\(page.id.uuidString.lowercased()).json", page) }
    for document in documents { try include("documents/\(document.id.uuidString.lowercased()).json", document) }
    for state in states { try include("document-states/\(state.id.uuidString.lowercased()).json", state) }
    return files
  }

  /// These are the inputs of referenceRevision, not another content store.
  public func referenceFilePaths(for targets: [CollaborationTarget]) -> Set<String> {
    var paths = Set<String>()
    for target in targets {
      let suffix = target.id.uuidString.lowercased() + ".json"
      switch target.kind {
      case .workspace: paths.insert("workspace.json")
      case .page: paths.insert("pages/" + suffix)
      case .document:
        paths.formUnion(["documents/" + suffix, "document-states/" + suffix])
      case .cover, .board:
        paths.formUnion(["workspace.json", "board.json", "spatial-ink.json"])
        if target.kind == .cover, workspace.item(id: target.id)?.kind != .board {
          paths.insert("documents/" + suffix)
        } else {
          let descendants = hierarchy.descendantBoardIDs(including: target.id)
          let items = hierarchy.boards.filter { descendants.contains($0.id) }.flatMap { $0.board.itemIDs }
          paths.formUnion(items.filter { workspace.item(id: $0)?.kind == .document }
            .map { "documents/\($0.uuidString.lowercased()).json" })
        }
      }
    }
    return paths
  }
}

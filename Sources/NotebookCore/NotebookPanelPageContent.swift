import Foundation

/// One ephemeral content cut feeds both the panel projection and native painter.
/// Only the store can capture it; navigation, history and cursor remain fresh reads.
public struct NotebookPanelPageContent: Sendable {
  public let page: PageDocument
  public let elements: [JSONValue]
  let rawInkPresent: Bool
  private let workspaceID: UUID
  private let sourceRevision: String
  private let storeKey: String
  private let ink: PageInkSource

  fileprivate init(page: PageDocument, workspaceID: UUID, sourceRevision: String, storeKey: String) throws {
    self.page = page; self.workspaceID = workspaceID; self.sourceRevision = sourceRevision; self.storeKey = storeKey
    ink = page.inkSource
    (elements, rawInkPresent) = try Self.projection(page)
  }

  func validate(in store: NotebookStore, workspaceID: UUID, target: CollaborationTarget) throws {
    guard self.workspaceID == workspaceID, storeKey == store.connectionKey,
      target.kind == .page, target.boardID == nil, target.id == page.id,
      page.inkSource.identity == ink.identity,
      try store.referenceRevision(target: target) == sourceRevision else {
      throw NotebookStorageError.transactionConflict
    }
  }

  static func projection(_ page: PageDocument) throws -> (elements: [JSONValue], rawInkPresent: Bool) {
    let ink = try page.inkDrawing(), graph = page.graphicGraph()
    let erasures = Dictionary(ink.elementErasures.map { (collaborationIdentity($0.key), $0.value) }, uniquingKeysWith: +)
    let elements = try page.elements.map { element -> JSONValue in
      var value: [String: JSONValue] = ["source": try .encode(element)]
      let resolution = element.graphic == nil ? nil : graph.resolve(element.id)
      if let resolution { value["graphicResolution"] = try resolution.readProjection(includeGeometry: true) }
      let frame = resolution?.layout?.frame ?? element.frame
      value["appearance"] = NotebookElementAppearance.readProjection(graphic: element.graphic, layout: resolution?.layout,
        size: .init(width: frame.width, height: frame.height), erasures: erasures[collaborationIdentity(element.id)] ?? [])
      return .object(value)
    }
    return (elements, ink.baselinePNG?.isEmpty == false || ink.actions.contains { $0.isActive && $0.tool == .pen })
  }
}

extension NotebookStore {
  public func capturePanelPageContent(_ cut: NotebookPanelPresentationCut) throws -> NotebookPanelPageContent {
    try readTransaction { _ in
      guard cut.target.kind == .page, cut.target.boardID == nil,
        try storedWorkspaceID() == cut.projection.workspaceID,
        try referenceRevision(target: cut.target) == cut.sourceRevision else {
        throw NotebookStorageError.transactionConflict
      }
      return try .init(page: loadPage(cut.target.id), workspaceID: cut.projection.workspaceID,
        sourceRevision: cut.sourceRevision, storeKey: connectionKey)
    }
  }
}

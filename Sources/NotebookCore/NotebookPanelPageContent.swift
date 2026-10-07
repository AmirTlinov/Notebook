import CoreGraphics
import Foundation

/// One ephemeral content cut feeds both the panel projection and native painter.
/// Only the store can capture it; navigation, history and cursor remain fresh reads.
public struct NotebookPanelPageContent: Sendable {
  public let page: PageDocument
  private let workspaceID: UUID
  private let sourceRevision: String
  private let storeKey: String
  private let ink: PageInkSource

  fileprivate init(page: PageDocument, workspaceID: UUID, sourceRevision: String, storeKey: String) {
    self.page = page; self.workspaceID = workspaceID; self.sourceRevision = sourceRevision; self.storeKey = storeKey
    ink = page.inkSource
  }

  /// Disclosure follows the admitted material window; the captured source and
  /// its revision fence still cover the whole page. Bodies keep their full source.
  public func projection(in bounds: NotebookReadBounds? = nil) throws -> (elements: [JSONValue], rawInkPresent: Bool) {
    try Self.projection(page, bounds: bounds.map { try $0.validated() })
  }

  func validate(in store: NotebookStore, workspaceID: UUID, target: CollaborationTarget) throws {
    guard self.workspaceID == workspaceID, storeKey == store.connectionKey,
      target.kind == .page, target.boardID == nil, target.id == page.id,
      page.inkSource.identity == ink.identity,
      try store.referenceRevision(target: target) == sourceRevision else {
      throw NotebookStorageError.transactionConflict
    }
  }

  static func projection(_ page: PageDocument, bounds: WorkspaceSpatialBounds? = nil) throws -> (elements: [JSONValue], rawInkPresent: Bool) {
    let ink = try page.inkDrawing(), graph = page.graphicGraph()
    let erasures = Dictionary(ink.elementErasures.map { (collaborationIdentity($0.key), $0.value) }, uniquingKeysWith: +)
    let selected = bounds.map { Self.sources(in: $0, page: page, graph: graph) } ?? page.elements
    let elements = try selected.map { element -> JSONValue in
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

  private static func sources(in bounds: WorkspaceSpatialBounds, page: PageDocument,
    graph: NotebookGraphicGraph) -> [AgentElement] {
    // Intersect in the tiled domain before flattening into page coordinates.
    // A distant, valid anchor must not round itself into a finite page.
    guard let clipped = bounds.intersection(.init(origin: .zero, width: page.size.width, height: page.size.height)),
      clipped.width > 0, clipped.height > 0 else { return [] }
    let offset = WorldPoint.zero.delta(to: clipped.origin)
    let area = CGRect(x: offset.x, y: offset.y, width: clipped.width, height: clipped.height)
    let visible = graph.visiblePageGraphics(page.id, in: area)
    var ids = Set(visible.layouts.keys.map(collaborationIdentity))
    ids.formUnion(visible.placements.keys.map(collaborationIdentity))
    for element in page.elements where !ids.contains(collaborationIdentity(element.id)) {
      let placement = graph.placement(element.id)
      // Typography and transformed program bodies already belong to the
      // retained visibility owner. Groups and hidden/pending graphics also
      // retain their whole control frame, including an erased appearance.
      if element.kind != .group, element.graphic == nil, placement != nil { continue }
      if let graphic = element.graphic, graph.node(element.id)?.shown == true {
        // Active paint membership is already resolved, including masks and
        // connectors whose authored frame does not locate their curves.
        if graphic.connection == nil || graph.resolve(element.id).layout != nil { continue }
      }
      let frame = placement.map { NotebookElementPresentation(element, placement: $0).bounds }
        ?? CGRect(x: element.frame.x, y: element.frame.y, width: element.frame.width, height: element.frame.height)
      if area.intersects(frame) { ids.insert(collaborationIdentity(element.id)) }
    }
    // Escaped members can be visible while their group's authored basis is
    // outside the window. Keep those addressed ancestors, in painter order.
    for id in Array(ids) {
      ids.formUnion((graph.placement(id)?.ancestors ?? []).map(collaborationIdentity))
    }
    return page.elements.filter { ids.contains(collaborationIdentity($0.id)) }
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

import NotebookCore

extension NotebookAppModel {
  func manipulatedEndpointBinding() -> NotebookGraphicConnection.Binding? {
    guard let contact = selectionSession.manipulation, case .endpoint(let terminal) = contact.kind,
      let connection = contact.connection else { return nil }
    let graph: NotebookGraphicGraph, surface: SurfaceID, id: String
    switch contact.reference {
    case .page(let owner,let elementID):
      guard let page = pages[owner] else { return nil }
      graph = page.graphicGraph(); surface = .page(owner); id = elementID
    case .spatial(let owner,let elementID):
      guard let board = boardHierarchy?.board(owner), let node = board.elements.first(where:{$0.id == elementID}) else { return nil }
      graph = compositionTiles.published.map { presentedGraphicGraph(boardID:owner,cohort:$0,preview:false) } ?? board.graphicGraph()
      surface = node.surface; id = elementID
    }
    let p = terminal == .start ? connection.start.point : connection.end.point
    return graph.binding(at:.init(x:contact.original.minX+p.x,y:contact.original.minY+p.y),
      origin:contact.worldOrigin ?? .zero,surface:surface,excluding:id,tolerance:18/max(0.001,presence?.camera.scale ?? 1))
  }
  /// One geometry draft, first owned by a contact, then by its accepted command.
  /// A later material contact or a selection change cannot erase that command.
  var graphicPreviewManipulation: NotebookElementManipulation? {
    if let contact = selectionSession.manipulation, graphicElement(contact.reference) != nil { return contact }
    return graphicCommandPreview
  }

  /// Canonical owners remain unchanged. Dependencies derive the same preview
  /// through lift and durable publication, without per-sample SQL writes.
  func graphicPreviewFrames() -> [String: PageRect] {
    guard let contact = graphicPreviewManipulation, graphicElement(contact.reference) != nil else { return [:] }
    let id: String
    switch contact.reference { case .page(_, let value), .spatial(_, let value): id = value }
    let frame = contact.frame
    return [id: .init(x:frame.minX,y:frame.minY,width:frame.width,height:frame.height)]
  }

  func graphicGraph(page: PageDocument, preview: Bool = true) -> NotebookGraphicGraph {
    let usesPreview: Bool
    if case .page(let pageID, _) = graphicPreviewManipulation?.reference { usesPreview = preview && pageID == page.id }
    else { usesPreview = false }
    return page.graphicGraph(frames: usesPreview ? graphicPreviewFrames() : [:],
      connections: usesPreview ? graphicPreviewConnections() : [:])
  }

  func graphicLayout(_ reference: EditableElementReference, preview: Bool = true) -> NotebookGraphicLayout? {
    switch reference {
    case .page(let pageID, let id): return pages[pageID].map { graphicGraph(page:$0,preview:preview).resolve(id).layout } ?? nil
    case .spatial(let boardID, let id):
      guard let cohort = compositionTiles.published else {
        return boardHierarchy?.board(boardID)?.graphicGraph().resolve(id).layout
      }
      return presentedGraphicGraph(boardID:boardID,cohort:cohort,preview:preview).resolve(id).layout
    }
  }

  func graphicPreviewConnections() -> [String: NotebookGraphicConnection] {
    guard let contact = graphicPreviewManipulation, let connection = contact.connection else { return [:] }
    switch contact.reference { case .page(_,let id), .spatial(_,let id): return [id:connection] }
  }
}

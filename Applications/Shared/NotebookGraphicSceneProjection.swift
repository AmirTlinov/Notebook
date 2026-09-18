import NotebookCore

extension NotebookAppModel {
  var manipulatedBindingTarget: (reference: EditableElementReference, elementID: String)? {
    guard let contact = selectionSession.manipulation, case .endpoint(let terminal) = contact.kind,
      let connection = contact.connection,
      let binding = terminal == .start ? connection.start.binding : connection.end.binding else { return nil }
    switch contact.reference {
    case .page(let owner,_): return (.page(pageID:owner,elementID:binding.elementID),binding.elementID)
    case .spatial(let owner,_): return (.spatial(boardID:owner,elementID:binding.elementID),binding.elementID)
    }
  }

  func manipulatedEndpointBinding(retaining retainedID: String? = nil) -> NotebookGraphicConnection.Binding? {
    guard let contact = selectionSession.manipulation, case .endpoint(let terminal) = contact.kind,
      let connection = contact.connection else { return nil }
    let graph: NotebookGraphicGraph, surface: SurfaceID, id: String
    switch contact.reference {
    case .page(let owner,let elementID):
      guard let page = pages[owner] else { return nil }
      graph = graphicGraph(page: page); surface = .page(owner); id = elementID
    case .spatial(let owner,let elementID):
      guard let board = boardHierarchy?.board(owner), let node = board.elements.first(where:{$0.id == elementID}) else { return nil }
      graph = compositionTiles.published.map { presentedGraphicGraph(boardID:owner,cohort:$0) } ?? board.graphicGraph()
      surface = node.surface; id = elementID
    }
    let p = terminal == .start ? connection.start.point : connection.end.point
    return graph.binding(at:.init(x:contact.original.minX+p.x,y:contact.original.minY+p.y),
      origin:contact.worldOrigin ?? .zero,surface:surface,excluding:id,tolerance:14/max(0.001,presence?.camera.scale ?? 1),retaining:retainedID,erasures:elementErasures(on:surface,fallback:compositionTiles.published?.liveData.ink))
  }
  func graphicGraph(page: PageDocument, preview: Bool = true) -> NotebookGraphicGraph {
    let graph = page.graphicGraph()
    guard preview else { return graph }
    let working = workingGraphics.filter { $0.surface == .page(page.id) }
    let ids = Set(working.map(\.id))
    let combined = NotebookGraphicGraph(Array(graph.nodes.values).filter { !ids.contains($0.id) } + working.map(\.node))
    return projectingGraphicCommands(combined) { .page(pageID: page.id, elementID: $0) }
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

}

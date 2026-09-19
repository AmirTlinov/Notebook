import Foundation
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
      origin:contact.worldOrigin ?? .zero,surface:surface,excluding:id,tolerance:14/max(0.001,presence?.camera.scale ?? 1),retaining:retainedID,erasures:elementErasures(on:surface,fallback:compositionTiles.published?.liveData.ink), appearance: { elementID, graphic, size, cuts in
        elementErasureCache.appearance(surface:surface,id:elementID,graphic:graphic,layout:nil,size:size,erasures:cuts)
      })
  }
  func graphicGraph(page: PageDocument, preview: Bool = true) -> NotebookGraphicGraph {
    let graph = page.graphicGraph()
    guard preview else { return graph }
    let working = workingGraphics.filter { $0.surface == .page(page.id) }
    let ids = Set(working.map(\.id))
    let combined = NotebookGraphicGraph(Array(graph.nodes.values).filter { !ids.contains($0.id) } + working.map(\.node))
    return projectingGraphicCommands(combined) { .page(pageID: page.id, elementID: $0) }
  }

  /// New commands see the accepted model and its queued drafts, not the older
  /// raster cohort. Persistence still chains the exact predecessor sources.
  func authoredGraphicGraph(boardID: UUID) -> NotebookGraphicGraph {
    let graph = boardHierarchy?.board(boardID)?.graphicGraph() ?? .init([])
    let working = pendingModelGraphics.filter {
      $0.surface == .board(boardID) || ($0.surface.kind == .cover &&
        $0.surface.ownerID.flatMap { boardHierarchy?.ownerBoardID(of:$0) } == boardID)
    }
    let ids = Set(working.map(\.id))
    let combined = NotebookGraphicGraph(Array(graph.nodes.values).filter { !ids.contains($0.id) } + working.map(\.node))
    return projectingGraphicCommands(combined) { .spatial(boardID:boardID,elementID:$0) }
  }

  func graphicLayout(_ reference: EditableElementReference, preview: Bool = true) -> NotebookGraphicLayout? {
    graphicLayouts([reference],preview:preview)[reference]
  }

  /// A selected set resolves one graph per owner, not one whole graph for each
  /// outline on every movement sample. Projection still belongs to the scene.
  func graphicLayouts(_ references: [EditableElementReference], preview: Bool = true) -> [EditableElementReference:NotebookGraphicLayout] {
    var graphs: [SurfaceID:NotebookGraphicGraph] = [:]
    var result: [EditableElementReference:NotebookGraphicLayout] = [:]
    for reference in references {
      let owner: SurfaceID, id: String
      switch reference {
      case .page(let pageID,let elementID):
        owner = .page(pageID); id = elementID
        if graphs[owner] == nil, let page = pages[pageID] { graphs[owner] = graphicGraph(page:page,preview:preview) }
      case .spatial(let boardID,let elementID):
        owner = .board(boardID); id = elementID
        if graphs[owner] == nil {
          graphs[owner] = compositionTiles.published.map { presentedGraphicGraph(boardID:boardID,cohort:$0,preview:preview) }
            ?? boardHierarchy?.board(boardID)?.graphicGraph()
        }
      }
      result[reference] = graphs[owner]?.resolve(id).layout
    }
    return result
  }

}

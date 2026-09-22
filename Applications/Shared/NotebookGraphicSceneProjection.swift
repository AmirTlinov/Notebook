import Foundation
import NotebookCore

struct NotebookPageGraphicDisplay {
  let graph:NotebookGraphicGraph
  let elements:[AgentElement]
  let layouts:[String:NotebookGraphicLayout]
  let visitedIndexNodes:Int
  let resolvedGraphics:Int
}

extension NotebookAppModel {
  func pageGraphicDisplay(_ page:PageDocument,in visibleRegion:CGRect?) -> NotebookPageGraphicDisplay {
    _ = workingGraphicRevision(on:.page(page.id))
    let graph=graphicGraph(page:page)
    let paper=CGRect(x:0,y:0,width:page.size.width,height:page.size.height)
    let query=graph.visiblePageGraphics(page.id,in:visibleRegion.map { $0.intersection(paper) } ?? paper)
    var layouts=query.layouts,pinned=Set<String>()
    if case .page(let owner,let id)=interactiveElementFocus,owner == page.id { pinned.insert(id) }
    if case .page(let owner,let id)=selectionSession.manipulation?.reference,owner == page.id { pinned.insert(id) }
    var resolved=query.resolvedGraphics
    for id in pinned where layouts[id] == nil {
      resolved += 1;layouts[id]=graph.resolve(id).layout
    }
    let working=workingGraphics.filter { $0.surface == .page(page.id) }
    let workingIDs=Set(working.map(\.id))
    let admitted=page.displayElements(graphicIDs:Set(layouts.keys)).filter { element in
      guard !workingIDs.contains(element.id) else { return false }
      if element.graphic != nil { return true }
      guard let placement=graph.placement(element.id) else { return false }
      return NotebookElementPresentation(element,placement:placement).bounds.intersects(paper)
    }
    return .init(graph:graph,elements:admitted+working.filter { layouts[$0.id] != nil }.map(\.pageElement),
      layouts:layouts,visitedIndexNodes:query.visitedIndexNodes,resolvedGraphics:resolved)
  }

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
      guard let board = boardHierarchy?.board(owner), let node = board.element(id:elementID) else { return nil }
      graph = compositionTiles.published.map { presentedGraphicGraph(boardID:owner,cohort:$0) } ?? board.graphicGraph()
      surface = node.surface; id = elementID
    }
    let p = terminal == .start ? connection.start.point : connection.end.point
    let shown=CGPoint(x:p.x,y:p.y).applying(contact.placement?.transform ?? .init(translationX:contact.original.minX,y:contact.original.minY))
    return graph.binding(at:.init(x:shown.x,y:shown.y),
      origin:contact.worldOrigin ?? .zero,surface:surface,excluding:id,tolerance:14/max(0.001,presence?.camera.scale ?? 1),retaining:retainedID,erasures:elementErasures(on:surface,fallback:compositionTiles.published?.liveData.ink), appearance: { elementID, graphic, layout, size, cuts in
        elementErasureCache.appearance(surface:surface,id:elementID,graphic:graphic,layout:layout,size:size,erasures:cuts)
      })
  }
  func graphicGraph(page: PageDocument, preview: Bool = true) -> NotebookGraphicGraph {
    let graph = (preview ? retainedGraphicGraph { .page(pageID:page.id,elementID:$0) } : nil) ?? page.graphicGraph()
    guard preview else { return graph }
    _ = workingGraphicRevision(on:.page(page.id))
    let working = workingGraphics.filter { $0.surface == .page(page.id) }
    let combined = graph.projecting(adding:working.map(\.node))
    return projectingGraphicCommands(combined) { .page(pageID: page.id, elementID: $0) }
  }

  /// New commands see the accepted model and its queued drafts, not the older
  /// raster cohort. Persistence still chains the exact predecessor sources.
  func authoredGraphicGraph(boardID: UUID) -> NotebookGraphicGraph {
    let graph = retainedGraphicGraph { .spatial(boardID:boardID,elementID:$0) } ?? boardHierarchy?.board(boardID)?.graphicGraph() ?? .init([])
    let working = pendingModelGraphics.filter {
      $0.surface == .board(boardID) || ($0.surface.kind == .cover &&
        $0.surface.ownerID.flatMap { boardHierarchy?.ownerBoardID(of:$0) } == boardID)
    }
    let combined = graph.projecting(adding:working.map(\.node))
    return projectingGraphicCommands(combined) { .spatial(boardID:boardID,elementID:$0) }
  }

  func editingGraphicGraph(_ reference:EditableElementReference) -> NotebookGraphicGraph? {
    switch reference {
    case .page(let owner,_): return pages[owner].map { graphicGraph(page:$0) }
    case .spatial(let owner,_): return compositionTiles.published.map { presentedGraphicGraph(boardID:owner,cohort:$0) }
      ?? boardHierarchy?.board(owner)?.graphicGraph()
    }
  }

  func graphicManipulationGeometry(_ reference: EditableElementReference,in prepared:NotebookGraphicGraph? = nil) -> (placement:NotebookElementPlacement,body:NotebookGraphicLayout,display:NotebookGraphicLayout)? {
    guard let graph=prepared ?? editingGraphicGraph(reference) else { return nil }
    let id=reference.elementID
    guard let node=graph.node(id),let body=graph.resolve(id,space:.body).layout,let display=graph.resolve(id).layout else { return nil }
    return (node.placement,body,display)
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

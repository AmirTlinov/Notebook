import Foundation
import NotebookCore

struct NotebookElementErasing {
  let id: UUID
  let surface: SurfaceID
  let samples: [SpatialInkSample]
  let targets: [InkElementTarget]
  var accepted = false

  var masks: [String: [InkElementErasure]] {
    Dictionary(uniqueKeysWithValues: targets.map {
      ($0.elementID, [InkElementErasure(target: $0, samples: samples)])
    })
  }
}

@MainActor final class NotebookElementErasureCache {
  private var pages: [UUID: (Data, [String: [InkElementErasure]])] = [:]
  private var spatial: [SurfaceID: [String: [InkElementErasure]]] = [:]
  func record(_ change: PreparedPageInkChange) {
    if pages.count >= 8 { pages.removeAll() }
    pages[change.pageID] = (change.data, change.drawing.elementErasures)
  }
  func page(_ page: PageDocument) -> [String: [InkElementErasure]] {
    if let cached = pages[page.id], cached.0 == page.drawingData { return cached.1 }
    let masks = (try? PageInkDrawing.decode(page.drawingData).elementErasures) ?? [:]
    if pages.count >= 8 { pages.removeAll() }
    pages[page.id] = (page.drawingData, masks)
    return masks
  }
  func invalidateSpatial() { spatial.removeAll() }
  func masks(on surface: SurfaceID, journal: SpatialInkJournal?) -> [String: [InkElementErasure]] {
    if let cached = spatial[surface] { return cached }
    let masks = journal?.elementErasures(on: surface) ?? [:]
    spatial[surface] = masks
    return masks
  }
}

extension NotebookAppModel {
  func eraserTargets(pageID: UUID) -> [InkElementTarget] {
    guard let page = pages[pageID] else { return [] }
    let graph = graphicGraph(page: page)
    return pageElementsForDisplay(page).compactMap { element in
      let frame: PageRect
      if element.graphic != nil {
        guard let layout = graph.resolve(element.id).layout else { return nil }; frame = layout.frame
      } else { frame = element.frame }
      return .init(elementID: element.id, frame: frame)
    }
  }

  func eraserTargets(boardID: UUID, cohort: SceneCompositionCohort) -> [SurfaceID: [InkElementTarget]] {
    let graph = presentedGraphicGraph(boardID: boardID, cohort: cohort)
    let board = cohort.frame.index.capturedHierarchy.board(boardID).map { presentedBoard($0, boardID: boardID, cohort: cohort) }
    var result: [SurfaceID: [InkElementTarget]] = [:]
    for element in board?.elements ?? [] where element.graphic == nil {
      result[element.surface, default: []].append(.init(elementID: element.id,
        frame: .init(x: element.frame.x, y: element.frame.y, width: element.frame.width, height: element.frame.height),
        worldOrigin: element.worldOrigin))
    }
    for node in graph.nodes.values {
      guard let layout = graph.resolve(node.id).layout else { continue }
      result[node.surface, default: []].append(.init(elementID: node.id, frame: layout.frame,
        worldOrigin: node.surface.kind == .board ? node.origin : nil))
    }
    return result
  }

  func updateElementErasing(_ contact: [NotebookElementErasing], id: UUID) {
    // Once lift transfers this contact to the model, an old paper's refresh
    // or teardown cannot retract it while preparation is still pending.
    guard workingElementErasures[id]?.contains(where: \.accepted) != true else { return }
    let visible = contact.filter { !$0.targets.isEmpty }
    if visible.isEmpty {
      // An inactive canvas may cancel during every SwiftUI update. A no-op
      // must not publish another update and strand the opened paper in a loop.
      if workingElementErasures[id] != nil { workingElementErasures[id] = nil }
    } else { workingElementErasures[id] = visible }
  }

  func elementErasures(on surface: SurfaceID, fallback: SpatialInkJournal? = nil) -> [String: [InkElementErasure]] {
    var result: [String: [InkElementErasure]]
    if surface.kind == .page, let id = surface.ownerID, let page = pages[id] {
      result = elementErasureCache.page(page)
    } else if loadedInkSurfaces.contains(surface) || fallback == nil {
      result = elementErasureCache.masks(on: surface, journal: spatialInk)
    } else { result = fallback?.elementErasures(on: surface) ?? [:] }
    for contacts in workingElementErasures.values {
      for contact in contacts where contact.surface == surface {
        result.merge(contact.masks) { $0 + $1 }
      }
    }
    return result
  }
}

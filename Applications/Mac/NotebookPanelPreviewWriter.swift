import AppKit
import Foundation
import NotebookCore

/// An addressed recipe executed exclusively by MacPreviewPublisher's existing
/// target queue. Output contains derived pixels, never a retained business model.
extension CurrentViewPreviewWriter {
  @MainActor
  static func writePanel(_ request: TargetRenderRequest, model: NotebookAppModel) async throws {
    guard let projection = request.panelProjection, model.permitsBackgroundPreparation else {
      throw CancellationError()
    }
    try projection.validated()
    let target = request.target, actor = model.actorID
    let captured = try await model.performStoreCommand { store in
      try store.readTransaction { _ in
        let header = try store.workspaceHeader()
        guard header.workspaceID == projection.workspaceID,
          try store.referenceRevision(target: target) == request.sourceRevision else {
          throw NotebookStorageError.transactionConflict
        }
        let snapshot = try store.readPanel(.init(workspaceID: projection.workspaceID,
          target: target, bounds: target.kind == .board ? projection.readBounds : nil), actor: actor)
        let page = target.kind == .page ? try store.loadPage(target.id) : nil
        return (header, snapshot, page)
      }
    }
    let (header, snapshot, page) = captured
    let source = SceneCompositionSource(store: model.store, revision: header.cursor,
      workspaceID: projection.workspaceID, recordPixelDependencies: true, documentGeometry: model.documentPaperSizes)
    let candidates = snapshot["elements"]?.arrayValues.filter(NotebookPanelEditableSubject.allows) ?? []
    let ids = try await panelSubjects(candidates, page: page, source: source, projection: projection, target: target)
    let layers: [NotebookPanelRasterLayer]
    if let page {
      layers = try await pagePanelLayers(page, projection: projection, editableIDs: ids, model: model)
    } else {
      let presence = SessionPresence(boardID: target.id, mode: .board, camera: projection.camera, viewport: projection.viewport)
      let renderer = SceneCompositionRenderer(source: source, permitsPreparation: { model.permitsBackgroundPreparation })
      layers = try await renderer.renderPanel(presence: presence, projection: projection, editableIDs: ids)
    }
    var cardGeometry: [JSONValue] = []
    if target.kind == .board {
      let presence = SessionPresence(boardID: target.id, mode: .board, camera: projection.camera, viewport: projection.viewport)
      for card in snapshot["cards"]?.arrayValues ?? [] {
        guard let id = card["item"]?["id"]?.stringValue.flatMap(UUID.init(uuidString:)),
          let item = try await source.item(id, presence: presence) else { continue }
        let delta = projection.worldOrigin.delta(to: item.center)
        cardGeometry.append(.object(["id": try .encode(id), "geometry": try .encode(item.geometry),
          "center": try .encode(item.center), "worldOrigin": try .encode(projection.worldOrigin),
          "frame": try .encode(PageRect(x: delta.x - item.geometry.width / 2, y: delta.y - item.geometry.height / 2,
            width: item.geometry.width, height: item.geometry.height))]))
      }
    }
    let appearance = JSONValue.object(["status": .string("ready"), "requestID": try .encode(request.id),
      "sourceRevision": .string(request.sourceRevision), "cursor": .string(String(header.cursor)),
      "camera": try .encode(projection.camera), "viewport": try .encode(projection.viewport),
      "layers": .array(try layers.map { try $0.encoded }), "cardGeometry": .array(cardGeometry), "diagnostics": .array([])])
    guard try JSONEncoder().encode(appearance).count <= NotebookPanelRenderProjection.maximumEncodedBytes else {
      throw SceneRenderError.resourceLimit
    }
    let dependencies = try await source.pixelDependencies()
    try Task.checkCancellation()
    guard model.permitsBackgroundPreparation else { throw CancellationError() }
    try await model.performStoreCommand { store in
      try Task.checkCancellation()
      let latest = try store.workspaceHeader()
      guard latest.workspaceID == projection.workspaceID,
        try store.referenceRevision(target: target) == request.sourceRevision,
        try dependencies?.isCurrent(store) != false else { throw NotebookStorageError.transactionConflict }
      try store.saveTargetRender(.init(request: request, status: "ready", camera: projection.camera,
        panelPresentation: appearance))
    }
  }

  /// Static painter ranges grow around granted subjects. Budget that native
  /// partition before painting; remaining bodies stay visible and read-only.
  @MainActor
  private static func panelSubjects(_ entries: [JSONValue], page: PageDocument?, source: SceneCompositionSource,
    projection: NotebookPanelRenderProjection, target: CollaborationTarget) async throws -> Set<String> {
    let density = projection.camera.scale * projection.pixelScale
    let viewportPixels = Int(ceil(projection.viewport.x * projection.pixelScale)) * Int(ceil(projection.viewport.y * projection.pixelScale))
    var available = NotebookPanelRenderProjection.maximumDecodedPixels - viewportPixels * (page == nil ? 4 : 3)
    var ids = Set<String>()
    let graph = page?.graphicGraph()
    for entry in entries {
      guard ids.count < NotebookPanelRenderProjection.maximumSubjects, let id = entry["source"]?["id"]?.stringValue else { continue }
      let frame: PageRect?
      if let page, let element = page.elements.first(where: { $0.id == id }), let graph {
        frame = graph.resolve(id).layout?.frame ?? graph.placement(id).map { NotebookElementPresentation(element, placement: $0).frame }
      } else if let read = try await source.readElementForPaint(id, boardID: target.id) {
        frame = read.layout?.frame ?? read.placement.map { NotebookElementPresentation(read.element, placement: $0).frame }
      } else { frame = nil }
      guard let frame, frame.width > 0, frame.height > 0,
        frame.width * density <= 2048, frame.height * density <= 2048 else { continue }
      let pixels = Int(ceil(frame.width * density)) * Int(ceil(frame.height * density))
      let cost = viewportPixels + pixels
      guard cost <= available else { continue }
      available -= cost; ids.insert(id)
    }
    return ids
  }

  @MainActor
  private static func pagePanelLayers(_ page: PageDocument, projection: NotebookPanelRenderProjection,
    editableIDs: Set<String>, model: NotebookAppModel) async throws -> [NotebookPanelRasterLayer] {
    let resources = SceneRenderResources.shared
    let graph = page.graphicGraph()
    let physical = CGRect(x: 0, y: 0, width: page.size.width, height: page.size.height)
    let origin = WorldPoint.zero.delta(to: projection.worldOrigin)
    let visible = physical.intersection(CGRect(x: origin.x, y: origin.y,
      width: projection.viewport.x / projection.camera.scale, height: projection.viewport.y / projection.camera.scale))
    guard !visible.isNull, !visible.isEmpty else { return [] }
    let region = PageRect(x: visible.minX, y: visible.minY, width: visible.width, height: visible.height)
    let density = projection.camera.scale * projection.pixelScale
    var borrowed: RasterLease?, preparation: SceneWebRasterPreparation?
    defer { borrowed?.release(); preparation?.close() }
    func raster(_ element: AgentElement) async throws -> RasterLease {
      borrowed?.release(); borrowed = nil
      let scale = density * (graph.placement(element.id).map { NotebookElementPresentation.maximumScale($0.transform) } ?? 1)
      if let cached = resources.retainRaster(for: element, minimumScale: scale) { borrowed = cached; return cached }
      if preparation == nil { preparation = try await SceneWebRasterPreparation.create(resources: resources,
        permitsPreparation: { model.permitsBackgroundPreparation }) }
      guard let preparation else { throw SceneRenderError.snapshotPending("panel_page_source") }
      let image = try await preparation.prepare(element, requestedScale: scale, programStore: model.store,
        permitsPreparation: { model.permitsBackgroundPreparation })
      borrowed = image; return image
    }
    var output = NotebookPanelRasterSet()
    let paper = try await SceneRasterCompositor.create(size: visible.size, scale: density, resources: resources,
      permitsPreparation: { model.permitsBackgroundPreparation })
    try await paper.drawPaper(size: physical.size, in: physical.offsetBy(dx: -visible.minX, dy: -visible.minY))
    try output.append(.init(id: "page-paper", order: -1, worldOrigin: .zero, frame: region, png: await paper.finishPNG()))
    let elements = PageCompositionRenderer.elements(in: page, region: region, elementID: nil)
    var pending = Set<String>(), rank = 0
    func staticLayer(_ ids: Set<String>, rank: Int) async throws -> NotebookPanelRasterLayer {
      let result = try await PageCompositionRenderer.renderAuthoredLayer(page, ids: ids, region: region,
        scale: density, resources: resources, permitsPreparation: { model.permitsBackgroundPreparation }, raster: raster)
      return try .init(id: "page-elements-\(rank)", order: rank, worldOrigin: .zero, frame: region, png: result.png)
    }
    for element in elements {
      let layout = graph.resolve(element.id).layout
      let presentation = graph.placement(element.id).map { NotebookElementPresentation(element, placement: $0) }
      let frame = layout?.frame ?? presentation?.frame
      guard editableIDs.contains(element.id), let frame, element.graphic?.sourceInkContactID == nil,
        frame.width * density <= 2048, frame.height * density <= 2048,
        frame.x >= 0, frame.y >= 0, frame.x + frame.width <= page.size.width,
        frame.y + frame.height <= page.size.height else { pending.insert(element.id); continue }
      if !pending.isEmpty { try output.append(await staticLayer(pending, rank: rank)); pending.removeAll(); rank += 1 }
      let result = try await PageCompositionRenderer.renderAuthoredLayer(page, ids: [element.id], region: frame,
        scale: density, resources: resources, permitsPreparation: { model.permitsBackgroundPreparation }, raster: raster)
      try output.append(.init(id: "subject-\(element.id)", order: rank, worldOrigin: .zero,
        frame: frame, png: result.png, elementID: element.id)); rank += 1
    }
    if !pending.isEmpty { try output.append(await staticLayer(pending, rank: rank)) }
    let ink = try await PageCompositionRenderer.renderInk(page, region: region, scale: density,
      resources: resources, permitsPreparation: { model.permitsBackgroundPreparation })
    try output.append(.init(id: "page-ink", order: 1000, worldOrigin: .zero, frame: region, png: ink.png))
    return output.layers
  }
}

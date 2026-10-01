import AppKit
import Foundation
import NotebookCore

/// Ephemeral app presentation executes in the publisher's existing target queue.
/// Native world material is borrowed from its shared pool; no camera receipt is written.
extension CurrentViewPreviewWriter {
  @MainActor
  static func panelMaterial(_ cut: NotebookPanelPresentationCut, model: NotebookAppModel,
    knownAssets: Set<UUID>) async throws -> JSONValue {
    let projection = cut.projection, target = cut.target, actor = model.actorID
    try projection.validated()
    guard model.permitsBackgroundPreparation else { throw CancellationError() }
    let viewBounds = WorkspaceSpatialBounds(origin: projection.worldOrigin,
      width: projection.viewport.x / projection.camera.scale, height: projection.viewport.y / projection.camera.scale)
    let initialCoverage = try CompositionTileCoverage(bounds: viewBounds,
      pixelsPerWorldPoint: projection.camera.scale * projection.pixelScale)
    let initialBounds = WorkspaceSpatialBounds(origin: initialCoverage.tiles.first!.origin,
      maximum: initialCoverage.tiles.last!.bounds.maximum)
    let captured = try await model.performStoreCommand { store in
      try store.readTransaction { _ in
        let header = try store.workspaceHeader()
        guard header.workspaceID == projection.workspaceID,
          try store.referenceRevision(target: target) == cut.sourceRevision else { throw NotebookStorageError.transactionConflict }
        let snapshot = try store.readPanel(.init(workspaceID: projection.workspaceID, target: target,
          bounds: target.kind == .board ? .init(anchor: initialBounds.origin,
            region: .init(x: 0, y: 0, width: initialBounds.width, height: initialBounds.height)) : nil), actor: actor)
        return (header, snapshot, target.kind == .page ? try store.loadPage(target.id) : nil)
      }
    }
    let (header, capturedSnapshot, page) = captured
    let source = SceneCompositionSource(store: model.store, revision: header.cursor,
      workspaceID: projection.workspaceID, recordPixelDependencies: true, documentGeometry: model.documentPaperSizes)
    let candidates = Array((capturedSnapshot["elements"]?.arrayValues ?? []).filter(NotebookPanelEditableSubject.allows)
      .prefix(NotebookPanelRenderProjection.maximumSubjects))
    let ids = Set(candidates.compactMap { $0["source"]?["id"]?.stringValue })
    let layers: [NotebookPanelRasterLayer], coverage: CompositionTileCoverage
    if let page {
      (layers, coverage) = try await pagePanelMaterials(page, projection: projection, editableIDs: ids,
        knownAssets: knownAssets, sourceRevision: cut.sourceRevision, model: model)
    } else {
      let presence = SessionPresence(boardID: target.id, mode: .board, camera: projection.camera, viewport: projection.viewport)
      let renderer = SceneCompositionRenderer(source: source, permitsPreparation: { model.permitsBackgroundPreparation })
      let movable = Set((capturedSnapshot["cards"]?.arrayValues ?? []).prefix(NotebookPanelRenderProjection.maximumSubjects)
        .compactMap { $0["item"]?["id"]?.stringValue.flatMap(UUID.init(uuidString:)) })
      let result = try await renderer.renderPanel(presence: presence, projection: projection,
        editableIDs: ids, movableItemIDs: movable, knownAssets: knownAssets)
      layers = result.layers; coverage = result.coverage
    }
    let materialBounds = WorkspaceSpatialBounds(origin: coverage.tiles.first!.origin,
      maximum: coverage.tiles.last!.bounds.maximum)
    let dependencies = try await source.pixelDependencies()
    try Task.checkCancellation()
    guard model.permitsBackgroundPreparation else { throw CancellationError() }
    return try await model.performStoreCommand { store in
      try store.readTransaction { _ in
        try Task.checkCancellation()
        guard try store.storedWorkspaceID() == projection.workspaceID,
          try store.referenceRevision(target: target) == cut.sourceRevision,
          try dependencies?.isCurrent(store) != false else { throw NotebookStorageError.transactionConflict }
        var snapshot = try store.readPanel(.init(workspaceID: projection.workspaceID, target: target,
          bounds: target.kind == .board ? .init(anchor: materialBounds.origin,
            region: .init(x: 0, y: 0, width: materialBounds.width, height: materialBounds.height)) : nil,
          includeFitBounds: cut.includeFitBounds), actor: actor)
        let editable = Set(layers.compactMap(\.elementID)), movable = Set(layers.compactMap(\.itemID))
        snapshot = snapshot.setting("elements", .array((snapshot["elements"]?.arrayValues ?? []).map { entry in
          entry.setting("editable", .bool(entry["source"]?["id"]?.stringValue.map(editable.contains) == true))
        }))
        snapshot = snapshot.setting("cards", .array((snapshot["cards"]?.arrayValues ?? []).map { card in
          guard let id = card["item"]?["id"]?.stringValue.flatMap(UUID.init(uuidString:)) else { return card }
          let layer = layers.first { $0.itemID == id }
          var value = card.setting("editable", .bool(movable.contains(id)))
          if let layer, let frame = layer.subjectFrame {
            value = value.setting("frame", try? .encode(frame)).setting("worldOrigin", try? .encode(layer.worldOrigin))
              .setting("center", try? .encode(layer.worldOrigin))
            value = value.setting("geometry", .object(["width": .number(frame.width), "height": .number(frame.height)]))
          }
          return value
        }))
        if target.kind == .page { snapshot = snapshot.setting("worldOrigin", try .encode(WorldPoint.zero)) }
        let appearance = JSONValue.object(["status": .string("ready"), "requestID": try .encode(cut.id),
          "sourceRevision": .string(cut.sourceRevision), "cursor": snapshot["cursor"] ?? .string(String(header.cursor)),
          "camera": try .encode(projection.camera), "viewport": try .encode(projection.viewport),
          "coverage": .object(["anchor": try .encode(materialBounds.origin),
            "region": try .encode(PageRect(x: 0, y: 0, width: materialBounds.width, height: materialBounds.height)),
            "level": .number(Double(coverage.level)),
            "pixelDensity": .number(Double(CompositionTile.pixelSize) / coverage.tiles[0].worldSize)]),
          "layers": .array(try layers.map { try $0.encoded }), "diagnostics": .array([])])
        snapshot = snapshot.setting("appearance", appearance)
        guard try JSONEncoder().encode(snapshot).count <= NotebookPanelRenderProjection.maximumEncodedBytes else {
          throw SceneRenderError.resourceLimit
        }
        return snapshot
      }
    }
  }

  /// Finite pages use the same world grid and native paper/ordered ink owners.
  /// Their body pixels are stable across a pan just like board materials.
  @MainActor
  private static func pagePanelMaterials(_ page: PageDocument, projection: NotebookPanelRenderProjection,
    editableIDs: Set<String>, knownAssets: Set<UUID>, sourceRevision: String, model: NotebookAppModel)
    async throws -> ([NotebookPanelRasterLayer], CompositionTileCoverage) {
    let resources = SceneRenderResources.shared, graph = page.graphicGraph()
    let requested = WorkspaceSpatialBounds(origin: projection.worldOrigin,
      width: projection.viewport.x / projection.camera.scale, height: projection.viewport.y / projection.camera.scale)
    var coverage = try CompositionTileCoverage(bounds: requested,
      pixelsPerWorldPoint: projection.camera.scale * projection.pixelScale, maximumTiles: 8)
    let target = CollaborationTarget(kind: .page, id: page.id)
    let density = Double(CompositionTile.pixelSize) / coverage.tiles[0].worldSize
    let physical = CGRect(x: 0, y: 0, width: page.size.width, height: page.size.height)
    var borrowed: RasterLease?, preparation: SceneWebRasterPreparation?
    var sourceRasters: [SceneSourceAddress: RasterLease] = [:], receipts: [SceneSourceAddress: SceneSourceReceipt] = [:]
    defer { borrowed?.release(); preparation?.close(); sourceRasters.values.forEach { $0.release() } }
    func raster(_ element: AgentElement) async throws -> RasterLease {
      borrowed?.release(); borrowed = nil
      let scale = density * (graph.placement(element.id).map { NotebookElementPresentation.maximumScale($0.transform) } ?? 1)
      let value: RasterLease
      if let cached = resources.retainRaster(for: element, minimumScale: scale) { value = cached }
      else {
        if preparation == nil { preparation = try await SceneWebRasterPreparation.create(resources: resources,
          permitsPreparation: { model.permitsBackgroundPreparation }) }
        value = try await preparation!.prepare(element, requestedScale: scale, programStore: model.store,
          permitsPreparation: { model.permitsBackgroundPreparation })
      }
      borrowed = value
      let address = SceneSourceAddress(plane: .board(page.id), elementID: element.id)
      let demand = SceneSourceDemand(source: element, minimumScale: scale)
      receipts[address] = .init(demand: demand, installedSource: value.source.agentElement, installedScale: value.pixelScale,
        status: .ready, installedRegion: value.source.captureRegion)
      sourceRasters[address]?.release(); sourceRasters[address] = value.retainedCopy()
      return value
    }
    var output = NotebookPanelRasterSet(), subjects: [String: PageRect] = [:]
    var available = NotebookPanelRenderProjection.maximumDecodedPixels - SceneCompositionPlan.maximumTiles * CompositionTile.pixelSize * CompositionTile.pixelSize
    for element in page.elements where editableIDs.contains(element.id) && element.graphic?.sourceInkContactID == nil {
      let frame = graph.resolve(element.id).layout?.frame
        ?? graph.placement(element.id).map { NotebookElementPresentation(element, placement: $0).frame }
      guard let frame, frame.width > 0, frame.height > 0,
        frame.width * density <= 2048, frame.height * density <= 2048,
        physical.contains(CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)) else { continue }
      let pixels = Int(ceil(frame.width * density)) * Int(ceil(frame.height * density))
      guard pixels <= available else { continue }; available -= pixels
      subjects[element.id] = frame
    }
    let elements = PageCompositionRenderer.elements(in: page,
      region: .init(x: 0, y: 0, width: page.size.width, height: page.size.height), elementID: nil)
    func painterRuns() -> (bands: [(ids: Set<String>, rank: Int)], subjects: [String: Int]) {
      var bands: [(Set<String>, Int)] = [], pending = Set<String>(), ranks: [String: Int] = [:], rank = 0
      for element in elements {
        if subjects[element.id] != nil {
          if !pending.isEmpty { bands.append((pending, rank)); pending.removeAll(); rank += 1 }
          ranks[element.id] = rank; rank += 1
        } else { pending.insert(element.id) }
      }
      if !pending.isEmpty { bands.append((pending, rank)) }
      return (bands, ranks)
    }
    var runs = painterRuns()
    while coverage.tiles.count * (runs.bands.count + 2) > SceneCompositionPlan.maximumTiles {
      let coarser = try CompositionTileCoverage(bounds: requested,
        pixelsPerWorldPoint: Double(CompositionTile.pixelSize) / (coverage.tiles[0].worldSize * 2), maximumTiles: 8)
      if coarser.level > coverage.level { coverage = coarser }
      else if let optional = elements.last(where: { subjects[$0.id] != nil }) {
        subjects.removeValue(forKey: optional.id); runs = painterRuns()
      } else { throw SceneRenderError.resourceLimit }
    }
    let bands = runs.bands
    for element in elements {
      guard let frame = subjects[element.id], let rank = runs.subjects[element.id] else { continue }
      let key = try SceneMaterialKey(workspaceID: projection.workspaceID, target: target, revision: sourceRevision,
        role: "element:" + element.id, frame: frame, density: density)
      let body: RasterLease
      if let cached = resources.retainMaterial(key) { body = cached }
      else {
        body = try await PageCompositionRenderer.renderMaterial(page, ids: [element.id], region: frame,
          scale: density, key: key, resources: resources,
          permitsPreparation: { model.permitsBackgroundPreparation }, raster: raster)
        resources.cacheComposition(body, receipts: receipts, sources: sourceRasters)
      }
      defer { body.release() }
      try output.append(await .completed(id: "subject-" + element.id, order: rank, worldOrigin: .zero,
        frame: frame, raster: body, knownAssets: knownAssets, elementID: element.id, subjectFrame: frame))
    }
    let tileDensity = Double(CompositionTile.pixelSize) / coverage.tiles[0].worldSize
    for tile in coverage.tiles {
      let delta = WorldPoint.zero.delta(to: tile.origin)
      let visible = physical.intersection(.init(x: delta.x, y: delta.y, width: tile.worldSize, height: tile.worldSize))
      guard !visible.isEmpty, !visible.isNull else { continue }
      let region = PageRect(x: visible.minX, y: visible.minY, width: visible.width, height: visible.height)
      for index in -1...bands.count {
        let role = index == -1 ? "page-paper" : index == bands.count ? "page-ink" : "page-elements:" + bands[index].ids.sorted().joined(separator: ",")
        let order = index == -1 ? -1 : index == bands.count ? 1000 : bands[index].rank
        let key = try SceneMaterialKey(workspaceID: projection.workspaceID, target: target, revision: sourceRevision,
          role: role, frame: region, density: tileDensity)
        let body: RasterLease
        if let cached = resources.retainMaterial(key) { body = cached }
        else if index == -1 {
          let canvas = try await SceneRasterCompositor.create(size: visible.size, scale: tileDensity, resources: resources,
            permitsPreparation: { model.permitsBackgroundPreparation })
          try await canvas.drawPaper(size: physical.size, in: physical.offsetBy(dx: -visible.minX, dy: -visible.minY))
          body = try await canvas.finishRaster(for: .material(key))
          resources.cacheComposition(body, receipts: [:], sources: [:])
        } else {
          body = try await PageCompositionRenderer.renderMaterial(page,
            ids: index == bands.count ? nil : bands[index].ids, region: region, scale: tileDensity,
            key: key, resources: resources, permitsPreparation: { model.permitsBackgroundPreparation }, raster: raster)
          resources.cacheComposition(body, receipts: receipts, sources: sourceRasters)
        }
        defer { body.release() }
        try output.append(await .completed(id: role + ":\(tile.column):\(tile.row):\(tile.localColumn):\(tile.localRow)",
          order: order, worldOrigin: .zero, frame: region, raster: body, knownAssets: knownAssets))
      }
    }
    return (output.layers, coverage)
  }

}

import AppKit
import Foundation
import NotebookCore

struct NotebookPanelPreparedScene {
  let snapshot: JSONValue
  let metadata: NotebookPanelMetadata
  let pixels: ScenePixelDependencies?
  let leafRasterCollector: SceneLeafRasterWitnessCollector
  let pageSource: NotebookPageSource?
}

/// Ephemeral app presentation executes in the publisher's existing target queue.
/// Native world material is borrowed from its shared pool; no camera receipt is written.
extension CurrentViewPreviewWriter {
  @MainActor
  static func panelMaterial(_ cut: NotebookPanelPresentationCut, model: NotebookAppModel,
    knownAssets: Set<UUID>, reusing pageSource: NotebookPageSource? = nil) async throws -> NotebookPanelPreparedScene {
    let projection = cut.projection, target = cut.target, actor = model.actorID
    try projection.validated()
    guard model.permitsPanelPreparation else { throw CancellationError() }
    let collector = SceneLeafRasterWitnessCollector()
    var prepared = false
    defer { if !prepared { collector.close() } }
    func observe(_ stage: String) {
      guard target.kind == .page, let observer = NotebookNavigationObservation.onPageMaterialPreparation else { return }
      observer(stage, cut.id, target.id, nil, nil, ProcessInfo.processInfo.systemUptime)
    }
    observe("panel_prepare_started")
    let viewBounds = WorkspaceSpatialBounds(origin: projection.worldOrigin,
      width: projection.viewport.x / projection.camera.scale, height: projection.viewport.y / projection.camera.scale)
    let initialCoverage = target.kind == .page
      ? try CompositionTileCoverage(bounds: viewBounds,
        pixelsPerWorldPoint: projection.camera.scale * projection.pixelScale, maximumTiles: 8)
      : try CompositionTileCoverage(bounds: viewBounds,
        pixelsPerWorldPoint: projection.camera.scale * projection.pixelScale)
    let initialBounds = WorkspaceSpatialBounds(origin: initialCoverage.tiles.first!.origin,
      maximum: initialCoverage.tiles.last!.bounds.maximum)
    let captured = try await model.readCommandCut { reader in
      let header = try reader.workspaceHeader()
      guard header.workspaceID == projection.workspaceID,
        try reader.referenceRevision(target: target) == cut.sourceRevision else { throw NotebookStorageError.transactionConflict }
      let page = target.kind == .page ? try reader.capturePanelPageContent(cut, reusing: pageSource) : nil
      if let page {
        // The painter always borrows this graph. Build it on the existing
        // reader; prepare visibility only for its actual physical paint window.
        let graph = page.page.graphicGraph()
        if initialBounds.intersection(.init(origin: .zero, width: page.page.size.width, height: page.page.size.height)) != nil {
          graph.prepareVisibility(on: .page(page.page.id))
        }
        try Task.checkCancellation()
      }
      let snapshot = target.kind == .board ? try reader.readPanel(.init(workspaceID: projection.workspaceID, target: target,
        bounds: .init(anchor: initialBounds.origin,
          region: .init(x: 0, y: 0, width: initialBounds.width, height: initialBounds.height))), actor: actor) : nil
      return (header, snapshot, page)
    }
    try Task.checkCancellation()
    guard model.permitsPanelPreparation else { throw CancellationError() }
    let (header, capturedSnapshot, page) = captured
    observe("panel_content_captured")
    let source = SceneCompositionSource(store: model.store, revision: header.cursor,
      workspaceID: projection.workspaceID, recordPixelDependencies: true, documentGeometry: model.documentPaperSizes)
    let layers: [NotebookPanelRasterLayer], coverage: CompositionTileCoverage, diagnostics: [RenderDiagnostic]
    let materialBounds: WorkspaceSpatialBounds
    if let page {
      (layers, coverage, diagnostics, materialBounds) = try await pagePanelMaterials(page, projection: projection, initialCoverage: initialCoverage,
        knownAssets: knownAssets, sourceRevision: cut.sourceRevision, model: model, leafRasterCollector: collector)
    } else {
      let candidates = Array((capturedSnapshot?["elements"]?.arrayValues ?? []).filter(NotebookPanelEditableSubject.allows)
        .prefix(NotebookPanelRenderProjection.maximumSubjects))
      let ids = Set(candidates.compactMap { $0["source"]?["id"]?.stringValue })
      let presence = SessionPresence(boardID: target.id, mode: .board, camera: projection.camera, viewport: projection.viewport)
      let renderer = SceneCompositionRenderer(source: source, leafRasterCollector: collector,
        permitsPreparation: { model.permitsPanelPreparation })
      let movable = Set((capturedSnapshot?["cards"]?.arrayValues ?? []).prefix(NotebookPanelRenderProjection.maximumSubjects)
        .compactMap { $0["item"]?["id"]?.stringValue.flatMap(UUID.init(uuidString:)) })
      let result = try await renderer.renderPanel(presence: presence, projection: projection,
        editableIDs: ids, movableItemIDs: movable, knownAssets: knownAssets)
      layers = result.layers; coverage = result.coverage; diagnostics = result.diagnostics; materialBounds = result.bounds
    }
    observe("panel_material_prepared")
    let preparedSnapshot: JSONValue?
    if target.kind == .board {
      preparedSnapshot = try await model.readCommandCut { reader in
        guard try reader.storedWorkspaceID() == projection.workspaceID,
          try reader.referenceRevision(target: target) == cut.sourceRevision else { throw NotebookStorageError.transactionConflict }
        return try reader.readPanel(.init(workspaceID: projection.workspaceID, target: target,
          bounds: .init(anchor: materialBounds.origin,
            region: .init(x: 0, y: 0, width: materialBounds.width, height: materialBounds.height)),
          includeFitBounds: cut.includeFitBounds), actor: actor)
      }
    } else { preparedSnapshot = nil }
    var cardItems: [RenderedWorkspaceItem] = []
    if target.kind == .board {
      let presence = SessionPresence(boardID: target.id, mode: .board, camera: projection.camera, viewport: projection.viewport)
      for card in preparedSnapshot?["cards"]?.arrayValues ?? [] {
        guard let id = card["item"]?["id"]?.stringValue.flatMap(UUID.init(uuidString:)),
          let item = try await source.item(id, presence: presence) else { throw NotebookStorageError.transactionConflict }
        cardItems.append(item)
      }
      cardItems.sort { WorkspaceSceneProjection.isPaintedBelow($0, $1, in: presence) }
    }
    let projectedItems = cardItems
    let dependencies = try await source.pixelDependencies()
    try Task.checkCancellation()
    guard model.permitsPanelPreparation else { throw CancellationError() }
    let (snapshot, metadata, retainedSource) = try await model.readCommandCut { reader in
      try Task.checkCancellation()
      guard try reader.storedWorkspaceID() == projection.workspaceID,
        try reader.referenceRevision(target: target) == cut.sourceRevision,
        try dependencies?.isCurrent(reader) != false else { throw NotebookStorageError.transactionConflict }
      // Content is immutable; device-local history, membership/selection and
      // cursor are read after the last await in this publication transaction.
      let metadata = try reader.readPanelMetadata(workspaceID: projection.workspaceID, target: target, actor: actor)
      var snapshot: JSONValue
      if let page {
        snapshot = try reader.readPanel(.init(workspaceID: projection.workspaceID, target: target,
          bounds: .init(anchor: materialBounds.origin,
            region: .init(x: 0, y: 0, width: materialBounds.width, height: materialBounds.height)),
          includeFitBounds: cut.includeFitBounds), actor: actor, reusing: page)
      } else if let preparedSnapshot { snapshot = try metadata.updating(preparedSnapshot) }
      else { throw NotebookStorageError.transactionConflict }
      let editable = Set(layers.compactMap(\.elementID)), movable = Set(layers.compactMap(\.itemID))
      snapshot = snapshot.setting("elements", .array((snapshot["elements"]?.arrayValues ?? []).map { entry in
        entry.setting("editable", .bool(entry["source"]?["id"]?.stringValue.map(editable.contains) == true))
      }))
      let cards = snapshot["cards"]?.arrayValues ?? []
      let cardsByID = Dictionary(uniqueKeysWithValues: try cards.map { card -> (UUID, JSONValue) in
        guard let id = card["item"]?["id"]?.stringValue.flatMap(UUID.init(uuidString:)) else { throw NotebookStorageError.transactionConflict }
        return (id, card)
      })
      let projectedCards = try projectedItems.compactMap { item -> JSONValue? in
        guard let card = cardsByID[item.id] else { return nil }
        let frame = PageRect(x: -item.geometry.width / 2, y: -item.geometry.height / 2,
          width: item.geometry.width, height: item.geometry.height)
        return try card.setting("editable", .bool(movable.contains(item.id)))
          .setting("frame", .encode(frame)).setting("worldOrigin", .encode(item.center)).setting("center", .encode(item.center))
          .setting("geometry", .object(["width": .number(frame.width), "height": .number(frame.height)]))
      }
      guard projectedCards.count == cards.count else { throw NotebookStorageError.transactionConflict }
      snapshot = snapshot.setting("cards", .array(projectedCards))
      if target.kind == .page { snapshot = snapshot.setting("worldOrigin", try .encode(WorldPoint.zero)) }
      let appearance = JSONValue.object(["status": .string("ready"), "requestID": try .encode(cut.id),
        "sourceRevision": .string(cut.sourceRevision), "cursor": snapshot["cursor"] ?? .string(String(header.cursor)),
        "camera": try .encode(projection.camera), "viewport": try .encode(projection.viewport),
        "coverage": .object(["anchor": try .encode(materialBounds.origin),
          "region": try .encode(PageRect(x: 0, y: 0, width: materialBounds.width, height: materialBounds.height)),
          "level": .number(Double(coverage.level)),
          "pixelDensity": .number(layers.filter { $0.repeatSize == nil }
            .map { min(Double($0.pixelWidth) / $0.frame.width, Double($0.pixelHeight) / $0.frame.height) }.min()
            ?? projection.camera.scale * projection.pixelScale)]),
        "layers": .array(try layers.map { try $0.encoded }), "diagnostics": try .encode(diagnostics)])
      snapshot = snapshot.setting("appearance", appearance)
      guard try JSONEncoder().encode(snapshot).count <= NotebookPanelRenderProjection.maximumEncodedBytes else {
        throw SceneRenderError.resourceLimit
      }
      var retainedSource = page?.source
      if let page, let visible = materialBounds.intersection(.init(origin: .zero, width: page.page.size.width, height: page.page.size.height)),
        visible.width > 0, visible.height > 0 { retainedSource = page.sourceForRetention() }
      return (snapshot, metadata, retainedSource)
    }
    try Task.checkCancellation()
    guard model.permitsPanelPreparation else { throw CancellationError() }
    guard collector.isCurrent else { throw NotebookStorageError.transactionConflict }
    observe("panel_published")
    prepared = true
    return .init(snapshot: snapshot, metadata: metadata, pixels: dependencies, leafRasterCollector: collector,
      pageSource: retainedSource)
  }

  /// Finite pages use the same world grid and native paper/ordered ink owners.
  /// Their body pixels are stable across a pan just like board materials.
  @MainActor
  private static func pagePanelMaterials(_ content: NotebookPanelPageContent, projection: NotebookPanelRenderProjection,
    initialCoverage: CompositionTileCoverage,
    knownAssets: Set<UUID>, sourceRevision: String, model: NotebookAppModel,
    leafRasterCollector: SceneLeafRasterWitnessCollector)
    async throws -> ([NotebookPanelRasterLayer], CompositionTileCoverage, [RenderDiagnostic], WorkspaceSpatialBounds) {
    let page = content.page, resources = SceneRenderResources.shared, graph = page.graphicGraph()
    let requested = WorkspaceSpatialBounds(origin: projection.worldOrigin,
      width: projection.viewport.x / projection.camera.scale, height: projection.viewport.y / projection.camera.scale)
    var coverage = initialCoverage
    var admitted = WorkspaceSpatialBounds(origin: coverage.tiles.first!.origin,
      maximum: coverage.tiles.last!.bounds.maximum)
    let requestedOffset = WorldPoint.zero.delta(to: requested.origin)
    let viewport = CGRect(x: requestedOffset.x, y: requestedOffset.y, width: requested.width, height: requested.height)
    let admittedOffset = WorldPoint.zero.delta(to: admitted.origin)
    var materialWindow = CGRect(x: admittedOffset.x, y: admittedOffset.y, width: admitted.width, height: admitted.height)
    let target = CollaborationTarget(kind: .page, id: page.id)
    let requestedDensity = projection.camera.scale * projection.pixelScale
    let density = max(requestedDensity, Double(SceneCompositionTileKey.requiredPixelSize(for: coverage.tiles[0],
      density: requestedDensity)) / coverage.tiles[0].worldSize)
    let physical = CGRect(x: 0, y: 0, width: page.size.width, height: page.size.height)
    var borrowed: RasterLease?, preparation: SceneWebRasterPreparation?
    var sourceRasters: [SceneSourceAddress: RasterLease] = [:], receipts: [SceneSourceAddress: SceneSourceReceipt] = [:]
    var materialSources: Set<SceneSourceAddress> = []
    defer { borrowed?.release(); preparation?.close(); sourceRasters.values.forEach { $0.release() } }
    func raster(_ element: AgentElement) async throws -> RasterLease {
      borrowed?.release(); borrowed = nil
      let scale = density * (graph.placement(element.id).map { NotebookElementPresentation.maximumScale($0.transform) } ?? 1)
      let value: RasterLease
      if let cached = resources.retainRaster(for: element, minimumScale: scale) { value = cached }
      else {
        if preparation == nil { preparation = try await SceneWebRasterPreparation.create(resources: resources,
          permitsPreparation: { model.permitsPanelPreparation }) }
        value = try await preparation!.prepare(element, requestedScale: scale, programStore: model.store,
          permitsPreparation: { model.permitsPanelPreparation })
      }
      borrowed = value
      leafRasterCollector.record(resources.leafRasterWitnesses(for: .agent(element), minimumScale: scale, using: value))
      let address = SceneSourceAddress(plane: .board(page.id), elementID: element.id)
      materialSources.insert(address)
      let demand = SceneSourceDemand(source: element, minimumScale: scale)
      receipts[address] = .init(demand: demand, installedSource: value.source.agentElement, installedScale: value.pixelScale,
        status: .ready, installedRegion: value.source.captureRegion)
      sourceRasters[address]?.release(); sourceRasters[address] = value.retainedCopy()
      return value
    }
    var output = NotebookPanelRasterSet()
    func paintElements(in window: CGRect) -> [AgentElement] {
      let clipped = window.intersection(physical)
      guard !clipped.isNull, !clipped.isEmpty else { return [] }
      return PageCompositionRenderer.elements(in: page,
        region: .init(x: clipped.minX, y: clipped.minY, width: clipped.width, height: clipped.height), elementID: nil)
    }
    func paintFrames(_ elements: [AgentElement]) -> [String: CGRect] {
      Dictionary(uniqueKeysWithValues: elements.compactMap { element -> (String, CGRect)? in
        let frame = graph.resolve(element.id).layout?.frame
          ?? graph.placement(element.id).map { NotebookElementPresentation(element, placement: $0).frame }
        return frame.map { (element.id, CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)) }
      })
    }
    var elements = paintElements(in: materialWindow), elementFrames = paintFrames(elements)
    var inkOwnedIDs = Set(elements.compactMap { $0.graphic?.sourceInkContactID == nil ? nil : $0.id })
    func projectedElements(in bounds: WorkspaceSpatialBounds) throws -> [JSONValue] {
      try content.projection(in: .init(anchor: bounds.origin,
        region: .init(x: 0, y: 0, width: bounds.width, height: bounds.height))).elements
    }
    var subjects = pagePanelSubjects(try projectedElements(in: admitted), frames: elementFrames, physical: physical,
      materialWindow: materialWindow, viewport: viewport, density: density, inkOwnedIDs: inkOwnedIDs)
    func visibleIDs(in frame: CGRect) -> Set<String> {
      Set(elementFrames.compactMap { $0.value.intersects(frame) ? $0.key : nil })
    }
    let inkSource = page.inkSource
    let inkRead = Task.detached(priority: .utility) { try inkSource.drawing() }
    let drawing = try await withTaskCancellationHandler { try await inkRead.value } onCancel: { inkRead.cancel() }
    try Task.checkCancellation()
    var hasInk: Bool { !drawing.isEmpty || !inkOwnedIDs.isEmpty }
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
    func fitCompositionCoverage() throws {
      while coverage.tiles.count * (runs.bands.count + 1 + (hasInk ? 1 : 0)) > SceneCompositionPlan.maximumTiles {
        let coarser = try CompositionTileCoverage(bounds: admitted,
          pixelsPerWorldPoint: Double(CompositionTile.pixelSize) / (coverage.tiles[0].worldSize * 2), maximumTiles: 8)
        if coarser.level > coverage.level { coverage = coarser }
        else if let optional = pagePanelOptionalSubject(subjects, ranks: runs.subjects, viewport: viewport) {
          subjects.removeValue(forKey: optional); runs = painterRuns()
        } else { throw SceneRenderError.resourceLimit }
      }
    }
    try fitCompositionCoverage()
    func regions(density: Double) -> [(tile: CompositionTile, frame: CGRect)] {
      var result: [(CompositionTile, CGRect)] = []
      let side = 1024 / density
      for tile in coverage.tiles {
        let offset = WorldPoint.zero.delta(to: tile.origin)
        let frame = physical.intersection(.init(x: offset.x, y: offset.y, width: tile.worldSize, height: tile.worldSize))
          .intersection(materialWindow)
        guard !frame.isNull, !frame.isEmpty else { continue }
        // The ordered renderer needs eight temporary backings. Admit a bounded
        // regional working set within the existing passive allocation window.
        for row in 0..<Int(ceil(frame.height / side)) {
          for column in 0..<Int(ceil(frame.width / side)) {
            let x = frame.minX + Double(column) * side, y = frame.minY + Double(row) * side
            let width = min(side, frame.maxX - x), height = min(side, frame.maxY - y)
            guard width > 0, height > 0 else { continue }
            result.append((tile, CGRect(x: x, y: y, width: width, height: height)))
          }
        }
      }
      return result
    }
    func pixelCount(_ frame: CGRect, scale: Double) -> Int {
      let width = ceil(frame.width * scale), height = ceil(frame.height * scale)
      guard width <= 8192, height <= 8192 else { return NotebookPanelRenderProjection.maximumDecodedPixels + 1 }
      return Int(width) * Int(height)
    }
    var tileDensity = max(requestedDensity, Double(SceneCompositionTileKey.requiredPixelSize(for: coverage.tiles[0],
      density: requestedDensity)) / coverage.tiles[0].worldSize)
    var tiles = regions(density: tileDensity), diagnostics: [RenderDiagnostic] = []
    func cost() -> (pixels: Int, layers: Int) {
      if tiles.count + subjects.count > 96 {
        return (NotebookPanelRenderProjection.maximumDecodedPixels + 1, tiles.count + subjects.count)
      }
      var pixels = subjects.values.reduce(0) { $0 + pixelCount(CGRect(x: 0, y: 0, width: $1.width, height: $1.height), scale: density) }
      var count = subjects.count
      for (_, frame) in tiles {
        pixels += pixelCount(frame, scale: tileDensity); count += 1
        if hasInk { pixels += pixelCount(frame, scale: tileDensity); count += 1 }
        let visible = visibleIDs(in: frame)
        for band in runs.bands where !band.ids.isDisjoint(with: visible) {
          pixels += pixelCount(frame, scale: tileDensity); count += 1
        }
      }
      return (pixels, count)
    }
    func fits() -> Bool { let value = cost(); return value.pixels <= NotebookPanelRenderProjection.maximumDecodedPixels && value.layers <= 96 }
    if !fits() {
      // Coarsening changes the grid inside one admitted overscan window. Only
      // this budget transition narrows that window and rebuilds admission.
      admitted = requested; materialWindow = viewport
      elements = paintElements(in: materialWindow); elementFrames = paintFrames(elements)
      inkOwnedIDs = Set(elements.compactMap { $0.graphic?.sourceInkContactID == nil ? nil : $0.id })
      subjects = pagePanelSubjects(try projectedElements(in: admitted), frames: elementFrames, physical: physical,
        materialWindow: materialWindow, viewport: viewport, density: density, inkOwnedIDs: inkOwnedIDs)
      runs = painterRuns(); try fitCompositionCoverage()
      tileDensity = requestedDensity; tiles = regions(density: tileDensity)
    }
    while !fits(), let optional = pagePanelOptionalSubject(subjects, ranks: runs.subjects, viewport: viewport) {
      subjects.removeValue(forKey: optional); runs = painterRuns()
    }
    let minimumDensity = Double(CompositionTile.pixelSize) / coverage.tiles[0].worldSize / 1024
    while !fits() {
      try Task.checkCancellation()
      guard tileDensity > minimumDensity else { throw SceneRenderError.resourceLimit }
      tileDensity *= 0.9
      tiles = regions(density: tileDensity)
    }
    if tileDensity + 0.000001 < requestedDensity {
      diagnostics.append(.init(kind: "quality_limit", message: "Разрешение видимой страницы ограничено общим объёмом пикселей. Приблизьте меньший участок."))
    }
    var materialPreparation: PageCompositionRenderer.MaterialPreparation?
    func preparedMaterial() async throws -> PageCompositionRenderer.MaterialPreparation {
      if let materialPreparation { return materialPreparation }
      let inkRegion = tiles.reduce(CGRect.null) { $0.union($1.frame) }
      let region = subjects.values.reduce(inkRegion) { bounds, frame in
        bounds.union(CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height))
      }
      let value = try await PageCompositionRenderer.prepareMaterial(page, graph: graph, region: region,
        scale: max(density, tileDensity), resources: resources,
        permitsPreparation: { model.permitsPanelPreparation })
      materialPreparation = value
      return value
    }
    let bands = runs.bands
    let bandRoles = bands.map { "page-elements:" + $0.ids.sorted().joined(separator: ",") }
    for element in elements {
      guard let frame = subjects[element.id], let rank = runs.subjects[element.id] else { continue }
      let key = try SceneMaterialKey(workspaceID: projection.workspaceID, target: target, revision: sourceRevision,
        role: "element:" + element.id, frame: frame, density: density)
      let body: RasterLease
      if let cached = resources.retainMaterial(key) { body = cached }
      else {
        materialSources.removeAll(keepingCapacity: true)
        body = try await PageCompositionRenderer.renderMaterial(page, ids: [element.id], region: frame,
          scale: density, key: key, preparation: preparedMaterial(), resources: resources,
          permitsPreparation: { model.permitsPanelPreparation }, raster: raster)
        resources.cacheComposition(body, receipts: receipts.filter { materialSources.contains($0.key) },
          sources: sourceRasters.filter { materialSources.contains($0.key) })
      }
      defer { body.release() }
      leafRasterCollector.record(body.leafRasters)
      try output.append(await .completed(id: "subject-" + element.id, order: rank, worldOrigin: .zero,
        frame: frame, raster: body, knownAssets: knownAssets, elementID: element.id, subjectFrame: frame))
    }
    for (regionIndex, entry) in tiles.enumerated() {
      let (tile, visible) = entry
      let region = PageRect(x: visible.minX, y: visible.minY, width: visible.width, height: visible.height)
      let owners = visibleIDs(in: visible)
      for index in -1...bands.count {
        if index == bands.count && !hasInk { continue }
        if index >= 0 && index < bands.count && bands[index].ids.isDisjoint(with: owners) { continue }
        let role = index == -1 ? "page-paper" : index == bands.count ? "page-ink" : bandRoles[index]
        let order = index == -1 ? -1 : index == bands.count ? 1000 : bands[index].rank
        let rasterDensity = tileDensity
        let key = try SceneMaterialKey(workspaceID: projection.workspaceID, target: target, revision: sourceRevision,
          role: role, frame: region, density: rasterDensity)
        let body: RasterLease
        if let cached = resources.retainMaterial(key) { body = cached }
        else if index == -1 {
          let canvas = try await SceneRasterCompositor.create(size: visible.size, scale: rasterDensity, resources: resources,
            permitsPreparation: { model.permitsPanelPreparation })
          try await canvas.drawPaper(size: physical.size, in: physical.offsetBy(dx: -visible.minX, dy: -visible.minY))
          body = try await canvas.finishRaster(for: .material(key))
          resources.cacheComposition(body, receipts: [:], sources: [:])
        } else {
          materialSources.removeAll(keepingCapacity: true)
          body = try await PageCompositionRenderer.renderMaterial(page,
            ids: index == bands.count ? nil : bands[index].ids, region: region, scale: rasterDensity,
            key: key, preparation: preparedMaterial(), resources: resources,
            permitsPreparation: { model.permitsPanelPreparation }, raster: raster)
          resources.cacheComposition(body, receipts: receipts.filter { materialSources.contains($0.key) },
            sources: sourceRasters.filter { materialSources.contains($0.key) })
        }
        defer { body.release() }
        leafRasterCollector.record(body.leafRasters)
        try output.append(await .completed(id: role + ":\(tile.column):\(tile.row):\(tile.localColumn):\(tile.localRow):\(regionIndex)",
          order: order, worldOrigin: .zero, frame: region, raster: body, knownAssets: knownAssets))
      }
    }
    return (output.layers, coverage, diagnostics, admitted)
  }

  /// Pixel-independent admission preserves full authored bodies and painter
  /// order. Visible subjects take the finite grant before prefetched neighbors.
  static func pagePanelSubjects(_ elements: [JSONValue], frames: [String: CGRect], physical: CGRect,
    materialWindow: CGRect, viewport: CGRect, density: Double, inkOwnedIDs: Set<String> = []) -> [String: PageRect] {
    var subjects: [String: PageRect] = [:]
    var available = NotebookPanelRenderProjection.maximumDecodedPixels
      - SceneCompositionPlan.maximumTiles * CompositionTile.pixelSize * CompositionTile.pixelSize
    for visibleFirst in [true, false] {
      for entry in elements {
        guard subjects.count < NotebookPanelRenderProjection.maximumSubjects else { break }
        guard let id = entry["source"]?["id"]?.stringValue,
          let frame = frames[id], frame.width > 0, frame.height > 0,
          frame.width * density <= 2048, frame.height * density <= 2048, physical.contains(frame) else { continue }
        let admitted = frame.intersection(materialWindow), visible = frame.intersection(viewport)
        guard !admitted.isNull, !admitted.isEmpty, (!visible.isNull && !visible.isEmpty) == visibleFirst,
          !inkOwnedIDs.contains(id), NotebookPanelEditableSubject.allows(entry) else { continue }
        let pixels = Int(ceil(frame.width * density)) * Int(ceil(frame.height * density))
        guard pixels <= available else { continue }
        available -= pixels
        subjects[id] = .init(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
      }
    }
    return subjects
  }

  /// Demotion follows the same viewport priority as admission. Its search is
  /// bounded by the sixteen subjects, independently of total page membership.
  static func pagePanelOptionalSubject(_ subjects: [String: PageRect], ranks: [String: Int], viewport: CGRect) -> String? {
    func isPrefetched(_ id: String) -> Bool {
      let frame = subjects[id]!
      let visible = viewport.intersection(.init(x: frame.x, y: frame.y, width: frame.width, height: frame.height))
      return visible.isNull || visible.isEmpty
    }
    return subjects.keys.max { first, second in
      let firstPrefetched = isPrefetched(first), secondPrefetched = isPrefetched(second)
      if firstPrefetched != secondPrefetched { return !firstPrefetched }
      return ranks[first, default: -1] < ranks[second, default: -1]
    }
  }

}

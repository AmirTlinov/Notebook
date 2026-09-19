import CoreGraphics
import NotebookCore
import SwiftUI

/// Exact, sequential painting of the physical scene. Camera and page-turn input
/// are absent here: a request supplies immutable sources and one projection.
/// Only a bounded index page and a borrowed source image enter each step.
@MainActor
final class SceneCompositionRenderer {
  struct Result {
    let png: Data
    let diagnostics: [RenderDiagnostic]
  }
  private let source: SceneCompositionSource
  private let resources: SceneRenderResources
  private let permitsPreparation: @MainActor () -> Bool
  private var webPreparation: SceneWebRasterPreparation?
  private let usesPreparedSources: Bool
  private var fallbackSources: [SceneSourceAddress: RasterLease]
  private var sourceFailures: [SceneSourceAddress: SceneSourceFailure]
  private var currentTile: SceneCompositionTileKey?
  var onSourceDemand: (@MainActor () -> Void)?
  private var paintedTiles = Set<SceneCompositionTileKey>()
  private var carriedReceipts: [SceneSourceAddress: SceneSourceReceipt] = [:]
  private var sourcePresentation: (plan: SceneCompositionPlan, frame: WorkspaceSceneFrame, displayScale: Double, refinesDetails: Bool)?
  private(set) var sourceDemands: [SceneSourceAddress: SceneSourceDemand] = [:]
  private(set) var sourceRasters: [SceneSourceAddress: RasterLease] = [:]
  private(set) var tileSources: [SceneCompositionTileKey: Set<SceneSourceAddress>] = [:]

  func useSourcePresentation(plan: SceneCompositionPlan, frame: WorkspaceSceneFrame, displayScale: Double, refinesDetails: Bool = true) {
    sourcePresentation = (plan, frame, displayScale, refinesDetails)
  }

  private func demand(for element: SpatialElement, plane: SceneCompositionPlane, density: Double) -> SceneSourceDemand {
    let source = agentElementSnapshotSource(element)
    guard let window = sourcePresentation,
      let view = window.plan.presentations[.board(plane.boardID)] else { return .init(source: source, minimumScale: density) }
    let address = SceneSourceAddress(plane: plane, elementID: source.id)
    let previous = fallbackSources[address].flatMap { raster in
      raster.source.agentElement.map { SceneRasterSource.agent($0) == .agent(source) } == true ? raster : nil
    }
    let density: Double = if !window.refinesDetails, let previous,
      (0.6...sqrt(2.0)).contains(density / previous.pixelScale) { previous.pixelScale }
      else { pow(2, ceil(log2(density) * 2) / 2) }
    var region = SceneSourceCapture.region(element: element, plane: plane,
      presence: view, frame: window.frame, density: density)
    let origin = SceneSourceCapture.origin(element: element, plane: plane, frame: window.frame)
    if region != nil, let previous,
      previous.pixelScale + 0.000_001 >= density, let old = previous.source.captureRegion {
      let visible = SceneSourceCapture.visibleRect(source: source, origin: origin, presence: view)
      if CGRect(x: old.x, y: old.y, width: old.width, height: old.height).contains(visible) { region = old }
    }
    return .init(source: source, minimumScale: density, region: region, worldOrigin: origin)
  }

  func sourcesOutsideCoverage(of previous: SceneCompositionCohort?) async throws -> Set<SceneSourceAddress> {
    guard let previous, let window = sourcePresentation else { return [] }
    var changed = Set<SceneSourceAddress>()
    for (address, receipt) in previous.sourceReceipts {
      guard let element = try await source.element(address.elementID, boardID: address.plane.boardID) else { continue }
      let scale = (window.frame.pixelScales[address.plane.boardID] ?? 1) * window.displayScale
      if demand(for: element, plane: address.plane, density: scale) != receipt.demand { changed.insert(address) }
    }
    return changed
  }

  /// Carried tiles keep the source receipts and owned fallbacks that produced
  /// them. Only fragments actually redrawn in this pass replace those values.
  func carrySources(from previous: SceneCompositionCohort?, tiles: [SceneCompositionTileKey: RasterLease]) {
    for (key, raster) in tiles {
      let oldKey = previous?.rasters.first { $0.value.entryID == raster.entryID }?.key
      let fromPrevious = oldKey != nil
      let receipts = fromPrevious ? previous?.sourceReceipts ?? [:] : resources.compositionReceipts(for: raster) ?? [:]
      let dependencies = fromPrevious ? oldKey.flatMap { previous?.tileSources[$0] } ?? [] : Set(receipts.keys)
      tileSources[key] = dependencies
      for address in dependencies {
        if let receipt = receipts[address] {
          sourceDemands[address] = receipt.demand; carriedReceipts[address] = receipt
        }
        if sourceRasters[address] == nil, fromPrevious {
          sourceRasters[address] = previous?.sourceRasters[address]?.retainedCopy()
        }
      }
    }
  }

  func cachePreparedTiles(_ rasters: [SceneCompositionTileKey: RasterLease]) {
    let receipts = receipts()
    for key in paintedTiles {
      guard let raster = rasters[key] else { continue }
      let dependencies = tileSources[key] ?? []
      resources.cacheComposition(raster, receipts: receipts.filter { dependencies.contains($0.key) }, sources: sourceRasters)
    }
  }

  /// Start the addressed, bounded workset before native preparation or a
  /// placeholder pass. Deeper painter discoveries join the same scheduler.
  func discoverSources(plan: SceneCompositionPlan, frame: WorkspaceSceneFrame, displayScale: Double) async throws {
    for plane in plan.presentations.keys {
      let workset = plane.coverID.flatMap { frame.covers[$0] } ?? frame.worksets[plane.boardID]
      let erased = try await source.wholeErasedElements(workset?.elements ?? [])
      for element in workset?.elements ?? [] where element.kind != .nativeText && element.kind != .graphic {
        if erased.contains(element.id) { continue }
        let address = SceneSourceAddress(plane: plane, elementID: element.id)
        let demand = demand(for: element, plane: plane,
          density: (frame.pixelScales[plane.boardID] ?? 1) * displayScale)
        sourceDemands[address] = demand
        if sourceRasters[address] == nil {
          sourceRasters[address] = resources.retainRaster(for: demand.rasterSource, minimumScale: demand.minimumScale)
            ?? fallbackSources[address]?.retainedCopy()
        }
      }
    }
  }

  func useLiveSources(_ requests: [LiveRasterRequest]) {
    for request in requests {
      let address = SceneSourceAddress(plane: request.owner.plane, elementID: request.source.id)
      sourceDemands[address] = request.demand
      sourceRasters[address] = resources.retainRaster(for: request.demand.rasterSource, minimumScale: request.requestedScale)
        ?? fallbackSources[address]?.retainedCopy()
    }
  }

  func receipts() -> [SceneSourceAddress: SceneSourceReceipt] {
    return Dictionary(uniqueKeysWithValues: sourceDemands.map { address, demand in
      let raster = sourceRasters[address]
      if raster == nil, let carried = carriedReceipts[address], carried.demand == demand {
        return (address, carried)
      }
      let installed: AgentElement?
      installed = raster?.source.agentElement
      let ready = raster?.image(for: demand.rasterSource, minimumScale: demand.minimumScale) != nil
      let failure = sourceFailures[address].flatMap { failure in
        failure.matches(demand) ? failure.message : nil
      }
      let status: SceneSourceReceipt.Status = ready ? .ready : failure.map(SceneSourceReceipt.Status.failed) ?? .pending
      return (address, .init(demand: demand, installedSource: installed,
        installedScale: raster?.pixelScale ?? 0, status: status, installedRegion: raster?.source.captureRegion))
    })
  }

  init(source: SceneCompositionSource, resources: SceneRenderResources = .shared,
    usesPreparedSources: Bool = false,
    fallbackSources: [SceneSourceAddress: RasterLease] = [:],
    sourceFailures: [SceneSourceAddress: SceneSourceFailure] = [:],
    permitsPreparation: @escaping @MainActor () -> Bool = { true }) {
    self.source = source; self.resources = resources; self.permitsPreparation = permitsPreparation
    self.usesPreparedSources = usesPreparedSources
    self.fallbackSources = fallbackSources; self.sourceFailures = sourceFailures
  }

  func render(presence: SessionPresence, scale: Double = 2, transitionViewport: SpatialPoint? = nil) async throws -> Result {
    defer { finishPreparation() }
    try checkPreparation()
    guard try await source.boardExists(presence.boardID) else { throw SceneRenderError.snapshotPending("board_source") }
    let size = CGSize(width: presence.viewport.x, height: presence.viewport.y)
    let canvas = try await SceneRasterCompositor.create(size: size, scale: scale,
      resources: resources, permitsPreparation: permitsPreparation)
    try checkPreparation()
    let frame = CGRect(origin: .zero, size: size)
    try await paintBoard(presence: presence, frame: frame, visible: frame,
      transitionViewport: transitionViewport ?? presence.viewport, passes: WorkspaceSceneProjection.portalPasses,
      canvas: canvas)
    try await source.validate()
    let png = try await canvas.finishPNG()
    return .init(png: png, diagnostics: canvas.diagnostics)
  }

  /// A physical cover contains only its paper, contents and ink. Neighbouring
  /// boards and shadows behind its transparent corners are not its sources.
  func renderCover(itemID: UUID, boardID: UUID, scale: Double = 2) async throws -> Result {
    defer { finishPreparation() }
    try checkPreparation()
    let presence = SessionPresence(boardID: boardID, mode: .cover, camera: .init(),
      viewport: .init(x: 834, y: 1194), focusedItemID: itemID)
    guard let item = try await source.item(itemID, presence: presence) else {
      throw SceneRenderError.snapshotPending("cover_source")
    }
    let size = CGSize(width: item.geometry.width, height: item.geometry.height)
    let canvas = try await SceneRasterCompositor.create(size: size, scale: scale,
      resources: resources, permitsPreparation: permitsPreparation)
    let frame = CGRect(origin: .zero, size: size)
    try await paintCover(item, boardID: boardID, frame: frame, visible: frame,
      transitionViewport: .init(x: size.width, y: size.height), passes: WorkspaceSceneProjection.portalPasses,
      canvas: canvas)
    try await source.validate()
    let png = try await canvas.finishPNG()
    return .init(png: png, diagnostics: canvas.diagnostics)
  }

  /// A tile owns transparent pixels of precisely one static painter range.
  /// The live board grid, ink and excluded owners are not duplicated here.
  func renderTile(key: SceneCompositionTileKey, presentation: SessionPresence) async throws -> RasterLease {
    try checkPreparation()
    currentTile = key
    defer { currentTile = nil }
    guard key.workspaceID == source.workspaceID, key.revision == source.revision,
      key.plane.boardID == presentation.boardID else { throw NotebookStorageError.transactionConflict }
    let tile = key.tile
    let cameraScale = min(SpatialCamera.maximumScale, max(SpatialCamera.minimumScale,
      Double(key.pixelSize) / tile.worldSize))
    let side = tile.worldSize * cameraScale
    let camera = SpatialCamera(center: tile.origin.offsetBy(x: tile.worldSize / 2, y: tile.worldSize / 2), scale: cameraScale)
    let presence = SessionPresence(boardID: key.plane.boardID, mode: presentation.mode, camera: camera,
      viewport: .init(x: side, y: side), focusedItemID: presentation.focusedItemID)
    let size = CGSize(width: side, height: side), frame = CGRect(origin: .zero, size: size)
    let canvas = try await SceneRasterCompositor.create(size: size, scale: Double(key.pixelSize) / side,
      resources: resources, permitsPreparation: permitsPreparation)
    switch key.plane {
    case .board:
      try await paintBoard(presence: presence, frame: frame, visible: frame,
        transitionViewport: presentation.viewport, passes: WorkspaceSceneProjection.portalPasses,
        range: key.range, itemPresentation: presentation, canvas: canvas)
    case .cover(let boardID, let itemID):
      try await paintCoverElements(itemID: itemID, boardID: boardID, bounds: tile.bounds,
        frame: frame, projection: cameraScale, range: key.range, canvas: canvas)
    }
    try await source.validate(); try checkPreparation()
    let raster = try await canvas.finishRaster(for: .composition(key))
    paintedTiles.insert(key)
    return raster
  }

  private func paintBoard(presence: SessionPresence, frame: CGRect, visible: CGRect,
    transitionViewport: SpatialPoint, passes: Int, range: ScenePaintRange? = nil,
    itemPresentation: SessionPresence? = nil, canvas: SceneRasterCompositor) async throws {
    try checkPreparation()
    let visible = visible.intersection(frame)
    guard !visible.isNull, !visible.isEmpty else { return }
    let projection = frame.width / presence.viewport.x
    let localVisible = CGRect(x: (visible.minX - frame.minX) / projection,
      y: (visible.minY - frame.minY) / projection,
      width: visible.width / projection, height: visible.height / projection)
    let origin = presence.camera.screenToWorld(.init(x: localVisible.minX, y: localVisible.minY), viewport: presence.viewport)
    let padding = WorkspaceCoverRaster.shadowPadding
    let bounds = WorkspaceSpatialBounds(origin: origin.offsetBy(x: -padding, y: -padding),
      width: localVisible.width / presence.camera.scale + 2 * padding,
      height: localVisible.height / presence.camera.scale + 2 * padding)
    if range == nil {
      try await canvas.drawBoardGrid(camera: presence.camera,
        size: .init(width: presence.viewport.x, height: presence.viewport.y), in: frame)
    }
    if range?.layer == .ink {
      try await paintInk(.board(presence.boardID), camera: presence.camera,
        size: .init(width: presence.viewport.x, height: presence.viewport.y), frame: frame, canvas: canvas)
      return
    }
    var paintedInk = false
    var cursor: SceneCompositionReadCursor?
    repeat {
      try checkPreparation()
      let page = try await source.readPaintOrder(boardID: presence.boardID, bounds: bounds, after: cursor)
      cursor = page.next
      for entry in page.entries {
        if case .item = entry.id, range == nil, !paintedInk {
          try await paintInk(.board(presence.boardID), camera: presence.camera,
            size: .init(width: presence.viewport.x, height: presence.viewport.y), frame: frame, canvas: canvas)
          paintedInk = true
        }
        guard range?.contains(entry) ?? true else { continue }
        switch entry.id {
        case .element(let id):
          guard let element = try await source.element(id, boardID: presence.boardID), let origin = element.worldOrigin else {
            throw SceneRenderError.snapshotPending("element_source")
          }
          let layout = try await source.graphicLayout(element,boardID:presence.boardID)
          if element.graphic != nil && layout == nil { continue }
          let local = layout?.frame ?? .init(x:element.frame.x,y:element.frame.y,width:element.frame.width,height:element.frame.height)
          let screen = presence.camera.worldToScreen(origin.offsetBy(x: local.x, y: local.y), viewport: presence.viewport)
          let rect = CGRect(x: frame.minX + screen.x * projection, y: frame.minY + screen.y * projection,
            width: local.width * presence.camera.scale * projection,
            height: local.height * presence.camera.scale * projection)
          if rect.intersects(visible) { try await paintElement(element, boardID: presence.boardID, frame: rect, canvas: canvas, graphicLayout:layout) }
        case .item(let id):
          guard let item = try await source.item(id, presence: itemPresentation ?? presence) else { continue }
          let screen = presence.camera.worldToScreen(item.center, viewport: presence.viewport)
          let scale = presence.camera.scale * projection
          let rect = CGRect(x: frame.minX + screen.x * projection - item.geometry.width * scale / 2,
            y: frame.minY + screen.y * projection - item.geometry.height * scale / 2,
            width: item.geometry.width * scale, height: item.geometry.height * scale)
          if rect.insetBy(dx: -padding * scale, dy: -padding * scale).intersects(visible) {
            try await paintCover(item, boardID: presence.boardID, frame: rect, visible: visible,
              transitionViewport: transitionViewport, passes: passes, canvas: canvas)
          }
        }
      }
      await Task.yield()
    } while cursor != nil
    if range == nil, !paintedInk {
      try await paintInk(.board(presence.boardID), camera: presence.camera,
        size: .init(width: presence.viewport.x, height: presence.viewport.y), frame: frame, canvas: canvas)
    }
  }

  private func paintInk(_ surface: SurfaceID, camera: SpatialCamera?, size: CGSize,
    frame: CGRect, canvas: SceneRasterCompositor) async throws {
    let journal = try await source.ink(surface)
    guard journal.actions.contains(where: { $0.isActive && $0.spans.contains(where: { $0.surface == surface }) }) else { return }
    try await canvas.drawInk(surface: surface, journal: journal, camera: camera, size: size, in: frame)
  }

  private func paintCoverElements(itemID: UUID, boardID: UUID, bounds: WorkspaceSpatialBounds,
    frame: CGRect, projection: Double, range: ScenePaintRange? = nil, canvas: SceneRasterCompositor) async throws {
    var cursor: SceneCompositionReadCursor?
    repeat {
      try checkPreparation()
      let page = try await source.readPaintOrder(boardID: boardID, coverID: itemID, bounds: bounds, after: cursor)
      cursor = page.next
      for entry in page.entries where range?.contains(entry) ?? true {
        guard case .element(let id) = entry.id, let element = try await source.element(id, boardID: boardID) else {
          throw SceneRenderError.snapshotPending("cover_element_source")
        }
        let layout = try await source.graphicLayout(element,boardID:boardID)
        if element.graphic != nil && layout == nil { continue }
        let local = layout?.frame ?? .init(x:element.frame.x,y:element.frame.y,width:element.frame.width,height:element.frame.height)
        let delta = bounds.origin.delta(to: .init(x: local.x, y: local.y))
        try await paintElement(element, boardID: boardID, frame: .init(x: frame.minX + delta.x * projection,
          y: frame.minY + delta.y * projection, width: local.width * projection,
          height: local.height * projection), canvas: canvas, graphicLayout:layout)
      }
      await Task.yield()
    } while cursor != nil
  }

  private func paintCover(_ item: RenderedWorkspaceItem, boardID: UUID, frame: CGRect, visible: CGRect,
    transitionViewport: SpatialPoint, passes: Int,
    canvas: SceneRasterCompositor) async throws {
    try checkPreparation()
    let size = CGSize(width: item.geometry.width, height: item.geometry.height)
    let projection = frame.width / size.width
    let padding = WorkspaceCoverRaster.shadowPadding
    let decoration = ZStack {
      WorkspaceItemShadow(geometry: item.geometry)
      WorkspaceItemDepthView(kind: item.item.kind, geometry: item.geometry)
    }.frame(width: size.width, height: size.height).padding(padding)
    try await canvas.drawView(decoration,
      size: .init(width: size.width + 2 * padding, height: size.height + 2 * padding),
      in: frame.insetBy(dx: -padding * projection, dy: -padding * projection))
    let shape = RoundedRectangle(cornerRadius: item.geometry.cornerRadius * projection, style: .continuous)
    try await canvas.pushClip(shape.path(in: frame).cgPath)
    if item.item.kind == .board {
      if WorkspaceSceneProjection.showsPortal(pixelScale: projection, remainingPasses: passes) {
        let camera = BoardPortalProjection.entryCamera(portalCamera: try await source.portalCamera(item.id),
          viewport: transitionViewport)
        let viewport = BoardPortalProjection.renderViewport(viewport: transitionViewport)
        try await paintBoard(presence: .init(boardID: item.id, mode: .board, camera: camera, viewport: viewport),
          frame: frame, visible: visible.intersection(frame), transitionViewport: transitionViewport,
          passes: passes - 1, canvas: canvas)
      } else {
        try await canvas.drawView(Color(red: 0.9, green: 0.93, blue: 0.925), size: size, in: frame)
      }
      try await canvas.drawView(RoundedRectangle(cornerRadius: item.geometry.cornerRadius, style: .continuous)
        .stroke(Color.black.opacity(0.16), lineWidth: 2), size: size, in: frame)
    } else {
      try await canvas.drawView(ZStack(alignment: .topLeading) {
        WorkspaceCoverSurface(item: item.item, geometry: item.geometry)
        WorkspaceCoverTitle(item: item.item, geometry: item.geometry)
      }, size: size, in: frame)
    }
    let visible = frame.intersection(visible)
    if !visible.isEmpty, !visible.isNull {
      let bounds = WorkspaceSpatialBounds(origin: .init(x: (visible.minX - frame.minX) / projection,
        y: (visible.minY - frame.minY) / projection), width: visible.width / projection, height: visible.height / projection)
      let contentFrame = CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: visible.height)
      try await paintCoverElements(itemID: item.id, boardID: boardID, bounds: bounds,
        frame: contentFrame, projection: projection, canvas: canvas)
      try await paintInk(.cover(item.id), camera: nil, size: size, frame: frame, canvas: canvas)
    }
    try await canvas.popClip()
  }

  private func paintElement(_ element: SpatialElement, boardID: UUID, frame: CGRect, canvas: SceneRasterCompositor,
    graphicLayout: NotebookGraphicLayout? = nil) async throws {
    try checkPreparation()
    let erasures = try await source.elementErasures(element)
    guard !erasures.contains(where: { $0.target.wholeElement }) else { return }
    let appearance = element.graphic != nil || element.kind == .nativeText
      ? try await source.elementAppearance(element, layout: graphicLayout) : nil
    try checkPreparation()
    if let graphic = element.graphic {
      if graphic.showsGeometry {
        let size = graphicLayout?.frame ?? .init(x:0,y:0,width:element.frame.width,height:element.frame.height)
        try await canvas.drawView(NotebookGraphicView(graphic: graphic,layout:graphicLayout, erasures: erasures, appearance: appearance),
          size: .init(width: size.width, height: size.height), in: frame)
      }
      return
    }
    if element.kind == .nativeText {
      try await canvas.drawView(SpatialTextSnapshot(element: element).erased(by: erasures, appearance: appearance),
        size: .init(width: element.frame.width, height: element.frame.height), in: frame)
      return
    }
    let source = agentElementSnapshotSource(element)
    // The destination defines the required samples, including a fractional LOD.
    // Quantizing upward keeps repeated nearby requests on one source density;
    // a coarse cache entry still cannot satisfy a larger exact export request.
    let density = max(frame.width / element.frame.width, frame.height / element.frame.height) * canvas.scale
    guard density.isFinite, density > 0 else { throw SceneRenderError.resourceLimit }
    let requiredScale = pow(2, ceil(log2(density)))
    if usesPreparedSources {
      let plane = element.surface.kind == .cover
        ? SceneCompositionPlane.cover(boardID: boardID, itemID: element.surface.ownerID!) : .board(boardID)
      let address = SceneSourceAddress(plane: plane, elementID: element.id)
      let desired = sourcePresentation.map { ($0.frame.pixelScales[boardID] ?? 1) * $0.displayScale } ?? density
      let demand = demand(for: element, plane: plane, density: desired)
      let discoversDemand = sourceDemands[address] != demand
      sourceDemands[address] = demand
      if let currentTile { tileSources[currentTile, default: []].insert(address) }
      // A painter pass consumes immutable, already admitted pixels. It never
      // awaits a neighbouring program, even when both overlap this same tile.
      let fallback = fallbackSources[address].flatMap { raster -> RasterLease? in
        guard let old = raster.source.agentElement, old.frame.width == source.frame.width,
          old.frame.height == source.frame.height else { return nil }
        return raster.retainedCopy()
      }
      let raster = sourceRasters[address]
        ?? resources.retainRaster(for: demand.rasterSource, minimumScale: demand.minimumScale)
        ?? fallback
      if let raster { sourceRasters[address] = raster }
      if discoversDemand { onSourceDemand?() }
      if let raster {
        let destination: CGRect
        if let crop = raster.source.captureRegion {
          destination = CGRect(x: frame.minX + crop.x / source.frame.width * frame.width,
            y: frame.minY + crop.y / source.frame.height * frame.height,
            width: crop.width / source.frame.width * frame.width, height: crop.height / source.frame.height * frame.height)
        } else { destination = frame }
        try await canvas.draw(raster, in: destination, erasures: erasures, elementFrame: frame)
      } else {
        let message = sourceFailures[address]?.matches(demand) == true ? "Не удалось загрузить" : "Подготовка…"
        try await canvas.drawView(ZStack {
          Color.secondary.opacity(0.07)
          Text(message).font(.system(size: 14)).foregroundStyle(.secondary)
        }, size: .init(width: element.frame.width, height: element.frame.height), in: frame)
      }
      return
    }
    let raster = try await prepareRaster(source, requestedScale: requiredScale)
    do { try await canvas.draw(raster, in: frame, erasures: erasures); raster.release() }
    catch { raster.release(); throw error }
    canvas.recordDiagnostics(resources.diagnostics(for: [source]))
  }

  /// Source values and their quantized WebKit extent are read once for this
  /// finite candidate set. Both admission and execution use this same request.
  struct LiveRasterRequest: Sendable {
    let owner: SceneCompositionLiveOwner
    let source: AgentElement
    let requestedScale: Double
    let demand: SceneSourceDemand
    let residentBytes: Int
    let snapshotAdditionalBytes: Int
    init(owner: SceneCompositionLiveOwner, element: SpatialElement, displayScale: Double, demand: SceneSourceDemand? = nil) throws {
      self.owner = owner; source = agentElementSnapshotSource(element)
      let demand = demand ?? .init(source: source, minimumScale: displayScale)
      self.demand = demand; requestedScale = demand.minimumScale
      guard let exact = demand.policy.pixelSize(for: source),
        exact.width < Double(Int.max - 2), exact.height < Double(Int.max - 2),
        let budget = SceneRenderResources.webSnapshotBudget(pixelSize: exact)
      else { throw SceneRenderError.resourceLimit }
      residentBytes = budget.resident; snapshotAdditionalBytes = max(0, budget.capture - budget.resident)
    }
  }

  func liveRasterRequests(plan: SceneCompositionPlan, frame: WorkspaceSceneFrame, displayScale: Double) async throws -> [LiveRasterRequest] {
    var requests: [LiveRasterRequest] = []
    for owner in plan.liveOwners {
      try checkPreparation()
      guard case .element(let id) = owner.id else { continue }
      guard let element = try await source.element(id, boardID: owner.plane.boardID),
        element.surface == (owner.plane.coverID.map(SurfaceID.cover) ?? .board(owner.plane.boardID)) else {
        throw SceneRenderError.snapshotPending("live_element_source")
      }
      if element.kind != .nativeText && element.kind != .graphic {
        guard let projection = frame.pixelScales[owner.plane.boardID] else {
          throw SceneRenderError.snapshotPending("live_element_projection")
        }
        let density = projection * displayScale
        requests.append(try .init(owner: owner, element: element, displayScale: density,
          demand: demand(for: element, plane: owner.plane, density: density)))
      }
    }
    return requests
  }

  /// Exclusion from static bands is not readiness. Cache hits already borrowed
  /// by the candidate keep their exact entry across every asynchronous step.
  func prepareLiveRasters(_ requests: [LiveRasterRequest],
    retained: [SceneCompositionLiveOwner: RasterLease]) async throws -> [SceneCompositionLiveOwner: RasterLease] {
    var rasters = retained
    do {
      for request in requests {
        try checkPreparation()
        if let hit = rasters[request.owner] {
          guard hit.image(for: request.demand.rasterSource, minimumScale: request.requestedScale) != nil else {
            throw SceneRenderError.snapshotPending("live_raster_lease")
          }
        } else {
          rasters[request.owner] = try await prepareRaster(request.source, requestedScale: request.requestedScale, region: request.demand.region)
        }
      }
      return rasters
    } catch {
      for raster in rasters.values { raster.release() }
      throw error
    }
  }

  private func prepareRaster(_ element: AgentElement, requestedScale: Double, region: PageRect? = nil) async throws -> RasterLease {
    try checkPreparation()
    let source: SceneRasterSource = region.map { .agentRegion(element, $0) } ?? .agent(element)
    if let cached = resources.retainRaster(for: source, minimumScale: requestedScale) { return cached }
    if webPreparation == nil {
      webPreparation = try await SceneWebRasterPreparation.create(resources: resources, permitsPreparation: permitsPreparation)
    }
    return try await webPreparation!.prepare(element, requestedScale: requestedScale, region: region, programStore: await self.source.programStore(), permitsPreparation: permitsPreparation)
  }

  func finishPreparation() { webPreparation?.close(); webPreparation = nil }
  func finishPreparationAndDrain() async throws {
    guard let preparation = webPreparation else { return }
    webPreparation = nil
    try await preparation.closeAndDrain()
  }
  isolated deinit { finishPreparation() }

  private func checkPreparation() throws {
    try Task.checkCancellation()
    guard permitsPreparation() else { throw CancellationError() }
  }
}

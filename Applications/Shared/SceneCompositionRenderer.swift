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
  private let index: WorkspaceSceneIndex
  private let hierarchy: BoardHierarchy
  private let journal: SpatialInkJournal
  private let resources: SceneRenderResources
  private let permitsPreparation: @MainActor () -> Bool

  init(index: WorkspaceSceneIndex, hierarchy: BoardHierarchy, journal: SpatialInkJournal,
    resources: SceneRenderResources = .shared,
    permitsPreparation: @escaping @MainActor () -> Bool = { true }) {
    self.index = index; self.hierarchy = hierarchy; self.journal = journal
    self.resources = resources; self.permitsPreparation = permitsPreparation
  }

  func render(presence: SessionPresence, scale: Double = 2, transitionViewport: SpatialPoint? = nil) async throws -> Result {
    try checkPreparation()
    guard index.board(id: presence.boardID) != nil else { throw SceneRenderError.snapshotPending("board_source") }
    let size = CGSize(width: presence.viewport.x, height: presence.viewport.y)
    let canvas = try await SceneRasterCompositor.create(size: size, scale: scale,
      resources: resources, permitsPreparation: permitsPreparation)
    let journal = journal
    let inkOwners = await Task.detached(priority: .utility) {
      Set(journal.actions.filter(\.isActive).flatMap { $0.spans.map(\.surface) })
    }.value
    try checkPreparation()
    let frame = CGRect(origin: .zero, size: size)
    try await paintBoard(presence: presence, frame: frame, visible: frame,
      transitionViewport: transitionViewport ?? presence.viewport, passes: WorkspaceSceneProjection.portalPasses,
      inkOwners: inkOwners, canvas: canvas)
    let png = try await canvas.finishPNG()
    return .init(png: png, diagnostics: canvas.diagnostics)
  }

  private func paintBoard(presence: SessionPresence, frame: CGRect, visible: CGRect,
    transitionViewport: SpatialPoint, passes: Int, inkOwners: Set<SurfaceID>,
    canvas: SceneRasterCompositor) async throws {
    try checkPreparation()
    let visible = visible.intersection(frame)
    guard !visible.isNull, !visible.isEmpty else { return }
    let projection = frame.width / presence.viewport.x
    let localVisible = CGRect(x: (visible.minX - frame.minX) / projection,
      y: (visible.minY - frame.minY) / projection,
      width: visible.width / projection, height: visible.height / projection)
    let origin = presence.camera.screenToWorld(.init(x: localVisible.minX, y: localVisible.minY),
      viewport: presence.viewport)
    let padding = WorkspaceCoverRaster.shadowPadding
    let bounds = WorkspaceSpatialBounds(origin: origin.offsetBy(x: -padding, y: -padding),
      width: localVisible.width / presence.camera.scale + 2 * padding,
      height: localVisible.height / presence.camera.scale + 2 * padding)
    try await canvas.drawView(SpatialBoardGrid(camera: presence.camera, outputScale: projection),
      size: .init(width: presence.viewport.x, height: presence.viewport.y), in: frame)

    // The scene's physical order is board elements, board ink, then covers.
    // Cover z-index never interleaves with the board's element-array order.
    for covers in [false, true] {
      if covers, inkOwners.contains(.board(presence.boardID)) {
        try await canvas.drawInk(surface: .board(presence.boardID), journal: journal, camera: presence.camera,
          size: .init(width: presence.viewport.x, height: presence.viewport.y), in: frame)
      }
      var cursor: WorkspaceSpatialReadCursor?
      repeat {
        try checkPreparation()
        guard let page = try index.readPaintOrder(boardID: presence.boardID, bounds: bounds, after: cursor)
        else { throw SceneRenderError.snapshotPending("board_source") }
        cursor = page.next
        for entry in page.entries {
          switch entry.id {
          case .element(let id) where !covers:
            guard let element = index.element(id: id, boardID: presence.boardID),
              let origin = element.worldOrigin else { continue }
            let screen = presence.camera.worldToScreen(origin.offsetBy(x: element.frame.x, y: element.frame.y),
              viewport: presence.viewport)
            let rect = CGRect(x: frame.minX + screen.x * projection, y: frame.minY + screen.y * projection,
              width: element.frame.width * presence.camera.scale * projection,
              height: element.frame.height * presence.camera.scale * projection)
            if rect.intersects(visible) { try await paintElement(element, frame: rect, canvas: canvas) }
          case .item(let id) where covers:
            guard let item = index.renderedItem(id: id, presence: presence) else { continue }
            let screen = presence.camera.worldToScreen(item.center, viewport: presence.viewport)
            let scale = presence.camera.scale * projection
            let rect = CGRect(x: frame.minX + screen.x * projection - item.geometry.width * scale / 2,
              y: frame.minY + screen.y * projection - item.geometry.height * scale / 2,
              width: item.geometry.width * scale, height: item.geometry.height * scale)
            if rect.insetBy(dx: -padding * scale, dy: -padding * scale).intersects(visible) {
              try await paintCover(item, boardID: presence.boardID, frame: rect, visible: visible,
                transitionViewport: transitionViewport, passes: passes, inkOwners: inkOwners, canvas: canvas)
            }
          default: break
          }
        }
        await Task.yield()
      } while cursor != nil
    }
  }

  private func paintCover(_ item: RenderedWorkspaceItem, boardID: UUID, frame: CGRect, visible: CGRect,
    transitionViewport: SpatialPoint, passes: Int, inkOwners: Set<SurfaceID>,
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
        let camera = BoardPortalProjection.entryCamera(portalCamera: hierarchy.portalCamera(item.id) ?? .init(),
          viewport: transitionViewport)
        let viewport = BoardPortalProjection.renderViewport(viewport: transitionViewport)
        try await paintBoard(presence: .init(boardID: item.id, mode: .board, camera: camera, viewport: viewport),
          frame: frame, visible: visible.intersection(frame), transitionViewport: transitionViewport,
          passes: passes - 1, inkOwners: inkOwners, canvas: canvas)
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
      var cursor: WorkspaceSpatialReadCursor?
      repeat {
        try checkPreparation()
        let page = try index.readPaintOrder(boardID: boardID, coverID: item.id, bounds: bounds, after: cursor)
        cursor = page?.next
        for entry in page?.entries ?? [] {
          guard case .element(let id) = entry.id, let element = index.element(id: id, boardID: boardID) else { continue }
          try await paintElement(element, frame: .init(x: frame.minX + element.frame.x * projection,
            y: frame.minY + element.frame.y * projection,
            width: element.frame.width * projection, height: element.frame.height * projection), canvas: canvas)
        }
        await Task.yield()
      } while cursor != nil
      if inkOwners.contains(.cover(item.id)) {
        try await canvas.drawInk(surface: .cover(item.id), journal: journal, camera: nil, size: size, in: frame)
      }
    }
    try await canvas.popClip()
  }

  private func paintElement(_ element: SpatialElement, frame: CGRect, canvas: SceneRasterCompositor) async throws {
    try checkPreparation()
    if element.kind == .nativeText {
      try await canvas.drawView(SpatialTextSnapshot(element: element),
        size: .init(width: element.frame.width, height: element.frame.height), in: frame)
      return
    }
    let source = agentElementSnapshotSource(element)
    let raster = try await resources.prepareRaster(source, permitsPreparation: permitsPreparation)
    do { try await canvas.draw(raster, in: frame); raster.release() }
    catch { raster.release(); throw error }
    canvas.recordDiagnostics(resources.diagnostics(for: [source]))
  }

  private func checkPreparation() throws {
    try Task.checkCancellation()
    guard permitsPreparation() else { throw CancellationError() }
  }
}

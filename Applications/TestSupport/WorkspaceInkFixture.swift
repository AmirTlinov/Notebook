#if os(iOS)
import NotebookCore
import SwiftUI
import UIKit
import XCTest
@testable import Notebook

/// A completed composition and its actual native input owners. Input tests use
/// the same cohort, raster leases, pose registrations and installed ink receipts
/// as the scene, rather than a permissive coordinator-only geometry shortcut.
@MainActor
final class WorkspaceInkFixture {
  let cohort: SceneCompositionCohort
  let presence: SessionPresence
  let registry: SpatialInkSurfaceRegistry
  let gate: NotebookInputGate
  let canvas: SpatialInkContainerView
  private(set) var poses: [UUID: WorkspaceItemPoseController] = [:]
  private(set) var inks: [UUID: InkCanvasView] = [:]
  private(set) var lifted: [UUID: Bool] = [:]
  private(set) var engaged: [UUID] = []
  private var interactions: [UUID: NotebookInteractionTouchView] = [:]
  var onLift: ((UUID, Bool) -> Void)?
  var onDrop: ((UUID, WorldPoint) -> WorkspaceItemPoseDestination?)?

  var surfaces: [SpatialWorkspaceItemSurface] {
    cohort.frame.workset(boardID: presence.boardID).items.map {
      .init(itemID: $0.id, geometry: $0.geometry, center: $0.center, zIndex: $0.zIndex)
    }
  }

  static func prepare(boardID: UUID, camera: SpatialCamera, viewport: SpatialPoint,
    items: [SpatialWorkspaceItemSurface], journal: SpatialInkJournal? = nil,
    registry: SpatialInkSurfaceRegistry = .init(),
    resources: SceneRenderResources = .init()) async throws -> SceneCompositionCohort {
    let stamp = journal?.stamp ?? VersionStamp(counter: 0, actor: UUID())
    // An empty visible board still belongs to a valid nonempty workspace.
    let placements = items.isEmpty
      ? [FreeItemPlacement(itemID: UUID(), center: .init(x: 1_000_000, y: 1_000_000), zIndex: 0, stamp: stamp)]
      : items.map { FreeItemPlacement(itemID: $0.itemID, center: $0.center, zIndex: Int($0.zIndex), stamp: stamp) }
    let values = placements.map { WorkspaceItem.notebook(id: $0.itemID, title: "Physical input", pageIDs: [UUID()]) }
    let workspace = WorkspaceIndex(items: values, selectedItemID: values[0].id,
      selectedPageID: values[0].pageIDs[0], stamp: stamp, rootBoardID: boardID)
    let hierarchy = BoardHierarchy(rootBoardID: boardID,
      boards: [.init(id: boardID, board: .init(freeItems: placements, stamp: stamp))], stamp: stamp)
    let index = WorkspaceSceneIndex(workspace: workspace, hierarchy: hierarchy, paperSizes: [:])
    let presence = SessionPresence(boardID: boardID, mode: .board, camera: camera, viewport: viewport)
    let frame = WorkspaceSceneFrame(index: index, presence: presence, portalCamera: { _ in nil })
    let source = SceneCompositionSource(index: index, hierarchy: hierarchy,
      journal: journal ?? .init(stamp: stamp))
    let tiles = SceneCompositionTiles(resources: resources, surfaceRegistry: registry)
    tiles.prepare(source: source, presence: presence, frame: frame,
      pinned: Set(items.map { .item($0.itemID) }), displayScale: 1)
    let deadline = ContinuousClock.now + .seconds(5)
    while tiles.published == nil, tiles.failure == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    let cohort = try XCTUnwrap(tiles.published, tiles.failure ?? "A real complete composition did not publish")
    XCTAssertTrue(cohort.plan.tiles.allSatisfy { cohort.rasters[$0]?.isReleased == false })
    return cohort
  }

  init(cohort: SceneCompositionCohort, presence: SessionPresence,
    canvas: SpatialInkContainerView, parent: UIViewController,
    registry: SpatialInkSurfaceRegistry, gate: NotebookInputGate,
    journal: SpatialInkJournal? = nil) throws {
    self.cohort = cohort; self.presence = presence; self.canvas = canvas
    self.registry = registry; self.gate = gate
    XCTAssertTrue(registry === cohort.nativeInk.registry)
    canvas.update(lease: cohort.nativeInk, surface: .board(presence.boardID), boardID: presence.boardID,
      camera: presence.camera, active: true)
    for item in cohort.frame.workset(boardID: presence.boardID).items
      where cohort.plan.allowsLive(.item(item.id), in: .board(presence.boardID)) {
      let pose = WorkspaceItemPoseController()
      let body = try XCTUnwrap(cohort.nativeInk.owners[.cover(item.id)]?.canvas)
      parent.addChild(pose); parent.view.addSubview(pose.view)
      pose.view.frame = canvas.frame; pose.didMove(toParent: parent)
      poses[item.id] = pose; inks[item.id] = body
      publish(item.id)
      pose.view.layoutIfNeeded(); pose.contentView.layoutIfNeeded()
      XCTAssertTrue(body.isDescendant(of: pose.contentView))
    }
  }

  func publish(_ id: UUID, rendered: RenderedWorkspaceItem? = nil,
    sourceBoard: BoardDocument? = nil, cohortID: UUID? = nil, rankOverride: Double? = nil) {
    guard let pose = poses[id], inks[id] != nil, let item = rendered
      ?? cohort.frame.workset(boardID: presence.boardID).items.first(where: { $0.id == id }) else { return }
    pose.update(rendered: item, camera: presence.camera, viewport: presence.viewport,
      boardID: presence.boardID, cohortID: cohortID ?? cohort.id, cohortRevision: cohort.plan.revision,
      sourceBoard: sourceBoard ?? cohort.frame.index.board(id: presence.boardID),
      publishedLiftRank: rankOverride ?? engaged.firstIndex(of: id).map { 9_000 + Double($0) }, projection: nil, registry: registry, inputGate: gate,
      onLiftChanged: { [weak self] value in
        guard let self else { return }
        lifted[id] = value; engaged.removeAll { $0 == id }
        if value { engaged.append(id) }
        onLift?(id, value)
      },
      onDrop: { [weak self] point in self?.onDrop?(id, point) },
      content: AnyView(ZStack {
        Color.white
        SpatialInkSurfaceView(surface: .cover(id), cohort: cohort, boardID: presence.boardID, isActive: true)
        if let interaction = interactions[id] { WorkspaceFixtureInteraction(view: interaction) }
      }
        .frame(width: item.geometry.width, height: item.geometry.height)))
  }

  func installInteraction(_ interaction: NotebookInteractionTouchView, on id: UUID) {
    interactions[id] = interaction
    publish(id)
    poses[id]?.contentView.layoutIfNeeded()
  }

  func close() {
    for pose in poses.values {
      pose.uninstall()
      pose.willMove(toParent: nil); pose.view.removeFromSuperview(); pose.removeFromParent()
    }
    poses.removeAll(); inks.removeAll(); interactions.removeAll()
    canvas.unmount()
  }
}

private struct WorkspaceFixtureInteraction: UIViewRepresentable {
  let view: NotebookInteractionTouchView
  func makeUIView(context: Context) -> NotebookInteractionTouchView { view }
  func updateUIView(_ uiView: NotebookInteractionTouchView, context: Context) {}
}
#endif

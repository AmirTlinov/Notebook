import CoreGraphics
import CryptoKit
import Foundation
import NotebookCore
import Observation
import SwiftUI

/// A failed program belongs to its source; a failed capture belongs to the
/// submitted crop and density. Physical placement does not create new pixels.
struct SceneSourceFailure {
  let demand: SceneSourceDemand
  let message: String
  let captureSpecific: Bool
  func matches(_ current: SceneSourceDemand) -> Bool {
    SceneRasterSource.agent(demand.source) == .agent(current.source)
      && (!captureSpecific || demand.policy == current.policy)
  }
}

enum SceneCompositionPlane: Hashable, Codable, Sendable {
  case board(UUID)
  case cover(boardID: UUID, itemID: UUID)
  var boardID: UUID { switch self { case .board(let id), .cover(let id, _): id } }
  var coverID: UUID? { if case .cover(_, let id) = self { return id }; return nil }

  /// Input demand precedes optional paint detail. The planner and the mounted
  /// runtime use the same visibility rule; a label cannot evict a live button.
  func demandsRuntime(source: AgentElement, origin: WorldPoint?, transform:CGAffineTransform, in presence: SessionPresence) -> Bool {
    guard boardID == presence.boardID, presence.mode != .page, presence.mode != .document,
      source.requiresLiveRuntime else { return false }
    if let coverID { return coverID == presence.focusedItemID }
    guard let origin else { return false }
    let visible = SceneSourceCapture.visibleRect(source: source, origin: origin, transform:transform, presence: presence)
    return !visible.isNull && !visible.isEmpty
  }
}

struct SceneCompositionTileKey: Hashable, Codable, Sendable {
  let workspaceID: UUID
  let revision: UInt64
  let contentRevision: String?
  let plane: SceneCompositionPlane
  let tile: CompositionTile
  let range: ScenePaintRange
  let presentationScale: Double
  let viewportWidth: Double
  let viewportHeight: Double
  let focusedItemID: UUID?
  let mode: String
  let pixelSize: Int
  init(workspaceID: UUID, revision: UInt64, plane: SceneCompositionPlane, tile: CompositionTile,
    range: ScenePaintRange, presentationScale: Double, viewportWidth: Double, viewportHeight: Double,
    focusedItemID: UUID?, mode: String, pixelSize: Int = CompositionTile.pixelSize, contentRevision: String? = nil) {
    self.workspaceID = workspaceID; self.revision = revision; self.contentRevision = contentRevision
    self.plane = plane; self.tile = tile; self.range = range
    // Only cover/portal painting uses the external camera to choose its content.
    // World-space elements and ink are rasterized in the tile's own basis.
    self.presentationScale = range.layer == .covers ? presentationScale : 1
    self.viewportWidth = range.layer == .covers ? viewportWidth : 0
    self.viewportHeight = range.layer == .covers ? viewportHeight : 0
    self.focusedItemID = range.layer == .covers ? focusedItemID : nil
    self.mode = range.layer == .covers ? mode : ""; self.pixelSize = pixelSize
  }
  func atRevision(_ revision: UInt64) -> Self {
    .init(workspaceID: workspaceID, revision: revision, plane: plane, tile: tile, range: range,
      presentationScale: presentationScale, viewportWidth: viewportWidth, viewportHeight: viewportHeight,
      focusedItemID: focusedItemID, mode: mode, pixelSize: pixelSize, contentRevision: contentRevision)
  }
  func withContentRevision(_ content: String?) -> Self {
    .init(workspaceID: workspaceID, revision: revision, plane: plane, tile: tile, range: range,
      presentationScale: presentationScale, viewportWidth: viewportWidth, viewportHeight: viewportHeight,
      focusedItemID: focusedItemID, mode: mode, pixelSize: pixelSize, contentRevision: content)
  }
  /// SQL revision remains the read fence. Only the existing bounded pixel pool
  /// indexes by completed physical content; no retained-cohort cache is needed.
  var pixelIdentity: Self { contentRevision == nil ? self : atRevision(0) }
  func hasSamePaintWindow(as other: Self) -> Bool {
    withContentRevision(nil).atRevision(0) == other.withContentRevision(nil).atRevision(0)
  }
}

struct SceneCompositionLiveOwner: Hashable, Sendable {
  let plane: SceneCompositionPlane
  let id: WorkspaceSpatialID
  let position: ScenePaintPosition
}

/// One contiguous native painter run, not one retained UIKit/WebKit host per
/// figure. Adjacency is proved by the source's order index, never by the window.
struct SceneCompositionVectorRun: Identifiable, Equatable, Sendable {
  let plane: SceneCompositionPlane
  var owners: [SceneCompositionLiveOwner]
  var id: SceneCompositionLiveOwner { owners[0] }

  /// A passive connection cannot keep an independently movable endpoint: its
  /// baked pixels would no longer follow the node. Demotion therefore closes
  /// over endpoint runs, not over every connected edge in the diagram. A live
  /// connection may still point to a passive (non-manipulable) node.
  static func demotionClosure(of owner: SceneCompositionLiveOwner, in runs: [Self],
    frame: WorkspaceSceneFrame, protected: Set<SceneCompositionLiveOwner>) -> Set<SceneCompositionLiveOwner>? {
    struct Address: Hashable {
      let plane: SceneCompositionPlane
      let id: String
      init(plane: SceneCompositionPlane, id: String) {
        self.plane = plane; self.id = UUID(uuidString: id)?.uuidString.lowercased() ?? id
      }
    }
    var membership: [Address: Int] = [:]
    for (index, run) in runs.enumerated() {
      for owner in run.owners {
        if case .element(let id) = owner.id { membership[.init(plane: owner.plane, id: id)] = index }
      }
    }
    guard case .element(let id) = owner.id,
      let first = membership[.init(plane: owner.plane, id: id)] else { return nil }
    var pending = [first], visited = Set<Int>(), result = Set<SceneCompositionLiveOwner>()
    while let index = pending.popLast() {
      guard visited.insert(index).inserted else { continue }
      let run = runs[index]
      guard protected.isDisjoint(with: run.owners) else { return nil }
      result.formUnion(run.owners)
      for owner in run.owners {
        guard case .element(let id) = owner.id else { continue }
        for binding in frame.index.element(id: id, boardID: owner.plane.boardID)?.graphic?.connection?.bindings ?? [] {
          if let endpointRun = membership[.init(plane: owner.plane, id: binding.elementID)], !visited.contains(endpointRun) {
            pending.append(endpointRun)
          }
        }
      }
    }
    return result
  }
}

struct SceneCompositionBand: Identifiable, Sendable {
  let plane: SceneCompositionPlane
  let range: ScenePaintRange
  let rank: Int
  var id: SelfID { .init(plane: plane, range: range) }
  struct SelfID: Hashable { let plane: SceneCompositionPlane; let range: ScenePaintRange }
}

/// Static ranges and source owners are finite. The byte planner separately
/// accounts for the shown cohort and exact candidate rasters; a tile-count
/// bound alone is not a claim that both sets fit the shared pool.
struct SceneCompositionPlan: Sendable {
  static let maximumNativeOwners = 8
  static let maximumLiveOwners = maximumNativeOwners + SceneRenderResources.maximumVisiblePrograms
  static let maximumTiles = 32
  static let maximumPrimitives = 96
  let revision: UInt64
  let workspaceID: UUID
  let rootBoardID: UUID
  let inkBoardIDs: Set<UUID>
  let liveOwners: [SceneCompositionLiveOwner]
  let protectedOwners: Set<SceneCompositionLiveOwner>
  let bands: [SceneCompositionBand]
  let coverage: [SceneCompositionPlane: CompositionTileCoverage]
  let presentations: [SceneCompositionPlane: SessionPresence]
  let tiles: [SceneCompositionTileKey]
  var requiredPixelDensity: [SceneCompositionPlane: Double] = [:]
  var vectorRuns: [SceneCompositionVectorRun] = []
  var groupPoses:[SceneCompositionPlane:[String:NotebookElementPlacement.Source]] = [:]
  var presentedOwners: [SceneCompositionLiveOwner] { liveOwners + vectorRuns.flatMap(\.owners) }
  var primitiveCount: Int { tiles.count + liveOwners.count + vectorRuns.count + inkBoardIDs.count }
  /// Every resource retry removes an optional owner or a static tile. Keeping
  /// this integer strictly decreasing bounds preparation without a timer retry.
  private var coverageTileCount: Int {
    tiles.count
  }
  var reductionPotential: Int {
    let optional = liveOwners.filter { !protectedOwners.contains($0) }.count
      + vectorRuns.filter { protectedOwners.isDisjoint(with: $0.owners) }.count
    return optional * (Self.maximumTiles + 1) + coverageTileCount
  }
  var nativeOwnerCount: Int {
    inkBoardIDs.count + liveOwners.filter { if case .item = $0.id { return true }; return false }.count
  }
  var inkSurfaces: [SurfaceID] {
    let items = Set(liveOwners.compactMap { owner -> UUID? in
      if case .item(let id) = owner.id { return id }; return nil
    })
    return inkBoardIDs.sorted().map(SurfaceID.board) + items.sorted().map(SurfaceID.cover)
  }

  private struct PaintSpan {
    let lower: ScenePaintPosition
    let upper: ScenePaintPosition
    let ids: Set<WorkspaceSpatialID>
  }
  private static func paintSpans(owners: [SceneCompositionLiveOwner], vectors: [SceneCompositionVectorRun],
    plane: SceneCompositionPlane, layer: ScenePaintPosition.Layer) -> [PaintSpan] {
    let singles = owners.filter { $0.plane == plane && $0.position.layer == layer }.map {
      PaintSpan(lower: $0.position, upper: $0.position, ids: [$0.id])
    }
    let batches = vectors.filter { $0.plane == plane && $0.owners.first?.position.layer == layer }.map {
      PaintSpan(lower: $0.owners.first!.position, upper: $0.owners.last!.position, ids: Set($0.owners.map(\.id)))
    }
    return (singles + batches).sorted { $0.lower < $1.lower }
  }
  func rank(id: WorkspaceSpatialID, in plane: SceneCompositionPlane) -> Double? {
    guard let owner = presentedOwners.first(where: { $0.id == id && $0.plane == plane }) else { return nil }
    return Self.paintSpans(owners: liveOwners, vectors: vectorRuns, plane: plane, layer: owner.position.layer)
      .firstIndex { $0.ids.contains(id) }.map { Double($0 * 2 + 1) }
  }
  func allowsLive(_ id: WorkspaceSpatialID, in plane: SceneCompositionPlane) -> Bool {
    // Membership does not need painter ranks, span allocation or sorting.
    liveOwners.contains { $0.id == id && $0.plane == plane }
      || vectorRuns.contains { run in run.owners.contains { $0.id == id && $0.plane == plane } }
  }

  /// Coverage and painter boundaries remain intact even where this exact
  /// source revision proves transparent pixels need no backing allocation.
  func removingEmptyTiles(source: SceneCompositionSource) async throws -> Self {
    guard source.revision == revision, source.workspaceID == workspaceID,source.groupPoses == groupPoses else {
      throw NotebookStorageError.transactionConflict
    }
    let populated = try await source.tilesRequiringPaint(tiles)
    return .init(revision: revision, workspaceID: workspaceID, rootBoardID: rootBoardID,
      inkBoardIDs: inkBoardIDs, liveOwners: liveOwners, protectedOwners: protectedOwners,
      bands: bands, coverage: coverage, presentations: presentations, tiles: populated,
      requiredPixelDensity: requiredPixelDensity, vectorRuns: vectorRuns,groupPoses:groupPoses)
  }

  /// Empty painter ranges and cells preserve order and coverage without a
  /// backing allocation. Count the occupied fine cells before assigning the
  /// physical quota: dividing a viewport by its painter bands first creates
  /// enormous mostly transparent images, even for one small visible source.
  func allocatingPopulatedCoverage(source: SceneCompositionSource, presence: SessionPresence,
    frame: WorkspaceSceneFrame, displayScale: Double, previous: Self?) async throws -> Self {
    let sparse = try await removingEmptyTiles(source: source)
    let occupied = Set(sparse.tiles.map { SceneCompositionBand.SelfID(plane: $0.plane, range: $0.range) })
    let planes = presentations.keys.sorted { a, b in
      if (a == .board(rootBoardID)) != (b == .board(rootBoardID)) { return a == .board(rootBoardID) }
      return String(describing: a) < String(describing: b)
    }
    var bounds: [SceneCompositionPlane: WorkspaceSpatialBounds] = [:]
    for plane in planes {
      guard let view = presentations[plane] else { throw SceneRenderError.resourceLimit }
      let area: WorkspaceSpatialBounds
      if let itemID = plane.coverID,
        let item = frame.worksets[plane.boardID]?.items.first(where: { $0.id == itemID }) {
        area = .init(origin: .zero, width: item.geometry.width, height: item.geometry.height)
      } else {
        area = NotebookSceneState.bounds(for: view, margin: WorkspaceSceneIndex.preparationMargin(for: view))
      }
      bounds[plane] = area
    }
    var coverage = sparse.coverage
    var allocated: [SceneCompositionPlane: [SceneCompositionTileKey]] = [:]
    // This is a finite metadata probe, not an image allocation. Each plane
    // has at most 256 cells and the source reads at most 64 indexed entries
    // per cell, shared by all painter bands on that cell.
    func probe(_ plane: SceneCompositionPlane, gridDensity: Double, previousLevel: Int? = nil) async throws {
      let populated = bands.filter { $0.plane == plane && occupied.contains($0.id) }
      guard !populated.isEmpty else { return }
      guard let area = bounds[plane], let view = presentations[plane] else { throw SceneRenderError.resourceLimit }
      let pixels = (frame.pixelScales[plane.boardID] ?? view.camera.scale) * displayScale
      let prepared = try CompositionTileCoverage(bounds: area, pixelsPerWorldPoint: gridDensity, previousLevel: previousLevel, maximumTiles: 256)
      coverage[plane] = prepared
      var candidates: [SceneCompositionTileKey] = []
      for band in populated {
        for tile in prepared.tiles {
          let required = min(2048, max(Double(CompositionTile.pixelSize), tile.worldSize * pixels))
          let quantized = Int(pow(2, ceil(log2(required))))
          // Do not alternate 512/1024 at a density boundary of a retained LOD.
          let retained = previous?.tiles.first { $0.plane == plane && $0.tile.level == tile.level }?.pixelSize ?? 0
          let pixelSize = max(quantized, retained)
          candidates.append(.init(workspaceID: workspaceID, revision: revision, plane: plane, tile: tile,
            range: band.range, presentationScale: view.camera.scale,
            viewportWidth: view.viewport.x, viewportHeight: view.viewport.y,
            focusedItemID: view.focusedItemID, mode: view.mode.rawValue, pixelSize: pixelSize))
        }
      }
      allocated[plane] = try await source.tilesRequiringPaint(candidates)
    }
    for plane in planes {
      guard let view = presentations[plane] else { throw SceneRenderError.resourceLimit }
      try await probe(plane, gridDensity: (frame.pixelScales[plane.boardID] ?? view.camera.scale) * displayScale,
        previousLevel: previous?.coverage[plane]?.level)
    }
    // Only an actually overfull set coarsens. Each step advances one finite
    // grid level; re-probe that plane because a new cell can straddle a band.
    while allocated.values.reduce(0, { $0 + $1.count }) > Self.maximumTiles {
      guard let plane = planes.filter({
        !(allocated[$0] ?? []).isEmpty && (coverage[$0]?.level ?? CompositionTile.levels.upperBound) < CompositionTile.levels.upperBound
      }).max(by: { (allocated[$0]?.count ?? 0) < (allocated[$1]?.count ?? 0) }),
        let current = coverage[plane], let tile = current.tiles.first else { throw SceneRenderError.resourceLimit }
      try await probe(plane, gridDensity: Double(CompositionTile.pixelSize) / (tile.worldSize * 2))
      guard (coverage[plane]?.level ?? current.level) > current.level else { throw SceneRenderError.resourceLimit }
    }
    let tiles = planes.flatMap { allocated[$0] ?? [] }
    let result = Self(revision: revision, workspaceID: workspaceID, rootBoardID: rootBoardID,
      inkBoardIDs: inkBoardIDs, liveOwners: liveOwners, protectedOwners: protectedOwners,
      bands: bands, coverage: coverage, presentations: presentations, tiles: tiles,
      requiredPixelDensity: requiredPixelDensity, vectorRuns: vectorRuns,groupPoses:groupPoses)
    guard result.primitiveCount <= Self.maximumPrimitives else { throw SceneRenderError.resourceLimit }
    return result
  }

  var meetsRequiredDensity: Bool {
    tiles.allSatisfy { key in
      Double(key.pixelSize) / key.tile.worldSize + 0.000_001
        >= (requiredPixelDensity[key.plane] ?? 0)
    }
  }

  static func prepare(source: SceneCompositionSource, presence: SessionPresence, frame: WorkspaceSceneFrame,
    pinned: Set<WorkspaceSpatialID>, displayScale: Double, previous: Self?) async throws -> Self {
    var pinned = pinned
    if let id = presence.focusedItemID { pinned.insert(.item(id)) }
    guard displayScale.isFinite, displayScale > 0, frame.rootBoardID == presence.boardID else { throw SceneRenderError.resourceLimit }
    var candidates: [(plane: SceneCompositionPlane, id: WorkspaceSpatialID, pinned: Bool, runtime: Bool, program: Bool, visiblePaper: Bool, paper: Bool)] = []
    let boardIDs = [presence.boardID] + frame.worksets.keys.filter { $0 != presence.boardID }.sorted { $0.uuidString < $1.uuidString }
    for boardID in boardIDs {
      guard let workset = frame.worksets[boardID] else { continue }
      for item in workset.items {
        // A live portal must already own its child's physical plane. Otherwise
        // the streaming painter renders the whole portal, never a placeholder.
        guard item.item.kind != .board || frame.presences[item.id] != nil else { continue }
        let rect = item.geometry.screenFrame(center: item.center, camera: presence.camera, viewport: presence.viewport)
        let visiblePaper = boardID == presence.boardID && item.item.kind != .board
          && rect.x < presence.viewport.x && rect.y < presence.viewport.y
          && rect.x + rect.width > 0 && rect.y + rect.height > 0
        candidates.append((.board(boardID), .item(item.id), pinned.contains(.item(item.id)), false, false, visiblePaper, item.item.kind != .board))
      }
      let erased = try await source.wholeErasedElements(workset.elements)
      for element in workset.elements {
        if erased.contains(element.id) {
          pinned.remove(.element(element.id)); continue
        }
        let plane = SceneCompositionPlane.board(boardID)
        let placement = element.kind == .web ? try await source.elementPlacement(element,boardID:boardID) : nil
        let program = element.kind == .web && agentElementSnapshotSource(element).requiresLiveRuntime
        let runtime = placement.map { plane.demandsRuntime(source:agentElementSnapshotSource(element),
          origin:SceneSourceCapture.origin(placement:$0,plane:plane,frame:frame),transform:SceneSourceCapture.linear($0),in:presence) } ?? false
        candidates.append((plane, .element(element.id), pinned.contains(.element(element.id)), runtime, program, false, false))
      }
    }
    // A pin on cover contents pins its physical carrier, then its local element.
    for (itemID, workset) in frame.covers {
      guard let boardID = frame.worksets.first(where: { $0.value.items.contains(where: { $0.id == itemID }) })?.key else { continue }
      let erased = try await source.wholeErasedElements(workset.elements)
      for element in workset.elements where element.graphic != nil || pinned.contains(.element(element.id)) {
        if erased.contains(element.id) {
          pinned.remove(.element(element.id)); continue
        }
        let isPinned = pinned.contains(.element(element.id))
        candidates.append((.cover(boardID: boardID, itemID: itemID), .element(element.id), isPinned, false,
          element.kind == .web && agentElementSnapshotSource(element).requiresLiveRuntime, false, false))
        if isPinned, let index = candidates.firstIndex(where: { $0.id == .item(itemID) }) { candidates[index].pinned = true }
      }
    }
    guard pinned.allSatisfy({ pin in candidates.contains { $0.id == pin } }) else { throw SceneRenderError.snapshotPending("pinned_owner_source") }
    candidates.sort { left, right in
      if left.pinned != right.pinned { return left.pinned }
      if left.runtime != right.runtime { return left.runtime }
      // A visible physical paper projects its ready material and native ink as
      // one object. Do not flatten it into viewport tiles just to keep a static
      // label/SVG live: zoom would then expose only the old partial tile window.
      if left.visiblePaper != right.visiblePaper { return left.visiblePaper }
      // The next paper already inside the bounded preparation window needs
      // the same physical owner. Flattening it behind optional offscreen labels
      // made one 500-ms cover-tile pass block every newly visible source.
      if left.paper != right.paper { return left.paper }
      if (left.plane.boardID == presence.boardID) != (right.plane.boardID == presence.boardID) { return left.plane.boardID == presence.boardID }
      return String(describing: left.id) < String(describing: right.id)
    }
    func isVector(_ id: WorkspaceSpatialID, boardID: UUID) -> Bool {
      guard case .element(let id) = id else { return false }
      return frame.index.element(id: id, boardID: boardID)?.graphic != nil
    }
    let physical = candidates.filter { !isVector($0.id, boardID: $0.plane.boardID) }
    let vectors = candidates.filter { isVector($0.id, boardID: $0.plane.boardID) }
    // A small program is not a full-screen ink canvas. Keep the paper/native
    // workset bounded independently, rather than silently baking visible
    // controls into screenshots after the seventh element.
    // Prefetched programs belong to the same bounded program pool before and
    // after crossing the viewport. Their visibility controls runtime mounting,
    // not whether they evict the paper/SVG owners into expensive raster tiles.
    let programs = physical.filter(\.program), ordinary = physical.filter { !$0.program }
    guard ordinary.filter(\.pinned).count < maximumNativeOwners,
      programs.filter(\.pinned).count <= SceneRenderResources.maximumVisiblePrograms
    else { throw SceneRenderError.snapshotPending("live_owner_budget") }
    let admitted = Array(programs.prefix(SceneRenderResources.maximumVisiblePrograms))
      + Array(ordinary.prefix(maximumNativeOwners - 1))
    let positioned = try await source.positionedOwners((admitted + vectors)
      .map { (plane: $0.plane, id: $0.id) })
    var owners = positioned.filter { !isVector($0.id, boardID: $0.plane.boardID) }
    let native = positioned.filter { isVector($0.id, boardID: $0.plane.boardID) }
    var vectorRuns = try await source.vectorRuns(native)
    let protected = Set(positioned.filter { owner in
      candidates.contains { $0.pinned && $0.id == owner.id && $0.plane == owner.plane }
    })
    while true {
      do {
        let assembled = try assemble(revision: source.revision, workspaceID: source.workspaceID, owners: owners, presence: presence,
          frame: frame, pinned: pinned, protected: protected, displayScale: displayScale, previous: previous, vectorRuns: vectorRuns,groupPoses:source.groupPoses)
        return try await assembled.allocatingPopulatedCoverage(source: source, presence: presence,
          frame: frame, displayScale: displayScale, previous: previous)
      } catch {
        // Fragmented native runs can require too many intervening raster
        // bands. Flatten an optional run, never lose its source or evict a
        // program merely to retain more optional vector detail.
        if let demoted = vectorRuns.reversed().lazy.compactMap({ run in
          SceneCompositionVectorRun.demotionClosure(of: run.id, in: vectorRuns, frame: frame, protected: protected)
        }).first {
          vectorRuns.removeAll { !demoted.isDisjoint(with: $0.owners) }
        } else if let index = owners.lastIndex(where: { !protected.contains($0) }) {
          owners.remove(at: index)
        } else { throw error }
      }
    }
  }

  /// Removing an optional host or native run puts its exact painter positions
  /// back into a static range. Mandatory pins and their visible carriers
  /// survive every reassembly; source values are never discarded as a shortcut.
  func demoting(_ owner: SceneCompositionLiveOwner, presence: SessionPresence,
    frame: WorkspaceSceneFrame, displayScale: Double) throws -> Self? {
    guard !protectedOwners.contains(owner) else { return nil }
    var owners = liveOwners, vectors = vectorRuns
    if let index = owners.firstIndex(of: owner) { owners.remove(at: index) }
    else if let demoted = SceneCompositionVectorRun.demotionClosure(of: owner, in: vectors,
      frame: frame, protected: protectedOwners) { vectors.removeAll { !demoted.isDisjoint(with: $0.owners) } }
    else { return nil }
    do {
      let result = try Self.assemble(revision: revision, workspaceID: workspaceID,
        owners: owners, presence: presence, frame: frame,
        pinned: Set(protectedOwners.map(\.id)), protected: protectedOwners,
        displayScale: displayScale, previous: self, vectorRuns: vectors,groupPoses:groupPoses, preservesCoverageDensity: true)
      guard result.reductionPotential < reductionPotential else { return nil }
      guard result.tiles.count <= Self.maximumTiles, result.primitiveCount <= Self.maximumPrimitives else { return nil }
      return result
    } catch SceneRenderError.resourceLimit { return nil }
    catch SceneRenderError.snapshotPending { return nil }
    catch { throw error }
  }

  /// Overview quality may become coarser under pressure, but its complete
  /// spatial bounds and every painter range remain present. Native ink and
  /// pinned source rasters keep their own density; exact export is independent.
  func coarseningCoverage(presence: SessionPresence, frame: WorkspaceSceneFrame,
    displayScale: Double) throws -> Self? {
    guard !tiles.isEmpty, coverageTileCount > 1 else { return nil }
    do {
      let result = try Self.assemble(revision: revision, workspaceID: workspaceID,
        owners: liveOwners, presence: presence, frame: frame,
        pinned: Set(protectedOwners.map(\.id)), protected: protectedOwners,
        displayScale: displayScale, previous: self, vectorRuns: vectorRuns,groupPoses:groupPoses, preservesCoverageDensity: true,
        tileAllowance: coverageTileCount - 1)
      guard result.coverageTileCount < coverageTileCount, result.liveOwners == liveOwners,
        result.protectedOwners == protectedOwners else { return nil }
      return result
    } catch SceneRenderError.resourceLimit { return nil }
    catch SceneRenderError.snapshotPending { return nil }
    catch { throw error }
  }

  /// Native cover backing follows paper size, not overview tile density.
  /// After its refusal, another allocation must remove an optional physical
  /// carrier. Coarsening the same static ranges cannot admit that same set.
  func reducingNativeOwners(presence: SessionPresence, frame: WorkspaceSceneFrame,
    displayScale: Double) throws -> Self? {
    for owner in liveOwners.reversed() where !protectedOwners.contains(owner) {
      guard case .item = owner.id,
        let next = try demoting(owner, presence: presence, frame: frame, displayScale: displayScale),
        next.nativeOwnerCount < nativeOwnerCount else { continue }
      return next
    }
    return nil
  }

  private static func assemble(revision: UInt64, workspaceID: UUID, owners requestedOwners: [SceneCompositionLiveOwner],
    presence: SessionPresence, frame: WorkspaceSceneFrame, pinned: Set<WorkspaceSpatialID>,
    protected: Set<SceneCompositionLiveOwner>, displayScale: Double, previous: Self?,
    vectorRuns requestedVectors: [SceneCompositionVectorRun] = [],
    groupPoses:[SceneCompositionPlane:[String:NotebookElementPlacement.Source]] = [:],
    preservesCoverageDensity: Bool = false, tileAllowance: Int = maximumTiles) throws -> Self {
    guard (1...maximumTiles).contains(tileAllowance) else { throw SceneRenderError.resourceLimit }
    var owners = requestedOwners
    var presentations: [SceneCompositionPlane: SessionPresence] = [:]
    var bounds: [SceneCompositionPlane: WorkspaceSpatialBounds] = [:]
    var density: [SceneCompositionPlane: Double] = [:]
    // A child projection exists only inside a retained live portal. Other
    // portals are recursively flattened by the same static cover renderer.
    var includedBoards: Set<UUID> = [presence.boardID]
    var changed = true
    while changed {
      changed = false
      for owner in owners where includedBoards.contains(owner.plane.boardID) {
        guard case .item(let id) = owner.id, frame.presences[id] != nil else { continue }
        if includedBoards.insert(id).inserted { changed = true }
      }
    }
    owners.removeAll { !includedBoards.contains($0.plane.boardID) }
    let vectorRuns = requestedVectors.filter { run in
      includedBoards.contains(run.plane.boardID) && (run.plane.coverID == nil
        || owners.contains { $0.id == .item(run.plane.coverID!) && $0.plane == .board(run.plane.boardID) })
    }
    let presented = owners + vectorRuns.flatMap(\.owners)
    guard pinned.allSatisfy({ pin in presented.contains { $0.id == pin } }), protected.isSubset(of: Set(presented))
    else { throw SceneRenderError.snapshotPending("pinned_owner_projection") }
    #if os(iOS)
      let inkBoardIDs = includedBoards
    #else
      // The headless Mac painter has no UIKit mount registry. Its passive
      // planes retain the ordinary source-ink bands; exact PNG export also
      // continues through SceneCompositionRenderer.paintInk independently.
      let inkBoardIDs: Set<UUID> = [presence.boardID]
    #endif
    let paperCount = owners.filter { if case .item = $0.id { return true }; return false }.count
    guard owners.count + inkBoardIDs.count <= maximumLiveOwners,
      paperCount + inkBoardIDs.count <= maximumNativeOwners else {
      throw SceneRenderError.snapshotPending("live_owner_budget")
    }
    for boardID in includedBoards {
      guard let view = frame.presences[boardID] else { throw SceneRenderError.snapshotPending("portal_projection") }
      let plane = SceneCompositionPlane.board(boardID)
      presentations[plane] = view
      let margin = WorkspaceSceneIndex.preparationMargin(for: view)
      bounds[plane] = .init(origin: view.camera.screenToWorld(.init(x: -margin, y: -margin), viewport: view.viewport),
          width: (view.viewport.x + 2 * margin) / view.camera.scale, height: (view.viewport.y + 2 * margin) / view.camera.scale)
      density[plane] = (frame.pixelScales[boardID] ?? view.camera.scale) * displayScale
      for owner in owners where owner.plane == plane {
        guard case .item(let itemID) = owner.id,
          let item = frame.worksets[boardID]?.items.first(where: { $0.id == itemID }) else { continue }
        let cover = SceneCompositionPlane.cover(boardID: boardID, itemID: itemID)
        presentations[cover] = view
        bounds[cover] = .init(origin: .zero, width: item.geometry.width, height: item.geometry.height)
        density[cover] = density[plane]
      }
    }
    var bands: [SceneCompositionBand] = []
    for plane in presentations.keys.sorted(by: { String(describing: $0) < String(describing: $1) }) {
      // Every retained board plane has one physical ink canvas. Reparenting
      // that owner preserves accepted chunks; no second static ink copy waits
      // for a newer source revision when the active board becomes a portal.
      let layers: [ScenePaintPosition.Layer] = plane.coverID == nil
        ? (inkBoardIDs.contains(plane.boardID) ? [.elements, .covers] : [.elements, .ink, .covers]) : [.elements]
      for layer in layers {
        let positions = paintSpans(owners: owners, vectors: vectorRuns, plane: plane, layer: layer)
        for index in 0...positions.count {
          bands.append(.init(plane: plane, range: .init(layer: layer,
            lower: index == 0 ? nil : positions[index - 1].upper, upper: index == positions.count ? nil : positions[index].lower), rank: index * 2))
        }
      }
    }
    // These are metadata ranges, not allocated images. Many ranges are
    // transparent (e.g. native figures separated by off-window neighbours).
    guard bands.count <= maximumPrimitives else { throw SceneRenderError.snapshotPending("composition_band_budget") }
    var coverage: [SceneCompositionPlane: CompositionTileCoverage] = [:]
    var tiles: [SceneCompositionTileKey] = []
    let planes = presentations.keys.sorted { a, b in
      if (a == .board(presence.boardID)) != (b == .board(presence.boardID)) { return a == .board(presence.boardID) }
      return String(describing: a) < String(describing: b)
    }
    var minimumCost: [SceneCompositionPlane: Int] = [:]
    for plane in planes {
      guard let bounds = bounds[plane] else { throw SceneRenderError.resourceLimit }
      let coarse = try CompositionTileCoverage(bounds: bounds, pixelsPerWorldPoint: 0x1p-48, maximumTiles: maximumTiles)
      minimumCost[plane] = coarse.tiles.count * bands.filter { $0.plane == plane }.count
    }
    // Let the existing occupancy probe decide which coarse candidates need
    // pixels before applying the raster quota. The initial metadata is bounded
    // by the admitted ranges and each plane's minimum covering grid.
    var remaining = max(tileAllowance, minimumCost.values.reduce(0, +))
    for (offset, plane) in planes.enumerated() {
      let planeBands = bands.filter { $0.plane == plane }
      let reserved = planes.dropFirst(offset + 1).reduce(0) { $0 + (minimumCost[$1] ?? 0) }
      let allowance = max(1, (remaining - reserved) / max(1, planeBands.count))
      guard let view = presentations[plane], let bounds = bounds[plane], let pixels = density[plane] else { throw SceneRenderError.resourceLimit }
      // Budget-driven demotion cannot spend its saving by silently refining
      // every static tile. Preserve the prepared density ceiling of this plan;
      // a later ordinary camera request may choose a finer coherent cohort.
      let requestedPixels: Double
      if preservesCoverageDensity, let tile = previous?.coverage[plane]?.tiles.first {
        requestedPixels = min(pixels, Double(CompositionTile.pixelSize) / tile.worldSize)
      } else { requestedPixels = pixels }
      let cover = try CompositionTileCoverage(bounds: bounds, pixelsPerWorldPoint: requestedPixels,
        previousLevel: previous?.coverage[plane]?.level, maximumTiles: min(allowance, maximumTiles))
      guard cover.tiles.count * planeBands.count <= remaining else { throw SceneRenderError.resourceLimit }
      coverage[plane] = cover; remaining -= cover.tiles.count * planeBands.count
      for band in planeBands {
        for tile in cover.tiles {
          tiles.append(.init(workspaceID: workspaceID, revision: revision, plane: plane, tile: tile, range: band.range,
            presentationScale: view.camera.scale, viewportWidth: view.viewport.x, viewportHeight: view.viewport.y,
            focusedItemID: view.focusedItemID, mode: view.mode.rawValue))
        }
      }
    }
    // Once the finite owner selection has admitted a portal's physical child
    // plane, that aperture is part of this cohort's continuing camera route.
    // Byte pressure may flatten optional source rasters or coarsen every range,
    // but cannot revoke the prepared destination under the next pinch. Portals
    // outside this already bounded selection do not become additional pins.
    let apertures = owners.filter { owner in
      guard case .item(let id) = owner.id else { return false }
      return presentations[.board(id)] != nil
    }
    return .init(revision: revision, workspaceID: workspaceID, rootBoardID: presence.boardID, inkBoardIDs: inkBoardIDs, liveOwners: owners, protectedOwners: protected.union(apertures), bands: bands,
      coverage: coverage, presentations: presentations, tiles: tiles, requiredPixelDensity: density, vectorRuns: vectorRuns,groupPoses:groupPoses)
  }
}

@MainActor
final class SceneCompositionCohort {
  /// Geometry/native ownership survives source-only paint publications.
  let id: UUID
  var geometryID: UUID { id }
  let paintID = UUID()
  let plan: SceneCompositionPlan
  let frame: WorkspaceSceneFrame
  let requestedSources: WorkspaceSceneFrame.SourceIdentity
  let liveData: SceneCompositionLiveData
  let rasters: [SceneCompositionTileKey: RasterLease]
  let liveRasters: [SceneCompositionLiveOwner: RasterLease]
  let sourceReceipts: [SceneSourceAddress: SceneSourceReceipt]
  let sourceRasters: [SceneSourceAddress: RasterLease]
  /// Native geometry does not promise an unlimited persistent WebKit runtime.
  /// Other native source owners display completed rasters and explicit paused
  /// program input while the single source executor prepares their pixels.
  let runtimeOwners: Set<SceneSourceAddress>
  let tileSources: [SceneCompositionTileKey: Set<SceneSourceAddress>]
  let tilePresenters: SceneTilePresentationRegistry
  private var materials: [SceneSourceAddress:NotebookInkMaterialReadiness] = [:]
  func recordMaterial(_ address:SceneSourceAddress,id:UUID,content:NotebookInkMaterialView.Content?,ready:Bool) {
    materials[address,default:.init()].record(id,content:content,ready:ready)
  }
  func hasPresentedMaterials(_ address:SceneSourceAddress,sources:[NotebookInkMaterialView.Content]) -> Bool {
    (materials[address] ?? .init()).isReady(for:sources)
  }
  private var installedLayers: [ScenePaintPosition.Layer: SceneCameraPlaneInstallation] = [:]
  private var installedTiles: [SceneCompositionTileKey: SceneSourceInstallation] = [:]
  private var installedSources: [SceneSourceAddress: SceneSourceInstallation] = [:]
  /// Observes the existing native claim without creating an installation or
  /// treating a cached raster as displayed pixels.
  func observedTileInstallation(_ key: SceneCompositionTileKey) -> (entryID: UUID?, isInstalled: Bool) {
    (installedTiles[key]?.entryID, installedTiles[key]?.isInstalled == true)
  }
  var isPaintInstalled: Bool {
    installedLayers[.elements]?.isInstalled == true && installedLayers[.covers]?.isInstalled == true
  }
  func installation(for layer: ScenePaintPosition.Layer) -> SceneCameraPlaneInstallation {
    if let value = installedLayers[layer] { return value }
    let value = SceneCameraPlaneInstallation()
    installedLayers[layer] = value
    return value
  }
  func didInstallTile(_ key: SceneCompositionTileKey, installation: SceneSourceInstallation) {
    guard rasters[key]?.entryID == installation.entryID else { return }
    installedTiles[key] = installation
  }
  func didReplaceTile(_ key: SceneCompositionTileKey) { installedTiles[key] = nil }
  func didInstallSource(_ address: SceneSourceAddress, installation: SceneSourceInstallation) {
    guard let receipt = sourceReceipts[address],
      let source = installation.source.agentElement,
      SceneRasterSource.agent(receipt.demand.source) == .agent(source) else { return }
    installedSources[address] = installation
  }
  func hasInstalledPixels(for address: SceneSourceAddress) -> Bool {
    guard isPaintInstalled, let receipt = sourceReceipts[address], receipt.hasCurrentPixels else { return false }
    let fragments = tileSources.filter { $0.value.contains(address) }.map(\.key)
    if !fragments.isEmpty {
      return fragments.allSatisfy { installedTiles[$0]?.entryID == rasters[$0]?.entryID && installedTiles[$0]?.isInstalled == true }
    }
    guard let installation = installedSources[address], let source = installation.source.agentElement else { return false }
    return installation.isInstalled && SceneRasterSource.agent(source) == .agent(receipt.demand.source)
  }

  func containsSourceWindows(presence: SessionPresence, frame: WorkspaceSceneFrame, displayScale: Double,
    refinesDetails: Bool = true) -> Bool {
    for (address, receipt) in sourceReceipts {
      guard let view = address.plane.boardID == presence.boardID ? presence : frame.presences[address.plane.boardID],
        receipt.coversVisibleWindow(in: view,
          pixelDensity: (frame.pixelScales[address.plane.boardID] ?? view.camera.scale) * displayScale,
          refinesDetails: refinesDetails) else { return false }
    }
    return true
  }
  func sharesGeometry(with plan: SceneCompositionPlan, frame: WorkspaceSceneFrame) -> Bool {
    guard self.plan.workspaceID == plan.workspaceID, self.plan.rootBoardID == plan.rootBoardID,
      self.plan.liveOwners == plan.liveOwners, self.plan.vectorRuns == plan.vectorRuns, self.plan.inkBoardIDs == plan.inkBoardIDs,
      self.plan.groupPoses == plan.groupPoses,
      Set(self.plan.presentations.keys) == Set(plan.presentations.keys) else { return false }
    for owner in plan.presentedOwners {
      switch owner.id {
      case .item(let id):
        guard let previous = self.frame.worksets[owner.plane.boardID]?.items.first(where: { $0.id == id }),
          let current = frame.worksets[owner.plane.boardID]?.items.first(where: { $0.id == id }),
          previous.geometry == current.geometry, previous.center == current.center,
          previous.stackID == current.stackID else { return false }
      case .element(let id):
        let previous = if let id = owner.plane.coverID { self.frame.covers[id] } else { self.frame.worksets[owner.plane.boardID] }
        let current = if let id = owner.plane.coverID { frame.covers[id] } else { frame.worksets[owner.plane.boardID] }
        guard let old = previous?.elements.first(where: { $0.id == id }),
          let new = current?.elements.first(where: { $0.id == id }), old.frame == new.frame,
          old.worldOrigin == new.worldOrigin, old.surface == new.surface else { return false }
      }
    }
    return true
  }
  #if os(iOS)
    let nativeInk: SpatialInkSceneLease
    init(plan: SceneCompositionPlan, frame: WorkspaceSceneFrame, requestedSources: WorkspaceSceneFrame.SourceIdentity,
      liveData: SceneCompositionLiveData, rasters: [SceneCompositionTileKey: RasterLease],
      liveRasters: [SceneCompositionLiveOwner: RasterLease], nativeInk: SpatialInkSceneLease,
      geometryID: UUID? = nil, sourceReceipts: [SceneSourceAddress: SceneSourceReceipt] = [:],
      sourceRasters: [SceneSourceAddress: RasterLease] = [:],
      runtimeOwners: Set<SceneSourceAddress> = [],
      tileSources: [SceneCompositionTileKey: Set<SceneSourceAddress>] = [:],
      tilePresenters: SceneTilePresentationRegistry = .init()) {
      id = geometryID ?? UUID()
      self.plan = plan; self.frame = frame; self.liveData = liveData; self.rasters = rasters
      self.requestedSources = requestedSources; self.liveRasters = liveRasters; self.nativeInk = nativeInk
      self.sourceReceipts = sourceReceipts; self.sourceRasters = sourceRasters; self.tileSources = tileSources
      self.runtimeOwners = runtimeOwners
      self.tilePresenters = tilePresenters
    }
  #else
  init(plan: SceneCompositionPlan, frame: WorkspaceSceneFrame, requestedSources: WorkspaceSceneFrame.SourceIdentity? = nil,
    liveData: SceneCompositionLiveData,
    rasters: [SceneCompositionTileKey: RasterLease], liveRasters: [SceneCompositionLiveOwner: RasterLease],
    geometryID: UUID? = nil, sourceReceipts: [SceneSourceAddress: SceneSourceReceipt] = [:],
    sourceRasters: [SceneSourceAddress: RasterLease] = [:],
    runtimeOwners: Set<SceneSourceAddress> = [],
    tileSources: [SceneCompositionTileKey: Set<SceneSourceAddress>] = [:],
    tilePresenters: SceneTilePresentationRegistry = .init()) {
    id = geometryID ?? UUID()
    self.plan = plan; self.frame = frame; self.liveData = liveData; self.rasters = rasters
    self.requestedSources = requestedSources ?? frame.sourceIdentity
    self.liveRasters = liveRasters
    self.sourceReceipts = sourceReceipts; self.sourceRasters = sourceRasters; self.tileSources = tileSources
    self.runtimeOwners = runtimeOwners
    self.tilePresenters = tilePresenters
  }
  #endif
  func bands(in plane: SceneCompositionPlane, layer: ScenePaintPosition.Layer) -> [SceneCompositionBand] {
    plan.bands.filter { $0.plane == plane && $0.range.layer == layer }
  }
  isolated deinit {
    for raster in rasters.values { raster.release() }
    for raster in liveRasters.values { raster.release() }
    for raster in sourceRasters.values { raster.release() }
  }
}

/// Candidate pixels remain private until the whole finite coverage succeeds.
/// Keeping the old cohort is a real image, not a count or a claim of readiness.
@MainActor
@Observable
final class SceneCompositionTiles {
  private(set) var published: SceneCompositionCohort?
  private(set) var isPreparing = false
  private(set) var failure: String?
  private let resources: SceneRenderResources
  let surfaceRegistry: SpatialInkSurfaceRegistry
  // Optional read-only phase observation; nil in the application. This records
  // existing awaits without adding a scheduling or publication path.
  @ObservationIgnored var onPreparationPhase: ((UUID, String) -> Void)?
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var inFlight: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var stopped = false
  @ObservationIgnored private var requestID = UUID()
  private struct Request {
    let source: SceneCompositionSource
    let presence: SessionPresence
    let frame: WorkspaceSceneFrame
    let pinned: Set<WorkspaceSpatialID>
    let displayScale: Double
    let refinesDetails: Bool
    let permitsPreparation: @MainActor () -> Bool
    let onSourceInvalidated: @MainActor () -> Void

    func continues(_ other: Self) -> Bool {
      source.workspaceID == other.source.workspaceID && source.revision == other.source.revision
        && presence.boardID == other.presence.boardID && presence.mode == other.presence.mode
        && presence.focusedItemID == other.presence.focusedItemID && presence.viewport == other.presence.viewport
        && pinned == other.pinned && displayScale == other.displayScale
    }
  }
  @ObservationIgnored private var preparingRequest: Request?
  @ObservationIgnored private var pendingRequest: Request?
  @ObservationIgnored private var lastRequest: Request?
  @ObservationIgnored private var dirtySources: Set<SceneSourceAddress> = []
  @ObservationIgnored private var sourceFailures: [SceneSourceAddress: (SceneSourceDemand, String)] = [:]
  private struct RuntimeSource {
    let leaseID: UUID
    var demand: SceneSourceDemand
    var isMounted = true
    var failure: AgentWebSourceFailure?
  }
  @ObservationIgnored private var runtimeSources: [SceneSourceAddress: RuntimeSource] = [:]
  private(set) var runtimeSourceGeneration: UInt64 = 0

  /// The physical runtime and static job report to the same composition owner.
  /// Source-only paint changes do not replace a still-mounted producer attempt.
  func registerRuntimeSource(focus: InteractiveElementReference, source: AgentElement,
    policy: AgentSnapshotPolicy, leaseID: UUID, cohort: SceneCompositionCohort?) -> SceneSourceAddress? {
    guard !stopped, let cohort, case .board(let boardID, let id) = focus else { return nil }
    let addresses = cohort.sourceReceipts.keys.filter { $0.plane.boardID == boardID && $0.elementID == id }
    guard addresses.count == 1, let address = addresses.first,
      cohort.plan.allowsLive(.element(id), in: address.plane),
      let admitted = cohort.sourceReceipts[address]?.demand.source,
      ScenePreparedRasterFallback.hasCompatibleGeometry(admitted, source) else { return nil }
    let region: PageRect? = if case .region(let value, _) = policy { value } else { nil }
    let demand = SceneSourceDemand(source: source, minimumScale: policy.minimumScale(for: source), region: region)
    if var current = runtimeSources[address], current.leaseID == leaseID, SceneRasterSource.agent(current.demand.source) == .agent(source) {
      if current.demand != demand {
        current.demand = demand
        if let policy = current.failure?.policy, policy != demand.policy {
          current.failure = nil; runtimeSourceGeneration &+= 1
        }
        runtimeSources[address] = current
      }
    } else {
      let hadFailure = runtimeSources[address]?.failure != nil
      runtimeSources[address] = .init(leaseID: leaseID, demand: demand)
      // Only failure presentation observes this generation. A successful
      // admission/density update must not invalidate every other live view.
      if hadFailure { runtimeSourceGeneration &+= 1; dirtySources.insert(address); refreshSources() }
    }
    return address
  }

  func runtimeFailure(at address: SceneSourceAddress?, source: AgentElement,
    policy: AgentSnapshotPolicy) -> AgentWebSourceFailure? {
    _ = runtimeSourceGeneration
    guard let address, let failure = runtimeSources[address]?.failure,
      SceneRasterSource.agent(failure.source) == .agent(source), failure.policy == nil || failure.policy == policy else { return nil }
    return failure
  }

  @discardableResult
  func failRuntimeSource(_ address: SceneSourceAddress, failure: AgentWebSourceFailure) -> Bool {
    guard !stopped, var current = runtimeSources[address], current.isMounted,
      current.leaseID == failure.leaseID, SceneRasterSource.agent(current.demand.source) == .agent(failure.source),
      failure.policy == nil || failure.policy == current.demand.policy else { return false }
    current.failure = failure; runtimeSources[address] = current
    runtimeSourceGeneration &+= 1; dirtySources.insert(address); refreshSources()
    return true
  }

  func runtimeSourceBecameReady(_ address: SceneSourceAddress, leaseID: UUID, source: AgentElement) {
    guard var current = runtimeSources[address], current.isMounted,
      current.leaseID == leaseID, SceneRasterSource.agent(current.demand.source) == .agent(source),
      current.failure?.policy != nil else { return }
    current.failure = nil; runtimeSources[address] = current
    runtimeSourceGeneration &+= 1; dirtySources.insert(address); refreshSources()
  }

  func retireRuntimeSource(_ address: SceneSourceAddress, leaseID: UUID) {
    guard var current = runtimeSources[address], current.leaseID == leaseID else { return }
    current.isMounted = false
    runtimeSources[address] = current.failure == nil ? nil : current
  }

  private var allSourceFailures: [SceneSourceAddress: SceneSourceFailure] {
    var failures = sourceFailures.mapValues {
      SceneSourceFailure(demand: $0.0, message: $0.1, captureSpecific: $0.1 == SceneRenderError.resourceLimit.description)
    }
    for (address, runtime) in runtimeSources {
      guard let failure = runtime.failure else { continue }
      let diagnostic = failure.diagnostic
      failures[address] = .init(demand: runtime.demand,
        message: diagnostic.kind == "resource_limit" ? SceneRenderError.resourceLimit.description : diagnostic.kind + ": " + diagnostic.message,
        captureSpecific: failure.policy != nil)
    }
    return failures
  }

  private func sourceFailure(_ address: SceneSourceAddress, demand: SceneSourceDemand) -> String? {
    guard let failed = allSourceFailures[address], failed.matches(demand) else { return nil }
    return failed.message
  }
  @ObservationIgnored private var preparedSources: [SceneSourceAddress: RasterLease] = [:]
  private struct SourceJob {
    let id: UUID
    var demand: SceneSourceDemand
    let capture: SceneRasterCaptureRequest
    let task: Task<Void, Never>
  }
  @ObservationIgnored private var sourceJobs: [SceneSourceAddress: SourceJob] = [:]
  @ObservationIgnored private var sourceWork: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var resourceObserver: NSObjectProtocol?
  @ObservationIgnored private var admissionObserver: NSObjectProtocol?
  @ObservationIgnored private var lastRefinementAdmission: SceneRasterAdmission?
  private(set) var hasQualityDebt = false
  init(resources: SceneRenderResources = .shared,
    surfaceRegistry: SpatialInkSurfaceRegistry = .init()) {
    self.resources = resources; self.surfaceRegistry = surfaceRegistry
    resourceObserver = NotificationCenter.default.addObserver(forName: SceneRenderResources.didChange,
      object: nil, queue: .main) { [weak self] note in
      guard let elementID = note.object as? String else { return }
      Task { @MainActor [weak self] in self?.sourcePixelsChanged(elementID) }
    }
    admissionObserver = NotificationCenter.default.addObserver(forName: SceneRenderResources.didGainRasterAdmission,
      object: resources, queue: .main) { [weak self] _ in
      Task { @MainActor [weak self] in self?.refineAfterAdmission() }
    }
  }

  func prepare(source: SceneCompositionSource, presence: SessionPresence, frame: WorkspaceSceneFrame,
    pinned: Set<WorkspaceSpatialID>, displayScale: Double = 2, refinesDetails: Bool = true,
    permitsPreparation: @escaping @MainActor () -> Bool = { true },
    onSourceInvalidated: @escaping @MainActor () -> Void = {}) {
    // A whole is an addressed source pin, never another painted host. A cover
    // keeps its one physical carrier; its members remain eligible for tiles.
    var painters=Set<WorkspaceSpatialID>()
    for pin in pinned {
      if case .element(let id)=pin,let element=frame.index.element(id:id,boardID:presence.boardID),element.kind == .group {
        if element.surface.kind == .cover,let owner=element.surface.ownerID { painters.insert(.item(owner)) }
      } else { painters.insert(pin) }
    }
    prepare(.init(source: source, presence: presence, frame: frame, pinned: painters,
      displayScale: displayScale, refinesDetails: refinesDetails,
      permitsPreparation: permitsPreparation, onSourceInvalidated: onSourceInvalidated))
  }

  private func prepare(_ request: Request) {
    guard !stopped else { return }
    lastRequest = request
    guard request.permitsPreparation() else { cancelPreparation(); return }
    resumeRetiredRuntimeCapturesIfAdmitted()
    // Camera samples replace one waiting address. They cannot repeatedly
    // cancel the source read or WebKit image that must reveal the next area.
    // A changed content cut, pin or physical scene still invalidates that work.
    if let preparingRequest {
      if request.continues(preparingRequest) {
        pendingRequest = request
        return
      }
      cancelPreparation()
    }
    let source = request.source, presence = request.presence, frame = request.frame
    let pinned = request.pinned.union(installedRuntimePins(frame: frame, presence: presence))
    let displayScale = request.displayScale
    let permitsPreparation = request.permitsPreparation, onSourceInvalidated = request.onSourceInvalidated
    let sources = frame.sourceIdentity
    let needsSourceScheduling = published?.sourceReceipts.contains { address, receipt in
      guard !receipt.hasCurrentPixels, sourceJobs[address] == nil,
        sourceFailure(address, demand: receipt.demand) == nil else { return false }
      if published?.runtimeOwners.contains(address) == true { return false }
      return true
    } ?? false
    let reusablePaint = published.flatMap { cohort -> SceneCompositionCohort? in
      guard dirtySources.isEmpty, !needsSourceScheduling,
        cohort.containsSourceWindows(presence: presence, frame: frame, displayScale: displayScale,
          refinesDetails: request.refinesDetails), cohort.requestedSources == sources,
        cohort.plan.revision == source.revision, cohort.plan.workspaceID == source.workspaceID,
        cohort.plan.groupPoses == source.groupPoses,
        Self.covers(cohort.plan, presence: presence, pinned: pinned, refinesDetails: request.refinesDetails)
      else { return nil }
      return cohort
    }
    if reusablePaint != nil, containsNativeProjection(for: request) { return }
    cancelPreparation()
    let id = requestID
    let changedSources = dirtySources
    dirtySources.removeAll()
    lastRefinementAdmission = resources.rasterAdmission
    isPreparing = true; failure = nil; budgetFailures = []; preparingRequest = request
    task = Task { [weak self, resources, surfaceRegistry] in
      defer {
        self?.onPreparationPhase?(id, "finished")
        self?.inFlight[id] = nil
        self?.finishRequest(id)
      }
      var rasters: [SceneCompositionTileKey: RasterLease] = [:]
      var liveRasters: [SceneCompositionLiveOwner: RasterLease] = [:]
      var fallbacks = self?.published?.sourceRasters ?? [:]
      fallbacks.merge(self?.preparedSources ?? [:]) { _, prepared in prepared }
      let renderer = SceneCompositionRenderer(source: source, resources: resources,
        usesPreparedSources: true, fallbackSources: fallbacks,
        sourceFailures: self?.allSourceFailures ?? [:],
        permitsPreparation: { [weak self] in self?.requestID == id && permitsPreparation() })
      defer { renderer.finishPreparation() }
      do {
        try Task.checkCancellation()
        guard self?.requestID == id, permitsPreparation() else { throw CancellationError() }
        #if os(iOS)
          if let reusablePaint {
            // The finite ink backing can need a new basis while every element,
            // source crop and static tile remains covered. Refill those SAME
            // physical ink owners without invalidating the live content tree.
            // liveData contains complete ink for the admitted surfaces, and
            // source validation plus install's contact/generation checks remain
            // authoritative; this is not an exemption for an empty canvas.
            self?.onPreparationPhase?(id, "native_ink")
            let nativeInk = try await surfaceRegistry.prepareSceneInk(plan: reusablePaint.plan, frame: frame,
              liveData: reusablePaint.liveData, resources: resources, displayScale: displayScale,
              refinesDetails: request.refinesDetails)
            try await source.validate(); try Task.checkCancellation()
            guard self?.requestID == id, self?.published === reusablePaint, permitsPreparation()
            else { throw CancellationError() }
            try nativeInk.install()
            self?.onPreparationPhase?(id, "native_projection_installed")
            return
          }
        #endif
        self?.onPreparationPhase?(id, "plan")
        var plan = try await SceneCompositionPlan.prepare(source: source, presence: presence, frame: frame,
          pinned: pinned, displayScale: displayScale, previous: self?.published?.plan)
        self?.onPreparationPhase?(id, "source_requests")
        renderer.useSourcePresentation(plan: plan, frame: frame, displayScale: displayScale, refinesDetails: request.refinesDetails)
        let requests = try await renderer.liveRasterRequests(plan: plan, frame: frame, displayScale: displayScale)
        let previous = self?.published
        var previousLiveData = previous.map { (plan: $0.plan, data: $0.liveData) }
        let changedSources = changedSources.union(try await renderer.sourcesOutsideCoverage(of: previous))
        let maximumAttempts = plan.reductionPotential + 1
        for attempt in 0..<maximumAttempts {
          try Task.checkCancellation()
          guard self?.requestID == id, permitsPreparation() else { throw CancellationError() }
          var phase = "live_source"
          var allocation = BudgetAllocation.raster
          let priorRefusal = resources.lastRasterRefusal?.generation
          #if os(iOS)
            var nativeInk: SpatialInkSceneLease?
          #endif
          do {
            self?.onPreparationPhase?(id, "live_source")
            let candidate = try await source.liveCandidate(plan: plan, presence: presence, frame: frame,
              previous: previous.map { (plan: $0.plan, data: $0.liveData) }, reusing: previousLiveData)
            let liveData = candidate.data
            previousLiveData = (plan, liveData)
            let canCarry = candidate.canCarry
            try Task.checkCancellation()
            guard self?.requestID == id, permitsPreparation() else { throw CancellationError() }
            let selected = requests.filter { plan.liveOwners.contains($0.owner) }
            let runtimeOwners = Self.runtimeOwners(requests: selected, plan: plan, resources: resources)
            self?.onPreparationPhase?(id, "discover_sources")
            try await renderer.discoverSources(plan: plan, frame: frame, displayScale: displayScale)
            renderer.onSourceDemand = { [weak self, weak renderer] in
              guard let self, requestID == id, let renderer else { return }
              scheduleSources(renderer.receipts(), runtimeOwners: runtimeOwners, presence: presence, frame: frame)
            }
            self?.scheduleSources(renderer.receipts(), runtimeOwners: runtimeOwners, presence: presence, frame: frame)
            let cached = selected.filter { resources.image(for: $0.demand.rasterSource, minimumScale: $0.requestedScale) != nil }
            let invalidatedTiles = Set(plan.tiles.filter { key in
              previous?.tileSources.contains { oldKey, addresses in
                oldKey.hasSamePaintWindow(as: key) && !addresses.isDisjoint(with: changedSources)
              } == true
            })
            let borrowed = try Self.borrowRasters(plan: plan, requests: cached, previous: previous,
              canCarry: canCarry, resources: resources, invalidatedTiles: invalidatedTiles)
            rasters = borrowed.tiles; liveRasters = borrowed.live
            phase = "raster_preflight"
            guard borrowed.prepareAdmission(resources) else {
              self?.recordBudgetFailure(phase: phase, plan: plan, attempt: attempt,
                requestedBytes: borrowed.additionalBytes, admission: resources.rasterAdmission)
              throw SceneRenderError.resourceLimit
            }
            #if os(iOS)
              // Reject an already impossible raster candidate before creating
              // any new native canvases. Their real grants then join this same
              // pool, so recheck rather than treating the first read as credit.
              phase = "native_ink"
              allocation = .nativeInk
              self?.onPreparationPhase?(id, "native_ink")
              nativeInk = try await surfaceRegistry.prepareSceneInk(plan: plan, frame: frame,
                liveData: liveData, resources: resources, displayScale: displayScale, refinesDetails: request.refinesDetails)
              phase = "raster_native_preflight"
              allocation = .raster
              guard borrowed.prepareAdmission(resources) else {
                self?.recordBudgetFailure(phase: phase, plan: plan, attempt: attempt,
                  requestedBytes: borrowed.additionalBytes, admission: resources.rasterAdmission)
                throw SceneRenderError.resourceLimit
              }
            #endif
            phase = "live_raster"
            self?.onPreparationPhase?(id, "tiles")
            renderer.carrySources(from: previous, tiles: rasters)
            renderer.useLiveSources(selected)
            for key in plan.tiles where rasters[key] == nil {
              try Task.checkCancellation()
              guard self?.requestID == id, permitsPreparation(), let presentation = plan.presentations[key.plane]
              else { throw CancellationError() }
              phase = "tile:\(key.plane):\(key.range.layer.rawValue):\(key.tile.level):\(key.tile.column):\(key.tile.row):\(key.tile.localColumn):\(key.tile.localRow)"
              self?.onPreparationPhase?(id, phase)
              // Screen tiles can contain explicit local pending/fallback
              // sources. Only the exact renderer uses durable complete PNGs.
              do {
                let raster = try await renderer.renderTile(key: key, presentation: presentation)
                rasters[key] = raster
              }
            }
            self?.onPreparationPhase?(id, "validate")
            try await source.validate(); try Task.checkCancellation()
            guard self?.requestID == id, permitsPreparation(), rasters.count == plan.tiles.count else { throw CancellationError() }
            var receipts = renderer.receipts()
            for (address, receipt) in receipts {
              guard let runtime = self?.runtimeSources[address], let failed = runtime.failure,
                SceneRasterSource.agent(failed.source) == .agent(receipt.demand.source),
                failed.policy == nil || failed.policy == receipt.demand.policy else { continue }
              receipts[address] = .init(demand: receipt.demand, installedSource: receipt.installedSource,
                installedScale: receipt.installedScale,
                status: .failed(failed.diagnostic.kind + ": " + failed.diagnostic.message),
                installedRegion: receipt.installedRegion)
            }
            // A source completed early enough to be consumed by this pass.
            // Its notification must not force another identical paint pass.
            for (address, receipt) in receipts where receipt.hasCurrentPixels {
              if let prepared = self?.preparedSources[address],
                prepared.entryID == renderer.sourceRasters[address]?.entryID {
                self?.dirtySources.remove(address)
              }
            }
            renderer.cachePreparedTiles(rasters)
            let ownedSources = renderer.sourceRasters.compactMapValues { $0.retainedCopy() }
            let geometryID = previous.flatMap { previous in
              previous.sharesGeometry(with: plan, frame: frame) ? previous.geometryID : nil
            }
            let tilePresenters = geometryID == nil ? SceneTilePresentationRegistry()
              : previous?.tilePresenters ?? SceneTilePresentationRegistry()
            // No await separates the validated native source installation and
            // the matching static publication. Mounted old leases retain their
            // actual owners until the old view, not just this field, lets go.
            #if os(iOS)
              guard let nativeInk else { throw SceneRenderError.snapshotPending("native_ink_preparation") }
              try nativeInk.install()
              tilePresenters.install(rasters)
              self?.published = .init(plan: plan, frame: frame, requestedSources: sources,
                liveData: liveData, rasters: rasters, liveRasters: liveRasters, nativeInk: nativeInk,
                geometryID: geometryID, sourceReceipts: receipts, sourceRasters: ownedSources,
                runtimeOwners: runtimeOwners,
                tileSources: renderer.tileSources, tilePresenters: tilePresenters)
            #else
              tilePresenters.install(rasters)
              self?.published = .init(plan: plan, frame: frame, requestedSources: sources,
                liveData: liveData, rasters: rasters, liveRasters: liveRasters,
                geometryID: geometryID, sourceReceipts: receipts, sourceRasters: ownedSources,
                runtimeOwners: runtimeOwners,
                tileSources: renderer.tileSources, tilePresenters: tilePresenters)
            #endif
            self?.onPreparationPhase?(id, "published")
            rasters.removeAll(); liveRasters.removeAll()
            self?.hasQualityDebt = !plan.meetsRequiredDensity
            self?.scheduleSources(receipts, runtimeOwners: runtimeOwners, presence: presence, frame: frame)
            return
          } catch SceneRenderError.resourceLimit {
            if !phase.hasSuffix("preflight") {
              let refusal = resources.lastRasterRefusal.flatMap { $0.generation != priorRefusal ? $0 : nil }
              self?.recordBudgetFailure(phase: phase, allocation: allocation, plan: plan, attempt: attempt,
                requestedBytes: refusal?.requestedBytes ?? 0, admission: refusal?.admission ?? resources.rasterAdmission)
            }
            for raster in rasters.values { raster.release() }; rasters.removeAll()
            for raster in liveRasters.values { raster.release() }; liveRasters.removeAll()
            #if os(iOS)
              nativeInk = nil
            #endif
            // A refused private candidate does not revoke the shown cohort.
            // Submitted WebKit work drains before another allocation attempt.
            try await renderer.finishPreparationAndDrain()
            try Task.checkCancellation()
            guard self?.requestID == id, permitsPreparation(), attempt + 1 < maximumAttempts,
              let smaller = try Self.lowerCostPlan(plan, allocation: allocation, requests: requests, previous: previous,
                presence: presence, frame: frame, displayScale: displayScale, resources: resources),
              smaller.reductionPotential < plan.reductionPotential
            else { throw SceneRenderError.resourceLimit }
            // Initial preparation already proved populated coverage. Only a
            // changed allocation candidate needs that addressed probe again.
            plan = try await smaller.removingEmptyTiles(source: source)
          }
        }
        throw SceneRenderError.resourceLimit
      } catch {
        for raster in rasters.values { raster.release() }
        for raster in liveRasters.values { raster.release() }
        try? await renderer.finishPreparationAndDrain()
        guard self?.requestID == id else { return }
        if case NotebookStorageError.transactionConflict = error {
          // The writer advanced while this candidate was being prepared.
          // Ask the model for the new read cut; waiting for camera movement
          // would strand an already saved edit behind the previous picture.
          onSourceInvalidated()
        } else if !(error is CancellationError) {
          self?.failure = String(describing: error)
          print("SCENE_COMPOSITION_FAILED board=\(presence.boardID) revision=\(source.revision) error=\(error)")
        }
      }
    }
    inFlight[id] = task
  }

  private func finishRequest(_ id: UUID) {
    guard requestID == id else { return }
    task = nil; preparingRequest = nil; isPreparing = !sourceJobs.isEmpty
    let next = pendingRequest
    pendingRequest = nil
    if let next { prepare(next) }
  }

  private static func runtimeOwners(requests: [SceneCompositionRenderer.LiveRasterRequest],
    plan: SceneCompositionPlan, resources: SceneRenderResources) -> Set<SceneSourceAddress> {
    guard resources.profile == .interactive, let root = plan.presentations[.board(plan.rootBoardID)] else { return [] }
    let candidates = requests.filter { request in
      // Only the current board mounts input-capable source consumers.
      // Portal previews are read-only projections: assigning their sources
      // a runtime owner would suppress the static producer even though no
      // such runtime can be mounted, leaving the source pending forever.
      return request.owner.plane.demandsRuntime(source: request.source,
        origin: request.demand.worldOrigin, transform:request.demand.bodyTransform, in: root)
    }
    // Membership expresses real visibility, not an optimistic resource grant.
    // The existing allocator admits these owners and queues the remainder.
    return Set(candidates.map {
      .init(plane: $0.owner.plane, elementID: $0.source.id)
    })
  }

  /// A working surface is not an optional raster-quality choice. Keep its
  /// physical owner while it remains visible; only leaving the scene, deletion
  /// or its explicit retirement can hand that position back to static paint.
  private func installedRuntimePins(frame: WorkspaceSceneFrame, presence: SessionPresence) -> Set<WorkspaceSpatialID> {
    let poses=(lastRequest?.source.groupPoses ?? [:]).filter { $0.key.boardID == presence.boardID }.values.reduce(into:[String:NotebookElementPlacement.Source]()) { result,values in
      result.merge(values,uniquingKeysWith:{ _,new in new })
    }
    let graph=frame.index.graphicGraph(boardID:presence.boardID)?.projecting(placements:poses)
    return Set(runtimeSources.compactMap { address, runtime in
      guard runtime.isMounted, address.plane.boardID == presence.boardID else { return nil }
      let element: SpatialElement?
      if let coverID = address.plane.coverID {
        guard presence.focusedItemID == coverID else { return nil }
        element = frame.covers[coverID]?.elements.first { $0.id == address.elementID }
      } else {
        element = frame.worksets[presence.boardID]?.elements.first { $0.id == address.elementID }
      }
      guard let element,let placement=graph?.placement(element.id) else { return nil }
      let origin = SceneSourceCapture.origin(placement:placement,plane:address.plane,frame:frame)
      let visible = SceneSourceCapture.visibleRect(source:agentElementSnapshotSource(element),origin:origin,
        transform:SceneSourceCapture.linear(placement),presence:presence)
      guard !visible.isNull, !visible.isEmpty else { return nil }
      return .element(element.id)
    })
  }

  private func scheduleSources(_ receipts: [SceneSourceAddress: SceneSourceReceipt],
    runtimeOwners: Set<SceneSourceAddress>, presence: SessionPresence, frame: WorkspaceSceneFrame) {
    let wanted = Set(receipts.keys)
    runtimeSources = runtimeSources.filter { wanted.contains($0.key) }
    for (address, job) in sourceJobs {
      guard let demand = receipts[address]?.demand, demand.source == job.demand.source,
        !runtimeOwners.contains(address) else {
        job.task.cancel(); sourceJobs[address] = nil; continue
      }
      // Source/state identity owns the job. Pinch density and viewport crops
      // retarget that same executor instead of resetting its readiness work.
      sourceJobs[address]?.demand = demand
      job.capture.update(demand.policy)
    }
    sourceFailures = sourceFailures.filter { address, failure in
      guard let current = receipts[address]?.demand, current.source == failure.0.source else { return false }
      return failure.1 != SceneRenderError.resourceLimit.description || current == failure.0
    }
    preparedSources = preparedSources.filter { wanted.contains($0.key) }
    func priority(_ entry: (key: SceneSourceAddress, value: SceneSourceReceipt)) -> (Int, Double, String) {
      let demand = entry.value.demand
      guard let origin = demand.worldOrigin,
        let view = entry.key.plane.boardID == presence.boardID ? presence : frame.presences[entry.key.plane.boardID]
      else { return (2, 0, entry.key.elementID) }
      let visible = SceneSourceCapture.visibleRect(source: demand.source, origin: origin, transform:demand.bodyTransform, presence: view)
      let localCenter=CGPoint(x:demand.source.frame.width/2,y:demand.source.frame.height/2).applying(demand.bodyTransform)
      let center = origin.offsetBy(x:localCenter.x,y:localCenter.y)
      let delta = view.camera.center.delta(to: center)
      let hasFallback = entry.value.installedSource != nil
      // A visible program mounts its own runtime. Do not make newly exposed
      // passive pixels wait behind speculative screenshots of programs still
      // outside the viewport; those previews use only the remaining capacity.
      return (visible.isEmpty || visible.isNull ? (demand.source.requiresLiveRuntime ? 3 : 2) : (hasFallback ? 1 : 0),
        delta.x * delta.x + delta.y * delta.y, entry.key.elementID)
    }
    for (address, receipt) in receipts.sorted(by: { priority($0) < priority($1) }) {
      guard !receipt.hasCurrentPixels, sourceJobs[address] == nil,
        sourceFailure(address, demand: receipt.demand) == nil else { continue }
      // Its admitted on-screen WebKit is the sole executor of a live
      // interactive program. Static tiles and passive exports use jobs below.
      if runtimeOwners.contains(address) { continue }
      guard sourceJobs.count < 32 else { break }
      let id = UUID(), demand = receipt.demand, programSource = lastRequest?.source
      let capture = SceneRasterCaptureRequest(policy: demand.policy)
      let work = Task { @MainActor [weak self, resources] in
        defer { self?.sourceWork[id] = nil }
        do {
          let focus = InteractiveElementReference.board(boardID: address.plane.boardID, elementID: address.elementID)
          let current = try await AgentWebCoordinator.captureCurrent(focus: focus, element: demand.source, resources: resources)
          let raster: RasterLease
          if let current, current.image(for: capture.policy.rasterSource(for: demand.source),
            minimumScale: capture.policy.minimumScale(for: demand.source)) != nil {
            raster = current
          } else {
            current?.release()
            // The same keyed WebKit admission waits for a demoted physical
            // program's actual final borrow before starting a raster executor.
            raster = try await resources.prepareRaster(demand.source, requestedScale: demand.minimumScale, region: demand.region,
            executionSource: focus,
            captureRequest: capture, programStore: await programSource?.programStore(),
            permitsPreparation: { [weak self] in
              guard let self, !stopped, sourceJobs[address]?.id == id else { return false }
              // This address already owns an admitted executor. A transient
              // input barrier may defer its publication, but cannot reset its
              // running ready promise at every finger lift. Source replacement,
              // leaving the workset and shutdown revoke this job explicitly.
              return true
            })
          }
          guard let self, !stopped, sourceJobs[address]?.id == id,
            sourceJobs[address]?.demand.source == demand.source, !Task.isCancelled else { raster.release(); return }
          preparedSources[address] = raster
          sourceJobs[address] = nil
          isPreparing = preparingRequest != nil || !sourceJobs.isEmpty
          dirtySources.insert(address)
          refreshSources()
        } catch {
          guard let self, sourceJobs[address]?.id == id else { return }
          let failedDemand = sourceJobs[address]?.demand ?? demand
          sourceJobs[address] = nil
          if !(error is CancellationError) {
            sourceFailures[address] = (failedDemand, String(describing: error))
            dirtySources.insert(address)
            refreshSources()
          }
          isPreparing = preparingRequest != nil || !sourceJobs.isEmpty
        }
      }
      sourceJobs[address] = .init(id: id, demand: demand, capture: capture, task: work)
      sourceWork[id] = work
    }
    isPreparing = preparingRequest != nil || !sourceJobs.isEmpty
  }

  private func sourcePixelsChanged(_ elementID: String) {
    guard !stopped, let published else { return }
    for (address, receipt) in published.sourceReceipts where address.elementID == elementID && !receipt.hasCurrentPixels {
      if let raster = resources.retainRaster(for: receipt.demand.rasterSource, minimumScale: receipt.demand.minimumScale) {
        preparedSources[address] = raster
        dirtySources.insert(address)
      }
    }
    if !dirtySources.isEmpty { refreshSources() }
  }

  private func containsNativeProjection(for request: Request) -> Bool {
    #if os(iOS)
      guard let published else { return false }
      return published.nativeInk.containsProjectionWindows(presence: request.presence,
        frame: request.frame, refinesDetails: request.refinesDetails)
    #else
      return true
    #endif
  }

  private func refreshSources() {
    guard !stopped, let request = lastRequest, request.permitsPreparation() else { return }
    prepare(request)
  }

  private func refineAfterAdmission() {
    guard !stopped, let request = lastRequest, request.permitsPreparation(), request.refinesDetails else { return }
    if resumeRetiredRuntimeCapturesIfAdmitted() { prepare(request); return }
    let current = resources.rasterAdmission
    if let previous = lastRefinementAdmission {
      let previousBytes = min(previous.byteLimit - previous.heldBytes,
        previous.passiveByteLimit - previous.pinnedBytes - previous.passiveReservedBytes)
      let currentBytes = min(current.byteLimit - current.heldBytes,
        current.passiveByteLimit - current.pinnedBytes - current.passiveReservedBytes)
      guard currentBytes > previousBytes
        || current.countLimit - current.pinnedCount - current.reservedCount
          > previous.countLimit - previous.pinnedCount - previous.reservedCount else { return }
    }
    for (address, failed) in sourceFailures where failed.1 == SceneRenderError.resourceLimit.description {
      sourceFailures[address] = nil
      dirtySources.insert(address)
    }
    let needsNativeRefinement = !containsNativeProjection(for: request)
    if hasQualityDebt || !dirtySources.isEmpty || needsNativeRefinement { prepare(request) }
  }

  @discardableResult
  private func resumeRetiredRuntimeCapturesIfAdmitted() -> Bool {
    let admission = resources.rasterAdmission
    var resumed = false
    for (address, runtime) in runtimeSources where !runtime.isMounted {
      guard runtime.failure?.canResumeCapture(with: admission) == true else { continue }
      // The failed demand and admission baseline belong to the physical source,
      // so consumer remounts cannot lose its stationary refinement wake-up.
      runtimeSources[address] = nil
      runtimeSourceGeneration &+= 1
      dirtySources.insert(address)
      resumed = true
    }
    return resumed
  }

  func retrySource(_ address: SceneSourceAddress) {
    let staticFailure = sourceFailures.removeValue(forKey: address) != nil
    let runtimeFailure = runtimeSources[address]?.failure != nil
    guard staticFailure || runtimeFailure else { return }
    if runtimeFailure {
      runtimeSources[address] = nil
      runtimeSourceGeneration &+= 1
    }
    dirtySources.insert(address); refreshSources()
  }

  func cancelPreparation() {
    requestID = UUID(); task?.cancel(); task = nil
    preparingRequest = nil; pendingRequest = nil; isPreparing = !sourceJobs.isEmpty
  }
  func removePublishedCoverage() {
    cancelPreparation(); published = nil; lastRequest = nil
    for job in sourceJobs.values { job.task.cancel() }
    sourceJobs.removeAll(); preparedSources.removeAll(); sourceFailures.removeAll(); runtimeSources.removeAll(); dirtySources.removeAll()
    runtimeSourceGeneration &+= 1
    hasQualityDebt = false; isPreparing = false
  }

  /// Cancellation revokes publication immediately, but submitted GPU/read work
  /// keeps its leases until completion. Shutdown waits for superseded jobs too.
  func stop() async {
    stopped = true
    let pending = Array(inFlight.values) + Array(sourceWork.values)
    cancelPreparation()
    for task in pending { task.cancel() }
    for task in pending { await task.value }
    sourceJobs.removeAll(); sourceWork.removeAll(); preparedSources.removeAll()
    if let resourceObserver { NotificationCenter.default.removeObserver(resourceObserver) }
    if let admissionObserver { NotificationCenter.default.removeObserver(admissionObserver) }
    resourceObserver = nil; admissionObserver = nil
    #if os(iOS)
      await surfaceRegistry.stopSceneInk()
    #endif
    removePublishedCoverage()
  }

  enum BudgetAllocation: Sendable { case raster, nativeInk }
  struct BudgetFailure: Sendable {
    let phase: String
    let allocation: BudgetAllocation
    let attempt: Int
    let liveOwners: Int
    let nativeOwners: Int
    let tiles: Int
    let requestedBytes: Int
    let admission: SceneRasterAdmission
  }
  private(set) var budgetFailures: [BudgetFailure] = []
  private func recordBudgetFailure(phase: String, allocation: BudgetAllocation = .raster,
    plan: SceneCompositionPlan, attempt: Int,
    requestedBytes: Int, admission: SceneRasterAdmission) {
    guard budgetFailures.count <= SceneCompositionPlan.maximumLiveOwners + SceneCompositionPlan.maximumTiles else { return }
    budgetFailures.append(.init(phase: phase, allocation: allocation, attempt: attempt,
      liveOwners: plan.liveOwners.count, nativeOwners: plan.nativeOwnerCount,
      tiles: plan.tiles.count, requestedBytes: requestedBytes, admission: admission))
    print("SCENE_COMPOSITION_BUDGET phase=\(phase) attempt=\(attempt) live=\(plan.liveOwners.count) tiles=\(plan.tiles.count) requested=\(requestedBytes) pinned=\(admission.pinnedBytes) reserved=\(admission.reservedBytes) limit=\(admission.byteLimit) passiveReserved=\(admission.passiveReservedBytes) passiveLimit=\(admission.passiveByteLimit)")
  }

  @MainActor
  private struct RasterBorrow {
    let tiles: [SceneCompositionTileKey: RasterLease]
    let live: [SceneCompositionLiveOwner: RasterLease]
    let admission: SceneRasterAdmission
    let additionalBytes: Int
    let additionalCount: Int
    func prepareAdmission(_ resources: SceneRenderResources) -> Bool {
      // Old mounted fragments are already charged by their leases. Reserve
      // this replacement and its real scratch, not a speculative second copy
      // of every unrelated source in the scene.
      resources.prepareRasterAdmission(additionalBytes: additionalBytes, additionalCount: additionalCount)
    }
    func release() {
      for raster in tiles.values { raster.release() }
      for raster in live.values { raster.release() }
    }
  }

  private static func borrowRasters(plan: SceneCompositionPlan,
    requests: [SceneCompositionRenderer.LiveRasterRequest], previous: SceneCompositionCohort?,
    canCarry: Bool, resources: SceneRenderResources,
    invalidatedTiles: Set<SceneCompositionTileKey> = []) throws -> RasterBorrow {
    var tiles: [SceneCompositionTileKey: RasterLease] = [:]
    var live: [SceneCompositionLiveOwner: RasterLease] = [:]
    var additional = 0, count = 0, extra = 0
    do {
      for request in requests {
        if let hit = resources.retainRaster(for: request.demand.rasterSource, minimumScale: request.requestedScale) {
          live[request.owner] = hit
        }
        else {
          additional = try sumBytes(additional, request.residentBytes); count += 1
          extra = max(extra, request.snapshotAdditionalBytes)
        }
      }
      for key in plan.tiles {
        if !invalidatedTiles.contains(key), canCarry, let previous, let old = previous.rasters.first(where: { $0.key.hasSamePaintWindow(as: key) })?.value,
          !old.isReleased, let hit = old.retainedCopy() { tiles[key] = hit }
        else if !invalidatedTiles.contains(key), let hit = resources.retainComposition(key, accepts: { receipts in
          receipts.allSatisfy { address, receipt in
            guard let view = plan.presentations[.board(address.plane.boardID)] else { return false }
            let density = plan.requiredPixelDensity[address.plane] ?? 0
            return receipt.installedScale + 0.000_001 >= density
              && receipt.coversVisibleWindow(in: view, pixelDensity: density, refinesDetails: true)
          }
        }) { tiles[key] = hit }
        else {
          guard let bytes = SceneRenderResources.estimatedRasterBytes(pixelWidth: key.pixelSize, pixelHeight: key.pixelSize)
          else { throw SceneRenderError.resourceLimit }
          additional = try sumBytes(additional, bytes); count += 1
        }
      }
      if !plan.tiles.isEmpty {
        // Artwork is clipped to the output grid. Static WebKit and ink can
        // require more; their real per-allocation grants remain authoritative.
        // Optional disk-cache scratch is not required to render a cold tile.
        let side = (plan.tiles.map(\.pixelSize).max() ?? CompositionTile.pixelSize) + 2
        guard let artwork = SceneRenderResources.estimatedRasterBytes(pixelWidth: side, pixelHeight: side)
        else { throw SceneRenderError.resourceLimit }
        if tiles.count < plan.tiles.count { extra = max(extra, artwork) }
      }
      return .init(tiles: tiles, live: live, admission: resources.rasterAdmission,
        additionalBytes: try sumBytes(additional, extra), additionalCount: count + (extra > 0 ? 1 : 0))
    } catch {
      for raster in tiles.values { raster.release() }; for raster in live.values { raster.release() }
      throw error
    }
  }

  private static func sumBytes(_ left: Int, _ right: Int) throws -> Int {
    let sum = left.addingReportingOverflow(right)
    guard !sum.overflow else { throw SceneRenderError.resourceLimit }
    return sum.partialValue
  }

  private static func lowerCostPlan(_ plan: SceneCompositionPlan, allocation: BudgetAllocation,
    requests: [SceneCompositionRenderer.LiveRasterRequest], previous: SceneCompositionCohort?,
    presence: SessionPresence, frame: WorkspaceSceneFrame, displayScale: Double,
    resources: SceneRenderResources) throws -> SceneCompositionPlan? {
    if allocation == .nativeInk {
      return try plan.reducingNativeOwners(presence: presence, frame: frame, displayScale: displayScale)
    }
    // Passive overview density yields before a physical input owner. Flattening
    // a cover first would remove its native gestures and accessibility even
    // when a complete, slightly coarser background leaves room for both.
    if let coarse = try plan.coarseningCoverage(presence: presence, frame: frame, displayScale: displayScale) {
      return coarse
    }
    var best: SceneCompositionPlan?, bestCost = Int.max
    let candidates = plan.vectorRuns.map { $0.owners[0] } + plan.liveOwners
    for owner in candidates where !plan.protectedOwners.contains(owner) {
      guard let candidate = try plan.demoting(owner, presence: presence, frame: frame, displayScale: displayScale) else { continue }
      let selected = requests.filter { candidate.liveOwners.contains($0.owner) }
      // Cross-revision carry is checked after selecting the smaller plan. This
      // local comparison never grants credit for an unvalidated old source.
      let borrowed = try borrowRasters(plan: candidate, requests: selected, previous: previous,
        canCarry: previous?.plan.revision == candidate.revision, resources: resources)
      let cost = try sumBytes(borrowed.admission.heldBytes, borrowed.additionalBytes)
      borrowed.release()
      if cost < bestCost { best = candidate; bestCost = cost }
    }
    return best
  }

  private static func covers(_ plan: SceneCompositionPlan, presence: SessionPresence,
    pinned: Set<WorkspaceSpatialID>, refinesDetails: Bool) -> Bool {
    let plane = SceneCompositionPlane.board(presence.boardID)
    guard plan.rootBoardID == presence.boardID, let basis = plan.presentations[plane],
      basis.mode == presence.mode, basis.focusedItemID == presence.focusedItemID, basis.viewport == presence.viewport,
      // Minification cannot exhaust pixel density. During contact, only new
      // spatial coverage or magnification warrants another cohort; after lift
      // the normal lower LOD bound can reclaim unnecessarily dense backing.
      (refinesDetails ? ((0.6...1).contains(presence.camera.scale / basis.camera.scale) && plan.meetsRequiredDensity)
        : (presence.camera.scale > 0 && presence.camera.scale / basis.camera.scale <= sqrt(2.0))),
      // Existing pixels do not grant a newly focused owner protection from
      // budget-driven demotion. Reuse only after that input demand is installed.
      pinned.allSatisfy({ pin in plan.protectedOwners.contains { $0.id == pin } }), let tiles = plan.coverage[plane]?.tiles,
      let first = tiles.first, let last = tiles.last else { return false }
    let visible = WorkspaceSpatialBounds(origin: presence.camera.screenToWorld(.zero, viewport: presence.viewport),
      width: presence.viewport.x / presence.camera.scale, height: presence.viewport.y / presence.camera.scale)
    return WorkspaceSpatialBounds(origin: first.origin, maximum: last.bounds.maximum).contains(visible)
  }
  isolated deinit {
    for task in inFlight.values { task.cancel() }
    for task in sourceWork.values { task.cancel() }
    if let resourceObserver { NotificationCenter.default.removeObserver(resourceObserver) }
    if let admissionObserver { NotificationCenter.default.removeObserver(admissionObserver) }
  }
}

/// Place each band next to its live owners in the SAME ZStack/SceneCameraPlane:
/// `.zIndex(Double(band.rank))` and `plan.rank(id:in:)` define their interleaving.
/// This view never mounts WebKit, reconstructs a source or handles a contact.
struct SceneCompositionTileBandView: View, Identifiable {
  let id: SceneCompositionBand.SelfID
  let rank: Int
  private struct Tile: Identifiable {
    let id: SceneCompositionTileKey
    let frame: CGRect
    weak var raster: RasterLease?
    weak var cohort: SceneCompositionCohort?
  }
  private let tiles: [Tile]

  init(cohort: SceneCompositionCohort, band: SceneCompositionBand, presence: SessionPresence) {
    id = band.id; rank = band.rank
    tiles = cohort.plan.tiles.filter { $0.plane == band.plane && $0.range == band.range }.map { key in
      let rect: CGRect
      if band.plane.coverID != nil {
        let delta = WorldPoint.zero.delta(to: key.tile.origin)
        rect = .init(x: delta.x, y: delta.y, width: key.tile.worldSize, height: key.tile.worldSize)
      } else {
        let screen = presence.camera.worldToScreen(key.tile.origin, viewport: presence.viewport)
        rect = .init(x: screen.x, y: screen.y,
          width: key.tile.worldSize * presence.camera.scale, height: key.tile.worldSize * presence.camera.scale)
      }
      return Tile(id: key, frame: rect, raster: cohort.rasters[key], cohort: cohort)
    }
  }

  /// Resolve the finite presentation before handing values to an escaping
  /// SwiftUI ForEach. Its cached content closure must not own the whole cohort.
  static func bands(in cohort: SceneCompositionCohort, plane: SceneCompositionPlane,
    layer: ScenePaintPosition.Layer, presence: SessionPresence) -> [Self] {
    cohort.bands(in: plane, layer: layer).map { .init(cohort: cohort, band: $0, presence: presence) }
  }

  var body: some View {
    ForEach(tiles) { tile in
      SceneCompositionTileRasterView(raster: tile.raster, onMounted: { [weak cohort = tile.cohort] view in
        guard let cohort else { return }
        cohort.tilePresenters.register(view, key: tile.id, cohort: cohort)
      }, onInstalled: { [weak cohort = tile.cohort] installation in
        cohort?.didInstallTile(tile.id, installation: installation)
      })
        .frame(width: tile.frame.width, height: tile.frame.height)
        .position(x: tile.frame.midX, y: tile.frame.midY)
        .allowsHitTesting(false).accessibilityHidden(true)
    }
  }
}

#if os(iOS)
private struct SceneCompositionTileRasterView: UIViewRepresentable {
  @Environment(NotebookAppModel.self) private var model: NotebookAppModel?
  weak var raster: RasterLease?
  let onMounted: (AgentSnapshotRasterView) -> Void
  let onInstalled: (SceneSourceInstallation) -> Void
  func makeUIView(context: Context) -> AgentSnapshotRasterView { .init() }
  func updateUIView(_ view: AgentSnapshotRasterView, context: Context) {
    view.bindSceneLifecycle(to: model)
    onMounted(view)
    view.onRasterInstalled = { [weak view] raster in
      // Overscan fragments are mounted outside the viewport intentionally.
      // Their native owner still must exist and keep exactly these bytes.
      if let view { onInstalled(view.installation(for: raster, requiresVisibility: false)) }
    }
    guard let raster, !raster.isReleased else { return }
    view.updateRaster(raster)
  }
  static func dismantleUIView(_ view: AgentSnapshotRasterView, coordinator: ()) { view.uninstall() }
}
#else
private struct SceneCompositionTileRasterView: NSViewRepresentable {
  @Environment(NotebookAppModel.self) private var model: NotebookAppModel?
  weak var raster: RasterLease?
  let onMounted: (AgentSnapshotRasterView) -> Void
  let onInstalled: (SceneSourceInstallation) -> Void
  func makeNSView(context: Context) -> AgentSnapshotRasterView { .init() }
  func updateNSView(_ view: AgentSnapshotRasterView, context: Context) {
    view.bindSceneLifecycle(to: model)
    onMounted(view)
    view.onRasterInstalled = { [weak view] raster in
      // Overscan fragments are mounted outside the viewport intentionally.
      // Their native owner still must exist and keep exactly these bytes.
      if let view { onInstalled(view.installation(for: raster, requiresVisibility: false)) }
    }
    guard let raster, !raster.isReleased else { return }
    view.updateRaster(raster)
  }
  static func dismantleNSView(_ view: AgentSnapshotRasterView, coordinator: ()) { view.uninstall() }
}
#endif

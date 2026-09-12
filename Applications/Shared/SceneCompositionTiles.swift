import CoreGraphics
import CryptoKit
import Foundation
import NotebookCore
import Observation
import SwiftUI

enum SceneCompositionPlane: Hashable, Codable, Sendable {
  case board(UUID)
  case cover(boardID: UUID, itemID: UUID)
  var boardID: UUID { switch self { case .board(let id), .cover(let id, _): id } }
  var coverID: UUID? { if case .cover(_, let id) = self { return id }; return nil }
}

struct SceneCompositionTileKey: Hashable, Codable, Sendable {
  let workspaceID: UUID
  let revision: UInt64
  let plane: SceneCompositionPlane
  let tile: CompositionTile
  let range: ScenePaintRange
  let presentationScale: Double
  let viewportWidth: Double
  let viewportHeight: Double
  let focusedItemID: UUID?
  let mode: String
  func atRevision(_ revision: UInt64) -> Self {
    .init(workspaceID: workspaceID, revision: revision, plane: plane, tile: tile, range: range,
      presentationScale: presentationScale, viewportWidth: viewportWidth, viewportHeight: viewportHeight,
      focusedItemID: focusedItemID, mode: mode)
  }
}

struct SceneCompositionLiveOwner: Hashable, Sendable {
  let plane: SceneCompositionPlane
  let id: WorkspaceSpatialID
  let position: ScenePaintPosition
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
  static let maximumLiveOwners = 8
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
  var primitiveCount: Int { tiles.count + liveOwners.count + inkBoardIDs.count }
  /// Every resource retry removes an optional owner or a static tile. Keeping
  /// this integer strictly decreasing bounds preparation without a timer retry.
  private var coverageTileCount: Int {
    bands.reduce(0) { $0 + (coverage[$1.plane]?.tiles.count ?? 0) }
  }
  var reductionPotential: Int { liveOwners.count - protectedOwners.count + coverageTileCount }
  var nativeOwnerCount: Int {
    inkBoardIDs.count + liveOwners.filter { if case .item = $0.id { return true }; return false }.count
  }

  func rank(id: WorkspaceSpatialID, in plane: SceneCompositionPlane) -> Double? {
    guard let owner = liveOwners.first(where: { $0.id == id && $0.plane == plane }) else { return nil }
    let peers = liveOwners.filter { $0.plane == plane && $0.position.layer == owner.position.layer }.sorted { $0.position < $1.position }
    return peers.firstIndex(of: owner).map { Double($0 * 2 + 1) }
  }
  func allowsLive(_ id: WorkspaceSpatialID, in plane: SceneCompositionPlane) -> Bool { rank(id: id, in: plane) != nil }

  /// Coverage and painter boundaries remain intact even where this exact
  /// source revision proves transparent pixels need no backing allocation.
  func removingEmptyTiles(source: SceneCompositionSource) async throws -> Self {
    guard source.revision == revision, source.workspaceID == workspaceID else {
      throw NotebookStorageError.transactionConflict
    }
    let populated = try await source.tilesRequiringPaint(tiles)
    return .init(revision: revision, workspaceID: workspaceID, rootBoardID: rootBoardID,
      inkBoardIDs: inkBoardIDs, liveOwners: liveOwners, protectedOwners: protectedOwners,
      bands: bands, coverage: coverage, presentations: presentations, tiles: populated)
  }

  static func prepare(source: SceneCompositionSource, presence: SessionPresence, frame: WorkspaceSceneFrame,
    pinned: Set<WorkspaceSpatialID>, displayScale: Double, previous: Self?) async throws -> Self {
    var pinned = pinned
    if let id = presence.focusedItemID { pinned.insert(.item(id)) }
    if frame.returnBoardID != nil { pinned.insert(.item(presence.boardID)) }
    guard displayScale.isFinite, displayScale > 0, frame.rootBoardID == presence.boardID else { throw SceneRenderError.resourceLimit }
    // Board ink retains the current Pencil owner even when it is still empty.
    guard pinned.count < maximumLiveOwners else { throw SceneRenderError.snapshotPending("live_owner_budget") }
    var candidates: [(plane: SceneCompositionPlane, id: WorkspaceSpatialID, pinned: Bool)] = []
    let boardIDs = [presence.boardID] + frame.worksets.keys.filter { $0 != presence.boardID }.sorted { $0.uuidString < $1.uuidString }
    for boardID in boardIDs {
      guard let workset = frame.worksets[boardID] else { continue }
      for item in workset.items {
        // A live portal must already own its child's physical plane. Otherwise
        // the streaming painter renders the whole portal, never a placeholder.
        guard item.item.kind != .board || frame.presences[item.id] != nil else { continue }
        candidates.append((.board(boardID), .item(item.id), pinned.contains(.item(item.id))))
      }
      for element in workset.elements { candidates.append((.board(boardID), .element(element.id), pinned.contains(.element(element.id)))) }
    }
    // A pin on cover contents pins its physical carrier, then its local element.
    for (itemID, workset) in frame.covers {
      guard let boardID = frame.worksets.first(where: { $0.value.items.contains(where: { $0.id == itemID }) })?.key else { continue }
      for element in workset.elements where pinned.contains(.element(element.id)) {
        candidates.append((.cover(boardID: boardID, itemID: itemID), .element(element.id), true))
        if let index = candidates.firstIndex(where: { $0.id == .item(itemID) }) { candidates[index].pinned = true }
      }
    }
    guard pinned.allSatisfy({ pin in candidates.contains { $0.id == pin } }) else { throw SceneRenderError.snapshotPending("pinned_owner_source") }
    candidates.sort { left, right in
      if left.pinned != right.pinned { return left.pinned }
      if (left.plane.boardID == presence.boardID) != (right.plane.boardID == presence.boardID) { return left.plane.boardID == presence.boardID }
      return String(describing: left.id) < String(describing: right.id)
    }
    guard candidates.filter(\.pinned).count < maximumLiveOwners else { throw SceneRenderError.snapshotPending("live_owner_budget") }
    var owners: [SceneCompositionLiveOwner] = []
    for candidate in candidates.prefix(maximumLiveOwners - 1) {
      guard let position = try await source.position(id: candidate.id, boardID: candidate.plane.boardID, coverID: candidate.plane.coverID) else {
        throw SceneRenderError.snapshotPending("live_owner_source")
      }
      owners.append(.init(plane: candidate.plane, id: candidate.id, position: position))
    }
    let protected = Set(owners.filter { owner in
      candidates.contains { $0.pinned && $0.id == owner.id && $0.plane == owner.plane }
    })
    while true {
      do {
        return try assemble(revision: source.revision, workspaceID: source.workspaceID, owners: owners, presence: presence,
          frame: frame, pinned: pinned, protected: protected, displayScale: displayScale, previous: previous)
      } catch {
        guard let index = owners.lastIndex(where: { !protected.contains($0) }) else { throw error }
        owners.remove(at: index)
      }
    }
  }

  /// Removing an optional physical owner puts its exact painter position back
  /// into a static range. Mandatory pins, their carriers and the return aperture
  /// survive every reassembly; source values are never discarded as a shortcut.
  func demoting(_ owner: SceneCompositionLiveOwner, presence: SessionPresence,
    frame: WorkspaceSceneFrame, displayScale: Double) throws -> Self? {
    guard liveOwners.contains(owner), !protectedOwners.contains(owner) else { return nil }
    do {
      let result = try Self.assemble(revision: revision, workspaceID: workspaceID,
        owners: liveOwners.filter { $0 != owner }, presence: presence, frame: frame,
        pinned: Set(protectedOwners.map(\.id)), protected: protectedOwners,
        displayScale: displayScale, previous: self, preservesCoverageDensity: true)
      guard result.reductionPotential < reductionPotential else { return nil }
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
        displayScale: displayScale, previous: self, preservesCoverageDensity: true,
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
    preservesCoverageDensity: Bool = false, tileAllowance: Int = maximumTiles) throws -> Self {
    guard (1...maximumTiles).contains(tileAllowance) else { throw SceneRenderError.resourceLimit }
    var owners = requestedOwners
    var presentations: [SceneCompositionPlane: SessionPresence] = [:]
    var bounds: [SceneCompositionPlane: WorkspaceSpatialBounds] = [:]
    var density: [SceneCompositionPlane: Double] = [:]
    // A child projection exists only inside a retained live portal. Other
    // portals are recursively flattened by the same static cover renderer.
    var includedBoards: Set<UUID> = [presence.boardID]
    if let parent = frame.returnBoardID { includedBoards.insert(parent) }
    var changed = true
    while changed {
      changed = false
      for owner in owners where includedBoards.contains(owner.plane.boardID) {
        guard case .item(let id) = owner.id, frame.presences[id] != nil else { continue }
        if includedBoards.insert(id).inserted { changed = true }
      }
    }
    owners.removeAll { !includedBoards.contains($0.plane.boardID) }
    guard pinned.allSatisfy({ pin in owners.contains { $0.id == pin } }), protected.isSubset(of: Set(owners))
    else { throw SceneRenderError.snapshotPending("pinned_owner_projection") }
    #if os(iOS)
      let inkBoardIDs = includedBoards
    #else
      // The headless Mac painter has no UIKit mount registry. Its passive
      // planes retain the ordinary source-ink bands; exact PNG export also
      // continues through SceneCompositionRenderer.paintInk independently.
      let inkBoardIDs: Set<UUID> = [presence.boardID]
    #endif
    guard owners.count + inkBoardIDs.count <= maximumLiveOwners else {
      throw SceneRenderError.snapshotPending("live_owner_budget")
    }
    for boardID in includedBoards {
      guard let view = frame.presences[boardID] else { throw SceneRenderError.snapshotPending("portal_projection") }
      let plane = SceneCompositionPlane.board(boardID)
      presentations[plane] = view
      let margin = 96.0
      bounds[plane] = boardID == frame.returnBoardID ? SceneCompositionSource.returnBounds(view)
        : .init(origin: view.camera.screenToWorld(.init(x: -margin, y: -margin), viewport: view.viewport),
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
        let positions = owners.filter { $0.plane == plane && $0.position.layer == layer }.map(\.position).sorted()
        for index in 0...positions.count {
          bands.append(.init(plane: plane, range: .init(layer: layer,
            lower: index == 0 ? nil : positions[index - 1], upper: index == positions.count ? nil : positions[index]), rank: index * 2))
        }
      }
    }
    guard bands.count <= maximumTiles else { throw SceneRenderError.snapshotPending("composition_band_budget") }
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
    guard minimumCost.values.reduce(0, +) <= tileAllowance else { throw SceneRenderError.resourceLimit }
    var remaining = tileAllowance
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
    guard tiles.count <= maximumTiles, tiles.count + owners.count + inkBoardIDs.count <= maximumPrimitives else { throw SceneRenderError.resourceLimit }
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
      coverage: coverage, presentations: presentations, tiles: tiles)
  }
}

@MainActor
final class SceneCompositionCohort {
  let id = UUID()
  let plan: SceneCompositionPlan
  let frame: WorkspaceSceneFrame
  let requestedSources: WorkspaceSceneFrame.SourceIdentity
  let liveData: SceneCompositionLiveData
  let rasters: [SceneCompositionTileKey: RasterLease]
  let liveRasters: [SceneCompositionLiveOwner: RasterLease]
  #if os(iOS)
    let nativeInk: SpatialInkSceneLease
    init(plan: SceneCompositionPlan, frame: WorkspaceSceneFrame, requestedSources: WorkspaceSceneFrame.SourceIdentity,
      liveData: SceneCompositionLiveData, rasters: [SceneCompositionTileKey: RasterLease],
      liveRasters: [SceneCompositionLiveOwner: RasterLease], nativeInk: SpatialInkSceneLease) {
      self.plan = plan; self.frame = frame; self.liveData = liveData; self.rasters = rasters
      self.requestedSources = requestedSources; self.liveRasters = liveRasters; self.nativeInk = nativeInk
    }
  #else
  init(plan: SceneCompositionPlan, frame: WorkspaceSceneFrame, requestedSources: WorkspaceSceneFrame.SourceIdentity? = nil,
    liveData: SceneCompositionLiveData,
    rasters: [SceneCompositionTileKey: RasterLease], liveRasters: [SceneCompositionLiveOwner: RasterLease]) {
    self.plan = plan; self.frame = frame; self.liveData = liveData; self.rasters = rasters
    self.requestedSources = requestedSources ?? frame.sourceIdentity
    self.liveRasters = liveRasters
  }
  #endif
  func bands(in plane: SceneCompositionPlane, layer: ScenePaintPosition.Layer) -> [SceneCompositionBand] {
    plan.bands.filter { $0.plane == plane && $0.range.layer == layer }
  }
  isolated deinit {
    for raster in rasters.values { raster.release() }
    for raster in liveRasters.values { raster.release() }
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
  private let diskCache: SceneCompositionTileCache?
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var inFlight: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var stopped = false
  @ObservationIgnored private var requestID = UUID()
  @ObservationIgnored private var preparingPlan: SceneCompositionPlan?
  @ObservationIgnored private var preparingSources: WorkspaceSceneFrame.SourceIdentity?
  init(resources: SceneRenderResources = .shared, cacheRoot: URL? = nil,
    surfaceRegistry: SpatialInkSurfaceRegistry = .init()) {
    self.resources = resources; self.surfaceRegistry = surfaceRegistry
    diskCache = cacheRoot.map { SceneCompositionTileCache(root: $0) }
  }

  func prepare(source: SceneCompositionSource, presence: SessionPresence, frame: WorkspaceSceneFrame,
    pinned: Set<WorkspaceSpatialID>, displayScale: Double = 2,
    permitsPreparation: @escaping @MainActor () -> Bool = { true },
    onSourceInvalidated: @escaping @MainActor () -> Void = {}) {
    guard !stopped else { return }
    let sources = frame.sourceIdentity
    if let plan = published?.plan, published?.requestedSources == sources,
      plan.revision == source.revision, plan.workspaceID == source.workspaceID,
      Self.covers(plan, presence: presence, pinned: pinned) { return }
    if preparingSources == sources, let plan = preparingPlan,
      plan.revision == source.revision, plan.workspaceID == source.workspaceID,
      Self.covers(plan, presence: presence, pinned: pinned) { return }
    task?.cancel(); requestID = UUID()
    let id = requestID
    isPreparing = true; failure = nil; budgetFailures = []; preparingPlan = nil; preparingSources = sources
    task = Task { [weak self, resources, surfaceRegistry] in
      defer { self?.inFlight[id] = nil }
      var rasters: [SceneCompositionTileKey: RasterLease] = [:]
      var liveRasters: [SceneCompositionLiveOwner: RasterLease] = [:]
      let renderer = SceneCompositionRenderer(source: source, resources: resources,
        permitsPreparation: { [weak self] in self?.requestID == id && permitsPreparation() })
      defer { renderer.finishPreparation() }
      do {
        try Task.checkCancellation()
        guard self?.requestID == id, permitsPreparation() else { throw CancellationError() }
        let frame = try await source.compositionFrame(requested: frame, presence: presence, pinned: pinned)
        try Task.checkCancellation()
        guard self?.requestID == id, permitsPreparation() else { throw CancellationError() }
        var plan = try await SceneCompositionPlan.prepare(source: source, presence: presence, frame: frame,
          pinned: pinned, displayScale: displayScale, previous: self?.published?.plan)
        let requests = try await renderer.liveRasterRequests(plan: plan, frame: frame, displayScale: displayScale)
        let previous = self?.published
        let maximumAttempts = plan.reductionPotential + 1
        for attempt in 0..<maximumAttempts {
          try Task.checkCancellation()
          guard self?.requestID == id, permitsPreparation() else { throw CancellationError() }
          plan = try await plan.removingEmptyTiles(source: source)
          try Task.checkCancellation()
          guard self?.requestID == id, permitsPreparation() else { throw CancellationError() }
          self?.preparingPlan = plan
          var phase = "live_source"
          var allocation = BudgetAllocation.raster
          let priorRefusal = resources.lastRasterRefusal?.generation
          #if os(iOS)
            var nativeInk: SpatialInkSceneLease?
          #endif
          do {
            let liveData = try await source.liveData(plan: plan, presence: presence, frame: frame)
            let canCarry: Bool
            if let previous {
              canCarry = try await source.canCarryStaticPixels(from: previous.plan, liveData: previous.liveData,
                to: plan, liveData: liveData)
            } else { canCarry = false }
            try Task.checkCancellation()
            guard self?.requestID == id, permitsPreparation() else { throw CancellationError() }
            let selected = requests.filter { plan.liveOwners.contains($0.owner) }
            let borrowed = try Self.borrowRasters(plan: plan, requests: selected, previous: previous,
              canCarry: canCarry, resources: resources)
            rasters = borrowed.tiles; liveRasters = borrowed.live
            phase = "raster_preflight"
            guard borrowed.fits(borrowed.admission, profile: resources.profile) else {
              self?.recordBudgetFailure(phase: phase, plan: plan, attempt: attempt,
                requestedBytes: borrowed.additionalBytes, admission: borrowed.admission)
              throw SceneRenderError.resourceLimit
            }
            #if os(iOS)
              // Reject an already impossible raster candidate before creating
              // any new native canvases. Their real grants then join this same
              // pool, so recheck rather than treating the first read as credit.
              phase = "native_ink"
              allocation = .nativeInk
              nativeInk = try await surfaceRegistry.prepareSceneInk(plan: plan, frame: frame,
                liveData: liveData, resources: resources, displayScale: displayScale)
              phase = "raster_native_preflight"
              allocation = .raster
              let admission = resources.rasterAdmission
              guard borrowed.fits(admission, profile: resources.profile) else {
                self?.recordBudgetFailure(phase: phase, plan: plan, attempt: attempt,
                  requestedBytes: borrowed.additionalBytes, admission: admission)
                throw SceneRenderError.resourceLimit
              }
            #endif
            phase = "live_raster"
            liveRasters = try await renderer.prepareLiveRasters(selected, retained: liveRasters)
            for key in plan.tiles where rasters[key] == nil {
              try Task.checkCancellation()
              guard self?.requestID == id, permitsPreparation(), let presentation = plan.presentations[key.plane]
              else { throw CancellationError() }
              phase = "tile:\(key.plane):\(key.range.layer.rawValue):\(key.tile.level):\(key.tile.column):\(key.tile.row):\(key.tile.localColumn):\(key.tile.localRow)"
              if let raster = try await self?.loadCached(key) { rasters[key] = raster }
              else {
                let raster = try await renderer.renderTile(key: key, presentation: presentation)
                rasters[key] = raster
                await self?.saveCached(raster, key: key)
              }
            }
            try await source.validate(); try Task.checkCancellation()
            guard self?.requestID == id, permitsPreparation(), rasters.count == plan.tiles.count else { throw CancellationError() }
            // No await separates the validated native source installation and
            // the matching static publication. Mounted old leases retain their
            // actual owners until the old view, not just this field, lets go.
            #if os(iOS)
              guard let nativeInk else { throw SceneRenderError.snapshotPending("native_ink_preparation") }
              try nativeInk.install()
              self?.published = .init(plan: plan, frame: frame, requestedSources: sources,
                liveData: liveData, rasters: rasters, liveRasters: liveRasters, nativeInk: nativeInk)
            #else
              self?.published = .init(plan: plan, frame: frame, requestedSources: sources,
                liveData: liveData, rasters: rasters, liveRasters: liveRasters)
            #endif
            rasters.removeAll(); liveRasters.removeAll()
            self?.isPreparing = false; self?.preparingPlan = nil; self?.preparingSources = nil; self?.task = nil
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
            plan = smaller
          }
        }
        throw SceneRenderError.resourceLimit
      } catch {
        for raster in rasters.values { raster.release() }
        for raster in liveRasters.values { raster.release() }
        try? await renderer.finishPreparationAndDrain()
        guard self?.requestID == id else { return }
        self?.isPreparing = false; self?.preparingPlan = nil; self?.preparingSources = nil; self?.task = nil
        if case NotebookStorageError.transactionConflict = error {
          // The writer advanced while this candidate was being prepared.
          // Ask the model for the new read cut; waiting for camera movement
          // would strand an already saved edit behind the previous picture.
          onSourceInvalidated()
        } else if !(error is CancellationError) { self?.failure = String(describing: error) }
      }
    }
    inFlight[id] = task
  }

  func cancelPreparation() {
    requestID = UUID(); task?.cancel(); task = nil; preparingPlan = nil; preparingSources = nil; isPreparing = false
  }
  func removePublishedCoverage() { cancelPreparation(); published = nil }

  /// Cancellation revokes publication immediately, but submitted GPU/read work
  /// keeps its leases until completion. Shutdown waits for superseded jobs too.
  func stop() async {
    stopped = true
    let pending = Array(inFlight.values)
    cancelPreparation()
    for task in pending { task.cancel() }
    for task in pending { await task.value }
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
    let outputBytes: Int
    let replacementScratch: Int
    func fits(_ admission: SceneRasterAdmission, profile: SceneResourceProfile) -> Bool {
      guard admission.fits(additionalBytes: additionalBytes, additionalCount: additionalCount) else { return false }
      guard profile == .interactive else { return true }
      // Publishing a cold dense cut must not consume the space needed for
      // its next whole revision. This is a planner bound in the same ledger,
      // not a speculative allocation or permission to borrow the input half.
      let passive = admission.passiveByteLimit - admission.passiveReservedBytes
      let total = admission.byteLimit - admission.reservedBytes
      let available = min(passive, total)
      guard replacementScratch <= available else { return false }
      return outputBytes <= (available - replacementScratch) / 2
    }
    func release() {
      for raster in tiles.values { raster.release() }
      for raster in live.values { raster.release() }
    }
  }

  private static func borrowRasters(plan: SceneCompositionPlan,
    requests: [SceneCompositionRenderer.LiveRasterRequest], previous: SceneCompositionCohort?,
    canCarry: Bool, resources: SceneRenderResources) throws -> RasterBorrow {
    var tiles: [SceneCompositionTileKey: RasterLease] = [:]
    var live: [SceneCompositionLiveOwner: RasterLease] = [:]
    var additional = 0, count = 0, extra = 0, output = 0, replacementScratch = 0
    var retainedEntries: Set<UUID> = []
    do {
      for request in requests {
        replacementScratch = max(replacementScratch, request.snapshotAdditionalBytes)
        if let hit = resources.retainRaster(for: request.source, minimumScale: request.requestedScale) {
          live[request.owner] = hit
          if retainedEntries.insert(hit.entryID).inserted { output = try sumBytes(output, hit.accountedByteCount) }
        }
        else {
          additional = try sumBytes(additional, request.residentBytes); count += 1
          output = try sumBytes(output, request.residentBytes)
          extra = max(extra, request.snapshotAdditionalBytes)
        }
      }
      for key in plan.tiles {
        if let hit = resources.retainRaster(for: .composition(key)) { tiles[key] = hit }
        else if canCarry, let previous, let old = previous.rasters[key.atRevision(previous.plan.revision)],
          !old.isReleased, let hit = old.retainedCopy() { tiles[key] = hit }
        else {
          guard let bytes = SceneRenderResources.estimatedRasterBytes(pixelWidth: 512, pixelHeight: 512)
          else { throw SceneRenderError.resourceLimit }
          additional = try sumBytes(additional, bytes); count += 1
          output = try sumBytes(output, bytes)
        }
        if let hit = tiles[key], retainedEntries.insert(hit.entryID).inserted { output = try sumBytes(output, hit.accountedByteCount) }
      }
      if !plan.tiles.isEmpty {
        // Artwork is clipped to the output grid. Static WebKit and ink can
        // require more; their real per-allocation grants remain authoritative.
        // Optional disk-cache scratch is not required to render a cold tile.
        guard let artwork = SceneRenderResources.estimatedRasterBytes(pixelWidth: 514, pixelHeight: 514)
        else { throw SceneRenderError.resourceLimit }
        replacementScratch = max(replacementScratch, artwork)
        if tiles.count < plan.tiles.count { extra = max(extra, artwork) }
      }
      return .init(tiles: tiles, live: live, admission: resources.rasterAdmission,
        additionalBytes: try sumBytes(additional, extra), additionalCount: count + (extra > 0 ? 1 : 0),
        outputBytes: output, replacementScratch: replacementScratch)
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
    for owner in plan.liveOwners where !plan.protectedOwners.contains(owner) {
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

  private func loadCached(_ key: SceneCompositionTileKey) async throws -> RasterLease? {
    guard let diskCache, try await diskCache.hasRecord(key) else { return nil }
    try Task.checkCancellation()
    guard let allocation = resources.reserveRaster(pixelWidth: 512, pixelHeight: 512, backingCount: 4) else { return nil }
    defer { allocation.release() }
    guard let temporary = resources.reserveDerivedBytes(8 * 1_024 * 1_024, priority: .passive) else { return nil }
    defer { temporary.release() }
    guard let pixels = try await diskCache.load(key) else { return nil }
    try Task.checkCancellation()
    #if os(iOS)
      let image = UIImage(cgImage: pixels, scale: 1, orientation: .up)
    #else
      let image = NSImage(cgImage: pixels, size: .init(width: pixels.width, height: pixels.height))
    #endif
    guard resources.store(image, for: .composition(key), reservation: allocation),
      let raster = resources.retainRaster(for: .composition(key)) else { throw SceneRenderError.resourceLimit }
    return raster
  }
  private func saveCached(_ raster: RasterLease, key: SceneCompositionTileKey) async {
    guard let diskCache, !raster.isReleased,
      let temporary = resources.reserveDerivedBytes(8 * 1_024 * 1_024, priority: .passive) else { return }
    defer { temporary.release() }
    #if os(iOS)
      let image = raster.image.cgImage
    #else
      let image = raster.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    #endif
    if let image { try? await diskCache.store(image, for: key) }
  }

  private static func covers(_ plan: SceneCompositionPlan, presence: SessionPresence, pinned: Set<WorkspaceSpatialID>) -> Bool {
    let plane = SceneCompositionPlane.board(presence.boardID)
    guard plan.rootBoardID == presence.boardID, let basis = plan.presentations[plane],
      basis.mode == presence.mode, basis.focusedItemID == presence.focusedItemID, basis.viewport == presence.viewport,
      (0.6...1.6).contains(presence.camera.scale / basis.camera.scale),
      pinned.allSatisfy({ pin in plan.liveOwners.contains { $0.id == pin } }), let tiles = plan.coverage[plane]?.tiles,
      let first = tiles.first, let last = tiles.last else { return false }
    let visible = WorkspaceSpatialBounds(origin: presence.camera.screenToWorld(.zero, viewport: presence.viewport),
      width: presence.viewport.x / presence.camera.scale, height: presence.viewport.y / presence.camera.scale)
    return WorkspaceSpatialBounds(origin: first.origin, maximum: last.bounds.maximum).contains(visible)
  }
  isolated deinit { for task in inFlight.values { task.cancel() } }
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
      return Tile(id: key, frame: rect, raster: cohort.rasters[key])
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
      SceneCompositionTileRasterView(raster: tile.raster)
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
  func makeUIView(context: Context) -> AgentSnapshotRasterView { .init() }
  func updateUIView(_ view: AgentSnapshotRasterView, context: Context) {
    view.bindSceneLifecycle(to: model)
    guard let raster, !raster.isReleased else { return }
    view.updateRaster(raster)
  }
  static func dismantleUIView(_ view: AgentSnapshotRasterView, coordinator: ()) { view.uninstall() }
}
#else
private struct SceneCompositionTileRasterView: NSViewRepresentable {
  @Environment(NotebookAppModel.self) private var model: NotebookAppModel?
  weak var raster: RasterLease?
  func makeNSView(context: Context) -> AgentSnapshotRasterView { .init() }
  func updateNSView(_ view: AgentSnapshotRasterView, context: Context) {
    view.bindSceneLifecycle(to: model)
    guard let raster, !raster.isReleased else { return }
    view.updateRaster(raster)
  }
  static func dismantleNSView(_ view: AgentSnapshotRasterView, coordinator: ()) { view.uninstall() }
}
#endif
